import AppKit
import SwiftUI

/// Carte de résultat en Liquid Glass : texte détecté, correction, traduction.
struct ResultView: View {
    @ObservedObject var model: ResultModel
    var onClose: () -> Void

    /// Hauteur max du panneau (bornée à l'écran) : au-delà, le contenu scrolle.
    var maxHeight: CGFloat = .infinity
    /// Mode fluide (taille de fenêtre mémorisée) : la vue remplit la fenêtre
    /// au lieu de la piloter.
    var fluid = false
    /// Clic sur un mot de la correction ou de la traduction : section, index
    /// du token (pour le remplacement) et mot nettoyé (bulle d'alternatives).
    var onWordTap: ((ResultModel.Section, Int, String) -> Void)?
    @State private var appeared = false
    @State private var originalExpanded = false
    @State private var contentHeight: CGFloat = 0
    @State private var headerHeight: CGFloat = 84

    private let languages = ["en", "fr", "es", "de", "it", "pt"]
    private let cardWidth: CGFloat = 440
    private let collapsedLineLimit = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 + 1 }
            Divider()
                .opacity(0.4)
                .padding(.horizontal, 24)
            scrollableContent
        }
        .frame(width: fluid ? nil : cardWidth, alignment: .leading)
        .frame(
            maxWidth: fluid ? .infinity : nil,
            maxHeight: fluid ? .infinity : nil,
            alignment: .top
        )
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
        // Le backdrop du verre occupe les bounds carrés de la fenêtre :
        // sans clip, ses bords débordent des coins arrondis.
        .clipShape(RoundedRectangle(cornerRadius: 28))
        .scaleEffect(appeared ? 1 : 0.94, anchor: .top)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) { appeared = true }
        }
        // Animer uniquement les changements d'état (loading → texte), pas
        // chaque token streamé, sinon le spring vibre pendant le stream.
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: phaseFingerprint)
    }

    /// Empreinte des phases de chaque section (0 loading, 1 valeur, 2 erreur).
    private var phaseFingerprint: [Int] {
        func kind(_ state: ResultModel.SectionState) -> Int {
            switch state {
            case .loading: return 0
            case .value: return 1
            case .failure: return 2
            }
        }
        return [model.original == nil ? 0 : 1, kind(model.correction), kind(model.translation)]
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            ButterflyShape()
                .fill(.primary)
                .frame(width: 22, height: 22)
            Text("Butterfly")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
            if !model.engineLabel.isEmpty {
                Text(model.engineLabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary.opacity(0.6), in: Capsule())
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 16)
        .contentShape(Rectangle())
        // Seul le header déplace la fenêtre : le reste du panneau est réservé
        // à la sélection de texte.
        .gesture(WindowDragGesture())
    }

    // MARK: - Contenu

    /// Le contenu suit sa hauteur naturelle tant qu'il tient dans l'écran,
    /// puis devient scrollable au lieu de faire déborder le panneau.
    /// En mode fluide, il remplit simplement la fenêtre.
    @ViewBuilder
    private var scrollableContent: some View {
        if fluid {
            ScrollView {
                content
            }
            .frame(maxHeight: .infinity)
            .scrollBounceBehavior(.basedOnSize)
        } else {
            let available = max(maxHeight - headerHeight, 120)
            ScrollView {
                content
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .frame(height: contentHeight > 0 ? min(contentHeight, available) : nil)
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let fatal = model.fatalMessage {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(fatal)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .padding(24)
        } else {
            VStack(alignment: .leading, spacing: 20) {
                originalSection
                if model.mode.showsCorrection {
                    correctionSection
                }
                if model.mode.showsTranslation {
                    translationSection
                }
                if model.mode.showsCorrection, case .value = model.correction {
                    regenerateButton
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 20)
        }
    }

    private var originalSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel(L10n.t("panel.detected"))
            if let original = model.original {
                Text(original)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(originalExpanded ? nil : collapsedLineLimit)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if needsExpansion(original) {
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            originalExpanded.toggle()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(L10n.t(originalExpanded ? "panel.less" : "panel.more"))
                            Image(systemName: originalExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 8, weight: .bold))
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L10n.t("panel.reading"))
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// Heuristique : le texte détecté risque d'être tronqué à 3 lignes.
    private func needsExpansion(_ text: String) -> Bool {
        text.count > 150 || text.filter { $0 == "\n" }.count >= collapsedLineLimit
    }

    /// Bouton « Régénérer une autre proposition », tout en bas du panneau.
    private var regenerateButton: some View {
        Button {
            model.regenerateCorrection()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .semibold))
                Text(L10n.t("panel.regenerate"))
            }
            .font(.system(size: 12, weight: .medium))
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var correctionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                sectionLabel(L10n.t("panel.correction"))
                if noCorrectionNeeded {
                    Text(L10n.t("panel.noChange"))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary.opacity(0.6), in: Capsule())
                }
                Spacer()
            }
            stateView(model.correction, section: .correction, emphasized: true)
        }
    }

    /// Vrai quand le texte corrigé est identique à l'original (aucune faute).
    private var noCorrectionNeeded: Bool {
        guard let original = model.original,
              case .value(let corrected) = model.correction else { return false }
        func normalize(_ s: String) -> String {
            s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return normalize(corrected) == normalize(original)
    }

    private var translationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                sectionLabel(L10n.t("panel.translation"))
                languageMenu
                Spacer()
            }
            stateView(model.translation, section: .translation, emphasized: false)
        }
    }

    private var languageMenu: some View {
        Menu {
            ForEach(languages, id: \.self) { code in
                Button {
                    model.targetLanguage = code
                } label: {
                    if code == model.targetLanguage {
                        Label(L10n.languageName(code), systemImage: "checkmark")
                    } else {
                        Text(L10n.languageName(code))
                    }
                }
            }
        } label: {
            Text(L10n.languageName(model.targetLanguage))
                .font(.system(size: 11, weight: .medium))
        }
        .menuStyle(.button) // un seul chevron : l'indicateur natif (à droite)
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .fixedSize()
    }

    @ViewBuilder
    private func stateView(_ state: ResultModel.SectionState, section: ResultModel.Section, emphasized: Bool) -> some View {
        switch state {
        case .loading:
            ShimmerLines()
        case .value(let text):
            HStack(alignment: .top, spacing: 12) {
                TappableText(
                    text: text,
                    font: .system(size: emphasized ? 14 : 13, weight: emphasized ? .medium : .regular),
                    onWordTap: { tokenIndex, word in onWordTap?(section, tokenIndex, word) }
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                CopyButton(text: text)
            }
        case .failure(let message):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(1.2)
            .foregroundStyle(.secondary)
    }
}

// MARK: - Composants

/// Texte dont chaque mot est cliquable : soulignement au survol, un clic
/// remonte l'index du token et le mot (nettoyé de sa ponctuation) pour la
/// bulle d'alternatives et le remplacement en place.
struct TappableText: View {
    let text: String
    let font: Font
    var onWordTap: ((Int, String) -> Void)?

    @State private var hoveredIndex: Int?

    private var tokens: [String] {
        text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
    }

    var body: some View {
        FlowLayout(horizontalSpacing: 4, verticalSpacing: 4) {
            ForEach(Array(tokens.enumerated()), id: \.offset) { index, token in
                Text(token)
                    .font(font)
                    .underline(hoveredIndex == index, color: .cyan)
                    .onHover { inside in
                        if inside {
                            hoveredIndex = index
                        } else if hoveredIndex == index {
                            hoveredIndex = nil
                        }
                    }
                    .onTapGesture {
                        let word = token.trimmingCharacters(in: .punctuationCharacters)
                        guard !word.isEmpty else { return }
                        onWordTap?(index, word)
                    }
            }
        }
    }
}

/// Disposition en lignes avec retour automatique (pour les mots cliquables).
struct FlowLayout: Layout {
    var horizontalSpacing: CGFloat = 4
    var verticalSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += lineHeight + verticalSpacing
                lineHeight = 0
            }
            x += size.width + horizontalSpacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - horizontalSpacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > bounds.width {
                x = 0
                y += lineHeight + verticalSpacing
                lineHeight = 0
            }
            subview.place(
                at: CGPoint(x: bounds.minX + x, y: bounds.minY + y),
                anchor: .topLeading,
                proposal: .unspecified
            )
            x += size.width + horizontalSpacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

/// Bouton copier rond en verre, feedback ✓ animé.
struct CopyButton: View {
    let text: String
    var icon: String = "doc.on.doc"
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                withAnimation(.easeOut(duration: 0.3)) { copied = false }
            }
        } label: {
            Image(systemName: copied ? "checkmark" : icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(copied ? AnyShapeStyle(.green) : AnyShapeStyle(.primary))
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .help(copied ? L10n.t("panel.copied") : L10n.t("panel.copy"))
    }
}

/// Placeholder de chargement : deux lignes qui pulsent doucement.
struct ShimmerLines: View {
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 6)
                .fill(.secondary.opacity(0.22))
                .frame(maxWidth: .infinity)
                .frame(height: 12)
            RoundedRectangle(cornerRadius: 6)
                .fill(.secondary.opacity(0.22))
                .frame(width: 180, height: 12)
        }
        .opacity(pulse ? 0.4 : 1)
        .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
        .onAppear { pulse = true }
    }
}
