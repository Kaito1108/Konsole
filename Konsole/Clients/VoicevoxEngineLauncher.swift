import Foundation

enum VoicevoxEngineError: Error, LocalizedError {
    case engineNotFound
    case startupTimedOut

    var errorDescription: String? {
        switch self {
        case .engineNotFound:
            return "VOICEVOXエンジンが見つかりません。/Applications/VOICEVOX.app がインストールされているか確認してください。"
        case .startupTimedOut:
            return "VOICEVOXエンジンの起動がタイムアウトしました。"
        }
    }
}

struct VoicevoxVoice: Identifiable, Hashable, Sendable {
    let id: Int
    let name: String
}

/// Launches VOICEVOX's headless synthesis engine (bundled inside VOICEVOX.app,
/// no GUI window/Dock icon) as a background subprocess on first use, so
/// KonSpeechClient doesn't require the user to manually keep the VOICEVOX app open.
actor VoicevoxEngineLauncher {
    static let shared = VoicevoxEngineLauncher()

    private static let host = "127.0.0.1"
    private static let port = 50021
    static var baseURL: URL { URL(string: "http://\(host):\(port)")! }

    private var launchedProcess: Process?

    /// Ensures the engine is reachable, launching it if necessary. Once launched,
    /// the process is left running in the background for subsequent calls.
    func ensureRunning() async throws {
        if await Self.isReachable() { return }

        if launchedProcess == nil {
            try launchEngine()
        }

        try await waitUntilReachable()
    }

    private func launchEngine() throws {
        let executablePath = try resolveEnginePath()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.currentDirectoryURL = URL(fileURLWithPath: executablePath).deletingLastPathComponent()
        process.arguments = [
            "--host", Self.host,
            "--port", String(Self.port),
            "--cors_policy_mode", "localapps"
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        launchedProcess = process
    }

    private func waitUntilReachable(timeout: TimeInterval = 30) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await Self.isReachable() { return }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw VoicevoxEngineError.startupTimedOut
    }

    /// All installed voices as (display name, style id), e.g. ("WhiteCUL（ノーマル）", 23).
    func availableVoices() async throws -> [VoicevoxVoice] {
        try await ensureRunning()
        let (data, _) = try await URLSession.shared.data(from: Self.baseURL.appendingPathComponent("speakers"))
        struct Speaker: Decodable {
            struct Style: Decodable { let name: String; let id: Int }
            let name: String
            let styles: [Style]
        }
        return try JSONDecoder().decode([Speaker].self, from: data).flatMap { speaker in
            speaker.styles.map { VoicevoxVoice(id: $0.id, name: "\(speaker.name)（\($0.name)）") }
        }
    }

    private static func isReachable() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("version"))
        request.timeoutInterval = 2
        return (try? await URLSession.shared.data(for: request)) != nil
    }

    private func resolveEnginePath() throws -> String {
        let candidates = [
            "/Applications/VOICEVOX.app/Contents/Resources/vv-engine/run"
        ]
        if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return path
        }
        throw VoicevoxEngineError.engineNotFound
    }
}

