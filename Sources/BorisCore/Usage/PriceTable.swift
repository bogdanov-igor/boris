import Foundation

/// A model's API list prices, in dollars per million tokens.
public struct ModelPrice: Sendable, Equatable {
    public var input, output, cacheRead, cacheWrite: Double

    public func cost(of usage: TokenUsage) -> Double {
        let perToken = (Double(usage.input) * input + Double(usage.output) * output + Double(usage.cacheRead) * cacheRead + Double(usage.cacheWrite) * cacheWrite)
        return perToken / 1_000_000
    }
}

/// The only place that knows prices. Copied by hand from platform.claude.com/docs/en/about-claude/pricing.
/// Cache writes use the 5-minute price, the API's default. Haiku 5.5 uses its price for prompts up to 100,000 tokens,
/// since the price of a longer prompt depends on each request and the logs are added up by day.
public enum PriceTable {
    /// The day the prices below were taken. The page says it, because prices change.
    public static let takenOn = "2026-11-05"

    private static func price(_ input: Double, _ output: Double, read: Double, write: Double) -> ModelPrice {
        ModelPrice(input: input, output: output, cacheRead: read, cacheWrite: write)
    }

    private static let prices: [String: ModelPrice] = [
        "claude-fable-5-1": price(10, 50, read: 0.25, write: 12.5),
        "claude-mythos-5-1": price(10, 50, read: 0.25, write: 12.5),
        "claude-fable-5": price(10, 50, read: 1, write: 12.5),
        "claude-mythos-5": price(10, 50, read: 1, write: 12.5),
        "claude-opus-5-5": price(4, 20, read: 0.2, write: 5),
        "claude-opus-5": price(5, 25, read: 0.5, write: 6.25),
        "claude-opus-4-8": price(5, 25, read: 0.5, write: 6.25),
        "claude-opus-4-7": price(5, 25, read: 0.5, write: 6.25),
        "claude-opus-4-6": price(5, 25, read: 0.5, write: 6.25),
        "claude-opus-4-5": price(5, 25, read: 0.5, write: 6.25),
        "claude-opus-4-1": price(15, 75, read: 1.5, write: 18.75),
        "claude-opus-4": price(15, 75, read: 1.5, write: 18.75),
        "claude-sonnet-5-5": price(2, 10, read: 0.1, write: 2.5),
        "claude-sonnet-5": price(2, 10, read: 0.2, write: 2.5),
        "claude-sonnet-4-6": price(3, 15, read: 0.3, write: 3.75),
        "claude-sonnet-4-5": price(3, 15, read: 0.3, write: 3.75),
        "claude-sonnet-4": price(3, 15, read: 0.3, write: 3.75),
        "claude-haiku-5-5": price(0.1, 0.5, read: 0.01, write: 0.125),
        "claude-haiku-4-5": price(1, 5, read: 0.1, write: 1.25),
        "claude-3-5-haiku": price(0.8, 4, read: 0.08, write: 1),
    ]

    /// Nil for a model with no known price: a guess would look like a number that was measured.
    public static func price(for model: String?) -> ModelPrice? {
        model.flatMap(ModelName.canonical).flatMap { prices[$0] }
    }
}

/// Model ids as the logs write them.
public enum ModelName {
    /// `us.anthropic.claude-opus-4-5-20251101-v1:0` and `claude-opus-4-5[1m]` both mean `claude-opus-4-5`.
    public static func canonical(_ raw: String) -> String? {
        let lowered = raw.lowercased()
        guard let start = lowered.range(of: "claude-") else { return nil }
        var id = String(lowered[start.lowerBound...])
        if let bracket = id.firstIndex(of: "[") { id = String(id[..<bracket]) }
        for ending in ["-v\\d+(:\\d+)?$", "[-@]\\d{8}$"] {
            if let range = id.range(of: ending, options: .regularExpression) { id.removeSubrange(range) }
        }
        return id
    }

    /// `Opus 5.5`, and `Haiku 3.5` from the older `claude-3-5-haiku`. Nil when the id does not read as a Claude model.
    public static func display(_ raw: String) -> String? {
        guard let id = canonical(raw) else { return nil }
        let parts = id.split(separator: "-").dropFirst().map(String.init)
        guard let family = parts.first(where: { $0.allSatisfy(\.isLetter) }) else { return nil }
        let version = parts.filter { $0.allSatisfy(\.isNumber) }
        guard parts.count == version.count + 1 else { return nil }
        let name = family.prefix(1).uppercased() + family.dropFirst()
        return version.isEmpty ? name : "\(name) \(version.joined(separator: "."))"
    }
}
