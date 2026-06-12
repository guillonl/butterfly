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
    private let historyPanel = HistoryPanelController()
    private let settingsPanel = SettingsPanelController()
    private let wordBubble = WordBubbleController()
    private var capturing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()

        HotKeyManager.shared.handlers[.capture] = { [weak self] in self?.startCapture() }
        HotKeyManager.shared.handlers[.selection] = { [weak self] in self?.startSelectionCorrection() }
        HotKeyManager.shared.start()

        settingsPanel.onShortcutChange = { [weak self] action, shortcut in
            guard HotKeyManager.shared.apply(shortcut, for: action) else { return false }
            ShortcutStore.save(shortcut, for: action)
            self?.updateMenuShortcuts()
            return true
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
        if CommandLine.arguments.contains("--demo") {
            runDemo()
        }
        if CommandLine.arguments.contains("--demo-overlay") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.startCapture()
            }
        }
        if CommandLine.arguments.contains("--demo-history") {
            runHistoryDemo()
        }
        if CommandLine.arguments.contains("--demo-settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.settingsPanel.show()
            }
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
        historyPanel.onCapture = { [weak self] in self?.startCapture() }

        let menu = NSMenu()

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

    @objc private func statusItemClicked() {
        guard let event = NSApp.currentEvent, let button = statusItem.button else { return }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            historyPanel.close()
            statusItem.menu = actionsMenu
            button.performClick(nil)
            statusItem.menu = nil
        } else {
            historyPanel.toggle(relativeTo: button)
        }
    }

    @objc private func menuCapture() {
        startCapture()
    }

    @objc private func menuSelection() {
        startSelectionCorrection()
    }

    @objc private func showSettings() {
        historyPanel.close()
        settingsPanel.show()
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

            await processText(text, model: model)
        }
    }

    /// Pipeline commun aux deux entrées (OCR de zone, texte sélectionné) :
    /// détection de langue, historique, correction streamée puis traduction.
    private func processText(_ text: String, model: ResultModel) async {
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
            targetLanguage: model.targetLanguage
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
                let corrected = try await TextEngine.shared.correct(text, source: detected, using: backend) { partial in
                    DispatchQueue.main.async { model.correction = .value(partial) }
                }
                translationSource = corrected
                model.correction = .value(corrected)
                HistoryStore.shared.updateCorrection(id: entryID, corrected: corrected)
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
            await processText(text, model: model)
        }
    }

    /// Un « mot » pour la bulle : 3 mots max, court, sans retour à la ligne.
    static func isShortExpression(_ text: String) -> Bool {
        guard !text.contains("\n"), text.count <= 40 else { return false }
        return text.split(separator: " ").count <= 3
    }

    private static func detectLanguage(of text: String) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage?.rawValue ?? "fr"
    }

    /// Mot cliqué DANS le panneau résultat → bulle d'alternatives au-dessus
    /// du mot, sans fermer le panneau ; choisir une alternative remplace le
    /// mot directement dans le texte affiché.
    private func showWordBubble(word: String, section: ResultModel.Section, tokenIndex: Int, at mouseGlobal: NSPoint) {
        if ProcessInfo.processInfo.environment["BUTTERFLY_DEBUG"] != nil {
            FileHandle.standardError.write(Data("[bubble] tap word=\(word) at=\(mouseGlobal)\n".utf8))
        }
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseGlobal, $0.frame, false) }) ?? NSScreen.main else { return }
        let anchor = CGRect(
            x: mouseGlobal.x - screen.frame.minX - 40,
            y: screen.frame.maxY - mouseGlobal.y - 12,
            width: 80,
            height: 20
        )
        let bubble = wordBubble.show(
            word: word,
            sourceLanguage: Self.detectLanguage(of: word),
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

    /// `--demo-history` : remplit l'historique de données fictives et ouvre
    /// le panneau sous l'icône menu bar (vérification visuelle sans clic).
    private func runHistoryDemo() {
        let samples: [(String, String, String, String)] = [
            ("Je veut tester l'aplication", "Je veux tester l'application", "I want to test the application", "en"),
            ("This is a sentense with mistaks", "This is a sentence with mistakes", "Ceci est une phrase avec des fautes", "fr"),
            ("On se voit demain matin a la gare", "On se voit demain matin à la gare", "See you tomorrow morning at the station", "en"),
        ]
        for sample in samples {
            HistoryStore.shared.add(HistoryEntry(
                id: UUID(),
                date: Date(),
                original: sample.0,
                corrected: sample.1,
                translated: sample.2,
                targetLanguage: sample.3
            ))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, let button = self.statusItem.button else {
                FileHandle.standardError.write(Data("[debug] demo-history: no status button\n".utf8))
                return
            }
            FileHandle.standardError.write(Data("[debug] demo-history: showing panel\n".utf8))
            self.historyPanel.show(relativeTo: button)
        }
    }

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
