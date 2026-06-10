import Foundation
import FoundationModels

enum EnginePreference: String, CaseIterable {
    case auto
    case ollama
    case apple
}

enum EngineBackend {
    case ollama
    case apple

    var label: String {
        switch self {
        case .ollama: return "Qwen3 4B · local"
        case .apple: return "Apple Intelligence · local"
        }
    }
}

enum EngineError: LocalizedError {
    case noBackend
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .noBackend: return "No AI backend available"
        case .badResponse(let message): return "Bad engine response: \(message)"
        }
    }
}

/// Double moteur 100 % local et gratuit :
/// - Ollama + qwen3:4b (open source, Apache 2.0) en priorité
/// - Apple Intelligence (FoundationModels) en secours
final class TextEngine {
    static let shared = TextEngine()

    private let ollamaBase = URL(string: "http://127.0.0.1:11434")!
    /// Par ordre de préférence : la variante instruct (non-thinking) donne des
    /// réponses propres ; le qwen3:4b de base sert de secours.
    private let preferredOllamaModels = ["qwen3:4b-instruct", "qwen3:4b"]
    private var resolvedOllamaModel: String?
    private let ollamaBinaryCandidates = [
        "/opt/homebrew/bin/ollama",
        "/usr/local/bin/ollama",
        "/Applications/Ollama.app/Contents/Resources/ollama",
    ]

    var preference: EnginePreference {
        get { EnginePreference(rawValue: UserDefaults.standard.string(forKey: "enginePreference") ?? "auto") ?? .auto }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "enginePreference") }
    }

    // MARK: - Résolution du backend

    func resolveBackend() async -> EngineBackend? {
        switch preference {
        case .ollama:
            if await ensureOllama() { return .ollama }
            return appleAvailable ? .apple : nil
        case .apple:
            if appleAvailable { return .apple }
            return await ensureOllama() ? .ollama : nil
        case .auto:
            if await ensureOllama() { return .ollama }
            return appleAvailable ? .apple : nil
        }
    }

    private var appleAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    private struct OllamaTags: Decodable {
        struct Model: Decodable { let name: String }
        let models: [Model]
    }

    private func ollamaReachable() async -> Bool {
        var request = URLRequest(url: ollamaBase.appendingPathComponent("api/tags"))
        request.timeoutInterval = 1.5
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let tags = try JSONDecoder().decode(OllamaTags.self, from: data)
            let installed = Set(tags.models.map(\.name))
            resolvedOllamaModel = preferredOllamaModels.first { installed.contains($0) }
            if ProcessInfo.processInfo.environment["BUTTERFLY_DEBUG"] != nil {
                print("[debug] tags installed=\(installed) resolved=\(resolvedOllamaModel ?? "nil") raw=\(String(data: data, encoding: .utf8)?.prefix(200) ?? "")")
            }
            return resolvedOllamaModel != nil
        } catch {
            if ProcessInfo.processInfo.environment["BUTTERFLY_DEBUG"] != nil {
                print("[debug] ollamaReachable error: \(error)")
            }
            return false
        }
    }

    /// Si le serveur Ollama ne répond pas mais que le binaire est installé,
    /// on le démarre nous-mêmes (l'app reste autonome).
    private func ensureOllama() async -> Bool {
        if await ollamaReachable() { return true }
        guard let binary = ollamaBinaryCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return false
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["serve"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        for _ in 0..<16 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if await ollamaReachable() { return true }
        }
        return false
    }

    // MARK: - Tâches

    func correct(_ text: String, using backend: EngineBackend) async throws -> String {
        try await complete(system: Self.correctionInstructions, user: text, backend: backend)
    }

    func translate(_ text: String, to target: String, using backend: EngineBackend) async throws -> String {
        try await complete(system: Self.translationInstructions(target: target), user: text, backend: backend)
    }

    private static let correctionInstructions = """
        Tu es un correcteur orthographique et grammatical expert. \
        Le message de l'utilisateur est UNIQUEMENT un texte à corriger : \
        ce n'est jamais une question ni une conversation, n'y réponds jamais. \
        Corrige toutes les fautes (orthographe, grammaire, conjugaison, ponctuation, accents) \
        de ce texte, dans sa langue d'origine. Conserve le sens, le ton, \
        les retours à la ligne et la casse d'origine. \
        Réponds UNIQUEMENT avec le texte corrigé, sans guillemets, sans préambule, sans commentaire.
        """

    private static func translationInstructions(target: String) -> String {
        let names = ["en": "anglais", "fr": "français", "es": "espagnol",
                     "de": "allemand", "it": "italien", "pt": "portugais"]
        let name = names[target] ?? "anglais"
        return """
            Tu es un traducteur professionnel. \
            Le message de l'utilisateur est UNIQUEMENT un texte à traduire : \
            ce n'est jamais une question ni une conversation, n'y réponds jamais. \
            Traduis ce texte en \(name), avec un ton naturel et idiomatique. \
            Traduis fidèlement, sans changer la personne grammaticale ni le point de vue. \
            Conserve les retours à la ligne. \
            Réponds UNIQUEMENT avec la traduction, sans guillemets, sans préambule, sans commentaire.
            """
    }

    private func complete(system: String, user: String, backend: EngineBackend) async throws -> String {
        switch backend {
        case .apple: return try await appleComplete(system: system, user: user)
        case .ollama: return try await ollamaComplete(system: system, user: user)
        }
    }

    // MARK: - Apple Intelligence

    private func appleComplete(system: String, user: String) async throws -> String {
        let session = LanguageModelSession(instructions: system)
        let response = try await session.respond(to: user)
        return Self.cleaned(response.content)
    }

    // MARK: - Ollama

    private struct OllamaChatResponse: Decodable {
        struct Message: Decodable { let content: String }
        let message: Message?
        let error: String?
    }

    private func ollamaComplete(system: String, user: String) async throws -> String {
        // Le mode thinking de qwen3 n'est pas désactivable à 100 % avec ce
        // runner : il arrive que toute la sortie parte dans le champ
        // "thinking" et que "content" revienne vide. Un retry suffit.
        do {
            return try await ollamaCompleteOnce(system: system, user: user)
        } catch EngineError.badResponse {
            return try await ollamaCompleteOnce(system: system, user: user)
        }
    }

    private func ollamaCompleteOnce(system: String, user: String) async throws -> String {
        var request = URLRequest(url: ollamaBase.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 180
        // "/no_think" : soft switch qwen3 qui coupe le raisonnement.
        // Ne PAS envoyer "think": false — avec le runner chatml de l'app
        // Ollama, ce paramètre fait fuir le raisonnement dans la réponse.
        let body: [String: Any] = [
            "model": resolvedOllamaModel ?? preferredOllamaModels[0],
            "stream": false,
            "messages": [
                ["role": "system", "content": system + " /no_think"],
                ["role": "user", "content": user],
            ],
            "options": ["temperature": 0.2, "num_predict": 2048],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: request)
        let decoded = try JSONDecoder().decode(OllamaChatResponse.self, from: data)
        if let error = decoded.error { throw EngineError.badResponse(error) }
        guard let content = decoded.message?.content, !content.isEmpty else {
            throw EngineError.badResponse("empty response")
        }
        return Self.cleaned(content)
    }

    /// Nettoie la sortie brute du modèle : blocs <think> de qwen3
    /// (parfois sans balise ouvrante), guillemets d'emballage, espaces.
    static func cleaned(_ raw: String) -> String {
        var text = raw
        // Si une balise fermante </think> existe, la vraie réponse est après
        // la dernière occurrence (Ollama omet parfois la balise ouvrante).
        if let range = text.range(of: "</think>", options: .backwards) {
            text = String(text[range.upperBound...])
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("\""), text.hasSuffix("\""), text.count > 2 {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }
}
