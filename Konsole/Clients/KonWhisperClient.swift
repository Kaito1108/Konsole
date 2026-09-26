import Foundation
import WhisperCpp

enum KonWhisperClientError: Error, LocalizedError {
    case modelNotFound

    var errorDescription: String? {
        switch self {
        case .modelNotFound:
            return "音声認識モデル(ggml-large-v3-turbo.bin)が見つかりません。Amicalをインストールするか、モデルファイルを ~/Library/Application Support/Konsole/models/ に配置してください。"
        }
    }
}

/// Fully local speech-to-text via whisper.cpp (large-v3-turbo).
/// Reuses the model already downloaded by Amical if present, to avoid a
/// second multi-GB download; otherwise looks in Konsole's own model folder.
actor KonWhisperClient {
    static let shared = KonWhisperClient()

    private static let modelFileName = "ggml-large-v3-turbo.bin"

    private var context: WhisperContext?

    func transcribe(samples: [Float]) async throws -> String {
        let context = try await resolvedContext()
        return try await context.transcribe(samples: samples, language: "ja")
    }

    private func resolvedContext() async throws -> WhisperContext {
        if let context {
            return context
        }
        let path = try Self.resolveModelPath()
        let context = try WhisperContext.createContext(modelPath: path)
        self.context = context
        return context
    }

    private static func resolveModelPath() throws -> String {
        let fileManager = FileManager.default
        let konsoleModelURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Konsole/models/\(modelFileName)")

        if fileManager.isReadableFile(atPath: konsoleModelURL.path) {
            return konsoleModelURL.path
        }

        let amicalModelURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Amical/models/\(modelFileName)")

        if fileManager.isReadableFile(atPath: amicalModelURL.path) {
            try? fileManager.createDirectory(
                at: konsoleModelURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if let copied = try? fileManager.copyItem(at: amicalModelURL, to: konsoleModelURL) {
                _ = copied
                return konsoleModelURL.path
            }
            // Copy failed (e.g. sandbox); fall back to reading Amical's copy in place.
            return amicalModelURL.path
        }

        throw KonWhisperClientError.modelNotFound
    }
}
