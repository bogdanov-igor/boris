import Foundation

/// What one look at Claude Desktop showed. Nothing read from its window goes further than this.
public enum ChatLook: Sendable, Equatable {
    case noPermission
    case appClosed
    /// The person can see it for themselves, so its window was left alone.
    case inFront
    case answering
    case notAnswering
    /// The window said nothing this time, which says nothing about the answer either.
    case cannotSee
}

/// How plain chat is connected, for the section «Sources».
public enum ChatConnection: Sendable, Equatable {
    /// No consent: Boris does not touch Claude Desktop's window.
    case notConnected
    case needsPermission
    case appClosed
    case cannotSee
    case connected
}

/// The button that stops an answer. It is on screen exactly while an answer is being written, and it is the only thing Boris looks for.
public enum ChatStopButton {
    /// Claude's interface comes in several languages, and only these are known. In any other Boris just never sees an answer being written.
    private static let labels: Set<String> = ["stop response", "stop generating", "остановить ответ", "остановить генерацию"]

    public static func matches(_ label: String?) -> Bool {
        guard let label else { return false }
        return labels.contains(label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
}

/// Follows the looks and says when an answer has become ready while the person was elsewhere.
public struct ChatTracker: Sendable, Equatable {
    public static let sessionId = "claude-chat"
    /// One empty look can be the button being redrawn, and a false «ready» is worse than a late one.
    private static let quietLooksForReady = 2
    /// How long an answer stays «being written» with nothing to see.
    private static let blindLimit: TimeInterval = 30

    public private(set) var connection = ChatConnection.notConnected
    public private(set) var answeringSince: Date?
    public private(set) var readyAt: Date?
    private var quietLooks = 0
    private var lastSeenAnswering: Date?

    public init() {}

    /// - Returns: true when an answer has just become ready.
    public mutating func note(_ look: ChatLook, now: Date) -> Bool {
        switch look {
        case .noPermission:
            connection = .needsPermission
            forget()
        case .appClosed:
            connection = .appClosed
            forget()
        case .inFront:
            connection = .connected
            forget()
        case .answering:
            connection = .connected
            if answeringSince == nil { answeringSince = now }
            lastSeenAnswering = now
            quietLooks = 0
            readyAt = nil
        case .notAnswering:
            connection = .connected
            guard answeringSince != nil else { break }
            quietLooks += 1
            guard quietLooks >= Self.quietLooksForReady else { break }
            forget()
            readyAt = now
            return true
        case .cannotSee:
            connection = .cannotSee
            if let seen = lastSeenAnswering, now.timeIntervalSince(seen) > Self.blindLimit { forget() }
        }
        return false
    }

    public mutating func turnOff() {
        connection = .notConnected
        forget()
    }

    private mutating func forget() {
        answeringSince = nil
        lastSeenAnswering = nil
        quietLooks = 0
        readyAt = nil
    }

    /// Chat counts as a session only while there is something to tell. It has no tokens, actions or text to show.
    public var session: WorkSession? {
        let state: WorkState
        if answeringSince != nil {
            state = .running
        } else if readyAt != nil {
            state = .finished
        } else {
            return nil
        }
        let moment = answeringSince ?? readyAt
        return WorkSession(id: Self.sessionId, environment: .chat, state: state, startedAt: moment, lastActivity: readyAt ?? moment, root: WorkNode(id: Self.sessionId, kind: .main, state: state))
    }

    /// What a page about chat shows once the person has seen the answer and the session has gone.
    public static var seenSession: WorkSession {
        WorkSession(id: sessionId, environment: .chat, state: .finished, root: WorkNode(id: sessionId, kind: .main, state: .finished))
    }

    /// Goes the way of the other events, and carries no text of the answer.
    public static func readyEvent(at date: Date) -> BorisEvent {
        BorisEvent(id: "chat|\(Int(date.timeIntervalSince1970))", kind: .sessionFinished, at: date, sessionId: sessionId, environment: .chat)
    }
}

extension WorkModel {
    /// The work with this chat in place of the one it had. A chat has no folder, so it goes with the sessions without a project.
    public func withChat(_ chat: WorkSession?) -> WorkModel {
        var projects = self.projects.compactMap { project -> WorkProject? in
            guard project.sessions.contains(where: { $0.environment == .chat }) else { return project }
            let rest = project.sessions.filter { $0.environment != .chat }
            return rest.isEmpty ? nil : WorkProject(path: project.path, sessions: rest)
        }
        if let chat {
            if let index = projects.firstIndex(where: { $0.path == nil }) {
                projects[index].sessions.append(chat)
            } else {
                projects.append(WorkProject(path: nil, sessions: [chat]))
            }
        }
        return WorkModel(projects: projects)
    }
}
