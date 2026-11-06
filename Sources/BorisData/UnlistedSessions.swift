import Foundation
import BorisCore

/// Sessions that write a transcript but have no `sessions/<pid>.json`: a Claude Code started from inside another one, Cowork, a program on the SDK.
/// With no process to look at, their files are the only sign of life.
struct UnlistedSessions {
    static let quietLimit: TimeInterval = 15 * 60
    static let idleLimit: TimeInterval = 5 * 60
    /// An agent can say something and go on working, so only a little silence after it means the turn is over.
    static let spokeSettle: TimeInterval = 10

    private struct Entry {
        let file: URL
        var info: SessionInfo
        var modified: Date?
        var spokeToPerson = false
    }

    private let startedAt: Date
    private var entries: [String: Entry] = [:]
    /// A session that once had a file and lost it has ended. Its last writes must not bring it back.
    private var everListed: Set<String> = []

    init(startedAt: Date) {
        self.startedAt = startedAt
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
            guard let modified = FileInfo.modified(transcript) else { return }
            // A file older than this launch says nothing: its session may have ended long ago, and the session list would have it if not.
            // Cowork has no such list, and a task that waits for the person writes nothing. How recent its file is, is all there is to go by.
            let isCowork = ClaudeFolders.isCowork(transcript)
            guard isCowork || modified > startedAt, now.timeIntervalSince(modified) <= (isCowork ? CoworkWaiting.quietLimit : Self.quietLimit) else { return }
        }
        guard FileManager.default.fileExists(atPath: transcript.path) else { return }
        let origin = TranscriptReader.origin(in: transcript)
        let info = SessionInfo(sessionId: id, pid: 0, cwd: origin.cwd, entrypoint: ClaudeFolders.entrypoint(origin.entrypoint, transcript: transcript), startedAt: FileInfo.created(transcript))
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
                entry.spokeToPerson = tail.spokeToPerson
                entry.info.currentStep = tail.running
                entry.info.statusUpdatedAt = modified
                if entry.info.cwd == nil {
                    let origin = TranscriptReader.origin(in: entry.file)
                    entry.info.cwd = origin.cwd
                    entry.info.entrypoint = ClaudeFolders.entrypoint(origin.entrypoint, transcript: entry.file)
                }
            }
            let lastWrite = max(modified, unfinishedWrites[id] ?? .distantPast)
            if entry.spokeToPerson, now.timeIntervalSince(lastWrite) >= Self.spokeSettle { entry.info.status = "idle" }
            let waitingFor = entry.info.environment == .cowork && entry.info.status == "busy" ? CoworkWaiting.reason(running: entry.info.currentStep, quietFor: now.timeIntervalSince(lastWrite)) : nil
            let limit = waitingFor != nil ? CoworkWaiting.quietLimit : entry.info.status == "idle" && unfinishedWrites[id] == nil ? Self.idleLimit : Self.quietLimit
            guard now.timeIntervalSince(lastWrite) <= limit else {
                entries[id] = nil
                continue
            }
            entries[id] = entry
            var shown = entry.info
            // Worked out at every scan: for a call that may ask, it is the silence that says so, and silence writes nothing.
            if let waitingFor {
                shown.status = "waiting"
                shown.waitingFor = waitingFor
            }
            result.append(shown)
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
