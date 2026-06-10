import AppKit
import ScreenCaptureKit

enum CaptureError: LocalizedError {
    case noDisplay
    case noPermission

    var errorDescription: String? {
        switch self {
        case .noDisplay: return "No display found"
        case .noPermission: return "Screen recording permission missing"
        }
    }
}

/// Écran gelé : l'image capturée + l'écran d'origine.
struct CapturedScreen {
    let image: CGImage
    let screen: NSScreen

    var scale: CGFloat { screen.backingScaleFactor }
    var logicalSize: CGSize { screen.frame.size }
}

enum ScreenCaptureService {

    static func screenWithMouse() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    static var hasPermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    static func requestPermission() {
        CGRequestScreenCaptureAccess()
    }

    /// Capture l'écran complet sous la souris, en pleine résolution Retina,
    /// AVANT que l'overlay ne s'affiche (image gelée propre, sans curseur).
    static func captureScreenUnderMouse() async throws -> CapturedScreen {
        let screen = screenWithMouse()
        guard let idNum = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            throw CaptureError.noDisplay
        }
        let displayID = CGDirectDisplayID(idNum.uint32Value)

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID })
            ?? content.displays.first else {
            throw CaptureError.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        let scale = screen.backingScaleFactor
        config.width = Int(CGFloat(display.width) * scale)
        config.height = Int(CGFloat(display.height) * scale)
        config.showsCursor = false
        config.captureResolution = .best

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return CapturedScreen(image: image, screen: screen)
    }

    /// Recadre la capture sur la sélection (coordonnées logiques, origine en haut à gauche).
    static func crop(_ capture: CapturedScreen, to rectTopLeft: CGRect) -> CGImage? {
        let s = capture.scale
        // Le CGImage et SwiftUI partagent la même origine (haut-gauche) :
        // une simple mise à l'échelle suffit.
        let pixelRect = CGRect(
            x: rectTopLeft.origin.x * s,
            y: rectTopLeft.origin.y * s,
            width: rectTopLeft.width * s,
            height: rectTopLeft.height * s
        ).integral
        return capture.image.cropping(to: pixelRect)
    }
}
