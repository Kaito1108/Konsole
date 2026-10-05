import Carbon
import Foundation

/// Registers system-wide keyboard shortcuts via the classic Carbon hot key API —
/// still the standard way to get a permission-free global shortcut on macOS
/// (no Accessibility/Input Monitoring prompt required, unlike an NSEvent
/// global monitor). Key combos come from KonSettings (⌥Space / ⌥⇧Space /
/// Escape by default); the cancel key is registered only while Kon is busy or
/// the text box is open, so it isn't swallowed from other apps the rest of the time.
final class KonHotKeyManager {
    static let shared = KonHotKeyManager()

    enum HotKey: UInt32 {
        case pushToTalk = 1
        case cancel = 2
        case textInput = 3

        var shortcut: KonShortcut {
            switch self {
            case .pushToTalk: return KonSettings.shared.pushToTalkShortcut
            case .cancel: return KonSettings.shared.cancelShortcut
            case .textInput: return KonSettings.shared.textInputShortcut
            }
        }
    }

    private static let signature: FourCharCode = {
        "KonH".utf16.reduce(FourCharCode(0)) { ($0 << 8) + FourCharCode($1) }
    }()

    private var handlers: [UInt32: () -> Void] = [:]
    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?
    /// While suspended (e.g. recording a new shortcut in Settings) handlers are
    /// kept but no key combos are grabbed, so the keys reach the recorder.
    private var isSuspended = false

    func register(_ hotKey: HotKey, handler: @escaping () -> Void) {
        installEventHandlerIfNeeded()
        unregister(hotKey)
        handlers[hotKey.rawValue] = handler
        if !isSuspended {
            grab(hotKey)
        }
    }

    func unregister(_ hotKey: HotKey) {
        release(hotKey)
        handlers[hotKey.rawValue] = nil
    }

    /// Re-grabs a registered hotkey after its shortcut changed in Settings.
    func refresh(_ hotKey: HotKey) {
        guard handlers[hotKey.rawValue] != nil, !isSuspended else { return }
        release(hotKey)
        grab(hotKey)
    }

    func suspend() {
        guard !isSuspended else { return }
        isSuspended = true
        for id in Array(hotKeyRefs.keys) {
            if let hotKey = HotKey(rawValue: id) { release(hotKey) }
        }
    }

    func resume() {
        guard isSuspended else { return }
        isSuspended = false
        for id in handlers.keys {
            if let hotKey = HotKey(rawValue: id) { grab(hotKey) }
        }
    }

    private func grab(_ hotKey: HotKey) {
        var ref: EventHotKeyRef?
        let shortcut = hotKey.shortcut
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: hotKey.rawValue)
        RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if let ref {
            hotKeyRefs[hotKey.rawValue] = ref
        }
    }

    private func release(_ hotKey: HotKey) {
        if let ref = hotKeyRefs.removeValue(forKey: hotKey.rawValue) {
            UnregisterEventHotKey(ref)
        }
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: OSType(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return noErr }
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                let manager = Unmanaged<KonHotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                manager.handlers[hotKeyID.id]?()
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
    }
}
