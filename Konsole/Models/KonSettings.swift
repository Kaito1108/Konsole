import AppKit
import Foundation
import Observation
import ServiceManagement

/// User-adjustable preferences, persisted in UserDefaults. Read live by the
/// voice session, speech and overlay code, so changes apply immediately.
@MainActor
@Observable
final class KonSettings {
    static let shared = KonSettings()

    private enum Key {
        static let speakReplies = "speakReplies"
        static let voicevoxSpeakerId = "voicevoxSpeakerId"
        static let speechSpeed = "speechSpeed"
        static let speechIntonation = "speechIntonation"
        static let sessionSilenceTimeout = "sessionSilenceTimeout"
        static let replyDisplaySeconds = "replyDisplaySeconds"
        static let playsListeningSound = "playsListeningSound"
        static let pushToTalkShortcut = "pushToTalkShortcut"
        static let cancelShortcut = "cancelShortcut"
        static let overlayDisplay = "overlayDisplay"
        static let sharesAppContext = "sharesAppContext"
        static let sharesClipboard = "sharesClipboard"
        static let userCallName = "userCallName"
        static let personaTone = "personaTone"
        static let personaNotes = "personaNotes"
        static let learnsFromConversations = "learnsFromConversations"
        static let routines = "routines"
    }

    private let defaults: UserDefaults

    var speakReplies: Bool {
        didSet { defaults.set(speakReplies, forKey: Key.speakReplies) }
    }
    /// VOICEVOX style id. 23 = WhiteCUL / ノーマル.
    var voicevoxSpeakerId: Int {
        didSet { defaults.set(voicevoxSpeakerId, forKey: Key.voicevoxSpeakerId) }
    }
    var speechSpeed: Double {
        didSet { defaults.set(speechSpeed, forKey: Key.speechSpeed) }
    }
    var speechIntonation: Double {
        didSet { defaults.set(speechIntonation, forKey: Key.speechIntonation) }
    }
    /// How long a voice session waits in silence before giving up.
    var sessionSilenceTimeout: Double {
        didSet { defaults.set(sessionSilenceTimeout, forKey: Key.sessionSilenceTimeout) }
    }
    /// How long the reply bubble stays on screen after it has been read out.
    var replyDisplaySeconds: Double {
        didSet { defaults.set(replyDisplaySeconds, forKey: Key.replyDisplaySeconds) }
    }
    var playsListeningSound: Bool {
        didSet { defaults.set(playsListeningSound, forKey: Key.playsListeningSound) }
    }
    /// Which display the voice overlay appears on.
    var overlayDisplay: KonOverlayDisplay {
        didSet { defaults.set(overlayDisplay.rawValue, forKey: Key.overlayDisplay) }
    }

    /// Tell Kon which app / window / file / page the user is on.
    var sharesAppContext: Bool {
        didSet { defaults.set(sharesAppContext, forKey: Key.sharesAppContext) }
    }
    /// Tell Kon what's on the clipboard (secrets from password managers are skipped).
    var sharesClipboard: Bool {
        didSet { defaults.set(sharesClipboard, forKey: Key.sharesClipboard) }
    }

    /// What Kon calls the user ("カイト", "ボス"...). Empty = no name.
    var userCallName: String {
        didSet { defaults.set(userCallName, forKey: Key.userCallName) }
    }
    var personaTone: KonPersonaTone {
        didSet { defaults.set(personaTone.rawValue, forKey: Key.personaTone) }
    }
    /// Free-form description of Kon's personality and how to talk with the user.
    var personaNotes: String {
        didSet { defaults.set(personaNotes, forKey: Key.personaNotes) }
    }
    /// Let Kon keep notes on the user's habits from past conversations (KonProfileStore).
    var learnsFromConversations: Bool {
        didSet { defaults.set(learnsFromConversations, forKey: Key.learnsFromConversations) }
    }

    /// "When I say X, do Y" phrases, handled by Kon from its system prompt.
    var routines: [KonRoutine] {
        didSet { defaults.set(try? JSONEncoder().encode(routines), forKey: Key.routines) }
    }

    /// The routine part of Kon's system prompt, or nil when there's none.
    var routinesPrompt: String? {
        let lines = routines.filter(\.isUsable).map { routine in
            let triggers = routine.triggers.map { "「\($0)」" }.joined(separator: "・")
            let instruction = routine.instruction
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
            return "- \(triggers) → \(instruction)"
        }
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n")
    }

    /// The persona part of Kon's system prompt.
    var personaPrompt: String {
        var lines = ["- 口調: \(personaTone.instruction)"]
        let name = userCallName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            lines.append("- ユーザーのことは「\(name)」と呼ぶ。毎回呼ぶ必要はなく、自然なときだけ。")
        }
        let notes = personaNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty {
            lines.append("- ユーザーが決めたコンの性格・対応のしかた（返答の短さのルールより優先しない）:\n\(notes)")
        }
        return lines.joined(separator: "\n")
    }

    var pushToTalkShortcut: KonShortcut {
        didSet { saveShortcut(pushToTalkShortcut, forKey: Key.pushToTalkShortcut) }
    }
    var cancelShortcut: KonShortcut {
        didSet { saveShortcut(cancelShortcut, forKey: Key.cancelShortcut) }
    }

    /// Backed by SMAppService rather than UserDefaults, so it reflects what the
    /// user may have changed in System Settings > General > Login Items.
    var launchAtLogin: Bool {
        get {
            access(keyPath: \.launchAtLogin)
            return SMAppService.mainApp.status == .enabled
        }
        set {
            withMutation(keyPath: \.launchAtLogin) {
                do {
                    if newValue {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    launchAtLoginError = error.localizedDescription
                }
            }
        }
    }
    var launchAtLoginError: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.speakReplies: true,
            Key.voicevoxSpeakerId: 23,
            Key.speechSpeed: 1.2,
            Key.speechIntonation: 1.3,
            Key.sessionSilenceTimeout: 5.0,
            Key.replyDisplaySeconds: 3.0,
            Key.playsListeningSound: true,
            Key.sharesAppContext: true,
            Key.sharesClipboard: true,
            Key.userCallName: "",
            Key.personaNotes: "",
            Key.learnsFromConversations: true,
        ])
        speakReplies = defaults.bool(forKey: Key.speakReplies)
        voicevoxSpeakerId = defaults.integer(forKey: Key.voicevoxSpeakerId)
        speechSpeed = defaults.double(forKey: Key.speechSpeed)
        speechIntonation = defaults.double(forKey: Key.speechIntonation)
        sessionSilenceTimeout = defaults.double(forKey: Key.sessionSilenceTimeout)
        replyDisplaySeconds = defaults.double(forKey: Key.replyDisplaySeconds)
        playsListeningSound = defaults.bool(forKey: Key.playsListeningSound)
        sharesAppContext = defaults.bool(forKey: Key.sharesAppContext)
        sharesClipboard = defaults.bool(forKey: Key.sharesClipboard)
        userCallName = defaults.string(forKey: Key.userCallName) ?? ""
        personaTone = defaults.string(forKey: Key.personaTone).flatMap(KonPersonaTone.init(rawValue:)) ?? .friendly
        personaNotes = defaults.string(forKey: Key.personaNotes) ?? ""
        learnsFromConversations = defaults.bool(forKey: Key.learnsFromConversations)
        routines = defaults.data(forKey: Key.routines).flatMap { try? JSONDecoder().decode([KonRoutine].self, from: $0) } ?? []
        overlayDisplay = defaults.string(forKey: Key.overlayDisplay).flatMap(KonOverlayDisplay.init(rawValue:)) ?? .mouse
        pushToTalkShortcut = Self.loadShortcut(from: defaults, forKey: Key.pushToTalkShortcut) ?? .defaultPushToTalk
        cancelShortcut = Self.loadShortcut(from: defaults, forKey: Key.cancelShortcut) ?? .defaultCancel
    }

    private func saveShortcut(_ shortcut: KonShortcut, forKey key: String) {
        defaults.set(try? JSONEncoder().encode(shortcut), forKey: key)
    }

    private static func loadShortcut(from defaults: UserDefaults, forKey key: String) -> KonShortcut? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(KonShortcut.self, from: data)
    }
}

/// A phrase the user says (e.g. おはよう) and what Kon should do for it.
struct KonRoutine: Identifiable, Codable, Hashable {
    var id = UUID()
    /// One or more phrases, separated by 、 or ,.
    var trigger: String
    /// Instruction for Kon, written like a prompt.
    var instruction: String
    var isEnabled = true

    var triggers: [String] {
        trigger.split(whereSeparator: { "、,，".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var isUsable: Bool {
        isEnabled && !triggers.isEmpty && !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Kon's speaking style.
enum KonPersonaTone: String, CaseIterable, Identifiable {
    case friendly, polite, cool, cheerful, gentle

    var id: Self { self }

    var title: String {
        switch self {
        case .friendly: "フレンドリー（タメ口）"
        case .polite: "丁寧（です・ます）"
        case .cool: "クール（淡々と簡潔）"
        case .cheerful: "元気（明るくノリよく）"
        case .gentle: "やさしい（おだやか）"
        }
    }

    var instruction: String {
        switch self {
        case .friendly: "親しい相棒としてタメ口で、気さくに話す。"
        case .polite: "です・ます調で丁寧に話す。堅すぎず感じよく。"
        case .cool: "感情表現は控えめに、淡々と要点だけを話す。タメ口。"
        case .cheerful: "明るく元気なタメ口で、ちょっとしたリアクションも入れる。"
        case .gentle: "おだやかでやさしいタメ口。ユーザーを気づかう一言を添えてもよい。"
        }
    }

    /// Line for the voice preview in Settings.
    var sample: String {
        switch self {
        case .friendly: "やっほー、コンだよ。なんでも聞いてね。"
        case .polite: "こんにちは、コンです。何でもお申し付けください。"
        case .cool: "コンだ。用件をどうぞ。"
        case .cheerful: "やっほー！コンだよ！今日もがんばろー！"
        case .gentle: "こんにちは、コンだよ。無理せずいこうね。"
        }
    }
}

/// Where the voice overlay is shown when more than one display is connected.
enum KonOverlayDisplay: Hashable {
    /// The display the mouse pointer is on.
    case mouse
    /// The display with the menu bar (primary display in System Settings).
    case primary
    /// A specific display, by CGDirectDisplayID. Falls back to `.primary`
    /// while that display is disconnected.
    case display(CGDirectDisplayID)

    init?(rawValue: String) {
        switch rawValue {
        case "mouse": self = .mouse
        case "primary": self = .primary
        default:
            guard rawValue.hasPrefix("display:"),
                  let id = UInt32(rawValue.dropFirst("display:".count)) else { return nil }
            self = .display(id)
        }
    }

    var rawValue: String {
        switch self {
        case .mouse: "mouse"
        case .primary: "primary"
        case .display(let id): "display:\(id)"
        }
    }

    var screen: NSScreen? {
        switch self {
        case .mouse:
            let location = NSEvent.mouseLocation
            return NSScreen.screens.first { NSMouseInRect(location, $0.frame, false) } ?? NSScreen.screens.first
        case .primary:
            return NSScreen.screens.first
        case .display(let id):
            return NSScreen.screens.first { $0.displayID == id } ?? NSScreen.screens.first
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
