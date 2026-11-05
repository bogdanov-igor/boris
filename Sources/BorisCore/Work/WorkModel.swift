import Foundation

/// The products of Claude that Boris understands.
public enum WorkProduct: String, Sendable, CaseIterable {
    case claudeCode, cowork, chat
}

/// Where a session runs. A project can be open in several of these at once, so this belongs to the session.
public enum WorkEnvironment: Sendable, Hashable {
    case terminal, vsCode, cursor, claudeDesktop, cowork, program, chat
    /// A Claude Code started from inside another one, which writes no session file.
    case insideClaude
    case remote(host: String)

    /// - Parameter unlisted: known only by its transcript, with no process to look at.
    public init?(entrypoint: String?, unlisted: Bool) {
        guard let entrypoint else {
            guard unlisted else { return nil }
            self = .insideClaude
            return
        }
        switch entrypoint {
        case "local-agent", "local_agent": self = .cowork
        case "cli": self = unlisted ? .insideClaude : .terminal
        case _ where entrypoint.contains("vscode"): self = .vsCode
        case _ where entrypoint.contains("cursor"): self = .cursor
        case _ where entrypoint.contains("desktop"): self = .claudeDesktop
        case _ where entrypoint.hasPrefix("sdk"): self = .program
        default: return nil
        }
    }

    public var product: WorkProduct {
        switch self {
        case .cowork: return .cowork
        case .chat: return .chat
        default: return .claudeCode
        }
    }
}

/// What is going on with a session or a node.
public enum WorkState: String, Sendable, Equatable {
    case running, silent, waiting, finished, failed, stopped, interrupted

    public var isActive: Bool { self == .running || self == .silent || self == .waiting }
}

public enum WorkNodeKind: String, Sendable, Equatable, CaseIterable {
    case main, subagent, fork, workflow, workflowAgent
}

/// What only a workflow has. Its status is judged from its final file, its agents and its process.
public struct WorkflowDetails: Sendable, Equatable {
    public var runId: String
    public var status: RunStatus
    public var description: String?
    public var phases: [PhaseGroup]
    /// What the script plans, for a run with no agents yet.
    public var planned: [String]
    public var total: Int
    public var done: Int
    public var running: Int
    public var failed: Int
    public var topFailure: FailureClass?
    public var durationMs: Int?
    public var errorFirstLine: String?
    public var stoppedByClaude: Bool
    public var totalTokens: Int?

    public init(_ run: RunState) {
        runId = run.runId
        status = run.status
        description = run.description
        phases = run.phases
        planned = run.plannedPhases
        total = run.total
        done = run.done
        running = run.running
        failed = run.failed
        topFailure = run.topFailure
        durationMs = run.durationMs
        errorFirstLine = run.errorFirstLine
        stoppedByClaude = run.stoppedByClaude
        totalTokens = run.totalTokens
    }
}

/// One thing that works: the main agent, a subagent, a fork, a workflow or an agent of a workflow. Any of them can have children, to any depth.
public struct WorkNode: Sendable, Equatable, Identifiable {
    public var id: String
    public var kind: WorkNodeKind
    /// Nil only for the root of a session.
    public var parentId: String?
    public var title: String?
    public var agentType: String?
    public var state: WorkState
    public var step: StepBrief?
    /// How full the context is, from the last record.
    public var contextTokens: Int?
    /// What was really spent, each message counted once.
    public var tokens: TokenUsage?
    public var model: String?
    public var failure: FailureInfo?
    public var attempts: Int
    public var phase: String?
    public var workflow: WorkflowDetails?
    /// Set only when it works somewhere other than its session: in its own separate copy of the project.
    public var place: GitPlace?
    public var lastActivity: Date?
    public var children: [WorkNode]

    public init(
        id: String,
        kind: WorkNodeKind,
        parentId: String? = nil,
        title: String? = nil,
        agentType: String? = nil,
        state: WorkState = .running,
        step: StepBrief? = nil,
        contextTokens: Int? = nil,
        tokens: TokenUsage? = nil,
        model: String? = nil,
        failure: FailureInfo? = nil,
        attempts: Int = 1,
        phase: String? = nil,
        workflow: WorkflowDetails? = nil,
        place: GitPlace? = nil,
        lastActivity: Date? = nil,
        children: [WorkNode] = []
    ) {
        self.id = id
        self.kind = kind
        self.parentId = parentId
        self.title = title
        self.agentType = agentType
        self.state = state
        self.step = step
        self.contextTokens = contextTokens
        self.tokens = tokens
        self.model = model
        self.failure = failure
        self.attempts = attempts
        self.phase = phase
        self.workflow = workflow
        self.place = place
        self.lastActivity = lastActivity
        self.children = children
    }

    /// This node and everything under it.
    public var flattened: [WorkNode] {
        var result: [WorkNode] = []
        var stack = [self]
        while let node = stack.popLast() {
            result.append(node)
            stack.append(contentsOf: node.children.reversed())
        }
        return result
    }
}

public struct WorkSession: Sendable, Equatable, Identifiable {
    public var id: String
    public var environment: WorkEnvironment?
    public var cwd: String?
    public var title: String?
    /// The session's own state combined with everything working under it.
    public var state: WorkState
    public var waitingFor: WaitingReason?
    public var startedAt: Date?
    public var lastActivity: Date?
    public var place: GitPlace?
    public var root: WorkNode

    public init(id: String, environment: WorkEnvironment? = nil, cwd: String? = nil, title: String? = nil, state: WorkState, waitingFor: WaitingReason? = nil, startedAt: Date? = nil, lastActivity: Date? = nil, place: GitPlace? = nil, root: WorkNode) {
        self.id = id
        self.environment = environment
        self.cwd = cwd
        self.title = title
        self.state = state
        self.waitingFor = waitingFor
        self.startedAt = startedAt
        self.lastActivity = lastActivity
        self.place = place
        self.root = root
    }

    /// The project this session belongs to: the main copy for a separate copy, and none for Cowork, whose folder lives inside a virtual machine.
    public var projectPath: String? {
        if environment == .cowork { return nil }
        return place?.mainFolder ?? cwd.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Agents busy right now, whatever started them. A workflow is a script, so it is not one of them.
    public var workingAgents: Int {
        root.flattened.filter { $0.kind != .workflow && ($0.state == .running || $0.state == .silent) }.count
    }
}

/// A folder with its sessions. `path` is nil for sessions without a working folder.
public struct WorkProject: Sendable, Equatable, Identifiable {
    public var id: String { path ?? "" }
    public var path: String?
    public var sessions: [WorkSession]

    public init(path: String?, sessions: [WorkSession]) {
        self.path = path
        self.sessions = sessions
    }

    public var name: String? {
        path.map { URL(fileURLWithPath: $0).lastPathComponent }
    }
}

/// Everything Boris knows about the work at one moment.
public struct WorkModel: Sendable, Equatable {
    public var projects: [WorkProject]

    public init(projects: [WorkProject] = []) {
        self.projects = projects
    }

    public var sessions: [WorkSession] { projects.flatMap(\.sessions) }

    public var waitingSessions: [WorkSession] { sessions.filter { $0.state == .waiting } }

    /// True while anything works, with or without a workflow.
    public var isWorking: Bool { sessions.contains { $0.state.isActive } }

    public var workingAgents: Int { sessions.reduce(0) { $0 + $1.workingAgents } }
}

/// What an action is, whichever source reported it.
public enum WorkAction: String, Sendable, Equatable, CaseIterable {
    case read, write, command, webSearch, webFetch, skill, mcp, startAgent, other

    public init(tool: String) {
        switch tool {
        case "Read", "NotebookRead", "Grep", "Glob", "LS": self = .read
        case "Edit", "MultiEdit", "NotebookEdit", "Write": self = .write
        case "Bash", "BashOutput", "Monitor": self = .command
        case "WebSearch": self = .webSearch
        case "WebFetch": self = .webFetch
        case "Skill": self = .skill
        case "Agent", "Task", "Workflow": self = .startAgent
        case _ where tool.hasPrefix("mcp__"): self = .mcp
        default: self = .other
        }
    }
}

/// One event from any source: who did what, where, and what it cost. Screens know only this.
public struct WorkEvent: Sendable, Equatable, Identifiable {
    public var id: String
    public var at: Date?
    public var environment: WorkEnvironment?
    public var project: String?
    public var sessionId: String
    public var agentId: String?
    public var action: WorkAction
    public var tool: String
    /// A file, an address or a skill. Never the text of a command.
    public var target: String?
    public var state: StepState
    public var durationMs: Int?
    public var added: Int?
    public var removed: Int?
    public var tokens: TokenUsage?

    public init(id: String, at: Date? = nil, environment: WorkEnvironment? = nil, project: String? = nil, sessionId: String, agentId: String? = nil, tool: String, target: String? = nil, state: StepState = .running, durationMs: Int? = nil, added: Int? = nil, removed: Int? = nil, tokens: TokenUsage? = nil) {
        self.id = id
        self.at = at
        self.environment = environment
        self.project = project
        self.sessionId = sessionId
        self.agentId = agentId
        self.action = WorkAction(tool: tool)
        self.tool = tool
        self.target = target
        self.state = state
        self.durationMs = durationMs
        self.added = added
        self.removed = removed
        self.tokens = tokens
    }
}
