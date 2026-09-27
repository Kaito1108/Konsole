import Foundation
import AVFoundation
import os

enum KonListenerState: Equatable {
    case idle
    /// The session started but the mic isn't delivering real audio yet
    /// (Bluetooth mics send digital silence for ~1s while coming up).
    case preparing
    /// The mic is actually picking up audio.
    case listening
    case thinking
}

/// Why a voice session ended without a command, so the user can be told
/// instead of the bubble silently disappearing.
enum KonListenEndReason: Equatable {
    /// ⌥Space again / Escape: the user meant it, nothing to say.
    case cancelled
    /// Nothing loud enough was heard before the wait ran out.
    case noSpeech
    /// The mic never delivered audio (device switch, Bluetooth hiccup).
    case micUnavailable
    /// Only a blip (a cough, a click) was heard.
    case tooShort
    /// Speech was heard but whisper made nothing of it.
    case notUnderstood
    /// Transcription itself failed (e.g. missing model).
    case failed
}

enum KonListenerError: Error, LocalizedError {
    case converterUnavailable

    var errorDescription: String? {
        switch self {
        case .converterUnavailable:
            return "マイク入力のフォーマット変換に失敗しました。"
        }
    }
}

/// Push-to-talk voice capture. The mic stays off until `startSession()` (the
/// ⌥Space hotkey); then one utterance is segmented with a simple energy-based
/// VAD, the mic is turned off again, and the utterance is transcribed locally
/// via whisper. A session that hears nothing for its silence timeout ends on
/// its own.
final class KonListener: @unchecked Sendable {
    /// Voice threshold = noise floor × this, clamped to the range below. A
    /// fixed 0.015 treated soft speech and quiet mics (AirPods) as silence,
    /// ending sessions mid-sentence.
    private static let voiceToNoiseRatio: Float = 3
    private static let minVoiceRMSThreshold: Float = 0.004
    private static let maxVoiceRMSThreshold: Float = 0.015
    private static let initialNoiseFloor: Float = 0.003
    /// Upper bound on the pause that ends an utterance: long enough to survive
    /// a breath mid-sentence. A shorter session silence timeout wins, so a
    /// 1s setting ends the utterance after 1s of silence too.
    private static let maxSilenceHangoverSeconds: Double = 1.6
    private static let minUtteranceSeconds: Double = 0.35
    /// However short the silence setting, give the user this long to start
    /// talking after the hotkey; 1s ended sessions before the first word.
    private static let minPreSpeechWaitSeconds: Double = 3
    /// While capturing, a buffer this far below the utterance's loudest part
    /// counts as silence even if it's above the noise-based threshold. Keeps
    /// a noisy room (fan, AirPods hiss) from holding the session open.
    private static let endpointPeakRatio: Float = 0.15
    private static let maxUtteranceSeconds: Double = 30.0
    private static let micStartupTimeoutSeconds: Double = 4.0
    /// Once audio has started, a gap this long means the tap stopped firing —
    /// e.g. another app (Discord) grabbed the mic and switched AirPods to the
    /// call profile, which silently stops our engine.
    private static let audioStallSeconds: Double = 1.5
    /// The noise floor also follows the quietest buffer of this window, so a
    /// constant background level stuck above the voice threshold (another
    /// app's voice processing boosting the mic) stops counting as speech.
    private static let noiseWindowSeconds: Double = 2.0
    /// Speech must be at least this much louder than the noise floor.
    private static let minVoiceToNoiseRatio: Float = 1.6

    private static let logger = Logger(subsystem: "Konsole", category: "listener")

    /// Fires on the main thread with the listener's high-level state, for UI (icon/bubble) to reflect.
    var onStateChange: ((KonListenerState) -> Void)?
    /// Fires on the main thread with the transcribed command.
    var onCommand: ((String) -> Void)?
    /// Fires on the main thread when a session ends without a command (silence, cancel, empty transcript).
    var onSessionEndedWithoutCommand: ((KonListenEndReason) -> Void)?
    /// Fires on the main thread when local transcription fails (e.g. missing whisper model).
    var onError: ((Error) -> Void)?

    /// Created per session and released afterwards. A stopped-but-alive
    /// AVAudioEngine keeps its input unit open, which holds Bluetooth headsets
    /// like AirPods in the low-quality call profile (HFP) even while idle.
    private var engine: AVAudioEngine?
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?

    // Only touched from the audio tap's serial callback thread.
    private var utteranceSamples: [Float] = []
    private var isCapturingUtterance = false
    private var silenceSeconds: Double = 0
    /// Smoothed loudest level of the current utterance.
    private var utterancePeak: Float = 0
    private var noiseFloor: Float = initialNoiseFloor
    /// When the mic started delivering real audio. The silence timeout counts
    /// from here, not from the hotkey: Bluetooth mics take ~1s to come up and
    /// only send zeros meanwhile, so a short timeout expired before the user
    /// could be heard at all.
    private var audioStartedAt: CFAbsoluteTime?
    private var sessionSilenceTimeout: CFAbsoluteTime = 5
    private var silenceHangoverSeconds: Double = maxSilenceHangoverSeconds
    private var isClosing = false
    /// Last time the tap delivered audio; read by the watchdog on the main thread.
    private var lastBufferAt: CFAbsoluteTime?
    /// Recent per-buffer levels with their durations, oldest first.
    private var recentLevels: [(rms: Float, seconds: Double)] = []
    private var recentLevelsSeconds: Double = 0
    private var watchdog: Timer?
    private var configurationObserver: NSObjectProtocol?

    private(set) var isListening = false

    func startSession(silenceTimeout: TimeInterval) throws {
        guard !isListening else { return }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw KonListenerError.converterUnavailable
        }
        self.converter = converter
        utteranceSamples.removeAll()
        isCapturingUtterance = false
        silenceSeconds = 0
        utterancePeak = 0
        noiseFloor = Self.initialNoiseFloor
        audioStartedAt = nil
        sessionSilenceTimeout = max(silenceTimeout, Self.minPreSpeechWaitSeconds)
        silenceHangoverSeconds = min(silenceTimeout, Self.maxSilenceHangoverSeconds)
        isClosing = false
        lastBufferAt = nil
        recentLevels.removeAll()
        recentLevelsSeconds = 0

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer: buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        self.engine = engine
        isListening = true
        notifyState(.preparing)

        // If the mic never comes up (device switch, engine stopped), don't
        // sit in "listening" forever.
        let engineID = ObjectIdentifier(engine)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.micStartupTimeoutSeconds + sessionSilenceTimeout) { [weak self] in
            guard let self, let current = self.engine, ObjectIdentifier(current) == engineID,
                  self.audioStartedAt == nil else { return }
            self.cancelSession(reason: .micUnavailable)
        }

        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            Self.logger.notice("Audio engine configuration changed mid-session")
            self?.endInterruptedSession()
        }
        let sessionStartedAt = CFAbsoluteTimeGetCurrent()
        let maxSessionSeconds = Self.micStartupTimeoutSeconds + sessionSilenceTimeout + Self.maxUtteranceSeconds + 5
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, self.isListening, !self.isClosing else { return }
            let now = CFAbsoluteTimeGetCurrent()
            if let lastBufferAt = self.lastBufferAt, now - lastBufferAt >= Self.audioStallSeconds {
                Self.logger.notice("Mic stopped delivering audio mid-session")
                self.endInterruptedSession()
            } else if now - sessionStartedAt >= maxSessionSeconds {
                Self.logger.notice("Voice session hit its hard time limit")
                self.endInterruptedSession()
            }
        }
    }

    /// The mic went away or the session ran far too long: transcribe what was
    /// heard so far, or give up if there's nothing. Main thread only.
    private func endInterruptedSession() {
        guard isListening, !isClosing else { return }
        isClosing = true
        // Stop the tap first so the audio thread no longer touches the buffers.
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        if isCapturingUtterance, !utteranceSamples.isEmpty {
            finishUtterance()
        } else {
            cancelSession(reason: .micUnavailable)
        }
    }

    /// Cancels the current session without transcribing anything.
    func cancelSession(reason: KonListenEndReason = .cancelled) {
        guard isListening else { return }
        stopMic()
        notifyState(.idle)
        notifySessionEndedWithoutCommand(reason)
    }

    private func stopMic() {
        guard isListening else { return }
        watchdog?.invalidate()
        watchdog = nil
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine?.reset()
        engine = nil
        converter = nil
        isListening = false
    }

    // MARK: - Audio tap (runs on CoreAudio's realtime callback thread)

    private func process(buffer: AVAudioPCMBuffer) {
        guard !isClosing, let converter, let samples = Self.convert(buffer, with: converter, to: targetFormat) else { return }

        if audioStartedAt == nil {
            // Still warming up: the device is sending digital silence.
            guard samples.contains(where: { $0 != 0 }) else { return }
            audioStartedAt = CFAbsoluteTimeGetCurrent()
            notifyState(.listening)
        }

        lastBufferAt = CFAbsoluteTimeGetCurrent()
        let rms = Self.rms(samples)
        let bufferSeconds = Double(samples.count) / targetFormat.sampleRate

        recentLevels.append((rms, bufferSeconds))
        recentLevelsSeconds += bufferSeconds
        while let oldest = recentLevels.first, recentLevelsSeconds - oldest.seconds >= Self.noiseWindowSeconds {
            recentLevels.removeFirst()
            recentLevelsSeconds -= oldest.seconds
        }
        // Speech has gaps between words, so the window's quietest buffer is
        // background noise even while someone is talking.
        if recentLevelsSeconds >= Self.noiseWindowSeconds * 0.9,
           let quietest = recentLevels.map(\.rms).min(), quietest > noiseFloor {
            noiseFloor = quietest
        }

        var threshold = min(max(noiseFloor * Self.voiceToNoiseRatio, Self.minVoiceRMSThreshold), Self.maxVoiceRMSThreshold)
        threshold = max(threshold, noiseFloor * Self.minVoiceToNoiseRatio)
        if rms <= threshold {
            // Track the room's background level from non-voice buffers only.
            noiseFloor = noiseFloor * 0.9 + rms * 0.1
        }
        // Once someone is talking, "silence" is also relative to how loud they
        // were: background noise stuck above the absolute threshold otherwise
        // never counts as silence and the session never ends.
        let endpointThreshold = isCapturingUtterance ? max(threshold, utterancePeak * Self.endpointPeakRatio) : threshold

        if rms > endpointThreshold {
            isCapturingUtterance = true
            silenceSeconds = 0
            utterancePeak = max(rms, utterancePeak * 0.98)
            utteranceSamples.append(contentsOf: samples)
        } else if isCapturingUtterance {
            silenceSeconds += bufferSeconds
            utteranceSamples.append(contentsOf: samples)
            if silenceSeconds >= silenceHangoverSeconds {
                finishUtterance()
                return
            }
        } else if let audioStartedAt, CFAbsoluteTimeGetCurrent() - audioStartedAt >= sessionSilenceTimeout {
            isClosing = true
            DispatchQueue.main.async { [weak self] in self?.cancelSession(reason: .noSpeech) }
            return
        }

        if Double(utteranceSamples.count) / targetFormat.sampleRate >= Self.maxUtteranceSeconds {
            finishUtterance()
        }
    }

    private func finishUtterance() {
        let samples = utteranceSamples
        utteranceSamples.removeAll()
        isCapturingUtterance = false
        isClosing = true

        let duration = Double(samples.count) / targetFormat.sampleRate
        guard duration >= Self.minUtteranceSeconds else {
            DispatchQueue.main.async { [weak self] in self?.cancelSession(reason: .tooShort) }
            return
        }

        // One command per session: the mic goes off as soon as the utterance ends.
        DispatchQueue.main.async { [weak self] in
            self?.stopMic()
            self?.notifyState(.thinking)
        }
        Task { [weak self] in
            guard let self else { return }
            defer { self.notifyState(.idle) }

            let text: String
            do {
                text = try await KonWhisperClient.shared.transcribe(samples: samples)
            } catch {
                self.notifyError(error)
                self.notifySessionEndedWithoutCommand(.failed)
                return
            }
            let command = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if command.isEmpty {
                self.notifySessionEndedWithoutCommand(.notUnderstood)
            } else {
                self.notifyCommand(command)
            }
        }
    }

    private func notifyState(_ state: KonListenerState) {
        DispatchQueue.main.async { [onStateChange] in onStateChange?(state) }
    }

    private func notifyCommand(_ text: String) {
        DispatchQueue.main.async { [onCommand] in onCommand?(text) }
    }

    private func notifySessionEndedWithoutCommand(_ reason: KonListenEndReason) {
        DispatchQueue.main.async { [onSessionEndedWithoutCommand] in onSessionEndedWithoutCommand?(reason) }
    }

    private func notifyError(_ error: Error) {
        DispatchQueue.main.async { [onError] in onError?(error) }
    }

    // MARK: - Audio conversion

    private static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, to format: AVAudioFormat) -> [Float]? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: outputCapacity) else { return nil }

        var didProvideInput = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
            if didProvideInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            didProvideInput = true
            inputStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, let channelData = outputBuffer.floatChannelData else { return nil }
        let frameCount = Int(outputBuffer.frameLength)
        return Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
    }

    private static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sumOfSquares = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return sqrt(sumOfSquares / Float(samples.count))
    }
}
