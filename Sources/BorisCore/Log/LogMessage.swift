import Foundation

/// Everything the log can say. A line is one of these plus a few typed values, so no call can write a sentence of its own.
/// The case name is what the file keeps, so a line can be shown in whatever language the interface is in later.
public enum LogMessage: String, Sendable, CaseIterable {
    // App
    case appStarted, appQuit, handedToAgent, autostartChanged, autostartFailed
    // Reading Claude's files
    case firstRead, tokensCounted, formatIssue, formatFine, claudeFolderMissing, claudeFolderFound, fileWriteFailed, fileBroken
    // Hooks and Claude's settings
    case hooksConnected, hooksRepaired, hooksDisconnected, hooksChangeFailed, hooksChangeRefused, hooksStatus, hooksLost
    case claudeSettingsWritten, claudeSettingsBackup, claudeSettingsUnreadable, claudeSettingsModeLost
    case hookServerStarted, hookServerFailed, hookServerStopped, hookFirstEvent, hookMessageUnreadable, hookForeignCaller
    // Requests
    case requestAsked, requestOverflow, requestEnded, requestTimedOut, requestAnswerRefused
    // Notifications
    case bannerSent, bannerFailed, bannersDenied, bannersAllowed, telegramSent, telegramFailed, telegramConnected, telegramConnectFailed, telegramDisconnected, keychainFailed, quietStarted, quietUntilOff, quietEnded
    // Sound
    case soundPlayed, soundFailed
    // Limits
    case limitsRefreshStarted, limitsRefreshDone, limitsAlreadyFresh, limitsRefreshFailed, limitsRefreshProblem, limitsRefreshSkipped
    // Settings
    case settingChanged, settingChangedHidden
    // Keys
    case hotKeyRegistered, hotKeyTaken, hotKeyOff, answerKeysTaken, answerKeysFree
    // Windows and surfaces
    case windowOpened, windowClosed, panelOpened, panelClosed
    // The Mac
    case macWoke, macSleeping, keepAwakeOn, keepAwakeOff, keepAwakeFailed

    public var level: LogLevel {
        switch self {
        case .autostartFailed, .fileWriteFailed, .hooksChangeFailed, .hookServerFailed, .bannerFailed, .keychainFailed, .soundFailed, .keepAwakeFailed:
            return .error
        case .formatIssue, .claudeFolderMissing, .fileBroken, .hooksChangeRefused, .hooksLost, .claudeSettingsUnreadable, .claudeSettingsModeLost, .hookMessageUnreadable, .hookForeignCaller,
             .requestOverflow, .requestAnswerRefused, .bannersDenied, .telegramFailed, .telegramConnectFailed, .limitsRefreshFailed, .limitsRefreshProblem, .hotKeyTaken, .answerKeysTaken:
            return .warning
        default:
            return .info
        }
    }

    public var area: LogArea {
        switch self {
        case .appStarted, .appQuit, .handedToAgent, .autostartChanged, .autostartFailed: return .app
        case .firstRead, .tokensCounted, .formatIssue, .formatFine, .claudeFolderMissing, .claudeFolderFound, .fileWriteFailed, .fileBroken: return .data
        case .hooksConnected, .hooksRepaired, .hooksDisconnected, .hooksChangeFailed, .hooksChangeRefused, .hooksStatus, .hooksLost,
             .claudeSettingsWritten, .claudeSettingsBackup, .claudeSettingsUnreadable, .claudeSettingsModeLost,
             .hookServerStarted, .hookServerFailed, .hookServerStopped, .hookFirstEvent, .hookMessageUnreadable, .hookForeignCaller:
            return .hooks
        case .requestAsked, .requestOverflow, .requestEnded, .requestTimedOut, .requestAnswerRefused: return .requests
        case .bannerSent, .bannerFailed, .bannersDenied, .bannersAllowed, .telegramSent, .telegramFailed, .telegramConnected, .telegramConnectFailed, .telegramDisconnected, .keychainFailed, .quietStarted, .quietUntilOff, .quietEnded:
            return .notifications
        case .soundPlayed, .soundFailed: return .sound
        case .limitsRefreshStarted, .limitsRefreshDone, .limitsAlreadyFresh, .limitsRefreshFailed, .limitsRefreshProblem, .limitsRefreshSkipped: return .limits
        case .settingChanged, .settingChangedHidden: return .settings
        case .hotKeyRegistered, .hotKeyTaken, .hotKeyOff, .answerKeysTaken, .answerKeysFree: return .keys
        case .windowOpened, .windowClosed, .panelOpened, .panelClosed: return .windows
        case .macWoke, .macSleeping, .keepAwakeOn, .keepAwakeOff, .keepAwakeFailed: return .system
        }
    }

    /// `%@` stands for each value, in order. A translation keeps that order.
    var template: String {
        switch self {
        case .appStarted: return L("Boris %@ started, %@")
        case .appQuit: return L("Boris quit")
        case .handedToAgent: return L("Handing over to the login agent")
        case .autostartChanged: return L("Open at login: %@")
        case .autostartFailed: return L("Could not change open at login: %@")
        case .firstRead: return L("First read of Claude's files: %@, sessions: %@")
        case .tokensCounted: return L("Tokens counted in %@")
        case .formatIssue: return L("Format problem: %@")
        case .formatFine: return L("Format is fine again")
        case .claudeFolderMissing: return L("Claude's folder not found")
        case .claudeFolderFound: return L("Claude's folder found")
        case .fileWriteFailed: return L("Could not write %@: %@")
        case .fileBroken: return L("%@ is broken, going on without it")
        case .hooksConnected: return L("Connected, asked by: %@")
        case .hooksRepaired: return L("Repaired, asked by: %@")
        case .hooksDisconnected: return L("Disconnected, asked by: %@")
        case .hooksChangeFailed: return L("Not changed, asked by: %@, %@")
        case .hooksChangeRefused: return L("A debug build leaves Claude's real settings alone, asked by: %@")
        case .hooksStatus: return L("In Claude's settings: %@")
        case .hooksLost: return L("Removed or changed by something else")
        case .claudeSettingsWritten: return L("Claude's settings written: %@")
        case .claudeSettingsBackup: return L("Copy of Claude's settings kept")
        case .claudeSettingsUnreadable: return L("Claude's settings cannot be read reliably, not writing")
        case .claudeSettingsModeLost: return L("Could not keep the permissions of Claude's settings file: %@")
        case .hookServerStarted: return L("Server started")
        case .hookServerFailed: return L("Server did not start")
        case .hookServerStopped: return L("Server stopped")
        case .hookFirstEvent: return L("First event received")
        case .hookMessageUnreadable: return L("Unreadable message from a hook")
        case .hookForeignCaller: return L("Connection from another user refused")
        case .requestAsked: return L("%@ asked, session %@")
        case .requestOverflow: return L("Too many open, %@ stays in Claude, session %@")
        case .requestEnded: return L("%@: %@, %@, after %@, session %@")
        case .requestTimedOut: return L("%@: time ran out in Boris, session %@")
        case .requestAnswerRefused: return L("Answer to %@ not taken: %@")
        case .bannerSent: return L("Sent: %@")
        case .bannerFailed: return L("Not sent: %@, %@")
        case .bannersDenied: return L("Turned off for Boris in macOS")
        case .bannersAllowed: return L("Allowed in macOS")
        case .telegramSent: return L("Telegram, sent: %@")
        case .telegramFailed: return L("Telegram, not sent: %@, %@")
        case .telegramConnected: return L("Telegram connected")
        case .telegramConnectFailed: return L("Telegram not connected: %@")
        case .telegramDisconnected: return L("Telegram disconnected")
        case .keychainFailed: return L("Could not keep the Telegram token in the Keychain")
        case .quietStarted: return L("Do not disturb on for %@")
        case .quietUntilOff: return L("Do not disturb on until turned off")
        case .quietEnded: return L("Do not disturb off")
        case .soundPlayed: return L("Played: %@")
        case .soundFailed: return L("Did not play: %@")
        case .limitsRefreshStarted: return L("Refresh started: %@")
        case .limitsRefreshDone: return L("Refreshed in %@")
        case .limitsAlreadyFresh: return L("Fresh enough, nothing started")
        case .limitsRefreshFailed: return L("Refresh failed after %@")
        case .limitsRefreshProblem: return L("Refresh problem: %@")
        case .limitsRefreshSkipped: return L("A debug build does not start Claude Code")
        case .settingChanged: return L("%@: %@")
        case .settingChangedHidden: return L("%@ changed")
        case .hotKeyRegistered: return L("Mini window key %@ registered")
        case .hotKeyTaken: return L("Mini window key %@ is taken by another app")
        case .hotKeyOff: return L("Mini window key is off")
        case .answerKeysTaken: return L("Answer keys are taken by another app")
        case .answerKeysFree: return L("Answer keys are free again")
        case .windowOpened: return L("Opened: %@")
        case .windowClosed: return L("Closed: %@")
        case .panelOpened: return L("Panel opened for a request")
        case .panelClosed: return L("Panel closed after %@, it opened: %@")
        case .macWoke: return L("The Mac woke up")
        case .macSleeping: return L("The Mac is going to sleep")
        case .keepAwakeOn: return L("Keeping the Mac awake while work runs")
        case .keepAwakeOff: return L("No longer keeping the Mac awake")
        case .keepAwakeFailed: return L("Could not keep the Mac awake")
        }
    }
}

/// The words a line can use. A closed list, so that nothing else can be said, and translated with the rest of the app.
public enum LogWord: String, Sendable, CaseIterable {
    case debugBuild, releaseBuild
    // What asked for a change of the hooks
    case connectSheet, repairInConnections, repairInDiagnostics, repairInMainWindow, repairOnRequestCard, disconnectInConnections, unknownCaller
    // Hook status
    case notInstalled, installed, outdated, disabledInSettings, disabledByPolicy, unreadable
    // A write to Claude's settings
    case hooksAdded, originalRestored, hooksRemoved, fileRemoved
    // Files of Boris's own
    case stateFile, decisionsFile, tokenCache, lossCache, ownFolder, packFolder
    // Format problems
    case unknownJournalEvent, unreadableFinal, unreadableSessions
    // How a request ended
    case allowed, denied, answered, planApproved, planDenied, expiredThenAnswered, closedInClaude
    // Where
    case requestsPage, miniWindow, panel, hotKey, inClaude, mainWindow, settingsWindow
    // Why an answer did not count
    case tooSoon, tooLate
    // What a notification was about, when it is not one event
    case awayWork, quietSummary, testMessage, other
    // Telegram
    case noConnection, badToken, badRecipient, botCannotWrite, tooOften
    // Limits
    case onSchedule, byButton, noClaudeBinary, noTerminal, couldNotStart, noFreshData, macSlept
    // Panel
    case byPointer, byRequest

    public var label: String {
        switch self {
        case .debugBuild: return L("debug build")
        case .releaseBuild: return L("installed build")
        case .connectSheet: return L("Connect button in the changes sheet")
        case .repairInConnections: return L("Repair in Connections")
        case .repairInDiagnostics: return L("Repair in Diagnostics")
        case .repairInMainWindow: return L("Repair in the main window")
        case .repairOnRequestCard: return L("Repair on a request card")
        case .disconnectInConnections: return L("Disconnect in Connections")
        case .unknownCaller: return L("unknown")
        case .notInstalled: return L("not installed")
        case .installed: return L("installed")
        case .outdated: return L("outdated")
        case .disabledInSettings: return L("turned off in Claude's settings")
        case .disabledByPolicy: return L("forbidden by policy")
        case .unreadable: return L("file cannot be read")
        case .hooksAdded: return L("hooks added")
        case .originalRestored: return L("original file put back")
        case .hooksRemoved: return L("hooks removed")
        case .fileRemoved: return L("file removed")
        case .stateFile: return L("state file")
        case .decisionsFile: return L("request history")
        case .tokenCache: return L("token cache")
        case .lossCache: return L("loss cache")
        case .ownFolder: return L("Boris's folder")
        case .packFolder: return L("walrus pack")
        case .unknownJournalEvent: return L("unknown journal event")
        case .unreadableFinal: return L("unreadable final file")
        case .unreadableSessions: return L("unreadable session files")
        case .allowed: return L("allowed")
        case .denied: return L("denied")
        case .answered: return L("answered")
        case .planApproved: return L("plan approved")
        case .planDenied: return L("plan rejected")
        case .expiredThenAnswered: return L("answered in Claude after the time ran out")
        case .closedInClaude: return L("closed in Claude")
        case .requestsPage: return L("on the Requests page")
        case .miniWindow: return L("mini window")
        case .panel: return L("panel")
        case .hotKey: return L("with a key")
        case .inClaude: return L("in Claude")
        case .mainWindow: return L("main window")
        case .settingsWindow: return L("settings window")
        case .tooSoon: return L("too soon after the card appeared")
        case .tooLate: return L("the request is no longer open")
        case .awayWork: return L("work lost while closed")
        case .quietSummary: return L("Do not disturb summary")
        case .testMessage: return L("test message")
        case .other: return L("other")
        case .noConnection: return L("no connection")
        case .badToken: return L("wrong token")
        case .badRecipient: return L("wrong recipient")
        case .botCannotWrite: return L("the bot cannot write there")
        case .tooOften: return L("too often")
        case .onSchedule: return L("on schedule")
        case .byButton: return L("by button")
        case .noClaudeBinary: return L("Claude Code not found")
        case .noTerminal: return L("no terminal for it")
        case .couldNotStart: return L("Claude Code did not start")
        case .noFreshData: return L("no fresh data came")
        case .macSlept: return L("the Mac fell asleep meanwhile")
        case .byPointer: return L("by the pointer")
        case .byRequest: return L("by a request")
        }
    }
}
