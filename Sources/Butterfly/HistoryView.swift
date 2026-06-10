import AppKit
import SwiftUI

/// Panneau historique en Liquid Glass, ancré sous l'icône de la barre de menus.
struct HistoryView: View {
    @ObservedObject var store: HistoryStore
    var onCapture: () -> Void

    @State private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
                .opacity(0.4)
                .padding(.horizontal, 20)
            if store.entries.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(store.entries) { entry in
                            HistoryRow(entry: entry)
                            if entry.id != store.entries.last?.id {
                                Divider()
                                    .opacity(0.25)
                                    .padding(.leading, 20)
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .frame(width: 360, height: 440, alignment: .top)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .scaleEffect(appeared ? 1 : 0.96, anchor: .top)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.84)) { appeared = true }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ButterflyShape()
                .fill(.primary)
                .frame(width: 20, height: 20)
            Text("Butterfly")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
            Spacer()
            Button(action: onCapture) {
                HStack(spacing: 6) {
                    Image(systemName: "plus.magnifyingglass")
                        .font(.system(size: 10, weight: .semibold))
                    Text("⌥⌘B")
                        .font(.system(size: 10, weight: .semibold))
                }
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .help(L10n.t("menu.capture"))
            if !store.entries.isEmpty {
                Button {
                    store.clear()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .help(L10n.t("history.clear"))
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            ButterflyShape()
                .fill(.quaternary)
                .frame(width: 48, height: 48)
            Text(L10n.t("history.empty"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Text(L10n.t("history.emptyHint"))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }
}

/// Une entrée d'historique : texte corrigé, méta, boutons copier.
struct HistoryRow: View {
    let entry: HistoryEntry

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.corrected ?? entry.original)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
                    .textSelection(.enabled)
                HStack(spacing: 6) {
                    Text(
                        Date().timeIntervalSince(entry.date) < 60
                            ? L10n.t("history.now")
                            : Self.relativeFormatter.localizedString(for: entry.date, relativeTo: Date())
                    )
                    if entry.translated != nil {
                        Text("· \(L10n.languageName(entry.targetLanguage))")
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                if let corrected = entry.corrected {
                    CopyButton(text: corrected)
                        .help(L10n.t("history.copyCorrection"))
                }
                if let translated = entry.translated {
                    CopyButton(text: translated, icon: "globe")
                        .help(L10n.t("history.copyTranslation"))
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }
}

/// Contrôleur du panneau historique ancré sous l'icône menu bar.
@MainActor
final class HistoryPanelController {
    private var panel: ResultPanel?
    private var monitors: [Any] = []
    var onCapture: (() -> Void)?

    var isVisible: Bool { panel != nil }

    func toggle(relativeTo button: NSStatusBarButton) {
        if panel != nil {
            close()
        } else {
            show(relativeTo: button)
        }
    }

    func show(relativeTo button: NSStatusBarButton) {
        close()
        guard let buttonWindow = button.window else { return }
        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen ?? NSScreen.main

        let width: CGFloat = 360
        let height: CGFloat = 440

        let panel = ResultPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let host = NSHostingController(
            rootView: HistoryView(store: HistoryStore.shared, onCapture: { [weak self] in
                self?.close()
                self?.onCapture?()
            })
        )
        // L'assignation du contentViewController réinitialise la frame de la
        // fenêtre : il faut imposer la taille PUIS ancrer le coin haut-gauche.
        panel.contentViewController = host
        panel.setContentSize(NSSize(width: width, height: height))

        // Ancré sous l'icône, aligné à droite, borné à l'écran
        var x = buttonFrame.midX - width + 32
        if let visible = screen?.visibleFrame {
            x = max(visible.minX + 8, min(x, visible.maxX - width - 8))
        }
        panel.setFrameTopLeftPoint(NSPoint(x: x, y: buttonFrame.minY - 6))

        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak panel] in
            panel?.invalidateShadow()
        }
        if ProcessInfo.processInfo.environment["BUTTERFLY_DEBUG"] != nil {
            FileHandle.standardError.write(Data("[debug] history panel frame=\(panel.frame) visible=\(panel.isVisible) button=\(buttonFrame)\n".utf8))
        }

        // Clic ailleurs (autre app) ou Échap → fermeture
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            Task { @MainActor in self?.close() }
        }) {
            monitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            if event.keyCode == 53 {
                self?.close()
                return nil
            }
            return event
        }) {
            monitors.append(monitor)
        }
    }

    func close() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        panel?.orderOut(nil)
        panel = nil
    }
}
