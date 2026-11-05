import Foundation

/// The events a person can turn on and off for each channel.
public enum NotificationTopic: String, Codable, CaseIterable, Sendable, Identifiable {
    case permission, question, plan, finished, failure, interrupted, silence, limitNear

    public var id: String { rawValue }

    public init(_ event: BorisEvent) {
        switch event.kind {
        case .waiting:
            if event.toolName == "ExitPlanMode" {
                self = .plan
            } else if event.toolName == "AskUserQuestion" || event.asksForAnswer {
                self = .question
            } else {
                self = .permission
            }
        case .completed, .sessionFinished: self = .finished
        case .completedWithErrors, .allAgentsFailed, .failed, .sessionError, .limitReached: self = .failure
        case .stopped, .interrupted: self = .interrupted
        case .silent: self = .silence
        case .limitNear: self = .limitNear
        }
    }

    public var label: String {
        switch self {
        case .permission: return L("Permission request")
        case .question: return L("Question")
        case .plan: return L("Plan")
        case .finished: return L("Completion")
        case .failure: return L("Failure")
        case .interrupted: return L("Interrupted work")
        case .silence: return L("Long silence")
        case .limitNear: return L("Limit close")
        }
    }
}

/// Where one kind of event goes.
public struct ChannelChoice: Codable, Sendable, Equatable {
    public var mac: Bool
    public var sound: Bool
    public var telegram: Bool

    public init(mac: Bool, sound: Bool, telegram: Bool) {
        self.mac = mac
        self.sound = sound
        self.telegram = telegram
    }
}

/// What the person chose about notifications. The Telegram token is not here: it lives in the Keychain.
public struct NotificationPreferences: Codable, Sendable, Equatable {
    public var channels: [NotificationTopic: ChannelChoice] = [:]
    public var voiceOn = true
    /// From 0 to 1.
    public var volume = 0.6
    /// How full a limit window gets before the warning.
    public var limitNearPercent = 90
    /// Empty means no bot is connected.
    public var telegramChat = ""
    public var telegramDuringQuiet = true

    public init() {}

    public static func standard(_ topic: NotificationTopic) -> ChannelChoice {
        switch topic {
        case .permission, .question, .failure, .limitNear: return ChannelChoice(mac: true, sound: true, telegram: true)
        case .plan, .finished, .silence: return ChannelChoice(mac: true, sound: false, telegram: false)
        case .interrupted: return ChannelChoice(mac: true, sound: false, telegram: true)
        }
    }

    public func choice(_ topic: NotificationTopic) -> ChannelChoice {
        channels[topic] ?? Self.standard(topic)
    }

    /// The channels of an event together with the mood the walrus shows for it.
    public func reaction(for event: BorisEvent, mood: MoodReaction) -> Reaction {
        let choice = choice(NotificationTopic(event))
        return Reaction(banner: choice.mac, sound: choice.sound && voiceOn, mood: mood)
    }

    public func wantsTelegram(_ event: BorisEvent, quiet: Bool) -> Bool {
        !telegramChat.isEmpty && choice(NotificationTopic(event)).telegram && (!quiet || telegramDuringQuiet)
    }
}

/// The walrus's short sounds, each a file in `Resources/Sounds`.
public enum WalrusSound: String, CaseIterable, Sendable {
    case bellow, done, alarm, wait, hmm, tired, poke, yawn

    public init(for kind: EventKind) {
        switch kind {
        case .completed, .sessionFinished: self = .done
        case .completedWithErrors, .allAgentsFailed, .failed, .interrupted, .sessionError: self = .alarm
        case .stopped, .silent: self = .hmm
        case .waiting: self = .wait
        case .limitReached, .limitNear: self = .tired
        }
    }
}

/// One and the same sound comes at most once in this many seconds, however many events ask for it.
public struct SoundLimiter: Sendable {
    public static let gap: TimeInterval = 10
    private var lastPlayed: [WalrusSound: Date] = [:]

    public init() {}

    public mutating func allow(_ sound: WalrusSound, now: Date) -> Bool {
        if let last = lastPlayed[sound], now.timeIntervalSince(last) < Self.gap { return false }
        lastPlayed[sound] = now
        return true
    }
}
