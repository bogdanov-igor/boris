import Foundation

public enum MoodReaction: String, Codable, Sendable, CaseIterable {
    case none, happy, hmm, alert, tired, watching, alarm
}

public struct Reaction: Codable, Sendable, Equatable {
    public var banner: Bool
    public var sound: Bool
    public var mood: MoodReaction

    public init(banner: Bool, sound: Bool, mood: MoodReaction) {
        self.banner = banner
        self.sound = sound
        self.mood = mood
    }
}

/// Which reaction each event gets. Statuses never read this, so settings cannot change the facts.
public struct ReactionMatrix: Codable, Sendable, Equatable {
    public var overrides: [EventKind: Reaction]

    public init(overrides: [EventKind: Reaction] = [:]) {
        self.overrides = overrides
    }

    public static func defaultReaction(_ kind: EventKind) -> Reaction {
        switch kind {
        case .completed: return Reaction(banner: true, sound: false, mood: .happy)
        case .completedWithErrors, .allAgentsFailed, .failed, .interrupted: return Reaction(banner: true, sound: true, mood: .alarm)
        case .stopped: return Reaction(banner: true, sound: false, mood: .hmm)
        case .silent: return Reaction(banner: true, sound: false, mood: .alert)
        case .waiting: return Reaction(banner: true, sound: true, mood: .watching)
        case .sessionFinished: return Reaction(banner: true, sound: false, mood: .none)
        case .limitReached: return Reaction(banner: true, sound: true, mood: .tired)
        case .limitNear: return Reaction(banner: true, sound: false, mood: .none)
        case .sessionError: return Reaction(banner: true, sound: true, mood: .alert)
        }
    }

    public func reaction(for kind: EventKind) -> Reaction {
        overrides[kind] ?? Self.defaultReaction(kind)
    }

    public mutating func reset() {
        overrides = [:]
    }
}

/// Banners, sounds and the walrus's reactions off for a while. Statuses and requests keep working, and one summary comes at the end.
public struct QuietMode: Codable, Sendable, Equatable {
    public var until: Date?
    public var missed: [EventKind: Int]

    /// Longer than anyone leaves a Mac on: the way to say "until turned off" with an end date.
    public static let indefinitely: TimeInterval = 10 * 365 * 24 * 3600

    public init(until: Date? = nil, missed: [EventKind: Int] = [:]) {
        self.until = until
        self.missed = missed
    }

    public func isOn(now: Date) -> Bool {
        guard let until else { return false }
        return now < until
    }

    public mutating func start(for duration: TimeInterval, now: Date) {
        until = now.addingTimeInterval(duration)
        missed = [:]
    }

    /// Applies quiet mode to a reaction, remembering what the user would have seen.
    public mutating func filter(_ reaction: Reaction, kind: EventKind, now: Date) -> Reaction {
        guard isOn(now: now) else { return reaction }
        if reaction.banner || reaction.sound { missed[kind, default: 0] += 1 }
        return Reaction(banner: false, sound: false, mood: .none)
    }

    /// Returns the summary once quiet mode has just ended.
    public mutating func finish(now: Date) -> [EventKind: Int]? {
        guard let until, now >= until else { return nil }
        self.until = nil
        defer { missed = [:] }
        return missed.isEmpty ? nil : missed
    }

    /// Ends quiet mode at the user's request. "Until turned off" ends in no other way, so what was missed is told here too.
    @discardableResult
    public mutating func cancel() -> [EventKind: Int]? {
        defer {
            until = nil
            missed = [:]
        }
        return missed.isEmpty ? nil : missed
    }
}
