import AppKit
import Carbon.HIToolbox

// Shortcuts on keyboard layouts that don't type Latin letters, or that remap
// keys while ⌘ is held (such as macOS "Dvorak - QWERTY ⌘").
//
// Plain Dvorak, AZERTY, and US layouts type Latin and are left as-is; non-Latin
// layouts fall back to macOS's paired Latin layout on ⌘/⌃/⌥ chords; and
// "Dvorak - QWERTY ⌘" uses what the layout itself produces while ⌘ is held.

extension NSEvent {
    /// `charactersIgnoringModifiers`, lowercased, resolved through the paired Latin
    /// layout on non-Latin input sources and through `cmdKey` on hybrid layouts.
    var shortcutCharacters: String {
        KeyLayout.shortcut(
            keyCode,
            flags: modifierFlags,
            shift: modifierFlags.contains(.shift),
            typed: charactersIgnoringModifiers
        )
    }

    /// `characters(byApplyingModifiers: [])`, lowercased, resolved without ⇧.
    var shortcutKey: String {
        KeyLayout.shortcut(
            keyCode,
            flags: modifierFlags,
            shift: false,
            typed: characters(byApplyingModifiers: [])
        )
    }
}

enum KeyLayout {
    struct Layout {
        let data: Data
        let isLatin: Bool

        init?(_ source: TISInputSource) {
            guard let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
            data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
            isLatin = KeyLayout.isLatin(source)
        }

        init(data: Data, isLatin: Bool) {
            self.data = data
            self.isLatin = isLatin
        }

        func type(_ keyCode: UInt16, modifiers: Int, action: Int = kUCKeyActionDown) -> String? {
            data.withUnsafeBytes { raw -> String? in
                guard let base = raw.baseAddress else { return nil }
                let layout = base.assumingMemoryBound(to: UCKeyboardLayout.self)
                var dead: UInt32 = 0
                var length = 0
                var typed = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(
                    layout,
                    keyCode,
                    UInt16(action),
                    UInt32(modifiers >> 8) & 0xFF,
                    UInt32(LMGetKbdType()),
                    OptionBits(kUCKeyTranslateNoDeadKeysMask),
                    &dead,
                    typed.count,
                    &length,
                    &typed
                )
                guard status == noErr, length > 0 else { return nil }
                return String(utf16CodeUnits: typed, count: length)
            }
        }

        func underCommand(_ keyCode: UInt16, shift: Bool) -> String? {
            guard let plain = type(keyCode, modifiers: 0),
                  let command = type(keyCode, modifiers: cmdKey),
                  plain.lowercased() != command.lowercased()
            else { return nil }
            return (shift ? type(keyCode, modifiers: cmdKey | shiftKey) : command)?.lowercased()
        }
    }

    static func shortcut(
        _ keyCode: UInt16,
        flags: NSEvent.ModifierFlags,
        shift: Bool,
        typed: String?,
        current: Layout?,
        latin: () -> Layout?
    ) -> String {
        let fallback = typed?.lowercased() ?? ""
        guard !flags.isDisjoint(with: [.command, .control, .option]), let current else { return fallback }
        if !current.isLatin {
            return latin()?.type(keyCode, modifiers: shift ? shiftKey : 0, action: kUCKeyActionDisplay)?
                .lowercased() ?? fallback
        }
        if flags.contains(.command), let key = current.underCommand(keyCode, shift: shift) {
            return key
        }
        return fallback
    }

    static func shortcut(_ keyCode: UInt16, flags: NSEvent.ModifierFlags, shift: Bool, typed: String?) -> String {
        guard !flags.isDisjoint(with: [.command, .control, .option]) else { return typed?.lowercased() ?? "" }
        return shortcut(keyCode, flags: flags, shift: shift, typed: typed, current: inUse, latin: pairedLatin)
    }

    private static var inUse: Layout? {
        guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        let keys = TISCopyCurrentKeyboardLayoutInputSource().flatMap { Layout($0.takeRetainedValue()) }
        return Layout(data: keys?.data ?? Data(), isLatin: isLatin(current))
    }

    private static func pairedLatin() -> Layout? {
        TISCopyCurrentASCIICapableKeyboardLayoutInputSource().flatMap { Layout($0.takeRetainedValue()) }
    }

    private static func isLatin(_ source: TISInputSource) -> Bool {
        guard let list = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else { return false }
        let languages = Unmanaged<CFArray>.fromOpaque(list).takeUnretainedValue() as? [String] ?? []
        return languages.contains { $0 == "en" || $0.hasPrefix("en-") }
            || languages.contains {
                let code = Locale.Language(identifier: $0).languageCode?.identifier ?? ""
                return ["fr", "de", "es", "it", "pt", "nl", "sv", "no", "nb", "nn", "da", "fi",
                        "pl", "cs", "sk", "hu", "ro", "tr", "id", "ms", "vi", "ca", "gl", "eu"].contains(code)
            }
    }
}
