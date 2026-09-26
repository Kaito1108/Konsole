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
        ])
        speakReplies = defaults.bool(forKey: Key.speakReplies)
        voicevoxSpeakerId = defaults.integer(forKey: Key.voicevoxSpeakerId)
        speechSpeed = defaults.double(forKey: Key.speechSpeed)
        speechIntonation = defaults.double(forKey: Key.speechIntonation)
        sessionSilenceTimeout = defaults.double(forKey: Key.sessionSilenceTimeout)
        replyDisplaySeconds = defaults.double(forKey: Key.replyDisplaySeconds)
        playsListeningSound = defaults.bool(forKey: Key.playsListeningSound)
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
