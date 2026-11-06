import Foundation

/// What one transcript spent on one day with one model.
public struct TokenRecord: Sendable, Equatable {
    public var sessionId: String
    /// Nil for the main agent's own transcript.
    public var agentId: String?
    public var runId: String?
    public var cwd: String?
    public var entrypoint: String?
    public var day: String
    public var model: String?
    public var usage: TokenUsage
    /// The remote machine it was spent on. Nil on this Mac.
    public var host: String?

    public init(sessionId: String, agentId: String? = nil, runId: String? = nil, cwd: String? = nil, entrypoint: String? = nil, day: String, model: String? = nil, usage: TokenUsage, host: String? = nil) {
        self.sessionId = sessionId
        self.agentId = agentId
        self.runId = runId
        self.cwd = cwd
        self.entrypoint = entrypoint
        self.day = day
        self.model = model
        self.usage = usage
        self.host = host
    }
}
