import Foundation

/// When the limits should be fetched again by themselves.
public enum UsageRefreshPolicy {
    public static let intervals = [5, 15, 30, 60]

    /// - Parameter macAwake: false from the Mac going to sleep until it wakes for the person. With the lid closed it still wakes
    ///   by itself for a few seconds every few minutes, and the app runs then, but such a wake is often over before Claude Code is.
    public static func isDue(now: Date, enabled: Bool, macAwake: Bool, intervalMinutes: Int, liveSessions: Int, account: ClaudeAccount, fetchedAt: Date?, lastAttempt: Date?) -> Bool {
        // Without a plan there are no limits to fetch, and starting Claude Code would be for nothing.
        guard enabled, macAwake, liveSessions > 0, account != .apiKey, account != .gateway else { return false }
        let interval = TimeInterval(intervalMinutes) * 60
        if let fetchedAt, now.timeIntervalSince(fetchedAt) < interval { return false }
        // A failed attempt is not repeated at every scan.
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < interval { return false }
        return true
    }
}
