import AppKit
import Observation

/// Rebuilds Konsole from the source folder it was built from and replaces
/// /Applications/Konsole.app, by running scripts/install.sh. On success the
/// script quits this app and opens the new one; on failure we stay running
/// and show why.
@MainActor
@Observable
final class KonUpdater {
    static let shared = KonUpdater()

    enum State: Equatable {
        case idle
        case building
        case failed(String)
    }

    private(set) var state: State = .idle

    nonisolated static let logURL = URL.libraryDirectory
        .appending(path: "Logs/Konsole", directoryHint: .isDirectory)
        .appending(path: "update.log")

    /// Baked in at build time from $(SRCROOT) via Konsole-Info.plist.
    var sourceRoot: URL? {
        guard let path = Bundle.main.object(forInfoDictionaryKey: "KonSourceRoot") as? String,
              !path.isEmpty, !path.hasPrefix("$(") else { return nil }
        return URL(filePath: path, directoryHint: .isDirectory)
    }

    private var scriptURL: URL? {
        sourceRoot?.appending(path: "scripts/install.sh")
    }

    private init() {}

    func update() {
        guard state != .building else { return }
        guard let scriptURL, FileManager.default.fileExists(atPath: scriptURL.path(percentEncoded: false)) else {
            state = .failed("ソースフォルダが見つかりません（\(sourceRoot?.path(percentEncoded: false) ?? "不明")）。移動した場合は一度 scripts/install.sh を手動で実行してください。")
            return
        }

        let log: FileHandle
        do {
            try FileManager.default.createDirectory(at: Self.logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: Self.logURL.path(percentEncoded: false), contents: nil)
            log = try FileHandle(forWritingTo: Self.logURL)
        } catch {
            state = .failed("ログファイルを作れませんでした: \(error.localizedDescription)")
            return
        }

        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = [scriptURL.path(percentEncoded: false)]
        // A file, not a pipe: the script outlives this app once it quits us,
        // and writing to a pipe whose reader is gone would kill it.
        process.standardOutput = log
        process.standardError = log
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
        process.environment = environment
        process.terminationHandler = { process in
            let status = process.terminationStatus
            Task { @MainActor in
                try? log.close()
                // Success normally never gets here: the script quits us first.
                KonUpdater.shared.state = status == 0 ? .idle : .failed(Self.failureSummary())
            }
        }

        do {
            try process.run()
            state = .building
        } catch {
            try? log.close()
            state = .failed("更新を始められませんでした: \(error.localizedDescription)")
        }
    }

    func revealLog() {
        NSWorkspace.shared.activateFileViewerSelecting([Self.logURL])
    }

    /// The first compiler errors, or the log's tail when there are none.
    private static func failureSummary() -> String {
        let text = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        let lines = text.split(separator: "\n").map(String.init)
        let errors = lines.filter { $0.contains("error:") }
        let picked = errors.isEmpty ? Array(lines.suffix(5)) : Array(errors.prefix(3))
        return picked.isEmpty ? "ビルドに失敗しました。" : "ビルドに失敗しました:\n" + picked.joined(separator: "\n")
    }
}
