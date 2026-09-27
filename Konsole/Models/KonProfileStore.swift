import Foundation
import Observation

/// Kon's notes about the user — speech habits, what they usually mean, how
/// they like to be answered — kept as Markdown in `profile.md` and added to
/// Kon's system prompt. The notes are rewritten in the background from recent
/// conversations (a one-shot `claude -p` run), and the user can edit them in
/// Settings or just tell Kon "覚えておいて".
@MainActor
@Observable
final class KonProfileStore {
    static let shared = KonProfileStore()

    nonisolated static let fileURL = URL.applicationSupportDirectory
        .appending(path: "Konsole", directoryHint: .isDirectory)
        .appending(path: "profile.md")

    /// Learn once this many new user messages have piled up mid-conversation.
    private static let messagesPerLearning = 10
    /// ...or this many when a conversation is closed (「新しい会話」).
    private static let messagesPerLearningAtConversationEnd = 3
    /// The first run would otherwise feed the whole history in.
    private static let maxEntriesPerLearning = 150
    private static let maxCharactersPerEntry = 300
    private static let lastLearnedAtKey = "profileLastLearnedAt"

    private(set) var text: String
    private(set) var isLearning = false
    private(set) var lastError: String?
    private(set) var lastLearnedAt: Date? {
        didSet { UserDefaults.standard.set(lastLearnedAt, forKey: Self.lastLearnedAtKey) }
    }

    private let settings = KonSettings.shared
    private let history = KonHistoryStore.shared

    private init() {
        text = Self.readProfile() ?? ""
        lastLearnedAt = UserDefaults.standard.object(forKey: Self.lastLearnedAtKey) as? Date
    }

    /// Current notes, read fresh from disk since Kon may have edited them itself.
    nonisolated static func readProfile() -> String? {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Picks up edits Kon made through its own tools.
    func reload() {
        text = Self.readProfile() ?? ""
    }

    func save(_ newText: String) {
        do {
            try FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try newText.write(to: Self.fileURL, atomically: true, encoding: .utf8)
            text = newText
            lastError = nil
        } catch {
            lastError = "メモを保存できませんでした: \(error.localizedDescription)"
        }
    }

    /// Forgets everything learned; the next learning run starts from recent history.
    func reset() {
        save("")
        lastLearnedAt = Date()
    }

    /// User messages Kon hasn't learned from yet.
    var pendingMessageCount: Int {
        pendingEntries.filter { $0.role == .user }.count
    }

    private var pendingEntries: [KonHistoryEntry] {
        let entries = history.entries.filter { entry in lastLearnedAt.map { entry.date > $0 } ?? true }
        return Array(entries.suffix(Self.maxEntriesPerLearning))
    }

    /// Called after each reply, and with `conversationEnded` when the user starts over.
    func learnIfNeeded(conversationEnded: Bool = false) {
        guard settings.learnsFromConversations, !isLearning else { return }
        let threshold = conversationEnded ? Self.messagesPerLearningAtConversationEnd : Self.messagesPerLearning
        guard pendingMessageCount >= threshold else { return }
        learnNow()
    }

    func learnNow() {
        guard !isLearning else { return }
        let entries = pendingEntries
        guard entries.contains(where: { $0.role == .user }) else {
            lastError = "まだ学習していない会話がありません。"
            return
        }
        reload()
        isLearning = true
        lastError = nil
        let learnedUpTo = entries.last?.date ?? Date()
        let prompt = Self.learningPrompt(currentNotes: text, entries: entries)

        Task {
            defer { isLearning = false }
            do {
                let notes = try await Self.runClaude(prompt: prompt)
                // Kon may have written "覚えておいて" notes while this ran; those
                // are lost only if they landed during this short window.
                save(notes)
                lastLearnedAt = learnedUpTo
            } catch {
                lastError = "学習に失敗しました: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Learning run

    private static let learningSystemPrompt = """
    あなたは音声アシスタント「コン」の記憶係です。ユーザーとコンの会話ログを読み、今後の会話でコンがユーザーの意図を汲み取りやすくなるメモを更新します。
    ユーザーの発言は音声認識で文字起こしされたものなので、言い淀み・誤変換を含みます。

    出力はメモ本文のみ。前置き・説明・コードブロックは書かない。次の見出しのMarkdown箇条書きで、全体40行以内:
    ## 話し方の癖
    口癖、言い淀み、よくある音声認識の誤変換（「〇〇」→「××」のこと、の形式）など。
    ## 言いたいことの傾向
    省略や指示語がふつう何を指すか、よく頼むこと、話の進め方など。
    ## ユーザーについて
    仕事・使っているツールやプロジェクトなど、今後も役立つ事実。
    ## 対応のコツ
    好む返答の長さや言い方、嫌がったこと、うまくいった対応。

    ルール:
    - 現在のメモを土台に、新しい会話ログで分かったことを追加・修正する。矛盾したら新しいほうを採用する。
    - ユーザーが自分で書いた項目や「覚えておいて」と頼んだ項目は消さない。
    - 繰り返し現れる傾向や今後も役立つことだけを書く。一度きりの話題や一時的な予定は書かない。根拠の薄い推測は書かない。
    - パスワード・APIキー・住所・電話番号などの機密情報は書かない。
    - 書くことがなければ現在のメモをそのまま出力する。
    """

    private static func learningPrompt(currentNotes: String, entries: [KonHistoryEntry]) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "M/d H:mm"
        let log = entries.map { entry in
            let speaker = entry.role == .user ? "ユーザー" : "コン"
            let text = entry.text.count > maxCharactersPerEntry
                ? String(entry.text.prefix(maxCharactersPerEntry)) + "…"
                : entry.text
            return "[\(formatter.string(from: entry.date))] \(speaker): \(text)"
        }.joined(separator: "\n")
        return """
        # 現在のメモ
        \(currentNotes.isEmpty ? "（まだありません）" : currentNotes)

        # 新しい会話ログ
        \(log)
        """
    }

    private nonisolated static func runClaude(prompt: String) async throws -> String {
        let executable = try KonClient.findClaudeExecutable()
        return try await Task.detached {
            let process = Process()
            process.executableURL = URL(filePath: executable)
            process.arguments = [
                "-p", prompt,
                "--model", "haiku",
                "--output-format", "json",
                "--system-prompt", learningSystemPrompt,
                "--tools", "",
                "--strict-mcp-config",
                "--setting-sources", "project",
                "--no-session-persistence"
            ]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = json["result"] as? String else {
                throw KonClientError.invalidResponse
            }
            if (json["is_error"] as? Bool) ?? false {
                throw KonClientError.classify(errorText: result) ?? KonClientError.agentError(result)
            }
            let notes = stripCodeFence(result)
            guard !notes.isEmpty else { throw KonClientError.invalidResponse }
            return notes
        }.value
    }

    private nonisolated static func stripCodeFence(_ text: String) -> String {
        var lines = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        if lines.first?.hasPrefix("```") == true, lines.last?.hasPrefix("```") == true, lines.count >= 2 {
            lines.removeFirst()
            lines.removeLast()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
