import BorisCore
import Foundation

/// Every session Claude still keeps a log of, whole trees of agents included.
///
/// A transcript is what makes a session exist here: once Claude deletes the log, the session is gone from the list. Nothing is written anywhere.
public actor SessionHistory {
    private struct Known {
        let modified: Date?
        let info: SessionInfo
        let outcome: WorkState
        let place: GitPlace?
    }

    private let paths: ClaudePaths
    private let others: @Sendable () -> [ClaudePaths]
    private let scanner: RunScanner
    private var known: [String: Known] = [:]

    public init(paths: ClaudePaths, others: @escaping @Sendable () -> [ClaudePaths] = { [] }) {
        self.paths = paths
        self.others = others
        var config = RunScanner.Config()
        config.window = .infinity
        scanner = RunScanner(paths: paths, config: config, others: others)
    }

    /// Reads only what changed since the last time. Which of these are still at work, only the live scan can say.
    public func sessions(now: Date = Date()) async -> [WorkSession] {
        let transcripts = Self.transcripts(in: [paths] + others())
        known = known.filter { transcripts[$0.key] != nil }
        for (id, file) in transcripts {
            let modified = FileInfo.modified(file)
            if let entry = known[id], entry.modified == modified { continue }
            known[id] = Self.read(id: id, file: file, modified: modified)
            await Task.yield()
        }

        await scanner.markDiscovery()
        var world = await scanner.scan(now: now)
        // With nobody alive, an unfinished run counts as cut off. Those still at work are told apart by the live scan.
        world.sessions = []
        world.endedSessions = []
        var tracker = RunTracker()
        let runs = tracker.resolve(world) { _ in nil }
        let ownFolder = BorisPaths.usageProbeFolder.path
        world.sessions = known.values.map(\.info).filter { $0.cwd != ownFolder }
        for entry in known.values { world.places[entry.info.sessionId] = entry.place }
        let listed = Set(world.sessions.map(\.sessionId))

        return WorkBuilder.build(world: world, runs: runs).sessions
            .filter { listed.contains($0.id) }
            .map { session in
                var session = session
                session.root = Self.settled(session.root)
                session.root.state = known[session.id]?.outcome ?? .finished
                session.state = session.root.state
                return session
            }
    }

    private static func read(id: String, file: URL, modified: Date?) -> Known {
        let origin = TranscriptReader.origin(in: file)
        let tail = TranscriptReader.tail(file)
        // Its process is gone, so the number only has to be positive: zero would mean a session that never had a process.
        var info = SessionInfo(sessionId: id, pid: 1, cwd: origin.cwd, entrypoint: origin.entrypoint, status: "idle", startedAt: FileInfo.created(file), statusUpdatedAt: modified)
        info.title = TranscriptReader.title(in: file)
        info.contextTokens = tail.usage?.context
        info.model = tail.model
        return Known(modified: modified, info: info, outcome: outcome(tail), place: GitPlaceReader.place(folder: origin.cwd, branch: tail.gitBranch ?? origin.gitBranch))
    }

    /// How the session ended, from the last thing in its log.
    private static func outcome(_ tail: TranscriptReader.Tail) -> WorkState {
        if tail.last?.isApiError == true { return .failed }
        if tail.turnEnded || tail.last == nil { return .finished }
        return tail.last?.text?.hasPrefix("[Request interrupted") == true ? .stopped : .interrupted
    }

    /// Whatever had not finished when its session ended will never finish now.
    private static func settled(_ node: WorkNode) -> WorkNode {
        var node = node
        if node.state.isActive { node.state = .stopped }
        node.step = nil
        node.children = node.children.map(settled)
        return node
    }

    private static func transcripts(in roots: [ClaudePaths]) -> [String: URL] {
        var found: [String: URL] = [:]
        for root in roots {
            for project in FileInfo.names(in: root.projects) where !project.hasPrefix(".") {
                let folder = root.projects.appendingPathComponent(project)
                for name in FileInfo.names(in: folder) where name.hasSuffix(".jsonl") && !name.hasPrefix(".") {
                    found[String(name.dropLast(".jsonl".count))] = folder.appendingPathComponent(name)
                }
            }
        }
        return found
    }
}
