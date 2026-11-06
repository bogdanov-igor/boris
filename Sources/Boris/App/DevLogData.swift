#if DEBUG
import BorisCore
import BorisData
import Foundation

/// Invented log lines for looking at the section. Nothing here comes from a real run.
@MainActor
enum DevLogData {
    static func fill(_ model: AppModel, data: DevData, problems: Bool, huge: Bool) {
        let now = Date()
        let records: [LogRecord]
        if huge {
            records = hugeRecords(now: now)
        } else if data == .empty {
            records = []
        } else {
            records = sample(now: now, long: data == .long)
        }
        model.logFeed.showForSnapshot(records, period: huge || data == .long ? .everything : .lastHour, onlyProblems: problems)
    }

    private static func sample(now: Date, long: Bool) -> [LogRecord] {
        func at(_ minutesAgo: Double, _ message: LogMessage, _ values: LogValue...) -> LogRecord {
            LogRecord(at: now.addingTimeInterval(-minutesAgo * 60), message: message, values: values)
        }
        var sounds = at(9, .soundPlayed, .choice(WalrusSound.alarm))
        sounds.count = 4
        sounds.lastAt = sounds.at.addingTimeInterval(95)
        var lines = [
            at(58, .appStarted, .version("0.4.1"), .word(.debugBuild)),
            at(58, .hooksStatus, .word(.installed)),
            at(58, .hookServerStarted),
            at(58, .firstRead, .seconds(0.84), .number(7)),
            at(57, .tokensCounted, .seconds(31)),
            at(52, .windowOpened, .word(.mainWindow)),
            at(44, .requestAsked, .tool("Bash"), .session("3f9a11c2-77aa")),
            at(44, .requestEnded, .tool("Bash"), .word(.allowed), .word(.hotKey), .seconds(6.2), .session("3f9a11c2-77aa")),
            at(41, .bannerSent, .choice(EventKind.completed)),
            at(41, .soundPlayed, .choice(WalrusSound.done)),
            at(36, .telegramFailed, .choice(EventKind.failed), .word(.noConnection)),
            at(30, .hooksStatus, .word(.notInstalled)),
            at(30, .hooksLost),
            at(29, .hooksRepaired, .word(.repairInConnections)),
            at(29, .claudeSettingsBackup),
            at(29, .claudeSettingsWritten, .word(.hooksAdded)),
            at(21, .limitsRefreshStarted, .word(.onSchedule)),
            at(21, .limitsRefreshFailed, .seconds(26)),
            at(18, .fileWriteFailed, .word(.tokenCache), .failure(CocoaError(.fileWriteOutOfSpace))),
            at(14, .macSleeping),
            at(11, .macWoke),
            sounds,
            at(6, .requestAsked, .tool("mcp__invented__tool"), .session("a1b2c3d4-0000")),
            at(4, .requestEnded, .tool("mcp__invented__tool"), .word(.expiredThenAnswered), .word(.inClaude), .seconds(120), .session("a1b2c3d4-0000")),
            at(1, .hotKeyTaken, .keys("⌥⌘O")),
        ]
        if long {
            // Yesterday's lines bring in the heading for the day, and the longest words show how a line wraps.
            lines.insert(contentsOf: [
                at(26 * 60, .appStarted, .version("0.4.0-beta.1+build.77"), .word(.releaseBuild)),
                at(25 * 60, .hooksChangeFailed, .word(.repairOnRequestCard), .failure(CocoaError(.fileWriteVolumeReadOnly))),
                at(25 * 60, .hooksChangeRefused, .word(.repairInMainWindow)),
                at(24.5 * 60, .requestAnswerRefused, .tool("AskUserQuestion"), .word(.tooSoon)),
            ], at: 0)
            lines.append(at(0.5, .requestEnded, .tool("AskUserQuestion"), .word(.expiredThenAnswered), .word(.requestsPage), .seconds(599), .session("ffffffff-ffff")))
        }
        return lines
    }

    /// About what a full file holds: 5 MB of lines over a day.
    private static func hugeRecords(now: Date) -> [LogRecord] {
        let count = 60_000
        let step = 23 * 3600.0 / Double(count)
        return (0..<count).map { index in
            let at = now.addingTimeInterval(-Double(count - index) * step)
            switch index % 7 {
            case 0: return LogRecord(at: at, message: .requestAsked, values: [.tool("Bash"), .session("3f9a11c2")])
            case 1: return LogRecord(at: at, message: .requestEnded, values: [.tool("Bash"), .word(.allowed), .word(.miniWindow), .seconds(4), .session("3f9a11c2")])
            case 2: return LogRecord(at: at, message: .soundPlayed, values: [.choice(WalrusSound.done)])
            case 3: return LogRecord(at: at, message: .bannerSent, values: [.choice(EventKind.completed)])
            case 4: return LogRecord(at: at, message: .telegramFailed, values: [.choice(EventKind.failed), .word(.noConnection)])
            case 5: return LogRecord(at: at, message: .hooksStatus, values: [.word(.installed)])
            default: return LogRecord(at: at, message: .fileWriteFailed, values: [.word(.tokenCache), .failure(CocoaError(.fileWriteOutOfSpace))])
            }
        }
    }
}
#endif
