import Foundation

/// What an organization deployed to this Mac. Settings fetched from claude.ai cannot be seen from here;
/// the check for missing hook events is what notices those.
public struct ManagedSettings: Sendable {
    public var folder: URL
    public var profiles: [URL]

    public init(folder: URL, profiles: [URL]) {
        self.folder = folder
        self.profiles = profiles
    }

    public static var system: ManagedSettings {
        let preferences = "/Library/Managed Preferences"
        return ManagedSettings(
            folder: URL(fileURLWithPath: "/Library/Application Support/ClaudeCode"),
            profiles: ["\(preferences)/\(NSUserName())/com.anthropic.claudecode.plist", "\(preferences)/com.anthropic.claudecode.plist"].map { URL(fileURLWithPath: $0) }
        )
    }

    public var blocksUserHooks: Bool {
        sources.contains { $0["disableAllHooks"] as? Bool == true || $0["allowManagedHooksOnly"] as? Bool == true }
    }

    private var sources: [[String: Any]] {
        let dropIns = folder.appendingPathComponent("managed-settings.d")
        let files = [folder.appendingPathComponent("managed-settings.json")]
            + FileInfo.names(in: dropIns).filter { $0.hasSuffix(".json") }.map { dropIns.appendingPathComponent($0) }
        let json = files.compactMap { file -> [String: Any]? in
            (try? Data(contentsOf: file)).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
        }
        let plists = profiles.compactMap { file -> [String: Any]? in
            (try? Data(contentsOf: file)).flatMap { (try? PropertyListSerialization.propertyList(from: $0, format: nil)) as? [String: Any] }
        }
        return json + plists
    }
}
