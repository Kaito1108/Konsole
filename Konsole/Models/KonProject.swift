import Foundation

/// A folder Kon works in: either a project it may change, or a reference it
/// only reads. The active one becomes the `claude` CLI's working directory, so
/// "このファイル直して" and relative paths resolve where the user expects.
nonisolated struct KonProject: Identifiable, Codable, Hashable {
    var id = UUID()
    /// What the user calls it out loud ("Konsole", "ノートブック").
    var name: String
    /// Absolute path to the folder.
    var path: String
    /// Other ways the user may say it, separated by 、 (音声認識の揺れ対策).
    var aliases: String = ""
    /// Anything Kon should keep in mind while working here.
    var notes: String = ""
    /// A reference: Kon reads it but doesn't change anything in it.
    var isReadOnly = false
    var isEnabled = true

    var aliasList: [String] {
        aliases.split(whereSeparator: { "、,，".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedPath: String { path.trimmingCharacters(in: .whitespacesAndNewlines) }

    var isUsable: Bool { isEnabled && !trimmedName.isEmpty && !trimmedPath.isEmpty }

    /// Expands a leading ~ so a hand-typed path works too.
    var expandedPath: String { (trimmedPath as NSString).expandingTildeInPath }

    var folderExists: Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: expandedPath, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    var kindLabel: String { isReadOnly ? "参照" : "プロジェクト" }

    /// Matches what the user said ("Konsoleに移動して") against the name and aliases.
    func matches(_ spoken: String) -> Bool {
        let needle = spoken.lowercased()
        return ([trimmedName] + aliasList)
            .map { $0.lowercased() }
            .filter { !$0.isEmpty }
            .contains { needle.contains($0) }
    }
}
