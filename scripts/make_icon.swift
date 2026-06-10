#!/usr/bin/env swift
//
//  make_icon.swift — Butterfly app icon (macOS 26 Tahoe, Liquid Glass)
//
//  Draws a 1024×1024 app icon: deep indigo→violet→cyan glass squircle
//  with a simple geometric translucent-glass butterfly.
//
//  Usage:   swift scripts/make_icon.swift [output.png]
//  Default output: assets/icon_1024.png (relative to cwd)
//
//  Coordinate convention: the CGContext is flipped (origin TOP-LEFT, y down)
//  so all layout code reads like design coordinates. CGContext shadows use
//  base space (y up), hence the negated shadow offset.
//

import AppKit

// MARK: - Design parameters ---------------------------------------------------

let canvas: CGFloat = 1024

// Squircle
let squircleSize: CGFloat = 820
let squircleRadius: CGFloat = 185
let squircleOrigin = CGPoint(x: (canvas - squircleSize) / 2, y: (canvas - squircleSize) / 2)

// Background gradient (top-left → bottom-right)
struct GradientStop { let hex: UInt32; let alpha: CGFloat; let location: CGFloat }
let bgStops: [GradientStop] = [
    .init(hex: 0x3730A3, alpha: 1.0, location: 0.00),  // deep indigo
    .init(hex: 0x4F46E5, alpha: 1.0, location: 0.26),  // indigo
    .init(hex: 0x8B5CF6, alpha: 1.0, location: 0.52),  // violet
    .init(hex: 0x22D3EE, alpha: 1.0, location: 0.96),  // luminous cyan
]

// Butterfly geometry — normalized to the squircle (origin = squircle top-left,
// units = fraction of squircle size). Tuned visually, see git history.
struct Wing {
    var cx: CGFloat; var cy: CGFloat       // center
    var w: CGFloat; var h: CGFloat         // ellipse size
    var rotation: CGFloat                  // degrees, flipped-space
    var alphaTop: CGFloat; var alphaBottom: CGFloat
}

// Rotation convention: positive = clockwise on screen (CSS/SwiftUI-style),
// which in this flipped CG context maps directly to ctx.rotate(by:).
var upperLeftWing  = Wing(cx: 0.300, cy: 0.330, w: 0.42, h: 0.27, rotation: 35,
                          alphaTop: 0.88, alphaBottom: 0.66)
var lowerLeftWing  = Wing(cx: 0.365, cy: 0.650, w: 0.28, h: 0.20, rotation: -38,
                          alphaTop: 0.72, alphaBottom: 0.52)

// Body
let bodyW: CGFloat = 0.06
let bodyH: CGFloat = 0.40
let bodyCenter = CGPoint(x: 0.50, y: 0.54)
let headRadius: CGFloat = 0.035
let headGap: CGFloat = 0.012               // gap between body top and head
let antennaLength: CGFloat = 0.100         // vertical reach of antennae
let antennaSpread: CGFloat = 0.080         // horizontal reach of antennae
let antennaTipRadius: CGFloat = 0.008

// Strokes & shadow
let wingStrokeAlpha: CGFloat = 0.90
let wingStrokeWidth: CGFloat = 5
let shadowAlpha: CGFloat = 0.18
let shadowBlur: CGFloat = 30
let shadowOffsetY: CGFloat = 14            // downward, in design space

// MARK: - Helpers -------------------------------------------------------------

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: srgb, components: [
        CGFloat((hex >> 16) & 0xFF) / 255,
        CGFloat((hex >> 8) & 0xFF) / 255,
        CGFloat(hex & 0xFF) / 255,
        alpha
    ])!
}

func white(_ alpha: CGFloat) -> CGColor {
    CGColor(colorSpace: srgb, components: [1, 1, 1, alpha])!
}

func black(_ alpha: CGFloat) -> CGColor {
    CGColor(colorSpace: srgb, components: [0, 0, 0, alpha])!
}

func makeGradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: srgb, colors: colors as CFArray, locations: locations)!
}

/// Squircle-space normalized point → canvas point (flipped space, y down).
func sq(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
    CGPoint(x: squircleOrigin.x + x * squircleSize,
            y: squircleOrigin.y + y * squircleSize)
}

func sqLen(_ v: CGFloat) -> CGFloat { v * squircleSize }

func deg(_ d: CGFloat) -> CGFloat { d * .pi / 180 }

// MARK: - Bitmap setup --------------------------------------------------------

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(canvas), pixelsHigh: Int(canvas),
    bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0
) else { fatalError("Could not create bitmap rep") }
rep.size = NSSize(width: canvas, height: canvas)

guard let nsCtx = NSGraphicsContext(bitmapImageRep: rep) else {
    fatalError("Could not create graphics context")
}
NSGraphicsContext.current = nsCtx
let ctx = nsCtx.cgContext

// Flip to top-left origin, y down.
ctx.translateBy(x: 0, y: canvas)
ctx.scaleBy(x: 1, y: -1)
ctx.setAllowsAntialiasing(true)
ctx.interpolationQuality = .high

let squircleRect = CGRect(origin: squircleOrigin,
                          size: CGSize(width: squircleSize, height: squircleSize))
let squirclePath = CGPath(roundedRect: squircleRect,
                          cornerWidth: squircleRadius,
                          cornerHeight: squircleRadius,
                          transform: nil)

// MARK: - 1. Background gradient ---------------------------------------------

ctx.saveGState()
ctx.addPath(squirclePath)
ctx.clip()

let bgGradient = makeGradient(bgStops.map { color($0.hex, $0.alpha) },
                              bgStops.map { $0.location })
ctx.drawLinearGradient(
    bgGradient,
    start: CGPoint(x: squircleRect.minX, y: squircleRect.minY),       // top-left
    end: CGPoint(x: squircleRect.maxX, y: squircleRect.maxY),         // bottom-right
    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
)

// MARK: - 2. Glass highlight (upper third) -------------------------------------

// Wide soft ellipse hanging over the top edge, white fading downward.
let glossRect = CGRect(
    x: squircleRect.midX - squircleSize * 0.75,
    y: squircleRect.minY - squircleSize * 0.34,
    width: squircleSize * 1.50,
    height: squircleSize * 0.68
)
ctx.saveGState()
ctx.addEllipse(in: glossRect)
ctx.clip()
let glossGradient = makeGradient([white(0.16), white(0.10), white(0.0)], [0.0, 0.55, 1.0])
ctx.drawLinearGradient(
    glossGradient,
    start: CGPoint(x: glossRect.midX, y: glossRect.minY),
    end: CGPoint(x: glossRect.midX, y: glossRect.maxY),
    options: []
)
ctx.restoreGState()

// MARK: - 3. Bottom vignette ---------------------------------------------------

let vignetteGradient = makeGradient([black(0.0), black(0.16)], [0.0, 1.0])
ctx.drawLinearGradient(
    vignetteGradient,
    start: CGPoint(x: squircleRect.midX, y: squircleRect.minY + squircleSize * 0.62),
    end: CGPoint(x: squircleRect.midX, y: squircleRect.maxY),
    options: []
)

// MARK: - 4. Subtle inner edge light -------------------------------------------

ctx.saveGState()
ctx.addPath(CGPath(roundedRect: squircleRect.insetBy(dx: 1.5, dy: 1.5),
                   cornerWidth: squircleRadius - 1.5,
                   cornerHeight: squircleRadius - 1.5,
                   transform: nil))
ctx.setStrokeColor(white(0.10))
ctx.setLineWidth(3)
ctx.strokePath()
ctx.restoreGState()

// MARK: - 5. Butterfly ----------------------------------------------------------
// Drawn inside a transparency layer so the soft shadow applies to the whole
// silhouette at once (glass object resting on the background).

func drawWing(_ wing: Wing, mirrored: Bool) {
    let cx = mirrored ? 1 - wing.cx : wing.cx
    let rotation = mirrored ? -wing.rotation : wing.rotation
    let center = sq(cx, wing.cy)
    let w = sqLen(wing.w), h = sqLen(wing.h)
    let rect = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)

    ctx.saveGState()
    ctx.translateBy(x: center.x, y: center.y)
    ctx.rotate(by: deg(rotation))

    // Glass fill: vertical gradient inside the rotated ellipse (top more opaque).
    ctx.saveGState()
    ctx.addEllipse(in: rect)
    ctx.clip()
    let wingGradient = makeGradient([white(wing.alphaTop), white(wing.alphaBottom)], [0, 1])
    ctx.drawLinearGradient(
        wingGradient,
        start: CGPoint(x: 0, y: rect.minY),
        end: CGPoint(x: 0, y: rect.maxY),
        options: []
    )
    ctx.restoreGState()

    // Crisp rim.
    ctx.addEllipse(in: rect.insetBy(dx: wingStrokeWidth / 2, dy: wingStrokeWidth / 2))
    ctx.setStrokeColor(white(wingStrokeAlpha))
    ctx.setLineWidth(wingStrokeWidth)
    ctx.strokePath()

    ctx.restoreGState()
}

func drawBody() {
    let w = sqLen(bodyW), h = sqLen(bodyH)
    let center = sq(bodyCenter.x, bodyCenter.y)
    let bodyRect = CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h)

    // Capsule body.
    ctx.addPath(CGPath(roundedRect: bodyRect, cornerWidth: w / 2, cornerHeight: w / 2,
                       transform: nil))
    ctx.setFillColor(white(0.96))
    ctx.fillPath()

    // Head.
    let r = sqLen(headRadius)
    let headCenter = CGPoint(x: center.x, y: bodyRect.minY - sqLen(headGap) - r)
    ctx.addEllipse(in: CGRect(x: headCenter.x - r, y: headCenter.y - r,
                              width: 2 * r, height: 2 * r))
    ctx.setFillColor(white(0.96))
    ctx.fillPath()

    // Antennae: two thin curves from the head, arcing up & outward.
    let tipR = sqLen(antennaTipRadius)
    for side: CGFloat in [-1, 1] {
        let start = CGPoint(x: headCenter.x + side * r * 0.35, y: headCenter.y - r * 0.7)
        let tip = CGPoint(x: headCenter.x + side * sqLen(antennaSpread),
                          y: headCenter.y - sqLen(antennaLength))
        let control = CGPoint(x: headCenter.x + side * sqLen(antennaSpread) * 0.15,
                              y: headCenter.y - sqLen(antennaLength) * 0.95)
        ctx.move(to: start)
        ctx.addQuadCurve(to: tip, control: control)
        ctx.setStrokeColor(white(0.92))
        ctx.setLineWidth(6)
        ctx.setLineCap(.round)
        ctx.strokePath()

        // Tiny dot at the tip.
        ctx.addEllipse(in: CGRect(x: tip.x - tipR, y: tip.y - tipR,
                                  width: 2 * tipR, height: 2 * tipR))
        ctx.setFillColor(white(0.92))
        ctx.fillPath()
    }
}

// Soft drop shadow for the whole butterfly (offset y is base-space, hence negative).
ctx.setShadow(offset: CGSize(width: 0, height: -shadowOffsetY),
              blur: shadowBlur,
              color: black(shadowAlpha))
ctx.beginTransparencyLayer(auxiliaryInfo: nil)

drawWing(upperLeftWing, mirrored: false)
drawWing(upperLeftWing, mirrored: true)
drawWing(lowerLeftWing, mirrored: false)
drawWing(lowerLeftWing, mirrored: true)
drawBody()

ctx.endTransparencyLayer()

ctx.restoreGState()   // squircle clip

// MARK: - Export ----------------------------------------------------------------

NSGraphicsContext.current = nil

let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "assets/icon_1024.png"

guard let pngData = rep.representation(using: .png, properties: [:]) else {
    fatalError("PNG encoding failed")
}
let outputURL = URL(fileURLWithPath: outputPath)
try? FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
)
do {
    try pngData.write(to: outputURL)
    print("Wrote \(outputPath) (\(pngData.count) bytes)")
} catch {
    fatalError("Could not write \(outputPath): \(error)")
}
