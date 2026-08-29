import AppKit
import NaturalLanguage
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var engineMenu: NSMenu?
    private var actionsMenu: NSMenu?
    private var captureMenuItem: NSMenuItem?
    private var selectionMenuItem: NSMenuItem?
    private let overlay = OverlayController()
    private let resultPanel = ResultPanelController()
    private let mainWindow = MainWindowController()
    private let dictation = DictationController()
    private let wordBubble = WordBubbleController()
    private var capturing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        AppSettings.applyActivationPolicy(windowOpen: false)

        // Dictée système : fn maintenu, partout. Nécessite l'Accessibilité
        // (les monitors globaux sont inertes sans elle, sans erreur).
        dictation.start()
        dictation.onAccessibilityMissing = { [weak self] in self?.showAccessibilityAlert() }
        // Whisper (option Qualité) : chargement CoreML long au premier run →
        // précharger si l'option est active et le modèle déjà sur disque.
        if DictationSettings.asrChoice == "whisper" {
            Task { await WhisperEngine.shared.loadIfNeeded() }
        }

        HotKeyManager.shared.handlers[.capture] = { [weak self] in self?.startCapture() }
        HotKeyManager.shared.handlers[.selection] = { [weak self] in self?.startSelectionCorrection() }
        HotKeyManager.shared.start()

        // Réglages intégrés à la fenêtre principale (refonte 2026-08-28).
        mainWindow.onOpenSettings = { [weak self] in
            guard let model = self?.mainWindow.model else { return }
            if model.section != .settings {
                model.sectionBeforeSettings = model.section
            }
            model.section = .settings
        }
        mainWindow.model.onShortcutChange = { [weak self] action, shortcut in
            guard HotKeyManager.shared.apply(shortcut, for: action) else { return false }
            ShortcutStore.save(shortcut, for: action)
            self?.updateMenuShortcuts()
            return true
        }
        // Mot corrigé cliqué dans la fenêtre principale → bulle de synonymes
        // (mode copie) au-dessus du curseur.
        mainWindow.model.onWordTap = { [weak self] word, language in
            self?.showMainWindowBubble(word: word, language: language)
        }

        // Cliquer un mot dans le panneau résultat → bulle au-dessus du mot ;
        // choisir une alternative remplace le mot dans sa section d'origine.
        resultPanel.onWordSelected = { [weak self] section, tokenIndex, word, mouseGlobal in
            self?.showWordBubble(word: word, section: section, tokenIndex: tokenIndex, at: mouseGlobal)
        }
        // Échap ferme la bulle d'abord, le panneau ensuite.
        resultPanel.shouldIgnoreEscape = { [weak self] in
            self?.wordBubble.isVisible == true
        }

        if CommandLine.arguments.contains("--selftest") {
            runSelfTest()
        }
        if CommandLine.arguments.contains("--test-replace") {
            runReplaceTests()
        }
        if CommandLine.arguments.contains("--test-resize") {
            runResizeTests()
        }
        if CommandLine.arguments.contains("--demo") {
            runDemo()
        }
        if CommandLine.arguments.contains("--demo-overlay") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.startCapture()
            }
        }
        if CommandLine.arguments.contains("--demo-main") {
            runMainWindowDemo()
        }
        if CommandLine.arguments.contains("--test-diff") {
            runDiffTests()
        }
        if CommandLine.arguments.contains("--test-quality") {
            QualityBench.run()
        }
        if let flagIndex = CommandLine.arguments.firstIndex(of: "--test-whisper") {
            let file = CommandLine.arguments.count > flagIndex + 1 ? CommandLine.arguments[flagIndex + 1] : nil
            runWhisperTest(file: file)
        }
        if CommandLine.arguments.contains("--test-langpick") {
            runLangPickTests()
        }
        if CommandLine.arguments.contains("--test-learn") {
            runLearnTests()
        }
        if CommandLine.arguments.contains("--demo-hud") {
            runHUDDemo()
        }
        if let flagIndex = CommandLine.arguments.firstIndex(of: "--test-dictation") {
            let file = CommandLine.arguments.count > flagIndex + 1 ? CommandLine.arguments[flagIndex + 1] : nil
            runDictationTest(file: file)
        }
        if CommandLine.arguments.contains("--demo-bubble") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self, let screen = NSScreen.main else { return }
                let center = CGRect(x: screen.frame.width / 2 - 140, y: screen.frame.height / 2 - 160, width: 280, height: 4)
                let bubble = self.wordBubble.show(word: "améliorer", sourceLanguage: "fr", near: center, on: screen)
                Task { @MainActor in
                    guard let backend = await TextEngine.shared.resolveBackend() else { return }
                    bubble.backend = backend
                    bubble.load()
                }
            }
        }
    }

    // MARK: - Barre de menus

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = ButterflyArt.statusItemImage()
        statusItem.button?.toolTip = "Butterfly"
        // Clic gauche → panneau historique ; clic droit → menu d'actions.
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.target = self
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        let menu = NSMenu()

        let openItem = NSMenuItem(
            title: L10n.t("main.open"),
            action: #selector(openMainWindow),
            keyEquivalent: ""
        )
        openItem.target = self
        menu.addItem(openItem)
        menu.addItem(.separator())

        let captureItem = NSMenuItem(
            title: L10n.t("menu.capture"),
            action: #selector(menuCapture),
            keyEquivalent: ""
        )
        captureItem.target = self
        menu.addItem(captureItem)
        captureMenuItem = captureItem

        let selectionItem = NSMenuItem(
            title: L10n.t("menu.selection"),
            action: #selector(menuSelection),
            keyEquivalent: ""
        )
        selectionItem.target = self
        menu.addItem(selectionItem)
        selectionMenuItem = selectionItem
        menu.addItem(.separator())

        let engineItem = NSMenuItem(title: L10n.t("menu.engine"), action: nil, keyEquivalent: "")
        let engineMenu = NSMenu()
        let prefs: [(EnginePreference, String)] = [
            (.auto, "menu.engine.auto"),
            (.ollama, "menu.engine.ollama"),
            (.apple, "menu.engine.apple"),
        ]
        for (pref, key) in prefs {
            let item = NSMenuItem(title: L10n.t(key), action: #selector(selectEngine(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = pref.rawValue
            item.state = TextEngine.shared.preference == pref ? .on : .off
            engineMenu.addItem(item)
        }
        engineItem.submenu = engineMenu
        menu.addItem(engineItem)
        self.engineMenu = engineMenu
        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: L10n.t("menu.settings"), action: #selector(showSettings), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let aboutItem = NSMenuItem(title: L10n.t("menu.about"), action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        menu.addItem(NSMenuItem(
            title: L10n.t("menu.quit"),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))

        // Pas de menu permanent : il est attaché à la volée au clic droit,
        // sinon il intercepterait aussi le clic gauche.
        actionsMenu = menu
        updateMenuShortcuts()
    }

    /// Affiche les raccourcis courants dans le menu (façon native quand la
    /// touche est un caractère simple, sinon dans le titre).
    private func updateMenuShortcuts() {
        let pairs: [(NSMenuItem?, HotKeyAction, String)] = [
            (captureMenuItem, .capture, "menu.capture"),
            (selectionMenuItem, .selection, "menu.selection"),
        ]
        for (item, action, titleKey) in pairs {
            guard let item else { continue }
            let shortcut = ShortcutStore.shortcut(for: action)
            let keyName = Shortcut.keyName(for: shortcut.keyCode)
            if keyName.count == 1 {
                item.title = L10n.t(titleKey)
                item.keyEquivalent = keyName.lowercased()
                item.keyEquivalentModifierMask = shortcut.modifiers
            } else {
                item.keyEquivalent = ""
                item.title = "\(L10n.t(titleKey))  (\(shortcut.display))"
            }
        }
    }

    /// Bulle de synonymes pour la fenêtre principale : mode copie (le clic
    /// sur une proposition la copie, pas de remplacement en place ici).
    private func showMainWindowBubble(word: String, language: String) {
        let mouseGlobal = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseGlobal, $0.frame, false) }) ?? NSScreen.main else { return }
        let anchor = CGRect(
            x: mouseGlobal.x - screen.frame.minX - 40,
            y: screen.frame.maxY - mouseGlobal.y - 12,
            width: 80,
            height: 20
        )
        let bubble = wordBubble.show(
            word: word,
            sourceLanguage: language,
            near: anchor,
            on: screen,
            anchorMode: .above,
            takeFocus: false
        )
        Task { @MainActor in
            guard let backend = await TextEngine.shared.resolveBackend() else {
                bubble.phase = .failure(L10n.t("panel.engineMissing"))
                return
            }
            bubble.backend = backend
            bubble.load()
        }
    }

    @objc private func statusItemClicked() {
        guard let event = NSApp.currentEvent, let button = statusItem.button else { return }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            statusItem.menu = actionsMenu
            button.performClick(nil)
            statusItem.menu = nil
        } else {
            mainWindow.show()
        }
    }

    @objc private func openMainWindow() {
        mainWindow.show()
    }

    @objc private func menuCapture() {
        startCapture()
    }

    @objc private func menuSelection() {
        startSelectionCorrection()
    }

    @objc private func showSettings() {
        if mainWindow.model.section != .settings {
            mainWindow.model.sectionBeforeSettings = mainWindow.model.section
        }
        mainWindow.model.section = .settings
        mainWindow.show()
    }

    @objc private func selectEngine(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let pref = EnginePreference(rawValue: raw) else { return }
        TextEngine.shared.preference = pref
        engineMenu?.items.forEach { item in
            item.state = (item.representedObject as? String) == raw ? .on : .off
        }
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    // MARK: - Flux principal

    private func startCapture() {
        guard !capturing else { return }
        resultPanel.close()

        guard ScreenCaptureService.hasPermission else {
            ScreenCaptureService.requestPermission()
            showPermissionAlert()
            return
        }

        // Précharge le modèle pendant que l'utilisateur fait sa sélection :
        // au moment de l'OCR, le moteur est déjà chaud.
        Task.detached(priority: .utility) {
            await TextEngine.shared.warmup()
        }

        capturing = true
        Task { @MainActor in
            defer { capturing = false }
            do {
                let capture = try await ScreenCaptureService.captureScreenUnderMouse()
                overlay.present(capture: capture) { [weak self] rect in
                    self?.process(selection: rect, capture: capture)
                } onCancel: {}
            } catch {
                NSSound.beep()
            }
        }
    }

    private func process(selection rect: CGRect, capture: CapturedScreen) {
        let model = resultPanel.show(near: rect, on: capture.screen)

        Task { @MainActor in
            guard let cropped = ScreenCaptureService.crop(capture, to: rect) else {
                model.fail(L10n.t("panel.noText"))
                return
            }

            let text = (try? await OCRService.recognizeText(in: cropped)) ?? ""
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                model.fail(L10n.t("panel.noText"))
                return
            }

            await processText(text, model: model, trigger: "capture")
        }
    }

    /// Pipeline commun aux deux entrées (OCR de zone, texte sélectionné) :
    /// détection de langue, historique, correction streamée puis traduction.
    private func processText(_ text: String, model: ResultModel, trigger: String) async {
        // Cible automatique : preset mémorisé par langue source
        // (défauts : fr → en, en → fr).
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let detected = recognizer.dominantLanguage?.rawValue ?? "fr"
        model.applyLanguages(source: detected, target: LanguagePresets.target(for: detected))
        model.original = text

        let entryID = UUID()
        model.historyID = entryID
        HistoryStore.shared.add(HistoryEntry(
            id: entryID,
            date: Date(),
            original: text,
            corrected: nil,
            translated: nil,
            targetLanguage: model.targetLanguage,
            trigger: trigger
        ))

        guard let backend = await TextEngine.shared.resolveBackend() else {
            model.fail(L10n.t("panel.engineMissing"))
            return
        }
        model.backend = backend
        model.engineLabel = TextEngine.shared.label(for: backend)

        // Selon le mode : correction d'abord (la traduction part de la version
        // corrigée), ou traduction directe de l'original.
        if model.mode.showsCorrection {
            var translationSource = text
            do {
                let started = Date()
                let corrected = try await TextEngine.shared.correct(text, source: detected, using: backend) { partial in
                    DispatchQueue.main.async { model.correction = .value(partial) }
                }
                translationSource = corrected
                model.correction = .value(corrected)
                HistoryStore.shared.updateCorrection(id: entryID, corrected: corrected)
                HistoryStore.shared.updateMetrics(
                    id: entryID,
                    engine: TextEngine.shared.label(for: backend),
                    processingTime: Date().timeIntervalSince(started)
                )
            } catch {
                model.correction = .failure(L10n.t("panel.error"))
            }
            model.translationSource = translationSource
        } else {
            model.translationSource = text
        }
        model.retranslate()
    }

    /// Flux « texte sélectionné » : lit la sélection de l'app frontale
    /// AVANT d'afficher le moindre panneau (pour ne pas perturber le focus),
    /// puis lance le même pipeline que la loupe.
    private func startSelectionCorrection() {
        resultPanel.close()

        guard SelectedTextService.hasPermission else {
            if UserDefaults.standard.bool(forKey: "axPromptShown") {
                showAccessibilityAlert()
            } else {
                UserDefaults.standard.set(true, forKey: "axPromptShown")
                SelectedTextService.requestPermission()
            }
            return
        }

        Task.detached(priority: .utility) {
            await TextEngine.shared.warmup()
        }

        // Position mémorisée tout de suite : le panneau s'ancre là où était
        // la souris au moment du raccourci.
        let screen = ScreenCaptureService.screenWithMouse()
        let mouse = NSEvent.mouseLocation
        let anchor = CGRect(
            x: mouse.x - screen.frame.minX - 220,
            y: screen.frame.maxY - mouse.y,
            width: 440,
            height: 4
        )

        Task { @MainActor in
            let fetched = await SelectedTextService.fetchSelectedText()
            let text = fetched?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            let model = resultPanel.show(near: anchor, on: screen)
            guard !text.isEmpty else {
                model.fail(L10n.t("panel.noSelection"))
                return
            }
            await processText(text, model: model, trigger: "selection")
        }
    }

    /// Un « mot » pour la bulle : 3 mots max, court, sans retour à la ligne.
    static func isShortExpression(_ text: String) -> Bool {
        guard !text.contains("\n"), text.count <= 40 else { return false }
        return text.split(separator: " ").count <= 3
    }

    /// Mot cliqué DANS le panneau résultat → bulle d'alternatives au-dessus
    /// du mot, sans fermer le panneau ; choisir une alternative remplace le
    /// mot directement dans le texte affiché.
    private func showWordBubble(word: String, section: ResultModel.Section, tokenIndex: Int, at mouseGlobal: NSPoint) {
        if ProcessInfo.processInfo.environment["BUTTERFLY_DEBUG"] != nil {
            FileHandle.standardError.write(Data("[bubble] tap word=\(word) at=\(mouseGlobal)\n".utf8))
        }
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseGlobal, $0.frame, false) }) ?? NSScreen.main else { return }
        // La langue du mot est celle de SA section, pas une détection sur le
        // fragment isolé : « ajuste » seul passe pour de l'espagnol alors qu'il
        // vient d'une correction française. La correction est dans la langue
        // source du texte, la traduction dans la langue cible.
        let language: String
        if let model = resultPanel.model {
            language = section == .correction ? model.sourceLanguage : model.targetLanguage
        } else {
            language = "fr"
        }
        let anchor = CGRect(
            x: mouseGlobal.x - screen.frame.minX - 40,
            y: screen.frame.maxY - mouseGlobal.y - 12,
            width: 80,
            height: 20
        )
        let bubble = wordBubble.show(
            word: word,
            sourceLanguage: language,
            near: anchor,
            on: screen,
            anchorMode: .above,
            takeFocus: false,
            onPick: { [weak self] replacement in
                self?.resultPanel.model?.replaceWord(
                    in: section,
                    tokenIndex: tokenIndex,
                    original: word,
                    replacement: replacement
                )
            }
        )
        Task { @MainActor in
            guard let backend = await TextEngine.shared.resolveBackend() else {
                bubble.phase = .failure(L10n.t("panel.engineMissing"))
                return
            }
            bubble.backend = backend
            bubble.load()
        }
    }

    private func showAccessibilityAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L10n.t("alert.ax.title")
        alert.informativeText = L10n.t("alert.ax.message")
        alert.alertStyle = .informational
        alert.addButton(withTitle: L10n.t("alert.ax.open"))
        alert.addButton(withTitle: L10n.t("alert.ax.later"))
        if alert.runModal() == .alertFirstButtonReturn {
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            NSWorkspace.shared.open(url)
        }
    }

    private func showPermissionAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L10n.t("alert.screen.title")
        alert.informativeText = L10n.t("alert.screen.message")
        alert.alertStyle = .informational
        alert.addButton(withTitle: L10n.t("alert.screen.open"))
        alert.addButton(withTitle: L10n.t("alert.screen.later"))
        if alert.runModal() == .alertFirstButtonReturn {
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Modes de test (CLI)

    /// `--selftest` : vérifie le moteur IA de bout en bout depuis le terminal,
    /// dans les deux sens (FR→EN et EN→FR), correction restant dans la langue source.
    /// Fixtures de la fenêtre principale (--demo-main) : données en mémoire
    /// uniquement, l'historique et le profil réels ne sont pas touchés.
    private func runMainWindowDemo() {
        let now = Date()
        let hour: TimeInterval = 3600
        HistoryStore.shared.loadDemoEntries([
            HistoryEntry(
                id: UUID(), date: now.addingTimeInterval(-0.4 * hour),
                original: "Je te partage le fichier des que j'ai terminer la maquette.",
                corrected: "Je te partage le fichier dès que j'ai terminé la maquette.",
                translated: "I'll share the file with you as soon as I've finished the mockup.",
                targetLanguage: "en", trigger: "capture",
                engine: "Apple Intelligence · local", processingTime: 0.9
            ),
            HistoryEntry(
                id: UUID(), date: now.addingTimeInterval(-3.2 * hour),
                original: "Peux-tu relancer le client au sujet du devis avant vendredi ?",
                corrected: "Peux-tu relancer le client au sujet du devis avant vendredi ?",
                translated: nil,
                targetLanguage: "en", trigger: "selection",
                engine: "Apple Intelligence · local", processingTime: 0.7
            ),
            HistoryEntry(
                id: UUID(), date: now.addingTimeInterval(-5 * hour),
                original: "Prépare un résumé des retours client pour la revue de sprint de jeudi matin, et ajoute les captures du nouveau parcours d'onboarding.",
                corrected: "Prépare un résumé des retours client pour la revue de sprint de jeudi matin, et ajoute les captures du nouveau parcours d'onboarding.",
                targetLanguage: "en", kind: .dictation, sourceApp: "Mail",
                trigger: "dictation",
                rawTranscript: "euh prépare un résumé des retours client pour la revue de sprint de jeudi matin et euh ajoute les captures du nouveau parcours onboarding",
                duration: 14
            ),
            HistoryEntry(
                id: UUID(), date: now.addingTimeInterval(-26 * hour),
                original: "Merci pour ta patiance, on revient vers toi très vite.",
                corrected: "Merci pour ta patience, on revient vers toi très vite.",
                translated: nil,
                targetLanguage: "en", trigger: "selection",
                engine: "Qwen3 4B Instruct · local", processingTime: 1.2
            ),
            HistoryEntry(
                id: UUID(), date: now.addingTimeInterval(-28 * hour),
                original: "On se voit jeudi pour la revue de sprint, j'apporte les maquettes.",
                corrected: "On se voit jeudi pour la revue de sprint, j'apporte les maquettes.",
                targetLanguage: "en", kind: .dictation, sourceApp: "Slack",
                trigger: "dictation",
                rawTranscript: "on se voit jeudi pour la revue de sprint euh j'apporte les maquettes",
                duration: 9
            ),
        ])
        LanguageProfileStore.shared.loadDemoFixtures()
        // Variante : `--demo-main dictations|learning` présélectionne une vue.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            self.mainWindow.show()
            if let flagIndex = CommandLine.arguments.firstIndex(of: "--demo-main"),
               CommandLine.arguments.count > flagIndex + 1,
               let section = LibrarySection(rawValue: CommandLine.arguments[flagIndex + 1]) {
                self.mainWindow.model.section = section
            }
        }
    }

    /// Démo visuelle de la pilule de dictée (--demo-hud) : enchaîne les
    /// états sans micro ni moteur.
    private func runHUDDemo() {
        let hud = DictationHUDController()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            hud.show()
            var tick = 0
            Timer.scheduledTimer(withTimeInterval: 0.18, repeats: true) { timer in
                tick += 1
                Task { @MainActor in
                    hud.model.level = 0.25 + 0.65 * abs(sin(Double(tick) * 0.6))
                    hud.model.elapsed = Double(tick) * 0.18
                }
                if tick > 22 { timer.invalidate() }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) {
                hud.model.phase = .processing
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) {
                hud.model.phase = .inserted(words: 22)
                hud.close(after: 2.0)
            }
        }
    }

    /// Test de l'option Qualité (--test-whisper [fichier]) : télécharge le
    /// modèle si besoin, transcrit un fichier (généré via say sinon), chronomètre.
    private func runWhisperTest(file: String?) {
        Task { @MainActor in
            func log(_ message: String) {
                FileHandle.standardError.write(Data((message + "\n").utf8))
            }
            let url: URL
            if let file {
                url = URL(fileURLWithPath: file)
            } else {
                url = FileManager.default.temporaryDirectory.appendingPathComponent("whisper-test.aiff")
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
                process.arguments = ["-v", "Amélie", "-o", url.path,
                                     "Prépare un résumé des retours clients pour la revue de jeudi matin."]
                try? process.run()
                process.waitUntilExit()
            }
            let whisper = WhisperEngine.shared
            if WhisperEngine.downloadedModelFolder == nil {
                log("[whisper] téléchargement du modèle…")
                whisper.downloadAndLoad()
                var lastLogged = -10
                while true {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    switch whisper.state {
                    case .downloading(let progress):
                        let percent = Int(progress * 100)
                        if percent >= lastLogged + 10 {
                            log("[whisper] \(percent) %")
                            lastLogged = percent
                        }
                    case .loading: log("[whisper] chargement CoreML…")
                    case .ready: break
                    case .failed(let message): log("[whisper] ÉCHEC: \(message)"); exit(1)
                    case .notDownloaded: break
                    }
                    if whisper.state == .ready { break }
                }
            } else {
                await whisper.loadIfNeeded()
            }
            guard whisper.isReady else {
                log("[whisper] ÉCHEC: modèle pas prêt (\(String(describing: whisper.state)))")
                exit(1)
            }
            log("[whisper] modèle prêt, transcription…")
            do {
                for forced in [nil, "fr"] as [String?] {
                    let started = Date()
                    let result = try await whisper.transcribe(url: url, language: forced)
                    let elapsed = String(format: "%.2f", Date().timeIntervalSince(started))
                    log("[whisper] lang=\(forced ?? "auto") → \(result.language), \(elapsed)s : « \(result.text) »")
                }
                exit(0)
            } catch {
                log("[whisper] ÉCHEC transcription: \(error)")
                exit(1)
            }
        }
    }

    /// Non-régression du départage de langues (--test-langpick) : le duel
    /// fr/en doit choisir l'hypothèse dont la langue détectée correspond.
    private func runLangPickTests() {
        let fr = Locale(identifier: "fr_FR")
        let en = Locale(identifier: "en_US")
        struct Case {
            let name: String
            let hypotheses: [(locale: Locale, text: String, confidence: Double)]
            let expected: String
        }
        // Confiances typiques observées : le bon modèle > 0,7, le mauvais < 0,5.
        let cases = [
            Case(
                name: "français parlé",
                hypotheses: [
                    (en, "prepare an resume the retour clean poor la revue de sprint", 0.42),
                    (fr, "prépare un résumé des retours client pour la revue de sprint", 0.88),
                ],
                expected: "fr"
            ),
            Case(
                name: "anglais parlé (charabia fr plausible mais confiance basse)",
                hypotheses: [
                    (en, "this is a butterfly dictation test, it works locally", 0.91),
                    (fr, "disait une bateau flaille dictation test et work locale", 0.44),
                ],
                expected: "en"
            ),
            Case(
                name: "français avec anglicismes",
                hypotheses: [
                    (en, "on fat the sprint review demand batin japort les mockups", 0.48),
                    (fr, "on fait la sprint review demain matin j'apporte les mockups du onboarding", 0.83),
                ],
                expected: "fr"
            ),
            Case(
                name: "une seule hypothèse non vide",
                hypotheses: [(en, "", 0), (fr, "bonjour tout le monde", 0.9)],
                expected: "fr"
            ),
            Case(
                name: "sans confiance : cohérence linguistique seule",
                hypotheses: [
                    (en, "prepare an resume the retour clean poor la revue", 0),
                    (fr, "prépare un résumé des retours client pour la revue", 0),
                ],
                expected: "fr"
            ),
        ]
        var failures = 0
        for testCase in cases {
            let best = DictationEngine.pickBest(testCase.hypotheses)
            let got = best?.locale.language.languageCode?.identifier ?? "?"
            let ok = got == testCase.expected
            if !ok { failures += 1 }
            FileHandle.standardError.write(Data("[langpick] \(ok ? "OK " : "ÉCHEC") \(testCase.name) → \(got)\n".utf8))
        }
        FileHandle.standardError.write(Data("[langpick] \(cases.count - failures)/\(cases.count) cas passés\n".utf8))
        exit(failures == 0 ? 0 : 1)
    }

    /// Non-régression de l'extraction de retouches (--test-learn) :
    /// la boucle d'apprentissage ne doit apprendre que des substitutions
    /// plausibles de vocabulaire.
    private func runLearnTests() {
        struct Case {
            let name: String
            let inserted: String
            let field: String
            let expected: [DictationController.Retouche]
        }
        let cases = [
            Case(
                name: "nom propre recasé",
                inserted: "envoie le devis à energir demain",
                field: "envoie le devis à Énergir demain",
                expected: [.init(heard: "energir", written: "Énergir")]
            ),
            Case(
                name: "sigle réécrit",
                inserted: "je présente ça à bécé jeudi",
                field: "je présente ça à BYC jeudi",
                expected: [.init(heard: "bécé", written: "BYC")]
            ),
            Case(
                name: "texte intact",
                inserted: "rien ne change ici",
                field: "préambule. rien ne change ici. suite",
                expected: []
            ),
            Case(
                name: "mot courant ignoré",
                inserted: "je viens demain matin",
                field: "je viens demain soir",
                expected: []
            ),
            Case(
                name: "nom composé 1 vers 2",
                inserted: "regarde sur wisperflow pour comparer",
                field: "regarde sur Wispr Flow pour comparer",
                expected: [.init(heard: "wisperflow", written: "Wispr Flow")]
            ),
            Case(
                name: "réécriture totale ignorée",
                inserted: "on se voit jeudi pour la revue",
                field: "finalement je préfère annuler notre point",
                expected: []
            ),
        ]
        var failures = 0
        for testCase in cases {
            let result = DictationController.extractRetouches(inserted: testCase.inserted, fieldValue: testCase.field)
            let ok = result == testCase.expected
            if !ok { failures += 1 }
            FileHandle.standardError.write(Data("[learn] \(ok ? "OK " : "ÉCHEC") \(testCase.name) → \(result)\n".utf8))
        }
        FileHandle.standardError.write(Data("[learn] \(cases.count - failures)/\(cases.count) cas passés\n".utf8))
        exit(failures == 0 ? 0 : 1)
    }

    /// Test bout en bout du moteur de dictée (--test-dictation [fichier]) :
    /// transcrit un fichier audio (par défaut : généré via `say`) et vérifie
    /// que SpeechTranscriber renvoie du texte.
    private func runDictationTest(file: String?) {
        Task { @MainActor in
            let url: URL
            let expected: String?
            if let file {
                url = URL(fileURLWithPath: file)
                expected = nil
            } else {
                // Générer une phrase de référence avec la synthèse système.
                let phrase = L10n.isFrench
                    ? "Bonjour, ceci est un test de dictée locale."
                    : "Hello, this is a local dictation test."
                expected = phrase
                url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("butterfly-dictation-test.aiff")
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
                process.arguments = ["-o", url.path, phrase]
                try? process.run()
                process.waitUntilExit()
            }
            let locale = Locale(identifier: L10n.isFrench ? "fr_FR" : "en_US")
            let installed = await DictationEngine.isModelInstalled(for: locale)
            FileHandle.standardError.write(Data("[dictation] modèle \(locale.identifier) installé=\(installed)\n".utf8))
            do {
                let started = Date()
                let text = try await DictationEngine.transcribeFile(at: url, locale: locale)
                let elapsed = String(format: "%.2f", Date().timeIntervalSince(started))
                FileHandle.standardError.write(Data("[dictation] transcrit en \(elapsed)s : « \(text) »\n".utf8))
                if text.isEmpty {
                    FileHandle.standardError.write(Data("[dictation] ÉCHEC : transcription vide\n".utf8))
                    exit(1)
                }
                if let expected {
                    let normalize: (String) -> String = { value in
                        value.lowercased()
                            .components(separatedBy: CharacterSet.alphanumerics.inverted)
                            .filter { !$0.isEmpty }
                            .joined(separator: " ")
                    }
                    let match = normalize(text) == normalize(expected)
                    FileHandle.standardError.write(Data("[dictation] attendu : « \(expected) » → correspondance normalisée=\(match)\n".utf8))
                }
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("[dictation] ÉCHEC : \(error)\n".utf8))
                exit(1)
            }
        }
    }

    /// Non-régression du diff mot à mot (--test-diff) : substitutions,
    /// insertions, suppressions, ponctuation, comptage de fautes.
    private func runDiffTests() {
        struct Case {
            let name: String
            let original: String
            let corrected: String
            let expected: [WordDiff.Segment]
            let faults: Int
        }
        let cases = [
            Case(
                name: "substitutions",
                original: "des que j'ai terminer",
                corrected: "dès que j'ai terminé",
                expected: [.removed("des"), .added("dès"), .same("que"), .same("j'ai"), .removed("terminer"), .added("terminé")],
                faults: 2
            ),
            Case(
                name: "identique",
                original: "Rien à corriger ici.",
                corrected: "Rien à corriger ici.",
                expected: [.same("Rien"), .same("à"), .same("corriger"), .same("ici.")],
                faults: 0
            ),
            Case(
                name: "insertion",
                original: "je viens demain",
                corrected: "je viens dès demain",
                expected: [.same("je"), .same("viens"), .added("dès"), .same("demain")],
                faults: 1
            ),
            Case(
                name: "suppression",
                original: "il faut que de partir",
                corrected: "il faut partir",
                expected: [.same("il"), .same("faut"), .removed("que"), .removed("de"), .same("partir")],
                faults: 1
            ),
            Case(
                name: "ponctuation",
                original: "bonjour comment vas tu",
                corrected: "Bonjour, comment vas-tu ?",
                expected: [.removed("bonjour"), .added("Bonjour,"), .same("comment"), .removed("vas"), .removed("tu"), .added("vas-tu"), .added("?")],
                faults: 2
            ),
            Case(
                name: "vide → texte",
                original: "",
                corrected: "un mot",
                expected: [.added("un"), .added("mot")],
                faults: 1
            ),
        ]
        var failures = 0
        for testCase in cases {
            let segments = WordDiff.diff(original: testCase.original, corrected: testCase.corrected)
            let faults = WordDiff.faultCount(original: testCase.original, corrected: testCase.corrected)
            let ok = segments == testCase.expected && faults == testCase.faults
            if !ok { failures += 1 }
            let status = ok ? "OK " : "ÉCHEC"
            FileHandle.standardError.write(Data("[diff] \(status) \(testCase.name) → \(segments) fautes=\(faults)\n".utf8))
        }
        FileHandle.standardError.write(Data("[diff] \(cases.count - failures)/\(cases.count) cas passés\n".utf8))
        exit(failures == 0 ? 0 : 1)
    }

    private func runSelfTest() {
        Task {
            print("[selftest] resolving backend…")
            guard let backend = await TextEngine.shared.resolveBackend() else {
                print("[selftest] NO BACKEND")
                exit(1)
            }
            print("[selftest] backend: \(TextEngine.shared.label(for: backend))")
            let cases: [(text: String, source: String, target: String)] = [
                ("Je veut allé au cinéma se soir avec mes ami.", "fr", "en"),
                ("I has went to the cinema yesterday with my freinds.", "en", "fr"),
                // Anti-régression : texte correct, ne doit PAS être modifié
                // (le modèle retirait le trait d'union de « Entre-temps »).
                ("Nous traitons votre demande. Entre-temps, vous pouvez modifier vos comptes.", "fr", "en"),
            ]
            do {
                for testCase in cases {
                    let corrected = try await TextEngine.shared.correct(
                        testCase.text, source: testCase.source, using: backend)
                    print("[selftest] corrected(\(testCase.source)): \(corrected)")
                    let translated = try await TextEngine.shared.translate(
                        corrected, from: testCase.source, to: testCase.target, using: backend)
                    print("[selftest] translated(\(testCase.target)): \(translated)")
                }
                print("[selftest] OK")
                exit(0)
            } catch {
                print("[selftest] ERROR: \(error)")
                exit(1)
            }
        }
    }

    /// `--test-replace` : vérifie la logique de remplacement de mot
    /// (tokenisation, ponctuation accolée, casse) sans interface ni moteur.
    private func runReplaceTests() {
        struct Case {
            let text: String
            let section: ResultModel.Section
            let tokenIndex: Int
            let original: String
            let replacement: String
            let expected: String
        }
        let cases: [Case] = [
            // Remplacement simple au milieu d'une phrase
            Case(text: "Je veux tester l'application.", section: .correction,
                 tokenIndex: 2, original: "tester", replacement: "essayer",
                 expected: "Je veux essayer l'application."),
            // Ponctuation accolée conservée
            Case(text: "voir le résultat, vite", section: .correction,
                 tokenIndex: 2, original: "résultat", replacement: "rendu",
                 expected: "voir le rendu, vite"),
            // Majuscule initiale conservée
            Case(text: "Tester le code", section: .correction,
                 tokenIndex: 0, original: "Tester", replacement: "essayer",
                 expected: "Essayer le code"),
            // Retours à la ligne préservés
            Case(text: "un\ndeux trois", section: .translation,
                 tokenIndex: 1, original: "deux", replacement: "2",
                 expected: "un\n2 trois"),
            // Mot désynchronisé (le texte a changé) : aucun remplacement
            Case(text: "Je veux tester l'application.", section: .correction,
                 tokenIndex: 2, original: "corriger", replacement: "essayer",
                 expected: "Je veux tester l'application."),
        ]
        var failures = 0
        for (index, testCase) in cases.enumerated() {
            let model = ResultModel()
            if testCase.section == .correction {
                model.correction = .value(testCase.text)
            } else {
                model.translation = .value(testCase.text)
            }
            model.replaceWord(
                in: testCase.section,
                tokenIndex: testCase.tokenIndex,
                original: testCase.original,
                replacement: testCase.replacement
            )
            let state = testCase.section == .correction ? model.correction : model.translation
            guard case .value(let result) = state else {
                print("[test-replace] #\(index) état inattendu")
                failures += 1
                continue
            }
            if result == testCase.expected {
                print("[test-replace] #\(index) OK: \(result)")
            } else {
                print("[test-replace] #\(index) FAIL: attendu « \(testCase.expected) », obtenu « \(result) »")
                failures += 1
            }
        }
        print(failures == 0 ? "[test-replace] OK" : "[test-replace] \(failures) ÉCHEC(S)")
        exit(failures == 0 ? 0 : 1)
    }

    /// `--test-resize` : vérifie le SENS du redimensionnement par les bords
    /// (coordonnées AppKit, y vers le haut). « Diminuer » doit diminuer.
    private func runResizeTests() {
        let start = NSRect(x: 100, y: 100, width: 440, height: 390)
        let minSize = NSSize(width: 380, height: 280)
        typealias E = PanelResizeView.Edges
        struct Case {
            let name: String
            let edges: E
            let dx: CGFloat
            let dy: CGFloat
            let expected: NSRect
        }
        let cases: [Case] = [
            // Bord droit : tirer vers la droite agrandit, vers la gauche diminue.
            Case(name: "droit +", edges: .right, dx: 50, dy: 0,
                 expected: NSRect(x: 100, y: 100, width: 490, height: 390)),
            Case(name: "droit - (diminuer)", edges: .right, dx: -50, dy: 0,
                 expected: NSRect(x: 100, y: 100, width: 390, height: 390)),
            // Bord gauche : tirer vers la gauche agrandit, l'origine recule.
            Case(name: "gauche -", edges: .left, dx: -50, dy: 0,
                 expected: NSRect(x: 50, y: 100, width: 490, height: 390)),
            // Bord bas (souris vers le bas = dy négatif) : agrandit, origine descend, haut fixe.
            Case(name: "bas (vers le bas)", edges: .bottom, dx: 0, dy: -50,
                 expected: NSRect(x: 100, y: 50, width: 440, height: 440)),
            // Bord haut (souris vers le haut = dy positif) : agrandit, origine fixe.
            Case(name: "haut (vers le haut)", edges: .top, dx: 0, dy: 50,
                 expected: NSRect(x: 100, y: 100, width: 440, height: 440)),
            // minSize respectée même en tirant fort vers l'intérieur.
            Case(name: "clamp minSize", edges: .right, dx: -1000, dy: 0,
                 expected: NSRect(x: 100, y: 100, width: 380, height: 390)),
            // Coin bas-droit : largeur et hauteur ensemble.
            Case(name: "coin bas-droit", edges: [.right, .bottom], dx: 30, dy: -40,
                 expected: NSRect(x: 100, y: 60, width: 470, height: 430)),
        ]
        var failures = 0
        for testCase in cases {
            let result = PanelResizeView.resizedFrame(
                startFrame: start, edges: testCase.edges,
                dx: testCase.dx, dy: testCase.dy, minSize: minSize
            )
            if result == testCase.expected {
                print("[test-resize] \(testCase.name) OK")
            } else {
                print("[test-resize] \(testCase.name) FAIL: attendu \(testCase.expected), obtenu \(result)")
                failures += 1
            }
        }

        // Détection des bords/coins à partir d'un point (zone de coin = resize
        // diagonal). size 440×390, band 6, cornerReach 18.
        let size = NSSize(width: 440, height: 390)
        let band: CGFloat = 6, reach: CGFloat = 18
        struct HitCase { let name: String; let point: NSPoint; let expected: E }
        let hits: [HitCase] = [
            HitCase(name: "centre → rien", point: NSPoint(x: 220, y: 195), expected: []),
            HitCase(name: "bord droit milieu → droit", point: NSPoint(x: 438, y: 195), expected: .right),
            HitCase(name: "bord bas milieu → bas", point: NSPoint(x: 220, y: 3), expected: .bottom),
            HitCase(name: "coin bas-droit (fin) → droit+bas", point: NSPoint(x: 438, y: 3), expected: [.right, .bottom]),
            HitCase(name: "coin bas-droit (épais) → droit+bas", point: NSPoint(x: 426, y: 12), expected: [.right, .bottom]),
            HitCase(name: "coin haut-gauche → gauche+haut", point: NSPoint(x: 5, y: 385), expected: [.left, .top]),
            HitCase(name: "ex-trou (10px du droit, 12 du bas)", point: NSPoint(x: 430, y: 12), expected: [.right, .bottom]),
        ]
        for hit in hits {
            let result = PanelResizeView.edges(at: hit.point, size: size, band: band, cornerReach: reach)
            if result == hit.expected {
                print("[test-resize] \(hit.name) OK")
            } else {
                print("[test-resize] \(hit.name) FAIL: attendu \(hit.expected.rawValue), obtenu \(result.rawValue)")
                failures += 1
            }
        }
        print(failures == 0 ? "[test-resize] OK" : "[test-resize] \(failures) ÉCHEC(S)")
        exit(failures == 0 ? 0 : 1)
    }

    /// `--demo-history` : remplit l'historique de données fictives et ouvre

    /// `--demo` : affiche le panneau résultat avec des données fictives
    /// (permet de vérifier l'UI sans permission d'enregistrement d'écran).
    private func runDemo() {
        guard let screen = NSScreen.main else { return }
        let center = CGRect(
            x: screen.frame.width / 2 - 220,
            y: screen.frame.height / 2 - 200,
            width: 440,
            height: 60
        )
        let model = resultPanel.show(near: center, on: screen)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            model.original = "Je veut tester l'aplication avec quelque fautes pour voir le résulta. Ce texte de démonstration est volontairement assé long pour vérifier que le bouton Voir plus s'affiche correctement quand le texte détecté dépasse trois lignes dans le panneau de résultat de Butterfly."
            model.engineLabel = "Qwen3 4B · local"
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            model.correction = .value("Je veux tester l'application avec quelques fautes pour voir le résultat.")
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            model.translation = .value("I want to test the application with a few mistakes to see the result.")
        }
    }
}
