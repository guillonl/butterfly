import AppKit
import SwiftUI

/// Fenêtre borderless plein écran qui doit pouvoir devenir key
/// pour recevoir clavier (Échap) et souris.
final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class OverlayController {
    private var window: OverlayWindow?
    private var keyMonitor: Any?

    func present(
        capture: CapturedScreen,
        onSelect: @escaping (CGRect) -> Void,
        onCancel: @escaping () -> Void
    ) {
        dismiss()

        let screen = capture.screen
        let window = OverlayWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .screenSaver
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = false
        window.acceptsMouseMovedEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let rootView = OverlayView(
            capture: capture,
            onSelect: { [weak self] rect in
                self?.dismiss()
                onSelect(rect)
            },
            onCancel: { [weak self] in
                self?.dismiss()
                onCancel()
            }
        )
        window.contentView = NSHostingView(rootView: rootView)
        window.setFrame(screen.frame, display: true)

        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        // Le curseur système disparaît : la loupe devient le curseur,
        // avec un réticule précis en son centre.
        NSCursor.hide()

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Échap
                self?.dismiss()
                onCancel()
                return nil
            }
            return event
        }
    }

    func dismiss() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        guard let window else { return }
        NSCursor.unhide()
        window.orderOut(nil)
        self.window = nil
    }
}
