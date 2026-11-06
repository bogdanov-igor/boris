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

    public init(id: String, sessionId: String, project: String? = nil, name: String? = nil, agentType: String? = nil, source: Source, cause: FailureClass? = nil, problem: ApiProblem? = nil, resets: String? = nil, at: Date? = nil) {
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

    public var failures: [WorkFailure] {
        var result: [WorkFailure] = []
        if state == .interrupted {
            result.append(WorkFailure(id: id, sessionId: id, project: projectName, name: hasName ? displayName : nil, source: .session, at: lastActivity))
        }
        if state == .failed {
            result.append(WorkFailure(id: id, sessionId: id, project: projectName, name: hasName ? displayName : nil, source: .sessionError, cause: root.failure?.failureClass, problem: root.failure?.apiProblem, resets: root.failure?.resets, at: lastActivity))
        }
        var stack = Array(root.children.reversed())
        while let node = stack.popLast() {
            if let details = node.workflow {
                guard details.status.isFailure else {
                    stack.append(contentsOf: node.children.reversed())
                    continue
                }
                let failed = node.children.flatMap(\.flattened).filter { $0.state == .failed }
                result.append(WorkFailure(
                    id: node.id,
                    sessionId: id,
                    project: projectName,
                    name: node.title,
                    source: .workflow(details.status, failed: failed.count, total: details.total),
                    cause: details.topFailure,
                    problem: failed.lazy.compactMap { $0.failure?.apiProblem }.first,
                    resets: failed.lazy.compactMap { $0.failure?.resets }.first,
                    at: node.lastActivity
                ))
                continue
            }
            if node.state == .failed {
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
            stack.append(contentsOf: node.children.reversed())
        }
        return result
    }

    /// Everyone who worked on it, the main agent included. A workflow is a script, so it is not one of them.
    public var agentCount: Int {
        root.flattened.filter { $0.kind != .workflow }.count
    }

    /// How many agents fell. A workflow that broke without any failed agent, and a session cut off, count as one each.
    public var failureCount: Int {
        failures.reduce(0) { total, failure in
            if case .workflow(_, let failed, _) = failure.source { return total + max(failed, 1) }
            return total + 1
        }
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
        active = model.sessions.filter { $0.state.isActive && $0.state != .waiting }
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
