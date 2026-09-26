import Foundation
import whisper

public enum WhisperError: Error, LocalizedError {
    case couldNotInitializeContext(path: String)
    case transcriptionFailed

    public var errorDescription: String? {
        switch self {
        case .couldNotInitializeContext(let path):
            return "whisperモデルの読み込みに失敗しました: \(path)"
        case .transcriptionFailed:
            return "音声の文字起こしに失敗しました。"
        }
    }
}

/// Thin Swift wrapper around whisper.cpp's C API for fully local speech-to-text.
/// whisper.cpp requires single-threaded access to a given context, hence the actor.
public actor WhisperContext {
    private let context: OpaquePointer

    private init(context: OpaquePointer) {
        self.context = context
    }

    deinit {
        whisper_free(context)
    }

    public static func createContext(modelPath: String) throws -> WhisperContext {
        var params = whisper_context_default_params()
        params.flash_attn = true // Metal-accelerated on Apple Silicon

        guard let context = whisper_init_from_file_with_params(modelPath, params) else {
            throw WhisperError.couldNotInitializeContext(path: modelPath)
        }
        return WhisperContext(context: context)
    }

    /// Transcribes 16kHz mono Float32 PCM samples and returns the recognized text.
    /// - Parameter language: BCP-47-ish whisper language code (e.g. "ja"), or nil to auto-detect.
    public func transcribe(samples: [Float], language: String? = "ja") throws -> String {
        let maxThreads = max(1, min(8, ProcessInfo.processInfo.processorCount - 2))
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_realtime = false
        params.print_progress = false
        params.print_timestamps = false
        params.print_special = false
        params.translate = false
        params.n_threads = Int32(maxThreads)
        params.offset_ms = 0
        params.no_context = true
        params.single_segment = false
        params.suppress_blank = true

        return try withOptionalCString(language) { languagePointer in
            params.language = languagePointer

            whisper_reset_timings(context)
            let result = samples.withUnsafeBufferPointer { buffer in
                whisper_full(context, params, buffer.baseAddress, Int32(buffer.count))
            }
            guard result == 0 else {
                throw WhisperError.transcriptionFailed
            }

            var transcription = ""
            for i in 0..<whisper_full_n_segments(context) {
                transcription += String(cString: whisper_full_get_segment_text(context, i))
            }
            return transcription.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

/// Keeps a C string alive for the duration of `body`, since `whisper_full_params.language`
/// is a bare `UnsafePointer<CChar>?` with no ownership of its own.
private func withOptionalCString<T>(_ string: String?, _ body: (UnsafePointer<CChar>?) throws -> T) rethrows -> T {
    guard let string else { return try body(nil) }
    return try string.withCString(body)
}
