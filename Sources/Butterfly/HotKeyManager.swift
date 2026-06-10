import AppKit
import Carbon.HIToolbox

/// Raccourcis globaux via l'API Carbon RegisterEventHotKey.
/// Contrairement aux NSEvent global monitors, cette API ne demande
/// aucune permission Accessibilité. Gère plusieurs raccourcis,
/// ré-enregistrables à chaud (réglages).
final class HotKeyManager {
    static let shared = HotKeyManager()

    var handlers: [HotKeyAction: () -> Void] = [:]

    private var hotKeyRefs: [HotKeyAction: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?
    private let signature = OSType(0x4254_4659) // 'BTFY'

    /// Installe le handler d'événements puis enregistre les raccourcis stockés.
    func start() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let userData, let event else { return noErr }
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event, EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
                )
                let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                guard let action = HotKeyAction(rawValue: hotKeyID.id) else { return noErr }
                DispatchQueue.main.async { manager.handlers[action]?() }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )

        for action in HotKeyAction.allCases {
            apply(ShortcutStore.shortcut(for: action), for: action)
        }
    }

    /// (Ré)enregistre un raccourci pour une action. Retourne false si le
    /// système refuse (combinaison déjà prise par un autre processus).
    @discardableResult
    func apply(_ shortcut: Shortcut, for action: HotKeyAction) -> Bool {
        if let existing = hotKeyRefs[action] {
            UnregisterEventHotKey(existing)
            hotKeyRefs[action] = nil
        }
        let hotKeyID = EventHotKeyID(signature: signature, id: action.rawValue)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else { return false }
        hotKeyRefs[action] = ref
        return true
    }
}
