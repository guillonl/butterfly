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

    /// Section de texte cliquable du panneau (provenance d'un mot surligné).
    enum Section {
        case correction
        case translation
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

    /// Remplace le N-ième mot du texte affiché par l'alternative choisie dans
    /// la bulle, en conservant la ponctuation accolée et la majuscule initiale.
    /// Un remplacement dans la correction retraduit (même chaîne que regenerate).
    func replaceWord(in section: Section, tokenIndex: Int, original: String, replacement: String) {
        let state = section == .correction ? correction : translation
        guard case .value(let text) = state else { return }

        // Mêmes séparateurs que TappableText : l'index de token doit retrouver
        // exactement le mot cliqué.
        var ranges: [Range<String.Index>] = []
        var tokenStart: String.Index?
        for index in text.indices {
            if text[index] == " " || text[index] == "\n" {
                if let start = tokenStart {
                    ranges.append(start..<index)
                    tokenStart = nil
                }
            } else if tokenStart == nil {
                tokenStart = index
            }
        }
        if let start = tokenStart { ranges.append(start..<text.endIndex) }

        guard tokenIndex < ranges.count else { return }
        let token = String(text[ranges[tokenIndex]])
        // Le texte a pu changer entre le clic et le choix (stream, retraduction).
        guard token.trimmingCharacters(in: .punctuationCharacters) == original else { return }

        let punctuation = CharacterSet.punctuationCharacters
        let lead = String(token.prefix { $0.unicodeScalars.allSatisfy(punctuation.contains) })
        let trail = String(token.reversed().prefix { $0.unicodeScalars.allSatisfy(punctuation.contains) }.reversed())

        var adjusted = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = original.first, first.isUppercase,
           let replacementFirst = adjusted.first, replacementFirst.isLowercase {
            adjusted = adjusted.prefix(1).uppercased() + adjusted.dropFirst()
        }
        let newText = text.replacingCharacters(in: ranges[tokenIndex], with: lead + adjusted + trail)

        switch section {
        case .correction:
            correction = .value(newText)
            if let id = historyID {
                HistoryStore.shared.updateCorrection(id: id, corrected: newText)
            }
            translationSource = newText
            retranslate()
        case .translation:
            translation = .value(newText)
            if let id = historyID {
                HistoryStore.shared.updateTranslation(id: id, translated: newText, language: targetLanguage)
            }
        }
    }
}

/// Panneau borderless qui peut devenir key (boutons + Échap).
final class ResultPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Redimensionnement par les bords pour le panneau borderless.
/// AppKit ne fournit le resize de bord qu'aux fenêtres titrées ; sur une
/// borderless il passe par le drag de fond, désactivé ici par
/// `isMovableByWindowBackground = false` (le drag doit sélectionner le texte).
/// Cette vue invisible ne capte que le pourtour : curseurs de bord natifs,
/// drag = resize manuel avec ancrage du côté opposé et minSize respectée.
final class PanelResizeView: NSView {
    var onResizeStart: (() -> Void)?
    var onResizeEnd: (() -> Void)?

    private let band: CGFloat = 6
    private let cornerReach: CGFloat = 14

    private struct Edges: OptionSet {
        let rawValue: Int
        static let left = Edges(rawValue: 1 << 0)
        static let right = Edges(rawValue: 1 << 1)
        static let top = Edges(rawValue: 1 << 2)
        static let bottom = Edges(rawValue: 1 << 3)
    }

    /// Seule la bande de bord est interactive : tout le reste passe au contenu.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        return edges(at: local).isEmpty ? nil : self
    }

    private func edges(at point: NSPoint) -> Edges {
        var edges: Edges = []
        if point.x <= band { edges.insert(.left) }
        if point.x >= bounds.width - band { edges.insert(.right) }
        if point.y <= band { edges.insert(.bottom) }
        if point.y >= bounds.height - band { edges.insert(.top) }
        // Coins plus faciles à attraper que l'intersection stricte des bandes.
        if !edges.isEmpty {
            if !edges.isDisjoint(with: [.left, .right]) {
                if point.y <= cornerReach { edges.insert(.bottom) }
                if point.y >= bounds.height - cornerReach { edges.insert(.top) }
            }
            if !edges.isDisjoint(with: [.top, .bottom]) {
                if point.x <= cornerReach { edges.insert(.left) }
                if point.x >= bounds.width - cornerReach { edges.insert(.right) }
            }
        }
        return edges
    }

    override func resetCursorRects() {
        let w = bounds.width, h = bounds.height
        let positions: [(NSRect, NSCursor.FrameResizePosition)] = [
            (NSRect(x: 0, y: band, width: band, height: h - 2 * band), .left),
            (NSRect(x: w - band, y: band, width: band, height: h - 2 * band), .right),
            (NSRect(x: band, y: h - band, width: w - 2 * band, height: band), .top),
            (NSRect(x: band, y: 0, width: w - 2 * band, height: band), .bottom),
            (NSRect(x: 0, y: 0, width: band, height: band), .bottomLeft),
            (NSRect(x: w - band, y: 0, width: band, height: band), .bottomRight),
            (NSRect(x: 0, y: h - band, width: band, height: band), .topLeft),
            (NSRect(x: w - band, y: h - band, width: band, height: band), .topRight),
        ]
        for (rect, position) in positions {
            addCursorRect(rect, cursor: .frameResize(position: position, directions: .all))
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let start = convert(event.locationInWindow, from: nil)
        let edges = edges(at: start)
        guard !edges.isEmpty else { return }

        let startFrame = window.frame
        let startMouse = NSEvent.mouseLocation
        let minSize = window.minSize
        onResizeStart?()
        defer { onResizeEnd?() }

        // Boucle de tracking classique : le drag pilote la frame en direct.
        while true {
            guard let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else { break }
            if next.type == .leftMouseUp { break }
            let mouse = NSEvent.mouseLocation
            let dx = mouse.x - startMouse.x
            let dy = mouse.y - startMouse.y
            var frame = startFrame
            if edges.contains(.right) {
                frame.size.width = max(minSize.width, startFrame.width + dx)
            }
            if edges.contains(.left) {
                let width = max(minSize.width, startFrame.width - dx)
                frame.origin.x = startFrame.maxX - width
                frame.size.width = width
            }
            if edges.contains(.top) {
                frame.size.height = max(minSize.height, startFrame.height + dy)
            }
            if edges.contains(.bottom) {
                let height = max(minSize.height, startFrame.height - dy)
                frame.origin.y = startFrame.maxY - height
                frame.size.height = height
            }
            window.setFrame(frame, display: true)
        }
    }
}

@MainActor
final class ResultPanelController {
    /// Mot cliqué dans le panneau : section d'origine, index du token, mot
    /// nettoyé, position souris globale (bas-gauche) pour ancrer la bulle.
    var onWordSelected: ((ResultModel.Section, Int, String, NSPoint) -> Void)?
    /// Échap est ignoré quand ceci renvoie true (ex. bulle ouverte par-dessus).
    var shouldIgnoreEscape: (() -> Bool)?

    private var panel: ResultPanel?
    private var hostRef: NSHostingController<ResultView>?
    private var keyMonitor: Any?
    private var resizeObserver: NSObjectProtocol?
    private var moveObserver: NSObjectProtocol?
    private var topLeft: NSPoint = .zero
    private var programmaticMove = false
    private var userResizing = false
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
            rootView: makeResultView(model: model, maxHeight: visible.height - 32, fluid: savedSize != nil)
        )
        // En mode fluide (taille mémorisée), la fenêtre garde sa taille et la
        // vue la remplit ; sinon la vue pilote la taille de la fenêtre.
        host.sizingOptions = savedSize == nil ? [.preferredContentSize] : []
        self.hostRef = host
        panel.contentViewController = host
        if savedSize != nil {
            panel.setContentSize(initialSize)
        }

        // Bande de redimensionnement par-dessus le contenu (bords uniquement,
        // le hitTest laisse passer tout le reste vers les vues SwiftUI).
        if let content = panel.contentView {
            let resizer = PanelResizeView(frame: content.bounds)
            resizer.autoresizingMask = [.width, .height]
            resizer.onResizeStart = { [weak self] in self?.beginUserResize() }
            resizer.onResizeEnd = { [weak self] in self?.endUserResize() }
            content.addSubview(resizer)
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
            guard !self.userResizing else { return }
            self.programmaticMove = true
            panel.setFrameTopLeftPoint(self.topLeft)
            self.clampIntoScreen(panel)
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
                if self?.shouldIgnoreEscape?() == true { return event }
                self?.close()
                return nil
            }
            return event
        }

        return model
    }

    /// Vue résultat câblée : fermeture, clic sur un mot (section + index pour
    /// le remplacement par la bulle).
    private func makeResultView(model: ResultModel, maxHeight: CGFloat, fluid: Bool) -> ResultView {
        ResultView(
            model: model,
            onClose: { [weak self] in self?.close() },
            maxHeight: maxHeight,
            fluid: fluid,
            onWordTap: { [weak self] section, tokenIndex, word in
                self?.onWordSelected?(section, tokenIndex, word, NSEvent.mouseLocation)
            }
        )
    }

    /// Début du redimensionnement manuel : passer la vue en mode fluide
    /// (sinon le hosting réimpose la taille du contenu pendant le drag).
    private func beginUserResize() {
        guard let model else { return }
        userResizing = true
        hostRef?.sizingOptions = []
        hostRef?.rootView = makeResultView(model: model, maxHeight: .infinity, fluid: true)
    }

    /// Fin du redimensionnement : mémoriser la taille choisie pour les
    /// prochains panneaux et ré-ancrer le coin haut-gauche.
    private func endUserResize() {
        userResizing = false
        guard let panel else { return }
        PanelSizeStore.save(panel.frame.size)
        topLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        panel.invalidateShadow()
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
        panel?.orderOut(nil)
        panel = nil
        hostRef = nil
        model = nil
    }
}
