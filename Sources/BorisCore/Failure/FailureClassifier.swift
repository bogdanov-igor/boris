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
        let rest = text[range.upperBound...].trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? nil : rest
    }
}
