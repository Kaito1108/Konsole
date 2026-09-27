import Foundation
import Observation

/// A timer or reminder the user asked for ("25分後に教えて").
struct KonReminder: Identifiable, Hashable {
    let id: String
    let fireDate: Date
    /// Read aloud as-is when it fires.
    let text: String
}

extension KonReminder: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, fireDate, text
        case localTime
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        fireDate = try container.decode(Date.self, forKey: .fireDate)
        text = try container.decode(String.self, forKey: .text)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(fireDate, forKey: .fireDate)
        try container.encode(text, forKey: .text)
        // Only for Kon reading the file: fireDate is UTC, this is wall-clock time.
        try container.encode(Self.localTimeFormatter.string(from: fireDate), forKey: .localTime)
    }

    private static let localTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "yyyy年M月d日(E) H:mm:ss"
        return formatter
    }()
}

/// Reminders Kon schedules by running `open -g "konsole://remind?..."`.
/// Persisted to a JSON file (which Kon can read to answer "何が登録されてる？")
/// and restored on launch, so a quit or restart doesn't lose them.
@MainActor
@Observable
final class KonReminderStore {
    static let shared = KonReminderStore()

    nonisolated static let fileURL = URL.applicationSupportDirectory
        .appending(path: "Konsole", directoryHint: .isDirectory)
        .appending(path: "reminders.json")
    /// Reminders missed while Konsole wasn't running still fire on launch if
    /// they're at most this late; older ones are dropped.
    private static let missedGracePeriod: TimeInterval = 12 * 60 * 60

    private(set) var reminders: [KonReminder] = []
    /// Called on the main actor when a reminder is due.
    var onFire: ((KonReminder) -> Void)?

    private var timers: [String: Task<Void, Never>] = [:]

    private init() {
        load()
    }

    /// Arms timers for the restored reminders; call once `onFire` is set.
    func start() {
        let now = Date()
        reminders.removeAll { $0.fireDate < now.addingTimeInterval(-Self.missedGracePeriod) }
        save()
        reminders.forEach(arm)
    }

    // MARK: - URL scheme

    /// Handles `konsole://remind?in=秒&text=…`, `konsole://remind?at=UNIX秒&text=…`,
    /// `konsole://remind/cancel?id=…` and `konsole://remind/cancel?all=1`.
    @discardableResult
    func handle(_ url: URL) -> Bool {
        guard url.scheme == "konsole", url.host() == "remind",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        let query = Dictionary(
            (components.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { _, last in last }
        )

        if url.path() == "/cancel" {
            if query["all"] != nil {
                cancelAll()
            } else if let id = query["id"] {
                cancel(id: id)
            }
            return true
        }

        let fireDate: Date
        if let seconds = query["in"].flatMap(TimeInterval.init), seconds > 0 {
            fireDate = Date().addingTimeInterval(seconds)
        } else if let epoch = query["at"].flatMap(TimeInterval.init) {
            fireDate = Date(timeIntervalSince1970: epoch)
        } else {
            return false
        }
        let text = query["text"].flatMap { $0.isEmpty ? nil : $0 } ?? "時間になったよ"
        add(text: text, fireDate: fireDate)
        return true
    }

    // MARK: - Scheduling

    func add(text: String, fireDate: Date) {
        let reminder = KonReminder(id: String(UUID().uuidString.prefix(6)).lowercased(), fireDate: fireDate, text: text)
        reminders.append(reminder)
        reminders.sort { $0.fireDate < $1.fireDate }
        save()
        arm(reminder)
    }

    func cancel(id: String) {
        timers.removeValue(forKey: id)?.cancel()
        reminders.removeAll { $0.id == id }
        save()
    }

    func cancelAll() {
        timers.values.forEach { $0.cancel() }
        timers.removeAll()
        reminders.removeAll()
        save()
    }

    private func arm(_ reminder: KonReminder) {
        timers[reminder.id]?.cancel()
        timers[reminder.id] = Task { [weak self] in
            let delay = max(0, reminder.fireDate.timeIntervalSinceNow)
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.fire(reminder)
        }
    }

    private func fire(_ reminder: KonReminder) {
        timers[reminder.id] = nil
        reminders.removeAll { $0.id == reminder.id }
        save()
        onFire?(reminder)
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        reminders = (try? decoder.decode([KonReminder].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(reminders).write(to: Self.fileURL, options: .atomic)
        } catch {
            // Reminders still fire this session; they just won't survive a restart.
        }
    }
}
