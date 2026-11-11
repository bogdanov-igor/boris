import Foundation

// The hidden things around the walrus. This is the one list of them, and no page for the person mentions it.
//
// Done on purpose, as often as the person likes:
// - Clicks in a row (`PokeLadder`): a bellow at 3, "Enough" at 7, his back at 15, a full turn at 30, the credits at 50.
// - "угу" or "ugu" typed in the main window: a bellow.
// - His name, "boris" or "борис", typed in the main window: a wink and a word.
// - The Konami code typed in the main window: a minute in the pixel outfit and a refusal to surrender to codes.
// Once a day at most, on their own (`EggDiary`):
// - 30 November, Churchill's birthday: the party hat by the calendar, and a line on the first click of the day.
// - Night shift: work running between midnight and five, one line a night.
// - A round figure: the day's tokens pass a hundred million, or ten times that, one dry remark.
// - The weekly limit spent: a yawn and a line.
// By the calendar: upside down on 1 April, a crow on Friday the 13th, pixels on the 256th day, a party after ten clean runs, a fish after a hundred.
//
// None of them blocks anything, plays a sound or shows anything of the person's work: only figures and dates.
// Nothing runs for them between events: the keys are looked at only when pressed, the rest only when a scan brings news.

/// A trick typed at the walrus.
public enum KeyTrick: Sendable, Equatable {
    case konami, name, hoot
}

/// A hidden thing that comes on its own, at most once a day.
public enum Surprise: Sendable, Equatable {
    case birthday, nightShift, weekSpent
    case roundTokens(Int)

    var key: String {
        switch self {
        case .birthday: return "birthday"
        case .nightShift: return "nightShift"
        case .weekSpent: return "weekSpent"
        case .roundTokens: return "roundTokens"
        }
    }

    /// What he does along with the line. The poses and reactions are the ones he already has.
    public var act: Act? {
        switch self {
        case .weekSpent: return .yawn
        case .roundTokens: return .wink
        case .birthday, .nightShift: return nil
        }
    }
}

/// Which of the surprises have had their day. Day keys only.
public struct EggDiary: Codable, Sendable, Equatable {
    /// The smallest figure worth a remark. A day of real work passes a million tokens before lunch.
    public static let firstRoundFigure = 100_000_000

    private var said: [String: String] = [:]

    public init() {}

    /// What may be said on its own now, if anything. Saying it is the caller's business, and then `note`.
    public func due(now: Date, working: Bool, tokensToday: Int, weekSpent: Bool, calendar: Calendar = .current) -> Surprise? {
        let today = Self.day(now, calendar)
        if weekSpent, said[Surprise.weekSpent.key] != today { return .weekSpent }
        if working, calendar.component(.hour, from: now) < 5, said[Surprise.nightShift.key] != today { return .nightShift }
        if let figure = Self.roundFigure(tokensToday), said[Surprise.roundTokens(figure).key] != today { return .roundTokens(figure) }
        return nil
    }

    /// The first click on Churchill's birthday.
    public func birthdayDue(now: Date, calendar: Calendar = .current) -> Bool {
        let c = calendar.dateComponents([.month, .day], from: now)
        return c.month == 11 && c.day == 30 && said[Surprise.birthday.key] != Self.day(now, calendar)
    }

    public mutating func note(_ surprise: Surprise, now: Date, calendar: Calendar = .current) {
        said[surprise.key] = Self.day(now, calendar)
    }

    /// The largest power of ten the day's tokens have reached, from a hundred million up.
    static func roundFigure(_ tokens: Int) -> Int? {
        guard tokens >= firstRoundFigure else { return nil }
        var figure = firstRoundFigure
        while figure <= tokens / 10 { figure *= 10 }
        return figure
    }

    /// A weekly window used up and not yet renewed. The per-model weeks and spare money do not count.
    public static func weekSpent(_ usage: UsageSnapshot?, now: Date) -> Bool {
        usage?.windows.contains { $0.kind == .week && $0.percent >= 100 && ($0.resetsAt.map { $0 > now } ?? true) } ?? false
    }

    private static func day(_ date: Date, _ calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
