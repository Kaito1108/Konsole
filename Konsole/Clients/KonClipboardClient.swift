import AppKit

/// Hands Kon's answers back to the user via the clipboard. Kon stops here on
/// purpose: it never types or pastes into other apps itself.
enum KonClipboardClient {
    @MainActor
    static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
