import SwiftUI

/// Settings window: a custom sidebar (logo + sections) and a content area
/// that shows each section as a centered card.
struct SettingsView: View {
    var chatViewModel: ChatViewModel
    @State private var selection: SettingsSection = .general

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(selection: $selection)
                .frame(width: 210)
            Divider()
            ScrollView {
                content
                    .frame(maxWidth: 520)
                    .padding(.horizontal, 32)
                    .padding(.top, 48)
                    .padding(.bottom, 32)
                    .frame(maxWidth: .infinity)
            }
            .background(SettingsPalette.contentBackground)
        }
        .frame(minWidth: 780, minHeight: 540)
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var content: some View {
        switch selection {
        case .general: GeneralPane()
        case .voice: VoicePane()
        case .shortcuts: ShortcutsPane()
        case .history: HistoryPane(chatViewModel: chatViewModel)
        }
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, voice, shortcuts, history

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "一般"
        case .voice: "音声"
        case .shortcuts: "ショートカット"
        case .history: "履歴"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .voice: "waveform"
        case .shortcuts: "keyboard"
        case .history: "clock.arrow.circlepath"
        }
    }
}

enum SettingsPalette {
    static let accent = Color.orange
    static let sidebarBackground = Color(nsColor: .windowBackgroundColor)
    static let contentBackground = Color(nsColor: .underPageBackgroundColor)
    static let cardBackground = Color(nsColor: .controlBackgroundColor)
}

// MARK: - Sidebar

private struct SettingsSidebar: View {
    @Binding var selection: SettingsSection

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image("KonFace")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Konsole")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                    Text("v\(AppInfo.version)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 44)
            .padding(.bottom, 20)

            ForEach(SettingsSection.allCases) { section in
                SidebarItem(section: section, isSelected: selection == section) {
                    selection = section
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .background(SettingsPalette.sidebarBackground)
    }
}

private struct SidebarItem: View {
    let section: SettingsSection
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Label(section.title, systemImage: section.systemImage)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
                .background {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(isSelected ? SettingsPalette.accent.opacity(0.08) : (isHovered ? Color.primary.opacity(0.05) : .clear))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(isSelected ? SettingsPalette.accent : .clear, lineWidth: 1.5)
                }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Shared building blocks

private struct SettingsCard<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                Text(title)
                    .font(.headline)
                    .padding(.bottom, 12)
            }
            content
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SettingsPalette.cardBackground, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.06), radius: 10, y: 4)
    }
}

private struct PaneHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 24, weight: .bold))
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 20)
    }
}

private struct SettingRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.vertical, 10)
    }
}

private struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: step)
                .tint(SettingsPalette.accent)
        }
        .padding(.vertical, 8)
    }
}

enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }
}

// MARK: - General

private struct GeneralPane: View {
    @Bindable private var settings = KonSettings.shared

    var body: some View {
        VStack(spacing: 16) {
            PaneHeader(title: "一般", subtitle: "コンのふるまいを調整します")
            SettingsCard {
                SettingRow(title: "ログイン時に起動", detail: "Macにログインしたらコンを常駐させます") {
                    Toggle("", isOn: $settings.launchAtLogin).labelsHidden()
                }
                if let error = settings.launchAtLoginError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Divider()
                SettingRow(title: "返事を読み上げる", detail: "VOICEVOXで返答を声に出します") {
                    Toggle("", isOn: $settings.speakReplies).labelsHidden()
                }
                Divider()
                SettingRow(title: "聞き取り開始の効果音", detail: "聞き始めたときに鳴らします") {
                    Toggle("", isOn: $settings.playsListeningSound).labelsHidden()
                }
            }
            .toggleStyle(.switch)
            .tint(SettingsPalette.accent)

            SettingsCard(title: "吹き出し") {
                SliderRow(title: "読み終わってから閉じるまで", value: $settings.replyDisplaySeconds, range: 1...15, step: 1) {
                    "\(Int($0))秒"
                }
            }
        }
    }
}

// MARK: - Voice

private struct VoicePane: View {
    @Bindable private var settings = KonSettings.shared
    @State private var voices: [VoicevoxVoice] = []
    @State private var voicesError: String?
    @State private var speechClient = KonSpeechClient()

    var body: some View {
        VStack(spacing: 16) {
            PaneHeader(title: "音声", subtitle: "コンの声と聞き取りを設定します")
            SettingsCard(title: "声") {
                SettingRow(title: "話者", detail: "VOICEVOXのキャラクター") {
                    if voices.isEmpty {
                        if voicesError == nil {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("ID \(settings.voicevoxSpeakerId)").foregroundStyle(.secondary)
                        }
                    } else {
                        Picker("", selection: $settings.voicevoxSpeakerId) {
                            ForEach(voices) { voice in
                                Text(voice.name).tag(voice.id)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 240)
                    }
                }
                if let voicesError {
                    Text(voicesError).font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                SliderRow(title: "話す速さ", value: $settings.speechSpeed, range: 0.5...2.0, step: 0.05) {
                    String(format: "%.2f×", $0)
                }
                SliderRow(title: "抑揚", value: $settings.speechIntonation, range: 0...2.0, step: 0.05) {
                    String(format: "%.2f", $0)
                }
                HStack {
                    Spacer()
                    Button {
                        speechClient.speak("こんにちは、コンです。今日もよろしくね。")
                    } label: {
                        Label("試し聞き", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(SettingsPalette.accent)
                }
                .padding(.top, 6)
            }

            SettingsCard(title: "聞き取り") {
                SliderRow(title: "無言で終了するまで", value: $settings.sessionSilenceTimeout, range: 2...15, step: 1) {
                    "\(Int($0))秒"
                }
                Text("\(settings.pushToTalkShortcut.displayString)を押してから何も話さないと、この時間で自動的に終わります。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .task { await loadVoices() }
    }

    private func loadVoices() async {
        do {
            try await VoicevoxEngineLauncher.shared.ensureRunning()
            voices = try await VoicevoxEngineLauncher.shared.availableVoices()
            voicesError = nil
        } catch {
            voicesError = "VOICEVOXに接続できませんでした（\(error.localizedDescription)）"
        }
    }
}

// MARK: - Shortcuts

private struct ShortcutsPane: View {
    @Bindable private var settings = KonSettings.shared

    var body: some View {
        VStack(spacing: 16) {
            PaneHeader(title: "ショートカット", subtitle: "クリックして新しいキーを押すと変更できます")
            SettingsCard {
                SettingRow(title: "声で話しかける", detail: "どのアプリからでも反応します。もう一度押すと聞き取りをやめます") {
                    ShortcutRecorder(
                        shortcut: $settings.pushToTalkShortcut,
                        defaultShortcut: .defaultPushToTalk,
                        requiresModifier: true,
                        conflictsWith: settings.cancelShortcut
                    )
                }
                Divider()
                SettingRow(title: "聞き取りをキャンセル", detail: "聞いている最中だけ有効です") {
                    ShortcutRecorder(
                        shortcut: $settings.cancelShortcut,
                        defaultShortcut: .defaultCancel,
                        requiresModifier: false,
                        conflictsWith: settings.pushToTalkShortcut
                    )
                }
            }
        }
    }
}

/// Click to record: global hotkeys are suspended so the pressed combo reaches
/// this view instead of triggering Kon, then re-grabbed with the new combo.
private struct ShortcutRecorder: View {
    @Binding var shortcut: KonShortcut
    let defaultShortcut: KonShortcut
    let requiresModifier: Bool
    let conflictsWith: KonShortcut

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var message: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                Button(action: toggleRecording) {
                    Group {
                        if isRecording {
                            Text("キーを押してください…")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(SettingsPalette.accent)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                        } else {
                            KeyCaps(keys: shortcut.displayKeys)
                        }
                    }
                    .frame(minWidth: 120)
                    .padding(4)
                    .background {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(isRecording ? SettingsPalette.accent : Color.primary.opacity(0.12), lineWidth: isRecording ? 1.5 : 1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if shortcut != defaultShortcut {
                    Button {
                        shortcut = defaultShortcut
                        KonHotKeyManager.shared.refresh(.pushToTalk)
                        KonHotKeyManager.shared.refresh(.cancel)
                    } label: {
                        Image(systemName: "arrow.uturn.backward.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("元に戻す（\(defaultShortcut.displayString)）")
                }
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(.red)
            }
        }
        .onDisappear(perform: stopRecording)
    }

    private func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        message = nil
        isRecording = true
        KonHotKeyManager.shared.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            record(event)
            return nil
        }
    }

    private func record(_ event: NSEvent) {
        let candidate = KonShortcut(event: event)
        if requiresModifier && candidate.modifiers == 0 && !candidate.isFunctionKey {
            message = "⌥・⌘・⌃・⇧のどれかと組み合わせてください"
            return
        }
        if candidate.keyCode == conflictsWith.keyCode && candidate.modifiers == conflictsWith.modifiers {
            message = "もう一方のショートカットと同じです"
            return
        }
        shortcut = candidate
        message = nil
        stopRecording()
    }

    private func stopRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        if isRecording {
            isRecording = false
            KonHotKeyManager.shared.resume()
        }
    }
}

private struct KeyCaps: View {
    let keys: [String]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Text(key)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15)))
            }
        }
    }
}

// MARK: - History

private struct HistoryPane: View {
    var chatViewModel: ChatViewModel
    private var store = KonHistoryStore.shared
    @State private var query = ""

    init(chatViewModel: ChatViewModel) {
        self.chatViewModel = chatViewModel
    }

    private struct Conversation: Identifiable {
        let id: UUID
        let entries: [KonHistoryEntry]
        var startedAt: Date { entries.first?.date ?? .distantPast }
    }

    /// Conversations, newest first, each keeping only entries matching the search.
    private var conversations: [Conversation] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let matching = trimmed.isEmpty ? store.entries : store.entries.filter { $0.text.localizedCaseInsensitiveContains(trimmed) }
        return Dictionary(grouping: matching, by: \.conversationId)
            .map { Conversation(id: $0.key, entries: $0.value.sorted { $0.date < $1.date }) }
            .sorted { $0.startedAt > $1.startedAt }
    }

    var body: some View {
        VStack(spacing: 16) {
            PaneHeader(title: "履歴", subtitle: "コンと話した内容はすべてここに残ります")
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("履歴を検索", text: $query)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(SettingsPalette.cardBackground, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))

                Button {
                    NSWorkspace.shared.open(KonHistoryStore.directory)
                } label: {
                    Image(systemName: "folder")
                }
                .help("履歴フォルダをFinderで開く")
                .disabled(store.entries.isEmpty)

                Button("新しい会話") {
                    chatViewModel.startNewConversation()
                }
                .disabled(chatViewModel.messages.isEmpty || chatViewModel.isSending)
                .help("今の会話の文脈をリセットします（履歴は消えません）")
            }

            if let error = store.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            if conversations.isEmpty {
                SettingsCard {
                    Text(query.isEmpty ? "まだ会話はありません。" : "見つかりませんでした。")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 28)
                }
            } else {
                LazyVStack(spacing: 14) {
                    ForEach(conversations) { conversation in
                        SettingsCard(title: conversation.startedAt.formatted(.dateTime.year().month().day().weekday().hour().minute())) {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(conversation.entries.enumerated()), id: \.element.id) { index, entry in
                                    if index > 0 { Divider() }
                                    HistoryRow(entry: entry)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct HistoryRow: View {
    let entry: KonHistoryEntry

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(entry.role == .kon ? "コン" : "あなた")
                .font(.caption.weight(.semibold))
                .foregroundStyle(entry.role == .kon ? SettingsPalette.accent : .secondary)
                .frame(width: 44, alignment: .leading)
            Text(entry.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(entry.date, format: .dateTime.hour().minute())
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 10)
    }
}

#Preview {
    SettingsView(chatViewModel: ChatViewModel())
}
