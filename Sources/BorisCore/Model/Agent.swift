import Foundation

/// One line of a run's journal, without the agent's result text.
public struct JournalEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case launched, started, result, failed
        case unknown(String)
    }

    public var kind: Kind
    public var key: String?
    public var agentId: String?
    public var label: String?
    public var phase: String?
    public var toolsUsed: [String]?

    public init(kind: Kind, key: String? = nil, agentId: String? = nil, label: String? = nil, phase: String? = nil, toolsUsed: [String]? = nil) {
        self.kind = kind
        self.key = key
        self.agentId = agentId
        self.label = label
        self.phase = phase
        self.toolsUsed = toolsUsed
    }
}

public enum AgentState: String, Codable, Sendable, Equatable {
    case running, done, failed
    /// Was still at work when its run ended.
    case cancelled
}

public struct AgentRecord: Sendable, Equatable, Identifiable {
    public var id: String { key }
    public var key: String
    public var agentId: String?
    public var label: String?
    public var phase: String?
    public var state: AgentState
    public var attempts: Int
    public var failure: FailureInfo?
    public var contextTokens: Int?
    public var model: String?
    public var durationMs: Int?
    public var toolCalls: Int?
    public var lastToolName: String?
    public var toolsUsed: [String]?
    /// Tool running right now, known only in hook mode.
    public var currentTool: String?
    /// What the agent is doing now, from the end of its transcript.
    public var currentStep: StepBrief?
    /// The agent that started this one, when it was not the session.
    public var parentAgentId: String?
    /// The kind of agent it was started as, such as `scout`. Empty for the general kinds.
    public var agentType: String?
    /// The ids of its earlier attempts. Each wrote a file of its own, and what they spent is this agent's too.
    public var earlierAgentIds: [String] = []

    public init(
        key: String,
        agentId: String? = nil,
        label: String? = nil,
        phase: String? = nil,
        state: AgentState = .running,
        attempts: Int = 1,
        failure: FailureInfo? = nil,
        contextTokens: Int? = nil,
        model: String? = nil,
        durationMs: Int? = nil,
        toolCalls: Int? = nil,
        lastToolName: String? = nil,
        toolsUsed: [String]? = nil,
        currentTool: String? = nil
    ) {
        self.key = key
        self.agentId = agentId
        self.label = label
        self.phase = phase
        self.state = state
        self.attempts = attempts
        self.failure = failure
        self.contextTokens = contextTokens
        self.model = model
        self.durationMs = durationMs
        self.toolCalls = toolCalls
        self.lastToolName = lastToolName
        self.toolsUsed = toolsUsed
        self.currentTool = currentTool
    }
}

/// Folds journal events by `key`: the last event of a key decides its state, repeated starts count as attempts.
public struct AgentTally: Sendable, Equatable {
    private var order: [String] = []
    private var records: [String: AgentRecord] = [:]
    public private(set) var unknownEvents: Set<String> = []

    public init() {}

    public mutating func add(_ event: JournalEvent) {
        if case .unknown(let name) = event.kind {
            unknownEvents.insert(name)
            return
        }
        guard let key = event.key else { return }
        var record = records[key] ?? AgentRecord(key: key, attempts: 0)
        if records[key] == nil { order.append(key) }
        if let agentId = event.agentId {
            if let earlier = record.agentId, earlier != agentId, !earlier.isEmpty {
                record.earlierAgentIds.removeAll { $0 == earlier || $0 == agentId }
                record.earlierAgentIds.append(earlier)
            }
            record.agentId = agentId
        }
        if let label = event.label { record.label = label }
        if let phase = event.phase { record.phase = phase }
        switch event.kind {
        case .started:
            record.state = .running
            record.attempts += 1
        case .result:
            record.state = .done
            if let tools = event.toolsUsed { record.toolsUsed = tools }
        case .failed:
            record.state = .failed
        case .launched, .unknown:
            break
        }
        records[key] = record
    }

    public var agents: [AgentRecord] {
        order.compactMap { key in
            guard var record = records[key] else { return nil }
            record.attempts = max(record.attempts, 1)
            return record
        }
    }
}

/// The result of a whole run, from its final file.
public struct FinalReport: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public var agentId: String?
        public var label: String?
        public var phaseTitle: String?
        public var phaseIndex: Int?
        public var state: String?
        public var tokens: Int?
        public var toolCalls: Int?
        public var durationMs: Int?
        public var model: String?
        public var attempt: Int?
        public var error: String?
        public var lastAttemptReason: String?
        public var lastToolName: String?

        public init(
            agentId: String? = nil,
            label: String? = nil,
            phaseTitle: String? = nil,
            phaseIndex: Int? = nil,
            state: String? = nil,
            tokens: Int? = nil,
            toolCalls: Int? = nil,
            durationMs: Int? = nil,
            model: String? = nil,
            attempt: Int? = nil,
            error: String? = nil,
            lastAttemptReason: String? = nil,
            lastToolName: String? = nil
        ) {
            self.agentId = agentId
            self.label = label
            self.phaseTitle = phaseTitle
            self.phaseIndex = phaseIndex
            self.state = state
            self.tokens = tokens
            self.toolCalls = toolCalls
            self.durationMs = durationMs
            self.model = model
            self.attempt = attempt
            self.error = error
            self.lastAttemptReason = lastAttemptReason
            self.lastToolName = lastToolName
        }
    }

    public var status: String
    public var workflowName: String?
    public var agentCount: Int?
    public var durationMs: Int?
    public var totalTokens: Int?
    public var errorFirstLine: String?
    public var startTime: Date?
    public var taskId: String?
    public var phaseTitles: [String]
    public var entries: [Entry]

    public init(
        status: String,
        workflowName: String? = nil,
        agentCount: Int? = nil,
        durationMs: Int? = nil,
        totalTokens: Int? = nil,
        errorFirstLine: String? = nil,
        startTime: Date? = nil,
        taskId: String? = nil,
        phaseTitles: [String] = [],
        entries: [Entry] = []
    ) {
        self.status = status
        self.workflowName = workflowName
        self.agentCount = agentCount
        self.durationMs = durationMs
        self.totalTokens = totalTokens
        self.errorFirstLine = errorFirstLine
        self.startTime = startTime
        self.taskId = taskId
        self.phaseTitles = phaseTitles
        self.entries = entries
    }
}

public extension FinalReport.Entry {
    /// The agent as the final file describes it. This wins over the journal once a run has a result.
    var record: AgentRecord {
        let isError = state == "error"
        let failure: FailureInfo? = isError ? FailureClassifier.classify(nil, reason: error ?? lastAttemptReason) : nil
        return AgentRecord(
            key: agentId ?? label ?? UUID().uuidString,
            agentId: agentId,
            label: label,
            phase: phaseTitle,
            state: isError ? .failed : (state == "progress" ? .running : .done),
            attempts: max(attempt ?? 1, 1),
            failure: failure,
            contextTokens: tokens,
            model: model,
            durationMs: durationMs,
            toolCalls: toolCalls,
            lastToolName: lastToolName
        )
    }
}
