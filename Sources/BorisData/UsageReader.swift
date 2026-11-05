import Foundation
import BorisCore

/// Reads limit percentages from Claude Code's own cache. No network, no credentials.
public enum UsageReader {
    public static func read(_ url: URL) -> UsageSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parse(data)
    }

    /// Only `cachedUsageUtilization` is used. The account id next to it is dropped here.
    static func parse(_ data: Data) -> UsageSnapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cache = root["cachedUsageUtilization"] as? [String: Any],
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
        return UsageSnapshot(fetchedAt: fetched, windows: windows)
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
