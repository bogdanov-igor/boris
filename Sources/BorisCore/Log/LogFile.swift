import Foundation

/// How lines look in the file: one per line, fields split by tabs, readable with `cat`.
///
///     2026-11-06T11:02:11.123Z  warning  hooks  hooksLost
///     2026-11-06T11:02:40.000Z  +  4
///
/// A `+` line says that the line above happened that many more times, the last of them at its own time.
/// Reading is strict: whatever does not parse in full is left out, so a damaged file costs only its damaged lines.
public enum LogFile {
    public static func line(_ record: LogRecord) -> String {
        var fields = [stamp(record.at), record.level.rawValue, record.area.rawValue, record.message.rawValue]
        fields += record.values.map(\.stored)
        return fields.joined(separator: "\t") + "\n"
    }

    public static func repeatLine(at: Date, extra: Int) -> String {
        "\(stamp(at))\t+\t\(extra)\n"
    }

    /// A record with its repeats folded in, as one line followed by one `+` line.
    public static func lines(_ record: LogRecord) -> String {
        record.count > 1 ? line(record) + repeatLine(at: record.lastAt, extra: record.count - 1) : line(record)
    }

    /// The time of a line, if the bytes begin with a whole one.
    public static func time(atStartOf bytes: UnsafeBufferPointer<UInt8>) -> Date? {
        guard bytes.count >= stampLength else { return nil }
        return parseStamp(UnsafeBufferPointer(rebasing: bytes[0..<stampLength]))
    }

    public static func parse(_ data: Data) -> [LogRecord] {
        var records: [LogRecord] = []
        records.reserveCapacity(data.count / 80)
        var messages: [String: LogMessage] = [:]
        for message in LogMessage.allCases { messages[message.rawValue] = message }

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            var start = 0
            var lastKept = false
            // Without its line end the last line may have been cut off in a crash.
            while let end = find(0x0A, in: bytes, from: start) {
                lastKept = add(UnsafeBufferPointer(rebasing: bytes[start..<end]), to: &records, messages: messages, lastKept: lastKept)
                start = end + 1
            }
        }
        return records
    }

    private static func find(_ byte: UInt8, in bytes: UnsafeBufferPointer<UInt8>, from start: Int) -> Int? {
        guard let base = bytes.baseAddress, start < bytes.count, let found = memchr(base + start, Int32(byte), bytes.count - start) else { return nil }
        return UnsafeRawPointer(found) - UnsafeRawPointer(base)
    }

    /// Says whether the line was kept. A count belongs only to the line right above it, so when that one is damaged its count goes with it.
    private static func add(_ line: UnsafeBufferPointer<UInt8>, to records: inout [LogRecord], messages: [String: LogMessage], lastKept: Bool) -> Bool {
        guard line.count > stampLength, line[stampLength] == 0x09, let time = parseStamp(UnsafeBufferPointer(rebasing: line[0..<stampLength])) else { return false }
        var fields: [String] = []
        var start = stampLength + 1
        while start <= line.count {
            let end = find(0x09, in: line, from: start) ?? line.count
            fields.append(String(decoding: line[start..<end], as: UTF8.self))
            start = end + 1
        }
        if fields.first == "+" {
            guard lastKept, fields.count == 2, let extra = Int(fields[1]), extra > 0, !records.isEmpty else { return false }
            records[records.count - 1].count += extra
            records[records.count - 1].lastAt = time
            return true
        }
        guard fields.count >= 3, let message = messages[fields[2]] else { return false }
        var values: [LogValue] = []
        values.reserveCapacity(fields.count - 3)
        for field in fields[3...] {
            guard let value = LogValue(stored: field) else { return false }
            values.append(value)
        }
        records.append(LogRecord(at: time, message: message, values: values))
        return true
    }

    // MARK: - Time

    private static let stampLength = 24

    /// `2026-11-06T11:02:11.123Z`. Done by hand, because a formatter is the slowest thing in reading a whole file of these.
    public static func stamp(_ date: Date) -> String {
        let interval = date.timeIntervalSince1970
        var seconds = time_t(interval.rounded(.down))
        let thousandths = min(999, max(0, Int((interval - interval.rounded(.down)) * 1000)))
        var parts = tm()
        gmtime_r(&seconds, &parts)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ", parts.tm_year + 1900, parts.tm_mon + 1, parts.tm_mday, parts.tm_hour, parts.tm_min, parts.tm_sec, thousandths)
    }

    private static func parseStamp(_ text: UnsafeBufferPointer<UInt8>) -> Date? {
        guard text.count == stampLength, text[4] == 0x2D, text[7] == 0x2D, text[10] == 0x54, text[13] == 0x3A, text[16] == 0x3A, text[19] == 0x2E, text[23] == 0x5A else { return nil }
        func number(_ from: Int, _ to: Int) -> Int? {
            var value = 0
            for index in from..<to {
                guard (0x30...0x39).contains(text[index]) else { return nil }
                value = value * 10 + Int(text[index] - 0x30)
            }
            return value
        }
        guard let year = number(0, 4), let month = number(5, 7), let day = number(8, 10), let hour = number(11, 13), let minute = number(14, 16), let second = number(17, 19), let thousandths = number(20, 23),
              (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 62
        else { return nil }
        // Days from the civil date, with the year starting in March so that the leap day comes last.
        let shifted = month <= 2 ? year - 1 : year
        let era = shifted / 400
        let yearOfEra = shifted - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        let days = era * 146_097 + dayOfEra - 719_468
        return Date(timeIntervalSince1970: Double(days * 86400 + hour * 3600 + minute * 60 + second) + Double(thousandths) / 1000)
    }
}
