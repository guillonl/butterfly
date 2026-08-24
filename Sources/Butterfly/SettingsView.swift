import AppKit
import SwiftUI

/// Réglages compacts, organisés avec la même hiérarchie de cartes que Jauge.
struct SettingsView: View {
    let onShortcutChange: (HotKeyAction, Shortcut) -> Bool
    let onOpenGuide: () -> Void
    let onClose: () -> Void

    @State private var shortcuts: [HotKeyAction: Shortcut] = [
        .capture: ShortcutStore.shortcut(for: .capture),
        .selection: ShortcutStore.shortcut(for: .selection),
    ]
    @State private var recording: HotKeyAction?
    @State private var errorMessage: String?
    @State private var keyMonitor: Any?
    @State private var appeared = false
    @State private var mode: ProcessingMode = .current
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var systemError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: ButterflyTokens.sectionSpacing) {
                    shortcutsSection
                    actionsSection
                    generalSection
                    permissionsSection
                }
                .padding(ButterflyTokens.panelPadding)
            }
        }
        .frame(width: 460, height: 520)
        .butterflyPanel()
        .scaleEffect(appeared ? 1 : 0.98, anchor: .top)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            launchAtLogin = LoginItem.isEnabled
            withAnimation(.spring(response: 0.3, dampingFraction: 0.88)) { appeared = true }
            installMonitor()
        }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.t("settings.title"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(ButterflyTokens.ink)
                Text(L10n.t("settings.subtitle"))
                    .font(.system(size: 11))
                    .foregroundStyle(ButterflyTokens.dim)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9.5, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(L10n.t("panel.close"))
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 14)
    }

    private var shortcutsSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            ButterflySectionTitle(text: L10n.t("settings.section.shortcuts"))
            VStack(alignment: .leading, spacing: 0) {
                shortcutRow(
                    action: .capture,
                    icon: "plus.magnifyingglass",
                    title: L10n.t("settings.capture"),
                    hint: L10n.t("settings.captureHint")
                )
                Divider().overlay(ButterflyTokens.hairline)
                shortcutRow(
                    action: .selection,
                    icon: "text.cursor",
                    title: L10n.t("settings.selection"),
                    hint: L10n.t("settings.selectionHint")
                )
                Text(L10n.t("settings.note"))
                    .font(.system(size: 10))
                    .foregroundStyle(ButterflyTokens.dim)
                    .padding(.top, 8)
            }
            .padding(11)
            .butterflyCard()

            if let errorMessage {
                problemLabel(errorMessage)
            }
        }
    }

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            ButterflySectionTitle(text: L10n.t("settings.mode"))
            VStack(alignment: .leading, spacing: 10) {
                rowLabel(
                    icon: "wand.and.stars",
                    title: L10n.t("settings.modeTitle"),
                    hint: L10n.t("settings.modeHint")
                )
                Picker("", selection: $mode) {
                    ForEach(ProcessingMode.allCases, id: \.self) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .accessibilityLabel(L10n.t("settings.mode"))
                .onChange(of: mode) { _, newValue in ProcessingMode.save(newValue) }
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .butterflyCard()
        }
    }

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            ButterflySectionTitle(text: L10n.t("settings.section.general"))
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    rowLabel(
                        icon: "power",
                        title: L10n.t("settings.login"),
                        hint: L10n.t("settings.loginHint")
                    )
                    Spacer(minLength: 8)
                    Toggle("", isOn: $launchAtLogin)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .accessibilityLabel(L10n.t("settings.login"))
                        .onChange(of: launchAtLogin) { _, enabled in updateLoginItem(enabled) }
                }
                if let systemError { problemLabel(systemError) }
            }
            .padding(11)
            .butterflyCard()
        }
    }

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            ButterflySectionTitle(text: L10n.t("settings.section.permissions"))
            VStack(alignment: .leading, spacing: 0) {
                permissionRow(
                    title: L10n.t("onboard.screen.title"),
                    granted: ScreenCaptureService.hasPermission,
                    icon: "rectangle.dashed.badge.record"
                )
                Divider().overlay(ButterflyTokens.hairline)
                permissionRow(
                    title: L10n.t("onboard.ax.title"),
                    granted: SelectedTextService.hasPermission,
                    icon: "accessibility"
                )
                Button(L10n.t("settings.permissions"), action: onOpenGuide)
                    .font(.system(size: 11, weight: .medium))
                    .controlSize(.small)
                    .padding(.top, 9)
            }
            .padding(11)
            .butterflyCard()
        }
    }

    private func shortcutRow(action: HotKeyAction, icon: String, title: String, hint: String) -> some View {
        HStack(spacing: 11) {
            rowLabel(icon: icon, title: title, hint: hint)
            Spacer(minLength: 10)
            Button {
                errorMessage = nil
                recording = recording == action ? nil : action
            } label: {
                Text(recording == action ? L10n.t("settings.recording") : (shortcuts[action]?.display ?? "?"))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(recording == action ? ButterflyTokens.dim : ButterflyTokens.ink)
                    .frame(minWidth: 88)
            }
            .controlSize(.small)
            .accessibilityLabel(title)
            .accessibilityHint(hint)
        }
        .padding(.vertical, 7)
    }

    private func rowLabel(icon: String, title: String, hint: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(ButterflyTokens.dim)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(ButterflyTokens.ink)
                Text(hint)
                    .font(.system(size: 10.5))
                    .foregroundStyle(ButterflyTokens.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func permissionRow(title: String, granted: Bool, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(ButterflyTokens.dim)
                .frame(width: 22)
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(ButterflyTokens.ink)
            Spacer()
            Label(
                granted ? L10n.t("settings.allowed") : L10n.t("settings.required"),
                systemImage: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
            )
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(granted ? ButterflyTokens.good : ButterflyTokens.warn)
            .accessibilityValue(granted ? L10n.t("settings.allowed") : L10n.t("settings.required"))
        }
        .padding(.vertical, 8)
    }

    private func problemLabel(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 10.5))
            .foregroundStyle(ButterflyTokens.warn)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func updateLoginItem(_ enabled: Bool) {
        do {
            try LoginItem.setEnabled(enabled)
            systemError = nil
        } catch {
            launchAtLogin = LoginItem.isEnabled
            systemError = L10n.t("settings.loginError")
        }
    }

    private func installMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if let action = recording {
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

@MainActor
final class SettingsPanelController {
    private var panel: ResultPanel?
    var onShortcutChange: ((HotKeyAction, Shortcut) -> Bool)?
    var onOpenGuide: (() -> Void)?

    func show() {
        close()
        let screen = ScreenCaptureService.screenWithMouse()
        let width: CGFloat = 460
        let height: CGFloat = 520

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
                onOpenGuide: { [weak self] in self?.onOpenGuide?() },
                onClose: { [weak self] in self?.close() }
            )
        )
        panel.contentViewController = host
        panel.setContentSize(NSSize(width: width, height: height))

        let visible = screen.visibleFrame
        panel.setFrameTopLeftPoint(NSPoint(
            x: visible.midX - width / 2,
            y: visible.midY + height / 2
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
