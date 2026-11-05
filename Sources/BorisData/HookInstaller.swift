import Foundation

/// Adds and removes Boris's entries in `settings.json`, leaving everything else as it was.
public enum HookInstaller {
    public struct Plan: Sendable, Equatable {
        public var helperPath: String
        public var permissions: Bool
        public var permissionWait: Int

        public init(helperPath: String, permissions: Bool, permissionWait: Int) {
            self.helperPath = helperPath
            self.permissions = permissions
            self.permissionWait = permissionWait
        }
    }

    public enum Status: Sendable, Equatable {
        case notInstalled, installed, outdated, disabledByPolicy
    }

    public enum Failure: Error, Equatable {
        case invalidSettings
    }

    static let events = ["SessionStart", "SessionEnd", "PreToolUse", "PostToolUse", "PostToolUseFailure", "SubagentStop", "Stop", "StopFailure", "Notification"]
    static let permissionEvent = "PermissionRequest"
    private static let marker = "/boris-hook"

    /// The check makes a removed app harmless: no error reaches Claude Code.
    static func command(_ plan: Plan, permission: Bool) -> String {
        let quoted = "'" + plan.helperPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let arguments = permission ? " --permission \(plan.permissionWait)" : ""
        return "[ -x \(quoted) ] && exec \(quoted)\(arguments) || exit 0"
    }

    static func merged(_ settings: [String: Any], plan: Plan) -> [String: Any] {
        var settings = removed(settings)
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for event in events {
            var groups = hooks[event] as? [[String: Any]] ?? []
            groups.append(["hooks": [["type": "command", "command": command(plan, permission: false), "async": true]]])
            hooks[event] = groups
        }
        if plan.permissions {
            var groups = hooks[permissionEvent] as? [[String: Any]] ?? []
            groups.append(["hooks": [["type": "command", "command": command(plan, permission: true), "timeout": plan.permissionWait + 5]]])
            hooks[permissionEvent] = groups
        }
        settings["hooks"] = hooks
        return settings
    }

    static func removed(_ settings: [String: Any]) -> [String: Any] {
        var settings = settings
        guard var hooks = settings["hooks"] as? [String: Any] else { return settings }
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let kept = groups.compactMap { group -> [String: Any]? in
                guard let list = group["hooks"] as? [[String: Any]] else { return group }
                let others = list.filter { !isOurs($0) }
                if others.count == list.count { return group }
                guard !others.isEmpty else { return nil }
                var group = group
                group["hooks"] = others
                return group
            }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        settings["hooks"] = hooks.isEmpty ? nil : hooks
        return settings
    }

    private static func isOurs(_ hook: [String: Any]) -> Bool {
        guard let command = hook["command"] as? String else { return false }
        return command.contains(marker)
    }

    static func status(_ settings: [String: Any], plan: Plan) -> Status {
        if settings["disableAllHooks"] as? Bool == true { return .disabledByPolicy }
        let hooks = settings["hooks"] as? [String: Any] ?? [:]
        var found = 0
        var matching = 0
        let expected = events + (plan.permissions ? [permissionEvent] : [])
        for (event, value) in hooks {
            for group in value as? [[String: Any]] ?? [] {
                for hook in group["hooks"] as? [[String: Any]] ?? [] where isOurs(hook) {
                    found += 1
                    let wanted = command(plan, permission: event == permissionEvent)
                    if expected.contains(event), hook["command"] as? String == wanted { matching += 1 }
                }
            }
        }
        if found == 0 { return .notInstalled }
        return found == expected.count && matching == expected.count ? .installed : .outdated
    }

    static func encode(_ settings: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        return data
    }

    private static func parse(_ url: URL) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.invalidSettings }
        return object
    }

    public static func status(at url: URL, plan: Plan) -> Status {
        guard let settings = try? parse(url) else { return .notInstalled }
        return status(settings, plan: plan)
    }

    /// Lines that will change, for showing before anything is written.
    public static func preview(at url: URL, plan: Plan) throws -> [String] {
        let settings = try parse(url)
        return diff(old: try encode(settings), new: try encode(merged(settings, plan: plan)))
    }

    public static func previewRemoval(at url: URL) throws -> [String] {
        let settings = try parse(url)
        return diff(old: try encode(settings), new: try encode(removed(settings)))
    }

    static func diff(old: Data, new: Data) -> [String] {
        let a = String(decoding: old, as: UTF8.self).components(separatedBy: "\n")
        let b = String(decoding: new, as: UTF8.self).components(separatedBy: "\n")
        return b.difference(from: a).map { change in
            switch change {
            case .insert(_, let line, _): return "+ " + line
            case .remove(_, let line, _): return "- " + line
            }
        }
    }

    private static func backupURL(_ url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".boris-backup")
    }

    public static func install(at url: URL, plan: Plan) throws {
        let settings = try parse(url)
        let backup = backupURL(url)
        // The first backup is the one that matters. Reinstalling must not overwrite it with a file that has our entries.
        if !FileManager.default.fileExists(atPath: backup.path), FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.copyItem(at: url, to: backup)
        }
        try encode(merged(settings, plan: plan)).write(to: url, options: .atomic)
    }

    /// When nothing else changed since the backup, the original bytes come back exactly.
    public static func uninstall(at url: URL) throws {
        let settings = try parse(url)
        let clean = removed(settings)
        let backup = backupURL(url)
        if let original = try? Data(contentsOf: backup),
           let object = try? JSONSerialization.jsonObject(with: original) as? [String: Any],
           NSDictionary(dictionary: object).isEqual(to: clean) {
            try original.write(to: url, options: .atomic)
            try FileManager.default.removeItem(at: backup)
            return
        }
        if clean.isEmpty, !FileManager.default.fileExists(atPath: backup.path) {
            try FileManager.default.removeItem(at: url)
            return
        }
        try encode(clean).write(to: url, options: .atomic)
    }
}
