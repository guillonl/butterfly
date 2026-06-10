import AppKit
import SwiftUI

/// État observable du panneau résultat. Chaque section avance indépendamment.
@MainActor
final class ResultModel: ObservableObject {
    enum SectionState: Equatable {
        case loading
        case value(String)
        case failure(String)
    }

    @Published var original: String?
    @Published var correction: SectionState = .loading
    @Published var translation: SectionState = .loading
    @Published var fatalMessage: String?
    @Published var engineLabel: String = ""
    /// Cible choisie automatiquement à chaque capture (texte anglais → français,
    /// sinon → anglais) ; le picker du panneau permet de changer ponctuellement.
    @Published var targetLanguage: String = "en" {
        didSet {
            guard targetLanguage != oldValue else { return }
            retranslate()
        }
    }

    var backend: EngineBackend?
    var translationSource: String?
    var historyID: UUID?
    private var translationTask: Task<Void, Never>?

    func fail(_ message: String) {
        fatalMessage = message
    }

    func retranslate() {
        guard let backend, let source = translationSource else { return }
        translationTask?.cancel()
        translation = .loading
        let language = targetLanguage
        translationTask = Task { [weak self] in
            do {
                let translated = try await TextEngine.shared.translate(source, to: language, using: backend) { partial in
                    DispatchQueue.main.async { [weak self] in
                        guard !(Task.isCancelled) else { return }
                        self?.translation = .value(partial)
                    }
                }
                guard !Task.isCancelled else { return }
                self?.translation = .value(translated)
                if let id = self?.historyID {
                    HistoryStore.shared.updateTranslation(id: id, translated: translated, language: language)
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.translation = .failure(L10n.t("panel.error"))
            }
        }
    }
}

/// Panneau borderless qui peut devenir key (boutons + Échap).
final class ResultPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class ResultPanelController {
    private var panel: ResultPanel?
    private var keyMonitor: Any?
    private var resizeObserver: NSObjectProtocol?
    private var moveObserver: NSObjectProtocol?
    private var topLeft: NSPoint = .zero
    private var programmaticMove = false
    private(set) var model: ResultModel?

    private let panelWidth: CGFloat = 440
    private let estimatedHeight: CGFloat = 320

    /// Affiche le panneau près de la sélection (coordonnées overlay,
    /// origine haut-gauche de l'écran) et retourne son modèle.
    @discardableResult
    func show(near rectTopLeft: CGRect, on screen: NSScreen) -> ResultModel {
        close()

        let model = ResultModel()
        self.model = model

        // Overlay (origine haut-gauche) → coordonnées globales AppKit (bas-gauche)
        let sf = screen.frame
        let globalRect = NSRect(
            x: sf.minX + rectTopLeft.minX,
            y: sf.maxY - rectTopLeft.maxY,
            width: rectTopLeft.width,
            height: rectTopLeft.height
        )

        let visible = screen.visibleFrame
        var x = globalRect.midX - panelWidth / 2
        x = max(visible.minX + 8, min(x, visible.maxX - panelWidth - 8))

        // Sous la sélection si possible, sinon au-dessus
        var top = globalRect.minY - 16
        if top - estimatedHeight < visible.minY + 8 {
            top = min(globalRect.maxY + 16 + estimatedHeight, visible.maxY - 8)
        }
        topLeft = NSPoint(x: x, y: top)

        let panel = ResultPanel(
            contentRect: NSRect(x: x, y: top - estimatedHeight, width: panelWidth, height: estimatedHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        // Ombre native de fenêtre : elle épouse exactement le contour arrondi
        // du verre (une ombre SwiftUI dans une fenêtre transparente laisse un
        // halo rectangulaire disgracieux).
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let host = NSHostingController(
            rootView: ResultView(model: model, onClose: { [weak self] in self?.close() })
        )
        host.sizingOptions = [.preferredContentSize]
        panel.contentViewController = host

        self.panel = panel
        programmaticMove = true
        panel.setFrameTopLeftPoint(topLeft)
        programmaticMove = false
        panel.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak panel] in
            panel?.invalidateShadow()
        }

        // Le contenu SwiftUI change de taille au fil des résultats :
        // on garde le coin haut-gauche ancré.
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: panel, queue: .main
        ) { [weak self] _ in
            guard let self, let panel = self.panel else { return }
            self.programmaticMove = true
            panel.setFrameTopLeftPoint(self.topLeft)
            self.programmaticMove = false
            // L'ombre native est un snapshot : la rafraîchir à chaque
            // changement de taille (stream, animations) évite les contours
            // fantômes de l'ancienne forme.
            panel.invalidateShadow()
        }
        // Si Léo déplace le panneau à la main, on ré-ancre sur sa position.
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak self] _ in
            guard let self, !self.programmaticMove, let panel = self.panel else { return }
            self.topLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Échap
                self?.close()
                return nil
            }
            return event
        }

        return model
    }

    func close() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if let resizeObserver {
            NotificationCenter.default.removeObserver(resizeObserver)
            self.resizeObserver = nil
        }
        if let moveObserver {
            NotificationCenter.default.removeObserver(moveObserver)
            self.moveObserver = nil
        }
        panel?.orderOut(nil)
        panel = nil
        model = nil
    }
}
