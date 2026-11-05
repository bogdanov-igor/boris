import Foundation

/// Numbers for one day. No names, projects or text ever land here.
public struct DayStats: Codable, Sendable, Equatable {
    public var runs: [String: Int]
    public var agents: Int
    public var failures: [String: Int]
    public var limitHits: Int
    public var tokens: TokenUsage
    public var watchSeconds: TimeInterval
    public var silentDeaths: Int

    public init(runs: [String: Int] = [:], agents: Int = 0, failures: [String: Int] = [:], limitHits: Int = 0, tokens: TokenUsage = TokenUsage(), watchSeconds: TimeInterval = 0, silentDeaths: Int = 0) {
        self.runs = runs
        self.agents = agents
        self.failures = failures
        self.limitHits = limitHits
        self.tokens = tokens
        self.watchSeconds = watchSeconds
        self.silentDeaths = silentDeaths
    }

    public var runCount: Int { runs.values.reduce(0, +) }

    public static func + (a: DayStats, b: DayStats) -> DayStats {
        DayStats(
            runs: a.runs.merging(b.runs, uniquingKeysWith: +),
            agents: a.agents + b.agents,
            failures: a.failures.merging(b.failures, uniquingKeysWith: +),
            limitHits: a.limitHits + b.limitHits,
            tokens: a.tokens + b.tokens,
            watchSeconds: a.watchSeconds + b.watchSeconds,
            silentDeaths: a.silentDeaths + b.silentDeaths
        )
    }
}

public struct StatsBook: Codable, Sendable, Equatable {
    public static let keepDays = 400

    public var days: [String: DayStats]
    /// Attempts already counted in this launch. Never saved: this file holds dates and numbers only,
    /// and across launches each attempt reaches here once anyway, because events are not repeated.
    public var counted: Set<String>
    public var tokensSince: Date?

    private enum CodingKeys: String, CodingKey {
        case days, tokensSince
    }

    public init(days: [String: DayStats] = [:], counted: Set<String> = [], tokensSince: Date? = nil) {
        self.days = days
        self.counted = counted
        self.tokensSince = tokensSince
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        days = try container.decode([String: DayStats].self, forKey: .days)
        tokensSince = try container.decodeIfPresent(Date.self, forKey: .tokensSince)
        counted = []
    }

    public static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Counts a finished attempt on the day it ended. Returns false if it was already counted.
    @discardableResult
    public mutating func record(_ run: RunState, at date: Date, calendar: Calendar = .current) -> Bool {
        guard run.status.isTerminal else { return false }
        let key = "\(run.runId)|\(run.attempt)"
        guard counted.insert(key).inserted else { return false }
        let day = Self.dayKey(date, calendar: calendar)
        var stats = days[day] ?? DayStats()
        stats.runs[run.status.key, default: 0] += 1
        stats.agents += run.total
        for agent in run.agents where agent.state == .failed {
            stats.failures[(agent.failure?.failureClass ?? .unknown).rawValue, default: 0] += 1
        }
        if run.status == .interrupted { stats.silentDeaths += 1 }
        days[day] = stats
        return true
    }

    public mutating func addTokens(_ usage: TokenUsage, at date: Date, calendar: Calendar = .current) {
        let key = Self.dayKey(date, calendar: calendar)
        days[key, default: DayStats()].tokens = days[key, default: DayStats()].tokens + usage
    }

    public mutating func addLimitHit(at date: Date, calendar: Calendar = .current) {
        days[Self.dayKey(date, calendar: calendar), default: DayStats()].limitHits += 1
    }

    public mutating func addWatchTime(_ seconds: TimeInterval, at date: Date, calendar: Calendar = .current) {
        days[Self.dayKey(date, calendar: calendar), default: DayStats()].watchSeconds += seconds
    }

    /// Sum of the last `count` days including today.
    public func total(lastDays count: Int, now: Date, calendar: Calendar = .current) -> DayStats {
        var result = DayStats()
        for offset in 0..<max(count, 1) {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: now), let day = days[Self.dayKey(date, calendar: calendar)] else { continue }
            result = result + day
        }
        return result
    }

    public mutating func prune(now: Date, calendar: Calendar = .current) {
        guard let cutoff = calendar.date(byAdding: .day, value: -Self.keepDays, to: now) else { return }
        let key = Self.dayKey(cutoff, calendar: calendar)
        days = days.filter { $0.key >= key }
        if counted.count > 5000 { counted = [] }
    }

    public mutating func reset() {
        days = [:]
        counted = []
    }
}
