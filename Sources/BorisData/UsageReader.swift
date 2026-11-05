import Foundation
import BorisCore

/// Reads limit percentages from Claude Code's own cache. No network, no credentials.
public enum UsageReader {
    public struct Profile: Sendable, Equatable {
        public var usage: UsageSnapshot?
        public var account: ClaudeAccount
    }

    public static func read(_ url: URL) -> UsageSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parse(data)
    }

    /// Nil while the file cannot be read: it may be in the middle of a rewrite, which says nothing about the account.
    public static func profile(_ url: URL, settings: URL, managed: ManagedSettings = .system, environment: [String: String] = ProcessInfo.processInfo.environment) -> Profile? {
        guard let data = try? Data(contentsOf: url), let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let usage = parse(root)
        return Profile(usage: usage, account: account(root, usage: usage, settings: settings, managed: managed, environment: environment))
    }

    /// Only whether a sign-in exists is looked at, nothing that is in it. Keys and tokens are never touched.
    private static func account(_ root: [String: Any], usage: UsageSnapshot?, settings: URL, managed: ManagedSettings, environment: [String: String]) -> ClaudeAccount {
        if environment["ANTHROPIC_BASE_URL"]?.isEmpty == false || settingsSetGateway(settings) || managed.setsGateway { return .gateway }
        if let signIn = root["oauthAccount"] as? [String: Any], !signIn.isEmpty { return .signedIn }
        return usage == nil ? .apiKey : .signedIn
    }

    private static func settingsSetGateway(_ settings: URL) -> Bool {
        guard let data = try? Data(contentsOf: settings), let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return (root["env"] as? [String: Any])?["ANTHROPIC_BASE_URL"] != nil
    }

    static func parse(_ data: Data) -> UsageSnapshot? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any]).flatMap { parse($0) }
    }

    /// Only `cachedUsageUtilization` is used. The account id next to it is dropped here.
    private static func parse(_ root: [String: Any]) -> UsageSnapshot? {
        guard let cache = root["cachedUsageUtilization"] as? [String: Any],
              let utilization = cache["utilization"] as? [String: Any]
        else { return nil }
        let fetched = (cache["fetchedAtMs"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }

        var windows: [UsageWindow] = []
        for (id, kind) in [("five_hour", UsageWindow.Kind.fiveHour), ("seven_day", .week), ("seven_day_opus", .weekModel("Opus")), ("seven_day_sonnet", .weekModel("Sonnet"))] {
            if let entry = utilization[id] as? [String: Any], let percent = (entry["utilization"] as? NSNumber)?.doubleValue {
                windows.append(UsageWindow(id: id, kind: kind, percent: percent, resetsAt: date(entry["resets_at"] as? String)))
            }
        }
        windows += modelWindows(utilization["limits"] as? [[String: Any]] ?? [], known: windows)
        if let extra = extraSpend(utilization["extra_usage"] as? [String: Any]) {
            windows.append(extra)
        }
        // Other records have changing code names. Some hold dollars too, but what they mean is unknown.
        windows.sort { rank($0.kind) < rank($1.kind) }
        return UsageSnapshot(fetchedAt: fetched, windows: windows, extra: extra(utilization["extra_usage"] as? [String: Any]))
    }

    /// Money is shown only when its scale is known: ten times too much is worse than no number.
    private static func extra(_ extra: [String: Any]?) -> ExtraSpend {
        guard let extra, let enabled = extra["is_enabled"] as? Bool else { return .noData }
        guard enabled else { return .off }
        guard let used = (extra["used_credits"] as? NSNumber)?.doubleValue,
              let places = (extra["decimal_places"] as? NSNumber)?.doubleValue
        else { return .noData }
        let scale = pow(10, places)
        let limit = (extra["monthly_limit"] as? NSNumber)?.doubleValue ?? 0
        let currency = (extra["currency"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "USD"
        return .on(used: used / scale, limit: limit > 0 ? limit / scale : nil, currency: currency)
    }

    private static func modelWindows(_ limits: [[String: Any]], known: [UsageWindow]) -> [UsageWindow] {
        limits.compactMap { limit in
            guard limit["kind"] as? String == "weekly_scoped",
                  let scope = limit["scope"] as? [String: Any],
                  let model = (scope["model"] as? [String: Any])?["display_name"] as? String,
                  let percent = (limit["percent"] as? NSNumber)?.doubleValue,
                  limit["is_active"] as? Bool == true || percent > 0,
                  !known.contains(where: { $0.kind == .weekModel(model) })
            else { return nil }
            return UsageWindow(id: "weekly_scoped:\(model)", kind: .weekModel(model), percent: percent, resetsAt: date(limit["resets_at"] as? String))
        }
    }

    private static func extraSpend(_ extra: [String: Any]?) -> UsageWindow? {
        guard let extra, extra["is_enabled"] as? Bool == true,
              let limit = (extra["monthly_limit"] as? NSNumber)?.doubleValue, limit > 0,
              let used = (extra["used_credits"] as? NSNumber)?.doubleValue
        else { return nil }
        let scale = pow(10, (extra["decimal_places"] as? NSNumber)?.doubleValue ?? 0)
        return UsageWindow(id: "extra_usage", kind: .extraSpend, percent: used / limit * 100, usedDollars: used / scale, limitDollars: limit / scale)
    }

    private static func rank(_ kind: UsageWindow.Kind) -> Int {
        switch kind {
        case .fiveHour: return 0
        case .week: return 1
        case .weekModel: return 2
        case .extraSpend: return 3
        }
    }

    /// `resets_at` has six fractional digits, which the standard ISO 8601 formatter rejects.
    static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        let cleaned = text.replacingOccurrences(of: "\\.\\d+", with: "", options: .regularExpression)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: cleaned)
    }
}
