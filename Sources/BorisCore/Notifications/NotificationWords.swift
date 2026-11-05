import Foundation

/// Where a click on a notification leads.
public enum NotificationRoute: Sendable, Equatable {
    case now, usage
    case session(String)
    case requests(session: String?)

    public var userInfo: [String: String] {
        switch self {
        case .now: return ["route": "now"]
        case .usage: return ["route": "usage"]
        case .session(let id): return ["route": "session", "session": id]
        case .requests(let id?): return ["route": "requests", "session": id]
        case .requests(nil): return ["route": "requests"]
        }
    }

    public init?(userInfo: [AnyHashable: Any]) {
        let session = userInfo["session"] as? String
        switch userInfo["route"] as? String {
        case "now": self = .now
        case "usage": self = .usage
        case "requests": self = .requests(session: session)
        case "session":
            guard let session else { return nil }
            self = .session(session)
        default: return nil
        }
    }
}

public struct MacBanner: Sendable, Equatable {
    public var id: String
    public var title: String
    public var body: String
    public var route: NotificationRoute

    public init(id: String, title: String, body: String, route: NotificationRoute) {
        self.id = id
        self.title = title
        self.body = body
        self.route = route
    }
}

/// One Telegram message: who it is about, in bold, and what happened.
public struct TelegramLine: Sendable, Equatable {
    public var subject: String
    public var text: String

    public init(subject: String, text: String) {
        self.subject = subject
        self.text = text
    }

    public var full: String { "\(subject) · \(text)" }
}

/// The texts of notifications. Only the project and the event get here, whatever else a session holds:
/// no commands, prompts, paths, tool names or titles, and the same text in both display modes.
public enum NotificationWords {
    /// The folder's name, never the path to it.
    private static func project(_ event: BorisEvent) -> String? {
        guard let project = event.project, !project.isEmpty else { return nil }
        return URL(fileURLWithPath: project).lastPathComponent
    }

    /// A remote machine's name stays on this Mac.
    private static func place(_ event: BorisEvent, forTelegram: Bool) -> String? {
        guard let environment = event.environment else { return nil }
        if forTelegram, case .remote = environment { return nil }
        return WorkPhrases.environment(environment)
    }

    private static func subject(_ event: BorisEvent) -> String {
        project(event) ?? place(event, forTelegram: true) ?? "Claude"
    }

    private static func capitalized(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }

    /// The event itself, as it follows the name of the project.
    private static func phrase(_ event: BorisEvent) -> String {
        switch event.kind {
        case .waiting:
            switch NotificationTopic(event) {
            case .plan: return L("plan is ready")
            case .question: return L("asks a question")
            default: return L("waiting for permission")
            }
        case .completed, .sessionFinished: return L("work done")
        case .completedWithErrors: return L("work done with errors")
        case .allAgentsFailed: return L("all agents failed")
        case .failed: return L("work failed")
        case .sessionError: return L("session error")
        case .stopped: return L("work stopped")
        case .interrupted: return L("work interrupted")
        case .silent: return L("silent for a long time")
        case .limitReached: return L("the limit ran out")
        case .limitNear: return L("limit is close")
        }
    }

    private static func reason(_ failure: FailureClass) -> String {
        switch failure {
        case .limit: return L("the limit ran out")
        case .network: return L("no connection to Claude")
        case .sleep: return L("the Mac fell asleep")
        case .stall: return L("the task got stuck")
        case .api: return L("Claude had an error")
        case .unknown: return L("reason unknown")
        }
    }

    private static func failedAgents(_ count: Int) -> String {
        count == 1 ? L("%lld agent failed", count) : L("%lld agents failed", count)
    }

    /// Reset time as Claude wrote it. Anything longer than a time is not one.
    private static func resets(_ event: BorisEvent) -> String? {
        guard let resets = event.resets, resets.count <= 40, !resets.contains("\n") else { return nil }
        return L("Resets at %@", resets)
    }

    private static func window(_ id: String?) -> String? {
        guard let id else { return nil }
        if id.hasPrefix("five_hour") { return L("5-hour window") }
        if id.hasPrefix("seven_day") { return L("weekly window") }
        return nil
    }

    private static func detail(_ parts: [String?]) -> String {
        parts.compactMap { $0 }.joined(separator: " · ")
    }

    private static func requestBody(_ event: BorisEvent) -> String {
        let want: String
        switch NotificationTopic(event) {
        case .plan:
            want = L("Claude has a plan and waits for your decision")
        case .question:
            want = L("Claude is waiting for your answer")
        default:
            switch event.toolName.map(StepKind.init(tool:)) {
            case .shell?: want = L("Claude wants to run a command")
            case .edit?, .write?: want = L("Claude wants to change a file")
            default: want = L("Claude asks for permission")
            }
        }
        return detail([want, place(event, forTelegram: false)])
    }

    private static func body(_ event: BorisEvent) -> String {
        switch event.kind {
        case .waiting:
            return requestBody(event)
        case .completed, .sessionFinished:
            let agents = event.agentsTotal.flatMap { $0 > 1 ? WorkPhrases.agents($0) : nil }
            let took = event.durationMs.map { L("took %@", WorkFormat.duration(Double($0) / 1000)) }
            return detail([agents, took].map { $0.map(capitalized) })
        case .completedWithErrors, .allAgentsFailed, .failed:
            let count: String?
            if let failed = event.agentsFailed, let total = event.agentsTotal, total > 1 {
                count = L("%lld of %lld failed", failed, total)
            } else {
                count = nil
            }
            return detail([count, event.topFailure.map(reason)].map { $0.map(capitalized) })
        case .sessionError:
            return place(event, forTelegram: false) ?? ""
        case .stopped, .interrupted:
            return L("Open to see where the work stopped.")
        case .silent:
            return L("No news for a while.")
        case .limitReached:
            let parts = [project(event), resets(event)].compactMap { $0 }
            return parts.isEmpty ? "" : parts.joined(separator: ". ") + "."
        case .limitNear:
            return window(event.windowId).map(capitalized) ?? ""
        }
    }

    private static func route(_ event: BorisEvent) -> NotificationRoute {
        if event.kind == .waiting { return .requests(session: event.sessionId) }
        if event.kind == .limitReached || event.kind == .limitNear { return .usage }
        return event.sessionId.map(NotificationRoute.session) ?? .now
    }

    public static func banner(_ event: BorisEvent) -> MacBanner {
        let title: String
        switch event.kind {
        case .limitReached:
            let agents = event.agentsFailed ?? 0
            title = agents > 1 ? "\(capitalized(phrase(event))) · \(failedAgents(agents))" : capitalized(phrase(event))
        case .limitNear:
            title = detail([capitalized(phrase(event)), event.percent.map(WorkFormat.percent)])
        default:
            title = "\(subject(event)) · \(phrase(event))"
        }
        return MacBanner(id: event.id, title: title, body: body(event), route: route(event))
    }

    public static func telegram(_ event: BorisEvent) -> TelegramLine {
        var text = phrase(event)
        switch event.kind {
        case .waiting:
            if let place = place(event, forTelegram: true) { text += " (\(place))" }
        case .completedWithErrors, .allAgentsFailed, .failed:
            if let failure = event.topFailure { text += ": \(reason(failure))" }
        case .limitReached:
            if let agents = event.agentsFailed, agents > 1 { text += ", \(failedAgents(agents))" }
            if let resets = resets(event) { text += ". \(resets)" }
        case .limitNear:
            text = detail([text, event.percent.map(WorkFormat.percent), window(event.windowId)])
        default:
            break
        }
        return TelegramLine(subject: subject(event), text: text)
    }

    /// A few names and how many more there are.
    static func names(_ names: [String]) -> String {
        guard names.count > 3 else {
            guard let last = names.last else { return "" }
            return names.count == 1 ? last : L("%@ and %@", names.dropLast().joined(separator: ", "), last)
        }
        return L("%@ and %lld more", names.prefix(3).joined(separator: ", "), names.count - 3)
    }

    /// How a burst of one kind of event is called.
    private static func waveTitle(_ topic: NotificationTopic, count: Int) -> String {
        switch topic {
        case .permission: return L("Requests for permission: %lld", count)
        case .question: return L("Questions from Claude: %lld", count)
        case .plan: return L("Plans ready: %lld", count)
        case .finished: return L("Work finished: %lld", count)
        case .failure: return L("Failures: %lld", count)
        case .interrupted: return L("Work interrupted: %lld", count)
        case .silence: return L("Silent for a long time: %lld", count)
        case .limitNear: return L("Limits close: %lld", count)
        }
    }

    static func waveBanner(_ topic: NotificationTopic, count: Int, projects: [String]) -> MacBanner {
        let isRequest = topic == .permission || topic == .question || topic == .plan
        return MacBanner(id: "boris.wave.\(topic.rawValue)", title: waveTitle(topic, count: count), body: names(projects), route: isRequest ? .requests(session: nil) : .now)
    }

    static func waveTelegram(_ topic: NotificationTopic, count: Int, projects: [String]) -> TelegramLine {
        let title = waveTitle(topic, count: count)
        return TelegramLine(subject: "Boris", text: projects.isEmpty ? title : "\(title). \(names(projects))")
    }

    /// `прервались 2 сессии: boris и deploy-tools`
    private static func awayDetail(sessions: Int, projects: [String]) -> String {
        let count = sessions == 1 ? L("%lld session was interrupted", sessions) : L("%lld sessions were interrupted", sessions)
        return projects.isEmpty ? count : "\(count): \(names(projects))"
    }

    /// The title is short, because the system cuts a long one where the number would be.
    static func awayBanner(sessions: [String?], projects: [String]) -> MacBanner {
        var route = NotificationRoute.now
        if sessions.count == 1, let session = sessions[0] { route = .session(session) }
        let detail = capitalized(awayDetail(sessions: sessions.count, projects: projects))
        return MacBanner(id: "boris.away", title: L("While Boris was closed"), body: "\(detail). \(L("Open to see where the work stopped."))", route: route)
    }

    static func awayTelegram(sessions: Int, projects: [String]) -> TelegramLine {
        TelegramLine(subject: "Boris", text: L("while Boris was closed, %@", awayDetail(sessions: sessions, projects: projects)))
    }

    /// `3 запроса, 1 сбой, 2 завершения. 1 запрос всё ещё ждёт.`
    public static func quietSummary(missed: [EventKind: Int], requestsWaiting: Int) -> MacBanner {
        func total(_ kinds: EventKind...) -> Int { kinds.reduce(0) { $0 + (missed[$1] ?? 0) } }
        var parts: [String] = []
        let requests = total(.waiting)
        if requests > 0 { parts.append(requests == 1 ? L("%lld request", requests) : L("%lld requests", requests)) }
        let failures = total(.completedWithErrors, .allAgentsFailed, .failed, .sessionError, .limitReached)
        if failures > 0 { parts.append(failures == 1 ? L("%lld failure", failures) : L("%lld failures", failures)) }
        let finished = total(.completed, .sessionFinished)
        if finished > 0 { parts.append(L("%lld finished", finished)) }
        let interrupted = total(.stopped, .interrupted)
        if interrupted > 0 { parts.append(L("%lld interrupted", interrupted)) }
        let silent = total(.silent)
        if silent > 0 { parts.append(L("%lld went silent", silent)) }
        let limits = total(.limitNear)
        if limits > 0 { parts.append(limits == 1 ? L("%lld limit warning", limits) : L("%lld limit warnings", limits)) }

        var body = parts.joined(separator: ", ")
        if !body.isEmpty { body += "." }
        if requestsWaiting > 0 {
            let waiting = requestsWaiting == 1 ? L("%lld request is still waiting.", requestsWaiting) : L("%lld requests are still waiting.", requestsWaiting)
            body += body.isEmpty ? waiting : " \(waiting)"
        }
        return MacBanner(id: "boris.quiet", title: L("While Do not disturb was on"), body: body, route: requestsWaiting > 0 ? .requests(session: nil) : .now)
    }

    /// The first message to a new bot.
    public static var telegramTest: TelegramLine {
        TelegramLine(subject: "Boris", text: L("the bot is connected, this is a test"))
    }
}
