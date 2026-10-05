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
    /// Called repeatedly with the reply as it's still being written, so the
    /// bubble can show it while Kon is talking.
    var onStreamingReply: ((String) -> Void)?
    /// Called when a tool needs the user's approval. Answer via the closure
    /// (true = allow once); Kon waits until it's called.
    var onPermissionRequest: ((KonPermissionRequest, @escaping (Bool) -> Void) -> Void)?

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
    /// Keep the mic open after Kon answers (連続会話), until silence or Escape.
    private var isContinuing = false
    /// How many times in a row the mic was reopened because a turn was heard
    /// but not understood. Reset as soon as a command comes through.
    private var continuousRetries = 0
    private static let maxContinuousRetries = 2
    /// The assistant message being streamed, and how much of it has been
    /// handed to the speech queue.
    private var streamSegmentText = ""
    private var streamedText = ""
    private var spokenStreamCount = 0
    private var isStreamingSpeech = false
    /// Waiting on 許可 / 拒否 for a tool call.
    private var pendingPermission: CheckedContinuation<Bool, Never>?
    private var permissionTimeoutTask: Task<Void, Never>?
    /// An unanswered question is denied rather than left hanging.
    private static let permissionTimeout: Duration = .seconds(90)

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
            self?.continuousRetries = 0
            self?.onActivity?()
            self?.send(text)
        }
        listener.onSessionEndedWithoutCommand = { [weak self] reason in
            guard let self else { return }
            let wasContinuing = isContinuing
            isContinuing = false
            if wasContinuing {
                // A blip or an empty transcript isn't the user going quiet:
                // they did say something and it didn't survive the VAD or
                // whisper. Reopening the mic beats ending the conversation
                // on someone who is still talking.
                if reason == .tooShort || reason == .notUnderstood,
                   continuousRetries < Self.maxContinuousRetries {
                    continuousRetries += 1
                    isContinuing = true
                    resumeContinuousListeningIfNeeded()
                    return
                }
                // Real silence: the user is done talking; closing the bubble
                // quietly beats "何も聞こえなかったよ".
                if reason == .noSpeech || reason == .tooShort {
                    onCancel?()
                    return
                }
            }
            onListeningEndedWithoutCommand?(reason)
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
            isContinuing = false
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
            isContinuing = settings.continuesConversation
            continuousRetries = 0
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
        isContinuing = false
        if listener.isListening {
            listener.cancelSession()
            return
        }
        // A pending question would otherwise leave the CLI waiting forever.
        answerPendingPermission(false)
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
        answerPendingPermission(false)
        sendGeneration += 1
        isSending = false
        updateBusy()
        Task { [client] in await client.interrupt() }
    }

    private func stopSpeaking() {
        speechClient.stop()
        isStreamingSpeech = false
        isSpeaking = false
        updateBusy()
    }

    private func speak(_ text: String) {
        isSpeaking = true
        updateBusy()
        speechClient.speak(
            text,
            onStart: { [weak self] duration in self?.onSpeechStart?(duration) },
            onFinish: { [weak self] in self?.finishSpeaking() }
        )
    }

    private func finishSpeaking() {
        isStreamingSpeech = false
        isSpeaking = false
        updateBusy()
        onSpeechFinish?()
        resumeContinuousListeningIfNeeded()
    }

    // MARK: - 連続会話

    /// Reopens the mic once Kon has finished talking, so a back-and-forth
    /// doesn't need the hotkey every turn.
    private func resumeContinuousListeningIfNeeded() {
        guard isContinuing, settings.continuesConversation else { return }
        guard !isSending, !isSpeaking, !listener.isListening else { return }
        Task {
            // A beat, so the tail of Kon's own voice doesn't reopen the mic onto itself.
            try? await Task.sleep(for: .milliseconds(350))
            guard isContinuing, !isSending, !isSpeaking, !listener.isListening else { return }
            do {
                try listener.startSession(silenceTimeout: settings.continuousSilenceTimeout)
                onListeningStart?()
            } catch {
                isContinuing = false
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - 許可の確認

    private func requestPermission(_ request: KonPermissionRequest) async -> Bool {
        guard let onPermissionRequest else { return false }
        answerPendingPermission(false)
        let generation = sendGeneration
        let allowed = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            pendingPermission = continuation
            onPermissionRequest(request) { [weak self] allowed in
                self?.answerPendingPermission(allowed)
            }
            permissionTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: Self.permissionTimeout)
                self?.answerPendingPermission(false)
            }
        }
        permissionTimeoutTask?.cancel()
        return generation == sendGeneration ? allowed : false
    }

    private func answerPendingPermission(_ allowed: Bool) {
        guard let continuation = pendingPermission else { return }
        pendingPermission = nil
        permissionTimeoutTask?.cancel()
        continuation.resume(returning: allowed)
    }

    // MARK: - ストリーミング

    private func beginStreaming() {
        streamSegmentText = ""
        streamedText = ""
        spokenStreamCount = 0
        isStreamingSpeech = false
    }

    /// One update of the reply in progress: shows it and queues up whatever
    /// full sentences it now contains for reading aloud.
    private func receiveStream(_ text: String, isNewSegment: Bool, generation: Int) {
        guard generation == sendGeneration else { return }
        if isNewSegment {
            // Kon said something before using a tool; that part is complete.
            flushSpeechStream(all: true)
            streamedText += streamSegmentText
            spokenStreamCount = 0
        }
        streamSegmentText = text
        onStreamingReply?(text)
        guard settings.speakReplies else { return }
        if !isStreamingSpeech {
            isStreamingSpeech = true
            isSpeaking = true
            updateBusy()
            speechClient.startStream(
                onStart: { [weak self] duration in self?.onSpeechStart?(duration) },
                onFinish: { [weak self] in self?.finishSpeaking() }
            )
        }
        flushSpeechStream(all: false)
    }

    /// Hands finished sentences to the speech queue, keeping the tail that is
    /// still being written (`all` takes the tail too).
    private func flushSpeechStream(all: Bool) {
        guard isStreamingSpeech else { return }
        let pending = String(streamSegmentText.dropFirst(spokenStreamCount))
        guard !pending.isEmpty else { return }
        let chunk: String
        if all {
            chunk = pending
        } else if let boundary = Self.sentenceBoundary(in: pending) {
            chunk = String(pending[pending.startIndex..<boundary])
        } else {
            return
        }
        spokenStreamCount += chunk.count
        speechClient.appendStream(chunk)
    }

    private static let sentenceEnds: Set<Character> = ["。", "！", "？", "!", "?", "\n"]
    private static let clauseEnds: Set<Character> = ["、", ",", "。"]
    /// A clause this long is broken at a comma so reading starts sooner.
    private static let clauseBreakLength = 48

    /// Index just past the last complete sentence, or nil while one is still
    /// being written.
    private static func sentenceBoundary(in text: String) -> String.Index? {
        if let index = text.lastIndex(where: { sentenceEnds.contains($0) }) {
            return text.index(after: index)
        }
        guard text.count >= clauseBreakLength,
              let index = text.lastIndex(where: { clauseEnds.contains($0) }) else { return nil }
        return text.index(after: index)
    }

    /// Reads out whatever is left of a streamed reply, plus the final text if
    /// it isn't what was streamed, and closes the queue.
    private func endStreamedSpeech(finalText: String) {
        flushSpeechStream(all: true)
        let spoken = streamedText + streamSegmentText
        let text = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty, !spoken.contains(text) {
            speechClient.appendStream(text)
        }
        speechClient.endStream()
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
                // The screenshot is only for this request.
                defer { KonScreenCapture.discard(context.screenshot) }
                guard generation == sendGeneration else { return }
                let streams = settings.streamsReplies
                if streams { beginStreaming() }
                var onStream: KonStreamHandler?
                if streams {
                    onStream = { [weak self] text, isNewSegment in
                        self?.receiveStream(text, isNewSegment: isNewSegment, generation: generation)
                    }
                }
                let onPermission: KonPermissionHandler = { [weak self] request in
                    guard let self else { return false }
                    return await requestPermission(request)
                }
                let reply = try await client.send(
                    trimmed,
                    context: context.text,
                    onStream: onStream,
                    onPermission: onPermission
                )
                guard generation == sendGeneration else { return }
                append(KonMessage(role: .kon, text: reply.text, actions: reply.actions))
                onReply?(reply)
                KonProfileStore.shared.learnIfNeeded()
                if settings.speakReplies {
                    if isStreamingSpeech {
                        endStreamedSpeech(finalText: reply.text)
                    } else {
                        speak(reply.text)
                    }
                } else {
                    // Nothing to wait for before listening again.
                    resumeContinuousListeningIfNeeded()
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
        isContinuing = false
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
