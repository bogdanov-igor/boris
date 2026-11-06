import BorisCore
import Foundation

/// Which sessions ran in Cursor. The logs say `claude-vscode` for both editors, so this can only be seen while a session runs,
/// and it is kept: nothing else will tell later. Only session ids go in the file.
public final class EditorBook: @unchecked Sendable {
    private let file: URL?
    private let onlyCursorInstalled: Bool
    private let lock = NSLock()
    private var cursor: Set<String> = []
    private var vsCode: Set<String> = []

    /// - Parameters:
    ///   - file: nil keeps it in memory.
    ///   - onlyCursorInstalled: with no VS Code on this Mac, a session nobody saw running can only have been in Cursor.
    public init(file: URL? = nil, onlyCursorInstalled: Bool = false) {
        self.file = file
        self.onlyCursorInstalled = onlyCursorInstalled
        if let file, let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(Set<String>.self, from: data) {
            cursor = saved
        }
    }

    public static var fileName: String { "cursor-sessions.json" }

    /// Looks where apps usually are. Any copy of VS Code counts, Insiders too.
    public static func isOnlyCursorInstalled(appFolders: [URL] = [URL(fileURLWithPath: "/Applications"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]) -> Bool {
        let names = appFolders.flatMap { FileInfo.names(in: $0) }
        return names.contains("Cursor.app") && !names.contains { $0.hasPrefix("Visual Studio Code") }
    }

    /// The entrypoint this session counts as.
    public func entrypoint(_ raw: String?, session: String) -> String? {
        guard let raw, raw.contains("vscode") else { return raw }
        lock.lock()
        defer { lock.unlock() }
        if cursor.contains(session) { return SourceDetection.cursorEntrypoint }
        return onlyCursorInstalled && !vsCode.contains(session) ? SourceDetection.cursorEntrypoint : raw
    }

    /// Asks the processes about a running session, once, and says what it counts as from then on.
    public func identified(_ session: SessionInfo) -> SessionInfo {
        guard session.entrypoint?.contains("vscode") == true else { return session }
        var session = session
        if !isKnown(session.sessionId), SessionReader.isLive(session) {
            note(session.sessionId, editor: SourceDetection.editor(of: session.pid))
        }
        session.entrypoint = entrypoint(session.entrypoint, session: session.sessionId)
        return session
    }

    private func isKnown(_ session: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cursor.contains(session) || vsCode.contains(session)
    }

    private func note(_ session: String, editor: LoadGroup?) {
        guard editor == .cursor || editor == .vsCode else { return }
        lock.lock()
        defer { lock.unlock() }
        if editor == .vsCode {
            vsCode.insert(session)
        } else if cursor.insert(session).inserted, let file, let data = try? JSONEncoder().encode(cursor) {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
    }
}

/// The one place that decides whether something belongs to a source that is off. Whoever reads Claude's files asks here first.
///
/// Sources that share a folder can only be told apart by a word near the start of each main transcript, so that much of a file is read, once, and only that word stays.
/// Everything else of an off source stays closed: the rest of the transcript, its agents and its workflows. Cowork has folders of its own, which are not opened at all.
public final class SourceFilter: @unchecked Sendable {
    /// Where Claude Code on this Mac keeps its files. Remote machines have their own.
    private static let localClaudeCode: Set<SourceID> = [.terminal, .vsCode, .cursor, .claudeDesktop, .program]

    public let off: Set<SourceID>
    /// Those of them with files on this Mac. The chat has none and is off by default, so it must not cost a look at every log.
    private let filesOff: Set<SourceID>
    public let editors: EditorBook
    private let lock = NSLock()
    private var heads: [String: (size: UInt64?, entrypoint: String?)] = [:]

    /// - Parameter off: sources with reading turned off. With none that have files here, nothing looks at any file.
    public init(off: Set<SourceID> = [], editors: EditorBook = EditorBook()) {
        self.off = off
        filesOff = off.intersection(Self.localClaudeCode.union([.cowork]))
        self.editors = editors
    }

    /// Whether another choice would read the same files as this one, so that nothing has to be read again for it.
    public func readsSameFiles(off other: Set<SourceID>) -> Bool {
        other.intersection(Self.localClaudeCode.union([.cowork])) == filesOff
    }

    /// Whether anything in this place may be opened.
    public func reads(root: ClaudePaths) -> Bool {
        root.processesAreHere ? !filesOff.isSuperset(of: Self.localClaudeCode) : !filesOff.contains(.cowork)
    }

    /// With nothing to say where it runs, work stays visible: there is no choice of the person's to apply to it.
    public func allows(session: SessionInfo) -> Bool {
        guard !off.isEmpty, let source = SourceID(session.environment) else { return true }
        return !off.contains(source)
    }

    /// - Parameter url: a session's own transcript. Its agents and workflows go by it.
    public func allows(transcript url: URL) -> Bool {
        guard !filesOff.isEmpty else { return true }
        let session = url.deletingPathExtension().lastPathComponent
        guard let source = SourceID(entrypoint: editors.entrypoint(head(of: url), session: session)) else { return true }
        return !off.contains(source)
    }

    /// A file that does not say yet is looked at again only once it has grown. One that has said stays as it is: logs are only added to.
    private func head(of url: URL) -> String? {
        lock.lock()
        defer { lock.unlock() }
        let size = FileInfo.size(url)
        if let known = heads[url.path], known.entrypoint != nil || known.size == size { return known.entrypoint }
        let found = TranscriptHead.entrypoint(in: url).entrypoint
        heads[url.path] = (size, found)
        return found
    }
}
