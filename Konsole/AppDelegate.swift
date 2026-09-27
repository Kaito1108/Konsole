import AppKit
import SwiftUI

/// Owns the menu bar status item, chat popover and floating overlay directly
/// via AppKit, and wires the ⌥Space push-to-talk hotkey to voice sessions.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var overlayPanel: NSPanel!
    private let hotKeyManager = KonHotKeyManager.shared
    let chatViewModel = ChatViewModel()
    private let overlayViewModel = KonOverlayViewModel()
    private var overlayHideTask: Task<Void, Never>?
    private var settingsWindow: NSWindow?
    private let settings = KonSettings.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        // LSUIElement apps have no window, so macOS's automatic termination
        // treats them as idle background cruft and silently kills them a
        // few seconds after launch unless they explicitly opt out.
        ProcessInfo.processInfo.disableAutomaticTermination("Konsole runs as a persistent menu bar agent")

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(named: "MenuBarIcon")
            image?.size = NSSize(width: 18, height: 18)
            image?.isTemplate = true
            button.image = image
            button.action = #selector(statusItemClicked(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 380, height: 520)
        popover.contentViewController = NSHostingController(rootView: ChatView(viewModel: chatViewModel))
        self.popover = popover

        setUpOverlayPanel()

        chatViewModel.onListeningStart = { [weak self] in
            self?.overlayHideTask?.cancel()
            self?.overlayViewModel.showPreparing()
            self?.showOverlay()
        }
        // Only claim to be listening once the mic actually delivers audio.
        chatViewModel.onMicLive = { [weak self] in
            guard let self, overlayViewModel.phase == .preparing else { return }
            overlayViewModel.showListening()
            if settings.playsListeningSound {
                NSSound(named: "Tink")?.play()
            }
        }
        // Escape stops whatever Kon is doing (listening, thinking, speaking),
        // but is only grabbed meanwhile so it keeps working in every other app.
        chatViewModel.onBusyChange = { [weak self] isBusy in
            guard let self else { return }
            if isBusy {
                hotKeyManager.register(.cancel) { [weak self] in
                    self?.chatViewModel.cancelCurrentActivity()
                }
            } else {
                hotKeyManager.unregister(.cancel)
            }
        }
        chatViewModel.onCancel = { [weak self] in
            self?.hideOverlay()
        }
        chatViewModel.onTranscribingStart = { [weak self] in
            guard self?.overlayViewModel.phase == .listening else { return }
            self?.overlayViewModel.showTranscribing()
        }
        chatViewModel.onListeningEndedWithoutCommand = { [weak self] reason in
            guard let self else { return }
            let phase = overlayViewModel.phase
            guard phase == .preparing || phase == .listening || phase == .transcribing else { return }
            // Say why nothing happened, rather than just vanishing.
            if let message = Self.message(for: reason) {
                showReplyOverlay(KonReply(text: message, actions: []), isSpoken: false)
            } else {
                hideOverlay()
            }
        }
        chatViewModel.onActivity = { [weak self] in
            self?.overlayHideTask?.cancel()
            self?.overlayViewModel.showThinking()
            self?.showOverlay()
        }
        chatViewModel.onReply = { [weak self] reply in
            self?.showReplyOverlay(reply)
        }
        chatViewModel.onFailure = { [weak self] reply, isSpoken in
            self?.showReplyOverlay(reply, isSpoken: isSpoken)
        }
        chatViewModel.onAnnouncement = { [weak self] text in
            self?.showReplyOverlay(KonReply(text: text, actions: ["リマインダー"]))
        }
        chatViewModel.onSpeechStart = { [weak self] duration in
            self?.overlayViewModel.startReading(duration: duration)
        }
        chatViewModel.onSpeechFinish = { [weak self] in
            guard let self else { return }
            scheduleOverlayAutoHide(after: settings.replyDisplaySeconds)
        }

        // Push-to-talk (⌥Space by default): the mic is only on during a voice session.
        hotKeyManager.register(.pushToTalk) { [weak self] in
            self?.chatViewModel.toggleVoiceSession()
        }

        let reminders = KonReminderStore.shared
        reminders.onFire = { [weak self] reminder in
            self?.chatViewModel.announce(reminder.text)
        }
        reminders.start()
    }

    // whisper.cpp's Metal backend asserts in its C++ static destructors when
    // the process exits with a model loaded (GGML_ASSERT rsets count == 0),
    // turning every quit — the menu, `osascript ... to quit` from the update
    // script — into a crash report. Nothing left needs exit-time cleanup
    // (the claude subprocess sees stdin close and exits), so skip them.
    func applicationWillTerminate(_ notification: Notification) {
        UserDefaults.standard.synchronize()
        fflush(stdout)
        fflush(stderr)
        _exit(0)
    }

    // Kon schedules reminders by running `open -g "konsole://remind?..."`.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            KonReminderStore.shared.handle(url)
        }
    }

    // MARK: - Status item popover (manual/typed chat)

    @objc private func statusItemClicked(_ sender: NSStatusItem) {
        guard let event = NSApp.currentEvent, event.type == .rightMouseUp else {
            togglePopover()
            return
        }
        showContextMenu()
    }

    private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button, !popover.isShown else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "設定…", action: #selector(openSettings), keyEquivalent: ",").target = self
        let updateItem = menu.addItem(withTitle: KonUpdater.shared.state == .building ? "更新中…" : "最新のソースで更新", action: #selector(updateFromSource), keyEquivalent: "")
        updateItem.target = self
        updateItem.isEnabled = KonUpdater.shared.state != .building
        menu.addItem(.separator())
        // Target NSApp explicitly: AppDelegate doesn't implement terminate(_:),
        // so targeting self left this item permanently disabled.
        menu.addItem(withTitle: "Konsoleを終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q").target = NSApp
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func updateFromSource() {
        KonUpdater.shared.update()
        // Failures are shown in 設定 > 一般; open it so they aren't missed.
        openSettings()
    }

    // An AppKit-owned window: SwiftUI's Settings scene can't be opened
    // reliably from an LSUIElement app without a main menu.
    @objc private func openSettings() {
        if settingsWindow == nil {
            let hostingController = NSHostingController(rootView: SettingsView(chatViewModel: chatViewModel))
            let window = NSWindow(contentViewController: hostingController)
            window.title = "Konsole 設定"
            window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 780, height: 540))
            window.center()
            // Open on the Space the user is on instead of jumping back to
            // wherever the window was first shown.
            window.collectionBehavior.insert(.moveToActiveSpace)
            settingsWindow = window
        }
        // Run after the status menu has finished closing: activating while it
        // is still tracking gets ignored, leaving the window behind other apps.
        DispatchQueue.main.async { [weak self] in
            guard let window = self?.settingsWindow else { return }
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            // macOS 14+ may decline activation for an LSUIElement app; this
            // still puts the window on top so it is never hidden.
            window.orderFrontRegardless()
        }
    }

    // MARK: - Floating top-right overlay (voice session HUD)

    private func setUpOverlayPanel() {
        let hostingController = NSHostingController(rootView: KonOverlayView(viewModel: overlayViewModel))
        let panel = NSPanel(contentViewController: hostingController)
        panel.styleMask = [.nonactivatingPanel, .borderless]
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.setContentSize(NSSize(width: 520, height: 220))
        overlayPanel = panel
        positionOverlayPanel()
    }

    private func positionOverlayPanel() {
        guard let screen = settings.overlayDisplay.screen else { return }
        let size = overlayPanel.frame.size
        // Inset from the top-right corner so the bubble doesn't hug the
        // menu bar or collide with notification banners.
        let rightInset: CGFloat = 16
        let topInset: CGFloat = 4
        let origin = NSPoint(
            x: screen.visibleFrame.maxX - size.width - rightInset,
            y: screen.visibleFrame.maxY - size.height - topInset
        )
        overlayPanel.setFrameOrigin(origin)
    }

    private func showOverlay() {
        // Re-resolve per session: displays come and go, and "mouse" follows
        // the pointer. Not while visible, so the bubble doesn't jump mid-reply.
        if !overlayPanel.isVisible {
            positionOverlayPanel()
        }
        overlayPanel.orderFrontRegardless()
    }

    private static let readingCharactersPerSecond = 8.0

    /// `isSpoken`: whether the text is about to be read aloud, which then
    /// drives scrolling and hiding; otherwise it scrolls at reading pace.
    private func showReplyOverlay(_ reply: KonReply, isSpoken: Bool? = nil) {
        overlayHideTask?.cancel()
        overlayViewModel.showReply(text: reply.text, actions: reply.actions)
        showOverlay()
        if !(isSpoken ?? settings.speakReplies) {
            // Nothing to sync to: scroll at a comfortable reading pace instead.
            let readingTime = Double(reply.text.count) / Self.readingCharactersPerSecond
            overlayViewModel.startReading(duration: readingTime)
            scheduleOverlayAutoHide(after: readingTime + settings.replyDisplaySeconds)
        }
    }

    private static func message(for reason: KonListenEndReason) -> String? {
        switch reason {
        case .cancelled: return nil
        case .noSpeech: return "何も聞こえなかったよ。もう一度話しかけてね。"
        case .micUnavailable: return "マイクの音が届かなかったよ。入力デバイスを確認してね。"
        case .tooShort: return "短すぎて聞き取れなかったよ。"
        case .notUnderstood: return "うまく聞き取れなかったよ。もう一度話してね。"
        case .failed: return "文字起こしに失敗したよ。"
        }
    }

    private func hideOverlay() {
        overlayHideTask?.cancel()
        overlayViewModel.hide()
        overlayPanel.orderOut(nil)
    }

    private func scheduleOverlayAutoHide(after seconds: TimeInterval) {
        overlayHideTask?.cancel()
        overlayHideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.overlayViewModel.hide()
            self?.overlayPanel.orderOut(nil)
        }
    }
}
