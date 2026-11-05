import Foundation

/// Limits how often the folder is scanned, however many files change.
public struct ScanGate: Sendable {
    public enum Decision: Sendable, Equatable {
        case runNow
        case runAfter(TimeInterval)
        /// A run is already planned, nothing to add.
        case alreadyPending
    }

    public var minInterval: TimeInterval
    private var lastRun: Date?
    private var pending = false

    public init(minInterval: TimeInterval = 2) {
        self.minInterval = minInterval
    }

    public mutating func request(now: Date) -> Decision {
        if pending { return .alreadyPending }
        guard let lastRun, now.timeIntervalSince(lastRun) < minInterval else {
            self.lastRun = now
            return .runNow
        }
        pending = true
        return .runAfter(minInterval - now.timeIntervalSince(lastRun))
    }

    public mutating func didRun(now: Date) {
        lastRun = now
        pending = false
    }
}
