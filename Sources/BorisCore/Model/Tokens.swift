import Foundation

public struct TokenUsage: Codable, Sendable, Equatable {
    public var input: Int
    public var output: Int
    public var cacheRead: Int
    public var cacheWrite: Int

    public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }

    /// Context size as Claude Code reports it: everything sent in, without the reply.
    public var context: Int { input + cacheRead + cacheWrite }
    public var total: Int { input + output + cacheRead + cacheWrite }

    public static func + (a: TokenUsage, b: TokenUsage) -> TokenUsage {
        TokenUsage(input: a.input + b.input, output: a.output + b.output, cacheRead: a.cacheRead + b.cacheRead, cacheWrite: a.cacheWrite + b.cacheWrite)
    }

    /// What was added since `previous`. A resumed run's transcripts also hold its earlier attempts.
    public func growth(since previous: TokenUsage) -> TokenUsage {
        TokenUsage(input: max(input - previous.input, 0), output: max(output - previous.output, 0), cacheRead: max(cacheRead - previous.cacheRead, 0), cacheWrite: max(cacheWrite - previous.cacheWrite, 0))
    }
}

/// Real spend: transcripts repeat a message per content block, so only the last record of each `message.id` counts.
public struct TokenLedger: Sendable, Equatable {
    private var byMessage: [String: TokenUsage] = [:]
    private var anonymous = TokenUsage()

    public init() {}

    public mutating func add(messageId: String?, usage: TokenUsage) {
        if let messageId {
            byMessage[messageId] = usage
        } else {
            anonymous = anonymous + usage
        }
    }

    public var total: TokenUsage {
        byMessage.values.reduce(anonymous, +)
    }
}
