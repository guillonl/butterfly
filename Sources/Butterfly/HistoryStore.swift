import Foundation

struct HistoryEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let date: Date
    let original: String
    var corrected: String?
    var translated: String?
    var targetLanguage: String
}

/// Historique des corrections, persisté dans UserDefaults (50 entrées max).
@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    @Published private(set) var entries: [HistoryEntry] = []

    private let storageKey = "history"
    private let maxEntries = 50

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

    func clear() {
        entries = []
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) else { return }
        entries = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
