import AppKit
import Carbon.HIToolbox

/// Raccourci global ⌥⌘B via l'API Carbon RegisterEventHotKey.
/// Contrairement aux NSEvent global monitors, cette API ne demande
/// aucune permission Accessibilité.
final class HotKeyManager {
    static let shared = HotKeyManager()

    var onHotKey: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    func register() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData -> OSStatus in
                guard let userData else { return noErr }
                let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { manager.onHotKey?() }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )

        // 'BTFY'
        let hotKeyID = EventHotKeyID(signature: OSType(0x4254_4659), id: 1)
        RegisterEventHotKey(
            UInt32(kVK_ANSI_B),
            UInt32(optionKey | cmdKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }
}
