import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var engineMenu: NSMenu?
    private let overlay = OverlayController()
    private let resultPanel = ResultPanelController()
    private var capturing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()

        HotKeyManager.shared.onHotKey = { [weak self] in
            self?.startCapture()
        }
        HotKeyManager.shared.register()

        if CommandLine.arguments.contains("--selftest") {
            runSelfTest()
        }
        if CommandLine.arguments.contains("--demo") {
            runDemo()
        }
        if CommandLine.arguments.contains("--demo-overlay") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.startCapture()
            }
        }
    }

    // MARK: - Barre de menus

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = ButterflyArt.statusItemImage()
        statusItem.button?.toolTip = "Butterfly"

        let menu = NSMenu()

        let captureItem = NSMenuItem(
            title: L10n.t("menu.capture"),
            action: #selector(menuCapture),
            keyEquivalent: "b"
        )
        captureItem.keyEquivalentModifierMask = [.command, .option]
        captureItem.target = self
        menu.addItem(captureItem)
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

        let aboutItem = NSMenuItem(title: L10n.t("menu.about"), action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        menu.addItem(NSMenuItem(
            title: L10n.t("menu.quit"),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))

        statusItem.menu = menu
    }

    @objc private func menuCapture() {
        startCapture()
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
            model.original = text

            guard let backend = await TextEngine.shared.resolveBackend() else {
                model.fail(L10n.t("panel.engineMissing"))
                return
            }
            model.backend = backend
            model.engineLabel = TextEngine.shared.label(for: backend)

            // Correction d'abord (streamée) ; la traduction part de la version corrigée.
            var translationSource = text
            do {
                let corrected = try await TextEngine.shared.correct(text, using: backend) { partial in
                    DispatchQueue.main.async { model.correction = .value(partial) }
                }
                translationSource = corrected
                model.correction = .value(corrected)
            } catch {
                model.correction = .failure(L10n.t("panel.error"))
            }

            model.translationSource = translationSource
            model.retranslate()
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

    /// `--selftest` : vérifie le moteur IA de bout en bout depuis le terminal.
    private func runSelfTest() {
        Task {
            let sample = "Je veut allé au cinéma se soir avec mes ami."
            print("[selftest] resolving backend…")
            guard let backend = await TextEngine.shared.resolveBackend() else {
                print("[selftest] NO BACKEND")
                exit(1)
            }
            print("[selftest] backend: \(backend.label)")
            do {
                let corrected = try await TextEngine.shared.correct(sample, using: backend)
                print("[selftest] corrected: \(corrected)")
                let translated = try await TextEngine.shared.translate(corrected, to: "en", using: backend)
                print("[selftest] translated: \(translated)")
                print("[selftest] OK")
                exit(0)
            } catch {
                print("[selftest] ERROR: \(error)")
                exit(1)
            }
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
            model.original = "Je veut tester l'aplication avec quelque fautes pour voir le résulta."
            model.engineLabel = "Qwen3 4B · local"
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            model.correction = .value("Je veux tester l'application avec quelques fautes pour voir le résultat.")
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            model.translation = .value("I want to test the application with a few mistakes to see the result.")
        }
    }
}
