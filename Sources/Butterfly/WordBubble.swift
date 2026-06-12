import AppKit
import SwiftUI

/// État de la bulle de mot : alternatives proposées pour un mot surligné.
@MainActor
final class WordBubbleModel: ObservableObject {
    enum Phase: Equatable {
        case loading
        case value([String])
        case failure(String)
    }

    let word: String
    let sourceLanguage: String
    @Published var phase: Phase = .loading

    var backend: EngineBackend?
    private var seen: [String] = []
    private var task: Task<Void, Never>?

    init(word: String, sourceLanguage: String) {
        self.word = word
        self.sourceLanguage = sourceLanguage
    }

    func load() {
        guard let backend else { return }
        phase = .loading
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let alternatives = try await TextEngine.shared.alternatives(
                    for: self.word,
                    source: self.sourceLanguage,
                    excluding: self.seen,
                    using: backend
                )
                guard !Task.isCancelled else { return }
                guard !alternatives.isEmpty else {
                    self.phase = .failure(L10n.t("panel.error"))
                    return
                }
                self.seen.append(contentsOf: alternatives)
                self.phase = .value(alternatives)
            } catch {
                guard !Task.isCancelled else { return }
                self.phase = .failure(L10n.t("panel.error"))
            }
        }
    }
}

/// Petite bulle compacte : le mot, des alternatives cliquables (copie),
/// un bouton pour régénérer d'autres propositions.
struct WordBubbleView: View {
    @ObservedObject var model: WordBubbleModel
    var onClose: () -> Void

    @State private var appeared = false
    @State private var copiedIndex: Int?

    private let bubbleWidth: CGFloat = 280

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
                .opacity(0.4)
                .padding(.horizontal, 16)
            content
        }
        .frame(width: bubbleWidth, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .scaleEffect(appeared ? 1 : 0.92, anchor: .top)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { appeared = true }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.phase)
    }

    private var header: some View {
        HStack(spacing: 8) {
            ButterflyShape()
                .fill(.primary)
                .frame(width: 16, height: 16)
            Text(model.word)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Spacer()
            Button {
                model.load()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .disabled(model.phase == .loading)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L10n.t("bubble.loading"))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
        case .failure(let message):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(16)
        case .value(let alternatives):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(alternatives.enumerated()), id: \.offset) { index, alternative in
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(alternative, forType: .string)
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                            copiedIndex = index
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            withAnimation(.easeOut(duration: 0.2)) { copiedIndex = nil }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Text(alternative)
                                .font(.system(size: 13))
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: copiedIndex == index ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(copiedIndex == index ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                }
                Text(L10n.t("bubble.hint"))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 6)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
        }
    }
}

/// Contrôleur de la bulle, ancrée près du mot (position souris).
@MainActor
final class WordBubbleController {
    private var panel: ResultPanel?
    private var hostRef: NSHostingController<WordBubbleView>?
    private var monitors: [Any] = []
    private var topLeft: NSPoint = .zero
    private var resizeObserver: NSObjectProtocol?
    private(set) var model: WordBubbleModel?

    @discardableResult
    func show(word: String, sourceLanguage: String, near anchorTopLeft: CGRect, on screen: NSScreen) -> WordBubbleModel {
        close()

        let model = WordBubbleModel(word: word, sourceLanguage: sourceLanguage)
        self.model = model

        let width: CGFloat = 280
        let estimated: CGFloat = 200

        let sf = screen.frame
        let globalRect = NSRect(
            x: sf.minX + anchorTopLeft.minX,
            y: sf.maxY - anchorTopLeft.maxY,
            width: anchorTopLeft.width,
            height: anchorTopLeft.height
        )
        let visible = screen.visibleFrame
        var x = globalRect.midX - width / 2
        x = max(visible.minX + 8, min(x, visible.maxX - width - 8))
        var top = globalRect.minY - 12
        if top - estimated < visible.minY + 8 {
            top = min(globalRect.maxY + 12 + estimated, visible.maxY - 8)
        }
        topLeft = NSPoint(x: x, y: top)

        let panel = ResultPanel(
            contentRect: NSRect(x: x, y: top - estimated, width: width, height: estimated),
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
            rootView: WordBubbleView(model: model, onClose: { [weak self] in self?.close() })
        )
        host.sizingOptions = [.preferredContentSize]
        hostRef = host
        panel.contentViewController = host

        self.panel = panel
        panel.setFrameTopLeftPoint(topLeft)
        panel.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak panel] in
            panel?.invalidateShadow()
        }

        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: panel, queue: .main
        ) { [weak self] _ in
            guard let self, let panel = self.panel else { return }
            panel.setFrameTopLeftPoint(self.topLeft)
            panel.invalidateShadow()
        }

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

        return model
    }

    func close() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        if let resizeObserver {
            NotificationCenter.default.removeObserver(resizeObserver)
            self.resizeObserver = nil
        }
        panel?.orderOut(nil)
        panel = nil
        hostRef = nil
        model = nil
    }
}
