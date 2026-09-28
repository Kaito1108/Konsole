import Foundation

/// あぶない操作だけを「確認する」に落とすためのルール集。
///
/// `--permission-mode auto` は文字どおり全部を自動承認するので、`rm` でも
/// `git push` でも何も聞かれない（実測済み）。CLAUDE.md の方針
/// 「日常操作は自動承認、破壊的操作は確認」を満たすには、auto のまま
/// ここに並べたパターンだけを ask に上書きしてやる必要がある。
/// ask になったツール呼び出しだけが `can_use_tool` としてホストに届き、
/// 吹き出しの「許可 / 拒否」ボタンになる。
nonisolated enum KonPermissionRules {
    /// 取り消せない、または外に出ていくコマンド。
    private static let dangerousCommands = [
        // 消す・潰す
        "rm", "rmdir", "dd", "mkfs", "diskutil", "shred", "truncate",
        // 止める・権限をいじる
        "sudo", "su", "kill", "killall", "pkill", "shutdown", "reboot",
        "chmod", "chown", "launchctl", "crontab", "osascript", "defaults",
        // 外に出る・外から持ち込む
        "curl", "wget", "nc", "ssh", "scp", "sftp", "rsync",
        // 戻せない git 操作
        "git push", "git reset", "git clean", "git rebase", "git filter-branch",
        // 公開・アンインストール
        "gh release", "gh pr merge", "npm publish", "npm unpublish",
        "pip uninstall", "brew uninstall", "brew remove",
    ]

    /// さわられたくないファイル（鍵・認証情報・シェル設定）。
    private static let sensitivePaths = [
        ".ssh", ".aws", ".gnupg", ".config/gh", "Library/Keychains",
    ]

    private static let sensitiveFiles = [
        ".zshrc", ".zprofile", ".bash_profile", ".bashrc", ".gitconfig", ".netrc",
    ]

    /// 書き込み系ツール。読むだけの Read は鍵ディレクトリにだけ確認を出す。
    /// NotebookEdit はパス指定のルールを解釈できず、付けると普通の書き込みまで
    /// 確認に落ちてしまったので入れない（実測）。
    private static let writingTools = ["Write", "Edit", "MultiEdit"]

    static var askRules: [String] {
        var rules = dangerousCommands.map { "Bash(\($0):*)" }
        let home = NSHomeDirectory()
        for path in sensitivePaths {
            // ルールの絶対パスは "//" 始まり（`Write(//Users/me/.ssh/**)`）＝
            // スラッシュ1本 + 絶対パス。3本にすると効かない。
            let pattern = "/\(home)/\(path)/**"
            for tool in writingTools + ["Read"] {
                rules.append("\(tool)(\(pattern))")
            }
        }
        for file in sensitiveFiles {
            let pattern = "/\(home)/\(file)"
            for tool in writingTools {
                rules.append("\(tool)(\(pattern))")
            }
        }
        return rules
    }

    /// `--settings` に渡す JSON 文字列。作れなければ nil（確認なしで動く）。
    static var settingsJSON: String? {
        let payload = ["permissions": ["ask": askRules]]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return json
    }
}
