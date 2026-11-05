import Foundation

/// How Claude Code signs in, only as far as it changes what can be shown. Personal, Team and Enterprise plans need no difference:
/// each shows the windows Claude reports for it.
public enum ClaudeAccount: Sendable, Equatable {
    /// Claude's profile could not be read, so nothing is known.
    case unknown
    case signedIn
    /// A key of its own, or a cloud platform: there are no plan limits.
    case apiKey
    /// A company's gateway stands between Claude Code and the API.
    case gateway
}

/// Real money spent beyond the plan.
public enum ExtraSpend: Sendable, Equatable {
    case noData
    case off
    /// - Parameter limit: nil when no monthly limit is set.
    case on(used: Double, limit: Double?, currency: String)
}

/// What the limits block shows.
public enum LimitsCard: Sendable, Equatable {
    case hidden
    case windows([UsageWindow])
    /// Claude told nothing, which is not the same as nothing being used.
    case noData
}

/// What the block of real extra spend shows.
public enum ExtraCard: Sendable, Equatable {
    case hidden
    case spent(used: Double, limit: Double?, currency: String)
    case off
    case noData
}

/// Decides what can be shown for an account: only what was found, and an honest gap for the rest.
public enum UsageCards {
    public static func limits(usage: UsageSnapshot?, account: ClaudeAccount) -> LimitsCard {
        let windows = usage?.windows.filter { $0.kind != .extraSpend } ?? []
        if !windows.isEmpty { return .windows(windows) }
        return account == .apiKey ? .hidden : .noData
    }

    public static func extra(usage: UsageSnapshot?, account: ClaudeAccount) -> ExtraCard {
        switch usage?.extra ?? .noData {
        case .on(let used, let limit, let currency):
            return .spent(used: used, limit: limit, currency: currency)
        case .off:
            return .off
        case .noData:
            // Paying beyond a plan is something only a plan has.
            return account == .apiKey || account == .gateway ? .hidden : .noData
        }
    }
}
