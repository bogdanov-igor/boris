import Foundation

/// The time a list is limited to.
public enum WorkPeriod: Sendable, Hashable {
    case today, week, month
    case dates(from: Date, to: Date)

    /// From the start of the first day to the end of the last.
    public func days(now: Date, calendar: Calendar = .current) -> ClosedRange<Date> {
        let start: Date
        let end: Date
        switch self {
        case .today: (start, end) = (now, now)
        case .week: (start, end) = (calendar.date(byAdding: .day, value: -6, to: now) ?? now, now)
        case .month: (start, end) = (calendar.date(byAdding: .day, value: -29, to: now) ?? now, now)
        case .dates(let from, let to): (start, end) = (min(from, to), max(from, to))
        }
        let first = calendar.startOfDay(for: start)
        let afterLast = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end)) ?? end
        return first...afterLast.addingTimeInterval(-1)
    }
}

extension WorkFormat {
    /// `30 октября`, or `October 30`.
    public static func day(_ date: Date, timeZone: TimeZone = .current) -> String {
        formatted(date, Localizer.locale.identifier == "ru" ? "d MMMM" : "MMMM d", timeZone: timeZone)
    }

    /// `30.10` or `10/30`, for tight places.
    public static func shortDay(_ date: Date, timeZone: TimeZone = .current) -> String {
        formatted(date, Localizer.locale.identifier == "ru" ? "d.MM" : "M/d", timeZone: timeZone)
    }

    /// `Today 15:10` or `4.11 · 11:05`.
    public static func moment(_ date: Date, now: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        if calendar.isDate(date, inSameDayAs: now) { return L("Today %@", time(date, timeZone: timeZone)) }
        return "\(shortDay(date, timeZone: timeZone)) · \(time(date, timeZone: timeZone))"
    }

    private static func formatted(_ date: Date, _ pattern: String, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Localizer.locale
        formatter.timeZone = timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}
