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
        /// Telegram cannot take messages back, so its one summary waits until the burst is over.
        var telegramOwed = false
    }

    /// Agents keep falling for hours after the limit ran out, and the one notification has already told about them.
    static let limitCovers: TimeInterval = 5 * 3600

    private var waves: [NotificationTopic: Wave] = [:]
    private var limiter = SoundLimiter()
    private var limitToldAt: Date?

    public init() {}

    public mutating func route(_ items: [Item], now: Date) -> [NotificationDelivery] {
        var limits = items.filter { $0.event.kind == .limitReached }
        let causedByLimit = items.filter { $0.event.kind != .limitReached && $0.event.topFailure == .limit }
        // Without its own limit event a failure still has to tell about the limit, once.
        if limits.isEmpty, !isLimitTold(now: now) { limits = causedByLimit }
        let rest = items.filter { $0.event.kind != .limitReached && $0.event.topFailure != .limit }
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

    private func isLimitTold(now: Date) -> Bool {
        guard let limitToldAt else { return false }
        return now.timeIntervalSince(limitToldAt) < Self.limitCovers
    }

    private mutating func oneLimit(_ items: [Item], now: Date) -> [NotificationDelivery] {
        guard let first = items.first else { return [] }
        limitToldAt = now
        let projects = Set(items.compactMap(\.event.project))
        let merged = BorisEvent(
            id: "\(first.event.id)|limit",
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
        let projects = unique(items.compactMap(\.event.project))

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
            var shown: [Item] = []
            var replacing: [String]?
            for item in ofTopic {
                wave.lastAt = now
                wave.projects = unique(wave.projects + [item.event.project].compactMap { $0 })
                switch wave.grouper.add(item.event, now: now) {
                case .show:
                    wave.total += 1
                    shown.append(item)
                case .summarize(let counts, let ids):
                    wave.total = counts.values.reduce(0, +)
                    replacing = ids
                }
            }
            if let replacing {
                // Those from this same scan were never posted, so only the earlier ones need taking back.
                let thisScan = Set(ofTopic.map(\.event.id))
                let earlier = replacing.filter { !thisScan.contains($0) }
                if !earlier.isEmpty { deliveries.append(.removeBanners(earlier)) }
                if ofTopic.contains(where: \.reaction.banner) {
                    deliveries.append(.banner(NotificationWords.waveBanner(topic, count: wave.total, projects: wave.projects)))
                }
                if ofTopic.contains(where: \.telegram) { wave.telegramOwed = true }
            } else {
                for item in shown {
                    if item.reaction.banner { deliveries.append(.banner(NotificationWords.banner(item.event))) }
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
