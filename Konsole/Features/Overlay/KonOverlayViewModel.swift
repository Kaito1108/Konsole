import Foundation

enum KonOverlayPhase: Equatable {
    case hidden
    case preparing
    case listening
    case transcribing
    case thinking
    case reply(text: String, actions: [String])
    /// Kon is waiting for 許可 / 拒否 on a tool it wants to run.
    case permission(summary: String, detail: String?)
    /// The one-line text box, for asking without speaking.
    case textInput
}

@MainActor
@Observable
final class KonOverlayViewModel {
    private(set) var phase: KonOverlayPhase = .hidden
    /// When the reply started being read aloud, and for how long; drives the
    /// lyrics-style auto scroll. nil = not started yet (stays on the first line).
    private(set) var readingStartedAt: Date?
    private(set) var readingDuration: TimeInterval = 0
    /// The reply is arriving live, so every line shown is already spoken and
    /// the lyrics progress (which needs a known duration) doesn't apply.
    private(set) var isStreaming = false
    /// Answers the permission question; set while `.permission` is showing.
    var onPermissionDecision: ((Bool) -> Void)?
    /// Which model answered ("Haiku 4.5"), shown small next to the reply.
    private(set) var modelLabel: String?
    /// The reply is finished and worth taking away: show the コピー button.
    private(set) var canCopy = false
    /// The コピー button was pressed for the reply on screen.
    private(set) var didCopy = false
    /// What's being typed in the text box.
    var draft = ""
    /// Called with the typed text when Enter is pressed.
    var onSubmitText: ((String) -> Void)?

    func showPreparing() {
        phase = .preparing
    }

    func showListening() {
        phase = .listening
    }

    func showTranscribing() {
        phase = .transcribing
    }

    func showThinking() {
        phase = .thinking
    }

    func showReply(text: String, actions: [String], isStreaming: Bool = false, modelLabel: String? = nil, isCopyable: Bool = false) {
        phase = .reply(text: text, actions: actions)
        canCopy = isCopyable
        didCopy = false
        self.isStreaming = isStreaming
        self.modelLabel = modelLabel
        readingStartedAt = nil
        readingDuration = 0
    }

    /// The reply as it arrives; every line is shown as soon as it's written.
    func showStreamingReply(text: String) {
        phase = .reply(text: text, actions: [])
        canCopy = false
        didCopy = false
        isStreaming = true
        modelLabel = nil
        readingStartedAt = nil
        readingDuration = 0
    }

    func showPermission(summary: String, detail: String?, onDecision: @escaping (Bool) -> Void) {
        phase = .permission(summary: summary, detail: detail)
        onPermissionDecision = onDecision
    }

    func decidePermission(_ allowed: Bool) {
        let decide = onPermissionDecision
        onPermissionDecision = nil
        decide?(allowed)
    }

    func showTextInput() {
        draft = ""
        phase = .textInput
    }

    func submitText() {
        let text = draft
        draft = ""
        onSubmitText?(text)
    }

    func copyReply() {
        guard case .reply(let text, _) = phase else { return }
        KonClipboardClient.copy(KonReplyText(text).plainText)
        didCopy = true
    }

    func startReading(duration: TimeInterval) {
        readingStartedAt = Date()
        readingDuration = duration
    }

    func hide() {
        // A pending question disappearing must not leave the CLI waiting.
        decidePermission(false)
        phase = .hidden
        canCopy = false
        draft = ""
        readingStartedAt = nil
        isStreaming = false
    }

    var isAskingPermission: Bool {
        if case .permission = phase { return true }
        return false
    }

    var isTyping: Bool { phase == .textInput }
}
