import Foundation

public struct PhaseGroup: Sendable, Equatable, Identifiable {
    public var id: String { title ?? "" }
    /// Nil when agents have no phase information.
    public var title: String?
    public var agents: [AgentRecord]
    public var isCurrent: Bool

    public init(title: String?, agents: [AgentRecord], isCurrent: Bool = false) {
        self.title = title
        self.agents = agents
        self.isCurrent = isCurrent
    }
}

/// A run after judgement: what the rest of the app works with.
public struct RunState: Sendable, Equatable, Identifiable {
    public var id: String { runId }
    public var runId: String
    public var sessionId: String
    public var name: String
    public var description: String?
    public var cwd: String?
    public var status: RunStatus
    public var attempt: Int
    public var ownerAlive: Bool
    public var lastWrite: Date
    public var agents: [AgentRecord]
    public var phases: [PhaseGroup]
    public var plannedPhases: [String]
    public var total: Int
    public var done: Int
    public var running: Int
    public var failed: Int
    public var topFailure: FailureClass?
    public var durationMs: Int?
    public var errorFirstLine: String?
    public var stoppedByClaude: Bool
    public var totalTokens: Int?
    /// The agents the Losses page counts as fallen: failed, and not stopped together with the run.
    public var fallenAgents: [String] = []
    /// Agents still at work when the run was cut off, which will never finish.
    public var closedAgents: [String] = []
    /// The run's own error, when it is a failure of its own and not just its agents'.
    public var scriptFailure: LossReason?
    /// When it ended, by the same rule as the Losses page.
    public var endedAt: Date?
    public var startedAt: Date?
    public var entrypoint: String?

    public var environment: WorkEnvironment? { WorkEnvironment(entrypoint: entrypoint, unlisted: false) }

    /// How long it took or has been going. A resumed run's own count wins, because the file dates span the pause.
    public func elapsedMs(now: Date) -> Int? {
        if let durationMs { return durationMs }
        guard let startedAt else { return nil }
        return Int(max(0, (status.isActive ? now : lastWrite).timeIntervalSince(startedAt)) * 1000)
    }

    /// What the Losses page counts for it: each fallen agent, each agent left at work when it was cut off, and its own error.
    public var lost: Int { fallenAgents.count + closedAgents.count + (scriptFailure == nil ? 0 : 1) }

    /// The project's folder by the Projects page's rule: a separate copy belongs to its main copy.
    public var projectName: String? {
        GitPlace.projectPath(cwd: cwd, environment: environment).map { URL(fileURLWithPath: $0).lastPathComponent }
    }

    public init(
        runId: String,
        sessionId: String,
        name: String,
        description: String? = nil,
        cwd: String? = nil,
        status: RunStatus,
        attempt: Int = 1,
        ownerAlive: Bool = false,
        lastWrite: Date,
        agents: [AgentRecord] = [],
        phases: [PhaseGroup] = [],
        plannedPhases: [String] = [],
        topFailure: FailureClass? = nil,
        durationMs: Int? = nil,
        errorFirstLine: String? = nil,
        stoppedByClaude: Bool = false,
        totalTokens: Int? = nil,
        total: Int? = nil
    ) {
        self.runId = runId
        self.sessionId = sessionId
        self.name = name
        self.description = description
        self.cwd = cwd
        self.status = status
        self.attempt = attempt
        self.ownerAlive = ownerAlive
        self.lastWrite = lastWrite
        self.agents = agents
        self.phases = phases
        self.plannedPhases = plannedPhases
        self.total = total ?? agents.count
        self.done = agents.filter { $0.state == .done }.count
        self.running = agents.filter { $0.state == .running }.count
        self.failed = agents.filter { $0.state == .failed }.count
        // A killed run is the only one whose status is stopped.
        self.fallenAgents = agents.filter { RunLoss.fell($0, runKilled: status == .stopped) }.map { RunLoss.nodeId($0, runId: runId) }
        self.topFailure = topFailure
        self.durationMs = durationMs
        self.errorFirstLine = errorFirstLine
        self.stoppedByClaude = stoppedByClaude
        self.totalTokens = totalTokens
    }
}

public enum RunPresentation {
    /// Groups agents by phase in plan order. Agents of a phase outside the plan follow it.
    public static func phases(agents: [AgentRecord], plan: [String], isRunning: Bool) -> [PhaseGroup] {
        let withPhase = agents.contains { $0.phase != nil }
        guard withPhase else {
            return agents.isEmpty ? [] : [PhaseGroup(title: nil, agents: agents)]
        }
        var titles = plan
        for agent in agents {
            if let phase = agent.phase, !titles.contains(phase) { titles.append(phase) }
        }
        var groups = titles.map { title in
            PhaseGroup(title: title, agents: agents.filter { $0.phase == title })
        }
        let orphans = agents.filter { $0.phase == nil }
        if !orphans.isEmpty { groups.append(PhaseGroup(title: nil, agents: orphans)) }
        if isRunning, let current = groups.lastIndex(where: { group in group.agents.contains { $0.state == .running } }) {
            groups[current].isCurrent = true
        }
        return groups
    }

    /// The most frequent failure class among agents.
    public static func topFailure(_ agents: [AgentRecord]) -> FailureClass? {
        var counts: [FailureClass: Int] = [:]
        for agent in agents where agent.state == .failed {
            counts[agent.failure?.failureClass ?? .unknown, default: 0] += 1
        }
        return counts.max { a, b in
            a.value == b.value ? a.key.rawValue > b.key.rawValue : a.value < b.value
        }?.key
    }

    /// Name of a run: final file, then script file, then id.
    public static func name(_ run: RunSnapshot) -> String {
        run.final?.workflowName ?? run.scriptName ?? run.runId
    }
}
