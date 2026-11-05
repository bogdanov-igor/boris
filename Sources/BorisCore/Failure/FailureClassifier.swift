import Foundation

public enum FailureClass: String, Codable, Sendable, Equatable, CaseIterable {
    case limit, network, sleep, stall, api, unknown
}

public enum LimitKind: String, Codable, Sendable, Equatable {
    case session, monthly, other
}

public struct FailureInfo: Sendable, Equatable {
    public var failureClass: FailureClass
    public var limitKind: LimitKind?
    /// Reset time exactly as Claude Code wrote it, for example `1:30pm (Europe/London)`.
    public var resets: String?
    public var text: String?

    public init(failureClass: FailureClass, limitKind: LimitKind? = nil, resets: String? = nil, text: String? = nil) {
        self.failureClass = failureClass
        self.limitKind = limitKind
        self.resets = resets
        self.text = text
    }
}

/// The last record of a failed agent's transcript, reduced to what matters.
public struct LastRecord: Sendable, Equatable {
    public var isApiError: Bool
    public var errorCode: String?
    public var text: String?

    public init(isApiError: Bool, errorCode: String? = nil, text: String? = nil) {
        self.isApiError = isApiError
        self.errorCode = errorCode
        self.text = text
    }
}

public enum FailureClassifier {
    public static func classify(_ record: LastRecord?, reason: String? = nil) -> FailureInfo {
        let text = record?.text ?? reason
        let lower = text?.lowercased() ?? ""
        let code = record?.errorCode

        if code == "rate_limit" || (lower.contains("hit your") && lower.contains("limit")) {
            return FailureInfo(failureClass: .limit, limitKind: limitKind(lower), resets: resets(from: text), text: text)
        }
        // Sleep errors also carry server_error, so sleep is checked before network.
        if lower.contains("went to sleep") || lower.contains("was asleep") {
            return FailureInfo(failureClass: .sleep, text: text)
        }
        if code == "server_error" || ["can't reach", "timed out", "connection", "econnreset", "enotfound"].contains(where: lower.contains) {
            return FailureInfo(failureClass: .network, text: text)
        }
        if lower.contains("no progress") || lower.contains("stalled") {
            return FailureInfo(failureClass: .stall, text: text)
        }
        if record?.isApiError == true {
            return FailureInfo(failureClass: .api, text: text)
        }
        return FailureInfo(failureClass: .unknown, text: text)
    }

    private static func limitKind(_ lower: String) -> LimitKind {
        if lower.contains("session limit") { return .session }
        if lower.contains("monthly") { return .monthly }
        return .other
    }

    private static func resets(from text: String?) -> String? {
        guard let text, let range = text.range(of: "resets ") else { return nil }
        return resetTime(String(text[range.upperBound...]))
    }

    /// `4:10pm`, `18:40`, `Nov 8, 5pm (Europe/Moscow)`, `tomorrow at 5pm`.
    private static let resetTimePattern = #"^(?:(?:(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.? \d{1,2},?|(?:today|tomorrow|mon|tue|wed|thu|fri|sat|sun)[a-z]*,?)(?: at)? )?\d{1,2}(?::\d{2})?(?: ?[ap]m)?(?: \([a-z_]+(?:/[a-z0-9_+-]+)*\))?$"#

    /// The time at the start of what follows the word "resets". That text comes from the end of a transcript,
    /// so it can be anything an agent wrote, and only a time may go on to the state file or a notification.
    public static func resetTime(_ text: String) -> String? {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let time = line.components(separatedBy: " · ")[0].trimmingCharacters(in: .whitespaces)
        return time.range(of: resetTimePattern, options: [.regularExpression, .caseInsensitive]) == nil ? nil : time
    }
}
