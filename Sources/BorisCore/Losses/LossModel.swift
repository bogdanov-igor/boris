import Foundation

/// What kind of trouble it was.
public enum LossKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case crash, apiError, toolError, retry, cut, denied

    public var id: String { rawValue }
}

/// Why an agent went down. Wider than `FailureClass`, which only knows what an error's text says:
/// a broken workflow script and a closed Claude Code leave no such text.
public enum LossReason: String, Codable, Sendable, CaseIterable, Identifiable {
    case limit, network, stall, api, sleep, script, closed, unknown

    public var id: String { rawValue }

    public init(_ failure: FailureClass) {
        switch failure {
        case .limit: self = .limit
        case .network: self = .network
        case .sleep: self = .sleep
        case .stall: self = .stall
        case .api: self = .api
        case .unknown: self = .unknown
        }
    }
}

/// What an API error was about, when it was not a limit or the network.
public enum ApiProblem: String, Codable, Sendable {
    case overloaded, billing, access, request, other

    public init(code: String?, status: Int?, text: String?) {
        let lower = text?.lowercased() ?? ""
        if status == 529 || status == 503 || lower.contains("overloaded") || lower.contains("temporarily unavailable") {
            self = .overloaded
        } else if code == "billing_error" || lower.contains("credit balance") || lower.contains("billing") {
            self = .billing
        } else if code == "authentication_failed" || status == 401 || status == 403 || lower.contains("oauth") || lower.contains("authenticate") {
            self = .access
        } else if code == "invalid_request" || status == 400 || lower.contains("too long") {
            self = .request
        } else {
            self = .other
        }
    }
}

/// How a tool failed, in a word. Its output is looked at and never kept.
public enum ToolFailure: String, Codable, Sendable {
    case exitCode, noFile, notRead, changed, noMatch, badCall, timeout, tooLarge, permission, http, network, other
}

public enum LossDenial: String, Codable, Sendable {
    /// The person said no in Claude's dialog.
    case person
    /// A rule or a safety check said no.
    case rule
}

/// One failure. A workflow's agents that fell for one reason share a row, so `count` says how many it stands for.
public struct LossEntry: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var at: Date
    public var kind: LossKind
    public var count: Int
    public var sessionId: String
    public var agentId: String?
    public var runId: String?
    public var cwd: String?
    public var entrypoint: String?
    /// The name of the agent or the workflow. Nil for a session's main agent.
    public var title: String?
    /// The agents whose tokens this row lost.
    public var agents: [String]
    /// How many agents the workflow had, to say "3 of 12".
    public var total: Int?
    public var reason: LossReason?
    public var problem: ApiProblem?
    public var limit: LimitKind?
    /// When the limit resets, as Claude Code wrote it or as a date when it gave one.
    public var resets: String?
    public var resetsAt: Date?
    /// The error's code and status, for those who want to look it up.
    public var code: String?
    public var status: Int?
    public var tool: String?
    public var toolFailure: ToolFailure?
    /// The exit code of a command or the status of a page.
    public var toolCode: Int?
    /// What came of the retries. Nil while nothing is known yet.
    public var recovered: Bool?
    public var denial: LossDenial?
    /// The error as it was written, kept only for reasons Boris could not name. It comes from a workflow's result, never from a transcript.
    public var rawText: String?

    public init(id: String, at: Date, kind: LossKind, count: Int = 1, sessionId: String, agentId: String? = nil, runId: String? = nil, cwd: String? = nil, entrypoint: String? = nil, title: String? = nil, agents: [String] = [], total: Int? = nil, reason: LossReason? = nil, problem: ApiProblem? = nil, limit: LimitKind? = nil, resets: String? = nil, resetsAt: Date? = nil, code: String? = nil, status: Int? = nil, tool: String? = nil, toolFailure: ToolFailure? = nil, toolCode: Int? = nil, recovered: Bool? = nil, denial: LossDenial? = nil, rawText: String? = nil) {
        self.id = id
        self.at = at
        self.kind = kind
        self.count = count
        self.sessionId = sessionId
        self.agentId = agentId
        self.runId = runId
        self.cwd = cwd
        self.entrypoint = entrypoint
        self.title = title
        self.agents = agents
        self.total = total
        self.reason = reason
        self.problem = problem
        self.limit = limit
        self.resets = resets
        self.resetsAt = resetsAt
        self.code = code
        self.status = status
        self.tool = tool
        self.toolFailure = toolFailure
        self.toolCode = toolCode
        self.recovered = recovered
        self.denial = denial
        self.rawText = rawText
    }

    public var project: String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }

    public var environment: WorkEnvironment? {
        WorkEnvironment(entrypoint: entrypoint, unlisted: false)
    }
}

public enum LossCallKind: String, Codable, Sendable {
    case skill, search, fetch
}

/// Calls of one kind on one day. Calls are counted exactly, tokens are an estimate from the size of what came back.
public struct LossCalls: Codable, Sendable, Equatable {
    public var day: String
    public var kind: LossCallKind
    /// The skill's name. Nil for searches and page loads.
    public var name: String?
    public var calls: Int
    public var estimatedTokens: Int

    public init(day: String, kind: LossCallKind, name: String? = nil, calls: Int = 0, estimatedTokens: Int = 0) {
        self.day = day
        self.kind = kind
        self.name = name
        self.calls = calls
        self.estimatedTokens = estimatedTokens
    }
}

/// Everything known, before choosing a period.
public struct LossHistory: Sendable, Equatable {
    public var entries: [LossEntry]
    public var calls: [LossCalls]

    public init(entries: [LossEntry] = [], calls: [LossCalls] = []) {
        self.entries = entries
        self.calls = calls
    }
}

public enum LossPeriod: String, CaseIterable, Sendable, Identifiable {
    case week, month, all

    public var id: String { rawValue }

    /// The first moment that counts: whole days, today included.
    public func start(now: Date, calendar: Calendar = .current) -> Date? {
        let days: Int
        switch self {
        case .week: days = 7
        case .month: days = 30
        case .all: return nil
        }
        return calendar.date(byAdding: .day, value: 1 - days, to: calendar.startOfDay(for: now))
    }
}

/// What the page shows for one period.
public struct LossBook: Sendable, Equatable {
    public struct ReasonCount: Sendable, Equatable, Identifiable {
        public var reason: LossReason
        public var count: Int

        public var id: String { reason.rawValue }
    }

    public struct SkillCount: Sendable, Equatable, Identifiable {
        public var name: String?
        public var calls: Int

        public var id: String { name ?? "" }
    }

    /// Newest first.
    public var entries: [LossEntry]
    /// Most frequent first, reasons with nothing behind them are left out.
    public var reasons: [ReasonCount]
    public var kinds: [LossKind: Int]
    /// Nil when nothing is known about tokens yet, which is not the same as zero.
    public var lostTokens: Int?
    public var skills: [SkillCount]
    public var skillTokens: Int
    public var searches: Int
    public var fetches: Int
    public var webTokens: Int
    public var projects: [String]
    public var environments: [WorkEnvironment]

    /// The list as narrowed down by the page's filters. Nil lets everything through.
    public func entries(kind: LossKind?, project: String?, environment: WorkEnvironment?) -> [LossEntry] {
        entries.filter { entry in
            (kind == nil || entry.kind == kind) && (project == nil || entry.project == project) && (environment == nil || entry.environment == environment)
        }
    }

    public var crashed: Int { kinds[.crash] ?? 0 }
    public var skillCalls: Int { skills.reduce(0) { $0 + $1.calls } }

    /// - Parameter agentTokens: what each agent really spent, from the token index.
    public init(history: LossHistory, period: LossPeriod, agentTokens: [String: Int], now: Date, calendar: Calendar = .current) {
        let start = period.start(now: now, calendar: calendar)
        let entries = history.entries
            .filter { entry in start.map { entry.at >= $0 } ?? true }
            .sorted { $0.at == $1.at ? $0.id < $1.id : $0.at > $1.at }
        self.entries = entries

        var kinds: [LossKind: Int] = [:]
        var reasons: [LossReason: Int] = [:]
        var lost: Set<String> = []
        for entry in entries {
            kinds[entry.kind, default: 0] += entry.count
            guard entry.kind == .crash else { continue }
            reasons[entry.reason ?? .unknown, default: 0] += entry.count
            lost.formUnion(entry.agents)
        }
        self.kinds = kinds
        self.reasons = reasons
            .map { ReasonCount(reason: $0.key, count: $0.value) }
            .sorted { $0.count == $1.count ? $0.reason.rawValue < $1.reason.rawValue : $0.count > $1.count }
        lostTokens = agentTokens.isEmpty && !lost.isEmpty ? nil : lost.reduce(0) { $0 + (agentTokens[$1] ?? 0) }

        let firstDay = start.map { StatsBook.dayKey($0, calendar: calendar) }
        let calls = history.calls.filter { bucket in firstDay.map { bucket.day >= $0 } ?? true }
        var perSkill: [String?: Int] = [:]
        for bucket in calls where bucket.kind == .skill { perSkill[bucket.name, default: 0] += bucket.calls }
        skills = perSkill
            .filter { $0.value > 0 }
            .map { SkillCount(name: $0.key, calls: $0.value) }
            .sorted { $0.calls == $1.calls ? ($0.name ?? "") < ($1.name ?? "") : $0.calls > $1.calls }
        skillTokens = calls.filter { $0.kind == .skill }.reduce(0) { $0 + $1.estimatedTokens }
        searches = calls.filter { $0.kind == .search }.reduce(0) { $0 + $1.calls }
        fetches = calls.filter { $0.kind == .fetch }.reduce(0) { $0 + $1.calls }
        webTokens = calls.filter { $0.kind != .skill }.reduce(0) { $0 + $1.estimatedTokens }

        projects = Array(Set(entries.compactMap(\.project))).sorted()
        var seen: Set<WorkEnvironment> = []
        environments = entries.compactMap(\.environment).filter { seen.insert($0).inserted }
    }
}
