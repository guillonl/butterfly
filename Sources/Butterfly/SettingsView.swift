import AppKit
import SwiftUI

/// Panneau Réglages en Liquid Glass : personnalisation des deux raccourcis.
struct SettingsView: View {
    /// Tente d'appliquer le nouveau raccourci ; retourne false si refusé.
    let onShortcutChange: (HotKeyAction, Shortcut) -> Bool
    let onClose: () -> Void

    @State private var shortcuts: [HotKeyAction: Shortcut] = [
        .capture: ShortcutStore.shortcut(for: .capture),
        .selection: ShortcutStore.shortcut(for: .selection),
    ]
    @State private var recording: HotKeyAction?
    @State private var errorMessage: String?
    @State private var keyMonitor: Any?
    @State private var appeared = false
    @State private var showTranslation: Bool =
        UserDefaults.standard.object(forKey: "showTranslation") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "showTranslation")

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
                .opacity(0.4)
                .padding(.horizontal, 20)
            VStack(alignment: .leading, spacing: 16) {
                shortcutRow(
                    action: .capture,
                    icon: "plus.magnifyingglass",
                    title: L10n.t("settings.capture"),
                    hint: L10n.t("settings.captureHint")
                )
                shortcutRow(
                    action: .selection,
                    icon: "text.cursor",
                    title: L10n.t("settings.selection"),
                    hint: L10n.t("settings.selectionHint")
                )
                Divider().opacity(0.3)
                HStack(spacing: 12) {
                    Image(systemName: "globe")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.t("settings.showTranslation"))
                            .font(.system(size: 13, weight: .medium))
                        Text(L10n.t("settings.showTranslationHint"))
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 12)
                    Toggle("", isOn: $showTranslation)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                        .onChange(of: showTranslation) { _, newValue in
                            UserDefaults.standard.set(newValue, forKey: "showTranslation")
                        }
                }
                if let errorMessage {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                        Text(errorMessage)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(L10n.t("settings.note"))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 20)
        }
        .frame(width: 400, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .scaleEffect(appeared ? 1 : 0.96, anchor: .top)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.84)) { appeared = true }
            installMonitor()
        }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ButterflyShape()
                .fill(.primary)
                .frame(width: 20, height: 20)
            Text(L10n.t("settings.title"))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private func shortcutRow(action: HotKeyAction, icon: String, title: String, hint: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 12)
            Button {
                errorMessage = nil
                recording = recording == action ? nil : action
            } label: {
                Text(recording == action ? L10n.t("settings.recording") : (shortcuts[action]?.display ?? "?"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(recording == action ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .frame(minWidth: 96)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
        }
    }

    private func installMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if let action = recording {
                // Échap seul : annule l'enregistrement
                if event.keyCode == 53, modifiers.isEmpty {
                    recording = nil
                    errorMessage = nil
                    return nil
                }
                let candidate = Shortcut(keyCode: UInt32(event.keyCode), modifierFlags: modifiers.rawValue)
                guard candidate.isValid else {
                    errorMessage = L10n.t("settings.needModifier")
                    return nil
                }
                let otherAction: HotKeyAction = action == .capture ? .selection : .capture
                if candidate == shortcuts[otherAction] {
                    errorMessage = L10n.t("settings.taken")
                    return nil
                }
                if onShortcutChange(action, candidate) {
                    shortcuts[action] = candidate
                    recording = nil
                    errorMessage = nil
                } else {
                    errorMessage = L10n.t("settings.taken")
                }
                return nil
            }
            if event.keyCode == 53 {
                onClose()
                return nil
            }
            return event
        }
    }
}

/// Contrôleur du panneau Réglages, centré sur l'écran de la souris.
@MainActor
final class SettingsPanelController {
    private var panel: ResultPanel?
    var onShortcutChange: ((HotKeyAction, Shortcut) -> Bool)?

    func show() {
        close()
        let screen = ScreenCaptureService.screenWithMouse()
        let width: CGFloat = 400
        let height: CGFloat = 240

        let panel = ResultPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let host = NSHostingController(
            rootView: SettingsView(
                onShortcutChange: { [weak self] action, shortcut in
                    self?.onShortcutChange?(action, shortcut) ?? false
                },
                onClose: { [weak self] in self?.close() }
            )
        )
        panel.contentViewController = host
        // Taille réelle du contenu SwiftUI (la hauteur varie avec les rangées)
        let fitting = host.view.fittingSize
        panel.setContentSize(NSSize(width: width, height: max(height, fitting.height)))

        let visible = screen.visibleFrame
        panel.setFrameTopLeftPoint(NSPoint(
            x: visible.midX - width / 2,
            y: visible.midY + height / 2 + 80
        ))

        self.panel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak panel] in
            panel?.invalidateShadow()
        }
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }
}
