import CoreGraphics
import Foundation

/// The numbers the notch and the panel show.
public struct SurfaceNumbers: Sendable, Equatable {
    public struct Context: Sendable, Equatable {
        public var name: String
        public var tokens: Int

        public init(name: String, tokens: Int) {
            self.name = name
            self.tokens = tokens
        }
    }

    public var waiting: Int
    public var agents: Int
    /// Nil until the first pass over the logs is done, which is not the same as zero.
    public var tokensToday: Int?
    public var usage: UsageSnapshot?
    /// The fullest context among what is at work.
    public var context: Context?

    public init(waiting: Int = 0, agents: Int = 0, tokensToday: Int? = 0, usage: UsageSnapshot? = nil, context: Context? = nil) {
        self.waiting = waiting
        self.agents = agents
        self.tokensToday = tokensToday
        self.usage = usage
        self.context = context
    }

    /// - Parameter today: nil until the first pass over the logs is done.
    public init(work: WorkModel, requests: Int, today: TokenUsage?, usage: UsageSnapshot?) {
        var fullest: Context?
        for session in work.sessions where session.state.isActive {
            for node in session.root.flattened where node.state.isActive {
                if let tokens = node.contextTokens, tokens > fullest?.tokens ?? 0 {
                    fullest = Context(name: session.displayName, tokens: tokens)
                }
            }
        }
        self.init(waiting: requests, agents: work.workingAgents, tokensToday: today?.total, usage: usage, context: fullest)
    }
}

/// The closed surface's text in two parts, because who is waiting has its own colour.
public struct SurfaceLine: Sendable, Equatable {
    public var main: String
    public var waiting: String

    public init(main: String = "", waiting: String = "") {
        self.main = main
        self.waiting = waiting
    }
}

/// The last thing that broke, in words made here. The text of the error itself never gets into them.
public struct SurfaceFailure: Sendable, Equatable {
    public var sessionId: String
    public var name: String
    public var nameIsFolder: Bool
    public var who: String
    public var what: String
    public var at: Date?

    public init(sessionId: String, name: String, nameIsFolder: Bool, who: String, what: String, at: Date?) {
        self.sessionId = sessionId
        self.name = name
        self.nameIsFolder = nameIsFolder
        self.who = who
        self.what = what
        self.at = at
    }
}

public enum SurfaceWords {
    /// An old failure is no news: the surface shows only what broke lately.
    public static let failureFreshFor: TimeInterval = 24 * 3600

    public static func waiting(_ count: Int) -> String {
        count == 1 ? L("%lld needs you", count) : L("%lld need you", count)
    }

    public static func working(_ count: Int) -> String {
        count == 1 ? L("%lld agent at work", count) : L("%lld agents at work", count)
    }

    /// - Parameter onNotch: the sides of the cutout are short, so in the simple mode who is waiting takes the place alone.
    public static func closedLine(_ numbers: SurfaceNumbers, mode: DisplayMode, onNotch: Bool) -> SurfaceLine {
        let waiting = numbers.waiting > 0 ? Self.waiting(numbers.waiting) : ""
        let quiet = numbers.waiting == 0 && numbers.agents == 0
        switch mode {
        case .simple:
            if numbers.agents == 0 || (onNotch && !waiting.isEmpty) {
                return SurfaceLine(main: quiet ? L("Quiet") : "", waiting: waiting)
            }
            return SurfaceLine(main: working(numbers.agents), waiting: waiting)
        case .technical:
            var parts: [String] = []
            if quiet { parts.append(L("Quiet")) }
            if numbers.agents > 0 { parts.append(WorkPhrases.agents(numbers.agents)) }
            // Room is short here, so what is not known yet is left out rather than shown as zero.
            if let tokens = numbers.tokensToday, tokens > 0 { parts.append(WorkFormat.tokens(tokens)) }
            if let limit = numbers.usage?.windows.first(where: { $0.kind == .fiveHour }) {
                parts.append(L("5 h %@", WorkFormat.percent(limit.percent)))
            }
            if let context = numbers.context { parts.append(L("ctx %@", WorkFormat.tokens(context.tokens))) }
            return SurfaceLine(main: parts.joined(separator: " · "), waiting: waiting)
        }
    }

    /// How wide the closed notch is in the design. It grows from here when its text needs it.
    public static func closedNotchWidth(_ numbers: SurfaceNumbers, mode: DisplayMode) -> CGFloat {
        if numbers.waiting == 0, numbers.agents == 0 { return 300 }
        return mode == .technical ? 460 : 380
    }

    /// The row of numbers in the technical mode. What is not known is left out.
    public static func numbersRow(_ numbers: SurfaceNumbers, now: Date, timeZone: TimeZone = .current) -> [String] {
        var parts: [String] = []
        if numbers.tokensToday == nil {
            parts.append(L("Today %@", UsageFormat.total(nil)))
        } else if let tokens = numbers.tokensToday, tokens > 0 {
            parts.append(L("Today %@", WorkFormat.tokens(tokens)))
        }
        for window in numbers.usage?.windows ?? [] {
            switch window.kind {
            case .fiveHour:
                let limit = L("5 h %@", WorkFormat.percent(window.percent))
                parts.append(window.resetsAt.map { "\(limit), \(WorkFormat.resets($0, now: now, timeZone: timeZone))" } ?? limit)
            case .week:
                parts.append(L("Week %@", WorkFormat.percent(window.percent)))
            case .weekModel, .extraSpend:
                break
            }
        }
        if let context = numbers.context { parts.append(L("Context %@ %@", shortened(context.name), WorkFormat.tokens(context.tokens))) }
        return parts
    }

    /// A long name would push the number out of the row, and the number is what the row is for.
    private static func shortened(_ name: String) -> String {
        name.count > 24 ? "\(name.prefix(23))…" : name
    }

    /// `VS Code · ждёт вас`: where the session runs and what it does, after its name on one line.
    public static func sessionDetail(_ session: WorkSession, mode: DisplayMode) -> String {
        let place = WorkPhrases.environment(session.environment)
        // The card above says what exactly it wants.
        let doing = session.state == .waiting && mode == .simple ? WorkPhrases.state(.waiting, mode: .simple) : WorkPhrases.line(session, mode: mode)
        // In the technical mode a line starts with the name of a tool, which keeps its capital.
        guard mode == .simple, let first = doing.first else { return "\(place) · \(doing)" }
        return "\(place) · \(first.lowercased())\(doing.dropFirst())"
    }

    /// How long a session has waited, and in the technical mode what a working one has spent.
    public static func sessionTrailing(_ session: WorkSession, mode: DisplayMode, now: Date) -> String {
        if session.state == .waiting {
            return (session.lastActivity ?? session.startedAt).map { WorkFormat.duration(now.timeIntervalSince($0)) } ?? ""
        }
        guard mode == .technical else { return "" }
        // The root holds the whole session once the logs are added up. Until then only what its agents metered live is known.
        let spent = session.root.tokens?.total ?? session.root.flattened.compactMap(\.tokens).reduce(0) { $0 + $1.total }
        return spent > 0 ? WorkFormat.tokens(spent) : ""
    }

    public static func lastFailure(in work: WorkModel, mode: DisplayMode, now: Date) -> SurfaceFailure? {
        var latest: SurfaceFailure?
        for session in work.sessions {
            guard let at = session.lastActivity, now.timeIntervalSince(at) < failureFreshFor, at > latest?.at ?? .distantPast else { continue }
            let nodes = session.root.flattened
            if let node = nodes.first(where: { $0.state == .failed }) {
                latest = SurfaceFailure(sessionId: session.id, name: session.name(in: mode), nameIsFolder: session.nameIsFolder, who: who(node, mode: mode), what: what(node, mode: mode), at: at)
            } else if let node = nodes.first(where: { $0.state == .interrupted }) {
                // A workflow can be cut off while its session counts as finished.
                let what = mode == .simple ? L("Cut off: Claude Code closed") : L("Interrupted: the process closed")
                latest = SurfaceFailure(sessionId: session.id, name: session.name(in: mode), nameIsFolder: session.nameIsFolder, who: who(node, mode: mode), what: what, at: at)
            }
        }
        return latest
    }

    private static func who(_ node: WorkNode, mode: DisplayMode) -> String {
        guard let title = node.title, !title.isEmpty else { return "" }
        let simple = mode == .simple
        switch node.kind {
        case .main: return ""
        case .subagent, .fork: return simple ? L("helper “%@”", title) : L("subagent “%@”", title)
        case .workflow: return simple ? PhraseBook.taskName(title) : L("workflow “%@”", title)
        case .workflowAgent: return simple ? L("helper “%@”", title) : L("agent “%@”", title)
        }
    }

    private static func what(_ node: WorkNode, mode: DisplayMode) -> String {
        let simple = mode == .simple
        let failure = node.failure
        switch failure?.failureClass ?? node.workflow?.topFailure ?? .unknown {
        case .limit:
            // A workflow's own node knows only the cause: when the limit resets, its agents know.
            let resets = node.flattened.lazy.compactMap { $0.failure?.resets }.first
            guard simple else { return resets.map { L("Limit reached, resets %@", $0) } ?? L("Limit reached") }
            if node.workflow?.status == .completedWithErrors {
                return resets.map { L("Partly done: the limit ran out, resets %@", $0) } ?? L("Partly done: the limit ran out")
            }
            return resets.map { L("Did not work out: the limit ran out, resets %@", $0) } ?? L("Did not work out: the limit ran out")
        case .network:
            return simple ? PhraseBook.advice(cause: .network) : L("Network error")
        case .sleep:
            return simple ? PhraseBook.advice(cause: .sleep) : L("Interrupted by sleep")
        case .stall:
            return simple ? PhraseBook.advice(cause: .stall) : L("Stalled: no progress")
        case .api:
            // The error's own words decide only which sentence to show, and are not shown.
            guard !simple else { return PhraseBook.advice(cause: .api, problem: failure?.apiProblem) }
            return failure?.apiProblem == .overloaded ? L("API error: overloaded") : L("API error")
        case .unknown:
            return simple ? PhraseBook.advice(cause: .unknown) : L("Unknown failure")
        }
    }
}
