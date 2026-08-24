import AppKit
import SwiftUI

/// Grammaire visuelle partagée avec Jauge. Les surfaces et métriques sont
/// centralisées pour éviter que chaque panneau invente ses propres rayons,
/// gris et tailles de texte.
enum ButterflyTokens {
    static let ink = dynamic(light: 0x15171C, dark: 0xF1F2F4)
    static let dim = dynamic(light: 0x7C8087, dark: 0x8F939B)
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x1E1F24)
    static let cardFill = dynamic(light: 0xF7F8F9, dark: 0x26282E)
    static let cardStroke = dynamic(light: 0xEBEDEF, dark: 0x31333A)
    static let hairline = dynamic(light: 0xEEF0F2, dark: 0x2B2D33)
    static let good = dynamic(light: 0x3AAB68, dark: 0x45C078)
    static let warn = dynamic(light: 0xE28B33, dark: 0xF0A04B)
    static let bad = dynamic(light: 0xD4453A, dark: 0xE8574A)

    static let panelRadius: CGFloat = 18
    static let cardRadius: CGFloat = 12
    static let controlRadius: CGFloat = 7
    static let panelPadding: CGFloat = 18
    static let cardPadding: CGFloat = 12
    static let sectionSpacing: CGFloat = 20

    private static func dynamic(light: Int, dark: Int) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let darkMode = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(butterflySRGB: darkMode ? dark : light)
        })
    }
}

extension View {
    func butterflyCard(_ fill: Color = ButterflyTokens.cardFill) -> some View {
        background(
            RoundedRectangle(cornerRadius: ButterflyTokens.cardRadius, style: .continuous)
                .fill(fill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ButterflyTokens.cardRadius, style: .continuous)
                .stroke(ButterflyTokens.cardStroke, lineWidth: 0.5)
        )
    }

    func butterflyPanel() -> some View {
        background(ButterflyTokens.surface)
            .clipShape(RoundedRectangle(cornerRadius: ButterflyTokens.panelRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: ButterflyTokens.panelRadius, style: .continuous)
                    .stroke(ButterflyTokens.cardStroke, lineWidth: 0.75)
            )
    }
}

struct ButterflySectionTitle: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(ButterflyTokens.dim)
    }
}

extension NSColor {
    convenience init(butterflySRGB hex: Int) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
