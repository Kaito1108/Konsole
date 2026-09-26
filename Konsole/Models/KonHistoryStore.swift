import Foundation
import Observation

/// One saved chat message. Stored as a JSON line in a per-day file.
struct KonHistoryEntry: Identifiable, Codable, Hashable {
    enum Role: String, Codable {
        case user
        case kon
    }

    let id: UUID
    let conversationId: UUID
    let date: Date
    let role: Role
    let text: String
    var actions: [String]
}

/// Persists every conversation to `History/yyyy-MM-dd.jsonl` in the Konsole
/// project folder. Konsole is a personal app, so writing next to its sources
/// (located via #filePath at build time) is intentional.
@MainActor
@Observable
final class KonHistoryStore {
    static let shared = KonHistoryStore()

    /// <project>/History — this file lives at <project>/Konsole/Models/.
    static let directory = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "History", directoryHint: .isDirectory)

    /// All entries, oldest first.
    private(set) var entries: [KonHistoryEntry] = []
    private(set) var lastError: String?

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init() {
        load()
    }

    func append(_ message: KonMessage, conversationId: UUID) {
        let entry = KonHistoryEntry(
            id: message.id,
            conversationId: conversationId,
            date: message.date,
            role: message.role == .kon ? .kon : .user,
            text: message.text,
            actions: message.actions
        )
        entries.append(entry)
        do {
            try write(entry)
            lastError = nil
        } catch {
            lastError = "履歴を保存できませんでした: \(error.localizedDescription)"
        }
    }

    func load() {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: nil) else {
            entries = []
            return
        }
        entries = files
            .filter { $0.pathExtension == "jsonl" }
            .flatMap { file -> [KonHistoryEntry] in
                guard let contents = try? String(contentsOf: file, encoding: .utf8) else { return [] }
                return contents.split(separator: "\n").compactMap { line in
                    try? decoder.decode(KonHistoryEntry.self, from: Data(line.utf8))
                }
            }
            .sorted { $0.date < $1.date }
    }

    private func write(_ entry: KonHistoryEntry) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let file = Self.directory.appending(path: "\(entry.date.formatted(.iso8601.year().month().day())).jsonl")

        var line = try encoder.encode(entry)
        line.append(UInt8(ascii: "\n"))
        if fileManager.fileExists(atPath: file.path(percentEncoded: false)) {
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try line.write(to: file)
        }
    }
}
