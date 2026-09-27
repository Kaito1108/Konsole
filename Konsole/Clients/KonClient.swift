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
    - ユーザー発言の先頭にある［現在日時］は参考情報。日付・時刻・曜日を聞かれたらツールを使わずそれで答える。
    - Gmail・カレンダーなど外部サービスの操作は composio のMCPツールを使う。未接続のサービスは、Konsoleの設定の「連携」から接続するよう伝える。
    """

    private var claudeExecutablePath: String?
    private var sessionId: String?

    /// One long-lived `claude` process fed through `--input-format stream-json`.
    /// Spawning a fresh CLI per request cost ~1.4s of startup (plus resuming the
    /// session and reconnecting MCP) on every turn; reusing it drops a one-line
    /// reply from ~2.8s to ~1.4s.
    private var process: Process?
    private var stdin: FileHandle?
    private var reader: KonLineReader?
    /// MCP config the running process was started with; a change means restart.
    private var processMCPConfig: String?
    /// Stops the idle CLI so it doesn't hold ~300MB while Kon isn't being used.
    /// The next request restarts it and resumes the conversation via sessionId.
    private var idleShutdownTask: Task<Void, Never>?
    private var isSending = false
    private static let idleShutdownDelay: Duration = .seconds(10 * 60)

    /// Starts the CLI ahead of the first request so it's ready when Kon is called.
    func prewarm() async {
        let mcpConfig = await KonComposioStore.shared.mcpConfigJSON()
        try? await ensureProcess(mcpConfig: mcpConfig)
        scheduleIdleShutdown()
    }

    func send(_ prompt: String) async throws -> KonReply {
        idleShutdownTask?.cancel()
        isSending = true
        defer {
            isSending = false
            scheduleIdleShutdown()
        }
        let mcpConfig = await KonComposioStore.shared.mcpConfigJSON()
        try await ensureProcess(mcpConfig: mcpConfig)
        guard let stdin, let reader else { throw KonClientError.invalidResponse }

        let message: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": Self.contextPrefix() + prompt]
        ]
        var line = try JSONSerialization.data(withJSONObject: message)
        line.append(0x0A)
        do {
            try stdin.write(contentsOf: line)
        } catch {
            stopProcess()
            throw KonClientError.processLaunchFailed(error.localizedDescription)
        }

        var actions: [String] = []
        while let line = await reader.nextLine() {
            guard let lineData = line.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let eventType = event["type"] as? String else { continue }

            switch eventType {
            case "assistant":
                actions.append(contentsOf: Self.actionSummaries(fromAssistantEvent: event))
            case "result":
                if let id = event["session_id"] as? String {
                    sessionId = id
                }
                let result = (event["result"] as? String) ?? ""
                if (event["is_error"] as? Bool) ?? false {
                    throw KonClientError.agentError(result.isEmpty ? "エラーが発生しました。" : result)
                }
                return KonReply(text: result, actions: actions)
            default:
                break
            }
        }

        // stdout closed before a result: the CLI died. The next send restarts
        // it and resumes the conversation via sessionId.
        let errorText = reader.errorTail
        stopProcess()
        throw KonClientError.processLaunchFailed(errorText.isEmpty ? "claude CLIが終了しました" : errorText)
    }

    /// Lets Kon answer "今何時？" without spending a tool call on `date`.
    private static func contextPrefix() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "yyyy年M月d日(E) H:mm"
        return "［現在日時: \(formatter.string(from: Date()))］\n"
    }

    private func ensureProcess(mcpConfig: String?) async throws {
        if let process, process.isRunning, processMCPConfig == mcpConfig {
            return
        }
        stopProcess()

        let executablePath = try await resolveClaudeExecutablePath()
        // prewarm() and send() can interleave across that await; don't spawn twice.
        if let process, process.isRunning, processMCPConfig == mcpConfig {
            return
        }
        var arguments = [
            "-p",
            "--input-format", "stream-json",
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
        if let mcpConfig {
            arguments += ["--mcp-config", mcpConfig]
        }
        if let sessionId {
            arguments += ["--resume", sessionId]
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        // Load MCP tools up front instead of behind ToolSearch: Composio only
        // exposes a handful of meta tools, and deferring them cost a full
        // model round trip before every external-service request.
        environment["ENABLE_TOOL_SEARCH"] = "false"
        process.environment = environment

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let reader = KonLineReader(output: outputPipe.fileHandleForReading, error: errorPipe.fileHandleForReading)
        do {
            try process.run()
        } catch {
            reader.close()
            throw KonClientError.processLaunchFailed(error.localizedDescription)
        }

        self.process = process
        self.stdin = inputPipe.fileHandleForWriting
        self.reader = reader
        self.processMCPConfig = mcpConfig
    }

    private func scheduleIdleShutdown() {
        idleShutdownTask?.cancel()
        idleShutdownTask = Task { [weak self] in
            try? await Task.sleep(for: Self.idleShutdownDelay)
            guard !Task.isCancelled else { return }
            await self?.stopIfIdle()
        }
    }

    private func stopIfIdle() {
        // A prewarm racing a send can leave a timer armed mid-reply.
        guard !isSending else { return }
        stopProcess()
    }

    private func stopProcess() {
        try? stdin?.close()
        if let process, process.isRunning {
            process.terminate()
        }
        reader?.close()
        process = nil
        stdin = nil
        reader = nil
        processMCPConfig = nil
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
        case _ where name.hasPrefix("mcp__composio__"):
            return "外部サービスを操作: \(Self.composioSummary(input: input))"
        default:
            return "\(name) を実行しました"
        }
    }

    /// Composio's meta tools wrap the real tool slugs (e.g. GMAIL_SEND_EMAIL)
    /// inside their input, so surface those instead of the meta tool name.
    private static func composioSummary(input: [String: Any]) -> String {
        if let tools = input["tools"] as? [[String: Any]] {
            let slugs = tools.compactMap { $0["tool_slug"] as? String }
            if !slugs.isEmpty { return truncate(slugs.joined(separator: ", ")) }
        }
        if let queries = input["queries"] as? [[String: Any]] {
            let uses = queries.compactMap { $0["use_case"] as? String }
            if !uses.isEmpty { return "ツールを検索（\(truncate(uses.joined(separator: ", ")))）" }
        }
        if let toolkits = input["toolkits"] as? [String], !toolkits.isEmpty {
            return "接続を確認（\(toolkits.joined(separator: ", "))）"
        }
        return "Composio"
    }

    private static func truncate(_ text: String, limit: Int = 60) -> String {
        text.count > limit ? String(text.prefix(limit)) + "…" : text
    }

    private static func lastPathComponent(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    func resetSession() async {
        sessionId = nil
        stopProcess()
        await prewarm()
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
}

/// Splits a pipe's output into lines for async consumption, and keeps the tail
/// of stderr for error messages. Pipes are drained continuously so the child
/// never blocks on a full buffer.
nonisolated final class KonLineReader: @unchecked Sendable {
    private let lock = NSLock()
    private let output: FileHandle
    private let error: FileHandle
    private var buffer = Data()
    private var lines: [String] = []
    private var waiter: CheckedContinuation<String?, Never>?
    private var isFinished = false
    private var errorData = Data()

    init(output: FileHandle, error: FileHandle) {
        self.output = output
        self.error = error
        output.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.receive(data)
        }
        error.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            lock.lock()
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                errorData.append(data)
                if errorData.count > 4096 { errorData = errorData.suffix(4096) }
            }
            lock.unlock()
        }
    }

    var errorTail: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Next complete line, or nil once the pipe has closed.
    func nextLine() async -> String? {
        await withCheckedContinuation { continuation in
            lock.lock()
            if !lines.isEmpty {
                let line = lines.removeFirst()
                lock.unlock()
                continuation.resume(returning: line)
            } else if isFinished {
                lock.unlock()
                continuation.resume(returning: nil)
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }

    func close() {
        output.readabilityHandler = nil
        error.readabilityHandler = nil
        finish()
    }

    private func receive(_ data: Data) {
        if data.isEmpty {
            output.readabilityHandler = nil
            finish()
            return
        }
        lock.lock()
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
                lines.append(line)
            }
        }
        let continuation = lines.isEmpty ? nil : waiter
        let line = continuation == nil ? nil : lines.removeFirst()
        if continuation != nil { waiter = nil }
        lock.unlock()
        continuation?.resume(returning: line)
    }

    private func finish() {
        lock.lock()
        isFinished = true
        let continuation = lines.isEmpty ? waiter : nil
        if continuation != nil { waiter = nil }
        lock.unlock()
        continuation?.resume(returning: nil)
    }
}
