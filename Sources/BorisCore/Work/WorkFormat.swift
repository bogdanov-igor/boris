import Foundation

/// Numbers and dates as the interface writes them, in the chosen language.
public enum WorkFormat {
    private static func number(_ value: Double, digits: Int) -> String {
        value.formatted(.number.precision(.fractionLength(0...digits)).locale(Localizer.locale))
    }

    /// `950`, `12,3 тыс.`, `1,84 млн`.
    public static func tokens(_ value: Int) -> String {
        switch value {
        case ..<1000:
            return "\(value)"
        case ..<1_000_000:
            let thousands = Double(value) / 1000
            return L("%@K", number(thousands, digits: thousands < 100 ? 1 : 0))
        default:
            let millions = Double(value) / 1_000_000
            return L("%@M", number(millions, digits: millions < 100 ? 2 : 0))
        }
    }

    public static func percent(_ value: Double) -> String {
        L("%lld%%", Int(value.rounded()))
    }

    public static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 1 { return L("less than a minute") }
        if minutes < 60 { return L("%lld min", minutes) }
        let days = minutes / (24 * 60)
        if days > 0 { return L("%lld d %lld h", days, minutes / 60 % 24) }
        return L("%lld h %lld min", minutes / 60, minutes % 60)
    }

    public static func ago(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return L("%lld s ago", max(0, Int(seconds))) }
        if seconds < 3600 { return L("%lld min ago", Int(seconds / 60)) }
        if seconds < 24 * 3600 { return L("%lld h %lld min ago", Int(seconds / 3600), Int(seconds / 60) % 60) }
        return L("%lld d ago", Int(seconds / (24 * 3600)))
    }

    public static func time(_ date: Date, timeZone: TimeZone = .current) -> String {
        format(date, "HH:mm", timeZone: timeZone)
    }

    /// Today by the hour, otherwise by the day.
    public static func resets(_ date: Date, now: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        if calendar.isDate(date, inSameDayAs: now) { return L("resets at %@", time(date, timeZone: timeZone)) }
        return L("resets %@", format(date, date.timeIntervalSince(now) < 6 * 24 * 3600 ? "EEEE" : "d MMMM", timeZone: timeZone))
    }

    /// `четверг, 5 ноября · 16:21`.
    public static func today(_ date: Date, timeZone: TimeZone = .current) -> String {
        "\(format(date, Localizer.locale.identifier == "ru" ? "EEEE, d MMMM" : "EEEE, MMMM d", timeZone: timeZone)) · \(time(date, timeZone: timeZone))"
    }

    private static func format(_ date: Date, _ pattern: String, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Localizer.locale
        formatter.timeZone = timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}
