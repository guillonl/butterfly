// Génère le fond de la fenêtre du DMG d'installation : fond clair dégradé,
// titre, instruction, et une flèche fine entre l'emplacement de l'app (gauche)
// et l'alias Applications (droite). Produit assets/dmg-background.png (@1x) +
// assets/dmg-background@2x.png, que scripts/make_dmg.sh combine en .tiff Retina.
//
//   swift scripts/make_dmg_background.swift
//
// Dimensions logiques calées sur la fenêtre du DMG (540 × 380, cf. make_dmg.sh).
import AppKit

let W: CGFloat = 540
let H: CGFloat = 380

// Centres des icônes (coordonnées create-dmg, origine haut-gauche). La flèche
// vit entre les deux, sur la même ligne, pour pointer de l'app vers Applications.
let iconY: CGFloat = 188
let appX: CGFloat = 140
let appsX: CGFloat = 400

/// Rend le fond à l'échelle donnée (1 = 540×380, 2 = 1080×760 Retina).
func render(scale: CGFloat) -> NSBitmapImageRep {
    let pxW = Int(W * scale), pxH = Int(H * scale)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pxW, pixelsHigh: pxH,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    // rep.size en POINTS logiques (540×380) alors que le bitmap fait pxW×pxH :
    // NSGraphicsContext applique tout seul le scale points→pixels, on dessine
    // donc en coordonnées logiques et le @2x reste net (pas de scaleBy manuel,
    // sinon double échelle et contenu hors-cadre).
    rep.size = NSSize(width: W, height: H)

    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx

    // CoreGraphics a son origine en bas-gauche : convertit un y « depuis le haut ».
    func top(_ y: CGFloat) -> CGFloat { H - y }

    // Fond : dégradé vertical très doux, blanc cassé en haut → gris perle en bas.
    let gradient = NSGradient(colors: [
        NSColor(calibratedWhite: 0.992, alpha: 1),
        NSColor(calibratedWhite: 0.937, alpha: 1),
    ])!
    gradient.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -90)

    // Titre.
    let titleStyle = NSMutableParagraphStyle()
    titleStyle.alignment = .center
    let title = NSAttributedString(string: "Butterfly", attributes: [
        .font: NSFont.systemFont(ofSize: 24, weight: .semibold),
        .foregroundColor: NSColor(calibratedWhite: 0.11, alpha: 1),
        .paragraphStyle: titleStyle,
    ])
    title.draw(in: NSRect(x: 0, y: top(64), width: W, height: 34))

    // Instruction.
    let hintStyle = NSMutableParagraphStyle()
    hintStyle.alignment = .center
    let hint = NSAttributedString(string: "Glisse Butterfly sur Applications pour l’installer", attributes: [
        .font: NSFont.systemFont(ofSize: 13, weight: .regular),
        .foregroundColor: NSColor(calibratedWhite: 0.45, alpha: 1),
        .paragraphStyle: hintStyle,
    ])
    hint.draw(in: NSRect(x: 0, y: top(96), width: W, height: 20))

    // Flèche fine entre les deux icônes (gris doux, traits arrondis).
    let arrow = NSColor(calibratedWhite: 0.72, alpha: 1)
    arrow.setStroke()
    let shaft = NSBezierPath()
    shaft.lineWidth = 3
    shaft.lineCapStyle = .round
    let startX = appX + 72
    let endX = appsX - 72
    let y = top(iconY)
    shaft.move(to: NSPoint(x: startX, y: y))
    shaft.line(to: NSPoint(x: endX, y: y))
    shaft.stroke()
    // Pointe.
    let head = NSBezierPath()
    head.lineWidth = 3
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    head.move(to: NSPoint(x: endX - 11, y: y + 8))
    head.line(to: NSPoint(x: endX, y: y))
    head.line(to: NSPoint(x: endX - 11, y: y - 8))
    head.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func write(_ rep: NSBitmapImageRep, to path: String) {
    guard let data = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("PNG encode failed\n".utf8)); exit(1)
    }
    try! data.write(to: URL(fileURLWithPath: path))
    print("écrit \(path) (\(rep.pixelsWide)×\(rep.pixelsHigh))")
}

let dir = "assets"
write(render(scale: 1), to: "\(dir)/dmg-background.png")
write(render(scale: 2), to: "\(dir)/dmg-background@2x.png")
