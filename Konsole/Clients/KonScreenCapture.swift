import AppKit
import ApplicationServices
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Takes a still of the window the user is looking at, so Kon can answer
/// "このエラー何？" by reading the image file with its Read tool. Strictly
/// read-only: a picture is written to a private temp folder for one request
/// and deleted afterwards. Nothing is clicked or typed.
@MainActor
final class KonScreenCapture {
    static let shared = KonScreenCapture()

    /// Where screenshots live while a request is in flight. Passed to the CLI
    /// with --add-dir so reading one doesn't need a permission prompt.
    nonisolated static let directory = FileManager.default.temporaryDirectory
        .appending(path: "KonScreen", directoryHint: .isDirectory)

    /// Long side in pixels. Enough to read an error dialog or a code editor,
    /// small enough that Kon looking at it stays quick.
    private static let maxPixelSize = 1600.0
    private static let jpegQuality = 0.8

    private init() {
        // Leftovers from a crash or a force quit mid-request. Only the files:
        // the running CLI may already have been pointed at the folder.
        let leftovers = (try? FileManager.default.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: nil)) ?? []
        leftovers.forEach(Self.discard)
    }

    /// Creates the screenshot folder and returns its path, for --add-dir.
    /// Owner-only: what's on screen shouldn't be readable by other accounts.
    nonisolated static func preparedDirectoryPath() -> String {
        let path = directory.path(percentEncoded: false)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return path
    }

    /// Screen Recording permission. Checking never prompts.
    var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system prompt the first time; after that macOS only lets the
    /// user flip it in System Settings, so open that pane instead.
    func requestPermission() {
        guard !CGRequestScreenCaptureAccess() else { return }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Captures the focused window of `app` to a JPEG and returns its file.
    /// Nil when permission is missing or the window can't be found — the
    /// request then goes ahead on the text context alone.
    func captureFocusedWindow(of app: NSRunningApplication, focusedFrame: CGRect?) async -> URL? {
        guard hasPermission else { return nil }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard let window = Self.focusedWindow(in: content, pid: app.processIdentifier, focusedFrame: focusedFrame) else {
                return nil
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let configuration = SCStreamConfiguration()
            let scale = min(
                Double(filter.pointPixelScale),
                Self.maxPixelSize / max(filter.contentRect.width, filter.contentRect.height, 1)
            )
            configuration.width = Int(filter.contentRect.width * scale)
            configuration.height = Int(filter.contentRect.height * scale)
            configuration.showsCursor = false
            configuration.ignoreShadowsSingleWindow = true
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            return Self.writeJPEG(image)
        } catch {
            return nil
        }
    }

    /// Removes a screenshot once its request is done. Safe to call with nil.
    nonisolated static func discard(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Private

    /// The window Accessibility says is focused, matched by frame (both use
    /// top-left global coordinates); otherwise the frontmost normal window.
    private static func focusedWindow(in content: SCShareableContent, pid: pid_t, focusedFrame: CGRect?) -> SCWindow? {
        let candidates = content.windows.filter {
            $0.owningApplication?.processID == pid
                && $0.windowLayer == 0
                && $0.frame.width > 40 && $0.frame.height > 40
        }
        if let focusedFrame,
           let match = candidates.first(where: { framesMatch($0.frame, focusedFrame) }) {
            return match
        }
        return candidates.first(where: \.isActive) ?? candidates.first
    }

    private static func framesMatch(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 4 && abs(a.minY - b.minY) < 4
            && abs(a.width - b.width) < 4 && abs(a.height - b.height) < 4
    }

    private static func writeJPEG(_ image: CGImage) -> URL? {
        _ = preparedDirectoryPath()
        let url = directory.appending(path: "window-\(UUID().uuidString).jpg")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        let options = [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return url
    }
}
