import AppKit
import SwiftUI

/// Carte de résultat en Liquid Glass : texte détecté, correction, traduction.
struct ResultView: View {
    @ObservedObject var model: ResultModel
    var onClose: () -> Void

    @State private var appeared = false

    private let languages = ["en", "fr", "es", "de", "it", "pt"]
    private let cardWidth: CGFloat = 440

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
                .opacity(0.4)
                .padding(.horizontal, 24)
            content
        }
        .frame(width: cardWidth, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
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
    }

    // MARK: - Contenu

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
                correctionSection
                translationSection
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
                    .lineLimit(5)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
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

    private var correctionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel(L10n.t("panel.correction"))
            stateView(model.correction, emphasized: true)
        }
    }

    private var translationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                sectionLabel(L10n.t("panel.translation"))
                languageMenu
                Spacer()
            }
            stateView(model.translation, emphasized: false)
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
            HStack(spacing: 4) {
                Text(L10n.languageName(model.targetLanguage))
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
            }
            .font(.system(size: 11, weight: .medium))
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .fixedSize()
    }

    @ViewBuilder
    private func stateView(_ state: ResultModel.SectionState, emphasized: Bool) -> some View {
        switch state {
        case .loading:
            ShimmerLines()
        case .value(let text):
            HStack(alignment: .top, spacing: 12) {
                Text(text)
                    .font(.system(size: emphasized ? 14 : 13, weight: emphasized ? .medium : .regular))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
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

/// Bouton copier rond en verre, feedback ✓ animé.
struct CopyButton: View {
    let text: String
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
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
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
