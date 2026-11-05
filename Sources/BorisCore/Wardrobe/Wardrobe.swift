import Foundation

public enum Outfit: String, Codable, Sendable, CaseIterable {
    case none, santa, witch, party, scholar, nightcap, pixel, hearts, flower, crow, fish
}

public enum WardrobeMode: Codable, Sendable, Equatable {
    case byDate
    case manual(Outfit)
    case off
}

public struct WardrobeSettings: Codable, Sendable, Equatable {
    public var mode: WardrobeMode
    /// Month and day only: the year is never needed.
    public var userBirthday: MonthDay?
    public var firstLaunch: Date?
    /// The pack in use instead of the built-in walrus, by its folder on the shelf.
    public var pack: String?

    public init(mode: WardrobeMode = .byDate, userBirthday: MonthDay? = nil, firstLaunch: Date? = nil, pack: String? = nil) {
        self.mode = mode
        self.userBirthday = userBirthday
        self.firstLaunch = firstLaunch
        self.pack = pack
    }
}

public struct MonthDay: Codable, Sendable, Equatable {
    public var month: Int
    public var day: Int

    public init(month: Int, day: Int) {
        self.month = month
        self.day = day
    }
}

public enum Wardrobe {
    /// - Parameter rewardParty: a party hat earned by a clean streak, for the rest of the day.
    public static func outfit(at date: Date, settings: WardrobeSettings, rewardParty: Bool = false, calendar: Calendar = .current) -> Outfit {
        switch settings.mode {
        case .off: return .none
        case .manual(let outfit): return outfit
        case .byDate: break
        }
        if rewardParty || isBirthday(date, settings: settings, calendar: calendar) { return .party }
        let c = calendar.dateComponents([.month, .day, .weekday, .hour], from: date)
        guard let month = c.month, let day = c.day else { return .none }
        if day == 13, c.weekday == 6 { return .crow }
        if let dated = dateOutfit(month: month, day: day, date: date, calendar: calendar) { return dated }
        if let hour = c.hour, hour < 5 { return .nightcap }
        return .none
    }

    public static func isAprilFools(_ date: Date, calendar: Calendar = .current) -> Bool {
        let c = calendar.dateComponents([.month, .day], from: date)
        return c.month == 4 && c.day == 1
    }

    private static func dateOutfit(month: Int, day: Int, date: Date, calendar: Calendar) -> Outfit? {
        switch (month, day) {
        case (12, 20...31), (1, 1...10): return .santa
        case (10, 25...31): return .witch
        case (2, 14): return .hearts
        case (3, 8): return .flower
        case (9, 1): return .scholar
        default:
            return calendar.ordinality(of: .day, in: .year, for: date) == 256 ? .pixel : nil
        }
    }

    private static func isBirthday(_ date: Date, settings: WardrobeSettings, calendar: Calendar) -> Bool {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        if let birthday = settings.userBirthday, birthday.month == c.month, birthday.day == c.day { return true }
        if let first = settings.firstLaunch {
            let f = calendar.dateComponents([.year, .month, .day], from: first)
            return f.month == c.month && f.day == c.day && (c.year ?? 0) > (f.year ?? 0)
        }
        return false
    }
}
