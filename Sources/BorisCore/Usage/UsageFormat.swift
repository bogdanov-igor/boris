import Foundation

/// Words and numbers of the usage page. They live here so that a test can read them without a window.
public enum UsageFormat {
    /// `12,40 $`, `$12.40`, `50 $`. Cents are left out only when there are none.
    public static func money(_ value: Double, currency: String = "USD", locale: Locale = Localizer.locale) -> String {
        let cents = value.rounded() == value ? 0 : 2
        return value.formatted(.currency(code: currency).locale(locale).precision(.fractionLength(cents)))
    }

    /// The total of a sum that may not be known yet: before the first pass over the logs there is no number, and zero would be a wrong one.
    public static func total(_ usage: TokenUsage?) -> String {
        usage.map { WorkFormat.tokens($0.total) } ?? L("no data")
    }

    /// Always with the sign that says it is not a measured sum.
    public static func estimate(_ estimate: SpendEstimate, locale: Locale = Localizer.locale) -> String {
        guard estimate.isKnown else { return L("no data") }
        // A sum too small to write is still not zero.
        let dollars = estimate.dollars > 0 ? max(estimate.dollars, 0.01) : 0
        return "≈ \(money(dollars.rounded(toPlaces: 2), locale: locale))"
    }

    /// What the sum means depends on who is looking: for a subscriber it is not money that left.
    public static func estimateNote(account: ClaudeAccount) -> String {
        switch account {
        case .signedIn, .unknown:
            return L("This is what these tokens would cost through the API. It is not a charge.")
        case .apiKey:
            return L("An approximate cost at API prices. The exact sum is on your bill.")
        case .gateway:
            return L("An approximate cost at API prices. Your gateway's prices may differ.")
        }
    }

    public static func windowTitle(_ window: UsageWindow) -> String {
        switch window.kind {
        case .fiveHour: return L("5 hours")
        case .week: return L("Week")
        case .weekModel(let name): return L("Week, %@", name)
        case .extraSpend: return ""
        }
    }

    public static func periodTitle(_ period: UsagePeriod) -> String {
        switch period {
        case .today: return L("Today")
        case .week: return L("7 days")
        case .month: return L("30 days")
        case .all: return L("All time")
        }
    }

    /// Goes after the total: `9,21 млн за 7 дней`.
    public static func periodCaption(_ period: UsagePeriod) -> String {
        switch period {
        case .today: return L("for today")
        case .week: return L("for 7 days")
        case .month: return L("for 30 days")
        case .all: return L("for all time")
        }
    }

    public static func breakdownTitle(_ breakdown: TokenBreakdown) -> String {
        switch breakdown {
        case .days: return L("Days")
        case .environments: return L("Environments")
        case .projects: return L("Projects")
        case .models: return L("Models")
        case .agents: return L("Agents")
        }
    }

    /// The name of a row in a breakdown.
    public static func lineTitle(_ key: TokenLine.Key, today: String, mode: DisplayMode, locale: Locale = Localizer.locale) -> String {
        switch key {
        case .day(let day):
            return dayTitle(day, today: today, locale: locale)
        case .environment(let environment):
            return WorkPhrases.environment(environment)
        case .project(let path):
            guard let path, !path.isEmpty else { return L("No project") }
            return URL(fileURLWithPath: path).lastPathComponent
        case .model(let model):
            guard let model else { return L("Unknown model") }
            return mode == .technical ? model : ModelName.display(model) ?? model
        case .agents(.main):
            return L("Main agents")
        case .agents(.subagents):
            return mode == .technical ? L("Subagents") : L("Helpers")
        case .agents(.workflow):
            return mode == .technical ? L("Workflow agents") : L("Helpers in big tasks")
        }
    }

    /// `Сегодня`, `30.10`, and with the year once it is not this one.
    public static func dayTitle(_ day: String, today: String, locale: Locale = Localizer.locale) -> String {
        if day == today { return L("Today") }
        guard let date = parseDay(day) else { return day }
        let russian = locale.identifier.hasPrefix("ru")
        let sameYear = day.prefix(4) == today.prefix(4)
        return text(date, russian ? (sameYear ? "d.MM" : "d.MM.yy") : (sameYear ? "MMM d" : "MMM d, yyyy"), locale: locale)
    }

    /// `12 сентября`, `September 12`, with the year when it is not this one.
    public static func longDay(_ day: String, today: String, locale: Locale = Localizer.locale) -> String {
        guard let date = parseDay(day) else { return day }
        let russian = locale.identifier.hasPrefix("ru")
        let sameYear = day.prefix(4) == today.prefix(4)
        return text(date, russian ? (sameYear ? "d MMMM" : "d MMMM yyyy") : (sameYear ? "MMMM d" : "MMMM d, yyyy"), locale: locale)
    }

    private static let utc = TimeZone(identifier: "UTC") ?? .current

    private static func parseDay(_ day: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = utc
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: day)
    }

    private static func text(_ date: Date, _ pattern: String, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = utc
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let scale = pow(10, Double(places))
        return (self * scale).rounded() / scale
    }
}
