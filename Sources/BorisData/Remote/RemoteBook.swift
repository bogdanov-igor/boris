import BorisCore
import Foundation

/// A live event from a remote machine, in words that hold nothing of the conversation.
public struct RemoteEvent: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case started, ended, turnEnded, failed, answered, agentStarted, agentStopped
        case tool(String)
        case waiting(tool: String?)
    }

    public var id: Int
    public var at: Date
    public var kind: Kind
    public var agent: String?

    public init(id: Int, at: Date, kind: Kind, agent: String? = nil) {
        self.id = id
        self.at = at
        self.kind = kind
        self.agent = agent
    }
}

/// What remote machines add to the picture of the work, in the shapes everything else already understands.
public struct RemoteWorld: Sendable, Equatable {
    public var sessions: [SessionInfo] = []
    public var ended: [SessionInfo] = []
    public var agents: [AgentSnapshot] = []
    public var places: [String: GitPlace] = [:]
    /// Sessions with no connection right now, so what hooks said about them earlier no longer holds.
    public var lost: Set<String> = []

    public init() {}

    public mutating func add(_ other: RemoteWorld) {
        sessions += other.sessions
        ended += other.ended
        agents += other.agents
        places.merge(other.places) { first, _ in first }
        lost.formUnion(other.lost)
    }
}

/// Everything known about one remote machine. Pure, so that every path can be tested without a connection.
public struct RemoteBook: Sendable {
    private struct AgentTrack: Sendable {
        var startedAt: Date
        var stoppedAt: Date?
    }

    private struct Entry: Sendable {
        var id: String
        var cwd: String?
        var version: String?
        var status: String?
        var waitingFor: String?
        var startedAt: Date?
        var updatedAt: Date?
        /// When this Mac last heard of it. The times above come from the machine's clock, if at all.
        var heardAt: Date
        /// Named by the helper's list, and not only by hooks. Only the list can tell that such a session has gone.
        var listed = false
        var ended = false
        var died = false
        var agents: [String: AgentTrack] = [:]

        var isLive: Bool { !ended && !died && status != "idle" }
    }

    private struct SpendKey: Hashable, Sendable {
        var session: String
        var agent: String?
        var run: String?
        var time: Int
        var model: String?
    }

    /// How long a finished or lost session stays around when nobody says anything more about it.
    static let kept: TimeInterval = 24 * 3600
    /// A session known only by its hooks stops counting as busy after this much silence: its end may have been lost with the connection.
    static let hookQuiet: TimeInterval = 30 * 60
    static let eventsKept = 200
    /// Finished agents kept per session.
    static let agentsKept = 32
    /// The size of a row's time, in seconds.
    static let quarter = 900

    public let host: String
    public private(set) var isUp = false
    private var downSince: Date?
    private var entries: [String: Entry] = [:]
    private var spend: [SpendKey: RemoteSpendRow] = [:]
    private var log: [String: [RemoteEvent]] = [:]
    private var nextEvent = 0
    public private(set) var spendVersion = 0

    public init(host: String, rows: [RemoteSpendRow] = []) {
        self.host = host
        take(rows: rows)
    }

    // MARK: - What comes in

    public mutating func linkUp() {
        isUp = true
        downSince = nil
    }

    public mutating func linkDown(now: Date) {
        if isUp || downSince == nil { downSince = now }
        isUp = false
        // Whatever was going on under a session is not known any more.
        for id in entries.keys { stopAgents(of: id, now: now) }
    }

    /// The whole list as the machine sees it. It is the truth about what runs there, as files are on this Mac.
    public mutating func take(sessions reports: [RemoteSessionReport], now: Date) {
        let named = Set(reports.map(\.id))
        for report in reports {
            var entry = entries[report.id] ?? Entry(id: report.id, heardAt: now)
            entry.heardAt = now
            entry.listed = true
            entry.status = report.status
            entry.waitingFor = report.waitingFor
            entry.cwd = report.cwd ?? entry.cwd
            entry.version = report.version ?? entry.version
            entry.startedAt = report.startedAt ?? entry.startedAt
            entry.updatedAt = report.updatedAt ?? entry.updatedAt
            entry.died = report.gone
            entry.ended = false
            entries[report.id] = entry
        }
        for (id, entry) in entries where entry.listed && !named.contains(id) && !entry.ended {
            finish(id, now: now)
        }
        prune(now: now)
    }

    public mutating func take(_ signal: HookSignal, now: Date) {
        switch signal {
        case .sessionStarted(let session, _, let cwd):
            touch(session, now: now)
            if let cwd = RemoteField.path(cwd) { entries[session]?.cwd = cwd }
            if entries[session]?.status == nil { entries[session]?.status = "idle" }
            remember(.started, session: session, now: now)
        case .sessionEnded(let session, _, _):
            touch(session, now: now)
            finish(session, now: now)
            remember(.ended, session: session, now: now)
        case .toolStarted(let session, let agent, let tool):
            touch(session, now: now)
            if entries[session]?.status != "waiting" { entries[session]?.status = "busy" }
            if let agent, entries[session]?.agents[agent] == nil { entries[session]?.agents[agent] = AgentTrack(startedAt: now) }
            remember(.tool(tool), session: session, agent: agent, now: now)
        case .toolFinished(let session, _, _):
            touch(session, now: now)
        case .agentStarted(let session, let agent):
            touch(session, now: now)
            entries[session]?.status = "busy"
            entries[session]?.agents[agent] = AgentTrack(startedAt: now)
            remember(.agentStarted, session: session, agent: agent, now: now)
        case .agentStopped(let session, let agent):
            touch(session, now: now)
            entries[session]?.agents[agent, default: AgentTrack(startedAt: now)].stoppedAt = now
            trimAgents(session)
            remember(.agentStopped, session: session, agent: agent, now: now)
        case .workflowLaunched(let session, _):
            touch(session, now: now)
        case .turnStopped(let session):
            touch(session, now: now)
            entries[session]?.status = "idle"
            remember(.turnEnded, session: session, now: now)
        case .stopFailure(let session, _):
            touch(session, now: now)
            remember(.failed, session: session, now: now)
        case .needsUser(let session):
            touch(session, now: now)
            remember(.waiting(tool: nil), session: session, now: now)
        case .permissionAsked(let session, let tool):
            touch(session, now: now)
            remember(.waiting(tool: tool), session: session, now: now)
        case .permissionAnswered(let session):
            touch(session, now: now)
            remember(.answered, session: session, now: now)
        }
    }

    /// A request names the folder, even when no other event has yet.
    public mutating func note(cwd: String?, session: String, now: Date) {
        touch(session, now: now)
        if let cwd = RemoteField.path(cwd), entries[session]?.cwd == nil { entries[session]?.cwd = cwd }
    }

    public mutating func take(rows: [RemoteSpendRow], full: Bool = false) {
        if full { spend = [:] }
        for row in rows {
            spend[SpendKey(session: row.session, agent: row.agent, run: row.run, time: row.time, model: row.model)] = row
        }
        spendVersion += 1
    }

    private mutating func touch(_ session: String, now: Date) {
        if entries[session] == nil { entries[session] = Entry(id: session, heardAt: now) }
        entries[session]?.heardAt = now
        entries[session]?.updatedAt = now
        if entries[session]?.startedAt == nil { entries[session]?.startedAt = now }
        entries[session]?.ended = false
    }

    private mutating func finish(_ id: String, now: Date) {
        entries[id]?.ended = true
        entries[id]?.status = "idle"
        entries[id]?.waitingFor = nil
        entries[id]?.updatedAt = now
        stopAgents(of: id, now: now)
    }

    private mutating func stopAgents(of id: String, now: Date) {
        guard var entry = entries[id] else { return }
        for (agent, track) in entry.agents where track.stoppedAt == nil { entry.agents[agent]?.stoppedAt = now }
        entries[id] = entry
    }

    private mutating func remember(_ kind: RemoteEvent.Kind, session: String, agent: String? = nil, now: Date) {
        nextEvent += 1
        log[session, default: []].append(RemoteEvent(id: nextEvent, at: now, kind: kind, agent: agent))
        if let count = log[session]?.count, count > Self.eventsKept { log[session]?.removeFirst(count - Self.eventsKept) }
    }

    private mutating func trimAgents(_ session: String) {
        guard let agents = entries[session]?.agents else { return }
        let finished = agents.filter { $0.value.stoppedAt != nil }.sorted { ($0.value.stoppedAt ?? .distantPast) < ($1.value.stoppedAt ?? .distantPast) }
        for item in finished.prefix(max(finished.count - Self.agentsKept, 0)) { entries[session]?.agents[item.key] = nil }
    }

    private mutating func prune(now: Date) {
        for (id, entry) in entries where !entry.isLive || !isUp {
            guard now.timeIntervalSince(entry.heardAt) > Self.kept else { continue }
            entries[id] = nil
            log[id] = nil
        }
    }

    // MARK: - What goes out

    public func events(session: String) -> [RemoteEvent] {
        log[session] ?? []
    }

    public func knows(session: String) -> Bool {
        entries[session] != nil
    }

    /// The live picture of this machine, in the shapes the rest of Boris reads from a Mac's own files.
    public func world(now: Date) -> RemoteWorld {
        var world = RemoteWorld()
        for entry in entries.values {
            var info = SessionInfo(sessionId: entry.id, pid: 0, cwd: entry.cwd, status: entry.status, waitingFor: entry.waitingFor, version: entry.version, startedAt: entry.startedAt, statusUpdatedAt: entry.updatedAt)
            info.host = host
            if let cwd = entry.cwd, let main = GitPlace.mainFolder(of: cwd) {
                world.places[entry.id] = GitPlace(isSeparateCopy: true, mainFolder: main, folderName: URL(fileURLWithPath: cwd).lastPathComponent)
            }
            if entry.died {
                world.ended.append(info)
                continue
            }
            let lastHeard = entry.heardAt
            if entry.isLive, !isUp {
                // A whole day without the machine: it no longer says anything about what runs there.
                if let downSince, now.timeIntervalSince(downSince) > Self.kept { continue }
                info.status = SessionInfo.noConnectionStatus
                info.waitingFor = nil
                world.lost.insert(entry.id)
            } else if entry.isLive, !entry.listed, now.timeIntervalSince(lastHeard) > Self.hookQuiet {
                info.status = "idle"
            }
            world.sessions.append(info)
            for (id, track) in entry.agents where info.status != SessionInfo.noConnectionStatus {
                let quiet = now.timeIntervalSince(lastHeard) > Self.hookQuiet
                world.agents.append(AgentSnapshot(id: id, sessionId: entry.id, state: track.stoppedAt == nil && !entry.ended && !quiet ? .running : .done, cwd: entry.cwd, startedAt: track.startedAt, lastWrite: track.stoppedAt ?? lastHeard))
            }
        }
        return world
    }

    /// Every session this machine has left numbers for or was seen with: the logs stay there, so this is what Projects can list.
    public func pastSessions() -> [WorkSession] {
        struct Summary {
            var cwd: String?
            var first = Int.max
            var last = 0
            var usage = TokenUsage()
            var model: String?
        }
        var summaries: [String: Summary] = [:]
        for row in spend.values {
            var summary = summaries[row.session] ?? Summary()
            if row.agent == nil || summary.cwd == nil { summary.cwd = row.cwd ?? summary.cwd }
            summary.first = min(summary.first, row.time)
            if row.time >= summary.last {
                summary.last = row.time
                summary.model = row.model ?? summary.model
            }
            summary.usage = summary.usage + row.usage
            summaries[row.session] = summary
        }
        var ids = Set(summaries.keys)
        ids.formUnion(entries.keys)
        return ids.map { id in
            let summary = summaries[id]
            let entry = entries[id]
            let started = entry?.startedAt ?? summary.map { Date(timeIntervalSince1970: TimeInterval($0.first)) }
            let last = entry?.updatedAt ?? summary.map { Date(timeIntervalSince1970: TimeInterval($0.last + Self.quarter)) }
            let cwd = entry?.cwd ?? summary?.cwd
            let state: WorkState = entry?.died == true ? .interrupted : .finished
            var session = WorkSession(
                id: id,
                environment: .remote(host: host),
                cwd: cwd,
                state: state,
                startedAt: started,
                lastActivity: last,
                root: WorkNode(id: id, kind: .main, state: state, tokens: summary?.usage, model: summary?.model)
            )
            if let cwd, let main = GitPlace.mainFolder(of: cwd) {
                session.place = GitPlace(isSeparateCopy: true, mainFolder: main, folderName: URL(fileURLWithPath: cwd).lastPathComponent)
            }
            return session
        }
    }

    #if DEBUG
    public mutating func showForSnapshot(_ event: RemoteEvent, session: String) {
        log[session, default: []].append(event)
    }
    #endif

    public var spendRows: [RemoteSpendRow] {
        spend.values.sorted { ($0.time, $0.session, $0.agent ?? "", $0.model ?? "") < ($1.time, $1.session, $1.agent ?? "", $1.model ?? "") }
    }

    /// Spend in the form the local logs have it: per transcript, day and model, with days as this Mac counts them.
    public func records(timeZone: TimeZone = .current) -> [TokenRecord] {
        struct Key: Hashable {
            var session: String
            var agent: String?
            var run: String?
            var day: String
            var model: String?
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        var days: [Int: String] = [:]
        var cwds: [Key: String] = [:]
        var totals: [Key: TokenUsage] = [:]
        for row in spend.values {
            let day = days[row.time] ?? formatter.string(from: Date(timeIntervalSince1970: TimeInterval(row.time)))
            days[row.time] = day
            let key = Key(session: row.session, agent: row.agent, run: row.run, day: day, model: row.model)
            totals[key, default: TokenUsage()] = totals[key, default: TokenUsage()] + row.usage
            if let cwd = row.cwd { cwds[key] = cwd }
        }
        return totals.map { key, usage in
            TokenRecord(sessionId: key.session, agentId: key.agent, runId: key.run, cwd: cwds[key], day: key.day, model: key.model, usage: usage, host: host)
        }
    }
}
