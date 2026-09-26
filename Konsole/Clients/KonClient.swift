import Foundation

enum KonClientError: Error, LocalizedError {
    case claudeExecutableNotFound
    case processLaunchFailed(String)
    case invalidResponse
    case agentError(String)

    var errorDescription: String? {
        switch self {
        case .claudeExecutableNotFound:
            return "claude CLIが見つかりません。インストール済みか確認してください。"
        case .processLaunchFailed(let message):
            return "claude CLIの起動に失敗しました: \(message)"
        case .invalidResponse:
            return "claude CLIの応答を解析できませんでした。"
        case .agentError(let message):
            return message
        }
    }
}

/// A completed turn: Kon's reply text plus a human-readable log of what it did
/// (derived from tool_use events in the CLI's stream-json output), so the UI
/// can show "何をしたか" alongside the reply.
struct KonReply {
    let text: String
    let actions: [String]
}

/// Drives Claude Code via the `claude` CLI subprocess (`-p --output-format stream-json`)
/// instead of the Python/TypeScript-only Agent SDK.
actor KonClient {
    /// Replies are read aloud and shown in a small bubble, so keep them short and plain.
    private static let systemPrompt = """
    あなたはユーザー専属の音声アシスタント「コン」です。返答はそのまま音声で読み上げられ、画面右上の小さな吹き出しに表示されます。
    - 返答は原則1〜3文、100文字程度までの話し言葉にする。結論から言う。
    - Markdown、箇条書き、見出し、コードブロック、URLの羅列は使わない。
    - 作業をした場合は、何をしたかと結果だけを一言で伝える。途中経過や長い説明は省く。
    - ユーザーが「詳しく」などと明示的に求めたときだけ長めに答えてよい。
    """

    private var claudeExecutablePath: String?
    private var sessionId: String?

    func send(_ prompt: String) async throws -> KonReply {
        let executablePath = try await resolveClaudeExecutablePath()

        var arguments = [
            "-p", prompt,
            "--output-format", "stream-json",
            "--verbose",
            "--permission-mode", "auto",
            "--append-system-prompt", Self.systemPrompt,
            // Skip the user-level MCP servers, plugins and hooks: loading them
            // cost ~5s of startup on every request (measured 8s → 3s for a
            // one-line reply). Kon gets its own MCP config when it needs one.
            "--strict-mcp-config",
            "--setting-sources", "project"
        ]
        if let sessionId {
            arguments += ["--resume", sessionId]
        }

        let outputData = try await runProcess(executablePath: executablePath, arguments: arguments)
        return try parseStream(outputData)
    }

    private func parseStream(_ data: Data) throws -> KonReply {
        guard let text = String(data: data, encoding: .utf8) else {
            throw KonClientError.invalidResponse
        }

        var actions: [String] = []
        var finalResult: String?
        var finalIsError = false

        for line in text.split(separator: "\n") {
            guard let lineData = line.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let eventType = event["type"] as? String else { continue }

            switch eventType {
            case "assistant":
                actions.append(contentsOf: Self.actionSummaries(fromAssistantEvent: event))
            case "result":
                finalResult = event["result"] as? String
                finalIsError = (event["is_error"] as? Bool) ?? false
                sessionId = event["session_id"] as? String
            default:
                break
            }
        }

        guard let finalResult else {
            throw KonClientError.invalidResponse
        }

        guard !finalIsError else {
            throw KonClientError.agentError(finalResult)
        }

        return KonReply(text: finalResult, actions: actions)
    }

    private static func actionSummaries(fromAssistantEvent event: [String: Any]) -> [String] {
        guard let message = event["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else { return [] }

        return content.compactMap { block -> String? in
            guard block["type"] as? String == "tool_use",
                  let name = block["name"] as? String else { return nil }
            let input = block["input"] as? [String: Any] ?? [:]
            return summary(forTool: name, input: input)
        }
    }

    private static func summary(forTool name: String, input: [String: Any]) -> String {
        switch name {
        case "Bash":
            let command = (input["command"] as? String) ?? ""
            return "コマンドを実行: \(Self.truncate(command))"
        case "Read":
            let path = (input["file_path"] as? String) ?? ""
            return "ファイルを読みました: \(Self.lastPathComponent(path))"
        case "Edit":
            let path = (input["file_path"] as? String) ?? ""
            return "ファイルを編集しました: \(Self.lastPathComponent(path))"
        case "Write":
            let path = (input["file_path"] as? String) ?? ""
            return "ファイルを作成しました: \(Self.lastPathComponent(path))"
        case "Grep":
            let pattern = (input["pattern"] as? String) ?? ""
            return "検索しました: \(Self.truncate(pattern))"
        case "Glob":
            let pattern = (input["pattern"] as? String) ?? ""
            return "ファイルを探しました: \(Self.truncate(pattern))"
        case "WebFetch":
            let url = (input["url"] as? String) ?? ""
            return "Webを確認しました: \(Self.truncate(url))"
        case "WebSearch":
            let query = (input["query"] as? String) ?? ""
            return "Web検索しました: \(Self.truncate(query))"
        default:
            return "\(name) を実行しました"
        }
    }

    private static func truncate(_ text: String, limit: Int = 60) -> String {
        text.count > limit ? String(text.prefix(limit)) + "…" : text
    }

    private static func lastPathComponent(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    func resetSession() {
        sessionId = nil
    }

    // MARK: - Executable resolution

    private func resolveClaudeExecutablePath() async throws -> String {
        if let claudeExecutablePath {
            return claudeExecutablePath
        }

        // GUI apps launched via Finder/LaunchServices get little to no PATH or
        // SHELL (unlike a Terminal session), so shelling out to "the user's
        // shell" to run `which claude` is unreliable. Check known install
        // locations directly instead.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let knownCandidates = [
            "\(home)/.local/share/mise/shims/claude", // mise shim, stable across Node version bumps
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.claude/local/claude"
        ]

        if let path = knownCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            claudeExecutablePath = path
            return path
        }

        throw KonClientError.claudeExecutableNotFound
    }

    // MARK: - Process execution

    private func runProcess(executablePath: String, arguments: [String]) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executablePath)
                process.arguments = arguments

                let outputPipe = Pipe()
                let errorPipe = Pipe()
                process.standardOutput = outputPipe
                process.standardError = errorPipe

                do {
                    try process.run()
                    // Read concurrently with execution to avoid the classic
                    // Process+Pipe deadlock when output exceeds the pipe buffer.
                    let outputData = try outputPipe.fileHandleForReading.readToEnd() ?? Data()
                    process.waitUntilExit()

                    if process.terminationStatus == 0 {
                        continuation.resume(returning: outputData)
                    } else {
                        var errorData = Data()
                        if let data = try? errorPipe.fileHandleForReading.readToEnd() {
                            errorData = data ?? Data()
                        }
                        let errorText = String(data: errorData, encoding: .utf8) ?? "unknown error"
                        continuation.resume(throwing: KonClientError.processLaunchFailed(errorText))
                    }
                } catch {
                    continuation.resume(throwing: KonClientError.processLaunchFailed(error.localizedDescription))
                }
            }
        }
    }
}
