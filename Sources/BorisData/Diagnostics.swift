import Foundation
import BorisCore

/// A report to paste into a bug: versions, field names and counters, with no content and no project paths.
public enum Diagnostics {
    public static func report(world: WorldSnapshot, paths: ClaudePaths, appVersion: String) -> String {
        var lines = [
            "Boris \(appVersion)",
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Claude Code: \(Set(world.sessions.compactMap(\.version)).sorted().joined(separator: ", "))",
            "Sessions: \(world.sessions.count), runs: \(world.runs.count)",
            "Claude folder found: \(world.claudeFolderFound)",
        ]
        let issues = world.formatIssues.map(describe).sorted()
        lines.append("Format issues: \(issues.isEmpty ? "none" : issues.joined(separator: "; "))")
        lines.append("Session fields: \(sessionFields(paths).joined(separator: ", "))")
        return lines.joined(separator: "\n")
    }

    private static func describe(_ issue: FormatIssue) -> String {
        switch issue {
        case .unknownJournalEvent(let name): return "unknown journal event \(name)"
        case .unreadableFinal: return "unreadable final file"
        case .unreadableSessions: return "unreadable session files"
        }
    }

    private static func sessionFields(_ paths: ClaudePaths) -> [String] {
        for name in FileInfo.names(in: paths.sessions) where name.hasSuffix(".json") {
            guard let data = try? Data(contentsOf: paths.sessions.appendingPathComponent(name)),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            return object.keys.sorted()
        }
        return []
    }
}
