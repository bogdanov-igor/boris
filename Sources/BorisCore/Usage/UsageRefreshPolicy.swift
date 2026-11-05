import Foundation

/// When the limits should be fetched again by themselves.
public enum UsageRefreshPolicy {
    public static let intervals = [5, 15, 30, 60]

    public static func isDue(now: Date, enabled: Bool, intervalMinutes: Int, liveSessions: Int, account: ClaudeAccount, fetchedAt: Date?, lastAttempt: Date?) -> Bool {
        // Without a plan there are no limits to fetch, and starting Claude Code would be for nothing.
        guard enabled, liveSessions > 0, account != .apiKey, account != .gateway else { return false }
        let interval = TimeInterval(intervalMinutes) * 60
        if let fetchedAt, now.timeIntervalSince(fetchedAt) < interval { return false }
        // A failed attempt is not repeated at every scan.
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < interval { return false }
        return true
    }
}
