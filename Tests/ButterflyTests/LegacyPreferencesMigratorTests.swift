import Foundation
import Testing
@testable import Butterfly

@Suite("Migration Butterfly Beta")
struct LegacyPreferencesMigratorTests {
    @Test("fusionne l'historique sans écraser les réglages stables")
    func mergesHistoryAndPreservesStablePreferences() throws {
        let currentName = "test.butterfly.current.\(UUID().uuidString)"
        let legacyName = "test.butterfly.legacy.\(UUID().uuidString)"
        let current = try #require(UserDefaults(suiteName: currentName))
        let legacy = try #require(UserDefaults(suiteName: legacyName))
        defer {
            current.removePersistentDomain(forName: currentName)
            legacy.removePersistentDomain(forName: legacyName)
        }

        current.set("apple", forKey: "enginePreference")
        legacy.set("ollama", forKey: "enginePreference")
        legacy.set(true, forKey: "onboardingDone")

        let stableEntry = HistoryEntry(
            id: UUID(), date: Date(timeIntervalSince1970: 200),
            original: "stable", corrected: "stable", translated: nil,
            targetLanguage: "en"
        )
        let betaEntry = HistoryEntry(
            id: UUID(), date: Date(timeIntervalSince1970: 100),
            original: "beta", corrected: "bêta", translated: nil,
            targetLanguage: "fr"
        )
        current.set(try JSONEncoder().encode([stableEntry]), forKey: "history")
        legacy.set(try JSONEncoder().encode([betaEntry]), forKey: "history")

        let result = LegacyPreferencesMigrator.migrateIfNeeded(current: current, legacy: legacy)

        #expect(current.string(forKey: "enginePreference") == "apple")
        #expect(current.bool(forKey: "onboardingDone"))
        #expect(result.copiedKeys == 1)
        #expect(result.importedHistoryEntries == 1)
        let data = try #require(current.data(forKey: "history"))
        let history = try JSONDecoder().decode([HistoryEntry].self, from: data)
        #expect(history.map(\.id) == [stableEntry.id, betaEntry.id])
    }

    @Test("ne rejoue pas une migration terminée")
    func migrationIsIdempotent() throws {
        let currentName = "test.butterfly.current.\(UUID().uuidString)"
        let legacyName = "test.butterfly.legacy.\(UUID().uuidString)"
        let current = try #require(UserDefaults(suiteName: currentName))
        let legacy = try #require(UserDefaults(suiteName: legacyName))
        defer {
            current.removePersistentDomain(forName: currentName)
            legacy.removePersistentDomain(forName: legacyName)
        }
        legacy.set("ollama", forKey: "enginePreference")

        _ = LegacyPreferencesMigrator.migrateIfNeeded(current: current, legacy: legacy)
        legacy.set("apple", forKey: "enginePreference")
        let second = LegacyPreferencesMigrator.migrateIfNeeded(current: current, legacy: legacy)

        #expect(current.string(forKey: "enginePreference") == "ollama")
        #expect(second == .init(copiedKeys: 0, importedHistoryEntries: 0))
    }
}
