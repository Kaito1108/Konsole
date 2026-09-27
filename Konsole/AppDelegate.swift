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
            self?.overlayViewModel.showListening()
            self?.showOverlay()
            if self?.settings.playsListeningSound == true {
                NSSound(named: "Tink")?.play()
            }
        }
        // Escape cancels a voice session, but is only grabbed while listening
        // so it keeps working normally in every other app.
        chatViewModel.onListenerStateChange = { [weak self] state in
            guard let self else { return }
            if state == .listening {
                hotKeyManager.register(.cancel) { [weak self] in
                    self?.chatViewModel.cancelVoiceSession()
                }
            } else {
                hotKeyManager.unregister(.cancel)
            }
        }
        chatViewModel.onListeningEndedWithoutCommand = { [weak self] in
            guard self?.overlayViewModel.phase == .listening else { return }
            self?.overlayViewModel.hide()
            self?.overlayPanel.orderOut(nil)
        }
        chatViewModel.onActivity = { [weak self] in
            self?.overlayHideTask?.cancel()
            self?.overlayViewModel.showThinking()
            self?.showOverlay()
        }
        chatViewModel.onReply = { [weak self] reply in
            guard let self else { return }
            overlayHideTask?.cancel()
            overlayViewModel.showReply(text: reply.text, actions: reply.actions)
            showOverlay()
            if !settings.speakReplies {
                // Nothing to sync to: scroll at a comfortable reading pace instead.
                let readingTime = Double(reply.text.count) / Self.readingCharactersPerSecond
                overlayViewModel.startReading(duration: readingTime)
                scheduleOverlayAutoHide(after: readingTime + settings.replyDisplaySeconds)
            }
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
        menu.addItem(.separator())
        // Target NSApp explicitly: AppDelegate doesn't implement terminate(_:),
        // so targeting self left this item permanently disabled.
        menu.addItem(withTitle: "Konsoleを終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q").target = NSApp
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
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
