import Foundation

/// A reply split into what Kon says and the code it hands over. Kon puts a
/// command, path or code in a fenced block (see KonClient's system prompt);
/// that part is shown in monospace and copied, never read aloud.
struct KonReplyText: Equatable {
    /// The reply without its fenced blocks. A block still being streamed (no
    /// closing fence yet) is left out too, so the spoken prefix never changes.
    let prose: String
    /// Contents of each fenced block, in order.
    let codeBlocks: [String]

    init(_ text: String) {
        var proseLines: [String] = []
        var blocks: [String] = []
        var blockLines: [String]?
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // ```git status``` on a single line.
            if blockLines == nil, trimmed.count > 6, trimmed.hasPrefix("```"), trimmed.hasSuffix("```") {
                let inner = trimmed.dropFirst(3).dropLast(3).trimmingCharacters(in: .whitespaces)
                if !inner.isEmpty { blocks.append(inner) }
                continue
            }
            if trimmed.hasPrefix("```") {
                if let lines = blockLines {
                    let code = lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
                    if !code.isEmpty { blocks.append(code) }
                    blockLines = nil
                } else {
                    blockLines = []
                }
                continue
            }
            if blockLines != nil {
                blockLines?.append(line)
            } else {
                proseLines.append(line)
            }
        }
        prose = proseLines.joined(separator: "\n")
        codeBlocks = blocks
    }

    /// What to put on the clipboard without being asked: only when the reply
    /// hands over exactly one thing, so there's no guessing which one is meant.
    var copyableSnippet: String? {
        codeBlocks.count == 1 ? codeBlocks.first : nil
    }

    /// The whole reply as plain text, for the コピー button.
    var plainText: String {
        ([prose.trimmingCharacters(in: .whitespacesAndNewlines)] + codeBlocks)
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}
