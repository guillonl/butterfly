import Foundation

/// Nature d'une entrée de la bibliothèque (sidebar de la fenêtre principale).
enum EntryKind: String, Codable {
    case correction
    case dictation
}

struct HistoryEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let date: Date
    let original: String
    var corrected: String?
    var translated: String?
    var targetLanguage: String
    /// correction (capture/sélection) ou dictée. Optionnel pour décoder les
    /// historiques existants (antérieurs à la refonte) : nil = correction.
    var kind: EntryKind = .correction
    /// App où le texte a été inséré/capturé (« Mail », « Slack »…).
    var sourceApp: String?
    /// Déclencheur : "capture" (⌥⌘B), "selection" (⌃⌘B), "dictation" (fn).
    var trigger: String?
    /// Dictée : transcription brute avant correction à la volée.
    var rawTranscript: String?
    /// Dictée : durée de l'enregistrement (secondes).
    var duration: TimeInterval?
    /// Dictée : nom du fichier audio dans Application Support/Butterfly/Recordings.
    var audioFile: String?
    /// Libellé du moteur qui a traité l'entrée (« Apple Intelligence · local »).
    var engine: String?
    /// Durée réelle du traitement (mesurée, jamais estimée).
    var processingTime: TimeInterval?

    init(
        id: UUID,
        date: Date,
        original: String,
        corrected: String? = nil,
        translated: String? = nil,
        targetLanguage: String,
        kind: EntryKind = .correction,
        sourceApp: String? = nil,
        trigger: String? = nil,
        rawTranscript: String? = nil,
        duration: TimeInterval? = nil,
        audioFile: String? = nil,
        engine: String? = nil,
        processingTime: TimeInterval? = nil
    ) {
        self.id = id
        self.date = date
        self.original = original
        self.corrected = corrected
        self.translated = translated
        self.targetLanguage = targetLanguage
        self.kind = kind
        self.sourceApp = sourceApp
        self.trigger = trigger
        self.rawTranscript = rawTranscript
        self.duration = duration
        self.audioFile = audioFile
        self.engine = engine
        self.processingTime = processingTime
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        date = try container.decode(Date.self, forKey: .date)
        original = try container.decode(String.self, forKey: .original)
        corrected = try container.decodeIfPresent(String.self, forKey: .corrected)
        translated = try container.decodeIfPresent(String.self, forKey: .translated)
        targetLanguage = try container.decode(String.self, forKey: .targetLanguage)
        kind = try container.decodeIfPresent(EntryKind.self, forKey: .kind) ?? .correction
        sourceApp = try container.decodeIfPresent(String.self, forKey: .sourceApp)
        trigger = try container.decodeIfPresent(String.self, forKey: .trigger)
        rawTranscript = try container.decodeIfPresent(String.self, forKey: .rawTranscript)
        duration = try container.decodeIfPresent(TimeInterval.self, forKey: .duration)
        audioFile = try container.decodeIfPresent(String.self, forKey: .audioFile)
        engine = try container.decodeIfPresent(String.self, forKey: .engine)
        processingTime = try container.decodeIfPresent(TimeInterval.self, forKey: .processingTime)
    }
}

/// Historique des corrections, persisté dans UserDefaults (50 entrées max).
@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    @Published private(set) var entries: [HistoryEntry] = []

    private let storageKey = "history"
    private let maxEntries = 200

    init() {
        load()
    }

    func add(_ entry: HistoryEntry) {
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }
        save()
    }

    func updateCorrection(id: UUID, corrected: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].corrected = corrected
        save()
    }

    func updateTranslation(id: UUID, translated: String, language: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].translated = translated
        entries[index].targetLanguage = language
        save()
    }

    func updateMetrics(id: UUID, engine: String, processingTime: TimeInterval) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].engine = engine
        entries[index].processingTime = processingTime
        save()
    }

    func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    func clear() {
        entries = []
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) else { return }
        entries = decoded
    }

    /// Fixtures `--demo-main` : remplace en mémoire sans jamais persister.
    func loadDemoEntries(_ demo: [HistoryEntry]) {
        demoMode = true
        entries = demo
    }

    private var demoMode = false

    private func save() {
        guard !demoMode else { return }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
