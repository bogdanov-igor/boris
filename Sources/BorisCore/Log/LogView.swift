import Foundation

/// A line as the viewer shows it, already in the language of the interface.
public struct LogRow: Sendable, Equatable {
    public let at: Date
    public let lastAt: Date
    public let level: LogLevel
    /// A heading for the day the lines below it belong to, since a line shows only the time.
    public let isDay: Bool
    /// Year and day of the year, for telling days apart without a calendar.
    public let day: Int
    public let time: String
    public let levelWord: String
    public let area: String
    public let text: String
    /// How long the part that wraps is, counted once because every row's height is asked for at every reload.
    public let messageLength: Int

    init(at: Date, lastAt: Date, level: LogLevel, isDay: Bool, day: Int, time: String, levelWord: String, area: String, text: String) {
        self.at = at
        self.lastAt = lastAt
        self.level = level
        self.isDay = isDay
        self.day = day
        self.time = time
        self.levelWord = levelWord
        self.area = area
        self.text = text
        messageLength = isDay ? text.count : area.count + 2 + text.count
    }

    /// The part that wraps.
    public var message: String { isDay ? text : "\(area): \(text)" }

    /// What goes into a bug report.
    public var plain: String { isDay ? text : "\(time) \(levelWord) \(area): \(text)" }
}

/// Turns records into rows. A whole file goes through this at once, so what stays the same from line to line is looked up only once.
public struct LogRenderer {
    private var templates: [LogMessage: String] = [:]
    private let levels: [LogLevel: String]
    private let areas: [LogArea: String]
    private let repeated: String

    public init() {
        levels = Dictionary(uniqueKeysWithValues: LogLevel.allCases.map { ($0, $0.label) })
        areas = Dictionary(uniqueKeysWithValues: LogArea.allCases.map { ($0, $0.label) })
        repeated = L("×%@, until %@")
    }

    public mutating func row(_ record: LogRecord) -> LogRow {
        let template: String
        if let known = templates[record.message] {
            template = known
        } else {
            template = record.message.template
            templates[record.message] = template
        }
        var text = LogRecord.fill(template, record.values.map(\.shown))
        if record.count > 1 {
            text += " " + LogRecord.fill(repeated, [String(record.count), LogView.time(record.lastAt)])
        }
        return LogRow(
            at: record.at,
            lastAt: record.lastAt,
            level: record.level,
            isDay: false,
            day: LogView.day(record.at),
            time: LogView.time(record.at),
            levelWord: levels[record.level] ?? record.level.rawValue,
            area: areas[record.area] ?? record.area.rawValue,
            text: text
        )
    }
}

public enum LogView {
    public enum Period: String, Sendable, CaseIterable {
        case lastHour, everything
    }

    /// How much of a period counts as the last hour.
    public static let hour: TimeInterval = 3600

    /// What is shown for a period and a filter, oldest first, with a heading wherever the day changes. A heading for today is left out when the whole list is today.
    public static func arrange(_ rows: [LogRow], period: Period, onlyProblems: Bool, now: Date) -> [LogRow] {
        let from = now.addingTimeInterval(-hour)
        var shown: [LogRow] = []
        shown.reserveCapacity(rows.count)
        var lastDay = day(now)
        for row in rows {
            if period == .lastHour, row.lastAt < from { continue }
            if onlyProblems, row.level == .info { continue }
            if row.day != lastDay { shown.append(heading(for: row.at, day: row.day)) }
            lastDay = row.day
            shown.append(row)
        }
        return shown
    }

    /// Adds a new line to what is shown, with a heading if it starts a new day.
    public static func append(_ row: LogRow, to shown: inout [LogRow], onlyProblems: Bool) {
        if onlyProblems, row.level == .info { return }
        if let last = shown.last, last.day != row.day { shown.append(heading(for: row.at, day: row.day)) }
        shown.append(row)
    }

    public static func copyText(_ rows: [LogRow], period: Period, now: Date) -> String {
        let name = period == .lastHour ? L("last hour") : L("everything kept")
        let lines = rows.filter { !$0.isDay }.count
        let header = LogRecord.fill(L("Boris log, %@, lines: %@, copied %@"), [name, String(lines), stampLocal(now)])
        return ([header] + rows.map(\.plain)).joined(separator: "\n") + "\n"
    }

    private static func heading(for date: Date, day: Int) -> LogRow {
        let formatter = DateFormatter()
        formatter.locale = Localizer.locale
        formatter.setLocalizedDateFormatFromTemplate("d MMMM")
        return LogRow(at: date, lastAt: date, level: .info, isDay: true, day: day, time: "", levelWord: "", area: "", text: formatter.string(from: date))
    }

    private static func parts(_ date: Date) -> tm {
        var seconds = time_t(date.timeIntervalSince1970.rounded(.down))
        var parts = tm()
        localtime_r(&seconds, &parts)
        return parts
    }

    static func day(_ date: Date) -> Int {
        let parts = parts(date)
        return Int(parts.tm_year) * 1000 + Int(parts.tm_yday)
    }

    /// `14:02:11`, by hand for the same reason as the stamps in the file.
    static func time(_ date: Date) -> String {
        let parts = parts(date)
        let digits = [Int(parts.tm_hour) / 10, Int(parts.tm_hour) % 10, -1, Int(parts.tm_min) / 10, Int(parts.tm_min) % 10, -1, Int(parts.tm_sec) / 10, Int(parts.tm_sec) % 10]
        return String(decoding: digits.map { $0 < 0 ? UInt8(0x3A) : UInt8(0x30 + $0) }, as: UTF8.self)
    }

    private static func stampLocal(_ date: Date) -> String {
        let parts = parts(date)
        return String(format: "%04d-%02d-%02d %@", parts.tm_year + 1900, parts.tm_mon + 1, parts.tm_mday, time(date))
    }

    /// How many lines a text takes when it breaks at spaces, in a font whose characters are all of one width.
    /// Row heights come from this, so that the viewer never has to measure sixty thousand strings.
    public static func lines(of text: String, perLine: Int) -> Int {
        guard perLine > 0 else { return 1 }
        var lines = 1
        var used = 0
        for word in text.split(separator: " ", omittingEmptySubsequences: false) {
            let length = word.count
            if used > 0, used + 1 + length > perLine {
                lines += 1
                used = 0
            }
            if used > 0 { used += 1 }
            used += length
            // A word longer than a whole line goes on over as many as it takes.
            while used > perLine {
                lines += 1
                used -= perLine
            }
        }
        return lines
    }
}

/// Notes only opening and closing that mean something: moving the pointer past the panel must not fill the log.
public struct PanelLogTrack: Sendable {
    /// Open for less than this, the pointer was only passing by.
    static let passingBy: TimeInterval = 2

    private var openedAt: Date?
    private var byRequest = false

    public init() {}

    public mutating func note(isOpen: Bool, hovering: Bool, now: Date = Date()) {
        if isOpen {
            guard openedAt == nil else { return }
            openedAt = now
            byRequest = !hovering
            if byRequest { AppLog.note(.panelOpened) }
        } else if let opened = openedAt {
            openedAt = nil
            let stayed = now.timeIntervalSince(opened)
            if byRequest || stayed >= Self.passingBy {
                AppLog.note(.panelClosed, .seconds(stayed), .word(byRequest ? .byRequest : .byPointer))
            }
        }
    }
}
