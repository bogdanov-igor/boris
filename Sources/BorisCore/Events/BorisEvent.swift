import Foundation

public enum EventKind: String, Codable, Sendable, CaseIterable {
    case completed, completedWithErrors, allAgentsFailed, failed, stopped, interrupted, silent
    case waiting, sessionFinished, limitReached, limitNear, sessionError

    public init?(status: RunStatus) {
        switch status {
        case .completed: self = .completed
        case .completedWithErrors: self = .completedWithErrors
        case .allAgentsFailed: self = .allAgentsFailed
        case .failed: self = .failed
        case .stopped: self = .stopped
        case .interrupted: self = .interrupted
        case .silent: self = .silent
        case .running, .unknown: return nil
        }
    }
}

public struct BorisEvent: Sendable, Equatable, Identifiable {
    public var id: String
    public var kind: EventKind
    public var at: Date
    public var runId: String?
    public var sessionId: String?
    public var name: String?
    public var project: String?
    public var agentsTotal: Int?
    public var agentsFailed: Int?
    public var topFailure: FailureClass?
    public var durationMs: Int?
    public var toolName: String?
    public var limitKind: LimitKind?
    public var resets: String?
    public var affectedRuns: Int?
    public var windowId: String?
    public var percent: Double?
    public var errorType: String?
    public var environment: WorkEnvironment?
    /// Claude waits for words from the person, not for a permission.
    public var asksForAnswer: Bool
    /// Found on the first look after a launch: it happened while Boris was closed.
    public var whileAway: Bool

    public init(
        id: String,
        kind: EventKind,
        at: Date,
        runId: String? = nil,
        sessionId: String? = nil,
        name: String? = nil,
        project: String? = nil,
        agentsTotal: Int? = nil,
        agentsFailed: Int? = nil,
        topFailure: FailureClass? = nil,
        durationMs: Int? = nil,
        toolName: String? = nil,
        limitKind: LimitKind? = nil,
        resets: String? = nil,
        affectedRuns: Int? = nil,
        windowId: String? = nil,
        percent: Double? = nil,
        errorType: String? = nil,
        environment: WorkEnvironment? = nil,
        asksForAnswer: Bool = false,
        whileAway: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.at = at
        self.runId = runId
        self.sessionId = sessionId
        self.name = name
        self.project = project
        self.agentsTotal = agentsTotal
        self.agentsFailed = agentsFailed
        self.topFailure = topFailure
        self.durationMs = durationMs
        self.toolName = toolName
        self.limitKind = limitKind
        self.resets = resets
        self.affectedRuns = affectedRuns
        self.windowId = windowId
        self.percent = percent
        self.errorType = errorType
        self.environment = environment
        self.asksForAnswer = asksForAnswer
        self.whileAway = whileAway
    }

    /// Stopped and interrupted runs can be continued from their session.
    public var canResume: Bool { kind == .stopped || kind == .interrupted }
}
