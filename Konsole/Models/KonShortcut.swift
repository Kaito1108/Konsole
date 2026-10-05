import AppKit
import Carbon

/// A user-configurable global shortcut: a virtual key code plus Carbon modifier
/// flags (the form RegisterEventHotKey takes).
struct KonShortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    /// Display name of the key itself, captured when it was recorded.
    var keyName: String

    static let defaultPushToTalk = KonShortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey), keyName: "Space")
    static let defaultCancel = KonShortcut(keyCode: UInt32(kVK_Escape), modifiers: 0, keyName: "esc")
    static let defaultTextInput = KonShortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey | shiftKey), keyName: "Space")

    init(keyCode: UInt32, modifiers: UInt32, keyName: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyName = keyName
    }

    init(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: UInt32 = 0
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        self.init(
            keyCode: UInt32(event.keyCode),
            modifiers: modifiers,
            keyName: Self.specialKeyNames[Int(event.keyCode)]
                ?? event.charactersIgnoringModifiers?.uppercased()
                ?? "Key \(event.keyCode)"
        )
    }

    /// Modifier symbols in the standard macOS order, followed by the key.
    var displayKeys: [String] {
        var keys: [String] = []
        if modifiers & UInt32(controlKey) != 0 { keys.append("⌃") }
        if modifiers & UInt32(optionKey) != 0 { keys.append("⌥") }
        if modifiers & UInt32(shiftKey) != 0 { keys.append("⇧") }
        if modifiers & UInt32(cmdKey) != 0 { keys.append("⌘") }
        keys.append(keyName)
        return keys
    }

    var displayString: String { displayKeys.joined() }

    var isFunctionKey: Bool { Self.functionKeyCodes.contains(Int(keyCode)) }

    private static let functionKeyCodes: Set<Int> = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]

    private static let specialKeyNames: [Int: String] = [
        kVK_Space: "Space", kVK_Escape: "esc", kVK_Return: "↩", kVK_Tab: "⇥",
        kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_LeftArrow: "←", kVK_RightArrow: "→",
        kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Home: "↖", kVK_End: "↘",
        kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17",
        kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]
}
