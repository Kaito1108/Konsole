import AVFoundation

/// Reads Kon's replies aloud via a local VOICEVOX engine (http://127.0.0.1:50021),
/// falling back to the system TTS engine if VOICEVOX isn't reachable.
/// Voice, speed and intonation come from `KonSettings` at the time of each call.
@MainActor
final class KonSpeechClient {
    private static let engineBaseURL = URL(string: "http://127.0.0.1:50021")!
    /// Rough speaking rate for the system voice, whose duration isn't known upfront.
    private static let systemVoiceCharactersPerSecond = 7.0

    private let settings = KonSettings.shared

    private let synthesizer = AVSpeechSynthesizer()
    private var audioPlayer: AVAudioPlayer?
    private let playbackObserver = PlaybackObserver()
    private var playbackContinuation: CheckedContinuation<Void, Never>?

    /// Bumped by `stop()` and by each new stream, so chunks of an abandoned
    /// reply never reach the speaker.
    private var streamGeneration = 0
    /// Sentences of the reply being streamed, synthesized as soon as they
    /// arrive (concurrently) but played strictly in order.
    private var streamChunks: [(text: String, audio: Task<Data?, Never>)] = []
    private var isStreamClosed = true
    private var isStreamPlaying = false
    private var streamOnStart: ((TimeInterval) -> Void)?
    private var streamOnFinish: (() -> Void)?

    init() {
        synthesizer.delegate = playbackObserver
    }

    /// - Parameters:
    ///   - onStart: Called when audio actually starts, with its (estimated) duration in seconds.
    ///   - onFinish: Called when playback ends on its own (not after `stop()`).
    func speak(_ text: String, onStart: @escaping (TimeInterval) -> Void = { _ in }, onFinish: @escaping () -> Void = {}) {
        guard !text.isEmpty else { return }

        Task {
            do {
                let audioData = try await synthesizeWithVoicevox(text)
                play(audioData, onStart: onStart, onFinish: onFinish)
            } catch {
                speakWithSystemVoice(text, onStart: onStart, onFinish: onFinish)
            }
        }
    }

    func stop() {
        streamGeneration += 1
        for chunk in streamChunks { chunk.audio.cancel() }
        streamChunks.removeAll()
        isStreamClosed = true
        streamOnStart = nil
        streamOnFinish = nil
        playbackObserver.onFinish = nil
        synthesizer.stopSpeaking(at: .immediate)
        audioPlayer?.stop()
        resumePlayback()
    }

    // MARK: - Streaming

    /// Reads a reply that is still being written: sentences are handed over with
    /// `appendStream` as they arrive and played back to back.
    /// - Parameters:
    ///   - onStart: Called when the first chunk starts playing, with its duration.
    ///   - onFinish: Called once every chunk has played and the stream is closed.
    func startStream(onStart: @escaping (TimeInterval) -> Void = { _ in }, onFinish: @escaping () -> Void = {}) {
        stop()
        isStreamClosed = false
        streamOnStart = onStart
        streamOnFinish = onFinish
    }

    func appendStream(_ text: String) {
        let sentence = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sentence.isEmpty, !isStreamClosed else { return }
        let generation = streamGeneration
        let audio = Task { [weak self] () -> Data? in
            guard let self, generation == streamGeneration else { return nil }
            return try? await synthesizeWithVoicevox(sentence)
        }
        streamChunks.append((sentence, audio))
        playStreamIfNeeded(generation: generation)
    }

    /// No more text is coming; `onFinish` fires once the queue has drained.
    func endStream() {
        guard !isStreamClosed else { return }
        isStreamClosed = true
        if !isStreamPlaying {
            finishStream(generation: streamGeneration)
        }
    }

    /// Whether a streamed reply is still being spoken (or waiting for more text).
    var isStreaming: Bool { !isStreamClosed || isStreamPlaying }

    private func playStreamIfNeeded(generation: Int) {
        guard !isStreamPlaying else { return }
        isStreamPlaying = true
        Task { [weak self] in
            guard let self else { return }
            var isFirstChunk = true
            while generation == streamGeneration {
                guard !streamChunks.isEmpty else {
                    if isStreamClosed { break }
                    // Waiting for the model to finish the next sentence.
                    try? await Task.sleep(for: .milliseconds(60))
                    continue
                }
                let chunk = streamChunks.removeFirst()
                let audio = await chunk.audio.value
                guard generation == streamGeneration else { break }
                let onStart = streamOnStart
                let reportStart: (TimeInterval) -> Void = { duration in
                    guard isFirstChunk else { return }
                    isFirstChunk = false
                    onStart?(duration)
                }
                if let audio {
                    await playAndWait(audio, onStart: reportStart)
                } else {
                    await speakWithSystemVoiceAndWait(chunk.text, onStart: reportStart)
                }
            }
            isStreamPlaying = false
            if isStreamClosed {
                finishStream(generation: generation)
            }
        }
    }

    private func finishStream(generation: Int) {
        guard generation == streamGeneration, streamChunks.isEmpty else { return }
        let handler = streamOnFinish
        streamOnFinish = nil
        streamOnStart = nil
        handler?()
    }

    // MARK: - VOICEVOX

    private func synthesizeWithVoicevox(_ text: String) async throws -> Data {
        try await VoicevoxEngineLauncher.shared.ensureRunning()
        let speakerId = settings.voicevoxSpeakerId
        let query = try applyProsody(to: try await audioQuery(for: text, speakerId: speakerId))
        return try await synthesis(query: query, speakerId: speakerId)
    }

    // VOICEVOX's default audio_query prosody reads flat/robotic ("棒読み"), so the
    // defaults bump intonation and ease speed slightly; both are user-adjustable.
    private func applyProsody(to queryData: Data) throws -> Data {
        guard var query = try JSONSerialization.jsonObject(with: queryData) as? [String: Any] else {
            return queryData
        }
        query["speedScale"] = settings.speechSpeed
        query["intonationScale"] = settings.speechIntonation
        return try JSONSerialization.data(withJSONObject: query)
    }

    private func audioQuery(for text: String, speakerId: Int) async throws -> Data {
        var components = URLComponents(url: Self.engineBaseURL.appendingPathComponent("audio_query"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "text", value: text),
            URLQueryItem(name: "speaker", value: String(speakerId))
        ]
        guard let url = components?.url else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.validate(response)
        return data
    }

    private func synthesis(query: Data, speakerId: Int) async throws -> Data {
        var components = URLComponents(url: Self.engineBaseURL.appendingPathComponent("synthesis"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "speaker", value: String(speakerId))
        ]
        guard let url = components?.url else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = query

        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.validate(response)
        return data
    }

    private static func validate(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
    }

    /// Plays one chunk and returns when it has finished (or was stopped).
    private func playAndWait(_ audioData: Data, onStart: (TimeInterval) -> Void) async {
        audioPlayer?.stop()
        guard let player = try? AVAudioPlayer(data: audioData) else { return }
        player.delegate = playbackObserver
        audioPlayer = player
        await withCheckedContinuation { continuation in
            playbackContinuation = continuation
            playbackObserver.onFinish = { [weak self] in self?.resumePlayback() }
            player.play()
            onStart(player.duration)
        }
    }

    private func speakWithSystemVoiceAndWait(_ text: String, onStart: (TimeInterval) -> Void) async {
        await withCheckedContinuation { continuation in
            playbackContinuation = continuation
            speakWithSystemVoice(text, onStart: onStart) { [weak self] in self?.resumePlayback() }
        }
    }

    private func resumePlayback() {
        guard let continuation = playbackContinuation else { return }
        playbackContinuation = nil
        continuation.resume()
    }

    private func play(_ audioData: Data, onStart: (TimeInterval) -> Void, onFinish: @escaping () -> Void) {
        audioPlayer?.stop()
        guard let player = try? AVAudioPlayer(data: audioData) else {
            onFinish()
            return
        }
        player.delegate = playbackObserver
        playbackObserver.onFinish = onFinish
        audioPlayer = player
        player.play()
        onStart(player.duration)
    }

    // MARK: - Fallback

    private func speakWithSystemVoice(_ text: String, onStart: (TimeInterval) -> Void, onFinish: @escaping () -> Void) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "ja-JP")
        playbackObserver.onFinish = onFinish
        synthesizer.speak(utterance)
        onStart(Double(text.count) / Self.systemVoiceCharactersPerSecond)
    }
}

/// Bridges AVAudioPlayer / AVSpeechSynthesizer completion back to the main actor.
private final class PlaybackObserver: NSObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    var onFinish: (() -> Void)?

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.finish() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finish() }
    }

    private func finish() {
        let handler = onFinish
        onFinish = nil
        handler?()
    }
}
