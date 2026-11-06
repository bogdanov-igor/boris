import BorisCore
import Foundation

/// How the hooks stand: what is in Claude's settings together with what the person asked for.
public enum HookConnection: Sendable, Equatable {
    case notConnected
    case connected
    /// The person connected them, and they are gone or no longer right.
    case damaged
    case settingsUnreadable
    case disabledInSettings
    case disabledByPolicy

    /// - Parameter wanted: the person connected the hooks and has not disconnected them.
    public init(wanted: Bool, status: HookInstaller.Status) {
        switch status {
        case .disabledByPolicy: self = .disabledByPolicy
        case .disabledInSettings: self = .disabledInSettings
        case .unreadable: self = .settingsUnreadable
        case .installed: self = .connected
        case .outdated: self = .damaged
        case .notInstalled: self = wanted ? .damaged : .notConnected
        }
    }

    public var canConnect: Bool {
        self == .notConnected || self == .damaged
    }
}

/// How many remote machines there are and what is wrong with those that cannot be reached.
public struct RemoteSummary: Sendable, Equatable {
    public var machines = 0
    public var connected = 0
    public var failures: [RemoteFailure] = []

    public init(machines: Int = 0, connected: Int = 0, failures: [RemoteFailure] = []) {
        self.machines = machines
        self.connected = connected
        self.failures = failures
    }
}

/// The state of every part of the connection, for the diagnostics section and the report.
public struct ConnectionStatus: Sendable, Equatable {
    public enum Limits: Sendable, Equatable {
        case noData
        case fresh
        case stale(age: TimeInterval)
    }

    public enum Problem: Sendable, Equatable {
        case claudeFolderMissing
        case filesUnreadable
        case formatChanged
        case settingsUnreadable
        case hooksDamaged
        case hooksSilent
        case hooksDisabledInSettings
        case hooksDisabledByPolicy
    }

    /// Long enough for Claude to have got as far as its first tool.
    public static let quietLimit: TimeInterval = 5 * 60

    public var claudeFolderFound: Bool
    public var lastRead: Date
    public var formatIssues: Set<FormatIssue>
    public var hooks: HookConnection
    public var lastHookEvent: Date?
    public var hooksSilent: Bool
    public var limits: Limits
    /// How remote machines stand. Their names stay out of it, because a report gets pasted into a bug.
    public var remote = RemoteSummary()

    /// - Parameter hooksSince: when the hooks could have started talking: the moment they were connected or this app started.
    public init(world: WorldSnapshot, hooks: HookConnection, hookState: HookState, hooksSince: Date, now: Date) {
        claudeFolderFound = world.claudeFolderFound
        lastRead = world.takenAt
        formatIssues = world.formatIssues
        self.hooks = hooks
        lastHookEvent = hookState.lastEventAt
        hooksSilent = hooks == .connected && Self.isSilent(sessions: world.sessions, lastEvent: hookState.lastEventAt, since: hooksSince, now: now)
        if let usage = world.usage {
            limits = usage.staleAge(now: now).map { .stale(age: $0) } ?? .fresh
        } else {
            limits = .noData
        }
    }

    /// A session changed its status long enough ago, stayed busy, and no event came after that change. A long command alone does not count,
    /// since its start was an event. Cowork and programs on the SDK may not load the person's settings, so they say nothing about the hooks.
    static func isSilent(sessions: [SessionInfo], lastEvent: Date?, since: Date, now: Date) -> Bool {
        let reference = max(lastEvent ?? .distantPast, since)
        return sessions.contains { session in
            guard session.status == "busy", let changed = session.statusUpdatedAt, let environment = session.environment,
                  [WorkEnvironment.terminal, .vsCode, .cursor, .claudeDesktop].contains(environment)
            else { return false }
            return changed > reference && now.timeIntervalSince(changed) > quietLimit
        }
    }

    /// Boris cannot read, or the connection the person made has stopped working. Hooks turned off on purpose are not broken.
    public var isBroken: Bool {
        problems.contains { $0 != .hooksDisabledInSettings && $0 != .hooksDisabledByPolicy }
    }

    public var problems: [Problem] {
        var found: [Problem] = []
        if !claudeFolderFound { found.append(.claudeFolderMissing) }
        if formatIssues.contains(.unreadableSessions) { found.append(.filesUnreadable) }
        if !formatIssues.isEmpty { found.append(.formatChanged) }
        switch hooks {
        case .settingsUnreadable: found.append(.settingsUnreadable)
        case .damaged: found.append(.hooksDamaged)
        case .disabledInSettings: found.append(.hooksDisabledInSettings)
        case .disabledByPolicy: found.append(.hooksDisabledByPolicy)
        case .connected, .notConnected: break
        }
        if hooksSilent { found.append(.hooksSilent) }
        return found
    }
}
