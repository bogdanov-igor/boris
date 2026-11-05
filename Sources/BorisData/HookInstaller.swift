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
        case notInstalled, installed, outdated
        /// `disableAllHooks` in the person's own settings: their choice, not a ban.
        case disabledInSettings
        case disabledByPolicy
        /// The file cannot be trusted, so nothing gets written to it.
        case unreadable
    }

    public enum Failure: Error, Equatable {
        case invalidSettings
    }

    public struct Preview: Sendable, Equatable {
        public var lines: [String]
        /// The layout of the file changes as well, while what is in it stays the same.
        public var reformats: Bool
    }

    static let events = ["SessionStart", "SessionEnd", "PreToolUse", "PostToolUse", "PostToolUseFailure", "SubagentStart", "SubagentStop", "Stop", "StopFailure", "Notification"]
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

    private static func hasOurEntries(_ settings: [String: Any]) -> Bool {
        guard let hooks = settings["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { value in
            (value as? [[String: Any]] ?? []).contains { group in
                (group["hooks"] as? [[String: Any]] ?? []).contains(where: isOurs)
            }
        }
    }

    static func status(_ settings: [String: Any], plan: Plan) -> Status {
        if settings["disableAllHooks"] as? Bool == true { return .disabledInSettings }
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

    private struct Loaded {
        var file: URL
        var settings: [String: Any]
        var raw: Data?
    }

    /// Follows a link, so a settings file kept in dotfiles stays where its owner put it. A file that exists and cannot be read is never taken for an empty one.
    private static func load(_ url: URL) throws -> Loaded {
        let manager = FileManager.default
        let file = url.resolvingSymlinksInPath()
        guard manager.fileExists(atPath: file.path) else {
            if (try? manager.destinationOfSymbolicLink(atPath: file.path)) != nil { throw Failure.invalidSettings }
            return Loaded(file: file, settings: [:], raw: nil)
        }
        guard let raw = try? Data(contentsOf: file), let settings = decode(raw), isSafeToEdit(settings) else { throw Failure.invalidSettings }
        return Loaded(file: file, settings: settings, raw: raw)
    }

    private static func decode(_ data: Data) -> [String: Any]? {
        data.isEmpty ? [:] : (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Adding to a value of an unexpected shape would replace it. Events Boris does not use are left out of this, and stay as they are.
    private static func isSafeToEdit(_ settings: [String: Any]) -> Bool {
        guard let value = settings["hooks"] else { return true }
        guard let hooks = value as? [String: Any] else { return false }
        return (events + [permissionEvent]).allSatisfy { hooks[$0] == nil || hooks[$0] is [[String: Any]] }
    }

    public static func status(at url: URL, plan: Plan, managed: ManagedSettings = .system) -> Status {
        if managed.blocksUserHooks { return .disabledByPolicy }
        guard let loaded = try? load(url) else { return .unreadable }
        return status(loaded.settings, plan: plan)
    }

    /// What will change, for showing before anything is written.
    public static func preview(at url: URL, plan: Plan) throws -> Preview {
        let loaded = try load(url)
        let current = try encode(loaded.settings)
        let lines = diff(old: current, new: try encode(merged(loaded.settings, plan: plan)))
        return Preview(lines: lines, reformats: isLaidOutDifferently(loaded, from: current))
    }

    public static func previewRemoval(at url: URL) throws -> Preview {
        let loaded = try load(url)
        let current = try encode(loaded.settings)
        let lines = diff(old: current, new: try encode(removed(loaded.settings)))
        switch try removal(loaded) {
        case .nothing: return Preview(lines: [], reformats: false)
        case .restore: return Preview(lines: lines, reformats: false)
        case .write, .delete: return Preview(lines: lines, reformats: isLaidOutDifferently(loaded, from: current))
        }
    }

    private static func isLaidOutDifferently(_ loaded: Loaded, from normal: Data) -> Bool {
        guard let raw = loaded.raw, !raw.isEmpty else { return false }
        return raw != normal
    }

    static func diff(old: Data, new: Data) -> [String] {
        let a = String(decoding: old, as: UTF8.self).components(separatedBy: "\n")
        let b = String(decoding: new, as: UTF8.self).components(separatedBy: "\n")
        return b.difference(from: a).compactMap { change in
            switch change {
            case .insert(_, let line, _): return line.allSatisfy(\.isWhitespace) ? nil : "+ " + line
            case .remove(_, let line, _): return line.allSatisfy(\.isWhitespace) ? nil : "- " + line
            }
        }
    }

    private static func backupURL(_ file: URL) -> URL {
        file.deletingLastPathComponent().appendingPathComponent(file.lastPathComponent + ".boris-backup")
    }

    /// The copy to come back to is the file without our entries. A repair must not overwrite it with one that has them.
    private static func keepBackup(_ loaded: Loaded) throws {
        let manager = FileManager.default
        let backup = backupURL(loaded.file)
        let exists = manager.fileExists(atPath: backup.path)
        if exists, hasOurEntries(loaded.settings) { return }
        if exists { try manager.removeItem(at: backup) }
        if loaded.raw != nil { try manager.copyItem(at: loaded.file, to: backup) }
    }

    /// Replacing a file would otherwise drop the permissions its owner set.
    private static func write(_ data: Data, to file: URL) throws {
        let manager = FileManager.default
        let permissions = try? manager.attributesOfItem(atPath: file.path)[.posixPermissions]
        try data.write(to: file, options: .atomic)
        if let permissions { try? manager.setAttributes([.posixPermissions: permissions], ofItemAtPath: file.path) }
    }

    public static func install(at url: URL, plan: Plan) throws {
        let loaded = try load(url)
        try keepBackup(loaded)
        try write(encode(merged(loaded.settings, plan: plan)), to: loaded.file)
    }

    private enum Removal {
        case nothing
        case restore(Data)
        case write(Data)
        case delete
    }

    /// When nothing else changed since the backup, the original bytes come back exactly.
    private static func removal(_ loaded: Loaded) throws -> Removal {
        guard hasOurEntries(loaded.settings) else { return .nothing }
        let clean = removed(loaded.settings)
        let backup = backupURL(loaded.file)
        if let original = try? Data(contentsOf: backup), let object = decode(original), !hasOurEntries(object),
           NSDictionary(dictionary: removed(object)).isEqual(to: clean) {
            return .restore(original)
        }
        if clean.isEmpty, !FileManager.default.fileExists(atPath: backup.path) { return .delete }
        return .write(try encode(clean))
    }

    public static func uninstall(at url: URL) throws {
        let loaded = try load(url)
        switch try removal(loaded) {
        case .nothing:
            break
        case .restore(let original):
            try write(original, to: loaded.file)
            try FileManager.default.removeItem(at: backupURL(loaded.file))
        case .write(let data):
            try write(data, to: loaded.file)
        case .delete:
            try FileManager.default.removeItem(at: loaded.file)
        }
    }
}
