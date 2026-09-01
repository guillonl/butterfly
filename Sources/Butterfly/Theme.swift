import SwiftUI

/// Design tokens de la refonte « Studio » (direction B du canvas).
/// Trois niveaux de surface sombre, un accent, hairlines subtiles.
/// Réf. maquettes : canvas « Refonte Butterfly » (2026-08-28).
enum Theme {
    // MARK: Surfaces (du plus profond au plus élevé)
    /// Fond du panneau détail.
    static let surfaceDeep = Color(red: 0x18 / 255, green: 0x18 / 255, blue: 0x1B / 255)
    /// Fond de la colonne liste.
    static let surfaceBase = Color(red: 0x1E / 255, green: 0x1E / 255, blue: 0x22 / 255)
    /// Fond de la sidebar et des cartes.
    static let surfaceRaised = Color(red: 0x23 / 255, green: 0x23 / 255, blue: 0x27 / 255)
    /// Cartes posées sur `surfaceRaised` (encart moteur).
    static let surfaceTop = Color(red: 0x2A / 255, green: 0x2A / 255, blue: 0x2F / 255)

    // MARK: Contenu
    static let textPrimary = Color(red: 0xF2 / 255, green: 0xF2 / 255, blue: 0xF4 / 255)
    static let textSecondary = Color(red: 0xD5 / 255, green: 0xD5 / 255, blue: 0xDA / 255)
    static let textTertiary = Color(red: 0x98 / 255, green: 0x98 / 255, blue: 0x9F / 255)
    static let textQuaternary = Color(red: 0x6E / 255, green: 0x6E / 255, blue: 0x76 / 255)

    // MARK: Accent et sémantique
    static let accent = Color(red: 0x0A / 255, green: 0x84 / 255, blue: 0xFF / 255)
    static let accentSoft = Color(red: 0x6F / 255, green: 0xB3 / 255, blue: 0xF2 / 255)
    /// Faute détectée (trait barré, pastilles).
    static let fault = Color(red: 0xFF / 255, green: 0x6B / 255, blue: 0x5E / 255)
    static let faultSoft = Color(red: 0xFF / 255, green: 0x8A / 255, blue: 0x7A / 255)
    /// Correction appliquée, états sains.
    static let fix = Color(red: 0x7D / 255, green: 0xDB / 255, blue: 0x98 / 255)
    static let ok = Color(red: 0x30 / 255, green: 0xD1 / 255, blue: 0x58 / 255)

    // MARK: Traits
    /// Hairline entre colonnes et sous les en-têtes.
    static let hairline = Color.white.opacity(0.06)
    /// Bordure des cartes.
    static let cardStroke = Color.white.opacity(0.06)
    /// Fond des contrôles discrets (boutons capsule secondaires, recherche).
    static let controlFill = Color.white.opacity(0.07)
    /// Fond des raccourcis clavier inline.
    static let keycapFill = Color.white.opacity(0.09)

    // MARK: Sélection
    static let selectionFill = accent.opacity(0.16)
    static let selectionStroke = accent.opacity(0.25)

    // MARK: Rayons (échelle fixe)
    static let radiusRow: CGFloat = 10
    static let radiusCard: CGFloat = 12
    static let radiusControl: CGFloat = 8

    // MARK: Typo (échelle héritée des panneaux existants)
    static let sectionLabel = Font.system(size: 10, weight: .semibold)
    static let meta = Font.system(size: 11)
    static let body = Font.system(size: 13)
    static let bodyEmphased = Font.system(size: 13, weight: .medium)
}

/// Label de section en capitales espacées (DÉTECTÉ, CORRECTION, …),
/// identique aux panneaux flottants existants.
struct StudioSectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(1.2)
            .foregroundStyle(Theme.textTertiary)
    }
}

/// Petit badge capsule (compteur de fautes, « propre », « à valider »…).
struct StudioBadge: View {
    let text: String
    var color: Color = Theme.textTertiary
    var background: Color = Theme.controlFill

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(background, in: Capsule())
    }
}

/// Bouton capsule du détail (Régénérer, Copier…) : variante pleine (accent)
/// ou discrète (controlFill), hover géré à la main (buttonStyle .plain).
struct StudioPillButton: View {
    let title: String
    let systemImage: String
    var prominent = false
    var action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(prominent ? .white : Theme.textSecondary)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(
                prominent
                    ? Theme.accent.opacity(hovered ? 0.85 : 1)
                    : Color.white.opacity(hovered ? 0.11 : 0.07),
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// Raccourci clavier inline (⌥⌘B) dans les textes d'aide.
struct StudioKeycap: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Theme.keycapFill, in: RoundedRectangle(cornerRadius: 4))
    }
}

/// Interrupteur Studio : capsule 34×20, accent bleu, animation spring.
/// Remplace le switch système dont la teinte suit l'accent utilisateur.
struct StudioToggle: View {
    @Binding var isOn: Bool
    var size: CGFloat = 20

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                isOn.toggle()
            }
        } label: {
            Capsule()
                .fill(isOn ? Theme.accent : Color.white.opacity(0.14))
                .frame(width: size * 1.7, height: size)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle()
                        .fill(.white)
                        .shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
                        .padding(2)
                }
        }
        .buttonStyle(.plain)
    }
}

/// Carte « bevel » du panneau détail : surface relevée, bordure dégradée
/// (lumière en haut), ombre courte. Sépare nettement les blocs de contenu
/// (correction, texte final, traduction…).
struct StudioCard<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(padding)
            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.radiusCard))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusCard)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.10), Color.white.opacity(0.03)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: .black.opacity(0.22), radius: 5, y: 2)
    }
}

/// Groupe d'actions segmenté (façon J'aime / J'aime pas) : une capsule,
/// des segments séparés par des hairlines, hover par segment.
struct StudioSegmentGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 0) { content }
            .background(Theme.controlFill, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
            .clipShape(Capsule())
    }
}

/// Un segment de StudioSegmentGroup.
struct StudioSegment: View {
    let title: String
    let systemImage: String
    var tint: Color = Theme.textSecondary
    var action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Color.white.opacity(hovered ? 0.08 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// Séparateur vertical entre segments.
struct StudioSegmentDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(width: 1, height: 16)
    }
}
