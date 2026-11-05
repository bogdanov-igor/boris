import Foundation

public enum NotificationDelivery: Sendable, Equatable {
    case banner(MacBanner)
    case removeBanners([String])
    case sound(WalrusSound)
    case telegram(TelegramLine)
}

/// Turns the events of one scan into what each channel gets: bursts become one notification, a limit one notification,
/// and work lost while Boris was closed one summary. All time comes from the scan, so there are no timers here.
public struct NotificationRouter: Sendable {
    public struct Item: Sendable, Equatable {
        public var event: BorisEvent
        /// Mac and sound, after do not disturb had its say.
        public var reaction: Reaction
        public var telegram: Bool

        public init(event: BorisEvent, reaction: Reaction, telegram: Bool) {
            self.event = event
            self.reaction = reaction
            self.telegram = telegram
        }
    }

    private struct Wave: Sendable {
        var grouper = WaveGrouper()
        var lastAt = Date.distantPast
        var total = 0
        var projects: [String] = []
        /// Banners of this burst still on screen, for its summary to take back.
        var posted: [String] = []
        /// Once a burst has its summary, nothing of it comes one by one again, even when it slows down.
        var summarized = false
        /// Telegram cannot take messages back, so its one summary waits until the burst is over.
        var telegramOwed = false
    }

    private var waves: [NotificationTopic: Wave] = [:]
    private var limiter = SoundLimiter()

    public init() {}

    public mutating func route(_ items: [Item], now: Date) -> [NotificationDelivery] {
        let limits = items.filter { $0.event.kind == .limitReached }
        // Agents keep falling for hours after the limit ran out. The detector gives each limit one event, and that event tells about them.
        let rest = items.filter { $0.event.kind != .limitReached && !$0.event.failedFromLimit }
        let away = rest.filter { $0.event.kind == .interrupted && $0.event.whileAway }
        let ordinary = rest.filter { !($0.event.kind == .interrupted && $0.event.whileAway) }

        // A burst that is over must not swallow what comes after it.
        var deliveries = drain(now: now)
        deliveries += oneLimit(limits, now: now)
        deliveries += awaySummary(away, now: now)
        deliveries += byWaves(ordinary, now: now)
        return deliveries
    }

    /// Whatever became due with time alone. Called after every scan, with or without events.
    public mutating func drain(now: Date) -> [NotificationDelivery] {
        var deliveries: [NotificationDelivery] = []
        for topic in NotificationTopic.allCases {
            guard var wave = waves[topic], now.timeIntervalSince(wave.lastAt) > wave.grouper.window else { continue }
            if wave.telegramOwed {
                deliveries.append(.telegram(NotificationWords.waveTelegram(topic, count: wave.total, projects: wave.projects)))
                wave.telegramOwed = false
            }
            waves[topic] = nil
        }
        return deliveries
    }

    private mutating func oneLimit(_ items: [Item], now: Date) -> [NotificationDelivery] {
        guard !items.isEmpty else { return [] }
        let projects = Set(items.compactMap(\.event.project))
        let merged = BorisEvent(
            // One place on the Mac: a limit first known without its time gets it here, not as a second notification.
            id: "boris.limit",
            kind: .limitReached,
            at: now,
            project: projects.count == 1 ? projects.first : nil,
            agentsFailed: items.reduce(0) { $0 + ($1.event.agentsFailed ?? 0) },
            resets: items.lazy.compactMap(\.event.resets).first
        )
        var deliveries: [NotificationDelivery] = []
        if items.contains(where: \.reaction.banner) { deliveries.append(.banner(NotificationWords.banner(merged))) }
        deliveries += sound(.tired, wanted: items.contains(where: \.reaction.sound), now: now)
        if items.contains(where: \.telegram) { deliveries.append(.telegram(NotificationWords.telegram(merged))) }
        return deliveries
    }

    private mutating func awaySummary(_ items: [Item], now: Date) -> [NotificationDelivery] {
        guard !items.isEmpty else { return [] }
        // A workflow and the session it ran in are one piece of lost work.
        var sessions: [String?] = []
        for item in items where item.event.sessionId == nil || !sessions.contains(item.event.sessionId) {
            sessions.append(item.event.sessionId)
        }
        let projects = unique(items.compactMap { NotificationWords.project($0.event) })

        var deliveries: [NotificationDelivery] = []
        if items.contains(where: \.reaction.banner) { deliveries.append(.banner(NotificationWords.awayBanner(sessions: sessions, projects: projects))) }
        deliveries += sound(.alarm, wanted: items.contains(where: \.reaction.sound), now: now)
        if items.contains(where: \.telegram) { deliveries.append(.telegram(NotificationWords.awayTelegram(sessions: sessions.count, projects: projects))) }
        return deliveries
    }

    private mutating func byWaves(_ items: [Item], now: Date) -> [NotificationDelivery] {
        var deliveries: [NotificationDelivery] = []
        for topic in NotificationTopic.allCases {
            let ofTopic = items.filter { NotificationTopic($0.event) == topic }
            guard !ofTopic.isEmpty else { continue }
            var wave = waves[topic] ?? Wave()
            for item in ofTopic {
                wave.lastAt = now
                wave.total += 1
                wave.projects = unique(wave.projects + [NotificationWords.project(item.event)].compactMap { $0 })
                if case .summarize = wave.grouper.add(item.event, now: now) { wave.summarized = true }
            }
            if wave.summarized {
                // With no summary to put in their place, the banners stay on screen.
                if ofTopic.contains(where: \.reaction.banner) {
                    if !wave.posted.isEmpty { deliveries.append(.removeBanners(wave.posted)) }
                    wave.posted = []
                    deliveries.append(.banner(NotificationWords.waveBanner(topic, count: wave.total, projects: wave.projects)))
                }
                if ofTopic.contains(where: \.telegram) { wave.telegramOwed = true }
            } else {
                for item in ofTopic {
                    if item.reaction.banner {
                        let banner = NotificationWords.banner(item.event)
                        wave.posted.append(banner.id)
                        deliveries.append(.banner(banner))
                    }
                    if item.telegram { deliveries.append(.telegram(NotificationWords.telegram(item.event))) }
                }
            }
            for item in ofTopic {
                deliveries += sound(WalrusSound(for: item.event.kind), wanted: item.reaction.sound, now: now)
            }
            waves[topic] = wave
        }
        return deliveries
    }

    private mutating func sound(_ sound: WalrusSound, wanted: Bool, now: Date) -> [NotificationDelivery] {
        wanted && limiter.allow(sound, now: now) ? [.sound(sound)] : []
    }

    private func unique(_ names: [String]) -> [String] {
        var seen: Set<String> = []
        return names.filter { seen.insert($0).inserted }
    }
}
