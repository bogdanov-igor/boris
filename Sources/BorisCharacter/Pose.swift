import CoreGraphics
import BorisCore

/// The drawn states. `watch` is not a mood: it is the base look for the wardrobe and the About window.
public enum PoseName: String, CaseIterable, Sendable {
    case watch, work, happy, alarm, sleep, wait, limit, broken, alert, stopped

    public init(mood: Mood) {
        switch mood {
        case .sleeping: self = .sleep
        case .working: self = .work
        case .happy: self = .happy
        case .hmm: self = .stopped
        case .alert: self = .alert
        case .tired: self = .limit
        case .waiting: self = .wait
        case .broken: self = .broken
        case .alarm: self = .alarm
        }
    }

    /// The most telling moment of the loop, used wherever nothing moves.
    public var keyTime: CGFloat {
        switch self {
        case .watch, .wait, .broken, .stopped: return 0.1
        case .work, .happy, .alert: return 0.25
        case .alarm: return 0.7
        case .sleep: return 0.5
        case .limit: return 0.2
        }
    }

    /// Moods that can last for hours stay still in the menu bar, so they cost nothing.
    public var movesInMenuBar: Bool {
        switch self {
        case .work, .happy, .alarm, .alert, .stopped: return true
        case .watch, .sleep, .wait, .limit, .broken: return false
        }
    }

    /// Eyes open and calm enough to blink.
    public var blinks: Bool {
        switch self {
        case .watch, .work, .wait, .alert, .stopped: return true
        case .happy, .alarm, .sleep, .limit, .broken: return false
        }
    }
}

public enum Eye: Sendable, Equatable {
    case open, lid, tired, wide, closed, happy, dizzy, small, big, heart, squint
}

/// `fish` is the reward for a hundred caught finishes: it takes the cigar's place.
public enum Cigar: Sendable, Equatable {
    case flat, up, droop, fish
}

public enum Monocle: Sendable, Equatable {
    case worn, popped, none, pixel
}

/// Hats that replace the bowler. The flower is worn on the bowler.
public enum Headwear: Sendable, Equatable {
    case santa, witch, party, scholar, nightcap, flower
}

public enum Effect: Sendable, Equatable {
    case bang(x: CGFloat, y: CGFloat)
    case zed(x: CGFloat, y: CGFloat, size: CGFloat, opacity: CGFloat)
    case question(x: CGFloat, y: CGFloat)
    case drop(x: CGFloat, y: CGFloat)
    case star(x: CGFloat, y: CGFloat, radius: CGFloat)
    case sound(phase: CGFloat)
}

public struct Hat: Sendable, Equatable {
    public var x, y, tilt: CGFloat

    public init(_ x: CGFloat, _ y: CGFloat, _ tilt: CGFloat) {
        self.x = x
        self.y = y
        self.tilt = tilt
    }
}

public struct Brow: Sendable, Equatable {
    public var lift, rotation: CGFloat

    public init(_ lift: CGFloat, _ rotation: CGFloat) {
        self.lift = lift
        self.rotation = rotation
    }
}

/// A pose of the full drawing, in its 240-wide grid.
public struct Pose: Sendable, Equatable {
    public var eyeLeft = Eye.open
    public var eyeRight = Eye.lid
    public var look = CGPoint.zero
    public var browLeft = Brow(6, -4)
    public var browRight = Brow(-1, 14)
    public var jaw: CGFloat = 0
    public var smile: CGFloat = 0
    public var lift: CGFloat = 0
    public var cigar: Cigar? = .flat
    public var smoke: CGFloat?
    public var lit = true
    public var droppedCigar: Hat?
    public var hat = Hat(126, 18, 9)
    public var monocle = Monocle.worn
    public var swing: CGFloat = 0
    public var bob: CGFloat = 0
    public var tilt: CGFloat = 0
    public var squash = CGSize(width: 1, height: 1)
    public var effects: [Effect] = []
    public var headwear: Headwear?
    /// Friday the 13th: nearly black, with the moustache and tusks glowing faintly.
    public var crow = false
    /// A three-quarter view, from -1 to 1.
    public var turn: CGFloat = 0
    /// He has turned his back on you.
    public var back = false
    public var upsideDown = false

    public init() {}
}

/// A pose of the simplified drawing, in its 84x72 grid. Its proportions are tuned by hand, so it is not a scaled full pose.
public struct SimplePose: Sendable, Equatable {
    public var eyeLeft = Eye.open
    public var eyeRight = Eye.lid
    public var look = CGPoint.zero
    public var jaw: CGFloat = 0
    public var smile: CGFloat = 0
    public var lift: CGFloat = 0
    public var cigar: Cigar? = .flat
    public var smoke: CGFloat?
    public var hat = Hat(0, 0, 7)
    public var bob: CGFloat = 0
    public var tilt: CGFloat = 0
    public var ring = true
    public var popped = false
    public var headwear: Headwear?
    public var glasses = false
    public var crow = false

    public init() {}
}
