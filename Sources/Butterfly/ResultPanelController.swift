import AppKit
import ApplicationServices
import SwiftUI

/// Ce que Butterfly fait d'une capture : corriger, traduire, ou les deux.
enum ProcessingMode: String, CaseIterable {
    case both
    case correctOnly
    case translateOnly

    static var current: ProcessingMode {
        if let raw = UserDefaults.standard.string(forKey: "processingMode"),
           let mode = ProcessingMode(rawValue: raw) {
            return mode
        }
        // Migration depuis l'ancien toggle « Afficher la traduction »
        if UserDefaults.standard.object(forKey: "showTranslation") != nil,
           UserDefaults.standard.bool(forKey: "showTranslation") == false {
            return .correctOnly
        }
        return .both
    }

    static func save(_ mode: ProcessingMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: "processingMode")
    }

    var showsCorrection: Bool { self != .translateOnly }
    var showsTranslation: Bool { self != .correctOnly }

    var label: String {
        switch self {
        case .both: return L10n.t("mode.both")
        case .correctOnly: return L10n.t("mode.correct")
        case .translateOnly: return L10n.t("mode.translate")
        }
    }
}

/// Taille du panneau résultat mémorisée après un redimensionnement manuel.
enum PanelSizeStore {
    private static let key = "resultPanelSize"

    static var saved: NSSize? {
        guard let dict = UserDefaults.standard.dictionary(forKey: key),
              let w = dict["w"] as? Double, let h = dict["h"] as? Double else { return nil }
        return NSSize(width: w, height: h)
    }

    static func save(_ size: NSSize) {
        UserDefaults.standard.set(["w": size.width, "h": size.height], forKey: key)
    }
}

/// Cible de traduction mémorisée PAR langue source : choisir « allemand »
/// pour un texte français est retenu pour tous les prochains textes français,
/// sans toucher au preset des autres langues. Défauts : fr→en, en→fr.
enum LanguagePresets {
    private static let key = "targetPresets"

    static func target(for source: String) -> String {
        let src = String(source.prefix(2))
        let dict = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        if let saved = dict[src] { return saved }
        return src == "en" ? "fr" : "en"
    }

    static func save(source: String, target: String) {
        let src = String(source.prefix(2))
        var dict = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        dict[src] = target
        UserDefaults.standard.set(dict, forKey: key)
    }
}

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
    /// Cible appliquée automatiquement à chaque capture depuis les presets
    /// par langue source ; un changement via le picker met le preset à jour.
    @Published var targetLanguage: String = "en" {
        didSet {
            guard targetLanguage != oldValue else { return }
            if !isApplyingPreset {
                LanguagePresets.save(source: sourceLanguage, target: targetLanguage)
            }
            retranslate()
        }
    }
    private var isApplyingPreset = false

    /// Initialisation des langues sans réécrire le preset.
    func applyLanguages(source: String, target: String) {
        sourceLanguage = source
        isApplyingPreset = true
        targetLanguage = target
        isApplyingPreset = false
    }

    var backend: EngineBackend?
    var translationSource: String?
    var sourceLanguage: String = "fr"
    var historyID: UUID?
    /// Mode d'action (corriger / traduire / les deux), lu à l'ouverture.
    var mode: ProcessingMode = .both
    var translationEnabled: Bool { mode.showsTranslation }
    private var translationTask: Task<Void, Never>?

    func fail(_ message: String) {
        fatalMessage = message
    }

    /// Régénère la correction avec une autre formulation, puis retraduit.
    func regenerateCorrection() {
        guard let backend, let original,
              case .value(let previous) = correction else { return }
        correction = .loading
        Task { [weak self] in
            do {
                let alternative = try await TextEngine.shared.regenerate(
                    original,
                    source: self?.sourceLanguage ?? "fr",
                    previous: previous,
                    using: backend
                ) { partial in
                    DispatchQueue.main.async { [weak self] in
                        self?.correction = .value(partial)
                    }
                }
                guard let self else { return }
                self.correction = .value(alternative)
                if let id = self.historyID {
                    HistoryStore.shared.updateCorrection(id: id, corrected: alternative)
                }
                self.translationSource = alternative
                self.retranslate()
            } catch {
                self?.correction = .failure(L10n.t("panel.error"))
            }
        }
    }

    func retranslate() {
        guard translationEnabled, let backend, let source = translationSource else { return }
        translationTask?.cancel()
        translation = .loading
        let language = targetLanguage
        let sourceLang = sourceLanguage
        translationTask = Task { [weak self] in
            do {
                let translated = try await TextEngine.shared.translate(source, from: sourceLang, to: language, using: backend) { partial in
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
    /// Mot surligné dans le panneau (mot, position souris globale bas-gauche).
    var onWordSelected: ((String, NSPoint) -> Void)?
    /// Échap est ignoré quand ceci renvoie true (ex. bulle ouverte par-dessus).
    var shouldIgnoreEscape: (() -> Bool)?

    private var panel: ResultPanel?
    private var hostRef: NSHostingController<ResultView>?
    private var keyMonitor: Any?
    private var resizeObserver: NSObjectProtocol?
    private var moveObserver: NSObjectProtocol?
    private var liveResizeStartObserver: NSObjectProtocol?
    private var liveResizeEndObserver: NSObjectProtocol?
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
        model.mode = ProcessingMode.current
        self.model = model

        // Taille mémorisée d'un redimensionnement manuel précédent : le
        // panneau démarre alors en mode « fluide » (la fenêtre pilote la vue).
        let savedSize = PanelSizeStore.saved
        let initialSize = savedSize ?? NSSize(width: panelWidth, height: estimatedHeight)

        // Overlay (origine haut-gauche) → coordonnées globales AppKit (bas-gauche)
        let sf = screen.frame
        let globalRect = NSRect(
            x: sf.minX + rectTopLeft.minX,
            y: sf.maxY - rectTopLeft.maxY,
            width: rectTopLeft.width,
            height: rectTopLeft.height
        )

        let visible = screen.visibleFrame
        var x = globalRect.midX - initialSize.width / 2
        x = max(visible.minX + 8, min(x, visible.maxX - initialSize.width - 8))

        // Sous la sélection si possible, sinon au-dessus
        var top = globalRect.minY - 16
        if top - initialSize.height < visible.minY + 8 {
            top = min(globalRect.maxY + 16 + initialSize.height, visible.maxY - 8)
        }
        topLeft = NSPoint(x: x, y: top)

        // .resizable sur une fenêtre borderless : redimensionnement par les
        // bords uniquement (curseur de resize au survol), aucune poignée.
        let panel = ResultPanel(
            contentRect: NSRect(x: x, y: top - initialSize.height, width: initialSize.width, height: initialSize.height),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.minSize = NSSize(width: 380, height: 280)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        // Ombre native de fenêtre : elle épouse exactement le contour arrondi
        // du verre (une ombre SwiftUI dans une fenêtre transparente laisse un
        // halo rectangulaire disgracieux).
        panel.hasShadow = true
        // Déplacement par le header uniquement (WindowDragGesture dans la vue) :
        // un drag sur le fond doit sélectionner le texte, pas bouger la fenêtre.
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let host = NSHostingController(
            rootView: ResultView(
                model: model,
                onClose: { [weak self] in self?.close() },
                maxHeight: visible.height - 32,
                fluid: savedSize != nil,
                onWordTap: { [weak self] word in
                    self?.onWordSelected?(word, NSEvent.mouseLocation)
                }
            )
        )
        // En mode fluide (taille mémorisée), la fenêtre garde sa taille et la
        // vue la remplit ; sinon la vue pilote la taille de la fenêtre.
        host.sizingOptions = savedSize == nil ? [.preferredContentSize] : []
        self.hostRef = host
        panel.contentViewController = host
        if savedSize != nil {
            panel.setContentSize(initialSize)
        }

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
            // Pendant un redimensionnement manuel, ne pas lutter avec l'utilisateur.
            guard !panel.inLiveResize else { return }
            self.programmaticMove = true
            panel.setFrameTopLeftPoint(self.topLeft)
            self.clampIntoScreen(panel)
            self.programmaticMove = false
            // L'ombre native est un snapshot : la rafraîchir à chaque
            // changement de taille (stream, animations) évite les contours
            // fantômes de l'ancienne forme.
            panel.invalidateShadow()
        }
        // Redimensionnement manuel : passer la vue en mode fluide dès le début
        // du geste (sinon le hosting réimpose la taille du contenu), puis
        // mémoriser la taille choisie pour les prochains panneaux.
        liveResizeStartObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willStartLiveResizeNotification, object: panel, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.hostRef?.sizingOptions = []
            self.hostRef?.rootView = ResultView(
                model: model,
                onClose: { [weak self] in self?.close() },
                maxHeight: .infinity,
                fluid: true,
                onWordTap: { [weak self] word in
                    self?.onWordSelected?(word, NSEvent.mouseLocation)
                }
            )
        }
        liveResizeEndObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didEndLiveResizeNotification, object: panel, queue: .main
        ) { [weak self] _ in
            guard let self, let panel = self.panel else { return }
            PanelSizeStore.save(panel.frame.size)
            self.topLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
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
                if self?.shouldIgnoreEscape?() == true { return event }
                self?.close()
                return nil
            }
            return event
        }

        // Surlignage d'un mot dans le panneau : à la fin du geste, lire la
        // sélection via l'accessibilité de notre propre process et remonter
        // le mot (la bulle s'ouvre au-dessus, sans fermer le panneau).
        return model
    }

    /// Garde le panneau entièrement visible : s'il grandit au point de sortir
    /// de l'écran (texte long), il remonte au lieu de déborder.
    private func clampIntoScreen(_ panel: NSPanel) {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        var frame = panel.frame
        if frame.maxY > visible.maxY - 8 { frame.origin.y = visible.maxY - 8 - frame.height }
        if frame.minY < visible.minY + 8 { frame.origin.y = visible.minY + 8 }
        if frame != panel.frame {
            panel.setFrame(frame, display: true)
            topLeft = NSPoint(x: frame.minX, y: frame.maxY)
        }
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
        if let liveResizeStartObserver {
            NotificationCenter.default.removeObserver(liveResizeStartObserver)
            self.liveResizeStartObserver = nil
        }
        if let liveResizeEndObserver {
            NotificationCenter.default.removeObserver(liveResizeEndObserver)
            self.liveResizeEndObserver = nil
        }
        panel?.orderOut(nil)
        panel = nil
        hostRef = nil
        model = nil
    }
}
