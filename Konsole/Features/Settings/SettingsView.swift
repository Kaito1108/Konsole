import AppKit
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
        case .projects: ProjectsPane()
        case .models: ModelsPane()
        case .persona: PersonaPane()
        case .routines: RoutinesPane()
        case .voice: VoicePane()
        case .shortcuts: ShortcutsPane()
        case .integrations: IntegrationsPane()
        case .history: HistoryPane(chatViewModel: chatViewModel)
        }
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, projects, models, persona, routines, voice, shortcuts, integrations, history

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "一般"
        case .projects: "作業フォルダ"
        case .models: "モデル"
        case .persona: "性格・学習"
        case .routines: "定型フレーズ"
        case .voice: "音声"
        case .shortcuts: "ショートカット"
        case .integrations: "連携"
        case .history: "履歴"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .projects: "folder"
        case .models: "cpu"
        case .persona: "pawprint"
        case .routines: "text.bubble"
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
                SettingRow(title: "文字で聞いたときも読み上げる", detail: "オフなら\(settings.textInputShortcut.displayString)で文字入力したときは吹き出しだけで答えます") {
                    Toggle("", isOn: $settings.speaksTypedReplies).labelsHidden()
                }
                .disabled(!settings.speakReplies)
                Divider()
                SettingRow(title: "聞き取り開始の効果音", detail: "聞き始めたときに鳴らします") {
                    Toggle("", isOn: $settings.playsListeningSound).labelsHidden()
                }
            }
            .toggleStyle(.switch)
            .tint(SettingsPalette.accent)

            WorkContextCard()

            UpdateCard()

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

/// Rebuild from source and replace the installed app (KonUpdater).
private struct UpdateCard: View {
    private var updater = KonUpdater.shared

    var body: some View {
        SettingsCard(title: "アップデート") {
            SettingRow(
                title: "最新のソースで更新",
                detail: "ソースをビルドして /Applications のKonsoleを置き換え、再起動します"
            ) {
                if updater.state == .building {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("ビルド中…").foregroundStyle(.secondary)
                    }
                } else {
                    Button("更新") { updater.update() }
                }
            }
            if let root = updater.sourceRoot {
                Text(root.path(percentEncoded: false))
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
            if case .failed(let message) = updater.state {
                HStack(alignment: .top) {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                    Spacer()
                    Button("ログを表示") { updater.revealLog() }
                        .controlSize(.small)
                }
                .padding(.top, 6)
            }
        }
    }
}

/// What Kon may know about the current work (KonContextProvider).
private struct WorkContextCard: View {
    @Bindable private var settings = KonSettings.shared
    @State private var isTrusted = KonContextProvider.shared.isAccessibilityTrusted

    var body: some View {
        SettingsCard(title: "作業状況") {
            SettingRow(title: "作業中のアプリを伝える", detail: "アプリ名・ウィンドウ名・開いているファイル・Finderの選択・ブラウザのページ") {
                Toggle("", isOn: $settings.sharesAppContext).labelsHidden()
            }
            if settings.sharesAppContext {
                HStack(spacing: 8) {
                    if isTrusted {
                        Label("アクセシビリティ許可済み", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("ウィンドウ名とファイルにはアクセシビリティの許可が必要です", systemImage: "exclamationmark.circle")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("許可する") { KonContextProvider.shared.requestAccessibility() }
                    }
                }
                .font(.caption)
                .padding(.bottom, 6)
            }
            Divider()
            SettingRow(title: "クリップボードを伝える", detail: "コピーした内容を「これ」で扱えるようにします（パスワード管理アプリのコピーは除外）") {
                Toggle("", isOn: $settings.sharesClipboard).labelsHidden()
            }
        }
        .toggleStyle(.switch)
        .tint(SettingsPalette.accent)
        // Granting happens in System Settings; re-check when coming back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            isTrusted = KonContextProvider.shared.isAccessibilityTrusted
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

// MARK: - Projects

private struct ProjectsPane: View {
    @Bindable private var settings = KonSettings.shared

    var body: some View {
        VStack(spacing: 16) {
            PaneHeader(
                title: "作業フォルダ",
                subtitle: "コンが作業するフォルダを登録します。声で「〇〇に移動して」と言えば切り替わります"
            )
            SettingsCard(title: "今の作業フォルダ") {
                SettingRow(title: "作業フォルダ", detail: settings.activeProject?.expandedPath ?? "指定なし（ホームフォルダ）") {
                    Picker("", selection: $settings.activeProjectId) {
                        Text("指定なし").tag(UUID?.none)
                        ForEach(settings.usableProjects) { project in
                            Text(project.trimmedName).tag(Optional(project.id))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220)
                }
                Text("ファイル名だけの指示や「このファイル」は、このフォルダを基準に探します。登録したほかのフォルダも読めます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if settings.projects.isEmpty {
                SettingsCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("まだ登録されていません")
                        Text("例: 名前「Konsole」、フォルダ「~/WorkSpace/Swift/Konsole」→ 「Konsoleに移動して」で切り替わります")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(settings.projects) { project in
                ProjectCard(
                    project: binding(for: project),
                    isActive: settings.activeProjectId == project.id,
                    onActivate: { settings.activeProjectId = project.id },
                    onDelete: {
                        if settings.activeProjectId == project.id { settings.activeProjectId = nil }
                        settings.projects.removeAll { $0.id == project.id }
                    }
                )
            }
            HStack {
                Text("「参照」にすると、コンは中を読むだけで変更しません。変更は次に話しかけたときから反映されます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    settings.projects.append(KonProject(name: "", path: ""))
                } label: {
                    Label("追加", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .tint(SettingsPalette.accent)
            }
        }
    }

    /// Looks the project up by id on every access, so a focused text field
    /// doesn't read a stale index after a row above it is deleted.
    private func binding(for project: KonProject) -> Binding<KonProject> {
        Binding(
            get: { settings.projects.first { $0.id == project.id } ?? project },
            set: { newValue in
                guard let index = settings.projects.firstIndex(where: { $0.id == project.id }) else { return }
                settings.projects[index] = newValue
            }
        )
    }
}

private struct ProjectCard: View {
    @Binding var project: KonProject
    let isActive: Bool
    let onActivate: () -> Void
    let onDelete: () -> Void

    var body: some View {
        SettingsCard {
            HStack(spacing: 10) {
                TextField("名前（例: Konsole、ノートブック）", text: $project.name)
                    .textFieldStyle(.roundedBorder)
                if isActive {
                    Text("使用中")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(SettingsPalette.accent.opacity(0.18), in: Capsule())
                }
                Toggle("", isOn: $project.isEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(SettingsPalette.accent)
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("削除")
            }
            HStack(spacing: 8) {
                TextField("フォルダのパス", text: $project.path)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                Button("選ぶ…") {
                    if let path = Self.chooseFolder() { project.path = path }
                }
            }
            .padding(.top, 10)
            if !project.trimmedPath.isEmpty, !project.folderExists {
                Text("このフォルダが見つからないよ")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.top, 4)
            }
            TextField("別の言い方（例: コンソール、こんそーる）", text: $project.aliases)
                .textFieldStyle(.roundedBorder)
                .padding(.top, 8)
            Text("聞き取りの揺れに備えて、「、」で区切って登録できます")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            Toggle("参照専用（中のファイルは変更しない）", isOn: $project.isReadOnly)
                .toggleStyle(.checkbox)
                .padding(.top, 8)
            Text("コンへのメモ")
                .padding(.top, 10)
                .padding(.bottom, 6)
            MemoEditor(text: $project.notes, minHeight: 56, placeholder: "例: Swiftのメニューバーアプリ。ビルドはxcodebuildで。")
            HStack {
                Spacer()
                Button("この作業フォルダにする", action: onActivate)
                    .disabled(isActive || !project.isUsable)
            }
            .padding(.top, 10)
        }
        .opacity(project.isEnabled ? 1 : 0.6)
    }

    private static func chooseFolder() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "選択"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path(percentEncoded: false)
    }
}

// MARK: - Models

private struct ModelsPane: View {
    @Bindable private var settings = KonSettings.shared

    var body: some View {
        VStack(spacing: 16) {
            PaneHeader(title: "モデル", subtitle: "用件の重さでモデルと考える時間を使い分けます")
            SettingsCard(title: "使い分け") {
                SettingRow(
                    title: "用件に合わせて切り替える",
                    detail: "あいさつや時刻はいちばん速いモデル、調査やコードは賢いモデルで答えます"
                ) {
                    Toggle("", isOn: $settings.routesModelByRequest)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(SettingsPalette.accent)
                }
                Divider()
                ForEach(KonModelTier.allCases) { tier in
                    ModelTierRow(tier: tier)
                    if tier != KonModelTier.allCases.last { Divider() }
                }
                Text("モデルは haiku / sonnet / opus のような別名でも、claude-opus-5 のようなIDでも指定できます。別名なら、アカウントで使える最新のモデルが自動で当たります。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 10)
            }

            SettingsCard(title: "話し方・確認") {
                SettingRow(title: "書けたところから話す", detail: "答えが全部そろうのを待たず、文ができるたびに読み上げます") {
                    Toggle("", isOn: $settings.streamsReplies)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(SettingsPalette.accent)
                }
                Divider()
                SettingRow(title: "確認を求められたら聞く", detail: "Claude（autoモード）が確認を求めてきたときだけ、吹き出しに「許可 / 拒否」のボタンを出します。切ると、それも黙って実行されます") {
                    Toggle("", isOn: $settings.asksToolPermission)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(SettingsPalette.accent)
                }
            }
            Text("どちらも変更は次に話しかけたときから反映されます。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ModelTierRow: View {
    let tier: KonModelTier
    private let settings = KonSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tier.title)
                .font(.subheadline.weight(.semibold))
            HStack(spacing: 8) {
                TextField("モデル", text: Binding(
                    get: { settings.model(for: tier) },
                    set: { settings.setModel($0, for: tier) }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 170)
                Picker("", selection: Binding(
                    get: { settings.thinking(for: tier) },
                    set: { settings.setThinking($0, for: tier) }
                )) {
                    ForEach(KonThinkingLevel.allCases) { level in
                        Text(level.title).tag(level)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 180)
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 10)
        .opacity(settings.routesModelByRequest || tier == .mid ? 1 : 0.45)
    }
}

// MARK: - Persona

private struct PersonaPane: View {
    @Bindable private var settings = KonSettings.shared
    @State private var speechClient = KonSpeechClient()

    var body: some View {
        VStack(spacing: 16) {
            PaneHeader(title: "性格・学習", subtitle: "コンの話し方と、あなたについて覚えていることを設定します")
            SettingsCard(title: "話し方") {
                SettingRow(title: "あなたの呼び方", detail: "空欄なら名前では呼びません") {
                    TextField("例: カイト", text: $settings.userCallName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 200)
                }
                Divider()
                SettingRow(title: "口調") {
                    Picker("", selection: $settings.personaTone) {
                        ForEach(KonPersonaTone.allCases) { tone in
                            Text(tone.title).tag(tone)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220)
                }
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("性格・対応のしかた")
                    Text("自由に書けます。例: 皮肉っぽいけど根はやさしい / 迷っていたら選択肢を2つに絞って / 壁打ちのときは質問で返して")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    MemoEditor(text: $settings.personaNotes, minHeight: 90)
                }
                .padding(.vertical, 10)
                HStack {
                    Text("変更は次に話しかけたときから反映されます")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        speechClient.speak(settings.personaTone.sample)
                    } label: {
                        Label("口調を試し聞き", systemImage: "play.fill")
                    }
                }
            }

            ProfileCard()
        }
    }
}

/// What Kon has learned about the user (KonProfileStore).
private struct ProfileCard: View {
    @Bindable private var settings = KonSettings.shared
    private var store = KonProfileStore.shared
    @State private var draft = ""
    @State private var confirmsReset = false

    var body: some View {
        SettingsCard(title: "あなたについてのメモ") {
            SettingRow(title: "会話から自動で学習する", detail: "話し方の癖や、だいたい何を言いたいかを会話から覚えます") {
                Toggle("", isOn: $settings.learnsFromConversations).labelsHidden()
            }
            .toggleStyle(.switch)
            .tint(SettingsPalette.accent)
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if store.isLearning {
                        ProgressView().controlSize(.small)
                    }
                }
                MemoEditor(text: $draft, minHeight: 180, placeholder: "まだメモはありません。話しかけるうちに増えていきます。直接書いてもOKです。")
                if let error = store.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                HStack {
                    Button("リセット", role: .destructive) { confirmsReset = true }
                        .disabled(store.text.isEmpty && draft.isEmpty)
                    Spacer()
                    Button("今すぐ学習") { store.learnNow() }
                        .disabled(store.isLearning || draft != store.text)
                    Button("保存") { store.save(draft) }
                        .buttonStyle(.borderedProminent)
                        .tint(SettingsPalette.accent)
                        .disabled(draft == store.text)
                }
                .padding(.top, 4)
            }
            .padding(.vertical, 10)
            Text("コンに「〇〇って覚えておいて」と言っても追記されます。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .confirmationDialog("メモを全部消しますか？", isPresented: $confirmsReset) {
            Button("消す", role: .destructive) { store.reset() }
        } message: {
            Text("これまでの会話はもう学習に使われません。")
        }
        .onAppear {
            store.reload()
            draft = store.text
        }
        .onChange(of: store.text) { _, newValue in draft = newValue }
    }

    private var statusText: String {
        if store.isLearning { return "会話から学習中…" }
        var parts: [String] = []
        if let date = store.lastLearnedAt {
            parts.append("最終学習: \(date.formatted(date: .abbreviated, time: .shortened))")
        }
        parts.append("未学習の発言: \(store.pendingMessageCount)件")
        return parts.joined(separator: "・")
    }
}

// MARK: - Routines

private struct RoutinesPane: View {
    @Bindable private var settings = KonSettings.shared

    var body: some View {
        VStack(spacing: 16) {
            PaneHeader(title: "定型フレーズ", subtitle: "決まった言葉を言ったときに、コンにしてほしいことを登録します")
            if settings.routines.isEmpty {
                SettingsCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("まだ登録されていません")
                        Text("例: 「おはよう」→「今日の日付と予定を確認して、未読の大事なメールがあれば一言で教えて。最後に今日も頑張ろうって言って」")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(settings.routines) { routine in
                RoutineCard(routine: binding(for: routine)) {
                    settings.routines.removeAll { $0.id == routine.id }
                }
            }
            HStack {
                Text("言い回しが少し違っても、コンが意味で判断して実行します。変更は次に話しかけたときから反映されます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    settings.routines.append(KonRoutine(trigger: "", instruction: ""))
                } label: {
                    Label("追加", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .tint(SettingsPalette.accent)
            }
        }
    }

    /// Looks the routine up by id on every access. `ForEach($settings.routines)`
    /// hands out index-based bindings, and a text field that is still focused
    /// reads its index after the row is deleted, crashing with out of range.
    private func binding(for routine: KonRoutine) -> Binding<KonRoutine> {
        Binding(
            get: { settings.routines.first { $0.id == routine.id } ?? routine },
            set: { newValue in
                guard let index = settings.routines.firstIndex(where: { $0.id == routine.id }) else { return }
                settings.routines[index] = newValue
            }
        )
    }
}

private struct RoutineCard: View {
    @Binding var routine: KonRoutine
    let onDelete: () -> Void

    var body: some View {
        SettingsCard {
            HStack(spacing: 10) {
                TextField("きっかけの言葉（例: おはよう、おはー）", text: $routine.trigger)
                    .textFieldStyle(.roundedBorder)
                Toggle("", isOn: $routine.isEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(SettingsPalette.accent)
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("削除")
            }
            Text("「、」で区切ると複数の言葉を登録できます")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
                .padding(.bottom, 10)
            Text("コンへの指示")
                .padding(.bottom, 6)
            MemoEditor(text: $routine.instruction, minHeight: 70, placeholder: "例: 今日の予定を確認して、最初の予定まであと何分か教えて")
        }
        .opacity(routine.isEnabled ? 1 : 0.6)
    }
}

private struct MemoEditor: View {
    @Binding var text: String
    var minHeight: CGFloat
    var placeholder: String?

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 12))
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(minHeight: minHeight)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
            .overlay(alignment: .topLeading) {
                if text.isEmpty, let placeholder {
                    Text(placeholder)
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .allowsHitTesting(false)
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
                SliderRow(title: "無言で終了するまで", value: $settings.sessionSilenceTimeout, range: 1...15, step: 0.5) {
                    "\($0.formatted(.number.precision(.fractionLength(0...1))))秒"
                }
                Text("\(settings.pushToTalkShortcut.displayString)を押してから何も話さないと、この時間（最低3秒）で自動的に終わります。話し終わったあとは、この時間（最大1.6秒）黙ると文字起こしに進みます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SettingsCard(title: "連続会話") {
                SettingRow(
                    title: "答えたあとも聞き続ける",
                    detail: "コンが話し終わったらマイクが開くので、\(settings.pushToTalkShortcut.displayString)を押し直さずに続けて話せます"
                ) {
                    Toggle("", isOn: $settings.continuesConversation)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(SettingsPalette.accent)
                }
                if settings.continuesConversation {
                    Divider()
                    SliderRow(title: "次の言葉を待つ時間", value: $settings.continuousSilenceTimeout, range: 2...15, step: 0.5) {
                        "\($0.formatted(.number.precision(.fractionLength(0...1))))秒"
                    }
                    Text("この時間だまっていると、何も言わずに会話を終わります。\(settings.cancelShortcut.displayString)でも終われます。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
                        conflictsWith: [settings.cancelShortcut, settings.textInputShortcut]
                    )
                }
                Divider()
                SettingRow(title: "文字で話しかける", detail: "声を出せない場所向け。吹き出しの位置に入力欄が出て、Enterで送ります") {
                    ShortcutRecorder(
                        shortcut: $settings.textInputShortcut,
                        defaultShortcut: .defaultTextInput,
                        requiresModifier: true,
                        conflictsWith: [settings.pushToTalkShortcut, settings.cancelShortcut]
                    )
                }
                Divider()
                SettingRow(title: "コンを止める", detail: "聞き取り・考え中・読み上げ中と、文字の入力中だけ有効です") {
                    ShortcutRecorder(
                        shortcut: $settings.cancelShortcut,
                        defaultShortcut: .defaultCancel,
                        requiresModifier: false,
                        conflictsWith: [settings.pushToTalkShortcut, settings.textInputShortcut]
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
    let conflictsWith: [KonShortcut]

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
                        KonHotKeyManager.shared.refresh(.textInput)
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
        if conflictsWith.contains(where: { $0.keyCode == candidate.keyCode && $0.modifiers == candidate.modifiers }) {
            message = "ほかのショートカットと同じです"
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
                        Task { await store.refreshStatuses(reloadProfiles: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .help("接続状態を更新")
                    .disabled(store.selectedToolkits.isEmpty)
                }
            }
            .padding(.bottom, 8)

            if store.lacksAccountPermission {
                ComposioAccountPermissionNotice()
                    .padding(.bottom, 8)
            }

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
    @State private var isAddingAccount = false

    init(slug: String) {
        self.slug = slug
    }

    var body: some View {
        let toolkit = store.toolkit(for: slug)
        let status = store.statuses[slug]
        let accounts = store.accounts[slug] ?? []
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                ToolkitLogo(url: toolkit?.logoURL)
                VStack(alignment: .leading, spacing: 2) {
                    Text(toolkit?.name ?? slug)
                    ComposioStatusLabel(status: status, activeAccounts: accounts.filter(\.isActive).count)
                }
                Spacer()
                if status == .notConnected || status == .pending, accounts.isEmpty {
                    Button(status == .pending ? "もう一度接続" : "接続") {
                        connect(alias: nil)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(SettingsPalette.accent)
                    .disabled(isConnecting)
                } else if !accounts.isEmpty, store.canAddAccount(to: slug) {
                    Button {
                        isAddingAccount = true
                    } label: {
                        Label("アカウントを追加", systemImage: "plus")
                    }
                    .disabled(isConnecting)
                    .popover(isPresented: $isAddingAccount, arrowEdge: .bottom) {
                        ComposioAddAccountForm(
                            hasUnnamedAccount: accounts.contains { ($0.alias ?? "").isEmpty },
                            onCancel: { isAddingAccount = false },
                            onConnect: { alias in
                                isAddingAccount = false
                                connect(alias: alias)
                            }
                        )
                    }
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
            if !accounts.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                        ComposioAccountRow(account: account)
                            .padding(.leading, TreeBranch.width)
                            .background(alignment: .leading) {
                                TreeBranch(isLast: index == accounts.count - 1)
                            }
                    }
                }
            }
        }
        .padding(.vertical, 8)
    }

    private func connect(alias: String?) {
        isConnecting = true
        Task {
            if let url = await store.connectURL(for: slug, alias: alias) {
                NSWorkspace.shared.open(url)
            }
            isConnecting = false
        }
    }
}

/// Shown when the API key can't read connected accounts: without that the
/// per-account list (and renaming / removing accounts) can't work.
private struct ComposioAccountPermissionNotice: View {
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "key.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("APIキーに「Connected Accounts」の権限がないため、連携中のアカウントを表示できません。")
                    .font(.callout)
                Text("Composioのダッシュボードでこのキーに Connected Accounts の読み取り・書き込み権限を追加するか、権限つきの新しいキーを作って貼り直してください。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Link("APIキーの設定を開く", destination: URL(string: "https://dashboard.composio.dev/~/project/settings/api-keys")!)
                    .font(.caption)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Asks for an alias before connecting another account, so Kon can tell
/// "仕事のメール" from "個人のメール".
private struct ComposioAddAccountForm: View {
    let hasUnnamedAccount: Bool
    let onCancel: () -> Void
    let onConnect: (String) -> Void
    @State private var alias = ""

    private var trimmed: String { alias.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("アカウントを追加").font(.headline)
            Text("コンに「仕事のメールを見て」のように呼び分けてもらうための名前です。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("別名（例: 仕事、個人）", text: $alias)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if !trimmed.isEmpty { onConnect(trimmed) } }
            if hasUnnamedAccount {
                Text("今あるアカウントにも鉛筆ボタンから別名をつけておくと呼び分けやすくなります。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("キャンセル", action: onCancel)
                Button("ブラウザで接続") { onConnect(trimmed) }
                    .buttonStyle(.borderedProminent)
                    .tint(SettingsPalette.accent)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 280)
    }
}

/// The "├─ / └─" lines hanging accounts off their service, like a directory
/// tree. The trunk sits under the center of the service logo.
private struct TreeBranch: View {
    let isLast: Bool

    static let width: CGFloat = 32
    private static let trunkX: CGFloat = 16

    var body: some View {
        Canvas { context, size in
            var path = Path()
            let midY = size.height / 2
            path.move(to: CGPoint(x: Self.trunkX, y: 0))
            path.addLine(to: CGPoint(x: Self.trunkX, y: isLast ? midY : size.height))
            path.move(to: CGPoint(x: Self.trunkX, y: midY))
            path.addLine(to: CGPoint(x: size.width - 4, y: midY))
            context.stroke(path, with: .color(.secondary.opacity(0.45)), lineWidth: 1)
        }
        .frame(width: Self.width)
    }
}

private struct ComposioAccountRow: View {
    let account: ComposioConnectedAccount
    private var store = KonComposioStore.shared
    @State private var draft = ""
    @State private var isEditing = false
    @State private var confirmsRemoval = false

    init(account: ComposioConnectedAccount) {
        self.account = account
    }

    private var hasAlias: Bool { !(account.alias ?? "").isEmpty }
    private var profile: ComposioAccountProfile? { store.profile(for: account) }

    /// The account's own name when known, else its address, else the handle.
    private var title: String {
        profile?.name ?? profile?.email ?? account.handle
    }

    var body: some View {
        HStack(spacing: 8) {
            AccountAvatar(url: profile?.pictureURL, name: profile?.name ?? profile?.email)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(title)
                        .lineLimit(1)
                    if !isEditing {
                        aliasTag
                    }
                    if !account.isActive {
                        Text("接続待ち").font(.caption).foregroundStyle(.orange)
                    }
                }
                if let email = profile?.email, email != title {
                    Text(email)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if isEditing {
                    HStack(spacing: 6) {
                        TextField("別名（例: 仕事）", text: $draft)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 140)
                            .onSubmit(save)
                        Button("保存", action: save)
                        Button("キャンセル") { isEditing = false }
                    }
                    .padding(.top, 2)
                }
            }
            Spacer()
            if !isEditing {
                Button {
                    draft = account.alias ?? ""
                    isEditing = true
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("別名を変更")
            }
            Button {
                confirmsRemoval = true
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("このアカウントの連携を解除")
            .confirmationDialog("「\(title)」の連携を解除しますか？", isPresented: $confirmsRemoval) {
                Button("解除", role: .destructive) {
                    Task { await store.removeAccount(account) }
                }
            } message: {
                Text("Composioからこのアカウントの接続が削除されます。")
            }
        }
        .font(.callout)
        .padding(.vertical, 5)
    }

    /// What Kon calls this account ("仕事のメール").
    @ViewBuilder
    private var aliasTag: some View {
        Text(hasAlias ? account.handle : "別名なし")
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .foregroundStyle(hasAlias ? SettingsPalette.accent : .secondary)
            .background(
                (hasAlias ? SettingsPalette.accent : Color.secondary).opacity(0.12),
                in: Capsule()
            )
            .help(hasAlias ? "コンに「\(account.handle)の〜」と頼むとこのアカウントを使います" : "鉛筆ボタンで別名をつけると呼び分けやすくなります（今は \(account.handle)）")
    }

    private func save() {
        isEditing = false
        Task { await store.renameAccount(account, to: draft) }
    }
}

/// Google profile photo, or the account's initial while it loads / if there's none.
private struct AccountAvatar: View {
    let url: URL?
    let name: String?

    private static let size: CGFloat = 26

    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                placeholder
            }
        }
        .frame(width: Self.size, height: Self.size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.primary.opacity(0.1)))
    }

    @ViewBuilder
    private var placeholder: some View {
        if let initial = name?.first {
            Text(String(initial).uppercased())
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.secondary.opacity(0.6))
        } else {
            Image(systemName: "person.crop.circle.fill")
                .resizable()
                .foregroundStyle(.tertiary)
        }
    }
}

private struct ComposioStatusLabel: View {
    let status: ComposioConnectionStatus?
    var activeAccounts = 0

    var body: some View {
        switch status {
        case .connected:
            Label(activeAccounts > 1 ? "接続済み（\(activeAccounts)アカウント）" : "接続済み", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).font(.caption)
        case .noAuthRequired:
            Label("接続不要", systemImage: "checkmark.circle").foregroundStyle(.green).font(.caption)
        case .pending:
            Label("接続を完了してください", systemImage: "clock").foregroundStyle(.orange).font(.caption)
        case .notConnected:
            Label("未接続", systemImage: "xmark.circle").foregroundStyle(.secondary).font(.caption)
        case .unknown:
            Label("確認できませんでした", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange).font(.caption)
                .help("下に表示されているエラーを確認して、更新ボタンで再確認してください")
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
