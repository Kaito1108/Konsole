import SwiftUI

@MainActor
@Observable
final class ChatViewModel {
    private(set) var messages: [KonMessage] = []
    private(set) var isSending = false
    private(set) var listenerState: KonListenerState = .idle
    var errorMessage: String?

    /// Called when a spoken command is recognized, so the menu bar host
    /// can surface the overlay even before a reply is ready.
    var onActivity: (() -> Void)?
    /// Called when a voice session starts and Kon is waiting for the command.
    var onListeningStart: (() -> Void)?
    /// Called when a voice session ends without a command (silence or cancel).
    var onListeningEndedWithoutCommand: (() -> Void)?
    /// Called whenever the voice session state changes (e.g. to arm Escape-to-cancel).
    var onListenerStateChange: ((KonListenerState) -> Void)?
    /// Called with every completed reply, so the menu bar host can show it in
    /// the floating speech-bubble overlay regardless of where the send came from.
    var onReply: ((KonReply) -> Void)?
    /// Called when the reply starts being read aloud, with the audio duration.
    var onSpeechStart: ((TimeInterval) -> Void)?
    /// Called when reading the reply aloud has finished.
    var onSpeechFinish: (() -> Void)?

    private let client = KonClient()
    private let speechClient = KonSpeechClient()
    private let listener = KonListener()
    private let settings = KonSettings.shared
    private let history = KonHistoryStore.shared
    /// Groups saved history entries into conversations.
    private var conversationId = UUID()

    init() {
        // Boot the claude CLI now so the first question doesn't pay for it.
        Task { [client] in await client.prewarm() }
        listener.onStateChange = { [weak self] state in
            self?.listenerState = state
            self?.onListenerStateChange?(state)
        }
        listener.onCommand = { [weak self] text in
            self?.onActivity?()
            self?.send(text)
        }
        listener.onSessionEndedWithoutCommand = { [weak self] in
            self?.onListeningEndedWithoutCommand?()
        }
        listener.onError = { [weak self] error in
            self?.errorMessage = error.localizedDescription
        }
    }

    var isListening: Bool { listener.isListening }

    /// Starts a push-to-talk voice session, or cancels the one in progress.
    func toggleVoiceSession() {
        if listener.isListening {
            listener.cancelSession()
            return
        }
        guard !isSending else { return }
        // Don't let Kon's own voice leak into the mic.
        speechClient.stop()
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

    func cancelVoiceSession() {
        listener.cancelSession()
    }

    /// Clears the transcript and starts a fresh Claude session (drops conversation context).
    func startNewConversation() {
        guard !isSending else { return }
        messages.removeAll()
        errorMessage = nil
        conversationId = UUID()
        Task { await client.resetSession() }
    }

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSending else { return }

        append(KonMessage(role: .user, text: trimmed))
        isSending = true
        errorMessage = nil

        Task {
            do {
                let reply = try await client.send(trimmed)
                append(KonMessage(role: .kon, text: reply.text, actions: reply.actions))
                onReply?(reply)
                if settings.speakReplies {
                    speechClient.speak(
                        reply.text,
                        onStart: { [weak self] duration in self?.onSpeechStart?(duration) },
                        onFinish: { [weak self] in self?.onSpeechFinish?() }
                    )
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isSending = false
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
        case .listening: return .green
        case .thinking: return .orange
        }
    }

    private var statusText: String {
        switch viewModel.listenerState {
        case .idle: return "\(pushToTalkKeys)で声で話しかけられます"
        case .listening: return "聞いています…"
        case .thinking: return "聞き取っています…"
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
