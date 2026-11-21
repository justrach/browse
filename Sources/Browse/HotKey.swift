import AppKit
import Carbon.HIToolbox

// One key that reaches browse from whichever app is in front: brings the
// browser forward and opens the address bar (Settings › Shortcuts).
//
// Carbon's hot keys are how macOS gives an app a system-wide shortcut without
// Accessibility permission or watching every keystroke: macOS hands over only
// this one combination, only while it is registered.

/// "BrwH", for telling this key's events from anyone else's.
private let browseHotKeySignature: OSType = 0x4272_7748

@MainActor
enum HotKey {
    private static var registered: EventHotKeyRef?
    private static var handler: EventHandlerRef?
    private static var current: (code: UInt32, modifiers: UInt32)?

    /// Called on the main thread each time the global shortcut is pressed.
    static var pressed: (() -> Void)?

    /// Carbon's modifier flags for a recorded KeyCombo.
    nonisolated static func modifiers(of combo: KeyCombo) -> UInt32 {
        var flags: UInt32 = 0
        if combo.command { flags |= UInt32(cmdKey) }
        if combo.shift { flags |= UInt32(shiftKey) }
        if combo.option { flags |= UInt32(optionKey) }
        if combo.control { flags |= UInt32(controlKey) }
        return flags
    }

    @discardableResult
    static func set(code: UInt16, modifiers: UInt32) -> OSStatus {
        if let current, registered != nil, current.code == UInt32(code), current.modifiers == modifiers { return noErr }
        clear()
        installHandler()
        var key: EventHotKeyRef?
        let id = EventHotKeyID(signature: browseHotKeySignature, id: 1)
        let status = RegisterEventHotKey(UInt32(code), modifiers, id, GetApplicationEventTarget(), 0, &key)
        guard status == noErr, let key else { return status == noErr ? OSStatus(eventInternalErr) : status }
        registered = key
        current = (UInt32(code), modifiers)
        return noErr
    }

    static func clear() {
        if let registered { UnregisterEventHotKey(registered) }
        registered = nil
        current = nil
    }

    static var isSet: Bool { registered != nil }

    /// Whether macOS already owns this key in System Settings › Keyboard ›
    /// Keyboard Shortcuts (screenshots, Spotlight, Mission Control, etc.).
    static func usedByMacOS(code: UInt16, modifiers: UInt32) -> Bool {
        var list: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&list) == noErr,
              let entries = list?.takeRetainedValue() as? [[String: Any]] else { return false }
        return usedByMacOS(code: code, modifiers: modifiers, in: entries)
    }

    nonisolated static func usedByMacOS(code: UInt16, modifiers: UInt32, in entries: [[String: Any]]) -> Bool {
        let held = UInt32(cmdKey | shiftKey | optionKey | controlKey)
        return entries.contains { entry in
            guard entry[kHISymbolicHotKeyEnabled as String] as? Bool == true,
                  entry[kHISymbolicHotKeyCode as String] as? Int == Int(code),
                  let flags = entry[kHISymbolicHotKeyModifiers as String] as? Int else { return false }
            return UInt32(truncatingIfNeeded: flags) & held == modifiers & held
        }
    }

    private static func installHandler() {
        guard handler == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &id
            )
            guard status == noErr, id.signature == browseHotKeySignature else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async { HotKey.pressed?() }
            return noErr
        }, 1, &type, nil, &handler)
    }
}
