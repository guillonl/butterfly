import AppKit
import SwiftUI

/// État affiché par la pilule de dictée.
@MainActor
final class DictationHUDModel: ObservableObject {
    enum Phase: Equatable {
        /// Micro ouvert, transcription en direct.
        case listening
        /// fn relâché : nettoyage LLM en cours.
        case processing
        /// Texte inséré (nombre de mots).
        case inserted(words: Int)
        case failed(String)
    }

    @Published var phase: Phase = .listening
    @Published var level: Double = 0
    @Published var elapsed: TimeInterval = 0
    @Published var languageCode = "fr"
}

/// Pilule HUD au-dessus de tout : papillon, barres de niveau micro,
/// chrono, badge langue. Conforme au concept validé sur le canvas.
struct DictationHUDView: View {
    @ObservedObject var model: DictationHUDModel

    var body: some View {
        HStack(spacing: 12) {
            ButterflyShape()
                .fill(.white)
                .frame(width: 16, height: 16)

            switch model.phase {
            case .listening:
                LevelBars(level: model.level)
                Text(Self.format(model.elapsed))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                Text(model.languageCode.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 1))
            case .processing:
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
                Text(L10n.t("hud.processing"))
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.85))
            case .inserted(let words):
                ZStack {
                    Circle().fill(Theme.ok).frame(width: 18, height: 18)
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                }
                Text(L10n.t("hud.inserted", L10n.plural("main.words", words)))
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.85))
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .frame(minWidth: 180)
        // Verre sombre : le panneau force l'apparence darkAqua, le verre
        // échantillonne l'écran derrière. Clip obligatoire (piège 10).
        .glassEffect(.regular, in: Capsule())
        .clipShape(Capsule())
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: model.phase)
    }

    static func format(_ elapsed: TimeInterval) -> String {
        let seconds = Int(elapsed)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// Barres de niveau micro : 7 barres, hauteur pilotée par le RMS lissé,
/// chaque barre avec un gain propre pour un rendu organique.
private struct LevelBars: View {
    let level: Double
    private static let gains: [Double] = [0.55, 0.8, 1.0, 0.7, 0.9, 0.6, 0.75]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<Self.gains.count, id: \.self) { index in
                Capsule()
                    .fill(Theme.accentSoft)
                    .frame(width: 3, height: 6 + 16 * level * Self.gains[index])
                    .animation(.easeOut(duration: 0.12), value: level)
            }
        }
        .frame(height: 22)
    }
}

/// Panneau flottant de la pilule : non-activant (l'app cible garde le
/// focus, condition de l'insertion au curseur), au-dessus de tout,
/// bas-centre de l'écran où se trouve le curseur.
@MainActor
final class DictationHUDController {
    private var panel: ResultPanel?
    let model = DictationHUDModel()
    private var timer: Timer?

    var isVisible: Bool { panel != nil }

    func show() {
        close()
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main else { return }

        model.phase = .listening
        model.level = 0
        model.elapsed = 0

        let panel = ResultPanel(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 44),
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
        panel.appearance = NSAppearance(named: .darkAqua)

        let host = NSHostingController(rootView: DictationHUDView(model: model))
        host.sizingOptions = [.preferredContentSize]
        panel.contentViewController = host
        // Piège 7 : taille PUIS position après l'assignation du contentViewController.
        panel.setContentSize(host.view.fittingSize)
        position(panel, on: screen)

        self.panel = panel
        panel.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak panel] in
            panel?.invalidateShadow()
        }

        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let panel = self.panel else { return }
                // Suivre la taille du contenu (les phases changent la largeur).
                let fitting = (panel.contentViewController as? NSHostingController<DictationHUDView>)?.view.fittingSize
                if let fitting, abs(fitting.width - panel.frame.width) > 2 {
                    panel.setContentSize(fitting)
                    if let screen = panel.screen { self.position(panel, on: screen) }
                    panel.invalidateShadow()
                }
            }
        }
    }

    private func position(_ panel: NSPanel, on screen: NSScreen) {
        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: visible.midX - panel.frame.width / 2,
            y: visible.minY + 34
        )
        panel.setFrameOrigin(origin)
    }

    /// Ferme après `delay` (laisser lire l'état ✓ / erreur).
    func close(after delay: TimeInterval = 0) {
        guard delay > 0 else {
            timer?.invalidate()
            timer = nil
            panel?.orderOut(nil)
            panel = nil
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.close()
        }
    }
}
