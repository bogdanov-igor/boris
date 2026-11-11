import BorisCore
import CoreGraphics
import Foundation

/// How he stands while he moves: upright, or leaning up to ten degrees to the left or the right. He does not rock.
/// Now and then he picks a new lean at random, turns to it quickly or slowly, and holds it for a few seconds.
/// The random source is seeded, so one seed always gives the same walrus.
public struct Lean: Sendable {
    /// Degrees to either side.
    public static let most: CGFloat = 10
    /// The smallest lean, and the smallest turn, worth making, in degrees.
    static let least = 3
    /// Seconds a turn takes.
    public static let quick: ClosedRange<TimeInterval> = 0.25...0.5
    public static let slow: ClosedRange<TimeInterval> = 1.2...2.4
    /// Seconds he holds where he has turned to, upright included.
    public static let hold: ClosedRange<TimeInterval> = 3...10
    /// After a longer pause, such as while nobody could see him, he goes on from where he stood instead of catching up.
    static let pause: TimeInterval = 30

    /// One turn and the hold after it, in seconds since he started.
    public struct Move: Sendable, Equatable {
        public var from, to: CGFloat
        public var start, turn, hold: TimeInterval

        public var end: TimeInterval { start + turn + hold }

        /// He sets off gently and settles gently.
        func degrees(at time: TimeInterval) -> CGFloat {
            guard turn > 0 else { return to }
            let k = CGFloat(min(max((time - start) / turn, 0), 1))
            return from + (to - from) * k * k * (3 - 2 * k)
        }
    }

    public private(set) var move: Move
    private var random: SplitMix

    /// He starts upright and stays so for a few seconds.
    public init(seed: UInt64) {
        var random = SplitMix(seed: seed)
        move = Move(from: 0, to: 0, start: 0, turn: 0, hold: .random(in: Self.hold, using: &random))
        self.random = random
    }

    /// His lean `elapsed` seconds after he started, to half a degree so that pictures can be kept. Time only goes forward.
    /// `moving` is false for a walrus that stands still, cannot be seen or must not move because of Reduce Motion:
    /// he is then upright, and his lean does not change.
    public mutating func degrees(at elapsed: TimeInterval, moving: Bool) -> CGFloat {
        guard moving else { return 0 }
        while elapsed >= move.end { next(after: elapsed) }
        return (move.degrees(at: elapsed) * 2).rounded() / 2
    }

    private mutating func next(after elapsed: TimeInterval) {
        let quick = Bool.random(using: &random)
        let to = target(after: move.to)
        move = Move(
            from: move.to,
            to: to,
            start: elapsed - move.end > Self.pause ? elapsed : move.end,
            turn: .random(in: quick ? Self.quick : Self.slow, using: &random),
            hold: .random(in: Self.hold, using: &random)
        )
    }

    /// From upright he always leans; from a lean he straightens up half the time. So every third hold or so is upright.
    private mutating func target(after current: CGFloat) -> CGFloat {
        if current != 0, Bool.random(using: &random) { return 0 }
        let leans = (Self.least...Int(Self.most)).flatMap { [CGFloat($0), -CGFloat($0)] }
        return leans.filter { abs($0 - current) >= CGFloat(Self.least) }.randomElement(using: &random) ?? 0
    }
}

/// SplitMix64: small, fast and the same on every Mac for the same seed.
struct SplitMix: RandomNumberGenerator, Sendable {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

extension PoseName {
    /// He stands upright here, so he leans now and then. The rest have a tilt of their own, tremble, jump or lie down.
    public var leans: Bool {
        switch self {
        case .watch, .work, .broken: return true
        case .happy, .alarm, .sleep, .wait, .limit, .alert, .stopped: return false
        }
    }
}

extension Act {
    /// A reaction with no posture of its own plays in his current lean, so he does not jump upright for it.
    /// Sulking, turning away and spinning set their own.
    var keepsLean: Bool {
        switch self {
        case .hoot, .yawn, .poke, .wink, .dizzy: return true
        case .annoyed, .back, .spin: return false
        }
    }
}
