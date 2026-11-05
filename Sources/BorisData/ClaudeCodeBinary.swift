import Foundation

/// Finds the Claude Code program on this Mac. An app started from Finder has no shell PATH, so the usual places are checked.
public enum ClaudeCodeBinary {
    public static func find(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let fixed = [
            home.appendingPathComponent(".local/bin/claude"),
            home.appendingPathComponent(".claude/local/claude"),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude"),
        ]
        if let found = fixed.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) { return found }
        return [".vscode", ".vscode-insiders", ".cursor"].compactMap { newestExtension(in: home.appendingPathComponent("\($0)/extensions")) }.first
    }

    /// `anthropic.claude-code-2.1.312-darwin-arm64` sorts by version, not by text: 2.1.9 is older than 2.1.312.
    private static func newestExtension(in folder: URL) -> URL? {
        let names = FileInfo.names(in: folder).filter { $0.hasPrefix("anthropic.claude-code-") }
        let sorted = names.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        return sorted.lazy
            .map { folder.appendingPathComponent($0).appendingPathComponent("resources/native-binary/claude") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}
