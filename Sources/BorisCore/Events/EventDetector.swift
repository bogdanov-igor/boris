import Foundation

/// Survives restarts, so a run that died while Boris was closed is still reported once.
public struct DetectorMemory: Codable, Sendable, Equatable {
    public var notified: Set<String>
    public var activeRuns: [String: Int]
    public var usageFired: Set<String>
    public var usageSeen: [String: Double]
    public var limitFired: [String: Date]
    /// Sessions with a running process at the last look. Optional, so a state file from before it still loads.
    public var liveSessions: Set<String>?

    public init(notified: Set<String> = [], activeRuns: [String: Int] = [:], usageFired: Set<String> = [], usageSeen: [String: Double] = [:], limitFired: [String: Date] = [:], liveSessions: Set<String>? = nil) {
        self.notified = notified
        self.activeRuns = activeRuns
        self.usageFired = usageFired
        self.usageSeen = usageSeen
        self.limitFired = limitFired
        self.liveSessions = liveSessions
    }
}

public struct DetectorConfig: Sendable, Equatable {
    public var longTurn: TimeInterval
    public var waitingDelay: TimeInterval
    public var usageThresholds: [Double]
    public var sessionAfterRunQuiet: TimeInterval

    public init(longTurn: TimeInterval = 5 * 60, waitingDelay: TimeInterval = 5, usageThresholds: [Double] = [80, 95], sessionAfterRunQuiet: TimeInterval = 10) {
        self.longTurn = longTurn
        self.waitingDelay = waitingDelay
        self.usageThresholds = usageThresholds
        self.sessionAfterRunQuiet = sessionAfterRunQuiet
    }
}

/// Compares what is known with what was known and produces events. Never repeats itself.
public struct EventDetector: Sendable {
    private struct SessionTrack: Sendable {
        var busySince: Date?
        var waitingSince: Date?
        var waitingFired = false
    }

    public var memory: DetectorMemory
    public var config: DetectorConfig
    private var bootstrapped = false
    private var tracks: [String: SessionTrack] = [:]
    private var lastTerminal: [String: Date] = [:]
    private var knownTerminal: Set<String> = []

    public init(memory: DetectorMemory = DetectorMemory(), config: DetectorConfig = DetectorConfig()) {
        self.memory = memory
        self.config = config
    }

    public mutating func detect(runs: [RunState], sessions: [SessionInfo], usage: UsageSnapshot?, now: Date, failures: [HookState.Failure] = [], endedSessions: [SessionInfo] = []) -> [BorisEvent] {
        var events: [BorisEvent] = []
        events += runEvents(runs, now: now)
        events += interruptedSessions(sessions, ended: endedSessions, runs: runs, now: now)
        events += limitEvents(runs, hookLimit: failures.contains { $0.error == "rate_limit" }, now: now)
        events += sessionErrors(failures.filter { $0.error != "rate_limit" }, sessions: sessions, now: now)
        events += usageEvents(usage, now: now)
        events += sessionEvents(sessions, now: now)
        if !bootstrapped {
            bootstrapped = true
            prune(existing: Set(runs.map(\.runId)))
        }
        return events
    }

    private mutating func runEvents(_ runs: [RunState], now: Date) -> [BorisEvent] {
        var events: [BorisEvent] = []
        for run in runs {
            if run.status.isActive {
                memory.activeRuns[run.runId] = run.attempt
            }
            let terminalKey = "\(run.runId)|\(run.attempt)"
            if run.status.isTerminal, !knownTerminal.contains(terminalKey) {
                knownTerminal.insert(terminalKey)
                lastTerminal[run.sessionId] = now
            }
            guard let kind = EventKind(status: run.status) else { continue }
            let key = "\(run.runId)|\(run.attempt)|\(run.status.key)"
            guard !memory.notified.contains(key) else { continue }
            memory.notified.insert(key)
            // On the first pass only runs last seen active are news. Everything else is already old.
            let isNews = bootstrapped || (run.status.isTerminal && memory.activeRuns[run.runId] != nil)
            if isNews {
                events.append(event(kind, run: run, key: key, now: now))
            }
            if run.status.isTerminal {
                memory.activeRuns[run.runId] = nil
            }
        }
        return events
    }

    private func event(_ kind: EventKind, run: RunState, key: String, now: Date) -> BorisEvent {
        BorisEvent(
            id: key,
            kind: kind,
            at: now,
            runId: run.runId,
            sessionId: run.sessionId,
            name: run.name,
            project: run.projectName,
            agentsTotal: run.total,
            agentsFailed: run.failed,
            topFailure: run.topFailure,
            durationMs: run.durationMs,
            environment: run.environment,
            whileAway: !bootstrapped
        )
    }

    /// A process that vanished in the middle of work never said goodbye. A session idling at that moment lost nothing,
    /// and a workflow under it reports for itself, so the same loss is not told twice.
    private mutating func interruptedSessions(_ sessions: [SessionInfo], ended: [SessionInfo], runs: [RunState], now: Date) -> [BorisEvent] {
        let known = memory.liveSessions ?? []
        let live = Set(sessions.filter { !$0.isUnlisted }.map(\.sessionId))
        memory.liveSessions = live
        return ended.compactMap { session in
            guard known.contains(session.sessionId), !live.contains(session.sessionId), session.status != "idle" else { return nil }
            guard !runs.contains(where: { $0.sessionId == session.sessionId && ($0.status.isActive || $0.status == .interrupted) }) else { return nil }
            // A killed session can be resumed under a new process, and the old file stays behind. Its one loss is told once.
            let key = "ended|\(session.sessionId)|\(session.pid)"
            guard memory.notified.insert(key).inserted else { return nil }
            return BorisEvent(
                id: key,
                kind: .interrupted,
                at: now,
                sessionId: session.sessionId,
                name: session.name,
                project: session.projectName,
                environment: session.environment,
                whileAway: !bootstrapped
            )
        }
    }

    /// All runs hitting one limit make one event, sent as soon as the first agent fails.
    private mutating func limitEvents(_ runs: [RunState], hookLimit: Bool, now: Date) -> [BorisEvent] {
        var hit: [String: (kind: LimitKind, resets: String?, runs: Set<String>, agents: Int, projects: Set<String>)] = [:]
        // A limit reported by a hook has no details of its own. It only counts when no run reports one.
        for run in runs where run.status.isActive {
            for agent in run.agents where agent.state == .failed {
                guard let failure = agent.failure, failure.failureClass == .limit else { continue }
                let kind = failure.limitKind ?? .other
                let key = "\(kind.rawValue)|\(failure.resets ?? "")"
                var entry = hit[key] ?? (kind, failure.resets, [], 0, [])
                entry.runs.insert(run.runId)
                entry.agents += 1
                if let project = run.projectName { entry.projects.insert(project) }
                hit[key] = entry
            }
        }
        if hookLimit, hit.isEmpty, !memory.limitFired.contains(where: { now.timeIntervalSince($0.value) < limitMemory(.session) }) {
            hit["\(LimitKind.other.rawValue)|"] = (.other, nil, [], 0, [])
        }
        var events: [BorisEvent] = []
        for key in hit.keys.sorted() {
            guard let entry = hit[key] else { continue }
            if let fired = memory.limitFired[key], now.timeIntervalSince(fired) < limitMemory(entry.kind) { continue }
            memory.limitFired[key] = now
            events.append(BorisEvent(
                id: "limit|\(key)|\(Int(now.timeIntervalSince1970))",
                kind: .limitReached,
                at: now,
                project: entry.projects.count == 1 ? entry.projects.first : nil,
                agentsFailed: entry.agents,
                limitKind: entry.kind,
                resets: entry.resets,
                affectedRuns: entry.runs.count
            ))
        }
        return events
    }

    private func sessionErrors(_ failures: [HookState.Failure], sessions: [SessionInfo], now: Date) -> [BorisEvent] {
        failures.enumerated().map { index, failure in
            let session = sessions.first { $0.sessionId == failure.session }
            return BorisEvent(
                id: "error|\(failure.session)|\(Int(now.timeIntervalSince1970))|\(index)",
                kind: .sessionError,
                at: now,
                sessionId: failure.session,
                name: session?.name,
                project: session?.projectName,
                errorType: failure.error,
                environment: session?.environment
            )
        }
    }

    private func limitMemory(_ kind: LimitKind) -> TimeInterval {
        kind == .session ? 5 * 3600 : 24 * 3600
    }

    private mutating func usageEvents(_ usage: UsageSnapshot?, now: Date) -> [BorisEvent] {
        guard let usage else { return [] }
        var events: [BorisEvent] = []
        for window in usage.windows {
            let seen = memory.usageSeen[window.id]
            memory.usageSeen[window.id] = window.percent
            guard let seen else { continue }
            for threshold in config.usageThresholds where seen < threshold && window.percent >= threshold {
                let key = "\(window.id)|\(Int(threshold))|\(window.resetsAt?.timeIntervalSince1970 ?? 0)"
                guard !memory.usageFired.contains(key) else { continue }
                memory.usageFired.insert(key)
                events.append(BorisEvent(id: "usage|\(key)", kind: .limitNear, at: now, windowId: window.id, percent: window.percent))
            }
        }
        return events
    }

    private mutating func sessionEvents(_ sessions: [SessionInfo], now: Date) -> [BorisEvent] {
        var events: [BorisEvent] = []
        var next: [String: SessionTrack] = [:]
        for session in sessions {
            var track = tracks[session.sessionId] ?? SessionTrack()
            let isWaiting = session.status == "waiting"
            let reason = WaitingReason(session.waitingFor)

            if isWaiting, reason != .dialog {
                if track.waitingSince == nil { track.waitingSince = now }
                if !track.waitingFired, let since = track.waitingSince, now.timeIntervalSince(since) >= config.waitingDelay {
                    track.waitingFired = true
                    var tool: String?
                    if case .permission(let name)? = reason { tool = name }
                    events.append(BorisEvent(
                        id: "waiting|\(session.sessionId)|\(Int(now.timeIntervalSince1970))",
                        kind: .waiting,
                        at: now,
                        sessionId: session.sessionId,
                        name: session.name,
                        project: session.projectName,
                        toolName: tool,
                        environment: session.environment,
                        asksForAnswer: tool == nil && reason != .permission(tool: nil)
                    ))
                }
            } else {
                track.waitingSince = nil
                track.waitingFired = false
            }

            switch session.status {
            case "busy", "waiting":
                if track.busySince == nil { track.busySince = session.statusUpdatedAt ?? now }
            case "idle":
                if let since = track.busySince, now.timeIntervalSince(since) >= config.longTurn, !runJustEnded(session.sessionId, now: now) {
                    events.append(BorisEvent(
                        id: "turn|\(session.sessionId)|\(Int(now.timeIntervalSince1970))",
                        kind: .sessionFinished,
                        at: now,
                        sessionId: session.sessionId,
                        name: session.name,
                        project: session.projectName,
                        durationMs: Int(now.timeIntervalSince(since) * 1000),
                        environment: session.environment
                    ))
                }
                track.busySince = nil
            default:
                break
            }
            next[session.sessionId] = track
        }
        tracks = next
        return events
    }

    private func runJustEnded(_ sessionId: String, now: Date) -> Bool {
        guard let at = lastTerminal[sessionId] else { return false }
        return now.timeIntervalSince(at) <= config.sessionAfterRunQuiet
    }

    /// Runs outside the 24 hour window will not come back with the same attempt, so their keys can go.
    private mutating func prune(existing: Set<String>) {
        memory.notified = memory.notified.filter { key in
            guard let run = key.split(separator: "|").first else { return false }
            return existing.contains(String(run))
        }
        memory.activeRuns = memory.activeRuns.filter { existing.contains($0.key) }
    }
}
