import Foundation
import Testing
@testable import BorisCore

/// The hidden things around the walrus, on a made-up clock and made-up keys. The list of them is in `Eggs.swift`.
@Suite("eggs")
struct EggTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int, hour: Int = 12, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: hour, minute: minute))!
    }

    private func due(_ diary: EggDiary, _ now: Date, working: Bool = false, tokens: Int = 0, weekSpent: Bool = false) -> Surprise? {
        diary.due(now: now, working: working, tokensToday: tokens, weekSpent: weekSpent, calendar: calendar)
    }

    @Test("Набрано его имя: он подмигивает, в обеих раскладках и любом регистре", arguments: ["boris", "борис", "Boris", "БОРИС"])
    func name(word: String) {
        var play = Play()
        var tricks: [KeyTrick?] = []
        for letter in word { tricks.append(play.key(.character(String(letter)), now: t0)) }
        #expect(tricks.last == .name)
        #expect(tricks.dropLast().allSatisfy { $0 == nil })
        #expect(play.current(now: at(0.5), restricted: false)?.act == .wink)
    }

    @Test("Код Konami называет себя, неполный нет")
    func konamiIsATrick() {
        var play = Play()
        let code: [PlayKey] = [.up, .up, .down, .down, .left, .right, .left, .right, .character("b"), .character("a")]
        let tricks = code.map { play.key($0, now: t0) }
        #expect(tricks.last == .konami)
        let again = play.key(.character("b"), now: t0)
        #expect(again == nil)
    }

    @Test("30 ноября: колпак по календарю и одна реплика на первый клик дня")
    func birthday() {
        let day = date(2026, 11, 30, hour: 10)
        #expect(Wardrobe.outfit(at: day, settings: WardrobeSettings(), calendar: calendar) == .party)
        #expect(Wardrobe.outfit(at: day, settings: WardrobeSettings(mode: .off), calendar: calendar) == .none)
        var diary = EggDiary()
        #expect(!diary.birthdayDue(now: date(2026, 11, 29), calendar: calendar))
        #expect(diary.birthdayDue(now: day, calendar: calendar))
        diary.note(.birthday, now: day, calendar: calendar)
        #expect(!diary.birthdayDue(now: date(2026, 11, 30, hour: 23), calendar: calendar))
        #expect(diary.birthdayDue(now: date(2027, 11, 30), calendar: calendar))
    }

    @Test("Ночная смена: работа после полуночи, одна реплика за ночь")
    func nightShift() {
        var diary = EggDiary()
        let night = date(2026, 11, 12, hour: 2)
        #expect(due(diary, night) == nil)
        #expect(due(diary, date(2026, 11, 12, hour: 6), working: true) == nil)
        #expect(due(diary, night, working: true) == .nightShift)
        diary.note(.nightShift, now: night, calendar: calendar)
        #expect(due(diary, date(2026, 11, 12, hour: 4, minute: 59), working: true) == nil)
        #expect(due(diary, date(2026, 11, 13, hour: 1), working: true) == .nightShift)
    }

    @Test("Круглая цифра: от ста миллионов токенов за день, одна сухая реплика в день")
    func roundFigure() {
        var diary = EggDiary()
        let noon = date(2026, 11, 12)
        #expect(due(diary, noon, tokens: 99_999_999) == nil)
        #expect(due(diary, noon, tokens: 100_000_000) == .roundTokens(100_000_000))
        #expect(due(diary, noon, tokens: 2_500_000_000) == .roundTokens(1_000_000_000))
        diary.note(.roundTokens(100_000_000), now: noon, calendar: calendar)
        #expect(due(diary, date(2026, 11, 12, hour: 20), tokens: 1_200_000_000) == nil)
        #expect(due(diary, date(2026, 11, 13), tokens: 150_000_000) == .roundTokens(100_000_000))
    }

    @Test("Недельный лимит исчерпан: только неделя, только пока не обновилась")
    func weekSpent() {
        let now = date(2026, 11, 12)
        let later = now.addingTimeInterval(3600)
        func usage(_ kind: UsageWindow.Kind, _ percent: Double, resets: Date? = nil) -> UsageSnapshot {
            UsageSnapshot(windows: [UsageWindow(id: "w", kind: kind, percent: percent, resetsAt: resets)])
        }
        #expect(EggDiary.weekSpent(usage(.week, 100, resets: later), now: now))
        #expect(EggDiary.weekSpent(usage(.week, 100), now: now))
        #expect(!EggDiary.weekSpent(usage(.week, 99), now: now))
        #expect(!EggDiary.weekSpent(usage(.week, 100, resets: now.addingTimeInterval(-1)), now: now))
        #expect(!EggDiary.weekSpent(usage(.fiveHour, 100), now: now))
        #expect(!EggDiary.weekSpent(usage(.weekModel("opus"), 100), now: now))
        #expect(!EggDiary.weekSpent(nil, now: now))

        var diary = EggDiary()
        #expect(due(diary, date(2026, 11, 12, hour: 2), working: true, tokens: 200_000_000, weekSpent: true) == .weekSpent)
        #expect(Surprise.weekSpent.act == .yawn)
        diary.note(.weekSpent, now: now, calendar: calendar)
        #expect(due(diary, now, weekSpent: true) == nil)
    }

    @Test("Своя реплика не перебивает ни сказанное, ни свежую реплику о работе")
    func remarkWaits() {
        var speech = WalrusSpeech()
        speech.hear(.failure, project: nil, now: t0, lines: { _ in ["Упал"] })
        let overLine = speech.remark("Сам", now: at(1))
        #expect(!overLine)
        #expect(speech.line(now: at(1))?.text == "Упал")
        let rightAfter = speech.remark("Сам", now: at(WalrusSpeech.shownFor + 1))
        #expect(!rightAfter)
        let later = speech.remark("Сам", now: at(WalrusSpeech.quietGap))
        #expect(later)
        #expect(speech.line(now: at(WalrusSpeech.quietGap + 1))?.text == "Сам")
        speech.hear(.failure, project: nil, now: at(WalrusSpeech.quietGap + 2), lines: { _ in ["Упал снова"] })
        #expect(speech.line(now: at(WalrusSpeech.quietGap + 3))?.text == "Упал снова")
    }

    @Test("У каждого сюрприза короткая реплика без длинного тире, а цифра в ней названа")
    func lines() {
        let all = [KeyTrick.konami, .name, .hoot].map(WalrusLines.trick) + [Surprise.birthday, .nightShift, .weekSpent, .roundTokens(100_000_000)].map(WalrusLines.surprise)
        for line in all {
            #expect(!line.isEmpty)
            #expect(!line.contains("—"))
            #expect(line.count <= 100)
        }
        #expect(WalrusLines.surprise(.roundTokens(100_000_000)).contains(WorkFormat.tokens(100_000_000)))
    }

    @Test("Дневник переживает кодирование")
    func diaryCodable() throws {
        var diary = EggDiary()
        diary.note(.nightShift, now: t0, calendar: calendar)
        let back = try JSONDecoder().decode(EggDiary.self, from: JSONEncoder().encode(diary))
        #expect(back == diary)
    }
}
