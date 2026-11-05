import CoreGraphics
import BorisCore

/// Puts an outfit on any pose, and the poses for the wardrobe shelf.
public enum Dress {
    private static func headwear(_ outfit: Outfit) -> Headwear? {
        switch outfit {
        case .santa: return .santa
        case .witch: return .witch
        case .party: return .party
        case .scholar: return .scholar
        case .nightcap: return .nightcap
        case .flower: return .flower
        case .none, .pixel, .hearts, .crow, .fish: return nil
        }
    }

    /// An outfit never closes his eyes or changes the mood: the hat follows the pose, and only calm eyes turn into hearts.
    public static func apply(_ outfit: Outfit, to pose: Pose) -> Pose {
        var pose = pose
        pose.headwear = headwear(outfit)
        switch outfit {
        case .santa: pose.hat = shifted(pose.hat, -2, 4, -3)
        case .witch: pose.hat = shifted(pose.hat, -6, 4, -15)
        case .party: pose.hat = shifted(pose.hat, -2, 8, -19)
        case .scholar: pose.hat = shifted(pose.hat, -4, 8, -2)
        case .nightcap: pose.hat = shifted(pose.hat, -6, 6, -5)
        case .pixel:
            if pose.monocle == .worn { pose.monocle = .pixel }
        case .hearts:
            pose.eyeLeft = hearted(pose.eyeLeft)
            pose.eyeRight = hearted(pose.eyeRight)
        case .crow:
            pose.crow = true
        case .fish:
            if pose.cigar != nil { pose.cigar = .fish }
        case .none, .flower:
            break
        }
        return pose
    }

    public static func apply(_ outfit: Outfit, to pose: SimplePose, mono: Bool) -> SimplePose {
        var pose = pose
        pose.headwear = headwear(outfit)
        switch outfit {
        case .santa: pose.hat = shifted(pose.hat, 0, -2, -3)
        case .witch: pose.hat = shifted(pose.hat, 0, 0, -12)
        case .party: pose.hat = shifted(pose.hat, 0, 0, -15)
        case .scholar: pose.hat = shifted(pose.hat, 0, 0, -2)
        case .nightcap: pose.hat = shifted(pose.hat, 0, -2, -4)
        case .pixel:
            pose.glasses = true
            pose.ring = false
        case .hearts:
            pose.eyeLeft = hearted(pose.eyeLeft)
            pose.eyeRight = hearted(pose.eyeRight)
            pose.ring = false
        case .crow:
            pose.crow = true
        case .fish:
            // The fish is a reward on the wardrobe shelf: there is no menu bar icon for it.
            if !mono, pose.cigar != nil { pose.cigar = .fish }
        case .none, .flower:
            break
        }
        return pose
    }

    /// The full pose an outfit is shown in on the shelf.
    public static func shelf(_ outfit: Outfit) -> Pose {
        var pose = Pose()
        switch outfit {
        case .party:
            pose.eyeLeft = .happy
            pose.eyeRight = .happy
            pose.smile = 1
            pose.lift = -3
            pose.cigar = .up
            pose.browLeft = Brow(9, -6)
            pose.browRight = Brow(9, -6)
        case .santa:
            pose.smile = 0.1
        case .witch:
            pose.eyeRight = .open
        case .nightcap:
            pose.eyeLeft = .closed
            pose.eyeRight = .closed
            pose.browLeft = Brow(-3, 8)
            pose.browRight = Brow(-3, 8)
            pose.cigar = .droop
            pose.lit = false
        case .flower:
            pose.smile = 0.15
        case .pixel:
            pose.eyeRight = .open
            pose.browLeft = Brow(8, -2)
            pose.browRight = Brow(8, -2)
            pose.cigar = .up
            pose.smile = 0.3
        case .hearts:
            pose.eyeLeft = .open
            pose.eyeRight = .open
            pose.smile = 0.6
            pose.lift = -2
            pose.browLeft = Brow(9, -6)
            pose.browRight = Brow(9, -6)
        case .fish:
            pose.smile = 0.25
            pose.eyeRight = .open
        case .none, .scholar, .crow:
            break
        }
        return apply(outfit, to: pose)
    }

    public static func shelfSimple(_ outfit: Outfit, mono: Bool) -> SimplePose {
        var pose = SimplePose()
        switch outfit {
        case .witch:
            pose.eyeRight = .open
        case .party:
            pose.eyeLeft = .happy
            pose.eyeRight = .happy
            pose.smile = 1
            pose.lift = -1
            pose.cigar = .up
        case .nightcap:
            pose.eyeLeft = .closed
            pose.eyeRight = .closed
            pose.cigar = .droop
        case .hearts:
            pose.eyeLeft = .open
            pose.eyeRight = .open
            pose.smile = 0.5
            pose.lift = -1
        case .fish:
            pose.smile = 0.2
            pose.eyeRight = .open
        case .none, .santa, .scholar, .flower, .pixel, .crow:
            break
        }
        return apply(outfit, to: pose, mono: mono)
    }

    private static func shifted(_ hat: Hat, _ x: CGFloat, _ y: CGFloat, _ tilt: CGFloat) -> Hat {
        Hat(hat.x + x, hat.y + y, hat.tilt + tilt)
    }

    private static func hearted(_ eye: Eye) -> Eye {
        switch eye {
        case .open, .lid, .small, .big: return .heart
        case .tired, .wide, .closed, .happy, .dizzy, .heart, .squint: return eye
        }
    }
}
