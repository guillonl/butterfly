import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Récupère le texte sélectionné dans l'application frontale.
/// Stratégie : API Accessibilité d'abord (propre, ne touche pas au
/// presse-papiers), sinon simulation de ⌘C avec sauvegarde/restauration
/// du presse-papiers. Les deux voies exigent la permission Accessibilité.
enum SelectedTextService {

    static var hasPermission: Bool {
        AXIsProcessTrusted()
    }

    /// Affiche la demande système si la permission manque.
    static func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    static func fetchSelectedText() async -> String? {
        if let text = accessibilitySelectedText(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        return await pasteboardSelectedText()
    }

    // MARK: - Voie 1 : Accessibilité

    private static func accessibilitySelectedText() -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef else { return nil }
        let element = focused as! AXUIElement

        var selectedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selectedRef) == .success,
           let text = selectedRef as? String, !text.isEmpty {
            return text
        }
        return nil
    }

    // MARK: - Voie 2 : ⌘C silencieux

    /// Simule ⌘C, lit le presse-papiers, puis restaure son contenu texte
    /// d'origine pour rester discret.
    private static func pasteboardSelectedText() async -> String? {
        let pasteboard = NSPasteboard.general
        let savedString = pasteboard.string(forType: .string)
        let savedChangeCount = pasteboard.changeCount

        postCommandC()

        // Attendre que l'app frontale écrive dans le presse-papiers (max ~1 s)
        var copied: String?
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            if pasteboard.changeCount != savedChangeCount {
                copied = pasteboard.string(forType: .string)
                break
            }
        }

        // Restaurer le presse-papiers d'origine
        if copied != nil {
            pasteboard.clearContents()
            if let savedString {
                pasteboard.setString(savedString, forType: .string)
            }
        }

        guard let copied, !copied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return copied
    }

    private static func postCommandC() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}
