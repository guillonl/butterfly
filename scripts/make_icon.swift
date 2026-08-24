#!/usr/bin/env swift
import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = root.appendingPathComponent("assets/Butterfly-icon-master.png")
let output = CommandLine.arguments.dropFirst().first.map(URL.init(fileURLWithPath:))
    ?? root.appendingPathComponent("assets/icon_1024.png")

guard let input = NSImage(contentsOf: source) else {
    FileHandle.standardError.write(Data("master Butterfly introuvable : \(source.path)\n".utf8))
    exit(1)
}

let pixels = 1024
guard let representation = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: pixels,
    pixelsHigh: pixels,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else { exit(1) }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
NSGraphicsContext.current?.imageInterpolation = .high
input.draw(
    in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
    from: .zero,
    operation: .copy,
    fraction: 1
)
NSGraphicsContext.restoreGraphicsState()

guard let png = representation.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: output)
print("icone Butterfly ecrite dans \(output.path)")
