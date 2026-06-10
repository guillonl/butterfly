import AppKit
import SwiftUI

/// Papillon géométrique partagé entre l'icône menu bar, le hint de l'overlay
/// et le header du panneau résultat. 4 ellipses pivotées + corps + tête.
struct ButterflyShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        let cx = rect.midX

        func wing(center: CGPoint, size: CGSize, degrees: Double) {
            let transform = CGAffineTransform(translationX: center.x, y: center.y)
                .rotated(by: degrees * .pi / 180)
            path.addEllipse(
                in: CGRect(x: -size.width / 2, y: -size.height / 2,
                           width: size.width, height: size.height),
                transform: transform
            )
        }

        // Géométrie alignée sur le logo final (assets/AppIcon.icns).
        // Ailes hautes (grandes)
        wing(center: CGPoint(x: rect.minX + 0.30 * w, y: rect.minY + 0.33 * h),
             size: CGSize(width: 0.42 * w, height: 0.27 * h), degrees: 35)
        wing(center: CGPoint(x: rect.minX + 0.70 * w, y: rect.minY + 0.33 * h),
             size: CGSize(width: 0.42 * w, height: 0.27 * h), degrees: -35)
        // Ailes basses (petites)
        wing(center: CGPoint(x: rect.minX + 0.365 * w, y: rect.minY + 0.65 * h),
             size: CGSize(width: 0.28 * w, height: 0.20 * h), degrees: -38)
        wing(center: CGPoint(x: rect.minX + 0.635 * w, y: rect.minY + 0.65 * h),
             size: CGSize(width: 0.28 * w, height: 0.20 * h), degrees: 38)
        // Corps
        path.addRoundedRect(
            in: CGRect(x: cx - 0.03 * w, y: rect.minY + 0.34 * h,
                       width: 0.06 * w, height: 0.40 * h),
            cornerSize: CGSize(width: 0.03 * w, height: 0.03 * w)
        )
        // Tête
        path.addEllipse(in: CGRect(x: cx - 0.035 * w, y: rect.minY + 0.258 * h,
                                   width: 0.07 * w, height: 0.07 * w))
        return path
    }
}

enum ButterflyArt {

    /// Icône template 20×20 pour la barre de menus (s'adapte clair/sombre).
    /// Le glyphe papillon n'occupe que ~72 % de sa bounding box : on
    /// surdimensionne le rect de dessin pour atteindre la taille optique
    /// des icônes système voisines.
    static func statusItemImage() -> NSImage {
        let size = NSSize(width: 20, height: 20)
        let image = NSImage(size: size, flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let overscan: CGFloat = 1.32
            let side = rect.width * overscan
            let drawRect = CGRect(
                x: rect.midX - side / 2,
                y: rect.minY - side * 0.085,
                width: side,
                height: side
            )
            let path = ButterflyShape().path(in: drawRect)
            context.addPath(path.cgPath)
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath()
            return true
        }
        image.isTemplate = true
        return image
    }
}
