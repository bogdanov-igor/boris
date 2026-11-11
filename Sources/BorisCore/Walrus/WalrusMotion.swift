import Foundation

/// When the walrus needs a timer at all. A walrus that is still or cannot be seen must cost nothing.
public enum WalrusMotion {
    public static let frameInterval: TimeInterval = 1.0 / 12

    /// Seconds until the next picture, or nil when no timer should run.
    /// - Parameters:
    ///   - moves: this state is meant to move on this surface.
    ///   - actLeft: how long a reaction still plays. With reduced motion it is one still picture, so all that is left is to end it.
    public static func nextFrame(moves: Bool, visible: Bool, reduceMotion: Bool, actLeft: TimeInterval? = nil, interval: TimeInterval = frameInterval) -> TimeInterval? {
        guard visible else { return nil }
        if let actLeft, actLeft > 0 { return reduceMotion ? actLeft : interval }
        return moves && !reduceMotion ? interval : nil
    }
}
