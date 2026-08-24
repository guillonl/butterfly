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
    /// Quatre rubans repliés reprennent le langage du logo d'app sans son
    /// fond, afin de rester lisibles à la taille d'une icône système.
    static func statusItemImage() -> NSImage {
        let size = NSSize(width: 20, height: 20)
        let image = NSImage(size: size, flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setStrokeColor(NSColor.black.cgColor)
            context.setFillColor(NSColor.black.cgColor)
            context.setLineWidth(3.2)
            context.setLineCap(.round)
            context.setLineJoin(.round)

            func ribbon(_ points: [CGPoint]) {
                guard let first = points.first else { return }
                let path = CGMutablePath()
                path.move(to: first)
                if points.count == 3 {
                    path.addQuadCurve(to: points[2], control: points[1])
                } else {
                    for point in points.dropFirst() { path.addLine(to: point) }
                }
                context.addPath(path)
                context.strokePath()
            }

            ribbon([CGPoint(x: 9.0, y: 9.7), CGPoint(x: 2.8, y: 1.8), CGPoint(x: 2.6, y: 8.2)])
            ribbon([CGPoint(x: 11.0, y: 9.7), CGPoint(x: 17.2, y: 1.8), CGPoint(x: 17.4, y: 8.2)])
            ribbon([CGPoint(x: 8.9, y: 10.8), CGPoint(x: 3.3, y: 18.0), CGPoint(x: 3.5, y: 12.2)])
            ribbon([CGPoint(x: 11.1, y: 10.8), CGPoint(x: 16.7, y: 18.0), CGPoint(x: 16.5, y: 12.2)])

            let body = CGPath(roundedRect: CGRect(x: 9.2, y: 7.0, width: 1.6, height: 9.7),
                              cornerWidth: 0.8, cornerHeight: 0.8, transform: nil)
            context.addPath(body)
            context.fillPath()
            context.fillEllipse(in: CGRect(x: 9.15, y: 4.9, width: 1.7, height: 1.7))
            return true
        }
        image.isTemplate = true
        return image
    }
}
