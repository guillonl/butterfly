import SwiftUI

/// Découpe la zone sélectionnée dans le voile sombre (remplissage even-odd).
struct CutoutShape: Shape {
    var cutout: CGRect?

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(rect)
        if let cutout, cutout.width > 1, cutout.height > 1 {
            path.addRoundedRect(in: cutout, cornerSize: CGSize(width: 6, height: 6))
        }
        return path
    }
}

/// L'overlay plein écran : capture gelée + voile + loupe liquide + sélection.
struct OverlayView: View {
    let capture: CapturedScreen
    let onSelect: (CGRect) -> Void
    let onCancel: () -> Void

    @State private var cursor: CGPoint?
    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?
    @State private var appeared = false

    private let loupeDiameter: CGFloat = 120
    private let magnification: CGFloat = 1.7

    private var selectionRect: CGRect? {
        guard let start = dragStart, let current = dragCurrent else { return nil }
        return CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(start.x - current.x),
            height: abs(start.y - current.y)
        )
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .topLeading) {
                frozenScreen(size: size)
                dimLayer
                if let rect = selectionRect, rect.width > 2 || rect.height > 2 {
                    selectionView(rect)
                }
                hintCapsule(size: size)
                if let cursor {
                    loupe(at: cursor, size: size)
                }
            }
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .gesture(dragGesture)
            .onContinuousHover(coordinateSpace: .local) { phase in
                if case .active(let point) = phase { cursor = point }
            }
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { appeared = true }
        }
    }

    // MARK: - Gestes

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                if dragStart == nil { dragStart = value.startLocation }
                dragCurrent = value.location
                cursor = value.location
            }
            .onEnded { _ in
                let rect = selectionRect
                dragStart = nil
                dragCurrent = nil
                if let rect, rect.width >= 12, rect.height >= 8 {
                    onSelect(rect)
                } else {
                    onCancel()
                }
            }
    }

    // MARK: - Couches

    private func frozenScreen(size: CGSize) -> some View {
        Image(decorative: capture.image, scale: capture.scale)
            .resizable()
            .frame(width: size.width, height: size.height)
    }

    private var dimLayer: some View {
        CutoutShape(cutout: selectionRect)
            .fill(Color.black.opacity(appeared ? 0.36 : 0), style: FillStyle(eoFill: true))
            .animation(.easeOut(duration: 0.25), value: appeared)
    }

    private func selectionView(_ rect: CGRect) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.white.opacity(0.95), lineWidth: 2)
                .shadow(color: .black.opacity(0.4), radius: 12, y: 2)
                .frame(width: max(rect.width, 4), height: max(rect.height, 4))
                .position(x: rect.midX, y: rect.midY)

            Text(L10n.t("drag.release"))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .glassEffect(.regular, in: .capsule)
                .position(x: rect.midX, y: rect.maxY + 28)
        }
    }

    private func hintCapsule(size: CGSize) -> some View {
        HStack(spacing: 10) {
            ButterflyShape()
                .fill(Color.white.opacity(0.95))
                .frame(width: 18, height: 18)
            Text(L10n.t("hint.select"))
                .font(.system(size: 13, weight: .medium))
            Text(L10n.t("hint.esc"))
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 4))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
        .position(x: size.width / 2, y: appeared ? 52 : 24)
        .opacity(appeared ? (dragStart == nil ? 1 : 0) : 0)
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: appeared)
        .animation(.easeOut(duration: 0.2), value: dragStart == nil)
    }

    /// La loupe liquide : contenu magnifié (avec la ligne de sélection
    /// reproduite dans la lentille) + réticule + reflet + anneau de verre.
    /// Elle remplace le curseur système (masqué par l'OverlayController) et
    /// suit le pointeur avec un spring court, effet « liquide ».
    private func loupe(at point: CGPoint, size: CGSize) -> some View {
        let d = loupeDiameter
        let m = magnification
        let offX = d / 2 - point.x * m
        let offY = d / 2 - point.y * m
        return ZStack {
            // Contenu magnifié, clippé à la lentille
            ZStack(alignment: .topLeading) {
                Image(decorative: capture.image, scale: capture.scale)
                    .resizable()
                    .frame(width: size.width * m, height: size.height * m)
                    .offset(x: offX, y: offY)

                // La sélection en cours, magnifiée elle aussi : on voit
                // précisément où passe la ligne sous la loupe.
                if let sel = selectionRect, sel.width > 2 || sel.height > 2 {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.white.opacity(0.95), lineWidth: 2.5)
                        .frame(width: max(sel.width * m, 4), height: max(sel.height * m, 4))
                        .position(x: sel.midX * m + offX, y: sel.midY * m + offY)
                }
            }
            .frame(width: d, height: d, alignment: .topLeading)
            .clipShape(Circle())

            Group {
                Rectangle().frame(width: 1, height: 12)
                Rectangle().frame(width: 12, height: 1)
            }
            .foregroundStyle(.white.opacity(0.9))
            .shadow(color: .black.opacity(0.6), radius: 1)

            Ellipse()
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0.22), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: d * 0.72, height: d * 0.34)
                .offset(y: -d * 0.26)

            Circle()
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.9), .white.opacity(0.25), .white.opacity(0.7)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 2
                )
            Circle()
                .inset(by: 2)
                .strokeBorder(Color.black.opacity(0.12), lineWidth: 1)
        }
        .frame(width: d, height: d)
        .compositingGroup()
        .shadow(color: .black.opacity(0.35), radius: 16, y: 8)
        .scaleEffect(appeared ? 1 : 0.6)
        .opacity(appeared ? 1 : 0)
        .position(point)
        .animation(.interactiveSpring(response: 0.18, dampingFraction: 0.78), value: point)
        .allowsHitTesting(false)
    }
}
