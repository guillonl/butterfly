import AppKit
import Carbon.HIToolbox

/// Un raccourci clavier : keyCode matériel + modificateurs NSEvent.
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifierFlags: UInt  // NSEvent.ModifierFlags.rawValue

    var modifiers: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifierFlags).intersection([.command, .option, .control, .shift])
    }

    /// Conversion vers les modificateurs Carbon pour RegisterEventHotKey.
    var carbonModifiers: UInt32 {
        var result: UInt32 = 0
        if modifiers.contains(.command) { result |= UInt32(cmdKey) }
        if modifiers.contains(.option) { result |= UInt32(optionKey) }
        if modifiers.contains(.control) { result |= UInt32(controlKey) }
        if modifiers.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    /// "⌃⌥⌘B" : affichage humain, dans l'ordre standard macOS.
    var display: String {
        var symbols = ""
        if modifiers.contains(.control) { symbols += "⌃" }
        if modifiers.contains(.option) { symbols += "⌥" }
        if modifiers.contains(.shift) { symbols += "⇧" }
        if modifiers.contains(.command) { symbols += "⌘" }
        return symbols + Self.keyName(for: keyCode)
    }

    /// Au moins un vrai modificateur (⌘/⌥/⌃) pour ne pas avaler une touche normale.
    var isValid: Bool {
        !modifiers.intersection([.command, .option, .control]).isEmpty
    }

    /// Nom de la touche selon la disposition clavier COURANTE (AZERTY ok).
    static func keyName(for keyCode: UInt32) -> String {
        let specials: [UInt32: String] = [
            UInt32(kVK_Space): "Espace", UInt32(kVK_Return): "↩",
            UInt32(kVK_Tab): "⇥", UInt32(kVK_Escape): "⎋",
            UInt32(kVK_Delete): "⌫", UInt32(kVK_ForwardDelete): "⌦",
            UInt32(kVK_LeftArrow): "←", UInt32(kVK_RightArrow): "→",
            UInt32(kVK_UpArrow): "↑", UInt32(kVK_DownArrow): "↓",
            UInt32(kVK_Home): "↖", UInt32(kVK_End): "↘",
            UInt32(kVK_PageUp): "⇞", UInt32(kVK_PageDown): "⇟",
            UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3",
            UInt32(kVK_F4): "F4", UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6",
            UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8", UInt32(kVK_F9): "F9",
            UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
        ]
        if let special = specials[keyCode] { return special }

        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return "#\(keyCode)"
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutPointer).takeUnretainedValue() as Data
        let name: String = layoutData.withUnsafeBytes { rawBuffer in
            guard let layout = rawBuffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return "" }
            var deadKeyState: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let error = UCKeyTranslate(
                layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState, chars.count, &length, &chars
            )
            guard error == noErr, length > 0 else { return "" }
            return String(utf16CodeUnits: chars, count: length)
        }
        return name.isEmpty ? "#\(keyCode)" : name.uppercased()
    }
}

/// Les deux actions déclenchables par raccourci global.
enum HotKeyAction: UInt32, CaseIterable {
    case capture = 1    // loupe à l'écran
    case selection = 2  // texte déjà sélectionné dans l'app frontale

    var defaultsKey: String {
        switch self {
        case .capture: return "shortcutCapture"
        case .selection: return "shortcutSelection"
        }
    }

    var defaultShortcut: Shortcut {
        switch self {
        case .capture:
            return Shortcut(keyCode: UInt32(kVK_ANSI_B),
                            modifierFlags: NSEvent.ModifierFlags([.option, .command]).rawValue)
        case .selection:
            return Shortcut(keyCode: UInt32(kVK_ANSI_B),
                            modifierFlags: NSEvent.ModifierFlags([.control, .command]).rawValue)
        }
    }
}

/// Persistance des raccourcis dans UserDefaults.
enum ShortcutStore {
    static func shortcut(for action: HotKeyAction) -> Shortcut {
        guard let data = UserDefaults.standard.data(forKey: action.defaultsKey),
              let decoded = try? JSONDecoder().decode(Shortcut.self, from: data) else {
            return action.defaultShortcut
        }
        return decoded
    }

    static func save(_ shortcut: Shortcut, for action: HotKeyAction) {
        guard let data = try? JSONEncoder().encode(shortcut) else { return }
        UserDefaults.standard.set(data, forKey: action.defaultsKey)
    }
}
