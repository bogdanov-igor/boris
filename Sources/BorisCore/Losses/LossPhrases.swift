import Foundation

/// The words for failures. The simple mode gets plain causes and what to do, without names of tools or error codes.
public enum LossPhrases {
    public static func kind(_ kind: LossKind) -> String {
        switch kind {
        case .crash: return L("Crash")
        case .apiError: return L("API error")
        case .toolError: return L("Tool error")
        case .retry: return L("Retry")
        case .cut: return L("Response cut")
        case .denied: return L("Refused")
        }
    }

    /// A little longer than `kind`, for the summary by types.
    public static func kindInFull(_ kind: LossKind) -> String {
        switch kind {
        case .crash: return L("Agent crash")
        case .denied: return L("Permission denied")
        case .apiError, .toolError, .retry, .cut: return LossPhrases.kind(kind)
        }
    }

    public static func reason(_ reason: LossReason, mode: DisplayMode) -> String {
        guard mode == .technical else { return PhraseBook.reasonTitle(reason) }
        switch reason {
        case .limit: return L("Limit")
        case .network: return L("Network")
        case .stall: return L("Stall")
        case .api: return L("API error")
        case .sleep: return L("Mac sleep")
        case .script: return L("Script error")
        case .closed: return L("Claude Code closed")
        case .unknown: return L("Unknown")
        }
    }

    /// What is said next to a failure in the simple mode: the cause and what to do about it.
    public static func advice(_ entry: LossEntry) -> String {
        switch entry.kind {
        case .toolError: return L("A step did not work, Claude usually copes with that on its own")
        case .denied: return L("You or a rule did not allow a step")
        case .retry: return L("Claude had to ask again")
        case .crash, .apiError, .cut: break
        }
        return PhraseBook.advice(reason: entry.reason ?? .unknown, problem: entry.problem, resets: resetsText(entry))
    }

    /// The text of a row in the technical mode.
    public static func detail(_ entry: LossEntry) -> String {
        switch entry.kind {
        case .crash:
            let cause = cause(entry)
            guard let total = entry.total, total > 1 else { return cause }
            let share = entry.count == total ? L("all %lld failed", total) : L("%lld of %lld agents failed", entry.count, total)
            return "\(share) · \(cause)"
        case .apiError, .cut:
            return cause(entry)
        case .toolError:
            return named(entry.tool, toolFailure(entry))
        case .retry:
            switch entry.recovered {
            case true?: return L("%@, it worked", retryCause(entry))
            case false?: return L("%@, it did not help", retryCause(entry))
            case nil: return retryCause(entry)
            }
        case .denied:
            return denial(entry)
        }
    }

    /// Each skill with its exact number of calls, one to a line, for those that a short list has no room for.
    public static func skillCounts(_ skills: some Sequence<LossBook.SkillCount>) -> String {
        skills.map { "\($0.name ?? L("Unnamed skill")) \($0.calls)" }.joined(separator: "\n")
    }

    /// `≈ 1,2 млн`: a number that says it is not exact.
    public static func estimate(_ tokens: Int) -> String {
        "≈ \(WorkFormat.tokens(tokens))"
    }

    /// The date of a row: today by the hour, earlier days with the day too.
    public static func when(_ date: Date, now: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        if calendar.isDate(date, inSameDayAs: now) { return WorkFormat.time(date, timeZone: timeZone) }
        let formatter = DateFormatter()
        formatter.locale = Localizer.locale
        formatter.timeZone = timeZone
        formatter.dateFormat = Localizer.locale.identifier == "ru" ? "dd.MM HH:mm" : "MMM d HH:mm"
        return formatter.string(from: date)
    }

    private static func cause(_ entry: LossEntry) -> String {
        if entry.code == "max_tokens" { return L("hit the length limit") }
        switch entry.reason ?? .unknown {
        case .limit:
            let limit: String
            switch entry.limit {
            case .session: limit = L("session limit")
            case .monthly: limit = L("monthly limit")
            case .other, nil: limit = L("limit")
            }
            return resetsText(entry).map { "\(limit), \($0)" } ?? limit
        case .network: return L("no connection")
        case .stall: return L("stalled")
        case .sleep: return L("the Mac went to sleep")
        case .closed: return L("Claude Code closed")
        case .api: return apiProblem(entry)
        case .script: return entry.rawText.map { L("script error: %@", $0) } ?? L("script error")
        case .unknown: return entry.rawText.map { L("unknown: %@", $0) } ?? L("unknown")
        }
    }

    private static func apiProblem(_ entry: LossEntry) -> String {
        problemWord(entry.problem ?? .other) ?? entry.code ?? L("API error, no details")
    }

    /// The name of what an API error was about. Nil when its text does not say.
    public static func problemWord(_ problem: ApiProblem) -> String? {
        switch problem {
        case .overloaded: return L("overloaded")
        case .billing: return L("billing")
        case .access: return L("no access to the account")
        case .request: return L("bad request")
        case .other: return nil
        }
    }

    private static func resetsText(_ entry: LossEntry) -> String? {
        if let date = entry.resetsAt { return WorkFormat.resets(date, now: entry.at) }
        return entry.resets.map { L("resets %@", $0) }
    }

    private static func retryCause(_ entry: LossEntry) -> String {
        switch entry.reason ?? .unknown {
        case .limit: return L("retry after hitting a limit")
        case .network, .closed: return L("retry after losing the connection")
        case .stall: return L("retry after a stall")
        case .sleep: return L("retry after the Mac slept")
        case .api:
            return (entry.problem ?? .other) == .overloaded ? L("retry after an overload") : L("retry after an API error")
        case .script, .unknown: return L("retry after an error")
        }
    }

    private static func toolFailure(_ entry: LossEntry) -> String {
        toolFailureWords(entry.toolFailure ?? .other, code: entry.toolCode)
    }

    public static func toolFailureWords(_ failure: ToolFailure, code: Int?) -> String {
        switch failure {
        case .exitCode: return code.map { L("exit code %lld", $0) } ?? L("returned an error")
        case .noFile: return L("file not found")
        case .notRead: return L("file was not read first")
        case .changed: return L("file changed in the meantime")
        case .noMatch: return L("text to replace not found")
        case .badCall: return L("wrong parameters")
        case .timeout: return L("timed out")
        case .tooLarge: return L("too large")
        case .permission: return L("no access")
        case .http: return code.map { L("HTTP %lld", $0) } ?? L("returned an error")
        case .network: return L("no connection")
        case .other: return L("returned an error")
        }
    }

    private static func denial(_ entry: LossEntry) -> String {
        guard entry.denial == .person else { return named(entry.tool, L("forbidden by a rule")) }
        guard let tool = entry.tool else { return L("you declined the step") }
        switch WorkAction(tool: tool) {
        case .command: return L("you declined the command")
        case .write: return L("you declined the edit")
        default: return L("you declined %@", tool)
        }
    }

    private static func named(_ tool: String?, _ text: String) -> String {
        tool.map { "\($0): \(text)" } ?? text
    }
}
