import Foundation

enum KonOverlayPhase: Equatable {
    case hidden
    case listening
    case transcribing
    case thinking
    case reply(text: String, actions: [String])
}

@MainActor
@Observable
final class KonOverlayViewModel {
    private(set) var phase: KonOverlayPhase = .hidden
    /// When the reply started being read aloud, and for how long; drives the
    /// lyrics-style auto scroll. nil = not started yet (stays on the first line).
    private(set) var readingStartedAt: Date?
    private(set) var readingDuration: TimeInterval = 0

    func showListening() {
        phase = .listening
    }

    func showTranscribing() {
        phase = .transcribing
    }

    func showThinking() {
        phase = .thinking
    }

    func showReply(text: String, actions: [String]) {
        phase = .reply(text: text, actions: actions)
        readingStartedAt = nil
        readingDuration = 0
    }

    func startReading(duration: TimeInterval) {
        readingStartedAt = Date()
        readingDuration = duration
    }

    func hide() {
        phase = .hidden
        readingStartedAt = nil
    }
}
