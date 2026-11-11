import Foundation

/// Something that went wrong in a session, once per thing a person would act on: a workflow counts as one, however many of its agents fell.
public struct WorkFailure: Sendable, Equatable, Identifiable {
    public enum Source: Sendable, Equatable {
        /// Cut off: its process went away without a word.
        case session
        /// Its last message is an error from the API.
        case sessionError
        case agent(WorkNodeKind)
        case workflow(RunStatus, failed: Int, total: Int)
    }

    public var id: String
    public var sessionId: String
    public var project: String?
    public var name: String?
    /// The type of an agent with no name of its own, for those who know what it means.
    public var agentType: String?
    public var source: Source
    public var cause: FailureClass?
    /// What an API error was about, as far as its text says.
    public var problem: ApiProblem?
    public var resets: String?
    public var at: Date?
    /// How many fallen agents it stands for, as the Losses page counts them: a workflow's fallen agents, those left at work when it was cut off, and its own error.
    /// None for a session that ended on an error from the API: it can be continued, and the Losses page has it as an API error, not a fallen agent.
    public var count: Int

    public init(id: String, sessionId: String, project: String? = nil, name: String? = nil, agentType: String? = nil, source: Source, cause: FailureClass? = nil, problem: ApiProblem? = nil, resets: String? = nil, at: Date? = nil, count: Int = 1) {
        self.id = id
        self.sessionId = sessionId
        self.project = project
        self.name = name
        self.agentType = agentType
        self.source = source
        self.cause = cause
        self.problem = problem
        self.resets = resets
        self.at = at
        self.count = count
    }
}

extension FailureInfo {
    /// What an API error was about. Nothing for any other failure.
    var apiProblem: ApiProblem? {
        failureClass == .api ? ApiProblem(code: nil, status: nil, text: text) : nil
    }
}

extension WorkSession {
    private var projectName: String? {
        projectPath.map { URL(fileURLWithPath: $0).lastPathComponent }
    }

    /// Every agent that fell, by the rule of the Losses page: a workflow's agents through the workflow, and every other agent by itself.
    public var failures: [WorkFailure] {
        var result: [WorkFailure] = []
        if state == .interrupted {
            result.append(WorkFailure(id: id, sessionId: id, project: projectName, name: hasName ? displayName : nil, source: .session, at: lastActivity))
        }
        if state == .failed {
            result.append(WorkFailure(id: id, sessionId: id, project: projectName, name: hasName ? displayName : nil, source: .sessionError, cause: root.failure?.failureClass, problem: root.failure?.apiProblem, resets: root.failure?.resets, at: lastActivity, count: 0))
        }
        var stack = Array(root.children.reversed())
        while let node = stack.popLast() {
            stack.append(contentsOf: node.children.reversed())
            if let details = node.workflow {
                let agents = node.children.flatMap(\.flattened).filter { $0.kind == .workflowAgent }
                // An agent that went on after its workflow ended is told by its own end.
                let continued = Set(agents.filter(\.continued).map(\.id))
                let fallen = agents.filter { !$0.continued && RunLoss.fell($0, in: details) }.map(\.id)
                // While the session is at work, what it left unfinished is not over yet, as on the Losses page.
                let closed = state.isCurrent ? [] : details.closedAgents.filter { !continued.contains($0) }
                let lost = fallen.count + closed.count + (details.scriptFailure == nil ? 0 : 1)
                guard lost > 0 else { continue }
                let failed = agents.filter { fallen.contains($0.id) }
                result.append(WorkFailure(
                    id: node.id,
                    sessionId: id,
                    project: projectName,
                    name: node.title,
                    source: .workflow(details.status, failed: fallen.count, total: details.total),
                    cause: details.topFailure,
                    problem: failed.lazy.compactMap { $0.failure?.apiProblem }.first,
                    resets: failed.lazy.compactMap { $0.failure?.resets }.first,
                    at: details.endedAt ?? node.lastActivity,
                    count: lost
                ))
                continue
            }
            guard node.state == .failed, node.kind != .workflowAgent || node.continued else { continue }
            result.append(WorkFailure(
                id: node.id,
                sessionId: id,
                project: projectName,
                name: node.title,
                agentType: node.agentType,
                source: .agent(node.kind),
                cause: node.failure?.failureClass,
                problem: node.failure?.apiProblem,
                resets: node.failure?.resets,
                at: node.lastActivity
            ))
        }
        return result
    }

    /// Everyone who worked on it, the main agent included. A workflow is a script, so it is not one of them.
    public var agentCount: Int {
        root.flattened.filter { $0.kind != .workflow }.count
    }

    /// How many agents fell, the same number the Losses page gives for this session.
    public var failureCount: Int {
        failures.reduce(0) { $0 + $1.count }
    }

    /// The fallen agents of a stretch of time, by when each one fell.
    public func failureCount(in days: ClosedRange<Date>) -> Int {
        failures.filter { days.contains($0.at ?? lastActivity ?? .distantPast) }.reduce(0) { $0 + $1.count }
    }
}

extension RunStatus {
    public var isFailure: Bool {
        switch self {
        case .completedWithErrors, .allAgentsFailed, .failed, .interrupted: return true
        case .running, .silent, .completed, .stopped, .unknown: return false
        }
    }
}

/// What the page «Now» shows.
public struct NowDigest: Sendable, Equatable {
    static let failureWindow: TimeInterval = 6 * 3600
    static let finishedWindow: TimeInterval = 3 * 3600
    static let listLimit = 5

    public var waiting: [WorkSession]
    public var active: [WorkSession]
    public var failures: [WorkFailure]
    public var finished: [WorkSession]

    public init(_ model: WorkModel, now: Date) {
        waiting = model.waitingSessions
        active = model.sessions.filter { $0.state.isCurrent && $0.state != .waiting }
        failures = Array(model.sessions.flatMap(\.failures)
            .filter { now.timeIntervalSince($0.at ?? .distantPast) <= Self.failureWindow }
            .sorted { ($0.at ?? .distantPast) > ($1.at ?? .distantPast) }
            .prefix(Self.listLimit))
        finished = Array(model.sessions
            .filter { $0.state == .finished && now.timeIntervalSince($0.lastActivity ?? .distantPast) <= Self.finishedWindow }
            .sorted { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
            .prefix(Self.listLimit))
    }

    /// True only when there is really nothing to look at. A session at work without any workflow is not that.
    public var isQuiet: Bool { waiting.isEmpty && active.isEmpty && failures.isEmpty }
}
