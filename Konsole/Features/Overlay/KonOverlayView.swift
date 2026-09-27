import SwiftUI

struct KonOverlayView: View {
    var viewModel: KonOverlayViewModel

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Spacer(minLength: 0)
            bubble
            face
        }
        .padding(12)
        .opacity(viewModel.phase == .hidden ? 0 : 1)
        .animation(.easeInOut(duration: 0.2), value: viewModel.phase)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }

    @ViewBuilder
    private var bubble: some View {
        switch viewModel.phase {
        case .hidden:
            EmptyView()
        case .preparing:
            HStack(spacing: 8) {
                Image(systemName: "mic")
                    .foregroundStyle(.secondary)
                Text("マイク準備中…")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(.thinMaterial, in: Capsule())
        case .listening:
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .symbolEffect(.variableColor.iterative, options: .repeating)
                    .foregroundStyle(.orange)
                Text("聞いています…")
                    .font(.system(size: 15, weight: .semibold))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(.thinMaterial, in: Capsule())
        case .transcribing:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("文字起こし中…")
                    .font(.system(size: 15, weight: .semibold))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(.thinMaterial, in: Capsule())
        case .thinking:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Thinking…")
                    .font(.system(size: 15, weight: .semibold))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(.thinMaterial, in: Capsule())
        case .reply(let text, let actions):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                    Label(action, systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                LyricsText(
                    text: text,
                    readingStartedAt: viewModel.readingStartedAt,
                    readingDuration: viewModel.readingDuration
                )
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .frame(maxWidth: 380, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
        }
    }

    private var face: some View {
        Image("KonFace")
            .resizable()
            .scaledToFit()
            .frame(width: 56, height: 56)
            .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
    }
}

/// Lyrics-style reply: lines appear as they're spoken (plus a dimmed preview
/// of the next one), so the bubble starts small and grows downward. Once it
/// reaches `maxHeight` it stops growing and the text scrolls up instead.
private struct LyricsText: View {
    let text: String
    let readingStartedAt: Date?
    let readingDuration: TimeInterval

    private static let font = Font.system(size: 15, weight: .medium)
    private static let maxHeight: CGFloat = 116
    /// Longer replies get the full bubble width up front so it doesn't jitter
    /// sideways as lines are revealed.
    private static let fullWidthThreshold = 24
    private static let fullWidth: CGFloat = 344

    @State private var contentHeight: CGFloat = 0

    private var lines: [String] { Self.split(text) }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { context in
            let current = currentLine(at: context.date)
            let visibleCount = min(current + 2, lines.count)
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(0..<visibleCount, id: \.self) { index in
                            Text(lines[index])
                                .font(Self.font)
                                .fixedSize(horizontal: false, vertical: true)
                                .foregroundStyle(index == current ? .primary : .secondary)
                                .opacity(index < current ? 0.45 : (index > current ? 0.6 : 1))
                                .id(index)
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                }
                .scrollDisabled(true)
                .defaultScrollAnchor(.bottom)
                .frame(height: min(contentHeight, Self.maxHeight))
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: contentHeight > Self.maxHeight ? .clear : .black, location: 0),
                            .init(color: .black, location: 0.15),
                            .init(color: .black, location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .animation(.easeInOut(duration: 0.35), value: visibleCount)
                .onChange(of: visibleCount) {
                    withAnimation(.easeInOut(duration: 0.35)) {
                        proxy.scrollTo(visibleCount - 1, anchor: .bottom)
                    }
                }
            }
        }
        .frame(width: text.count > Self.fullWidthThreshold ? Self.fullWidth : nil, alignment: .leading)
    }

    /// Maps elapsed speech time to a line, weighting each line by its length.
    private func currentLine(at date: Date) -> Int {
        guard let readingStartedAt, readingDuration > 0 else { return 0 }
        let progress = min(max(date.timeIntervalSince(readingStartedAt) / readingDuration, 0), 1)
        let target = progress * Double(text.count)
        var consumed = 0.0
        for (index, line) in lines.enumerated() {
            consumed += Double(line.count)
            if target < consumed { return index }
        }
        return max(lines.count - 1, 0)
    }

    /// Splits into sentences (keeping the punctuation); overly long sentences
    /// are split again at commas so each "lyric line" stays readable.
    static func split(_ text: String) -> [String] {
        func chunks(_ text: String, breakingAfter breaks: Set<Character>) -> [String] {
            var result: [String] = []
            var current = ""
            for character in text {
                if character == "\n" {
                    if !current.isEmpty { result.append(current) }
                    current = ""
                    continue
                }
                current.append(character)
                if breaks.contains(character) {
                    result.append(current)
                    current = ""
                }
            }
            if !current.isEmpty { result.append(current) }
            return result
        }

        return chunks(text, breakingAfter: ["。", "！", "？", "!", "?"])
            .flatMap { $0.count > 40 ? chunks($0, breakingAfter: ["、", ","]) : [$0] }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

#Preview {
    KonOverlayView(viewModel: {
        let vm = KonOverlayViewModel()
        vm.showReply(text: "今日の天気を調べました。晴れ、最高気温28度です。", actions: ["WebSearch: 今日の天気"])
        return vm
    }())
    .padding()
    .background(Color.gray.opacity(0.3))
}
