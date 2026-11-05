import Foundation

/// A limit window from Claude Code's local usage cache.
public struct UsageWindow: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case fiveHour, week
        case weekModel(String)
        case extraSpend
    }

    public var id: String
    public var kind: Kind
    public var percent: Double
    public var resetsAt: Date?
    public var usedDollars: Double?
    public var limitDollars: Double?

    public init(id: String, kind: Kind, percent: Double, resetsAt: Date? = nil, usedDollars: Double? = nil, limitDollars: Double? = nil) {
        self.id = id
        self.kind = kind
        self.percent = percent
        self.resetsAt = resetsAt
        self.usedDollars = usedDollars
        self.limitDollars = limitDollars
    }
}

public struct UsageSnapshot: Sendable, Equatable {
    public var fetchedAt: Date?
    public var windows: [UsageWindow]
    public var extra: ExtraSpend

    public init(fetchedAt: Date? = nil, windows: [UsageWindow] = [], extra: ExtraSpend = .noData) {
        self.fetchedAt = fetchedAt
        self.windows = windows
        self.extra = extra
    }

    /// Age to show, only when the cache is older than half an hour.
    public func staleAge(now: Date) -> TimeInterval? {
        guard let fetchedAt else { return nil }
        let age = now.timeIntervalSince(fetchedAt)
        return age > 30 * 60 ? age : nil
    }
}
