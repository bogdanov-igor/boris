import Foundation
import BorisCore

/// Sessions that write a transcript but have no `sessions/<pid>.json`: a Claude Code started from inside another one, Cowork, a program on the SDK.
/// With no process to look at, their files are the only sign of life.
struct UnlistedSessions {
    static let quietLimit: TimeInterval = 15 * 60
    static let idleLimit: TimeInterval = 5 * 60

    private struct Entry {
        let file: URL
        var info: SessionInfo
        var modified: Date?
    }

    private let startedAt: Date
    private let allows: (URL) -> Bool
    private var entries: [String: Entry] = [:]
    /// A session that once had a file and lost it has ended. Its last writes must not bring it back.
    private var everListed: Set<String> = []

    /// - Parameter allows: whether a session's transcript may be read at all.
    init(startedAt: Date, allows: @escaping @Sendable (URL) -> Bool = { _ in true }) {
        self.startedAt = startedAt
        self.allows = allows
    }

    /// Picks up transcripts in a project folder written since launch.
    mutating func look(in project: URL, now: Date) {
        guard project.lastPathComponent != BorisPaths.usageProbeProject else { return }
        for name in FileInfo.names(in: project) where name.hasSuffix(".jsonl") {
            notice(session: String(name.dropLast(".jsonl".count)), transcript: project.appendingPathComponent(name), now: now, needsFreshFile: true)
        }
    }

    /// - Parameter needsFreshFile: false when something else of this session, such as a run, was written since launch.
    mutating func notice(session id: String, transcript: URL, now: Date, needsFreshFile: Bool = false) {
        guard entries[id] == nil, !everListed.contains(id) else { return }
        if needsFreshFile {
            // A file older than this launch says nothing: its session may have ended long ago.
            guard let modified = FileInfo.modified(transcript), modified > startedAt, now.timeIntervalSince(modified) <= Self.quietLimit else { return }
        }
        guard FileManager.default.fileExists(atPath: transcript.path), allows(transcript) else { return }
        let origin = TranscriptReader.origin(in: transcript)
        let info = SessionInfo(sessionId: id, pid: 0, cwd: origin.cwd, entrypoint: origin.entrypoint, startedAt: FileInfo.created(transcript))
        entries[id] = Entry(file: transcript, info: info)
    }

    /// - Parameter unfinishedWrites: the last write of each session's unfinished runs and agents.
    mutating func sessions(listed: Set<String>, unfinishedWrites: [String: Date], now: Date) -> [SessionInfo] {
        everListed.formUnion(listed)
        var result: [SessionInfo] = []
        for (id, known) in entries {
            var entry = known
            guard !listed.contains(id), let modified = FileInfo.modified(entry.file) else {
                entries[id] = nil
                continue
            }
            if modified != entry.modified || entry.info.status == nil {
                let tail = TranscriptReader.tail(entry.file)
                entry.modified = modified
                entry.info.status = tail.turnEnded ? "idle" : "busy"
                entry.info.currentStep = tail.running
                entry.info.statusUpdatedAt = modified
                if entry.info.cwd == nil {
                    let origin = TranscriptReader.origin(in: entry.file)
                    entry.info.cwd = origin.cwd
                    entry.info.entrypoint = origin.entrypoint
                }
            }
            let lastWrite = max(modified, unfinishedWrites[id] ?? .distantPast)
            let limit = entry.info.status == "idle" && unfinishedWrites[id] == nil ? Self.idleLimit : Self.quietLimit
            guard now.timeIntervalSince(lastWrite) <= limit else {
                entries[id] = nil
                continue
            }
            entries[id] = entry
            result.append(entry.info)
        }
        return result.sorted { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) }
    }
}

/// Which kinds of agent are worth naming. The general ones say nothing.
enum AgentKind {
    static func shown(_ type: String?) -> String? {
        guard let type, !type.isEmpty, type != "general-purpose", type != "workflow-subagent" else { return nil }
        return type
    }
}
