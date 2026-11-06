import BorisCore
import Foundation

/// Where an answer was given.
public enum RequestPlace: String, Codable, Sendable {
    case window, mini, notch, hotKey, session
}

public enum RequestOutcome: String, Codable, Sendable {
    case allowed, denied, answered, planApproved, planDenied
    /// The time in Boris ran out, and the answer was given in Claude.
    case expired
    /// The request went away in Claude, and Boris cannot know how it was answered.
    case closedInClaude
}

/// What a request was about, in words that hold no text of it: a list shows this, and it may be kept.
public struct RequestBrief: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case command, file, questions, plan, other
    }

    public var tool: String
    public var kind: Kind
    /// The name of the file, without its folder.
    public var fileName: String?
    public var questions: Int

    public init(tool: String, kind: Kind, fileName: String? = nil, questions: Int = 0) {
        self.tool = tool
        self.kind = kind
        self.fileName = fileName
        self.questions = questions
    }

    public init(_ request: PendingPermission) {
        switch request.content {
        case .command:
            self.init(tool: request.tool, kind: .command)
        case .file(let path, _, _, _):
            self.init(tool: request.tool, kind: .file, fileName: URL(fileURLWithPath: path).lastPathComponent)
        case .questions(let questions):
            self.init(tool: request.tool, kind: .questions, questions: questions.count)
        case .plan:
            self.init(tool: request.tool, kind: .plan)
        case .other, .unreadable:
            // The tool name alone decides here, so a request too long to show still reads as what it is.
            switch request.tool {
            case "AskUserQuestion": self.init(tool: request.tool, kind: .questions, questions: 1)
            case "ExitPlanMode": self.init(tool: request.tool, kind: .plan)
            case "Bash": self.init(tool: request.tool, kind: .command)
            case "Edit", "MultiEdit", "Write", "NotebookEdit": self.init(tool: request.tool, kind: .file)
            default: self.init(tool: request.tool, kind: .other)
            }
        }
    }
}

/// One line of the history. It has no command, answer, reason or plan, so it can be kept in a file.
public struct RequestDecision: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var at: Date
    public var project: String?
    public var environment: String?
    public var agentType: String?
    public var isMainAgent: Bool
    public var brief: RequestBrief
    public var outcome: RequestOutcome
    public var place: RequestPlace
    public var waited: TimeInterval

    public init(id: UUID, at: Date, project: String?, environment: String?, agentType: String?, isMainAgent: Bool, brief: RequestBrief, outcome: RequestOutcome, place: RequestPlace, waited: TimeInterval) {
        self.id = id
        self.at = at
        self.project = project
        self.environment = environment
        self.agentType = agentType
        self.isMainAgent = isMainAgent
        self.brief = brief
        self.outcome = outcome
        self.place = place
        self.waited = waited
    }
}

/// A request whose time in Boris ran out. It still waits in Claude, and its text has already left memory.
public struct ExpiredRequest: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var session: String
    public var agent: String?
    public var agentType: String?
    public var project: String?
    public var brief: RequestBrief
    public var askedAt: Date
    public var deadline: Date
    public var digest: String?

    public init(_ request: PendingPermission) {
        id = request.id
        session = request.session
        agent = request.agent
        agentType = request.agentType
        project = request.project
        brief = RequestBrief(request)
        askedAt = request.askedAt
        deadline = request.deadline
        digest = request.digest
    }
}

/// One row of the queue.
public enum RequestRow: Identifiable, Equatable, Sendable {
    case open(PendingPermission)
    case expired(ExpiredRequest)
    /// Waiting in Claude with nothing held here, so the only ways out are the session and connecting the answers.
    case waiting(WorkSession)

    public var id: String {
        switch self {
        case .open(let request): return request.id.uuidString
        case .expired(let request): return request.id.uuidString
        case .waiting(let session): return session.id
        }
    }

    public var isOpen: Bool {
        if case .open = self { return true }
        return false
    }

    public var session: String {
        switch self {
        case .open(let request): return request.session
        case .expired(let request): return request.session
        case .waiting(let session): return session.id
        }
    }
}

/// Everything that is being asked and what became of it. Pure, so that every path can be tested without a socket.
public struct RequestQueue: Sendable, Equatable {
    public private(set) var open: [PendingPermission] = []
    public private(set) var expired: [ExpiredRequest] = []
    public private(set) var decisions: [RequestDecision] = []
    public private(set) var work = WorkModel()
    private var answeredAt: [String: Date] = [:]

    /// The files catch up with an answer within a few seconds. Until then the session should not look like it asks again.
    static let settling: TimeInterval = 5
    static let historyLimit = 500

    public init(decisions: [RequestDecision] = []) {
        self.decisions = decisions
    }

    /// Open requests first, then those that went over time, then sessions waiting with nothing held here. Oldest first in each.
    public func rows(now: Date) -> [RequestRow] {
        let held = Set(open.map(\.session) + expired.map(\.session))
        let elsewhere = work.waitingSessions
            .filter { !held.contains($0.id) && (answeredAt[$0.id].map { now.timeIntervalSince($0) >= Self.settling } ?? true) }
            .sorted { ($0.lastActivity ?? $0.startedAt ?? .distantPast) < ($1.lastActivity ?? $1.startedAt ?? .distantPast) }
        return open.sorted { $0.askedAt < $1.askedAt }.map(RequestRow.open)
            + expired.sorted { $0.askedAt < $1.askedAt }.map(RequestRow.expired)
            + elsewhere.map(RequestRow.waiting)
    }

    public func decisions(on day: Date, calendar: Calendar = .current) -> [RequestDecision] {
        decisions.filter { calendar.isDate($0.at, inSameDayAs: day) }.sorted { $0.at > $1.at }
    }

    public func session(_ id: String) -> WorkSession? {
        work.sessions.first { $0.id == id }
    }

    public mutating func add(_ request: PendingPermission) {
        open.append(request)
    }

    /// Takes the request out of the queue. Returns false when it has already gone, so an answer can never reach another one.
    /// Also false when the time is up, even if word of that is still on its way here: the hook has been let go, and nothing would reach Claude.
    public mutating func answered(_ id: UUID, with answer: HookAnswer, place: RequestPlace, now: Date) -> Bool {
        guard let held = open.first(where: { $0.id == id }), now < held.deadline, Self.fits(answer, held.content), let request = take(id) else { return false }
        let outcome: RequestOutcome
        switch (answer, request.content) {
        case (.answers, _): outcome = .answered
        case (.allow, .plan): outcome = .planApproved
        case (.deny, .plan): outcome = .planDenied
        case (.allow, _): outcome = .allowed
        case (.deny, _): outcome = .denied
        }
        record(request, outcome: outcome, place: place, waited: now.timeIntervalSince(request.askedAt), now: now)
        return true
    }

    /// The buttons and keys offer only these. Checked here too, because allowing what cannot be read is the one mistake that must not get through.
    private static func fits(_ answer: HookAnswer, _ content: RequestContent) -> Bool {
        switch (answer, content) {
        case (.deny, _), (.answers, .questions): return true
        case (.answers, _), (.allow, .questions): return false
        case (.allow, _): return content.canAllow
        }
    }

    /// The wait is over and the request stays in Claude, so the card says so and offers the session.
    public mutating func expire(_ id: UUID) {
        guard let request = take(id) else { return }
        expired.append(ExpiredRequest(request))
    }

    /// The hook went away before the time was up.
    public mutating func gone(_ id: UUID, now: Date) {
        guard let request = take(id) else { return }
        record(request, outcome: .closedInClaude, place: .session, waited: now.timeIntervalSince(request.askedAt), now: now)
    }

    /// A tool ran with the input of a request, so someone allowed it in Claude. Returns the held hooks to let go.
    public mutating func toolDone(session: String, digest: String, now: Date) -> [UUID] {
        var released: [UUID] = []
        for request in open where request.session == session && request.digest == digest {
            released.append(request.id)
            _ = take(request.id)
            record(request, outcome: .allowed, place: .session, waited: now.timeIntervalSince(request.askedAt), now: now)
        }
        for request in expired where request.session == session && request.digest == digest {
            removeExpired(request, outcome: .allowed, now: now)
        }
        return released
    }

    /// What ends a request without an answer from here. Returns the held hooks to let go.
    public mutating func note(_ signal: HookSignal, now: Date) -> [UUID] {
        switch signal {
        case .turnStopped(let session):
            return close(now: now) { $0 == session && $1 == nil }
        case .sessionEnded(let session, _, _):
            return close(now: now) { asked, _ in asked == session }
        case .agentStopped(let session, let agent):
            return close(now: now) { $0 == session && $1 == agent }
        case .toolStarted(let session, let agent, _):
            // The same agent moved on to another tool long after asking, so the request was answered in Claude.
            for request in expired where request.session == session && request.agent == agent && now > request.deadline {
                removeExpired(request, outcome: .expired, now: now)
            }
            return []
        default:
            return []
        }
    }

    private mutating func close(now: Date, _ matches: (String, String?) -> Bool) -> [UUID] {
        var released: [UUID] = []
        for request in open where matches(request.session, request.agent) {
            released.append(request.id)
            gone(request.id, now: now)
        }
        for request in expired where matches(request.session, request.agent) {
            removeExpired(request, outcome: .expired, now: now)
        }
        return released
    }

    /// The freshest picture of the work. Over-time requests of a session that no longer waits were answered in Claude.
    public mutating func note(work: WorkModel, now: Date) {
        self.work = work
        for request in expired {
            guard let session = session(request.session) else {
                if now.timeIntervalSince(request.deadline) > HookState.waitingExpiry { removeExpired(request, outcome: .expired, now: now) }
                continue
            }
            if session.state != .waiting { removeExpired(request, outcome: .expired, now: now) }
        }
        answeredAt = answeredAt.filter { now.timeIntervalSince($0.value) < Self.settling }
    }

    /// The person no longer wants Boris to deal with this source. Nothing was decided, so no history stays, and neither does its text.
    public mutating func forget(_ id: UUID) {
        _ = take(id)
        expired.removeAll { $0.id == id }
    }

    private mutating func take(_ id: UUID) -> PendingPermission? {
        guard let index = open.firstIndex(where: { $0.id == id }) else { return nil }
        return open.remove(at: index)
    }

    private mutating func removeExpired(_ request: ExpiredRequest, outcome: RequestOutcome, now: Date) {
        guard let index = expired.firstIndex(where: { $0.id == request.id }) else { return }
        expired.remove(at: index)
        let session = session(request.session)
        decisions.append(RequestDecision(
            id: request.id,
            at: now,
            project: request.project ?? session?.displayName,
            environment: session.map { WorkPhrases.environment($0.environment) },
            agentType: request.agentType,
            isMainAgent: request.agent == nil,
            brief: request.brief,
            outcome: outcome,
            place: .session,
            waited: request.deadline.timeIntervalSince(request.askedAt)
        ))
        answeredAt[request.session] = now
        trim()
    }

    private mutating func record(_ request: PendingPermission, outcome: RequestOutcome, place: RequestPlace, waited: TimeInterval, now: Date) {
        let session = session(request.session)
        decisions.append(RequestDecision(
            id: request.id,
            at: now,
            project: request.project ?? session?.displayName,
            environment: session.map { WorkPhrases.environment($0.environment) },
            agentType: request.agentType,
            isMainAgent: request.agent == nil,
            brief: RequestBrief(request),
            outcome: outcome,
            place: place,
            waited: waited
        ))
        answeredAt[request.session] = now
        trim()
    }

    private mutating func trim() {
        if decisions.count > Self.historyLimit { decisions.removeFirst(decisions.count - Self.historyLimit) }
    }

    #if DEBUG
    /// For looking at screens with made-up requests.
    public mutating func showForSnapshot(open: [PendingPermission], expired: [PendingPermission], decisions: [RequestDecision]) {
        self.open = open
        self.expired = expired.map(ExpiredRequest.init)
        self.decisions = decisions
    }
    #endif
}

/// The history in a file of its own. Losing it loses nothing but today's list.
public enum RequestLog {
    public static var url: URL { BorisPaths.support.appendingPathComponent("decisions.json") }

    public static func load(from url: URL = RequestLog.url) -> [RequestDecision] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([RequestDecision].self, from: data)) ?? []
    }

    /// Off the main thread, in order.
    public static func save(_ decisions: [RequestDecision], to url: URL = RequestLog.url) {
        queue.async {
            guard let data = try? JSONEncoder().encode(decisions) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Waits until queued writes are done, so nothing is lost on quit.
    public static func flush() {
        queue.sync {}
    }

    private static let queue = DispatchQueue(label: "app.boris.decisions", qos: .utility)
}
