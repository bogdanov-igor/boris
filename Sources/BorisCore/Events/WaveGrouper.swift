import Foundation

/// What to do with a banner: show it, or fold earlier ones into a single summary.
public enum WaveAction: Sendable, Equatable {
    case show(BorisEvent)
    case summarize(counts: [EventKind: Int], replacing: [String])
}

/// The first two events of a burst appear at once. From the third on, all of them become one summary.
public struct WaveGrouper: Sendable {
    public var window: TimeInterval
    public var threshold: Int
    private var recent: [BorisEvent] = []

    public init(window: TimeInterval = 10, threshold: Int = 3) {
        self.window = window
        self.threshold = threshold
    }

    public mutating func add(_ event: BorisEvent, now: Date) -> WaveAction {
        recent.removeAll { now.timeIntervalSince($0.at) > window }
        recent.append(event)
        guard recent.count >= threshold else { return .show(event) }
        var counts: [EventKind: Int] = [:]
        for item in recent { counts[item.kind, default: 0] += 1 }
        return .summarize(counts: counts, replacing: recent.map(\.id))
    }
}
