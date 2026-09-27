import AppKit
import ApplicationServices

/// A snapshot of what the user is working on, attached to each request so
/// "これ直して" or "さっきコピーしたやつ" make sense to Kon. Strictly read-only:
/// window titles and documents via Accessibility, Finder selection and
/// browser tabs via AppleScript, and the clipboard. Nothing is clicked or typed.
@MainActor
final class KonContextProvider {
    static let shared = KonContextProvider()

    private static let clipboardCharacterLimit = 1500
    private static let finderSelectionLimit = 20
    private static let appleScriptTimeout: Duration = .seconds(1.5)

    /// The last app other than Konsole the user was in. Typed chat activates
    /// Konsole, so "frontmost" at send time would always be Konsole itself.
    private var lastExternalApp: NSRunningApplication?
    private var activationObserver: NSObjectProtocol?

    private init() {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ownPID {
            lastExternalApp = front
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != ownPID else { return }
            MainActor.assumeIsolated { self?.lastExternalApp = app }
        }
    }

    /// Needed for window titles and open documents; everything else works without it.
    var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    /// Plain-text lines describing the current work context, or nil when
    /// sharing is off or there's nothing to say.
    func snapshot() async -> String? {
        let settings = KonSettings.shared
        var lines: [String] = []

        if settings.sharesAppContext, let app = lastExternalApp, !app.isTerminated {
            var line = "前面のアプリ: \(app.localizedName ?? app.bundleIdentifier ?? "不明")"
            let window = focusedWindowInfo(of: app)
            if let title = window.title, !title.isEmpty {
                line += "（ウィンドウ: \(title)）"
            }
            lines.append(line)
            if let document = window.documentPath {
                lines.append("開いているファイル: \(document)")
            }
            if let bundleId = app.bundleIdentifier {
                lines += await appSpecificLines(bundleId: bundleId)
            }
        }

        if settings.sharesClipboard, let clipboard = clipboardText() {
            lines.append("クリップボード:\n\(clipboard)")
        }

        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    // MARK: - Accessibility

    private func focusedWindowInfo(of app: NSRunningApplication) -> (title: String?, documentPath: String?) {
        guard isAccessibilityTrusted else { return (nil, nil) }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &windowValue) == .success,
              let windowValue, CFGetTypeID(windowValue) == AXUIElementGetTypeID() else { return (nil, nil) }
        let window = windowValue as! AXUIElement

        let title = stringAttribute(kAXTitleAttribute, of: window)
        // Document-based apps (Xcode, TextEdit, Preview, ...) expose the file URL.
        let documentPath = stringAttribute(kAXDocumentAttribute, of: window)
            .flatMap(URL.init(string:))
            .flatMap { $0.isFileURL ? $0.path(percentEncoded: false) : nil }
        return (title, documentPath)
    }

    private func stringAttribute(_ attribute: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    // MARK: - AppleScript

    private static let chromiumBrowsers: Set<String> = [
        "com.google.Chrome", "company.thebrowser.Browser", "com.brave.Browser",
        "com.microsoft.edgemac", "com.vivaldi.Vivaldi"
    ]

    private func appSpecificLines(bundleId: String) async -> [String] {
        switch bundleId {
        case "com.apple.finder":
            guard let output = await Self.runAppleScript(Self.finderSelectionScript) else { return [] }
            let paths = output.split(separator: "\n").map(String.init)
            guard !paths.isEmpty else { return [] }
            return ["Finderで選択中: " + paths.joined(separator: ", ")]
        case "com.apple.Safari":
            return Self.browserLines(await Self.runAppleScript("""
            tell application id "com.apple.Safari" to return (URL of current tab of front window) & linefeed & (name of current tab of front window)
            """))
        case _ where Self.chromiumBrowsers.contains(bundleId):
            return Self.browserLines(await Self.runAppleScript("""
            tell application id "\(bundleId)" to return (URL of active tab of front window) & linefeed & (title of active tab of front window)
            """))
        default:
            return []
        }
    }

    /// Selected items, or the open folder when nothing is selected.
    private static let finderSelectionScript = """
    tell application id "com.apple.finder"
        set out to ""
        set n to 0
        repeat with f in (selection as alias list)
            set out to out & POSIX path of f & linefeed
            set n to n + 1
            if n ≥ \(finderSelectionLimit) then exit repeat
        end repeat
        if out is "" then
            try
                set out to POSIX path of (target of front Finder window as alias)
            end try
        end if
        return out
    end tell
    """

    private static func browserLines(_ output: String?) -> [String] {
        guard let output else { return [] }
        let parts = output.split(separator: "\n", maxSplits: 1).map(String.init)
        guard let url = parts.first, !url.isEmpty else { return [] }
        var lines = ["ブラウザで表示中: \(url)"]
        if parts.count > 1 { lines.append("ページタイトル: \(parts[1])") }
        return lines
    }

    /// Runs off the main thread and gives up after a short timeout, so a busy
    /// app or a pending Automation permission prompt can't stall the request.
    private static func runAppleScript(_ source: String) async -> String? {
        await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            Task.detached {
                var error: NSDictionary?
                let result = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue
                once.resume(result?.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            Task.detached {
                try? await Task.sleep(for: appleScriptTimeout)
                once.resume(nil)
            }
        }
    }

    // MARK: - Clipboard

    private func clipboardText() -> String? {
        let pasteboard = NSPasteboard.general
        // Password managers mark secrets so clipboard tools skip them (nspasteboard.org).
        let skipped: Set<String> = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"]
        if pasteboard.types?.contains(where: { skipped.contains($0.rawValue) }) == true { return nil }
        guard let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text.count > Self.clipboardCharacterLimit
            ? String(text.prefix(Self.clipboardCharacterLimit)) + "…（以下省略）"
            : text
    }
}

/// Resumes a continuation exactly once, whichever of several racers finishes first.
private nonisolated final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: T) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }
}
