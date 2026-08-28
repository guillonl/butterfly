import AppKit
import ApplicationServices
import NaturalLanguage

/// Orchestre la dictée système : fn maintenu → micro + HUD → relâche →
/// nettoyage LLM → insertion au curseur → historique → observation des
/// retouches (boucle d'apprentissage).
///
/// Choix issus de la recherche Wispr Flow (2026-08-28) :
/// - observation par lecture AX différée, JAMAIS de CGEventTap global ;
/// - insertion presse-papiers + ⌘V + restauration (PasteService).
@MainActor
final class DictationController {

    private let engine = DictationEngine()
    private let hud = DictationHUDController()
    private var monitors: [Any] = []
    private var session: Session?
    private var hudTimer: Timer?

    private struct Session {
        let startedAt: Date
        let appName: String?
        let recordingFile: String?
    }

    /// Vrai pendant qu'une dictée est active (évite les doubles départs).
    private var isActive = false

    // MARK: - Raccourci fn (maintien)

    /// Démarre l'écoute du fn global. Exige la permission Accessibilité
    /// (déjà requise par la correction de sélection).
    func start() {
        guard monitors.isEmpty else { return }
        // fn enfoncé/relâché = flagsChanged keyCode 63. Monitors global
        // (autres apps) + local (Butterfly frontale).
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            Task { @MainActor in self?.handleFlags(event) }
        }) {
            monitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            Task { @MainActor in self?.handleFlags(event) }
            return event
        }) {
            monitors.append(monitor)
        }
        // Échap pendant une dictée : annulation.
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor in await self?.cancel() }
        }) {
            monitors.append(monitor)
        }
    }

    func stopMonitoring() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
    }

    private func handleFlags(_ event: NSEvent) {
        guard event.keyCode == 63 else { return }
        if event.modifierFlags.contains(.function) {
            Task { await begin() }
        } else {
            Task { await finish() }
        }
    }

    // MARK: - Session

    private func begin() async {
        guard !isActive else { return }
        isActive = true

        // Capturer l'app cible AVANT d'afficher quoi que ce soit.
        let appName = NSWorkspace.shared.frontmostApplication?.localizedName

        // Locale : langue système de l'utilisateur (fr/en…) ; le modèle
        // SpeechTranscriber est par locale.
        let locale = Locale(identifier: L10n.isFrench ? "fr_FR" : "en_US")

        // Fichier de réécoute (Application Support/Butterfly/Recordings).
        var recordingFile: String?
        var recordingURL: URL?
        if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let directory = support.appendingPathComponent("Butterfly/Recordings", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let name = "dictation-\(Int(Date().timeIntervalSince1970)).caf"
            recordingFile = name
            recordingURL = directory.appendingPathComponent(name)
        }

        session = Session(startedAt: Date(), appName: appName, recordingFile: recordingFile)

        hud.model.languageCode = String(locale.identifier.prefix(2))
        hud.show()

        engine.onLevel = { [weak self] level in
            self?.hud.model.level = level
        }
        hudTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.hud.model.elapsed = self.engine.elapsed
            }
        }

        do {
            try await engine.startMicrophone(locale: locale, recordingURL: recordingURL)
        } catch {
            hud.model.phase = .failed(error.localizedDescription)
            hud.close(after: 1.6)
            endSession()
        }
    }

    private func finish() async {
        guard isActive, let session else { return }
        hudTimer?.invalidate()
        hudTimer = nil

        // Appui trop bref (tap accidentel sur fn) : annuler sans bruit.
        let duration = Date().timeIntervalSince(session.startedAt)
        guard duration > 0.4 else {
            await cancelSilently(session: session)
            return
        }

        hud.model.phase = .processing
        let raw = await engine.stop()
        guard !raw.isEmpty else {
            deleteRecording(session.recordingFile)
            hud.model.phase = .failed(L10n.t("hud.noText"))
            hud.close(after: 1.4)
            endSession()
            return
        }

        // Nettoyage LLM avec le profil de langage (mesuré).
        let source = String(engine.locale.identifier.prefix(2))
        let profile = LanguageProfileStore.shared
        var cleaned = raw
        var engineLabel: String?
        var processingTime: TimeInterval?
        if let backend = await TextEngine.shared.resolveBackend() {
            let started = Date()
            if let result = try? await TextEngine.shared.cleanupDictation(
                raw,
                source: source,
                profileFragment: profile.promptFragment(),
                appName: session.appName,
                using: backend
            ), !result.isEmpty {
                cleaned = result
                engineLabel = TextEngine.shared.label(for: backend)
                processingTime = Date().timeIntervalSince(started)
            }
        }

        // Comptabiliser les règles apprises effectivement appliquées.
        if profile.loopEnabled {
            for rule in profile.vocab where rule.status == .learned {
                if raw.localizedCaseInsensitiveContains(rule.heard),
                   cleaned.contains(rule.written) {
                    profile.recordApplication(rule.id)
                }
            }
        }

        // Insertion au curseur (l'app cible a gardé le focus : HUD non-activant).
        await PasteService.insert(cleaned)

        let words = WordDiff.tokens(cleaned).count
        hud.model.phase = .inserted(words: words)
        hud.close(after: 1.2)

        HistoryStore.shared.add(HistoryEntry(
            id: UUID(),
            date: Date(),
            original: cleaned,
            targetLanguage: source == "fr" ? "en" : "fr",
            kind: .dictation,
            sourceApp: session.appName,
            trigger: "dictation",
            rawTranscript: raw,
            duration: duration,
            audioFile: session.recordingFile,
            engine: engineLabel,
            processingTime: processingTime
        ))

        // Boucle d'apprentissage : relire le champ dans ~2 min et comparer.
        if profile.loopEnabled {
            scheduleRetoucheWatch(inserted: cleaned, appName: session.appName)
        }
        endSession()
    }

    private func cancel() async {
        guard isActive, let session else { return }
        await cancelSilently(session: session)
    }

    private func cancelSilently(session: Session) async {
        hudTimer?.invalidate()
        hudTimer = nil
        await engine.cancel()
        deleteRecording(session.recordingFile)
        hud.close()
        endSession()
    }

    private func endSession() {
        session = nil
        isActive = false
    }

    private func deleteRecording(_ file: String?) {
        guard let file,
              let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        try? FileManager.default.removeItem(
            at: support.appendingPathComponent("Butterfly/Recordings/\(file)")
        )
    }

    // MARK: - Boucle d'apprentissage (watcher AX différé)

    /// Capture l'élément AX focalisé maintenant, relit sa valeur après
    /// `delay`, et transforme les retouches en règles proposées.
    private func scheduleRetoucheWatch(inserted: String, appName: String?, delay: TimeInterval = 120) {
        guard let element = Self.focusedElement() else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            var valueRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
                  let value = valueRef as? String, !value.isEmpty else { return }
            Task { @MainActor in
                Self.learnRetouches(inserted: inserted, fieldValue: value, appName: appName)
            }
        }
    }

    private static func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef,
              CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        return (focused as! AXUIElement)
    }

    /// Compare le texte inséré à la valeur actuelle du champ et enregistre
    /// les substitutions plausibles. Statique et pur (testable via --test-learn).
    static func learnRetouches(inserted: String, fieldValue: String, appName: String?) {
        for retouche in extractRetouches(inserted: inserted, fieldValue: fieldValue) {
            LanguageProfileStore.shared.observeRetouche(
                heard: retouche.heard,
                written: retouche.written,
                app: appName
            )
        }
    }

    struct Retouche: Equatable {
        let heard: String
        let written: String
    }

    /// Extraction pure des retouches : fenêtre du champ la plus proche du
    /// texte inséré, diff mot à mot, garde les substitutions 1→1 filtrées
    /// (mots courants, ponctuation seule, texte identique).
    static func extractRetouches(inserted: String, fieldValue: String) -> [Retouche] {
        // Le texte inséré est intact : rien à apprendre.
        guard !fieldValue.contains(inserted) else { return [] }

        let insertedTokens = WordDiff.tokens(inserted)
        let fieldTokens = WordDiff.tokens(fieldValue)
        guard !insertedTokens.isEmpty, !fieldTokens.isEmpty else { return [] }

        // Fenêtre glissante de taille comparable : celle qui partage le plus
        // de tokens avec l'insertion (le champ peut contenir d'autre texte).
        let window: [String]
        if fieldTokens.count <= Int(Double(insertedTokens.count) * 1.6) + 4 {
            window = fieldTokens
        } else {
            let size = min(fieldTokens.count, insertedTokens.count + 6)
            let insertedSet = Set(insertedTokens)
            var best = 0, bestScore = -1
            for start in 0...(fieldTokens.count - size) {
                let score = fieldTokens[start..<(start + size)].reduce(0) { $0 + (insertedSet.contains($1) ? 1 : 0) }
                if score > bestScore {
                    bestScore = score
                    best = start
                }
            }
            window = Array(fieldTokens[best..<(best + size)])
        }

        // La fenêtre doit rester proche de l'insertion, sinon l'utilisateur
        // a réécrit son texte : on n'apprend pas d'un remplacement total.
        let common = Set(insertedTokens).intersection(Set(window)).count
        guard Double(common) >= Double(insertedTokens.count) * 0.5 else { return [] }

        var retouches: [Retouche] = []
        var pendingRemoved: [String] = []
        var pendingAdded: [String] = []
        func flush() {
            // Substitution simple uniquement (1 mot → 1 mot, ou 1 → 2 pour
            // les noms composés) : les gros blocs réécrits ne sont pas du
            // vocabulaire, on les ignore.
            if pendingRemoved.count == 1, (1...2).contains(pendingAdded.count) {
                let heard = clean(pendingRemoved[0])
                let written = pendingAdded.map { clean($0) }.joined(separator: " ")
                if isLearnable(heard: heard, written: written) {
                    retouches.append(Retouche(heard: heard, written: written))
                }
            }
            pendingRemoved = []
            pendingAdded = []
        }
        for segment in WordDiff.diff(original: inserted, corrected: window.joined(separator: " ")) {
            switch segment {
            case .same:
                flush()
            case .removed(let word):
                pendingRemoved.append(word)
            case .added(let word):
                pendingAdded.append(word)
            }
        }
        flush()
        return retouches
    }

    private static func clean(_ token: String) -> String {
        token.trimmingCharacters(in: .punctuationCharacters)
    }

    /// Filtres anti-bruit : identique, trop court, mots courants.
    /// Un simple recasage (energir → Energir) reste apprenable : c'est
    /// exactement le cas des noms propres.
    static func isLearnable(heard: String, written: String) -> Bool {
        guard heard != written, heard.count >= 2, written.count >= 2 else { return false }
        if heard.lowercased() == written.lowercased() { return true }
        return !Self.stopWords.contains(heard.lowercased()) && !Self.stopWords.contains(written.lowercased())
    }

    /// Mots courants fr/en jamais appris comme vocabulaire.
    private static let stopWords: Set<String> = [
        "le", "la", "les", "un", "une", "des", "de", "du", "et", "ou", "mais",
        "je", "tu", "il", "elle", "on", "nous", "vous", "ils", "elles",
        "ce", "cette", "ces", "mon", "ton", "son", "ma", "ta", "sa",
        "que", "qui", "quoi", "dont", "pour", "par", "avec", "sans", "dans",
        "sur", "sous", "est", "sont", "être", "avoir", "fait", "faire",
        "plus", "moins", "très", "bien", "tout", "tous", "toute", "pas",
        "matin", "soir", "midi", "demain", "hier", "aujourd'hui",
        "the", "a", "an", "and", "or", "but", "of", "to", "in", "on", "at",
        "is", "are", "was", "were", "be", "been", "have", "has", "had",
        "i", "you", "he", "she", "it", "we", "they", "this", "that",
        "for", "with", "without", "not", "very", "all", "some", "any",
    ]
}
