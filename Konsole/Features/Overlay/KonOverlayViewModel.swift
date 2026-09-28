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

    func showReply(text: String, actions: [String], isStreaming: Bool = false, modelLabel: String? = nil) {
        phase = .reply(text: text, actions: actions)
        self.isStreaming = isStreaming
        self.modelLabel = modelLabel
        readingStartedAt = nil
        readingDuration = 0
    }

    /// The reply as it arrives; every line is shown as soon as it's written.
    func showStreamingReply(text: String) {
        phase = .reply(text: text, actions: [])
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

    func startReading(duration: TimeInterval) {
        readingStartedAt = Date()
        readingDuration = duration
    }

    func hide() {
        // A pending question disappearing must not leave the CLI waiting.
        decidePermission(false)
        phase = .hidden
        readingStartedAt = nil
        isStreaming = false
    }

    var isAskingPermission: Bool {
        if case .permission = phase { return true }
        return false
    }
}
