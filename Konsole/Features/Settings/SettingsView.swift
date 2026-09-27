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
        case .integrations: IntegrationsPane()
        case .history: HistoryPane(chatViewModel: chatViewModel)
        }
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, voice, shortcuts, integrations, history

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "一般"
        case .voice: "音声"
        case .shortcuts: "ショートカット"
        case .integrations: "連携"
        case .history: "履歴"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .voice: "waveform"
        case .shortcuts: "keyboard"
        case .integrations: "puzzlepiece.extension"
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
                SettingRow(title: "表示するディスプレイ", detail: "ディスプレイが複数あるときに吹き出しを出す場所") {
                    OverlayDisplayPicker(selection: $settings.overlayDisplay)
                }
                Divider()
                SliderRow(title: "読み終わってから閉じるまで", value: $settings.replyDisplaySeconds, range: 1...15, step: 1) {
                    "\(Int($0))秒"
                }
            }
        }
    }
}

private struct OverlayDisplayPicker: View {
    @Binding var selection: KonOverlayDisplay
    @State private var screens: [(id: CGDirectDisplayID, name: String)] = []

    var body: some View {
        Picker("", selection: $selection) {
            Text("マウスがあるディスプレイ").tag(KonOverlayDisplay.mouse)
            Text("メインディスプレイ").tag(KonOverlayDisplay.primary)
            Divider()
            ForEach(screens, id: \.id) { screen in
                Text(screen.name).tag(KonOverlayDisplay.display(screen.id))
            }
            // Keep a disconnected choice selectable instead of silently dropping it.
            if case .display(let id) = selection, !screens.contains(where: { $0.id == id }) {
                Text("未接続のディスプレイ").tag(selection)
            }
        }
        .labelsHidden()
        .frame(maxWidth: 240)
        .onAppear(perform: reloadScreens)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            reloadScreens()
        }
    }

    private func reloadScreens() {
        screens = NSScreen.screens.compactMap { screen in
            screen.displayID.map { (id: $0, name: screen.localizedName) }
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
                SliderRow(title: "無言で終了するまで", value: $settings.sessionSilenceTimeout, range: 1...15, step: 0.5) {
                    "\($0.formatted(.number.precision(.fractionLength(0...1))))秒"
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

// MARK: - Integrations

private struct IntegrationsPane: View {
    @Bindable private var store = KonComposioStore.shared

    var body: some View {
        VStack(spacing: 16) {
            PaneHeader(title: "連携", subtitle: "Composio経由でGmailやカレンダーなどをコンから使えるようにします")
            SettingsCard(title: "Composio") {
                SettingRow(title: "Composioと連携する", detail: "オンにすると、選んだサービスをコンが操作できます") {
                    Toggle("", isOn: $store.isEnabled).labelsHidden()
                }
                if store.isEnabled {
                    Divider()
                    ComposioAPIKeyRow()
                }
            }
            .toggleStyle(.switch)
            .tint(SettingsPalette.accent)

            if store.isEnabled && store.hasAPIKey {
                ComposioSelectedToolkitsCard()
                ComposioToolkitPickerCard()
            }

            if let error = store.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task(id: store.isEnabled && store.hasAPIKey) {
            guard store.isEnabled && store.hasAPIKey else { return }
            await store.loadCatalogIfNeeded()
            await store.refreshStatuses()
        }
        // Coming back from the browser after OAuth: pick up the new connection.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard store.isEnabled && store.hasAPIKey else { return }
            Task { await store.refreshStatuses() }
        }
    }
}

private struct ComposioAPIKeyRow: View {
    private var store = KonComposioStore.shared
    @State private var draft = ""
    @State private var isEditing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingRow(title: "APIキー", detail: "ダッシュボードの Project Settings > API Keys にある ak_ で始まるキー") {
                if store.hasAPIKey && !isEditing {
                    HStack(spacing: 8) {
                        Label("設定済み", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Button("変更") { isEditing = true }
                        Button("削除", role: .destructive) { store.removeAPIKey() }
                    }
                } else {
                    HStack(spacing: 8) {
                        SecureField("ak_...", text: $draft)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 200)
                            .onSubmit(save)
                        Button("保存", action: save)
                            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                        if isEditing {
                            Button("キャンセル") { isEditing = false; draft = "" }
                        }
                    }
                }
            }
            if !store.hasAPIKey {
                Link("Composioでキーを発行する", destination: URL(string: "https://dashboard.composio.dev/~/project/settings/api-keys")!)
                    .font(.caption)
            }
        }
    }

    private func save() {
        store.saveAPIKey(draft)
        draft = ""
        isEditing = false
    }
}

private struct ComposioSelectedToolkitsCard: View {
    private var store = KonComposioStore.shared

    var body: some View {
        SettingsCard {
            HStack {
                Text("使うサービス").font(.headline)
                Spacer()
                if store.isRefreshingStatuses {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        Task { await store.refreshStatuses() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .help("接続状態を更新")
                    .disabled(store.selectedToolkits.isEmpty)
                }
            }
            .padding(.bottom, 8)

            if store.selectedToolkits.isEmpty {
                Text("まだありません。下の一覧から追加してください。")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 10)
            } else {
                ForEach(Array(store.selectedToolkits.enumerated()), id: \.element) { index, slug in
                    if index > 0 { Divider() }
                    ComposioSelectedRow(slug: slug)
                }
            }
        }
    }
}

private struct ComposioSelectedRow: View {
    let slug: String
    private var store = KonComposioStore.shared
    @State private var isConnecting = false

    init(slug: String) {
        self.slug = slug
    }

    var body: some View {
        let toolkit = store.toolkit(for: slug)
        let status = store.statuses[slug]
        HStack(spacing: 12) {
            ToolkitLogo(url: toolkit?.logoURL)
            VStack(alignment: .leading, spacing: 2) {
                Text(toolkit?.name ?? slug)
                ComposioStatusLabel(status: status)
            }
            Spacer()
            if status == .notConnected || status == .pending {
                Button(status == .pending ? "もう一度接続" : "接続") {
                    connect()
                }
                .buttonStyle(.borderedProminent)
                .tint(SettingsPalette.accent)
                .disabled(isConnecting)
            }
            Button {
                store.removeToolkit(slug)
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("コンが使うサービスから外す")
        }
        .padding(.vertical, 8)
    }

    private func connect() {
        isConnecting = true
        Task {
            if let url = await store.connectURL(for: slug) {
                NSWorkspace.shared.open(url)
            }
            isConnecting = false
        }
    }
}

private struct ComposioStatusLabel: View {
    let status: ComposioConnectionStatus?

    var body: some View {
        switch status {
        case .connected:
            Label("接続済み", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
        case .noAuthRequired:
            Label("接続不要", systemImage: "checkmark.circle").foregroundStyle(.green).font(.caption)
        case .pending:
            Label("接続を完了してください", systemImage: "clock").foregroundStyle(.orange).font(.caption)
        case .notConnected:
            Label("未接続", systemImage: "xmark.circle").foregroundStyle(.secondary).font(.caption)
        case nil:
            Text("確認中…").foregroundStyle(.secondary).font(.caption)
        }
    }
}

private struct ComposioToolkitPickerCard: View {
    private var store = KonComposioStore.shared
    @State private var query = ""
    @State private var visibleCount = Self.pageSize

    private static let pageSize = 20

    /// Popular toolkits first; search narrows by name, slug or description.
    private var matches: [ComposioToolkit] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let candidates = store.catalog.filter { !store.selectedToolkits.contains($0.slug) }
        let matching = trimmed.isEmpty ? candidates : candidates.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed)
                || $0.slug.localizedCaseInsensitiveContains(trimmed)
                || $0.summary.localizedCaseInsensitiveContains(trimmed)
        }
        return matching
    }

    var body: some View {
        SettingsCard(title: "サービスを追加") {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Gmail、Slack、Notion…", text: $query)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(SettingsPalette.contentBackground, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
            .padding(.bottom, 8)

            let matches = matches
            let results = matches.prefix(visibleCount)
            if store.isLoadingCatalog {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            } else if matches.isEmpty {
                Text(store.catalog.isEmpty ? "一覧を読み込めませんでした。" : "見つかりませんでした。")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 10)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, toolkit in
                        if index > 0 { Divider() }
                        ComposioPickerRow(toolkit: toolkit) {
                            store.addToolkit(toolkit.slug)
                        }
                        .onAppear {
                            // Reached the bottom: reveal the next page.
                            if index == results.count - 1, visibleCount < matches.count {
                                visibleCount += Self.pageSize
                            }
                        }
                    }
                }
                Text("\(results.count) / \(matches.count)件")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
            }
        }
        .onChange(of: query) { visibleCount = Self.pageSize }
    }
}

private struct ComposioPickerRow: View {
    let toolkit: ComposioToolkit
    let onAdd: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onAdd) {
            HStack(spacing: 12) {
                ToolkitLogo(url: toolkit.logoURL)
                VStack(alignment: .leading, spacing: 2) {
                    Text(toolkit.name)
                    Text(toolkit.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(isHovered ? SettingsPalette.accent : .secondary)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

/// Composio serves logos as SVG, which AsyncImage can't decode; NSImage can.
private struct ToolkitLogo: View {
    let url: URL?
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "app.dashed").foregroundStyle(.tertiary)
            }
        }
        .frame(width: 26, height: 26)
        .padding(3)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.1)))
        .task(id: url) {
            image = nil
            guard let url else { return }
            image = await ToolkitLogoCache.shared.image(for: url)
        }
    }
}

@MainActor
private final class ToolkitLogoCache {
    static let shared = ToolkitLogoCache()
    private var images: [URL: NSImage] = [:]

    func image(for url: URL) async -> NSImage? {
        if let cached = images[url] { return cached }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let image = NSImage(data: data) else { return nil }
        images[url] = image
        return image
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
