#!/usr/bin/env swift
//
//  make_icon.swift — Butterfly app icon (macOS 26 Tahoe, monochrome dotwork)
//
//  Draws a 1024×1024 app icon: near-black squircle with a butterfly rendered
//  as a fine white outline (stroke only), filled with seeded film-grain /
//  stippling dots whose density and alpha increase toward the wing edges.
//
//  Usage:   swift scripts/make_icon.swift [output.png]
//  Default output: assets/icon_1024.png (relative to cwd)
//
//  Coordinate convention: the CGContext is flipped (origin TOP-LEFT, y down)
//  so all layout code reads like design coordinates.
//

import AppKit

// MARK: - Design parameters ---------------------------------------------------

let canvas: CGFloat = 1024

// Squircle (macOS Tahoe proportions — unchanged from v1)
let squircleSize: CGFloat = 820
let squircleRadius: CGFloat = 185
let squircleOrigin = CGPoint(x: (canvas - squircleSize) / 2, y: (canvas - squircleSize) / 2)

// Background — near-black, subtle radial lift behind the butterfly.
// Stays strictly within #050505…#161616.
let bgEdgeHex: UInt32 = 0x050505
let bgCenterHex: UInt32 = 0x141414

// Butterfly geometry — normalized to the squircle (origin = squircle top-left,
// units = fraction of squircle size). Validated visually in v1 — DO NOT TOUCH.
struct Wing {
    var cx: CGFloat; var cy: CGFloat       // center
    var w: CGFloat; var h: CGFloat         // ellipse size
    var rotation: CGFloat                  // degrees, flipped-space
}

// Rotation convention: positive = clockwise on screen (CSS/SwiftUI-style),
// which in this flipped CG context maps directly to ctx.rotate(by:).
let upperLeftWing  = Wing(cx: 0.300, cy: 0.330, w: 0.42, h: 0.27, rotation: 35)
let lowerLeftWing  = Wing(cx: 0.365, cy: 0.650, w: 0.28, h: 0.20, rotation: -38)

// Body (unchanged from v1)
let bodyW: CGFloat = 0.06
let bodyH: CGFloat = 0.40
let bodyCenter = CGPoint(x: 0.50, y: 0.54)
let headRadius: CGFloat = 0.035
let headGap: CGFloat = 0.012               // gap between body top and head
let antennaLength: CGFloat = 0.100         // vertical reach of antennae
let antennaSpread: CGFloat = 0.080         // horizontal reach of antennae
let antennaTipRadius: CGFloat = 0.008

// Stroke — fine, elegant white contour
let strokeAlpha: CGFloat = 0.95
let strokeWidth: CGFloat = 9               // 8–10 px at 1024
let antennaWidth: CGFloat = 6

// Grain — seeded stippling clipped strictly inside the butterfly shapes.
// Alpha & density ramp up toward shape edges (dotwork volume).
let grainSeed: Int32 = 42
let grainWingPoints = 175_000              // dots inside the four wings
let grainBodyPoints = 18_000               // dots inside body capsule + head
let grainMaxAttempts = 3_000_000
let grainMinAlpha: CGFloat = 0.04
let grainMaxAlpha: CGFloat = 0.30
let grainMinSize: CGFloat = 1.0
let grainMaxSize: CGFloat = 2.5
let grainEdgeFalloff: CGFloat = 1.35       // alpha ∝ r^falloff (r = 0 center → 1 edge)
let grainKeepFloor: CGFloat = 0.38         // keep probability at shape center
let grainAlphaSteps = 48                   // quantized color table (perf)

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

// MARK: - Butterfly paths -----------------------------------------------------

/// One wing ellipse as a CGPath in canvas coordinates.
func wingPath(_ wing: Wing, mirrored: Bool) -> CGPath {
    let cx = mirrored ? 1 - wing.cx : wing.cx
    let rotation = mirrored ? -wing.rotation : wing.rotation
    let center = sq(cx, wing.cy)
    let w = sqLen(wing.w), h = sqLen(wing.h)
    var t = CGAffineTransform(translationX: center.x, y: center.y)
        .rotated(by: deg(rotation))
    return CGPath(ellipseIn: CGRect(x: -w / 2, y: -h / 2, width: w, height: h),
                  transform: &t)
}

let bodyRectCanvas: CGRect = {
    let w = sqLen(bodyW), h = sqLen(bodyH)
    let c = sq(bodyCenter.x, bodyCenter.y)
    return CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h)
}()

let bodyPath = CGPath(roundedRect: bodyRectCanvas,
                      cornerWidth: bodyRectCanvas.width / 2,
                      cornerHeight: bodyRectCanvas.width / 2,
                      transform: nil)

let headCenterCanvas: CGPoint = {
    let r = sqLen(headRadius)
    return CGPoint(x: bodyRectCanvas.midX,
                   y: bodyRectCanvas.minY - sqLen(headGap) - r)
}()

let headPath: CGPath = {
    let r = sqLen(headRadius)
    return CGPath(ellipseIn: CGRect(x: headCenterCanvas.x - r, y: headCenterCanvas.y - r,
                                    width: 2 * r, height: 2 * r),
                  transform: nil)
}()

let wingPaths: [CGPath] = [
    wingPath(upperLeftWing, mirrored: false),
    wingPath(upperLeftWing, mirrored: true),
    wingPath(lowerLeftWing, mirrored: false),
    wingPath(lowerLeftWing, mirrored: true),
]

/// The four wings combined (grain clip region, pass 1).
let wingsCombinedPath: CGPath = {
    let p = CGMutablePath()
    wingPaths.forEach { p.addPath($0) }
    return p
}()

/// Body capsule + head combined (knockout + grain clip region, pass 2).
let bodyHeadPath: CGPath = {
    let p = CGMutablePath()
    p.addPath(bodyPath)
    p.addPath(headPath)
    return p
}()

// MARK: - Grain density model ---------------------------------------------------
// Each shape is approximated by an ellipse; r = normalized radial coordinate
// (0 = center, 1 = edge). A point's grain alpha follows min(r) over all shapes,
// so dots near any shape edge glow stronger — dotwork volume.

struct EllipseShape {
    let center: CGPoint
    let a: CGFloat        // semi-axis x (local)
    let b: CGFloat        // semi-axis y (local)
    let rot: CGFloat      // radians

    func normRadius(_ p: CGPoint) -> CGFloat {
        let dx = p.x - center.x, dy = p.y - center.y
        let c = cos(-rot), s = sin(-rot)
        let lx = dx * c - dy * s
        let ly = dx * s + dy * c
        return sqrt((lx / a) * (lx / a) + (ly / b) * (ly / b))
    }
}

let wingShapes: [EllipseShape] = {
    var shapes: [EllipseShape] = []
    for (wing, mirrored) in [(upperLeftWing, false), (upperLeftWing, true),
                             (lowerLeftWing, false), (lowerLeftWing, true)] {
        let cx = mirrored ? 1 - wing.cx : wing.cx
        let rotation = mirrored ? -wing.rotation : wing.rotation
        shapes.append(EllipseShape(center: sq(cx, wing.cy),
                                   a: sqLen(wing.w) / 2, b: sqLen(wing.h) / 2,
                                   rot: deg(rotation)))
    }
    return shapes
}()

let bodyShapes: [EllipseShape] = [
    // Body capsule ≈ ellipse (density only; exact clipping handled by the path).
    EllipseShape(center: CGPoint(x: bodyRectCanvas.midX, y: bodyRectCanvas.midY),
                 a: bodyRectCanvas.width / 2, b: bodyRectCanvas.height / 2, rot: 0),
    EllipseShape(center: headCenterCanvas,
                 a: sqLen(headRadius), b: sqLen(headRadius), rot: 0),
]

func minNormRadius(_ p: CGPoint, over shapes: [EllipseShape]) -> CGFloat {
    var m = CGFloat.greatestFiniteMagnitude
    for s in shapes { m = min(m, s.normRadius(p)) }
    return min(m, 1)
}

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

ctx.saveGState()
ctx.addPath(squirclePath)
ctx.clip()

// MARK: - 1. Background — near-black with a whisper of radial lift -------------

ctx.setFillColor(color(bgEdgeHex))
ctx.fill(squircleRect)

let bgGradient = makeGradient([color(bgCenterHex), color(bgEdgeHex)], [0.0, 1.0])
ctx.drawRadialGradient(
    bgGradient,
    startCenter: CGPoint(x: squircleRect.midX, y: squircleRect.midY), startRadius: 0,
    endCenter: CGPoint(x: squircleRect.midX, y: squircleRect.midY),
    endRadius: squircleSize * 0.72,
    options: []
)

// MARK: - 2. Grain machinery ----------------------------------------------------

srand48(Int(grainSeed))

// Quantized alpha → color table (avoids ~200k CGColor allocations).
let grainColors: [CGColor] = (0..<grainAlphaSteps).map { i in
    let t = CGFloat(i) / CGFloat(grainAlphaSteps - 1)
    return white(grainMinAlpha + (grainMaxAlpha - grainMinAlpha) * t)
}

func grainColorIndex(for alpha: CGFloat) -> Int {
    let t = (alpha - grainMinAlpha) / (grainMaxAlpha - grainMinAlpha)
    return max(0, min(grainAlphaSteps - 1, Int(round(t * CGFloat(grainAlphaSteps - 1)))))
}

var totalGrainPoints = 0
var totalGrainAttempts = 0

/// Stipple `target` dots strictly inside `clip`, alpha/density ramping toward
/// the edges of the approximating `shapes`.
func drawGrain(in clip: CGPath, shapes: [EllipseShape], target: Int) {
    ctx.saveGState()
    ctx.addPath(clip)
    ctx.clip()

    let bounds = clip.boundingBoxOfPath
    var drawn = 0
    var attempts = 0
    var lastColorIndex = -1

    while drawn < target && attempts < grainMaxAttempts {
        attempts += 1
        let p = CGPoint(x: bounds.minX + CGFloat(drand48()) * bounds.width,
                        y: bounds.minY + CGFloat(drand48()) * bounds.height)
        guard clip.contains(p) else { continue }

        let r = minNormRadius(p, over: shapes)

        // Density gradient: sparser at shape centers, denser toward edges.
        let keepProbability = grainKeepFloor + (1 - grainKeepFloor) * pow(r, 1.5)
        if CGFloat(drand48()) > keepProbability { continue }

        // Alpha gradient: faint at center → bright at edges, with per-dot jitter.
        let jitter = 0.4 + 0.6 * CGFloat(drand48())
        let alpha = grainMinAlpha + (grainMaxAlpha - grainMinAlpha) * pow(r, grainEdgeFalloff) * jitter

        // Dot size: 1–2.5 px, slightly larger dots allowed near edges.
        let size = grainMinSize + (grainMaxSize - grainMinSize) * CGFloat(drand48()) * (0.55 + 0.45 * r)

        let ci = grainColorIndex(for: alpha)
        if ci != lastColorIndex {
            ctx.setFillColor(grainColors[ci])
            lastColorIndex = ci
        }
        ctx.fillEllipse(in: CGRect(x: p.x - size / 2, y: p.y - size / 2,
                                   width: size, height: size))
        drawn += 1
    }

    ctx.restoreGState()
    totalGrainPoints += drawn
    totalGrainAttempts += attempts
}

/// Fill `path` with the exact background (knockout), so foreground shapes
/// cleanly mask anything drawn behind them.
func knockout(_ path: CGPath) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.setFillColor(color(bgEdgeHex))
    ctx.fill(path.boundingBoxOfPath)
    ctx.drawRadialGradient(
        bgGradient,
        startCenter: CGPoint(x: squircleRect.midX, y: squircleRect.midY), startRadius: 0,
        endCenter: CGPoint(x: squircleRect.midX, y: squircleRect.midY),
        endRadius: squircleSize * 0.72,
        options: []
    )
    ctx.restoreGState()
}

// MARK: - 3. Wings — grain, then crisp strokes ----------------------------------

drawGrain(in: wingsCombinedPath, shapes: wingShapes, target: grainWingPoints)

ctx.setStrokeColor(white(strokeAlpha))
ctx.setLineWidth(strokeWidth)
ctx.setLineJoin(.round)
for path in wingPaths {
    ctx.addPath(path)
    ctx.strokePath()
}

// MARK: - 4. Body & head — knockout wing lines behind, grain, strokes -----------

knockout(bodyHeadPath)
drawGrain(in: bodyHeadPath, shapes: bodyShapes, target: grainBodyPoints)

ctx.setStrokeColor(white(strokeAlpha))
ctx.setLineWidth(strokeWidth)
ctx.addPath(bodyPath)
ctx.strokePath()
ctx.addPath(headPath)
ctx.strokePath()

// MARK: - 5. Antennae — thin white curves with a dot at each tip ----------------

let headR = sqLen(headRadius)
let tipR = sqLen(antennaTipRadius)
ctx.setLineCap(.round)
ctx.setLineWidth(antennaWidth)
ctx.setStrokeColor(white(strokeAlpha))
ctx.setFillColor(white(strokeAlpha))

for side: CGFloat in [-1, 1] {
    let start = CGPoint(x: headCenterCanvas.x + side * headR * 0.35,
                        y: headCenterCanvas.y - headR * 0.7)
    let tip = CGPoint(x: headCenterCanvas.x + side * sqLen(antennaSpread),
                      y: headCenterCanvas.y - sqLen(antennaLength))
    let control = CGPoint(x: headCenterCanvas.x + side * sqLen(antennaSpread) * 0.15,
                          y: headCenterCanvas.y - sqLen(antennaLength) * 0.95)
    ctx.move(to: start)
    ctx.addQuadCurve(to: tip, control: control)
    ctx.strokePath()

    ctx.addEllipse(in: CGRect(x: tip.x - tipR, y: tip.y - tipR,
                              width: 2 * tipR, height: 2 * tipR))
    ctx.fillPath()
}

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
    print("Wrote \(outputPath) (\(pngData.count) bytes) — grain: \(totalGrainPoints) points, \(totalGrainAttempts) attempts")
} catch {
    fatalError("Could not write \(outputPath): \(error)")
}
