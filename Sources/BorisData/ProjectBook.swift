import BorisCore
import Foundation

public struct ProjectFilter: Sendable, Equatable {
    public var period: WorkPeriod
    public var environment: WorkEnvironment?

    public init(period: WorkPeriod = .week, environment: WorkEnvironment? = nil) {
        self.period = period
        self.environment = environment
    }
}

/// A project as the pages show it, within a chosen time and environment.
public struct ProjectSummary: Sendable, Equatable, Identifiable {
    public var id: String { path ?? "" }
    public var path: String?
    /// At work now, whoever needs the person first.
    public var active: [WorkSession] = []
    /// Everything else in the period, newest first.
    public var past: [WorkSession] = []
    public var today = TokenUsage()
    public var inPeriod = TokenUsage()
    /// What the tokens of the period would cost at API prices.
    public var estimate = SpendEstimate()
    /// Tokens by the `yyyy-MM-dd` of the day.
    public var byDay: [String: Int] = [:]

    public init(path: String?) {
        self.path = path
    }

    public var name: String? { path.map { URL(fileURLWithPath: $0).lastPathComponent } }
    public var sessions: [WorkSession] { active + past }
    /// Agents that fell within the period, by when each one fell: the same count the Losses page gives.
    public var failures = 0
    public var lastActivity: Date? { sessions.compactMap { $0.lastActivity ?? $0.startedAt }.max() }
    /// The session that says how the project is doing.
    public var lead: WorkSession? { active.first ?? past.first }

    public var environments: [WorkEnvironment] { ProjectBook.environments(of: sessions) }

    var isEmpty: Bool { active.isEmpty && past.isEmpty && inPeriod.total == 0 && failures == 0 }
}

public enum ProjectBook {
    /// What is at work comes from the live scan, the rest from the logs. A session that ended a moment ago may not be in the logs' list yet.
    /// One that ended before the logs were read and is not among them has had its log deleted, whatever the live scan still remembers.
    /// - Parameter logsReadAt: when the logs were last read. Nil until they have been.
    public static func sessions(work: WorkModel, past: [WorkSession], logsReadAt: Date? = nil) -> [WorkSession] {
        // The live scan sees only the last day. What a session at work did before that is in its log, and it stays on its page.
        let logged = Dictionary(past.map { ($0.id, $0) }) { first, _ in first }
        let active = work.sessions.filter(\.state.isCurrent).map { session in
            logged[session.id].map { WorkBuilder.merged(live: session, logged: $0) } ?? session
        }
        let activeIds = Set(active.map(\.id))
        let pastIds = Set(past.map(\.id))
        let newer = work.sessions.filter { session in
            guard !session.state.isCurrent, !pastIds.contains(session.id) else { return false }
            // A chat never has a log, so not being among the logs says nothing about it.
            guard let logsReadAt, session.environment != .chat else { return true }
            return (session.lastActivity ?? session.startedAt ?? .distantPast) > logsReadAt
        }
        return active + past.filter { !activeIds.contains($0.id) } + newer
    }

    /// Every project with something to show in the period: who waits for the person or has failures first, those without a folder last.
    public static func summaries(sessions: [WorkSession], tokens: [TokenRecord], filter: ProjectFilter, now: Date, calendar: Calendar = .current) -> [ProjectSummary] {
        collect(sessions: sessions, tokens: tokens, filter: filter, now: now, calendar: calendar).values
            .filter { !$0.isEmpty }
            .sorted(by: comesFirst)
    }

    /// One project, even with nothing in the period: its page stays open when the filter empties it.
    public static func summary(path: String?, sessions: [WorkSession], tokens: [TokenRecord], filter: ProjectFilter, now: Date, calendar: Calendar = .current) -> ProjectSummary {
        collect(sessions: sessions, tokens: tokens, filter: filter, now: now, calendar: calendar)[path] ?? ProjectSummary(path: path)
    }

    /// The environments there is something from, for the filter.
    public static func environments(of sessions: [WorkSession]) -> [WorkEnvironment] {
        sessions.compactMap(\.environment).reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    public static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private static func collect(sessions: [WorkSession], tokens: [TokenRecord], filter: ProjectFilter, now: Date, calendar: Calendar) -> [String?: ProjectSummary] {
        let days = filter.period.days(now: now, calendar: calendar)
        var projects: [String?: ProjectSummary] = [:]
        var owners: [String: WorkSession] = [:]
        for session in sessions {
            owners[session.id] = session
            guard filter.environment == nil || session.environment == filter.environment else { continue }
            var project = projects[session.projectPath] ?? ProjectSummary(path: session.projectPath)
            if session.state.isCurrent {
                project.active.append(session)
            } else if overlaps(session, days) {
                project.past.append(session)
            }
            project.failures += session.failureCount(in: days)
            projects[session.projectPath] = project
        }

        let today = dayKey(now, calendar: calendar)
        let first = dayKey(days.lowerBound, calendar: calendar)
        let last = dayKey(days.upperBound, calendar: calendar)
        var prices: [String: ModelPrice?] = [:]
        func price(_ model: String?) -> ModelPrice? {
            guard let model else { return nil }
            if let known = prices[model] { return known }
            let found = PriceTable.price(for: model)
            prices[model] = found
            return found
        }
        for record in tokens {
            let owner = owners[record.sessionId]
            let environment = owner?.environment ?? record.host.map { .remote(host: $0) } ?? WorkEnvironment(entrypoint: record.entrypoint, unlisted: false)
            guard filter.environment == nil || environment == filter.environment else { continue }
            // For a session not in the list yet, the record has to say by itself where it belongs.
            let path = owner.map(\.projectPath) ?? GitPlace.projectPath(cwd: record.cwd, environment: environment)
            var project = projects[path] ?? ProjectSummary(path: path)
            if record.day == today { project.today = project.today + record.usage }
            if record.day >= first, record.day <= last {
                project.inPeriod = project.inPeriod + record.usage
                project.estimate.add(record.usage, price: price(record.model))
                project.byDay[record.day, default: 0] += record.usage.total
            }
            projects[path] = project
        }

        for key in projects.keys {
            projects[key]?.active.sort(by: needsPersonFirst)
            projects[key]?.past.sort { ($0.lastActivity ?? $0.startedAt ?? .distantPast) > ($1.lastActivity ?? $1.startedAt ?? .distantPast) }
        }
        return projects
    }

    private static func overlaps(_ session: WorkSession, _ days: ClosedRange<Date>) -> Bool {
        let end = session.lastActivity ?? session.startedAt
        let start = session.startedAt ?? session.lastActivity
        guard let start, let end else { return true }
        return end >= days.lowerBound && start <= days.upperBound
    }

    private static func needsPersonFirst(_ a: WorkSession, _ b: WorkSession) -> Bool {
        if (a.state == .waiting) != (b.state == .waiting) { return a.state == .waiting }
        return (a.lastActivity ?? .distantPast) > (b.lastActivity ?? .distantPast)
    }

    private static func comesFirst(_ a: ProjectSummary, _ b: ProjectSummary) -> Bool {
        if (a.path == nil) != (b.path == nil) { return b.path == nil }
        func rank(_ project: ProjectSummary) -> Int {
            if project.active.contains(where: { $0.state == .waiting }) { return 0 }
            if project.failures > 0 { return 1 }
            return project.active.isEmpty ? 3 : 2
        }
        if rank(a) != rank(b) { return rank(a) < rank(b) }
        let x = a.lastActivity ?? .distantPast
        let y = b.lastActivity ?? .distantPast
        return x == y ? (a.path ?? "") < (b.path ?? "") : x > y
    }
}
