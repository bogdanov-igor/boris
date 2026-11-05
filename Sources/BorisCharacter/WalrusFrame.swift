import CoreGraphics
import BorisCore

/// Everything that decides one picture of the drawn walrus. It is a value, so a picture can be kept and found again.
public struct WalrusFrame: Hashable, Sendable {
    /// Steps of a reaction's progress that can differ, far more than can be shown.
    public static let actSteps = 64

    public var name: PoseName
    public var outfit: Outfit
    /// The step of the loop. `nil` is the still key frame.
    public var step: Int?
    public var firstLoop = false
    public var blink = false
    public var act: Act?
    public var actStep = 0
    /// A poke in alarm or waiting only squashes the pose that is there.
    public var softPoke = false
    /// Where the pupils look, as a share of how far they can go, in whole steps. `nil` leaves them to the pose.
    public var gaze: Gaze?
    public var upsideDown = false

    public struct Gaze: Hashable, Sendable {
        /// Steps from -3 to 3.
        public var x, y: Int

        public init(x: Int, y: Int) {
            self.x = x
            self.y = y
        }

        /// The pupils follow a point given relative to his head, with y pointing down.
        public init(toward dx: CGFloat, _ dy: CGFloat) {
            let length = max((dx * dx + dy * dy).squareRoot(), 40)
            x = Int((3 * dx / length).rounded())
            y = Int((3 * dy / length).rounded())
        }
    }

    public init(name: PoseName, outfit: Outfit) {
        self.name = name
        self.outfit = outfit
    }

    private var loopTime: CGFloat {
        step.map { CGFloat($0) / CGFloat(Timeline.framesPerLoop) } ?? name.keyTime
    }

    private var actTime: CGFloat { CGFloat(actStep) / CGFloat(Self.actSteps) }

    public func fullPose() -> Pose {
        var pose = Timeline.full(name, t: loopTime, firstLoop: step != nil && firstLoop)
        if let act {
            if softPoke {
                let k = Timeline.squashAmount(actTime)
                pose.squash = CGSize(width: 1 + 0.15 * k, height: 1 - 0.17 * k)
            } else {
                pose = Timeline.act(act, t: actTime)
            }
        } else if blink {
            pose.eyeLeft = .closed
            pose.eyeRight = .closed
        }
        if let gaze, name.followsPointer, act == nil || softPoke {
            pose.look = CGPoint(x: 2 * CGFloat(gaze.x), y: 5 * CGFloat(gaze.y) / 3)
        }
        pose = Dress.apply(outfit, to: pose)
        pose.upsideDown = upsideDown
        return pose
    }

    public func simplePose(mono: Bool = false) -> SimplePose {
        var pose = Timeline.simple(name, t: loopTime, mono: mono)
        if let act {
            if softPoke {
                pose.bob += 2 * Timeline.squashAmount(actTime)
            } else {
                pose = Timeline.simpleAct(act, t: actTime)
            }
        } else if blink {
            pose.eyeLeft = .closed
            pose.eyeRight = .closed
        }
        if let gaze, name.followsPointer, act == nil || softPoke {
            pose.look = CGPoint(x: 0.8 * CGFloat(gaze.x), y: 0.4 * CGFloat(gaze.y))
        }
        return Dress.apply(outfit, to: pose, mono: mono)
    }
}

extension PoseName {
    /// Eyes that can look at something. A sleeping, dizzy or weary walrus does not follow the pointer.
    public var followsPointer: Bool {
        switch self {
        case .watch, .work, .wait, .alert, .stopped, .alarm: return true
        case .happy, .sleep, .limit, .broken: return false
        }
    }

    /// Which pack state stands for this pose. The base look is not a state: `nil` shows the pack's base pose.
    public var packPose: WalrusPose? {
        switch self {
        case .watch: return nil
        case .work: return .working
        case .happy: return .happy
        case .alarm: return .alarm
        case .sleep: return .sleeping
        case .wait: return .waiting
        case .limit: return .tired
        case .broken: return .broken
        case .alert: return .alert
        case .stopped: return .hmm
        }
    }
}
