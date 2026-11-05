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

    /// The one mood to show, by the order in the spec: alarm, broken, waiting, tired, alert, happy or hmm, working, sleeping.
    /// - Parameter limitPercent: from here on a limit counts as nearly spent.
    public func mood(work: WorkModel, usage: UsageSnapshot? = nil, limitPercent: Double = 95, broken: Bool, matrix: ReactionMatrix, now: Date) -> Mood {
        if hasAlarm { return .alarm }
        if broken { return .broken }
        if !work.waitingSessions.isEmpty, matrix.reaction(for: .waiting).mood == .watching { return .waiting }
        if isTired(usage: usage, limitPercent: limitPercent, matrix: matrix, now: now) { return .tired }
        let silent = work.sessions.contains { $0.root.flattened.contains { $0.state == .silent } }
        if silent, matrix.reaction(for: .silent).mood == .alert { return .alert }
        if let transient, now < transient.until { return transient.mood }
        if work.sessions.contains(where: { $0.state == .running || $0.state == .silent }) {
            return .working(agents: work.workingAgents)
        }
        return .sleeping
    }

    /// A limit that ran out is an event, one that is nearly spent is a fact that lasts until the window resets. Spare money is not a limit.
    private func isTired(usage: UsageSnapshot?, limitPercent: Double, matrix: ReactionMatrix, now: Date) -> Bool {
        if let tiredSince, now.timeIntervalSince(tiredSince) < Self.tiredLimit { return true }
        guard matrix.reaction(for: .limitReached).mood == .tired, let usage else { return false }
        return usage.windows.contains { window in
            window.kind != .extraSpend && window.percent >= limitPercent && (window.resetsAt.map { $0 > now } ?? true)
        }
    }
}
