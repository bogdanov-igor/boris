import Foundation
import BorisCore

public struct AgentDetail: Sendable, Equatable {
    public var prompt: String?
    public var result: String?
    public var tokens: TokenUsage
    public var tools: [String: Int]
    public var model: String?
    public var messages: Int
    public var errorText: String?

    public init(prompt: String? = nil, result: String? = nil, tokens: TokenUsage = TokenUsage(), tools: [String: Int] = [:], model: String? = nil, messages: Int = 0, errorText: String? = nil) {
        self.prompt = prompt
        self.result = result
        self.tokens = tokens
        self.tools = tools
        self.model = model
        self.messages = messages
        self.errorText = errorText
    }
}

public enum AgentDetailReader {
    /// Longest text kept for the screen. A full transcript can be tens of megabytes.
    public static let textLimit = 512 * 1024

    public static func read(runDir: URL, key: String, agentId: String?) -> AgentDetail {
        var detail = AgentDetail()
        detail.result = JournalReader.result(in: runDir.appendingPathComponent("journal.jsonl"), key: key).map(trim)
        guard let agentId else { return detail }
        let file = runDir.appendingPathComponent("agent-\(agentId).jsonl")
        detail.prompt = TranscriptReader.firstPrompt(file).map(trim)
        let summary = TranscriptReader.summary(file)
        detail.tokens = summary.tokens
        detail.tools = summary.tools
        detail.model = summary.model
        detail.messages = summary.messages
        let tail = TranscriptReader.tail(file)
        if tail.last?.isApiError == true { detail.errorText = tail.last?.text }
        return detail
    }

    /// Real spend of every agent in a run, for statistics.
    /// `onlyAgent` is for an ordinary agent, whose folder also holds the other agents of its session.
    public static func runTokens(runDir: URL, onlyAgent: String? = nil) -> TokenUsage {
        if let onlyAgent {
            return TranscriptReader.summary(runDir.appendingPathComponent("agent-\(onlyAgent).jsonl")).tokens
        }
        var total = TokenUsage()
        for name in FileInfo.names(in: runDir) where name.hasPrefix("agent-") && name.hasSuffix(".jsonl") {
            total = total + TranscriptReader.summary(runDir.appendingPathComponent(name)).tokens
        }
        return total
    }

    private static func trim(_ text: String) -> String {
        text.utf8.count <= textLimit ? text : String(decoding: text.utf8.prefix(textLimit), as: UTF8.self) + "\n…"
    }
}
