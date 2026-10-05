import Foundation

enum KonClientError: Error, LocalizedError {
    case claudeExecutableNotFound
    /// The user cut the reply off (barge-in / Escape); not shown as an error.
    case interrupted
    case processLaunchFailed(String)
    case invalidResponse
    case agentError(String)
    /// Claude's subscription usage limit is used up; `resetsAt` is when it refills.
    case usageLimit(resetsAt: Date?, kind: String?)
    /// Anthropic's servers are overloaded (HTTP 529); retrying later helps.
    case overloaded

    var errorDescription: String? {
        switch self {
        case .claudeExecutableNotFound:
            return "claude CLIが見つかりません。インストール済みか確認してください。"
        case .interrupted:
            return "中断しました。"
        case .processLaunchFailed(let message):
            return "claude CLIの起動に失敗しました: \(message)"
        case .invalidResponse:
            return "claude CLIの応答を解析できませんでした。"
        case .agentError(let message):
            return message
        case .usageLimit(let resetsAt, let kind):
            var text = "Claudeの\(Self.limitName(kind))に達しちゃったから、今は答えられないよ。"
            if let resetsAt {
                text += "\(Self.resetTime(resetsAt))ごろにまた使えるようになるよ。"
            } else {
                text += "上限がリセットされるまで少し待ってね。"
            }
            return text
        case .overloaded:
            return "Claudeのサーバーが混み合ってて答えられなかったよ。少し待ってからもう一度話しかけてね。"
        }
    }

    private static func limitName(_ kind: String?) -> String {
        switch kind {
        case "five_hour": return "5時間ごとの利用上限"
        case let kind? where kind.hasPrefix("seven_day"): return "1週間の利用上限"
        default: return "利用上限"
        }
    }

    /// "18時30分" today, "明日の9時" tomorrow, "10月2日(木) 9時" beyond.
    private static func resetTime(_ date: Date) -> String {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        let minute = calendar.component(.minute, from: date)
        let clock = minute == 0 ? "H時" : "H時m分"
        if calendar.isDateInToday(date) {
            formatter.dateFormat = clock
            return formatter.string(from: date)
        }
        if calendar.isDateInTomorrow(date) {
            formatter.dateFormat = clock
            return "明日の" + formatter.string(from: date)
        }
        formatter.dateFormat = "M月d日(E) " + clock
        return formatter.string(from: date)
    }

    /// Reads a limit or overload out of the CLI's error text, for when no
    /// `rate_limit_event` said so (older CLIs, or a message-only failure).
    static func classify(errorText text: String) -> KonClientError? {
        let lower = text.lowercased()
        // Old format: "Claude AI usage limit reached|1759000000".
        if lower.contains("usage limit reached") {
            let epoch = text.split(separator: "|").last.flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }
            return .usageLimit(resetsAt: epoch.map { Date(timeIntervalSince1970: $0) }, kind: nil)
        }
        if lower.contains("hit your limit") || lower.contains("out of extra usage")
            || lower.contains("rate_limit_error") || lower.contains("rate limit") {
            return .usageLimit(resetsAt: nil, kind: nil)
        }
        if lower.contains("overloaded") || lower.range(of: #"\b529\b"#, options: .regularExpression) != nil {
            return .overloaded
        }
        return nil
    }
}

/// A completed turn: Kon's reply text plus a human-readable log of what it did
/// (derived from tool_use events in the CLI's stream-json output), so the UI
/// can show "何をしたか" alongside the reply.
struct KonReply {
    let text: String
    let actions: [String]
    /// Which model answered, when model routing is on ("Haiku 4.5"); nil hides it.
    var modelLabel: String? = nil
    /// The text was already shown/read as it arrived, so the UI shouldn't start over.
    var wasStreamed: Bool = false
}

/// A tool call the CLI is asking permission for, in words the user can judge.
struct KonPermissionRequest: Sendable {
    let toolName: String
    /// One line, e.g. 「ファイルを作成しました: memo.md」 rephrased as a question.
    let summary: String
    /// The concrete argument (path, command), if there is one worth showing.
    let detail: String?
}

/// Reply text as it arrives. `text` is everything of the current message so
/// far (a replacement, not an append); `isNewSegment` marks the start of a new
/// assistant message — the CLI may talk before and after using a tool.
typealias KonStreamHandler = @MainActor @Sendable (_ text: String, _ isNewSegment: Bool) -> Void
/// Answers a permission request: true = allow once, false = deny.
typealias KonPermissionHandler = @MainActor @Sendable (KonPermissionRequest) async -> Bool

/// Drives Claude Code via the `claude` CLI subprocess (`-p --output-format stream-json`)
/// instead of the Python/TypeScript-only Agent SDK.
actor KonClient {
    /// Replies are read aloud and shown in a small bubble, so keep them short and plain.
    private static let systemPrompt = """
    あなたはユーザー専属の音声アシスタント「コン」です。返答はそのまま音声で読み上げられ、画面右上の小さな吹き出しに表示されます。
    - 返答は原則1〜3文、100文字程度までの話し言葉にする。結論から言う。
    - Markdown、箇条書き、見出し、コードブロック、URLの羅列は使わない。
    - 例外として、ユーザーがそのまま貼り付けて使うコマンド・パス・コード・URLを答えるときは、本文のあとにそれだけを ``` で囲んだコードブロック1つにして置く。コードブロックは読み上げられず、自動でクリップボードにコピーされるので、本文では中身を読み上げず「〜はこれだよ」のように一言だけ言う。コピーしたことは言わなくてよい。
    - 作業をした場合は、何をしたかと結果だけを一言で伝える。途中経過や長い説明は省く。
    - ユーザーが「詳しく」などと明示的に求めたときだけ長めに答えてよい。
    - ユーザー発言の先頭にある［現在日時］は参考情報。日付・時刻・曜日を聞かれたらツールを使わずそれで答える。
    - Gmail・カレンダーなど外部サービスの操作は composio のMCPツールを使う。未接続のサービスは、Konsoleの設定の「連携」から接続するよう伝える。
    - ユーザー発言の先頭にある［作業状況］は、ユーザーが今見ているアプリ・ファイル・ページ・選択中のテキスト・クリップボードの参考情報。「これ」「このファイル」「さっきコピーしたの」などの指示語はこれで解釈する。選択中のテキストがあれば「これ」はまずそれを指す。関係ないときは触れない。
    - ［作業状況］に「画面の画像」のパスがあれば、それはユーザーが今見ているウィンドウのスクリーンショット。「このエラー何？」「これどう思う？」のように画面を見ないと答えられないときだけ、Readツールでその画像を開いて見る。テキストの情報で足りるときは開かない。画像は見るだけで、クリックや入力などの画面操作はしない。画像がなく画面を見る必要があるときは、見えていないことを一言伝えて、テキストを選択するかコピーしてもらう。
    - 「25分後に教えて」「17時に〇〇って言って」のようなタイマー・リマインダーは、Bashで open -g "konsole://remind?in=秒数&text=読み上げる一言" または open -g "konsole://remind?at=UNIX秒&text=読み上げる一言" を実行して登録する。textはURLエンコードし、時刻になったらそのまま読み上げられる一言にする（例: 25分たったよ、休憩しよう）。at は date -j -f "%Y-%m-%d %H:%M" "2026-01-01 17:00" +%s のように求める。
    - 登録済みリマインダーは \(KonReminderStore.fileURL.path(percentEncoded: false)) にJSONで保存されている。取り消しは open -g "konsole://remind/cancel?id=ID"、全部なら open -g "konsole://remind/cancel?all=1"。
    - ツールの実行がユーザーに拒否されたときは、やらなかったことを一言で伝えるだけにする。同じ操作をやり直したり、別の手で回避したりしない。
    - ユーザーに「覚えておいて」と頼まれた好み・呼び方・言葉の意味などは、\(KonProfileStore.fileURL.path(percentEncoded: false)) のメモ（Markdown、なければ作る）の該当する見出しに一行で追記する。
    """

    private var claudeExecutablePath: String?
    /// Session id per working folder, so switching projects and coming back
    /// resumes that folder's conversation instead of starting over.
    private var sessionIds: [String: String] = [:]

    /// One long-lived `claude` process fed through `--input-format stream-json`.
    /// Spawning a fresh CLI per request cost ~1.4s of startup (plus resuming the
    /// session and reconnecting MCP) on every turn; reusing it drops a one-line
    /// reply from ~2.8s to ~1.4s.
    private var process: Process?
    private var stdin: FileHandle?
    private var reader: KonLineReader?
    /// MCP config + system prompt the running process was started with; a
    /// change (e.g. a newly connected account) means restart.
    private var processConfig: ProcessConfig?
    /// Set when the user cuts the current reply off.
    private var isInterrupting = false
    private var interruptFallbackTask: Task<Void, Never>?
    private static let interruptGracePeriod: Duration = .seconds(3)

    /// Model and thinking budget the running CLI was last told to use, so an
    /// unchanged tier doesn't resend the control requests.
    private var appliedModel: String?
    private var appliedThinkingTokens: Int?

    private struct ProcessConfig: Equatable {
        let mcpConfig: String?
        let systemPrompt: String
        /// The CLI's working directory (the active project), nil = home.
        let workingDirectory: String?
        /// Other registered folders the CLI may touch without asking.
        let extraDirectories: [String]
        /// Route permission prompts to Kon (buttons in the bubble).
        let asksPermission: Bool
        /// Emit partial messages so the reply can be shown/read as it arrives.
        let streamsPartials: Bool

        /// Key for the resumable session belonging to this working folder.
        var sessionKey: String { workingDirectory ?? "~" }
    }
    /// Stops the idle CLI so it doesn't hold ~300MB while Kon isn't being used.
    /// The next request restarts it and resumes the conversation via sessionId.
    private var idleShutdownTask: Task<Void, Never>?
    private var isSending = false
    private static let idleShutdownDelay: Duration = .seconds(10 * 60)

    /// Starts the CLI ahead of the first request so it's ready when Kon is called.
    func prewarm() async {
        guard !isSending else { return }
        try? await ensureProcess(config: await currentConfig())
        scheduleIdleShutdown()
    }

    /// - Parameters:
    ///   - context: What the user is working on (see KonContextProvider).
    ///   - onStream: Called with the reply as it arrives, when streaming is on.
    ///   - onPermission: Asked before a tool that needs approval runs.
    func send(
        _ prompt: String,
        context: String? = nil,
        onStream: KonStreamHandler? = nil,
        onPermission: KonPermissionHandler? = nil
    ) async throws -> KonReply {
        // A barge-in sends the next request while the interrupted one is still
        // draining its output; the pipe carries one turn at a time.
        while isSending {
            try await Task.sleep(for: .milliseconds(50))
        }
        idleShutdownTask?.cancel()
        isSending = true
        isInterrupting = false
        defer {
            isSending = false
            isInterrupting = false
            interruptFallbackTask?.cancel()
            scheduleIdleShutdown()
        }
        let config = await currentConfig()
        try await ensureProcess(config: config)
        guard let stdin, let reader else { throw KonClientError.invalidResponse }

        let tier = await KonSettings.shared.tier(for: prompt)
        let model = await KonSettings.shared.model(for: tier)
        let thinkingTokens = await KonSettings.shared.thinking(for: tier).maxTokens
        let showsModel = await KonSettings.shared.routesModelByRequest
        applyModel(model, thinkingTokens: thinkingTokens)

        var content = Self.contextPrefix()
        if let context, !context.isEmpty {
            content += "［作業状況］\n\(context)\n［ここまで］\n"
        }
        content += prompt
        let message: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": content]
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
        /// Set when the CLI reports the request was refused for the usage limit.
        var rejection: KonClientError?
        /// Text of the assistant message being streamed right now.
        var streamedSegment = ""
        var didStream = false
        while let line = await reader.nextLine() {
            guard let lineData = line.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let eventType = event["type"] as? String else { continue }

            switch eventType {
            case "stream_event":
                // Partial text of the reply, so it can be shown and read while
                // the model is still writing. Sub-agent output is skipped.
                guard let onStream, event["parent_tool_use_id"] == nil,
                      let streamEvent = event["event"] as? [String: Any] else { break }
                switch streamEvent["type"] as? String {
                case "message_start":
                    streamedSegment = ""
                case "content_block_delta":
                    guard let delta = streamEvent["delta"] as? [String: Any],
                          delta["type"] as? String == "text_delta",
                          let chunk = delta["text"] as? String, !chunk.isEmpty else { break }
                    let isNewSegment = streamedSegment.isEmpty
                    streamedSegment += chunk
                    didStream = true
                    let snapshot = streamedSegment
                    await onStream(snapshot, isNewSegment)
                default:
                    break
                }
            case "control_request":
                // The CLI asks before running a tool that needs approval
                // (--permission-prompt-tool stdio); the user decides.
                guard let requestId = event["request_id"] as? String,
                      let request = event["request"] as? [String: Any],
                      request["subtype"] as? String == "can_use_tool" else { break }
                let toolName = request["tool_name"] as? String ?? "ツール"
                let input = request["input"] as? [String: Any] ?? [:]
                let allowed = await onPermission?(Self.permissionRequest(toolName: toolName, input: input)) ?? false
                answerPermission(requestId: requestId, allowed: allowed, input: input)
            case "assistant":
                actions.append(contentsOf: Self.actionSummaries(fromAssistantEvent: event))
                // "rate_limit" also covers e.g. a model being unavailable, so
                // only the wording decides whether it's the usage limit.
                if event["error"] as? String == "rate_limit", rejection == nil,
                   case .usageLimit? = KonClientError.classify(errorText: Self.text(ofAssistantEvent: event)) {
                    rejection = .usageLimit(resetsAt: nil, kind: nil)
                }
            case "rate_limit_event":
                if let info = event["rate_limit_info"] as? [String: Any],
                   info["status"] as? String == "rejected" {
                    rejection = .usageLimit(resetsAt: Self.date(from: info["resetsAt"]), kind: info["rateLimitType"] as? String)
                }
            case "result":
                if let id = event["session_id"] as? String {
                    sessionIds[config.sessionKey] = id
                }
                if isInterrupting {
                    throw KonClientError.interrupted
                }
                let result = (event["result"] as? String) ?? ""
                if (event["is_error"] as? Bool) ?? false {
                    if let rejection { throw rejection }
                    if let classified = KonClientError.classify(errorText: result) { throw classified }
                    throw KonClientError.agentError(result.isEmpty ? "エラーが発生しました。" : result)
                }
                return KonReply(
                    text: result,
                    actions: actions,
                    modelLabel: showsModel ? Self.modelLabel(fromResult: event, fallback: model) : nil,
                    // Only claim it was streamed if what the user already saw
                    // and heard is the reply itself, not a mid-turn aside.
                    wasStreamed: didStream && streamedSegment.trimmingCharacters(in: .whitespacesAndNewlines)
                        == result.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            default:
                break
            }
        }

        // stdout closed before a result: the CLI died (or was stopped because
        // an interrupt went unanswered). The next send restarts it and resumes
        // the conversation via sessionId.
        let errorText = reader.errorTail
        stopProcess()
        if isInterrupting {
            throw KonClientError.interrupted
        }
        if let rejection { throw rejection }
        if let classified = KonClientError.classify(errorText: errorText) { throw classified }
        throw KonClientError.processLaunchFailed(errorText.isEmpty ? "claude CLIが終了しました" : errorText)
    }

    private static func text(ofAssistantEvent event: [String: Any]) -> String {
        let blocks = (event["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
        return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    /// `resetsAt` is Unix seconds (milliseconds tolerated).
    private static func date(from value: Any?) -> Date? {
        guard let number = (value as? NSNumber)?.doubleValue, number > 0 else { return nil }
        return Date(timeIntervalSince1970: number > 1e12 ? number / 1000 : number)
    }

    /// Lets Kon answer "今何時？" without spending a tool call on `date`.
    private static func contextPrefix() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "yyyy年M月d日(E) H:mm"
        return "［現在日時: \(formatter.string(from: Date()))］\n"
    }

    /// Stops the reply in progress. The CLI is asked to interrupt the turn
    /// (keeping the process and conversation); if it doesn't wrap up quickly
    /// the process is stopped and the next request resumes the session.
    func interrupt() {
        guard isSending, !isInterrupting else { return }
        isInterrupting = true
        let request: [String: Any] = [
            "type": "control_request",
            "request_id": "kon_interrupt_\(UUID().uuidString)",
            "request": ["subtype": "interrupt"]
        ]
        if var line = try? JSONSerialization.data(withJSONObject: request) {
            line.append(0x0A)
            try? stdin?.write(contentsOf: line)
        }
        interruptFallbackTask?.cancel()
        interruptFallbackTask = Task { [weak self] in
            try? await Task.sleep(for: Self.interruptGracePeriod)
            guard !Task.isCancelled else { return }
            await self?.stopIfStillInterrupting()
        }
    }

    private func stopIfStillInterrupting() {
        guard isSending, isInterrupting else { return }
        stopProcess()
    }

    // MARK: - Model per request

    /// Switches the running CLI's model and thinking budget for the next turn.
    /// `set_model` / `set_max_thinking_tokens` are control requests, so routing
    /// costs nothing — restarting the process per tier would cost ~1.4s.
    private func applyModel(_ model: String, thinkingTokens: Int) {
        if appliedModel != model {
            writeControlRequest(["subtype": "set_model", "model": model])
            appliedModel = model
        }
        if appliedThinkingTokens != thinkingTokens {
            writeControlRequest([
                "subtype": "set_max_thinking_tokens",
                "max_thinking_tokens": thinkingTokens,
                // Kon speaks its replies; thinking text is never shown.
                "thinking_display": "omitted"
            ])
            appliedThinkingTokens = thinkingTokens
        }
    }

    /// "claude-haiku-4-5-20251001" → "Haiku 4.5". The result event names the
    /// model that actually answered, which beats the alias we asked for.
    private static func modelLabel(fromResult event: [String: Any], fallback: String) -> String {
        let used = (event["modelUsage"] as? [String: Any])?.keys.sorted().first
        return modelLabel(used ?? fallback)
    }

    private static func modelLabel(_ identifier: String) -> String {
        let families = ["haiku", "sonnet", "opus"]
        let parts = identifier.split(separator: "-").map(String.init)
        guard let index = parts.firstIndex(where: { families.contains($0.lowercased()) }) else {
            return identifier
        }
        let version = parts[(index + 1)...].prefix { $0.count <= 2 && $0.allSatisfy(\.isNumber) }
        let family = parts[index].capitalized
        return version.isEmpty ? family : family + " " + version.joined(separator: ".")
    }

    // MARK: - Permission prompts

    /// Turns the CLI's tool call into a question the user can answer without
    /// reading JSON.
    private static func permissionRequest(toolName: String, input: [String: Any]) -> KonPermissionRequest {
        let detail: String?
        switch toolName {
        case "Bash":
            detail = (input["command"] as? String).map { truncate($0, limit: 160) }
        case "Read", "Edit", "Write", "NotebookEdit":
            detail = (input["file_path"] as? String).map { truncate($0, limit: 120) }
        case "WebFetch":
            detail = (input["url"] as? String).map { truncate($0, limit: 120) }
        default:
            detail = nil
        }
        return KonPermissionRequest(
            toolName: toolName,
            summary: permissionSummary(forTool: toolName, input: input),
            detail: detail
        )
    }

    private static func permissionSummary(forTool name: String, input: [String: Any]) -> String {
        switch name {
        case "Bash": return "コマンドを実行してもいい？"
        case "Write": return "ファイルを作ってもいい？"
        case "Edit", "NotebookEdit": return "ファイルを書き換えてもいい？"
        case "Read": return "このファイルを読んでもいい？"
        case "WebFetch", "WebSearch": return "Webを見てもいい？"
        case _ where name.hasPrefix("mcp__composio__"): return "外部サービスを操作してもいい？"
        default: return "\(name) を実行してもいい？"
        }
    }

    private func answerPermission(requestId: String, allowed: Bool, input: [String: Any]) {
        let decision: [String: Any] = allowed
            ? ["behavior": "allow", "updatedInput": input]
            : ["behavior": "deny", "message": "ユーザーが許可しなかったので実行しません。"]
        let response: [String: Any] = [
            "type": "control_response",
            "response": [
                "subtype": "success",
                "request_id": requestId,
                "response": decision
            ]
        ]
        write(response)
    }

    private func writeControlRequest(_ request: [String: Any]) {
        write([
            "type": "control_request",
            "request_id": "kon_\(UUID().uuidString)",
            "request": request
        ])
    }

    private func write(_ object: [String: Any]) {
        guard var line = try? JSONSerialization.data(withJSONObject: object) else { return }
        line.append(0x0A)
        try? stdin?.write(contentsOf: line)
    }

    private func currentConfig() async -> ProcessConfig {
        let mcpConfig = await KonComposioStore.shared.mcpConfigJSON()
        var prompt = Self.systemPrompt
        prompt += "\n\n［コンの性格・話し方］\n" + (await KonSettings.shared.personaPrompt)
        if let routines = await KonSettings.shared.routinesPrompt {
            prompt += """


            ［定型フレーズ］ユーザーの発言が次のきっかけの言葉にあたるとき（言い回しの違い・音声認識の誤変換・前後の呼びかけを含む）は、矢印の先の指示に従って対応する。きっかけの言葉が別の依頼の一部に出てくるだけのときは通常どおり対応する。
            \(routines)
            """
        }
        if let profile = KonProfileStore.readProfile() {
            prompt += """


            ［ユーザーについてのメモ］これまでの会話から分かったユーザーの癖や傾向。発言の意図を汲むのに使い、メモの内容を口に出して説明しない。
            \(profile)
            """
        }
        if mcpConfig != nil, let accounts = await KonComposioStore.shared.accountsPromptSummary {
            prompt += """

            - 次のサービスは複数アカウントが連携されている。composioのツールを実行するときは arguments に "account": "別名" を必ず入れる。読むだけの依頼（予定・メールの確認など）でアカウントの指定がなければ全アカウントを確認し、送信・作成・削除などで指定がなければどのアカウントか短く確認する。
            \(accounts)
            """
        }
        if let projects = await KonSettings.shared.projectsPrompt {
            prompt += "\n\n" + projects
        }
        let active = await KonSettings.shared.activeProject
        var extraDirectories = await KonSettings.shared.usableProjects
            .map(\.expandedPath)
            .filter { $0 != active?.expandedPath }
        // Lets Kon open the screenshot without a permission prompt.
        if await KonSettings.shared.sharesScreenshot {
            extraDirectories.append(KonScreenCapture.preparedDirectoryPath())
        }
        return ProcessConfig(
            mcpConfig: mcpConfig,
            systemPrompt: prompt,
            workingDirectory: active?.folderExists == true ? active?.expandedPath : nil,
            extraDirectories: extraDirectories,
            asksPermission: await KonSettings.shared.asksToolPermission,
            streamsPartials: await KonSettings.shared.streamsReplies
        )
    }

    private func ensureProcess(config: ProcessConfig) async throws {
        if let process, process.isRunning, processConfig == config {
            return
        }
        stopProcess()

        let executablePath = try await resolveClaudeExecutablePath()
        // prewarm() and send() can interleave across that await; don't spawn twice.
        if let process, process.isRunning, processConfig == config {
            return
        }
        var arguments = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--permission-mode", "auto",
            "--append-system-prompt", config.systemPrompt,
            // Skip the user-level MCP servers, plugins and hooks: loading them
            // cost ~5s of startup on every request (measured 8s → 3s for a
            // one-line reply). Kon gets its own MCP config when it needs one.
            "--strict-mcp-config",
            "--setting-sources", "project"
        ]
        if config.asksPermission {
            // Undocumented in --help, but this is what routes permission
            // prompts to us as can_use_tool control requests instead of the
            // CLI silently refusing the tool call.
            arguments += ["--permission-prompt-tool", "stdio"]
            // ask ルールは足さない。auto モードの判断をそのまま使い、CLI が
            // 自分で聞いてきた呼び出しだけを吹き出しの「許可 / 拒否」に回す。
            // 以前は git push や gh pr merge まで ask に落としていて、PR を
            // 作るたびに確認が出ていた。
        }
        if config.streamsPartials {
            arguments += ["--include-partial-messages"]
        }
        for directory in config.extraDirectories {
            arguments += ["--add-dir", directory]
        }
        if let mcpConfig = config.mcpConfig {
            arguments += ["--mcp-config", mcpConfig]
        }
        if let sessionId = sessionIds[config.sessionKey] {
            arguments += ["--resume", sessionId]
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        // Relative paths and "このファイル" resolve in the active project.
        if let workingDirectory = config.workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        }
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
        self.processConfig = config
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
        processConfig = nil
        appliedModel = nil
        appliedThinkingTokens = nil
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
        sessionIds.removeAll()
        stopProcess()
        await prewarm()
    }

    // MARK: - Executable resolution

    private func resolveClaudeExecutablePath() async throws -> String {
        if let claudeExecutablePath {
            return claudeExecutablePath
        }
        let path = try Self.findClaudeExecutable()
        claudeExecutablePath = path
        return path
    }

    nonisolated static func findClaudeExecutable() throws -> String {
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
