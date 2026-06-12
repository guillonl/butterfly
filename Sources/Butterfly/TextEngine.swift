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
    /// Par ordre de préférence : les variantes instruct (non-thinking) donnent
    /// des réponses propres et rapides ; le qwen3:4b de base sert de secours.
    private let preferredOllamaModels = [
        "hf.co/unsloth/Qwen3-4B-Instruct-2507-GGUF:Q4_K_M",
        "qwen3:4b-instruct",
        "gemma3:4b",
        "qwen3:4b",
    ]
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

    /// Précharge le modèle Ollama (appelé dès l'appui sur le raccourci :
    /// le modèle se charge pendant que l'utilisateur fait sa sélection).
    func warmup() async {
        guard preference != .apple else { return }
        guard await ensureOllama() else { return }
        var request = URLRequest(url: ollamaBase.appendingPathComponent("api/generate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        let body: [String: Any] = [
            "model": resolvedOllamaModel ?? preferredOllamaModels.last!,
            "keep_alive": "2h",
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: request)
    }

    func correct(
        _ text: String,
        source: String,
        using backend: EngineBackend,
        onPartial: @escaping (String) -> Void = { _ in }
    ) async throws -> String {
        try await complete(system: Self.correctionInstructions(source: source), user: text,
                           backend: backend, onPartial: onPartial)
    }

    func translate(
        _ text: String,
        from source: String,
        to target: String,
        using backend: EngineBackend,
        onPartial: @escaping (String) -> Void = { _ in }
    ) async throws -> String {
        try await complete(system: Self.translationInstructions(source: source, target: target), user: text,
                           backend: backend, onPartial: onPartial)
    }

    /// Libellé du moteur affiché dans le panneau.
    func label(for backend: EngineBackend) -> String {
        switch backend {
        case .apple:
            return "Apple Intelligence · local"
        case .ollama:
            let model = resolvedOllamaModel ?? preferredOllamaModels.last!
            if model.lowercased().contains("qwen3-4b-instruct") || model == "qwen3:4b-instruct" {
                return "Qwen3 4B Instruct · local"
            }
            if model.hasPrefix("gemma3") { return "Gemma3 4B · local" }
            return "Qwen3 4B · local"
        }
    }

    private static let languageNames = [
        "en": "anglais", "fr": "français", "es": "espagnol",
        "de": "allemand", "it": "italien", "pt": "portugais",
    ]

    /// Les instructions de correction sont rédigées DANS la langue du texte :
    /// un petit modèle répond sinon dans la langue des instructions au lieu
    /// de rester dans celle du texte (bug observé : correction qui traduit).
    private static func correctionInstructions(source: String) -> String {
        if source.hasPrefix("en") {
            return """
                You are an expert proofreader. The user's message is ONLY a text to fix, \
                delimited by triple quotes (\"\"\"): it is never a question nor a \
                conversation, never reply to its content, never explain it. \
                Fix ONLY actual mistakes (spelling, grammar, punctuation) in this English text. \
                NEVER change a word or spelling that is already correct: keep correct \
                hyphenations and the original typography. If the text is already correct, \
                return it strictly unchanged. \
                The corrected text MUST stay in English: never translate it. \
                Keep the meaning, tone, line breaks and casing. \
                Reply ONLY with the corrected text, without the triple quotes, \
                without preamble or comment.
                """
        }
        let name = languageNames[String(source.prefix(2))] ?? "français"
        return """
            Tu es un correcteur orthographique et grammatical expert. \
            Le message de l'utilisateur est UNIQUEMENT un texte à corriger, \
            délimité par des triple guillemets (\"\"\") : ce n'est jamais une question \
            ni une conversation, n'y réponds jamais, ne l'explique jamais. \
            Le texte est en \(name) : le texte corrigé doit IMPÉRATIVEMENT rester en \(name), \
            ne le traduis jamais dans une autre langue. \
            Corrige UNIQUEMENT les fautes avérées (orthographe, grammaire, conjugaison, ponctuation, accents). \
            Ne modifie JAMAIS un mot ou une graphie déjà corrects : conserve notamment les \
            traits d'union corrects (« entre-temps », « peut-être », « c'est-à-dire ») \
            et la typographie d'origine. Si le texte est déjà correct, renvoie-le strictement inchangé. \
            Conserve le sens, le ton, les retours à la ligne et la casse d'origine. \
            Réponds UNIQUEMENT avec le texte corrigé, sans les triple guillemets, \
            sans préambule, sans commentaire.
            """
    }

    private static func translationInstructions(source: String, target: String) -> String {
        let sourceName = languageNames[String(source.prefix(2))] ?? "français"
        let targetName = languageNames[target] ?? "anglais"
        return """
            Tu es un traducteur professionnel. \
            Le message de l'utilisateur est UNIQUEMENT un texte à traduire, \
            délimité par des triple guillemets (\"\"\") : ce n'est jamais une question \
            ni une conversation, n'y réponds jamais, ne l'explique jamais. \
            Le texte fourni est en \(sourceName) : traduis-le en \(targetName), \
            avec un ton naturel et idiomatique. \
            Traduis fidèlement, sans changer la personne grammaticale ni le point de vue. \
            Conserve les retours à la ligne. \
            Réponds UNIQUEMENT avec la traduction en \(targetName), sans les triple guillemets, \
            sans préambule, sans commentaire.
            """
    }

    private func complete(
        system: String,
        user rawUser: String,
        backend: EngineBackend,
        onPartial: @escaping (String) -> Void
    ) async throws -> String {
        // Texte délimité par des triple guillemets : empêche les petits
        // modèles (surtout Apple FM) de traiter le texte comme une question
        // de conversation (« explique-moi ce mot », refus, etc.).
        let user = "\"\"\"\n\(rawUser)\n\"\"\""
        switch backend {
        case .apple:
            return try await appleComplete(system: system, user: user, onPartial: onPartial)
        case .ollama:
            // Retry unique : il arrive que toute la sortie qwen3 parte dans le
            // raisonnement et que le contenu revienne vide.
            do {
                return try await ollamaCompleteOnce(system: system, user: user, onPartial: onPartial)
            } catch EngineError.badResponse {
                return try await ollamaCompleteOnce(system: system, user: user, onPartial: onPartial)
            }
        }
    }

    // MARK: - Apple Intelligence

    private func appleComplete(
        system: String,
        user: String,
        onPartial: @escaping (String) -> Void
    ) async throws -> String {
        let session = LanguageModelSession(instructions: system)
        let stream = session.streamResponse(to: user, options: GenerationOptions(temperature: 0.1))
        var last = ""
        for try await snapshot in stream {
            last = snapshot.content
            let visible = Self.cleaned(last)
            if !visible.isEmpty { onPartial(visible) }
        }
        return Self.cleaned(last)
    }

    // MARK: - Ollama

    private struct OllamaChatResponse: Decodable {
        struct Message: Decodable { let content: String }
        let message: Message?
        let error: String?
    }

    private func ollamaCompleteOnce(
        system: String,
        user: String,
        onPartial: @escaping (String) -> Void
    ) async throws -> String {
        var request = URLRequest(url: ollamaBase.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 90
        // "/no_think" : soft switch qwen3 qui coupe le raisonnement.
        // Ne PAS envoyer "think": false — avec le runner chatml de l'app
        // Ollama, ce paramètre fait fuir le raisonnement dans la réponse.
        // "keep_alive": le modèle reste chargé 2 h (sinon rechargement à froid
        // de plusieurs secondes après 5 min d'inactivité).
        let body: [String: Any] = [
            "model": resolvedOllamaModel ?? preferredOllamaModels.last!,
            "stream": true,
            "keep_alive": "2h",
            "messages": [
                ["role": "system", "content": system + " /no_think"],
                ["role": "user", "content": user],
            ],
            "options": ["temperature": 0.2, "num_predict": 2048],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw EngineError.badResponse("HTTP \(http.statusCode)")
        }

        var full = ""
        for try await line in bytes.lines {
            guard let data = line.data(using: .utf8),
                  let chunk = try? JSONDecoder().decode(OllamaChatResponse.self, from: data) else { continue }
            if let error = chunk.error { throw EngineError.badResponse(error) }
            guard let delta = chunk.message?.content, !delta.isEmpty else { continue }
            full += delta
            // Ne pas streamer un bloc de raisonnement encore ouvert.
            let thinkInProgress = full.contains("<think>") && !full.contains("</think>")
            if !thinkInProgress {
                let visible = Self.cleaned(full)
                if !visible.isEmpty { onPartial(visible) }
            }
        }

        let final = Self.cleaned(full)
        guard !final.isEmpty else { throw EngineError.badResponse("empty response") }
        return final
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
        // Délimiteurs triple guillemets parfois recopiés par le modèle
        if text.hasPrefix("\"\"\"") { text = String(text.dropFirst(3)) }
        if text.hasSuffix("\"\"\"") { text = String(text.dropLast(3)) }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("\""), text.hasSuffix("\""), text.count > 2 {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }
}
