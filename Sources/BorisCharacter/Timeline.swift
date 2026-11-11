import CoreGraphics
import Foundation
import BorisCore

/// Each state is a pure function of time. `t` runs from 0 to 1 over one loop.
/// No state rocks from side to side: a tilt is either the pose's own and stays put, or his lean, which `Lean` decides.
public enum Timeline {
    private static let tau = 2 * CGFloat.pi

    public static let framesPerLoop = 24
    public static let fastestWorkLoop: TimeInterval = 1

    /// Seconds per loop. Work speeds up with the number of agents, up to a limit.
    public static func loop(for mood: Mood) -> TimeInterval {
        switch mood {
        case .working(let agents):
            let speedup = 1 + 0.35 * log2(Double(max(agents, 1)))
            return max(2.4 / speedup, fastestWorkLoop)
        default:
            return 1.92
        }
    }

    /// A short blink every few seconds, for the big drawing.
    public static func isBlinking(elapsed: TimeInterval) -> Bool {
        elapsed.truncatingRemainder(dividingBy: 5.3) > 5.14
    }

    /// `firstLoop` is false once a one-time move has played: the cigar that fell stays on the floor.
    public static func full(_ name: PoseName, t: CGFloat, firstLoop: Bool = true) -> Pose {
        var pose = Pose()
        let s = sin(tau * t)
        switch name {
        case .watch:
            let blink = t > 0.78 && t < 0.84
            let twitch = t > 0.3 && t < 0.55 ? sin(tau * t * 2) : 0
            pose.smoke = t
            pose.bob = s * 1.5
            if blink {
                pose.eyeLeft = .closed
                pose.eyeRight = .closed
            }
            pose.smile = 0.08 * twitch
            pose.browLeft = Brow(6 + 2 * twitch, -4)
        case .work:
            pose.look = CGPoint(x: 6 * s, y: 0)
            pose.smoke = (t * 2).truncatingRemainder(dividingBy: 1)
            pose.browRight = Brow(1 + s, 12)
            pose.smile = 0.06 * sin(tau * t * 4)
        case .happy:
            let jump = abs(s)
            pose.eyeLeft = .happy
            pose.eyeRight = .happy
            pose.smile = 1
            pose.lift = -3
            pose.cigar = .up
            pose.smoke = t
            pose.browLeft = Brow(9, -6)
            pose.browRight = Brow(9, -6)
            pose.bob = -16 * jump
            if jump < 0.22 { pose.squash = CGSize(width: 1.04, height: 0.96) }
            pose.hat = Hat(126, 18 - 24 * jump, 9 + 18 * s)
        case .alarm:
            let jitter: CGFloat = Int(t * 36) % 2 == 1 ? 2.2 : -2.2
            let fall = firstLoop ? min(1, t / 0.45) : 1
            pose.eyeLeft = .wide
            pose.eyeRight = .wide
            pose.jaw = 1
            pose.smile = 0.7
            pose.lift = -7
            pose.cigar = nil
            pose.browLeft = Brow(11, -6)
            pose.browRight = Brow(17, -6)
            pose.tilt = jitter
            pose.hat = Hat(126, -4 + 4 * sin(tau * t * 2), -7)
            pose.monocle = .popped
            pose.swing = sin(tau * t * 1.5)
            pose.droppedCigar = fall < 1 ? Hat(150, 170 + 62 * fall * fall, 10 + 150 * fall) : Hat(178, 234, 6)
            if Int(t * 8) % 2 == 0 { pose.effects = [.bang(x: 214, y: 8)] }
        case .sleep:
            let breath = (1 - cos(tau * t)) / 2
            pose.eyeLeft = .closed
            pose.eyeRight = .closed
            pose.jaw = 0.22 * breath
            pose.lift = -3 * breath
            pose.smile = -0.12
            pose.browLeft = Brow(-3, 8)
            pose.browRight = Brow(-3, 8)
            pose.cigar = .droop
            pose.lit = false
            pose.bob = 2 * breath
            pose.hat = Hat(112, 42 + breath * 2, -8)
            let zeds: [(CGFloat, CGFloat, CGFloat)] = [(186, 58, 16), (204, 34, 20), (226, 6, 24)]
            pose.effects = zeds.enumerated().map { index, zed in
                let f = (t + CGFloat(index) / 3).truncatingRemainder(dividingBy: 1)
                return .zed(x: zed.0 + f * 8, y: zed.1 - f * 10, size: zed.2, opacity: min(1, f * 3) * (1 - f * 0.5))
            }
        case .wait:
            pose.eyeRight = .open
            pose.look = CGPoint(x: 0, y: 1)
            pose.browLeft = Brow(9 + 3 * max(0, s), -6)
            pose.browRight = Brow(0, 4)
            pose.tilt = -4
            pose.smoke = t
            if t.truncatingRemainder(dividingBy: 0.5) < 0.36 { pose.effects = [.question(x: 214, y: 46)] }
        case .limit:
            pose.eyeLeft = .tired
            pose.eyeRight = .tired
            pose.look = CGPoint(x: 0, y: 3)
            pose.smile = -0.9
            pose.lift = 3
            pose.browLeft = Brow(-3, 12)
            pose.browRight = Brow(-3, 12)
            pose.cigar = .droop
            pose.lit = false
            pose.bob = 4 + 1.5 * s
            pose.hat = Hat(120, 28, 15)
            pose.effects = [.drop(x: 206, y: 70 + (t * 2).truncatingRemainder(dividingBy: 1) * 46)]
        case .broken:
            pose.eyeLeft = .dizzy
            pose.eyeRight = .dizzy
            pose.monocle = .none
            pose.cigar = .droop
            pose.lit = false
            pose.smile = -0.25
            pose.hat = Hat(130, 14, 24)
            pose.browLeft = Brow(8, -6)
            pose.browRight = Brow(8, -6)
            pose.effects = (0..<3).map { index in
                let a = tau * (t + CGFloat(index) / 3)
                return .star(x: 120 + cos(a) * 92, y: 16 + sin(a) * 16, radius: 11)
            }
        case .alert:
            pose.eyeRight = .open
            pose.look = CGPoint(x: 5 * s, y: 0)
            pose.tilt = -8
            pose.browRight = Brow(10, -6)
            pose.hat = Hat(122, 18, 2)
        case .stopped:
            pose.eyeRight = .open
            pose.tilt = 7
            pose.browLeft = Brow(0, 8)
            pose.browRight = Brow(14, -8)
            pose.smile = 0.2 * s
            pose.hat = Hat(132, 16, 14)
        }
        return pose
    }

    /// A play reaction, which replaces the mood's pose for as long as it lasts.
    public static func act(_ act: Act, t: CGFloat) -> Pose {
        var pose = Pose()
        switch act {
        case .hoot:
            pose.eyeLeft = .closed
            pose.eyeRight = .closed
            pose.jaw = 0.3 + 0.12 * sin(tau * t * 2)
            pose.cigar = nil
            pose.lift = -4
            pose.smile = 0.35
            pose.browLeft = Brow(9, -4)
            pose.browRight = Brow(9, -4)
            pose.hat = Hat(126, 16, 9)
            pose.effects = [.sound(phase: t)]
        case .yawn:
            let e = sin(CGFloat.pi * t) * sin(CGFloat.pi * t)
            pose.eyeLeft = .closed
            pose.eyeRight = .closed
            pose.jaw = 1.5 * e
            pose.cigar = nil
            pose.lift = -7 * e
            pose.smile = 0.55 * e
            pose.browLeft = Brow(5 * e - 2, 8)
            pose.browRight = Brow(5 * e - 2, 8)
            pose.hat = Hat(126, 18 - 7 * e, 9 - 14 * e)
            pose.bob = 2 * e
        case .poke:
            let k = squashAmount(t)
            let hard = k > 0.25
            pose.eyeLeft = hard ? .squint : .open
            pose.eyeRight = hard ? .squint : .lid
            pose.cigar = hard ? .up : .flat
            pose.squash = CGSize(width: 1 + 0.15 * k, height: 1 - 0.17 * k)
            pose.hat = Hat(126, 18 + 3 * k, 9 + 6 * k)
        case .annoyed:
            pose.eyeLeft = .lid
            pose.eyeRight = .lid
            pose.look = CGPoint(x: 7, y: 0)
            pose.tilt = -5
            pose.browLeft = Brow(-2, 12)
            pose.browRight = Brow(-2, 14)
            pose.smile = -0.2
            pose.smoke = t
            pose.hat = Hat(124, 19, 13)
        case .back:
            pose.back = true
            pose.smoke = t
            pose.bob = 1.2 * sin(tau * t)
        case .wink:
            let on = t > 0.2 && t < 0.7
            pose.eyeRight = on ? .happy : .lid
            pose.smile = on ? 0.55 : 0.1
            pose.lift = on ? -2 : 0
            pose.cigar = on ? .up : .flat
            pose.browRight = on ? Brow(-3, 10) : Brow(-1, 14)
            pose.browLeft = Brow(9, -5)
            pose.hat = Hat(126, on ? 16 : 18, on ? 14 : 9)
            pose.smoke = t
        case .spin:
            let a = tau * t
            if cos(a) < -0.15 {
                pose.back = true
            } else {
                pose.turn = sin(a)
                pose.eyeRight = .open
            }
        case .dizzy:
            return full(.broken, t: t)
        }
        return pose
    }

    /// A play reaction on the simplified drawing. It has no back view, so turning away means looking away, and a spin turns him around in place.
    public static func simpleAct(_ act: Act, t: CGFloat) -> SimplePose {
        var pose = SimplePose()
        switch act {
        case .hoot:
            pose.eyeLeft = .closed
            pose.eyeRight = .closed
            pose.jaw = 0.5 + 0.12 * sin(tau * t * 2)
            pose.cigar = nil
            pose.lift = -1
            pose.smile = 0.35
        case .yawn:
            let e = sin(CGFloat.pi * t) * sin(CGFloat.pi * t)
            pose.eyeLeft = .closed
            pose.eyeRight = .closed
            pose.jaw = 1.2 * e
            pose.cigar = nil
            pose.lift = -2 * e
            pose.smile = 0.5 * e
        case .poke:
            let k = squashAmount(t)
            let hard = k > 0.25
            pose.eyeLeft = hard ? .squint : .open
            pose.eyeRight = hard ? .squint : .lid
            pose.cigar = hard ? .up : .flat
            pose.bob = 2 * k
        case .annoyed:
            pose.eyeLeft = .lid
            pose.eyeRight = .lid
            pose.look = CGPoint(x: 2.4, y: 0)
            pose.tilt = -4
            pose.smile = -0.2
        case .back:
            pose.eyeLeft = .lid
            pose.eyeRight = .lid
            pose.look = CGPoint(x: -2.4, y: 0)
            pose.tilt = 6
            pose.bob = 0.5 * sin(tau * t)
        case .wink:
            let on = t > 0.2 && t < 0.7
            pose.eyeRight = on ? .happy : .lid
            pose.smile = on ? 0.55 : 0.1
            pose.lift = on ? -1 : 0
            pose.cigar = on ? .up : .flat
        case .spin:
            pose.tilt = 360 * t
        case .dizzy:
            return simple(.broken, t: t, mono: false)
        }
        return pose
    }

    /// How squashed he is during a poke: a quick bounce that dies away.
    public static func squashAmount(_ t: CGFloat) -> CGFloat {
        let k = max(0, 1 - t * 3.2)
        return k * abs(cos(k * 7))
    }

    /// `mono` matters because only work smokes in the menu bar.
    public static func simple(_ name: PoseName, t: CGFloat, mono: Bool) -> SimplePose {
        var pose = SimplePose()
        let s = sin(tau * t)
        switch name {
        case .watch:
            if t > 0.8 && t < 0.87 {
                pose.eyeLeft = .closed
                pose.eyeRight = .closed
            }
            pose.smoke = mono ? nil : t
            pose.bob = 0.5 * s
        case .work:
            pose.look = CGPoint(x: 2.4 * s, y: 0)
            pose.smoke = (t * 2).truncatingRemainder(dividingBy: 1)
        case .happy:
            let jump = abs(s)
            pose.eyeLeft = .happy
            pose.eyeRight = .happy
            pose.smile = 1
            pose.lift = -1
            pose.cigar = .up
            pose.smoke = mono ? nil : t
            pose.bob = mono ? 1 - jump : -2 * jump + 2
            pose.hat = Hat(0, mono ? -jump : -1 - 3 * jump, 7 + 9 * s)
        case .alarm:
            let jitter: CGFloat = Int(t * 24) % 2 == 1 ? 0.9 : -0.9
            pose.eyeLeft = .wide
            pose.eyeRight = .wide
            pose.ring = false
            pose.popped = true
            pose.jaw = 1
            pose.smile = 0.6
            pose.lift = -2
            pose.cigar = nil
            pose.hat = Hat(0, -1.6, -6)
            pose.bob = jitter * 0.3 + 1.6
            pose.tilt = jitter
        case .sleep:
            let breath = (1 - cos(tau * t)) / 2
            pose.eyeLeft = .closed
            pose.eyeRight = .closed
            pose.smile = -0.1
            pose.lift = -0.8 * breath
            pose.jaw = 0.14 * breath
            pose.cigar = .droop
            pose.hat = Hat(-3, 6, -8)
            pose.bob = 0.6 * breath
        case .wait:
            pose.eyeRight = .open
            pose.hat = Hat(0, -1, 7)
            pose.tilt = -3
            pose.smoke = mono ? nil : t
        case .limit:
            pose.eyeLeft = .tired
            pose.eyeRight = .tired
            pose.look = CGPoint(x: 0, y: 1.2)
            pose.smile = -0.8
            pose.lift = 1
            pose.cigar = .droop
            pose.hat = Hat(-1, 3, 13)
            pose.bob = 1 + 0.5 * s
        case .broken:
            pose.eyeLeft = .dizzy
            pose.eyeRight = .dizzy
            pose.ring = false
            pose.smile = -0.25
            pose.cigar = .droop
            pose.hat = Hat(2, -2, 20)
        case .alert:
            pose.eyeRight = .small
            pose.look = CGPoint(x: 2.2 * s, y: 0)
            pose.tilt = -9
            pose.hat = Hat(0, -1, 3)
        case .stopped:
            pose.eyeLeft = .small
            pose.eyeRight = .big
            pose.ring = false
            pose.tilt = 8
            pose.smile = 0.2 * s
            pose.hat = Hat(0, -1, 12)
        }
        return pose
    }
}
