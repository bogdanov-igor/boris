import Foundation

public enum UsagePeriod: String, CaseIterable, Sendable {
    case today, week, month, all

    /// How many days back it reaches, today included. Nil for all the logs there are.
    var days: Int? {
        switch self {
        case .today: return 1
        case .week: return 7
        case .month: return 30
        case .all: return nil
        }
    }
}

public enum TokenBreakdown: String, CaseIterable, Sendable {
    case days, environments, projects, models, agents
}

/// Who spent it, in a way that means something over many sessions.
public enum AgentGroup: String, CaseIterable, Sendable {
    case main, subagents, workflow
}

/// What tokens would cost at API prices. Tokens of a model with no known price are counted aside, never as free.
public struct SpendEstimate: Sendable, Equatable {
    public var dollars = 0.0
    public var pricedTokens = 0
    public var unpricedTokens = 0

    public init() {}

    /// False only when there were tokens and none of them had a price.
    public var isKnown: Bool { pricedTokens > 0 || unpricedTokens == 0 }

    mutating func add(_ usage: TokenUsage, price: ModelPrice?) {
        if let price {
            dollars += price.cost(of: usage)
            pricedTokens += usage.total
        } else {
            unpricedTokens += usage.total
        }
    }
}

public struct TokenLine: Sendable, Equatable, Identifiable {
    public enum Key: Sendable, Hashable {
        case day(String)
        case environment(WorkEnvironment?)
        case project(String?)
        case model(String?)
        case agents(AgentGroup)
    }

    public var key: Key
    public var usage = TokenUsage()
    public var estimate = SpendEstimate()

    public var id: Key { key }

    mutating func add(_ more: TokenUsage, price: ModelPrice?) {
        usage = usage + more
        estimate.add(more, price: price)
    }
}

/// Everything the usage page shows for one period.
public struct PeriodReport: Sendable {
    public var usage = TokenUsage()
    public var estimate = SpendEstimate()
    /// Every day of the period in order, quiet ones too, so that a gap in the work looks like a gap.
    public var chartDays: [TokenLine] = []
    fileprivate var lines: [TokenBreakdown: [TokenLine]] = [:]

    /// The busiest first. Days go from the newest, and only those with work.
    public func lines(_ breakdown: TokenBreakdown) -> [TokenLine] {
        lines[breakdown] ?? []
    }
}

/// Real spend added up at every level, once, off the main thread: screens only look numbers up.
public struct TokenBook: Sendable {
    /// How far back a chart goes. The sums are not cut: this is only about how many bars can be told apart.
    static let chartLimit = 180

    /// The day this was built for. A new day moves every period, so the book is built again.
    public let today: String
    /// The oldest day there are logs for. Nil when there are none.
    public let earliestDay: String?
    private let reports: [UsagePeriod: PeriodReport]
    private let days: [String: TokenUsage]
    /// The whole session: its main agent and everything under it.
    private let sessions: [String: TokenUsage]
    private let mainAgents: [String: TokenUsage]
    private let agents: [String: TokenUsage]
    private let runs: [String: TokenUsage]

    public init(records: [TokenRecord], now: Date, timeZone: TimeZone = .current) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: now)
        self.today = today

        // An agent's transcript may lack what its session's has.
        var cwds: [String: String] = [:]
        var entrypoints: [String: String] = [:]
        for record in records where record.agentId == nil {
            if let cwd = record.cwd { cwds[record.sessionId] = cwd }
            if let entrypoint = record.entrypoint { entrypoints[record.sessionId] = entrypoint }
        }

        var prices: [String: ModelPrice?] = [:]
        func price(_ model: String?) -> ModelPrice? {
            guard let model else { return nil }
            if let known = prices[model] { return known }
            let found = PriceTable.price(for: model)
            prices[model] = found
            return found
        }

        let starts = UsagePeriod.allCases.compactMap { period -> (UsagePeriod, String)? in
            guard let days = period.days, let start = calendar.date(byAdding: .day, value: 1 - days, to: now) else { return nil }
            return (period, formatter.string(from: start))
        }

        var tallies: [UsagePeriod: Tally] = [:]
        var days: [String: TokenUsage] = [:]
        var sessions: [String: TokenUsage] = [:]
        var mainAgents: [String: TokenUsage] = [:]
        var agents: [String: TokenUsage] = [:]
        var runs: [String: TokenUsage] = [:]
        var earliest: String?

        for record in records where record.usage.total > 0 {
            let usage = record.usage
            let cost = price(record.model)
            let keys = [
                (TokenBreakdown.days, TokenLine.Key.day(record.day)),
                (.environments, .environment(WorkEnvironment(entrypoint: record.entrypoint ?? entrypoints[record.sessionId], unlisted: false))),
                (.projects, .project(record.cwd ?? cwds[record.sessionId])),
                (.models, .model(record.model)),
                (.agents, .agents(record.agentId == nil ? .main : record.runId == nil ? .subagents : .workflow)),
            ]
            tallies[.all, default: Tally()].add(keys, usage, cost)
            for (period, start) in starts where record.day >= start && record.day <= today {
                tallies[period, default: Tally()].add(keys, usage, cost)
            }

            days[record.day, default: TokenUsage()] = days[record.day, default: TokenUsage()] + usage
            sessions[record.sessionId, default: TokenUsage()] = sessions[record.sessionId, default: TokenUsage()] + usage
            if let agent = record.agentId {
                agents[agent, default: TokenUsage()] = agents[agent, default: TokenUsage()] + usage
            } else {
                mainAgents[record.sessionId, default: TokenUsage()] = mainAgents[record.sessionId, default: TokenUsage()] + usage
            }
            if let run = record.runId {
                runs[run, default: TokenUsage()] = runs[run, default: TokenUsage()] + usage
            }
            if earliest.map({ record.day < $0 }) ?? true { earliest = record.day }
        }

        var reports: [UsagePeriod: PeriodReport] = [:]
        for period in UsagePeriod.allCases {
            var report = tallies[period]?.report() ?? PeriodReport()
            let wanted = period.days ?? Self.chartLimit
            report.chartDays = Self.chartDays(report, count: min(wanted, Self.chartLimit), earliest: earliest, now: now, calendar: calendar, formatter: formatter)
            reports[period] = report
        }
        self.reports = reports
        self.days = days
        self.sessions = sessions
        self.mainAgents = mainAgents
        self.agents = agents
        self.runs = runs
        earliestDay = earliest
    }

    /// A period older than the logs starts where the logs start.
    private static func chartDays(_ report: PeriodReport, count: Int, earliest: String?, now: Date, calendar: Calendar, formatter: DateFormatter) -> [TokenLine] {
        guard let earliest else { return [] }
        let known = Dictionary(report.lines(.days).map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [TokenLine] = []
        for back in stride(from: count - 1, through: 0, by: -1) {
            guard let date = calendar.date(byAdding: .day, value: -back, to: now) else { continue }
            let day = formatter.string(from: date)
            guard day >= earliest else { continue }
            let key = TokenLine.Key.day(day)
            result.append(known[key] ?? TokenLine(key: key))
        }
        return result
    }

    public func report(_ period: UsagePeriod) -> PeriodReport {
        reports[period] ?? PeriodReport()
    }

    /// True when the logs go back further than the chart of this period does. The sums still hold everything.
    public func chartLeavesOutDays(_ period: UsagePeriod) -> Bool {
        guard period == .all, let earliestDay, case .day(let first)? = report(period).chartDays.first?.key else { return false }
        return earliestDay < first
    }

    public func spent(onDay day: String) -> TokenUsage {
        days[day] ?? TokenUsage()
    }

    /// Lays the exact numbers over the live model. The root of a session gets the whole session, every other node what it spent itself.
    public func applied(to model: WorkModel) -> WorkModel {
        var result = model
        for project in result.projects.indices {
            for session in result.projects[project].sessions.indices {
                let id = result.projects[project].sessions[session].id
                result.projects[project].sessions[session].mainAgentTokens = mainAgents[id]
                if let total = sessions[id] { result.projects[project].sessions[session].root.tokens = total }
                lay(on: &result.projects[project].sessions[session].root.children)
            }
        }
        return result
    }

    /// What was only metered live, so that the book has not seen it yet, keeps its live number.
    private func lay(on nodes: inout [WorkNode]) {
        for index in nodes.indices {
            let exact = nodes[index].kind == .workflow ? runs[nodes[index].workflow?.runId ?? nodes[index].id] : agents[nodes[index].id]
            if let exact { nodes[index].tokens = exact }
            lay(on: &nodes[index].children)
        }
    }
}

/// The sums of one period while the book is being built.
private struct Tally {
    var usage = TokenUsage()
    var estimate = SpendEstimate()
    var lines: [TokenBreakdown: [TokenLine.Key: TokenLine]] = [:]

    mutating func add(_ keys: [(TokenBreakdown, TokenLine.Key)], _ more: TokenUsage, _ price: ModelPrice?) {
        usage = usage + more
        estimate.add(more, price: price)
        for (breakdown, key) in keys {
            lines[breakdown, default: [:]][key, default: TokenLine(key: key)].add(more, price: price)
        }
    }

    func report() -> PeriodReport {
        var report = PeriodReport(usage: usage, estimate: estimate)
        for (breakdown, found) in lines {
            report.lines[breakdown] = found.values.sorted { first, second in
                if case .day(let a) = first.key, case .day(let b) = second.key { return a > b }
                return first.usage.total == second.usage.total ? "\(first.key)" < "\(second.key)" : first.usage.total > second.usage.total
            }
        }
        return report
    }
}
