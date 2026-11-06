import BorisCore
import Foundation
import Observation

/// Everything that reaches Claude Desktop's window goes through this, so a check can run on a stand-in that touches nothing.
public protocol ChatWindowProbe: Sendable {
    /// Whether macOS lets Boris look. It never shows anything.
    func hasPermission() -> Bool
    /// Shows macOS's own question. Only after the person has agreed in «Sources».
    func askForPermission()
    func look() -> ChatLook
    /// The person has withdrawn their consent, so Claude Desktop can stop preparing for being looked at.
    func stopLooking()
}

/// Stands in where nothing outside may be touched, as in a snapshot.
public struct NoChatProbe: ChatWindowProbe {
    public init() {}
    public func hasPermission() -> Bool { false }
    public func askForPermission() {}
    public func look() -> ChatLook { .noPermission }
    public func stopLooking() {}
}

/// Looks at Claude Desktop every few seconds, and only with the person's consent. Without it there is no timer and no call to macOS.
@MainActor
@Observable
public final class ChatWatch {
    public private(set) var tracker = ChatTracker()

    @ObservationIgnored public var onChange: (() -> Void)?
    @ObservationIgnored private let probe: any ChatWindowProbe
    @ObservationIgnored private let period: Duration
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var news: [BorisEvent] = []

    public init(probe: any ChatWindowProbe, period: Duration = .seconds(3)) {
        self.probe = probe
        self.period = period
    }

    public var isLooking: Bool { loop != nil }

    public func update(consent: Bool) {
        if consent {
            start()
        } else {
            stop()
        }
    }

    public func askForPermission() {
        probe.askForPermission()
    }

    /// What has become ready since the last time anyone asked.
    public func takeEvents() -> [BorisEvent] {
        defer { news = [] }
        return news
    }

    private func start() {
        guard loop == nil else { return }
        let probe = probe
        let period = period
        loop = Task { [weak self] in
            while !Task.isCancelled {
                // Calls to another application can take a while, and they must never hold up the main thread.
                let look = await Task.detached(priority: .utility) { probe.hasPermission() ? probe.look() : ChatLook.noPermission }.value
                guard !Task.isCancelled, let self else { return }
                self.take(look, now: Date())
                try? await Task.sleep(for: period)
            }
        }
    }

    private func stop() {
        guard let running = loop else { return }
        running.cancel()
        loop = nil
        tracker.turnOff()
        news = []
        let probe = probe
        Task.detached(priority: .utility) { probe.stopLooking() }
        onChange?()
    }

    /// Boris is closing, and Claude Desktop should not go on preparing for a look that will not come. The consent stays.
    public func quit() {
        guard let running = loop else { return }
        running.cancel()
        loop = nil
        probe.stopLooking()
    }

    func take(_ look: ChatLook, now: Date) {
        let before = tracker
        if tracker.note(look, now: now) { news.append(ChatTracker.readyEvent(at: now)) }
        if tracker != before { onChange?() }
    }

    #if DEBUG
    /// Shows a state on a picture of the screen, with nothing looked at.
    public func showForSnapshot(_ looks: [ChatLook]) {
        for look in looks { _ = tracker.note(look, now: Date()) }
    }
    #endif
}
