import Foundation
import WhisperKit

/// Option « Qualité maximale » de la dictée : Whisper large-v3-turbo (CoreML,
/// argmaxinc/WhisperKit), meilleur français brut que le modèle système, avec
/// détection de langue native. Transcription 100 % locale ; seul le
/// téléchargement du modèle (~1,5 Go, sur bouton explicite) touche le réseau.
@MainActor
final class WhisperEngine: ObservableObject {
    static let shared = WhisperEngine()

    enum ModelState: Equatable {
        case notDownloaded
        /// Progression 0…1 du téléchargement.
        case downloading(Double)
        /// Modèle sur disque, chargement CoreML en cours (long au premier run).
        case loading
        case ready
        case failed(String)
    }

    @Published private(set) var state: ModelState

    private var kit: WhisperKit?
    /// Variante pleine précision (les quantizations dégradent le français).
    private static let variant = "openai_whisper-large-v3-v20240930_turbo"

    static var modelsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Butterfly/WhisperModels", isDirectory: true)
    }

    /// Cherche un dossier de modèle turbo sous `base` (WhisperKit range le
    /// modèle sous <base>/models/<repo>/<variant>).
    private static func findModelFolder(under base: URL) -> URL? {
        func find(in url: URL, depth: Int) -> URL? {
            guard depth < 4 else { return nil }
            if url.lastPathComponent.contains("turbo") { return url }
            let children = (try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )) ?? []
            for child in children {
                if let found = find(in: child, depth: depth + 1) { return found }
            }
            return nil
        }
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: base, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return nil }
        for url in contents {
            if let found = find(in: url, depth: 0) { return found }
        }
        return nil
    }

    /// Modèle EMBARQUÉ dans l'app (distribution clé en main : rien à
    /// télécharger pour l'utilisateur). build.sh le copie dans Resources.
    static var bundledModelFolder: URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let base = resources.appendingPathComponent("WhisperModels", isDirectory: true)
        guard FileManager.default.fileExists(atPath: base.path) else { return nil }
        return findModelFolder(under: base)
    }

    /// Dossier du modèle téléchargé par l'utilisateur, s'il existe.
    static var downloadedModelFolder: URL? {
        findModelFolder(under: modelsDirectory)
    }

    /// Le modèle disponible : embarqué d'abord, téléchargé sinon.
    static var availableModelFolder: URL? {
        bundledModelFolder ?? downloadedModelFolder
    }

    var isReady: Bool { state == .ready }

    init() {
        state = Self.availableModelFolder != nil ? .loading : .notDownloaded
    }

    /// Charge le modèle s'il est sur disque (préchargé au lancement quand
    /// l'option Qualité est active ; le premier chargement CoreML est long).
    func loadIfNeeded() async {
        guard kit == nil, let folder = Self.availableModelFolder else {
            if kit == nil { state = .notDownloaded }
            return
        }
        state = .loading
        do {
            let config = WhisperKitConfig(modelFolder: folder.path)
            kit = try await WhisperKit(config)
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Télécharge le modèle (~1,5 Go) puis le charge. Déclenché UNIQUEMENT
    /// par le bouton des Réglages : jamais de réseau silencieux.
    func downloadAndLoad() {
        guard case .notDownloaded = state else { return }
        state = .downloading(0)
        Task { @MainActor in
            do {
                try FileManager.default.createDirectory(at: Self.modelsDirectory, withIntermediateDirectories: true)
                _ = try await WhisperKit.download(
                    variant: Self.variant,
                    downloadBase: Self.modelsDirectory,
                    progressCallback: { progress in
                        Task { @MainActor [weak self] in
                            self?.state = .downloading(progress.fractionCompleted)
                        }
                    }
                )
                await loadIfNeeded()
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// Supprime le modèle TÉLÉCHARGÉ (récupère ~1,5 Go) ; un modèle embarqué
    /// dans l'app, lui, reste disponible.
    func removeModel() {
        kit = nil
        try? FileManager.default.removeItem(at: Self.modelsDirectory)
        state = Self.availableModelFolder != nil ? .loading : .notDownloaded
    }

    /// Transcrit un fichier audio. `language` : "fr"/"en"… ou nil pour la
    /// détection automatique native de Whisper.
    func transcribe(url: URL, language: String?) async throws -> (text: String, language: String) {
        guard let kit else { throw DictationEngine.DictationError.audioEngineUnavailable }
        var options = DecodingOptions(
            task: .transcribe,
            language: language,
            usePrefillPrompt: true,
            chunkingStrategy: .vad
        )
        // Sans langue imposée : activer explicitement la détection.
        options.detectLanguage = language == nil
        let results = try await kit.transcribe(audioPath: url.path, decodeOptions: options)
        let text = results.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let detected = results.first?.language ?? language ?? "fr"
        return (text, detected)
    }
}
