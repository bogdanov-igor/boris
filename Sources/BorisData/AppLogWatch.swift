import BorisCore
import Foundation

/// Turns the pictures the engine sends into log lines only when something has really changed. A scan alone writes nothing.
public struct AppLogWatch {
    private var readingSince: Date?
    private var tokensSince: Date?
    private var issues: Set<LogWord> = []
    private var folderFound: Bool?

    public init() {}

    /// Reading from the start, as at launch or after choosing another folder.
    public mutating func started(now: Date = Date()) {
        readingSince = now
        tokensSince = now
    }

    public mutating func saw(_ output: WorkEngine.Output, now: Date = Date()) {
        if let since = readingSince {
            readingSince = nil
            AppLog.note(.firstRead, .seconds(now.timeIntervalSince(since)), .number(output.world.sessions.count))
        }
        // Version zero means the first pass over the logs is not done yet.
        if let since = tokensSince, output.tokensVersion > 0 {
            tokensSince = nil
            AppLog.note(.tokensCounted, .seconds(now.timeIntervalSince(since)))
        }
        seeFolder(output.world.claudeFolderFound)
        seeIssues(Set(output.world.formatIssues.map(Self.word)))
    }

    private mutating func seeFolder(_ found: Bool) {
        guard found != folderFound else { return }
        // Being there from the first look is nothing to report.
        if folderFound != nil || !found { AppLog.note(found ? .claudeFolderFound : .claudeFolderMissing) }
        folderFound = found
    }

    private mutating func seeIssues(_ now: Set<LogWord>) {
        guard now != issues else { return }
        for issue in now.subtracting(issues).sorted(by: { $0.rawValue < $1.rawValue }) { AppLog.note(.formatIssue, .word(issue)) }
        if now.isEmpty { AppLog.note(.formatFine) }
        issues = now
    }

    /// By kind only. The name of an unknown event and the id of a run come from the logs.
    private static func word(_ issue: FormatIssue) -> LogWord {
        switch issue {
        case .unknownJournalEvent: return .unknownJournalEvent
        case .unreadableFinal: return .unreadableFinal
        case .unreadableSessions: return .unreadableSessions
        }
    }
}

public extension RequestOutcome {
    var logWord: LogWord {
        switch self {
        case .allowed: return .allowed
        case .denied: return .denied
        case .answered: return .answered
        case .planApproved: return .planApproved
        case .planDenied: return .planDenied
        case .expired: return .expiredThenAnswered
        case .closedInClaude: return .closedInClaude
        case .answeredInClaude: return .answeredInClaude
        }
    }
}

public extension RequestPlace {
    var logWord: LogWord {
        switch self {
        case .window: return .requestsPage
        case .mini: return .miniWindow
        case .notch: return .panel
        case .hotKey: return .hotKey
        case .session: return .inClaude
        }
    }
}

public extension TelegramProblem {
    var logWord: LogWord {
        switch self {
        case .noConnection: return .noConnection
        case .badToken: return .badToken
        case .badRecipient: return .badRecipient
        case .botCannotWrite: return .botCannotWrite
        case .tooOften: return .tooOften
        case .other: return .other
        }
    }
}

public extension HookInstaller.Status {
    var logWord: LogWord {
        switch self {
        case .notInstalled: return .notInstalled
        case .installed: return .installed
        case .outdated: return .outdated
        case .disabledInSettings: return .disabledInSettings
        case .disabledByPolicy: return .disabledByPolicy
        case .unreadable: return .unreadable
        }
    }
}
