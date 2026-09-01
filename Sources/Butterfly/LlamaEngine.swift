import Foundation
import llama

/// Moteur de texte intégré : Qwen3 4B Instruct (GGUF Q4_K_M) exécuté
/// in-process par llama.cpp (Metal). Aucun serveur, aucun process externe,
/// aucune installation : le modèle (~2,5 Go) se télécharge sur bouton
/// explicite dans Réglages > Moteur IA, puis tout reste local.
///
/// Légèreté : le GGUF est chargé en mmap (la mémoire résidente ne contient
/// que les pages réellement utilisées, le système les récupère sous
/// pression) ; un contexte court est recréé à chaque requête.
@MainActor
final class LlamaEngine: ObservableObject {
    static let shared = LlamaEngine()

    enum ModelState: Equatable {
        case notDownloaded
        case downloading(Double)
        case loading
        case ready
        case failed(String)
    }

    @Published private(set) var state: ModelState

    /// Le modèle exact validé sur ce projet (pull direct Hugging Face).
    private static let modelURL = URL(string:
        "https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/main/Qwen3-4B-Instruct-2507-Q4_K_M.gguf"
    )!
    static var modelLabel: String { L10n.t("engine.builtinLabel") }

    nonisolated static var modelFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Butterfly/LLM/Qwen3-4B-Instruct-2507-Q4_K_M.gguf")
    }

    nonisolated static var isModelDownloaded: Bool {
        FileManager.default.fileExists(atPath: modelFile.path)
    }

    private var model: OpaquePointer?
    private var downloader: ModelDownloader?

    var isReady: Bool { state == .ready }

    init() {
        state = Self.isModelDownloaded ? .loading : .notDownloaded
    }

    // MARK: - Cycle de vie du modèle

    /// Charge le modèle s'il est sur disque (mmap : quasi instantané).
    func loadIfNeeded() async {
        guard model == nil else {
            state = .ready
            return
        }
        guard Self.isModelDownloaded else {
            state = .notDownloaded
            return
        }
        state = .loading
        let path = Self.modelFile.path
        let loaded = await Task.detached(priority: .userInitiated) { () -> OpaquePointer? in
            llama_backend_init()
            var params = llama_model_default_params()
            params.n_gpu_layers = 99 // tout sur Metal (le GGUF reste en mmap)
            return llama_model_load_from_file(path, params)
        }.value
        if let loaded {
            model = loaded
            state = .ready
        } else {
            state = .failed("Modèle illisible")
        }
    }

    /// Télécharge le GGUF (~2,5 Go) puis charge. Bouton explicite uniquement.
    func downloadAndLoad() {
        guard case .notDownloaded = state else { return }
        state = .downloading(0)
        let downloader = ModelDownloader(
            url: Self.modelURL,
            destination: Self.modelFile,
            onProgress: { [weak self] progress in
                Task { @MainActor [weak self] in
                    if case .downloading = self?.state { self?.state = .downloading(progress) }
                }
            },
            onCompletion: { [weak self] error in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.downloader = nil
                    if let error {
                        self.state = .failed(error.localizedDescription)
                    } else {
                        await self.loadIfNeeded()
                    }
                }
            }
        )
        self.downloader = downloader
        downloader.start()
    }

    /// Libère le modèle de la mémoire sans toucher au fichier (teardown
    /// propre : sans lui, la destruction du backend Metal à la sortie du
    /// process fait sauter un assert ggml sur les residency sets).
    func unload() {
        if let model { llama_model_free(model) }
        model = nil
        if state == .ready {
            state = Self.isModelDownloaded ? .loading : .notDownloaded
        }
    }

    /// Supprime le modèle du disque (récupère ~2,5 Go).
    func removeModel() {
        if let model { llama_model_free(model) }
        model = nil
        try? FileManager.default.removeItem(at: Self.modelFile)
        state = .notDownloaded
    }

    // MARK: - Inférence

    enum LlamaError: LocalizedError {
        case notReady
        case decodeFailed
        var errorDescription: String? {
            switch self {
            case .notReady: return "Modèle Qwen3 intégré pas prêt"
            case .decodeFailed: return "Échec de décodage llama.cpp"
            }
        }
    }

    /// Complétion chat (system + user), streaming par onPartial.
    /// Le template de chat vient du GGUF lui-même (ChatML pour Qwen3).
    func complete(
        system: String,
        user: String,
        temperature: Double,
        onPartial: @escaping (String) -> Void
    ) async throws -> String {
        if model == nil { await loadIfNeeded() }
        guard let model, isReady else { throw LlamaError.notReady }

        return try await Task.detached(priority: .userInitiated) { () -> String in
            // 1. Prompt via le chat template du modèle.
            let prompt = Self.applyChatTemplate(model: model, system: system, user: user)

            // 2. Contexte frais (kv cache court, libéré à la fin).
            var contextParams = llama_context_default_params()
            contextParams.n_ctx = 4096
            contextParams.n_batch = 512
            guard let context = llama_init_from_model(model, contextParams) else {
                throw LlamaError.decodeFailed
            }
            defer { llama_free(context) }

            guard let vocab = llama_model_get_vocab(model) else { throw LlamaError.decodeFailed }

            // 3. Tokenisation du prompt.
            let utf8 = Array(prompt.utf8)
            var tokens = [llama_token](repeating: 0, count: utf8.count + 16)
            let tokenCount = llama_tokenize(
                vocab, prompt, Int32(utf8.count), &tokens, Int32(tokens.count), true, true
            )
            guard tokenCount > 0 else { throw LlamaError.decodeFailed }
            tokens.removeSubrange(Int(tokenCount)...)

            // 4. Prompt par tranches de n_batch, puis génération token par token.
            var index = 0
            while index < tokens.count {
                let chunk = Array(tokens[index..<min(index + 512, tokens.count)])
                var mutableChunk = chunk
                let batch = llama_batch_get_one(&mutableChunk, Int32(chunk.count))
                guard llama_decode(context, batch) >= 0 else { throw LlamaError.decodeFailed }
                index += chunk.count
            }

            // 5. Chaîne de sampling : température + tirage (greedy si ~0).
            let samplerParams = llama_sampler_chain_default_params()
            guard let sampler = llama_sampler_chain_init(samplerParams) else { throw LlamaError.decodeFailed }
            defer { llama_sampler_free(sampler) }
            if temperature <= 0.05 {
                llama_sampler_chain_add(sampler, llama_sampler_init_greedy())
            } else {
                llama_sampler_chain_add(sampler, llama_sampler_init_min_p(0.05, 1))
                llama_sampler_chain_add(sampler, llama_sampler_init_temp(Float(temperature)))
                llama_sampler_chain_add(sampler, llama_sampler_init_dist(LLAMA_DEFAULT_SEED))
            }

            var output = ""
            var pieceBuffer = [CChar](repeating: 0, count: 256)
            for _ in 0..<1024 {
                let token = llama_sampler_sample(sampler, context, -1)
                if llama_vocab_is_eog(vocab, token) { break }
                let length = llama_token_to_piece(vocab, token, &pieceBuffer, Int32(pieceBuffer.count), 0, false)
                if length > 0 {
                    let piece = String(
                        decoding: pieceBuffer[0..<Int(length)].map { UInt8(bitPattern: $0) },
                        as: UTF8.self
                    )
                    output += piece
                    let snapshot = output.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task { @MainActor in onPartial(snapshot) }
                }
                var next = token
                let batch = llama_batch_get_one(&next, 1)
                guard llama_decode(context, batch) >= 0 else { break }
            }
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
    }

    /// Applique le chat template embarqué dans le GGUF (ChatML pour Qwen3).
    private nonisolated static func applyChatTemplate(model: OpaquePointer, system: String, user: String) -> String {
        let template = llama_model_chat_template(model, nil).map { String(cString: $0) }
        var result = ""
        system.withCString { systemPointer in
            user.withCString { userPointer in
                "system".withCString { systemRole in
                    "user".withCString { userRole in
                        var messages = [
                            llama_chat_message(role: systemRole, content: systemPointer),
                            llama_chat_message(role: userRole, content: userPointer),
                        ]
                        let capacity = (system.utf8.count + user.utf8.count) * 2 + 512
                        var buffer = [CChar](repeating: 0, count: capacity)
                        let written = llama_chat_apply_template(
                            template, &messages, messages.count, true, &buffer, Int32(capacity)
                        )
                        if written > 0 {
                            result = String(
                                decoding: buffer[0..<Int(written)].map { UInt8(bitPattern: $0) },
                                as: UTF8.self
                            )
                        }
                    }
                }
            }
        }
        if result.isEmpty {
            // Repli ChatML explicite (le template Qwen3 est du ChatML).
            result = "<|im_start|>system\n\(system)<|im_end|>\n<|im_start|>user\n\(user)<|im_end|>\n<|im_start|>assistant\n"
        }
        return result
    }
}

/// Téléchargement avec progression (URLSession delegate) et reprise refusée
/// simple : un fichier .part déplacé à la fin.
final class ModelDownloader: NSObject, URLSessionDownloadDelegate {
    private let url: URL
    private let destination: URL
    private let onProgress: (Double) -> Void
    private let onCompletion: (Error?) -> Void
    private var session: URLSession?

    init(
        url: URL,
        destination: URL,
        onProgress: @escaping (Double) -> Void,
        onCompletion: @escaping (Error?) -> Void
    ) {
        self.url = url
        self.destination = destination
        self.onProgress = onProgress
        self.onCompletion = onCompletion
    }

    func start() {
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        self.session = session
        session.downloadTask(with: url).resume()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            onCompletion(nil)
        } catch {
            onCompletion(error)
        }
        self.session?.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            onCompletion(error)
            self.session?.finishTasksAndInvalidate()
        }
    }
}
