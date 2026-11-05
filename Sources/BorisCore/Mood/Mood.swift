import Foundation

public enum Mood: Sendable, Equatable {
    case alarm, broken, waiting, tired, alert, happy, hmm
    case working(agents: Int)
    case sleeping
}

/// Holds event-driven moods and combines them with live state into the one mood to show.
public struct MoodBoard: Sendable, Equatable {
    public static let transientDuration: TimeInterval = 10
    public static let tiredLimit: TimeInterval = 6 * 3600

    public private(set) var alarms: Set<String> = []
    public private(set) var tiredSince: Date?
    private var transient: (mood: Mood, until: Date)?

    public init() {}

    public static func == (a: MoodBoard, b: MoodBoard) -> Bool {
        a.alarms == b.alarms && a.tiredSince == b.tiredSince && a.transient?.mood == b.transient?.mood && a.transient?.until == b.transient?.until
    }

    public mutating func apply(_ event: BorisEvent, reaction: MoodReaction, now: Date) {
        let until = now.addingTimeInterval(Self.transientDuration)
        switch reaction {
        case .none:
            break
        case .alarm:
            alarms.insert(event.id)
        case .tired:
            tiredSince = now
        case .happy:
            transient = (.happy, until)
        case .hmm:
            transient = (.hmm, until)
        case .alert:
            // Silence is shown from live state for as long as it lasts.
            if event.kind != .silent { transient = (.alert, until) }
        case .watching:
            if event.kind != .waiting { transient = (.waiting, until) }
        }
    }

    /// Opening the menu confirms the alarm and the tired walrus.
    public mutating func acknowledge() {
        alarms = []
        tiredSince = nil
    }

    public var hasAlarm: Bool { !alarms.isEmpty }

    public func mood(runs: [RunState], sessions: [SessionInfo], formatBroken: Bool, matrix: ReactionMatrix, now: Date) -> Mood {
        if hasAlarm { return .alarm }
        if formatBroken { return .broken }
        let waiting = sessions.contains { $0.status == "waiting" && WaitingReason($0.waitingFor) != .dialog }
        if waiting, matrix.reaction(for: .waiting).mood == .watching { return .waiting }
        if let tiredSince, now.timeIntervalSince(tiredSince) < Self.tiredLimit { return .tired }
        if runs.contains(where: { $0.status == .silent }), matrix.reaction(for: .silent).mood == .alert { return .alert }
        if let transient, now < transient.until { return transient.mood }
        let working = runs.filter(\.status.isActive)
        if !working.isEmpty {
            return .working(agents: working.reduce(0) { $0 + $1.running })
        }
        if sessions.contains(where: { $0.status == "busy" }) {
            return .working(agents: 0)
        }
        return .sleeping
    }
}
