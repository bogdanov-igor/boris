import Foundation

/// Where Claude Code keeps its files.
public struct ClaudePaths: Sendable, Equatable {
    public var root: URL
    public var profile: URL
    /// False for Cowork: its `sessions` files name processes inside a virtual machine.
    public var processesAreHere = true

    public var sessions: URL { root.appendingPathComponent("sessions") }
    public var projects: URL { root.appendingPathComponent("projects") }
    public var settings: URL { root.appendingPathComponent("settings.json") }

    public init(root: URL, profile: URL? = nil) {
        self.root = root
        self.profile = profile ?? root.appendingPathComponent(".claude.json")
    }

    /// The setting wins, then `CLAUDE_CONFIG_DIR`, then `~/.claude`.
    public static func resolve(custom: String? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) -> ClaudePaths {
        if let custom, !custom.isEmpty {
            return ClaudePaths(root: URL(fileURLWithPath: (custom as NSString).expandingTildeInPath))
        }
        if let env = environment["CLAUDE_CONFIG_DIR"], !env.isEmpty {
            return ClaudePaths(root: URL(fileURLWithPath: (env as NSString).expandingTildeInPath))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ClaudePaths(root: home.appendingPathComponent(".claude"), profile: home.appendingPathComponent(".claude.json"))
    }

    public var isValid: Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: sessions.path, isDirectory: &isDir) && isDir.boolValue
    }
}

/// The other places on this Mac where Claude keeps the same kind of files. Only their transcripts and session lists are read.
public enum ClaudeFolders {
    public static func others(
        besides main: ClaudePaths,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [ClaudePaths] {
        guard environment["BORIS_ONLY_THIS_FOLDER"] == nil else { return [] }
        let settings = FileInfo.names(in: home)
            .filter { $0.hasPrefix(".") && $0.lowercased().contains("claude") }
            .map { home.appendingPathComponent($0) } + [home.appendingPathComponent(".config/claude")]
        var found = settings.filter { hasProjects($0) && !isSame($0, main.root) }.map { ClaudePaths(root: $0) }
        for folder in coworkFolders(home: home) where !isSame(folder, main.root) {
            var paths = ClaudePaths(root: folder)
            paths.processesAreHere = false
            found.append(paths)
        }
        return found
    }

    /// `local-agent-mode-sessions/<organisation>/<account>/agent/<id>/.claude`. The depth is not promised, so nearby levels count too.
    private static func coworkFolders(home: URL) -> [URL] {
        let base = home.appendingPathComponent("Library/Application Support/Claude/local-agent-mode-sessions")
        var level = [base]
        var found: [URL] = []
        for _ in 0..<4 {
            level = level.flatMap { folder in FileInfo.names(in: folder).filter { !$0.hasPrefix(".") }.map { folder.appendingPathComponent($0) } }
            found += level.map { $0.appendingPathComponent(".claude") }.filter(hasProjects)
        }
        return found
    }

    private static func hasProjects(_ folder: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: folder.appendingPathComponent("projects").path, isDirectory: &isDir) && isDir.boolValue
    }

    private static func isSame(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.resolvingSymlinksInPath().path == b.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

public enum BorisPaths {
    /// Boris's own files. `BORIS_STATE_DIR` moves them for tests and tools.
    public static var support: URL {
        if let custom = ProcessInfo.processInfo.environment["BORIS_STATE_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Boris", isDirectory: true)
    }

    /// Only a cache: it holds numbers and message ids and is built again if it goes away.
    public static var tokenIndex: URL { support.appendingPathComponent("token-index.json") }

    /// Boris's own empty folder for starting Claude Code. Sessions from here are his own and stay out of the menu.
    public static var usageProbeFolder: URL {
        support.appendingPathComponent("usage-probe", isDirectory: true)
    }
}

enum FileInfo {
    static func modified(_ url: URL) -> Date? {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return nil }
        return Date(timeIntervalSince1970: Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1_000_000_000)
    }

    static func created(_ url: URL) -> Date? {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return nil }
        return Date(timeIntervalSince1970: Double(st.st_birthtimespec.tv_sec))
    }

    static func size(_ url: URL) -> UInt64? {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return nil }
        return UInt64(st.st_size)
    }

    static func names(in url: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
    }
}
