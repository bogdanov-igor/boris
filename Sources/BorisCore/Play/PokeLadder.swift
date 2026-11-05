import Foundation

public enum PokeReaction: Sendable, Equatable {
    case squash, hoot, annoyed, turnAway, spin, credits, goToSleep, ignored
}

/// Counts pokes in a row and picks the walrus's response.
public struct PokeLadder: Sendable, Equatable {
    public static let resetAfter: TimeInterval = 30
    public static let turnAwayFor: TimeInterval = 10

    public private(set) var count = 0
    private var lastPoke: Date?
    private var turnedAwayUntil: Date?

    public init() {}

    /// - Parameters:
    ///   - restricted: the walrus is in alarm or waiting, so a poke may only squash it briefly.
    ///   - night: between midnight and 5 in the morning.
    public mutating func poke(now: Date, restricted: Bool = false, night: Bool = false) -> PokeReaction {
        if restricted { return .squash }
        if let turnedAwayUntil, now < turnedAwayUntil { return .ignored }
        if let lastPoke, now.timeIntervalSince(lastPoke) > Self.resetAfter { count = 0 }
        lastPoke = now
        count += 1
        switch count {
        case 3: return .hoot
        case 7: return .annoyed
        case 15:
            turnedAwayUntil = now.addingTimeInterval(Self.turnAwayFor)
            return .turnAway
        case 30: return .spin
        case 50:
            count = 0
            return .credits
        default:
            return night ? .goToSleep : .squash
        }
    }
}

/// Clean streaks and the trophy shelf.
public struct AwardTracker: Codable, Sendable, Equatable {
    public static let streakGoal = 10
    public static let fishGoal = 100

    public var cleanStreak: Int
    public var caught: Int
    public var partyDay: String?

    public init(cleanStreak: Int = 0, caught: Int = 0, partyDay: String? = nil) {
        self.cleanStreak = cleanStreak
        self.caught = caught
        self.partyDay = partyDay
    }

    public var hasFish: Bool { caught >= Self.fishGoal }

    public func hasParty(today: String) -> Bool { partyDay == today }

    public mutating func record(_ status: RunStatus, today: String) {
        guard status.isTerminal else { return }
        caught += 1
        switch status {
        case .completed:
            cleanStreak += 1
            if cleanStreak >= Self.streakGoal {
                cleanStreak = 0
                partyDay = today
            }
        case .stopped, .unknown:
            break
        default:
            cleanStreak = 0
        }
    }
}

/// What the walrus acts out in the open menu. The moods are not touched by any of this.
public enum Act: String, Sendable, Equatable, CaseIterable {
    case hoot, yawn, poke, annoyed, back, wink, spin, dizzy

    public var duration: TimeInterval {
        switch self {
        case .hoot: return 1.9
        case .yawn: return 2.4
        case .poke: return 0.6
        case .annoyed: return 3
        case .back: return PokeLadder.turnAwayFor
        case .wink: return 1.2
        case .spin: return 1.6
        case .dizzy: return 3
        }
    }

    /// The moment shown when movement is reduced.
    public var stillTime: Double {
        switch self {
        case .hoot, .dizzy: return 0.1
        case .yawn: return 0.5
        case .poke: return 0.06
        case .annoyed, .back: return 0.2
        case .wink: return 0.4
        case .spin: return 0.14
        }
    }
}

public enum PlayLine: Sendable, Equatable {
    case hoot, goToSleep, quietOn, quietOff
}

public enum PlayKey: Sendable, Equatable {
    case up, down, left, right
    case character(String)
}

/// The whole game in the open menu, as a function of pokes, keys and time.
public struct Play: Sendable, Equatable {
    public static let glassesFor: TimeInterval = 60
    public static let lineFor: TimeInterval = 2.5
    private static let konami: [PlayKey] = [.up, .up, .down, .down, .left, .right, .left, .right, .character("b"), .character("a")]

    public private(set) var ladder = PokeLadder()
    private var act: Act?
    private var actStart = Date.distantPast
    private var nextAct: Act?
    private var line: PlayLine?
    private var lineEnd = Date.distantPast
    private var glassesEnd = Date.distantPast
    private var keys: [PlayKey] = []
    /// A poke in alarm or waiting only squashes the pose that is already there.
    private var softPoke = false

    public init() {}

    /// Returns true when the credits should roll.
    public mutating func poke(now: Date, restricted: Bool, night: Bool, reduceMotion: Bool) -> Bool {
        switch ladder.poke(now: now, restricted: restricted, night: night) {
        case .squash:
            start(.poke, now: now, soft: restricted)
        case .goToSleep:
            start(.poke, now: now)
            say(.goToSleep, now: now)
        case .hoot:
            start(.hoot, now: now)
            say(.hoot, now: now)
        case .annoyed:
            start(.annoyed, now: now)
        case .turnAway:
            start(.back, now: now)
        case .spin:
            start(reduceMotion ? .dizzy : .spin, now: now)
            nextAct = reduceMotion ? nil : .dizzy
        case .credits:
            return true
        case .ignored:
            break
        }
        return false
    }

    public mutating func key(_ key: PlayKey, now: Date) {
        keys.append(Self.normalized(key))
        if keys.count > Self.konami.count { keys.removeFirst(keys.count - Self.konami.count) }
        if keys == Self.konami {
            glassesEnd = now.addingTimeInterval(Self.glassesFor)
            keys = []
        } else if keys.suffix(3) == [.character("у"), .character("г"), .character("у")] || keys.suffix(3) == [.character("u"), .character("g"), .character("u")] {
            start(.hoot, now: now)
            say(.hoot, now: now)
            keys = []
        }
    }

    public mutating func yawn(now: Date) {
        start(.yawn, now: now)
    }

    /// Plays a reaction on request, as the Walrus page does.
    public mutating func perform(_ act: Act, now: Date) {
        start(act, now: now)
    }

    public mutating func say(_ line: PlayLine, now: Date) {
        self.line = line
        lineEnd = now.addingTimeInterval(Self.lineFor)
    }

    /// The act on screen and how far along it is, from 0 to 1. `restricted` moods keep their pose, so only a soft poke remains.
    public func current(now: Date, restricted: Bool) -> (act: Act, t: Double)? {
        guard let running = act else { return nil }
        let elapsed = max(0, now.timeIntervalSince(actStart))
        if elapsed < running.duration {
            if restricted, running != .poke { return nil }
            return (running, elapsed / running.duration)
        }
        guard !restricted, let next = nextAct, elapsed < running.duration + next.duration else { return nil }
        return (next, (elapsed - running.duration) / next.duration)
    }

    /// The poke leaves the mood's own pose in place and only squashes it.
    public var isSoftPoke: Bool { softPoke && act == .poke }

    public func currentLine(now: Date) -> PlayLine? {
        now < lineEnd ? line : nil
    }

    public func wearsGlasses(now: Date) -> Bool {
        now < glassesEnd
    }

    private mutating func start(_ new: Act, now: Date, soft: Bool = false) {
        act = new
        actStart = now
        nextAct = nil
        softPoke = soft
    }

    /// Letters are compared in lower case. The B and A of the code sit on И and Ф in a Russian layout.
    private static func normalized(_ key: PlayKey) -> PlayKey {
        guard case .character(let text) = key else { return key }
        let lower = text.lowercased()
        switch lower {
        case "и": return .character("b")
        case "ф": return .character("a")
        default: return .character(lower)
        }
    }
}

/// Remembers a run that was going in the small hours, so the walrus can yawn in the morning.
public struct NightWatch: Codable, Sendable, Equatable {
    public var ranAtNight = false

    public init() {}

    public mutating func note(active: Bool, now: Date, calendar: Calendar = .current) {
        if active, calendar.component(.hour, from: now) < 5 { ranAtNight = true }
    }

    /// True once, on the first opening of the menu after the night.
    public mutating func shouldYawn(now: Date, calendar: Calendar = .current) -> Bool {
        guard ranAtNight, calendar.component(.hour, from: now) >= 5 else { return false }
        ranAtNight = false
        return true
    }
}
