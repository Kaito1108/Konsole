import SwiftUI

/// The one-line box shown where the bubble usually is: type, Enter to send.
/// The panel is made key while this is up, so the field gets the keyboard.
struct KonTextInputView: View {
    @Bindable var viewModel: KonOverlayViewModel
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "keyboard")
                .foregroundStyle(.secondary)
            TextField("コンに聞く…", text: $viewModel.draft)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .medium))
                .focused($isFocused)
                .onSubmit(viewModel.submitText)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(width: 340)
        .background(.thinMaterial, in: Capsule())
        .onAppear {
            // The panel only becomes key as it's ordered front; wait a beat
            // so the focus request isn't dropped.
            DispatchQueue.main.async { isFocused = true }
        }
    }
}

/// The reply's code (a command, a path...) in monospace, ready to select.
struct KonCodeBlockView: View {
    let code: String

    var body: some View {
        Text(code)
            .font(.system(size: 12, design: .monospaced))
            .lineLimit(4)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Puts the reply on the clipboard; Kon never pastes it anywhere itself.
struct KonCopyButton: View {
    let didCopy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(didCopy ? "コピーした" : "コピー", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                .font(.caption)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}
