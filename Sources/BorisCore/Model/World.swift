import Foundation

/// Everything read from disk about one run, before any judgement.
public struct RunSnapshot: Sendable, Equatable, Identifiable {
    public var id: String { runId }
    public var runId: String
    public var sessionId: String
    public var cwd: String?
    public var scriptName: String?
    /// One-line summary from the script's `meta.description`.
    public var description: String?
    public var plannedPhases: [String]
    public var lastWrite: Date
    public var journalModified: Date?
    public var final: FinalReport?
    public var finalModified: Date?
    public var agents: [AgentRecord]
    /// True when the parent transcript has a `TaskStop` call naming this run.
    public var stoppedByClaude: Bool
    public var startedAt: Date?
    /// What started its session, from the transcript. It outlives the session.
    public var entrypoint: String?

    public init(
        runId: String,
        sessionId: String,
        cwd: String? = nil,
        scriptName: String? = nil,
        description: String? = nil,
        plannedPhases: [String] = [],
        lastWrite: Date,
        journalModified: Date? = nil,
        final: FinalReport? = nil,
        finalModified: Date? = nil,
        agents: [AgentRecord] = [],
        stoppedByClaude: Bool = false
    ) {
        self.runId = runId
        self.sessionId = sessionId
        self.cwd = cwd
        self.scriptName = scriptName
        self.description = description
        self.plannedPhases = plannedPhases
        self.lastWrite = lastWrite
        self.journalModified = journalModified
        self.final = final
        self.finalModified = finalModified
        self.agents = agents
        self.stoppedByClaude = stoppedByClaude
    }
}

/// An agent started with the `Agent` tool, outside any workflow.
public struct AgentSnapshot: Sendable, Equatable, Identifiable {
    public var id: String
    public var sessionId: String
    /// The agent that started this one, when it was not the main agent.
    public var parentAgentId: String?
    public var description: String?
    /// The kind of agent it was started as, such as `scout`. Empty for the general kinds.
    public var agentType: String?
    public var isFork: Bool
    public var state: AgentState
    public var failure: FailureInfo?
    public var contextTokens: Int?
    public var model: String?
    public var currentStep: StepBrief?
    public var cwd: String?
    public var entrypoint: String?
    public var startedAt: Date?
    public var lastWrite: Date

    public init(
        id: String,
        sessionId: String,
        parentAgentId: String? = nil,
        description: String? = nil,
        agentType: String? = nil,
        isFork: Bool = false,
        state: AgentState = .running,
        failure: FailureInfo? = nil,
        contextTokens: Int? = nil,
        model: String? = nil,
        currentStep: StepBrief? = nil,
        cwd: String? = nil,
        entrypoint: String? = nil,
        startedAt: Date? = nil,
        lastWrite: Date
    ) {
        self.id = id
        self.sessionId = sessionId
        self.parentAgentId = parentAgentId
        self.description = description
        self.agentType = agentType
        self.isFork = isFork
        self.state = state
        self.failure = failure
        self.contextTokens = contextTokens
        self.model = model
        self.currentStep = currentStep
        self.cwd = cwd
        self.entrypoint = entrypoint
        self.startedAt = startedAt
        self.lastWrite = lastWrite
    }

    public var environment: WorkEnvironment? { WorkEnvironment(entrypoint: entrypoint, unlisted: false) }
}

public enum FormatIssue: Sendable, Equatable, Hashable {
    case unknownJournalEvent(String)
    case unreadableFinal(runId: String)
    case unreadableSessions
}

public struct WorldSnapshot: Sendable, Equatable {
    public var takenAt: Date
    /// Sessions whose process is running now.
    public var sessions: [SessionInfo]
    /// Sessions whose process vanished and left its file behind, as `kill -9` does.
    public var endedSessions: [SessionInfo] = []
    public var runs: [RunSnapshot]
    /// Ordinary agents, outside workflows.
    public var agents: [AgentSnapshot] = []
    public var usage: UsageSnapshot?
    public var account = ClaudeAccount.unknown
    public var claudeFolderFound: Bool
    public var formatIssues: Set<FormatIssue>
    /// What ordinary sessions spent since the previous scan.
    public var sessionTokenGrowth = TokenUsage()
    /// What each running run has spent so far.
    public var runTokens: [String: TokenUsage] = [:]
    /// What each running ordinary agent has spent so far.
    public var agentTokens: [String: TokenUsage] = [:]
    /// Where sessions and agents work in git, by their id.
    public var places: [String: GitPlace] = [:]
    /// Running sessions left out because their source is off. Only these numbers are known about them.
    public var hiddenSessions: [String: Int32] = [:]

    public init(
        takenAt: Date,
        sessions: [SessionInfo] = [],
        runs: [RunSnapshot] = [],
        usage: UsageSnapshot? = nil,
        claudeFolderFound: Bool = true,
        formatIssues: Set<FormatIssue> = []
    ) {
        self.takenAt = takenAt
        self.sessions = sessions
        self.runs = runs
        self.usage = usage
        self.claudeFolderFound = claudeFolderFound
        self.formatIssues = formatIssues
    }
}
