import AppKit
import SwiftUI

/// État des prérequis de Butterfly, rafraîchi en direct : moteur IA et
/// permissions système. L'onboarding interroge ces valeurs et guide
/// l'utilisateur étape par étape avec des boutons.
@MainActor
final class OnboardingModel: ObservableObject {
    @Published var appleStatus: TextEngine.AppleStatus = .unknown
    @Published var ollamaInstalled = false
    @Published var screenGranted = false
    @Published var accessibilityGranted = false

    func refresh() {
        appleStatus = TextEngine.shared.appleStatus
        ollamaInstalled = TextEngine.shared.ollamaInstalled()
        screenGranted = ScreenCaptureService.hasPermission
        accessibilityGranted = SelectedTextService.hasPermission
    }

    /// Un moteur IA est exploitable (Apple Intelligence prêt, ou Ollama présent).
    var engineReady: Bool {
        appleStatus == .available || ollamaInstalled
    }
}

/// Écran de bienvenue : trois prérequis (moteur IA, enregistrement d'écran,
/// accessibilité) présentés en liste, chacun avec son état et un bouton qui
/// ouvre le bon volet des Réglages. Les états se rafraîchissent tout seuls
/// quand l'utilisateur revient des Réglages.
struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    var onClose: () -> Void

    @State private var appeared = false
    private let cardWidth: CGFloat = 460

    private let refreshTimer = Timer.publish(every: 1.2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 9) {
                ButterflySectionTitle(text: L10n.t("onboard.section.setup"))
                engineStep
                permissionStep(
                    title: L10n.t("onboard.screen.title"),
                    description: L10n.t("onboard.screen.desc"),
                    granted: model.screenGranted,
                    systemImage: "rectangle.dashed.badge.record",
                    action: { Onboarding.openScreenRecordingSettings() }
                )
                permissionStep(
                    title: L10n.t("onboard.ax.title"),
                    description: L10n.t("onboard.ax.desc"),
                    granted: model.accessibilityGranted,
                    systemImage: "accessibility",
                    action: { Onboarding.openAccessibilitySettings() }
                )
            }
            .padding(.horizontal, ButterflyTokens.panelPadding)
            .padding(.top, 4)
            footer
        }
        .frame(width: cardWidth, alignment: .leading)
        .butterflyPanel()
        .scaleEffect(appeared ? 1 : 0.98, anchor: .center)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            model.refresh()
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { appeared = true }
        }
        .onReceive(refreshTimer) { _ in
            withAnimation(.easeInOut(duration: 0.25)) { model.refresh() }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.88), value: model.appleStatus)
        .animation(.spring(response: 0.4, dampingFraction: 0.88), value: model.screenGranted)
        .animation(.spring(response: 0.4, dampingFraction: 0.88), value: model.accessibilityGranted)
    }

    // MARK: - En-tête

    private var header: some View {
        HStack(spacing: 12) {
            ButterflyShape()
                .fill(.primary)
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.t("onboard.title"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(ButterflyTokens.ink)
                Text(L10n.t("onboard.subtitle"))
                    .font(.system(size: 11))
                    .foregroundStyle(ButterflyTokens.dim)
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 14)
    }

    // MARK: - Étape moteur IA

    @ViewBuilder
    private var engineStep: some View {
        switch model.appleStatus {
        case .available:
            stepRow(
                granted: true,
                systemImage: "apple.intelligence",
                title: L10n.t("onboard.engine.title"),
                description: L10n.t("onboard.engine.ready"),
                button: nil
            )
        case .notEnabled, .unknown:
            stepRow(
                granted: false,
                systemImage: "apple.intelligence",
                title: L10n.t("onboard.engine.title"),
                description: L10n.t("onboard.engine.enable"),
                button: (L10n.t("onboard.engine.enableButton"), { Onboarding.openAppleIntelligenceSettings() })
            )
        case .modelNotReady:
            stepRow(
                granted: false,
                systemImage: "apple.intelligence",
                title: L10n.t("onboard.engine.title"),
                description: L10n.t("onboard.engine.downloading"),
                button: nil,
                showSpinner: true
            )
        case .notEligible:
            // Mac non éligible : on bascule le discours sur Ollama (option avancée).
            stepRow(
                granted: model.ollamaInstalled,
                systemImage: "cpu",
                title: L10n.t("onboard.engine.title"),
                description: model.ollamaInstalled ? L10n.t("onboard.engine.ollamaReady") : L10n.t("onboard.engine.ollama"),
                button: model.ollamaInstalled ? nil : (L10n.t("onboard.engine.ollamaButton"), { Onboarding.openOllamaWebsite() })
            )
        }
    }

    private func permissionStep(title: String, description: String, granted: Bool, systemImage: String, action: @escaping () -> Void) -> some View {
        stepRow(
            granted: granted,
            systemImage: systemImage,
            title: title,
            description: description,
            button: granted ? nil : (L10n.t("onboard.allow"), action)
        )
    }

    // MARK: - Rangée générique

    private func stepRow(
        granted: Bool,
        systemImage: String,
        title: String,
        description: String,
        button: (String, () -> Void)?,
        showSpinner: Bool = false
    ) -> some View {
        HStack(alignment: .center, spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: ButterflyTokens.controlRadius, style: .continuous)
                    .fill(granted ? ButterflyTokens.good : ButterflyTokens.hairline)
                    .frame(width: 28, height: 28)
                if showSpinner {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: granted ? "checkmark" : systemImage)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(granted ? AnyShapeStyle(.white) : AnyShapeStyle(ButterflyTokens.dim))
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(ButterflyTokens.ink)
                Text(description)
                    .font(.system(size: 10.5))
                    .foregroundStyle(ButterflyTokens.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let button {
                Button(button.0, action: button.1)
                    .controlSize(.small)
                    .fixedSize()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .butterflyCard()
    }

    // MARK: - Pied

    private var footer: some View {
        HStack {
            Spacer()
            Button(action: onClose) {
                Text(model.engineReady ? L10n.t("onboard.start") : L10n.t("onboard.later"))
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 18)
    }
}

/// Helpers d'ouverture des Réglages Système (avec repli si l'URL d'un volet
/// précis n'est pas reconnue par la version de macOS).
enum Onboarding {
    static func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openAppleIntelligenceSettings() {
        // Volet « Apple Intelligence & Siri » ; repli sur les Réglages Système.
        if let url = URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension"),
           NSWorkspace.shared.open(url) { return }
        open("x-apple.systempreferences:")
    }

    static func openOllamaWebsite() {
        if let url = URL(string: "https://ollama.com/download") { NSWorkspace.shared.open(url) }
    }

    private static func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Contrôleur de la fenêtre d'onboarding, centrée sur l'écran de la souris.
@MainActor
final class OnboardingPanelController {
    private var panel: ResultPanel?
    private(set) var model = OnboardingModel()

    /// Affiche l'onboarding au 1er lancement si l'utilisateur ne l'a pas déjà vu.
    func showIfFirstLaunch() {
        guard !UserDefaults.standard.bool(forKey: "onboardingDone") else { return }
        show()
    }

    func show() {
        close()
        model = OnboardingModel()
        model.refresh()

        let screen = ScreenCaptureService.screenWithMouse()
        let width: CGFloat = 460

        let panel = ResultPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 360),
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
            rootView: OnboardingView(model: model, onClose: { [weak self] in self?.finish() })
        )
        panel.contentViewController = host
        let fitting = host.view.fittingSize
        panel.setContentSize(NSSize(width: width, height: max(360, fitting.height)))

        let visible = screen.visibleFrame
        panel.setFrameTopLeftPoint(NSPoint(
            x: visible.midX - width / 2,
            y: visible.midY + panel.frame.height / 2
        ))

        self.panel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak panel] in
            panel?.invalidateShadow()
        }
    }

    /// Marque l'onboarding comme vu et ferme.
    private func finish() {
        UserDefaults.standard.set(true, forKey: "onboardingDone")
        close()
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }
}
