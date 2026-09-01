import AppKit
import Carbon.HIToolbox

/// Insertion de texte au curseur de l'app frontale : presse-papiers +
/// ⌘V simulé + restauration, avec marquage « concealed » pour que les
/// gestionnaires de presse-papiers ignorent le contenu transitoire.
/// (Mécanique identique à Wispr Flow, la plus robuste inter-apps.)
enum PasteService {
    /// Type pasteboard conventionnel : contenu à ne pas historiser.
    private static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    /// Colle `text` dans l'app frontale. Restaure le presse-papiers ensuite.
    @MainActor
    static func insert(_ text: String) async {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboard.setString("", forType: concealed)

        postCommandV()

        // Laisser l'app cible consommer le collage avant de restaurer.
        try? await Task.sleep(nanoseconds: 400_000_000)
        pasteboard.clearContents()
        if let saved {
            pasteboard.setString(saved, forType: .string)
        }
    }

    private static func postCommandV() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}
