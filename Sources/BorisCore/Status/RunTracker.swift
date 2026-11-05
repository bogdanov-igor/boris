import Foundation

/// What must survive between checks of one run, and between launches of the app.
public struct RunMemory: Codable, Sendable, Equatable {
    public var owner: ProcessIdentity?
    public var ownerLostSince: Date?
    public var attempt: Int
    public var lastStatus: RunStatus?
    public var finalModified: Date?
    public var journalModified: Date?

    public init(owner: ProcessIdentity? = nil, ownerLostSince: Date? = nil, attempt: Int = 1, lastStatus: RunStatus? = nil, finalModified: Date? = nil, journalModified: Date? = nil) {
        self.owner = owner
        self.ownerLostSince = ownerLostSince
        self.attempt = attempt
        self.lastStatus = lastStatus
        self.finalModified = finalModified
        self.journalModified = journalModified
    }
}

/// Turns snapshots into run states. All time and process facts come in as parameters.
public struct RunTracker: Sendable, Equatable {
    public var memory: [String: RunMemory]
    /// The last moment the Mac woke up: silence is counted from here at the earliest.
    public var lastWake: Date?
    public var config: StatusConfig

    public init(memory: [String: RunMemory] = [:], lastWake: Date? = nil, config: StatusConfig = StatusConfig()) {
        self.memory = memory
        self.lastWake = lastWake
        self.config = config
    }

    /// - Parameter processStart: the real start time of a running process, or nil when it is not running.
    public mutating func resolve(_ world: WorldSnapshot, processStart: (Int32) -> Date?) -> [RunState] {
        let bySession = Dictionary(world.sessions.map { ($0.sessionId, $0) }, uniquingKeysWith: { first, _ in first })
        return world.runs.map { resolve($0, session: bySession[$0.sessionId], now: world.takenAt, processStart: processStart) }
    }

    private mutating func resolve(_ run: RunSnapshot, session: SessionInfo?, now: Date, processStart: (Int32) -> Date?) -> RunState {
        var mem = memory[run.runId] ?? RunMemory()
        let firstLook = memory[run.runId] == nil
        let alive = ownerAlive(run, session: session, memory: &mem, processStart: processStart)
        let final = StatusRules.validFinal(run)

        let status: RunStatus
        if let final {
            status = StatusRules.status(of: final, journalAgents: run.agents)
        } else if alive {
            let quietSince = max(run.lastWrite, lastWake ?? .distantPast)
            status = now.timeIntervalSince(quietSince) > config.silenceThreshold ? .silent : .running
        } else if ownerDeadLongEnough(run, memory: &mem, firstLook: firstLook, now: now) {
            status = .interrupted
        } else {
            // Inside the grace period the process may still write its final file.
            status = mem.lastStatus.flatMap { $0.isActive ? $0 : nil } ?? .running
        }
        if alive { mem.ownerLostSince = nil }

        if let previous = mem.lastStatus {
            if previous.isTerminal && (status.isActive || finalRewrittenByNewAttempt(run, memory: mem)) {
                mem.attempt += 1
            }
        }
        mem.lastStatus = status
        mem.finalModified = run.finalModified
        mem.journalModified = run.journalModified
        memory[run.runId] = mem
        return state(run, final: final, status: status, attempt: mem.attempt, alive: alive)
    }

    /// A resumed run that finished between two checks: the journal grew and the final file came much later.
    private func finalRewrittenByNewAttempt(_ run: RunSnapshot, memory mem: RunMemory) -> Bool {
        guard let new = run.finalModified, let old = mem.finalModified, new != old else { return false }
        return run.journalModified != mem.journalModified && new.timeIntervalSince(old) > 60
    }

    private func ownerAlive(_ run: RunSnapshot, session: SessionInfo?, memory mem: inout RunMemory, processStart: (Int32) -> Date?) -> Bool {
        // No process to look at: such a session is listed only while its files keep changing.
        if let session, session.isUnlisted {
            mem.owner = nil
            return true
        }
        if let session, let start = processStart(session.pid),
           StatusRules.sessionOwnsRun(session, lastWrite: run.lastWrite, processStart: start, config: config) {
            mem.owner = ProcessIdentity(pid: session.pid, start: start)
            return true
        }
        // The session file may have moved to a new sessionId while the same process goes on.
        if let owner = mem.owner, let start = processStart(owner.pid), abs(start.timeIntervalSince(owner.start)) <= config.clockTolerance {
            return session == nil
        }
        mem.owner = nil
        return false
    }

    private func ownerDeadLongEnough(_ run: RunSnapshot, memory mem: inout RunMemory, firstLook: Bool, now: Date) -> Bool {
        if mem.ownerLostSince == nil {
            // On a first look the death may be old: its time is no later than the last write.
            mem.ownerLostSince = firstLook ? min(now, run.lastWrite) : now
        }
        guard let since = mem.ownerLostSince else { return false }
        return now.timeIntervalSince(since) >= config.deathGrace
    }

    private func state(_ run: RunSnapshot, final: FinalReport?, status: RunStatus, attempt: Int, alive: Bool) -> RunState {
        var agents: [AgentRecord]
        let plan: [String]
        if let final, !final.entries.isEmpty {
            agents = final.entries.map(\.record)
            plan = final.phaseTitles.isEmpty ? run.plannedPhases : final.phaseTitles
        } else {
            agents = run.agents
            plan = run.plannedPhases
        }
        if status.isTerminal {
            agents = agents.map { agent in
                var agent = agent
                if agent.state == .running { agent.state = .cancelled }
                return agent
            }
        }
        var state = RunState(
            runId: run.runId,
            sessionId: run.sessionId,
            name: RunPresentation.name(run),
            description: run.description,
            cwd: run.cwd,
            status: status,
            attempt: attempt,
            ownerAlive: alive,
            lastWrite: run.lastWrite,
            agents: agents,
            phases: RunPresentation.phases(agents: agents, plan: plan, isRunning: status.isActive),
            plannedPhases: plan,
            topFailure: RunPresentation.topFailure(agents),
            durationMs: final?.durationMs,
            errorFirstLine: final?.errorFirstLine,
            stoppedByClaude: run.stoppedByClaude,
            totalTokens: final?.totalTokens,
            total: final?.agentCount ?? agents.count
        )
        state.startedAt = run.startedAt
        state.entrypoint = run.entrypoint
        return state
    }
}
