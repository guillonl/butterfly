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
    /// L'Accessibilité manque : l'AppDelegate affiche l'alerte qui guide
    /// vers les Réglages Système.
    var onAccessibilityMissing: (() -> Void)?
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
        // Pendant une dictée : Échap annule, et TOUTE frappe annule aussi
        // (indispensable quand la touche choisie est un modificateur usuel :
        // ⌘ droite maintenu + C = copie voulue, pas une dictée).
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] _ in
            Task { @MainActor in await self?.cancel() }
        }) {
            monitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard self?.isActive == true else { return event }
            Task { @MainActor in await self?.cancel() }
            return nil
        }) {
            monitors.append(monitor)
        }
    }

    func stopMonitoring() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
    }

    private func debugLog(_ message: String) {
        if ProcessInfo.processInfo.environment["BUTTERFLY_DEBUG"] != nil {
            FileHandle.standardError.write(Data("[dictation] \(message)\n".utf8))
        }
    }

    private func handleFlags(_ event: NSEvent) {
        let key = DictationSettings.shortcut
        guard event.keyCode == key.keyCode else { return }
        debugLog("flagsChanged keyCode=\(event.keyCode) flags=\(event.modifierFlags.rawValue) attendu=\(key.rawValue)")
        if event.modifierFlags.contains(key.flag) {
            Task { await begin() }
        } else {
            Task { await finish() }
        }
    }

    // MARK: - Session

    private func begin() async {
        guard !isActive else { return }
        isActive = true
        debugLog("begin")

        // Capturer l'app cible AVANT d'afficher quoi que ce soit.
        let appName = NSWorkspace.shared.frontmostApplication?.localizedName

        // Locales : réglage Dictée (auto = duel fr + en, langue détectée).
        let locales = DictationSettings.effectiveLocales

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

        debugLog("micro… locales=\(locales.map(\.identifier))")
        do {
            try await engine.startMicrophone(locales: locales, recordingURL: recordingURL)
            debugLog("micro démarré")
        } catch {
            debugLog("micro ÉCHEC: \(error)")
            hud.model.phase = .failed(error.localizedDescription)
            hud.close(after: 1.6)
            endSession()
        }
    }

    private func finish() async {
        guard isActive, let session else { return }
        // Dès ici la session n'est plus annulable : le ⌘V synthétique de
        // l'insertion ne doit pas déclencher le monitor « frappe = annuler ».
        isActive = false
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
        debugLog("raw(\(engine.locale.identifier)): « \(raw) »")
        guard !raw.isEmpty else {
            debugLog("transcription vide")
            deleteRecording(session.recordingFile)
            hud.model.phase = .failed(L10n.t("hud.noText"))
            hud.close(after: 1.4)
            endSession()
            return
        }

        // Nettoyage LLM dans la langue DÉTECTÉE (la gagnante du duel).
        let source = engine.locale.language.languageCode?.identifier ?? "fr"
        let profile = LanguageProfileStore.shared
        var cleaned = raw
        var engineLabel: String?
        var processingTime: TimeInterval?
        if DictationSettings.cleanupEnabled, let backend = await TextEngine.shared.resolveBackend() {
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

        let words = WordDiff.tokens(cleaned).count
        if SelectedTextService.hasPermission {
            debugLog("cleaned: « \(cleaned) » → insertion (AX ok)")
            // Insertion au curseur (l'app cible a gardé le focus : HUD non-activant).
            await PasteService.insert(cleaned)
            hud.model.phase = .inserted(words: words)
            hud.close(after: 1.2)
        } else {
            // Sans Accessibilité, le ⌘V simulé est silencieusement inerte :
            // laisser le texte dans le presse-papiers et guider l'utilisateur.
            debugLog("AX MANQUANTE → texte laissé dans le presse-papiers")
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(cleaned, forType: .string)
            hud.model.phase = .failed(L10n.t("hud.axMissing"))
            hud.close(after: 2.6)
            onAccessibilityMissing?()
        }

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
        isActive = false
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

    /// Capture l'élément AX focalisé maintenant et le relit en plusieurs
    /// passes (+20 s, +45 s, +90 s, +3 min) : une lecture unique ratait les
    /// retouches faites juste après l'insertion (message déjà envoyé) comme
    /// celles faites plus tard. Chaque passe apprend les retouches nouvelles ;
    /// la déduplication évite de compter plusieurs fois la même.
    private func scheduleRetoucheWatch(inserted: String, appName: String?) {
        guard let element = Self.focusedElement() else {
            debugLog("watch: aucun élément focalisé, abandon")
            return
        }
        // Écarts entre les passes (cumul ≈ 20 s, 45 s, 90 s, 180 s).
        let delays: [TimeInterval] = ProcessInfo.processInfo.environment["BUTTERFLY_DEBUG"] != nil
            ? [8, 12, 20]
            : [20, 25, 45, 90]
        watchPass(element: element, inserted: inserted, appName: appName, delays: delays, learned: [])
    }

    private func watchPass(
        element: AXUIElement,
        inserted: String,
        appName: String?,
        delays: [TimeInterval],
        learned: Set<String>
    ) {
        guard let delay = delays.first else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            var valueRef: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef)
            guard status == .success, let value = valueRef as? String, !value.isEmpty else {
                // Champ vidé (message envoyé) ou disparu : rien à apprendre de plus.
                self.debugLog("watch(+\(Int(delay))s): champ illisible ou vide (status \(status.rawValue)) → arrêt")
                return
            }
            var learnedNow = learned
            let retouches = Self.extractRetouches(inserted: inserted, fieldValue: value)
            for retouche in retouches {
                let key = "\(retouche.heard.lowercased())→\(retouche.written)"
                guard !learnedNow.contains(key) else { continue }
                learnedNow.insert(key)
                LanguageProfileStore.shared.observeRetouche(
                    heard: retouche.heard,
                    written: retouche.written,
                    app: appName
                )
                self.debugLog("watch: retouche apprise « \(retouche.heard) » → « \(retouche.written) »")
            }
            self.debugLog("watch(+\(Int(delay))s): \(retouches.count) retouche(s), champ \(value.count) car.")
            self.watchPass(
                element: element,
                inserted: inserted,
                appName: appName,
                delays: Array(delays.dropFirst()),
                learned: learnedNow
            )
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
