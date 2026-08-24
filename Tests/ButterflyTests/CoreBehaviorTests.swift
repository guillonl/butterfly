import AppKit
import Testing
@testable import Butterfly

@Suite("Comportements de base")
struct CoreBehaviorTests {
    @Test("nettoie les préambules et conserve une seule variante")
    @MainActor
    func cleansModelOutput() {
        #expect(TextEngine.cleanedResult("Voici la correction : 1. \"Bonjour\"\n2. \"Salut\"", singleResult: true) == "Bonjour")
    }

    @Test("le redimensionnement respecte la taille minimale")
    @MainActor
    func resizeClampsToMinimum() {
        let frame = PanelResizeView.resizedFrame(
            startFrame: NSRect(x: 100, y: 100, width: 440, height: 390),
            edges: .right,
            dx: -1_000,
            dy: 0,
            minSize: NSSize(width: 380, height: 280)
        )
        #expect(frame.width == 380)
        #expect(frame.minX == 100)
    }
}
