import AppKit
import SwiftUI

@MainActor
@Observable
final class ChatViewModel {
    private(set) var messages: [KonMessage] = []
    private(set) var isSending = false
    private(set) var listenerState: KonListenerState = .idle
    private(set) var isSpeaking = false
    var errorMessage: String?

    /// Called when a spoken command is recognized, so the menu bar host
    /// can surface the overlay even before a reply is ready.
    var onActivity: (() -> Void)?
    /// Called when a voice session starts; the mic may not be live yet.
    var onListeningStart: (() -> Void)?
    /// Called once the mic actually delivers audio, i.e. Kon can hear the user.
    var onMicLive: (() -> Void)?
    /// Called when the utterance ended and speech-to-text is running.
    var onTranscribingStart: (() -> Void)?
    /// Called when a voice session ends without a command (silence or cancel).
    var onListeningEndedWithoutCommand: ((KonListenEndReason) -> Void)?
    /// Called with every completed reply, so the menu bar host can show it in
    /// the floating speech-bubble overlay regardless of where the send came from.
    var onReply: ((KonReply) -> Void)?
    /// Called when the reply starts being read aloud, with the audio duration.
    var onSpeechStart: ((TimeInterval) -> Void)?
    /// Called when reading the reply aloud has finished.
    var onSpeechFinish: (() -> Void)?
    /// Called when Kon starts or stops doing anything the user may want to
    /// cut off (listening, thinking, speaking), e.g. to arm Escape-to-cancel.
    var onBusyChange: ((Bool) -> Void)?
    /// Called after the user cancelled what Kon was doing, so the overlay can close.
    var onCancel: (() -> Void)?
    /// Called when a request failed, with a message for the user (the usage
    /// limit, a crashed CLI, ...), so the overlay doesn't sit on "Thinking…".
    var onFailure: ((_ reply: KonReply, _ isSpoken: Bool) -> Void)?
    /// Called when a reminder is announced, with its text (before it's read aloud).
    var onAnnouncement: ((String) -> Void)?

    private let client = KonClient()
    private let speechClient = KonSpeechClient()
    private let listener = KonListener()
    private let settings = KonSettings.shared
    private let history = KonHistoryStore.shared
    private let contextProvider = KonContextProvider.shared
    /// Groups saved history entries into conversations.
    private var conversationId = UUID()
    /// Bumped per request, so a reply that was cut off is dropped when it lands.
    private var sendGeneration = 0
    private var wasBusy = false

    init() {
        // Boot the claude CLI now so the first question doesn't pay for it.
        Task { [client] in await client.prewarm() }
        listener.onStateChange = { [weak self] state in
            self?.listenerState = state
            self?.updateBusy()
            switch state {
            case .listening: self?.onMicLive?()
            case .thinking: self?.onTranscribingStart?()
            case .idle, .preparing: break
            }
        }
        listener.onCommand = { [weak self] text in
            self?.onActivity?()
            self?.send(text)
        }
        listener.onSessionEndedWithoutCommand = { [weak self] reason in
            self?.onListeningEndedWithoutCommand?(reason)
        }
        listener.onError = { [weak self] error in
            self?.errorMessage = error.localizedDescription
        }
    }

    var isListening: Bool { listener.isListening }

    var isBusy: Bool { listener.isListening || listenerState != .idle || isSending || isSpeaking }

    /// Starts a push-to-talk voice session, or cancels the one in progress.
    /// Pressed while Kon is thinking or speaking, it cuts Kon off and listens
    /// instead (barge-in).
    func toggleVoiceSession() {
        if listener.isListening {
            listener.cancelSession()
            return
        }
        if isSending {
            interruptReply()
        }
        // Don't let Kon's own voice leak into the mic.
        stopSpeaking()
        do {
            try listener.startSession(silenceTimeout: settings.sessionSilenceTimeout)
            // If the CLI was stopped for idleness, restart it while the user is
            // still talking so the reply doesn't pay for the launch.
            Task { [client] in await client.prewarm() }
            onListeningStart?()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Escape: stop whatever Kon is doing right now.
    func cancelCurrentActivity() {
        if listener.isListening {
            listener.cancelSession()
            return
        }
        if isSending {
            interruptReply()
        }
        stopSpeaking()
        onCancel?()
    }

    /// Reads a reminder out loud. Waits while Kon is mid-conversation rather
    /// than talking over the user or a reply.
    func announce(_ text: String) {
        Task {
            while isBusy {
                try? await Task.sleep(for: .seconds(1))
            }
            NSSound(named: "Glass")?.play()
            onAnnouncement?(text)
            if settings.speakReplies {
                speak(text)
            }
        }
    }

    private func interruptReply() {
        guard isSending else { return }
        sendGeneration += 1
        isSending = false
        updateBusy()
        Task { [client] in await client.interrupt() }
    }

    private func stopSpeaking() {
        speechClient.stop()
        isSpeaking = false
        updateBusy()
    }

    private func speak(_ text: String) {
        isSpeaking = true
        updateBusy()
        speechClient.speak(
            text,
            onStart: { [weak self] duration in self?.onSpeechStart?(duration) },
            onFinish: { [weak self] in
                self?.isSpeaking = false
                self?.updateBusy()
                self?.onSpeechFinish?()
            }
        )
    }

    private func updateBusy() {
        let busy = isBusy
        guard busy != wasBusy else { return }
        wasBusy = busy
        onBusyChange?(busy)
    }

    /// Clears the transcript and starts a fresh Claude session (drops conversation context).
    func startNewConversation() {
        guard !isSending else { return }
        messages.removeAll()
        errorMessage = nil
        conversationId = UUID()
        Task { await client.resetSession() }
        KonProfileStore.shared.learnIfNeeded(conversationEnded: true)
    }

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSending else { return }

        append(KonMessage(role: .user, text: trimmed))
        isSending = true
        updateBusy()
        errorMessage = nil
        sendGeneration += 1
        let generation = sendGeneration

        Task {
            do {
                let context = await contextProvider.snapshot()
                guard generation == sendGeneration else { return }
                let reply = try await client.send(trimmed, context: context)
                guard generation == sendGeneration else { return }
                append(KonMessage(role: .kon, text: reply.text, actions: reply.actions))
                onReply?(reply)
                KonProfileStore.shared.learnIfNeeded()
                if settings.speakReplies {
                    speak(reply.text)
                }
            } catch KonClientError.interrupted {
                // Cut off on purpose; nothing to report.
            } catch {
                if generation == sendGeneration {
                    report(error)
                }
            }
            if generation == sendGeneration {
                isSending = false
                updateBusy()
            }
        }
    }

    /// Tells the user why there's no answer — in the chat, the bubble and,
    /// for things they can act on (limit, overload), out loud.
    private func report(_ error: Error) {
        let message = error.localizedDescription
        errorMessage = message
        let label: String
        let speaks: Bool
        switch error as? KonClientError {
        case .usageLimit?:
            label = "利用上限"
            speaks = true
        case .overloaded?:
            label = "混雑中"
            speaks = true
        default:
            label = "エラー"
            speaks = false
        }
        let isSpoken = speaks && settings.speakReplies
        onFailure?(KonReply(text: message, actions: [label]), isSpoken)
        if isSpoken {
            speak(message)
        }
    }

    private func append(_ message: KonMessage) {
        messages.append(message)
        history.append(message, conversationId: conversationId)
    }
}

struct ChatView: View {
    var viewModel: ChatViewModel
    @State private var inputText = ""

    var body: some View {
        VStack(spacing: 0) {
            statusHeader
            Divider()
            transcript
            Divider()
            inputBar
        }
        .frame(width: 380, height: 520)
        .background(.regularMaterial)
    }

    private var statusHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "circle.fill")
                .font(.system(size: 8))
                .foregroundStyle(statusColor)
            Text(statusText)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                viewModel.toggleVoiceSession()
            } label: {
                Image(systemName: viewModel.isListening ? "mic.fill" : "mic")
            }
            .buttonStyle(.plain)
            .help(viewModel.isListening ? "聞き取りをやめる" : "声で話しかける（\(pushToTalkKeys)）")
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.plain)
            .help("Konsoleを終了")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var pushToTalkKeys: String {
        KonSettings.shared.pushToTalkShortcut.displayString
    }

    private var statusColor: Color {
        switch viewModel.listenerState {
        case .idle: return .gray
        case .preparing: return .yellow
        case .listening: return .green
        case .thinking: return .orange
        }
    }

    private var statusText: String {
        switch viewModel.listenerState {
        case .idle: return "\(pushToTalkKeys)で声で話しかけられます"
        case .preparing: return "マイク準備中…"
        case .listening: return "聞いています…"
        case .thinking: return "文字起こし中…"
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(viewModel.messages) { message in
                        MessageRow(message: message)
                            .id(message.id)
                    }
                    if viewModel.isSending {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("考え中…")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let errorMessage = viewModel.errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }
                .padding()
            }
            .onChange(of: viewModel.messages.count) {
                guard let lastId = viewModel.messages.last?.id else { return }
                withAnimation {
                    proxy.scrollTo(lastId, anchor: .bottom)
                }
            }
        }
    }

    private var inputBar: some View {
        HStack {
            TextField("コンに話しかける", text: $inputText)
                .textFieldStyle(.roundedBorder)
                .onSubmit(sendCurrentInput)
                .disabled(viewModel.isSending)

            Button("送信", action: sendCurrentInput)
                .disabled(viewModel.isSending || inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(12)
    }

    private func sendCurrentInput() {
        let text = inputText
        inputText = ""
        viewModel.send(text)
    }
}

private struct MessageRow: View {
    let message: KonMessage

    var body: some View {
        HStack {
            if message.role == .kon {
                bubble
                Spacer(minLength: 32)
            } else {
                Spacer(minLength: 32)
                bubble
            }
        }
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !message.actions.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(message.actions.enumerated()), id: \.offset) { _, action in
                        Label(action, systemImage: "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, 2)
            }
            Text(message.text)
        }
        .padding(10)
        .background(message.role == .user ? Color.accentColor.opacity(0.2) : Color.gray.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

#Preview {
    ChatView(viewModel: ChatViewModel())
}
