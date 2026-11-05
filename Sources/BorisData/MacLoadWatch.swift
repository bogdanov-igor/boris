import BorisCore
import Foundation
import Observation

/// Keeps the load fresh while someone can see it. With nobody looking there is no timer and no reading.
@MainActor
@Observable
public final class MacLoadWatch {
    public typealias Reader = @Sendable (LoadRequest) async -> MacLoad

    /// Nil before the first reading. It comes as soon as a block appears, with CPU load following a second later.
    public private(set) var current: MacLoad?
    /// Sources with reading turned off, whose processes are counted in the rest.
    public var off = Set<LoadGroup>()

    @ObservationIgnored public var reader: Reader?
    @ObservationIgnored public var sessions: @MainActor () -> [String: Int32] = { [:] }
    @ObservationIgnored private var viewers = Set<UUID>()
    @ObservationIgnored private var loop: Task<Void, Never>?
    private let period: Duration
    private let secondReadingAfter: Duration

    public init(reader: Reader? = nil, period: Duration = .seconds(3), secondReadingAfter: Duration = .milliseconds(1100)) {
        self.reader = reader
        self.period = period
        self.secondReadingAfter = secondReadingAfter
    }

    public var isReading: Bool { loop != nil }

    /// Each block says for itself whether it can be seen, as often as it likes.
    public func setVisible(_ visible: Bool, viewer: UUID) {
        if visible {
            viewers.insert(viewer)
        } else {
            viewers.remove(viewer)
        }
        if viewers.isEmpty {
            stop()
        } else {
            start()
        }
    }

    private func request(restart: Bool = false) -> LoadRequest {
        LoadRequest(sessions: sessions(), off: off, restart: restart)
    }

    private func start() {
        guard loop == nil, let reader else { return }
        let second = secondReadingAfter
        let period = period
        loop = Task { [weak self] in
            guard let self else { return }
            let first = await reader(self.request(restart: true))
            guard !Task.isCancelled else { return }
            self.current = first
            try? await Task.sleep(for: second)
            while !Task.isCancelled {
                let load = await reader(self.request())
                guard !Task.isCancelled else { return }
                self.current = load
                try? await Task.sleep(for: period)
            }
        }
    }

    private func stop() {
        loop?.cancel()
        loop = nil
        // Old numbers must not flash when the block opens again.
        if reader != nil { current = nil }
    }

    #if DEBUG
    /// Fixed numbers for pictures of the screens, with nothing read.
    public func showForSnapshot(_ load: MacLoad?) {
        current = load
    }
    #endif
}
