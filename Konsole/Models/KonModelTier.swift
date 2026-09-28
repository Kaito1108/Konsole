import Foundation

/// Which model answers a request. Small talk and quick lookups shouldn't pay
/// Opus latency, and a real task shouldn't be answered by Haiku, so the tier is
/// picked per request from what the user said (see `KonModelRouter`).
enum KonModelTier: String, CaseIterable, Identifiable, Codable {
    /// あいさつ・時刻・リマインダーなど、速さがすべての用
    case light
    /// ふだんの質問と軽い作業
    case mid
    /// 設計・原因調査・コード修正など、考える用
    case heavy

    var id: Self { self }

    var title: String {
        switch self {
        case .light: "かるい用（あいさつ・時刻・リマインダー）"
        case .mid: "ふつう（ふだんの質問・軽い作業）"
        case .heavy: "重い用（調査・コード・考えごと）"
        }
    }

    /// Aliases rather than pinned ids, so the account's current model for that
    /// tier is used (a new Opus lands automatically).
    var defaultModel: String {
        switch self {
        case .light: "haiku"
        case .mid: "sonnet"
        case .heavy: "opus"
        }
    }

    var defaultThinking: KonThinkingLevel {
        switch self {
        case .light: .off
        case .mid: .brief
        case .heavy: .deep
        }
    }
}

/// How much the model is allowed to think before answering. Kon's replies are
/// read aloud, so thinking is latency the user hears as silence.
enum KonThinkingLevel: String, CaseIterable, Identifiable, Codable {
    case off, brief, deep

    var id: Self { self }

    var title: String {
        switch self {
        case .off: "考えない（最速）"
        case .brief: "少し考える"
        case .deep: "じっくり考える"
        }
    }

    /// `set_max_thinking_tokens` budget for the CLI control request.
    var maxTokens: Int {
        switch self {
        case .off: 0
        case .brief: 4_000
        case .deep: 12_000
        }
    }
}

/// Picks a tier from the user's words, locally and instantly — asking a model
/// which model to use would cost the latency the routing is meant to save.
struct KonModelRouter {
    /// "じっくり考えて" and friends: the user is asking for the good model.
    private static let heavyHints = [
        "じっくり", "しっかり考え", "よく考え", "考えて", "どう思う", "相談",
        "設計", "仕様", "アーキ", "リファクタ", "レビュー", "比較", "検討", "計画",
        "原因", "デバッグ", "バグ", "エラー", "直して", "修正", "実装", "コード",
        "書いて", "作って", "なぜ", "どうして", "提案", "アイデア", "まとめて", "詳しく"
    ]
    /// Things that never need more than the fast model.
    private static let lightHints = [
        "ありがと", "おはよう", "おやすみ", "こんにちは", "こんばんは", "やっほ", "おつかれ",
        "何時", "なんじ", "日付", "何日", "曜日", "今日って",
        "タイマー", "リマイン", "後に教えて", "分後", "時間後",
        "聞こえる", "テスト", "ストップ", "やめて", "ありがとう"
    ]
    /// Below this, a request without heavy hints is small talk or a one-liner.
    private static let lightLengthLimit = 14
    /// Above this, the user is describing a real task.
    private static let heavyLengthFloor = 60

    static func tier(for text: String) -> KonModelTier {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        if heavyHints.contains(where: lowered.contains) { return .heavy }
        if lightHints.contains(where: lowered.contains) { return .light }
        if trimmed.count >= heavyLengthFloor { return .heavy }
        if trimmed.count <= lightLengthLimit { return .light }
        return .mid
    }
}
