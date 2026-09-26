import Foundation
import AVFoundation

enum KonListenerState: Equatable {
    case idle
    case listening
    case thinking
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
    private static let voiceRMSThreshold: Float = 0.015
    private static let silenceHangoverSeconds: Double = 1.2
    private static let minUtteranceSeconds: Double = 0.35
    private static let maxUtteranceSeconds: Double = 12.0

    /// Fires on the main thread with the listener's high-level state, for UI (icon/bubble) to reflect.
    var onStateChange: ((KonListenerState) -> Void)?
    /// Fires on the main thread with the transcribed command.
    var onCommand: ((String) -> Void)?
    /// Fires on the main thread when a session ends without a command (silence, cancel, empty transcript).
    var onSessionEndedWithoutCommand: (() -> Void)?
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
    private var sessionStartedAt: CFAbsoluteTime = 0
    private var sessionSilenceTimeout: CFAbsoluteTime = 5
    private var isClosing = false

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
        sessionStartedAt = CFAbsoluteTimeGetCurrent()
        sessionSilenceTimeout = silenceTimeout
        isClosing = false

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
        notifyState(.listening)
    }

    /// Cancels the current session without transcribing anything.
    func cancelSession() {
        guard isListening else { return }
        stopMic()
        notifyState(.idle)
        notifySessionEndedWithoutCommand()
    }

    private func stopMic() {
        guard isListening else { return }
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

        let rms = Self.rms(samples)
        let bufferSeconds = Double(samples.count) / targetFormat.sampleRate

        if rms > Self.voiceRMSThreshold {
            isCapturingUtterance = true
            silenceSeconds = 0
            utteranceSamples.append(contentsOf: samples)
        } else if isCapturingUtterance {
            silenceSeconds += bufferSeconds
            utteranceSamples.append(contentsOf: samples)
            if silenceSeconds >= Self.silenceHangoverSeconds {
                finishUtterance()
                return
            }
        } else if CFAbsoluteTimeGetCurrent() - sessionStartedAt >= sessionSilenceTimeout {
            isClosing = true
            DispatchQueue.main.async { [weak self] in self?.cancelSession() }
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
            DispatchQueue.main.async { [weak self] in self?.cancelSession() }
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
                self.notifySessionEndedWithoutCommand()
                return
            }
            let command = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if command.isEmpty {
                self.notifySessionEndedWithoutCommand()
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

    private func notifySessionEndedWithoutCommand() {
        DispatchQueue.main.async { [onSessionEndedWithoutCommand] in onSessionEndedWithoutCommand?() }
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
