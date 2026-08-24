import Foundation

/// Consolide une ancienne installation « Butterfly Beta » vers l'identité
/// stable sans écraser les réglages déjà utilisés dans Butterfly.
enum LegacyPreferencesMigrator {
    static let legacyBundleIdentifier = "com.leoguillon.butterfly.beta"
    static let migrationKey = "migration.beta.v1.completed"

    struct Result: Equatable {
        let copiedKeys: Int
        let importedHistoryEntries: Int
    }

    @discardableResult
    static func migrateIfNeeded(
        current: UserDefaults = .standard,
        legacy: UserDefaults? = UserDefaults(suiteName: legacyBundleIdentifier)
    ) -> Result {
        guard !current.bool(forKey: migrationKey), let legacy else {
            return Result(copiedKeys: 0, importedHistoryEntries: 0)
        }

        let scalarKeys = [
            "onboardingDone", "enginePreference", "processingMode",
            "showTranslation", "targetLanguage", "targetPresets",
            "shortcutCapture", "shortcutSelection", "resultPanelSize",
        ]
        var copiedKeys = 0
        for key in scalarKeys where current.object(forKey: key) == nil {
            guard let value = legacy.object(forKey: key) else { continue }
            current.set(value, forKey: key)
            copiedKeys += 1
        }

        let decoder = JSONDecoder()
        let currentEntries = current.data(forKey: "history")
            .flatMap { try? decoder.decode([HistoryEntry].self, from: $0) } ?? []
        let legacyEntries = legacy.data(forKey: "history")
            .flatMap { try? decoder.decode([HistoryEntry].self, from: $0) } ?? []

        var seen = Set(currentEntries.map(\.id))
        let imported = legacyEntries.filter { seen.insert($0.id).inserted }
        let merged = (currentEntries + imported)
            .sorted { $0.date > $1.date }
            .prefix(50)
        if !imported.isEmpty, let data = try? JSONEncoder().encode(Array(merged)) {
            current.set(data, forKey: "history")
        }

        current.set(true, forKey: migrationKey)
        return Result(copiedKeys: copiedKeys, importedHistoryEntries: imported.count)
    }
}
