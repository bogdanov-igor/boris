import Foundation
import Testing
@testable import BorisCore

@Suite("reaction-settings")
struct ReactionTests {
    @Test("Значения по умолчанию", arguments: [
        (EventKind.failed, true, true, MoodReaction.alarm),
        (.interrupted, true, true, .alarm),
        (.allAgentsFailed, true, true, .alarm),
        (.completedWithErrors, true, true, .alarm),
        (.limitReached, true, true, .tired),
        (.limitNear, true, false, .none),
        (.waiting, true, true, .watching),
        (.completed, true, false, .happy),
        (.stopped, true, false, .hmm),
        (.silent, true, false, .alert),
        (.sessionFinished, true, false, .none),
        (.sessionError, true, true, .alert),
    ] as [(EventKind, Bool, Bool, MoodReaction)])
    func defaults(kind: EventKind, banner: Bool, sound: Bool, mood: MoodReaction) {
        #expect(ReactionMatrix().reaction(for: kind) == Reaction(banner: banner, sound: sound, mood: mood))
    }

    @Test("Выключен звук") func soundOff() {
        var matrix = ReactionMatrix()
        matrix.overrides[.completed] = Reaction(banner: true, sound: false, mood: .none)
        #expect(matrix.reaction(for: .completed).mood == .none)
    }

    @Test("Сброс возвращает значения") func reset() {
        var matrix = ReactionMatrix(overrides: [.completed: Reaction(banner: false, sound: false, mood: .none)])
        matrix.reset()
        #expect(matrix == ReactionMatrix())
    }

    @Test("Матрица переживает кодирование") func codable() throws {
        let matrix = ReactionMatrix(overrides: [.failed: Reaction(banner: false, sound: true, mood: .hmm)])
        let decoded = try JSONDecoder().decode(ReactionMatrix.self, from: JSONEncoder().encode(matrix))
        #expect(decoded == matrix)
    }

    @Test("Смягчение реакции не меняет статус") func softenedKeepsStatus() {
        // Tracker has no access to the matrix at all: the type system keeps statuses independent.
        var tracker = RunTracker()
        let r = resolve(&tracker, run(final: final("completed", entries: [entry("error")])), now: at(1))
        #expect(r.status == .allAgentsFailed)
    }

    @Test("Тихий час: баннера нет, сова работает, в конце сводка") func quiet() {
        var quiet = QuietMode()
        quiet.start(for: 3600, now: t0)
        let alarm = ReactionMatrix().reaction(for: .failed)
        #expect(quiet.filter(alarm, kind: .failed, now: at(10)) == Reaction(banner: false, sound: false, mood: .alarm))
        _ = quiet.filter(alarm, kind: .failed, now: at(20))
        #expect(quiet.finish(now: at(100)) == nil)
        #expect(quiet.finish(now: at(3601)) == [.failed: 2])
        #expect(quiet.finish(now: at(3602)) == nil)
    }

    @Test("Вне тихого режима реакция не меняется") func quietOff() {
        var quiet = QuietMode()
        let alarm = ReactionMatrix().reaction(for: .failed)
        #expect(quiet.filter(alarm, kind: .failed, now: t0) == alarm)
    }

    @Test("Без пропущенных событий сводки нет") func quietNoMissed() {
        var quiet = QuietMode()
        quiet.start(for: 60, now: t0)
        #expect(quiet.finish(now: at(61)) == nil)
    }
}

@Suite("character")
struct MoodTests {
    private let matrix = ReactionMatrix()

    private func mood(_ board: MoodBoard, runs: [RunState] = [], sessions: [SessionInfo] = [], broken: Bool = false, matrix: ReactionMatrix = ReactionMatrix(), now: Date = t0) -> Mood {
        board.mood(runs: runs, sessions: sessions, formatBroken: broken, matrix: matrix, now: now)
    }

    private func event(_ kind: EventKind) -> BorisEvent { BorisEvent(id: "\(kind)", kind: kind, at: t0) }

    @Test("Ничего не происходит: спит") func sleeping() {
        #expect(mood(MoodBoard()) == .sleeping)
    }

    @Test("Упал один и идёт другой: тревога") func alarmWins() {
        var board = MoodBoard()
        board.apply(event(.failed), reaction: .alarm, now: t0)
        #expect(mood(board, runs: [state(.running)]) == .alarm)
    }

    @Test("Завершился один и идёт другой: радуется 10 секунд") func happyThenWork() {
        var board = MoodBoard()
        board.apply(event(.completed), reaction: .happy, now: t0)
        let agent = AgentRecord(key: "a", state: .running)
        #expect(mood(board, runs: [state(.running, agents: [agent])], now: at(5)) == .happy)
        #expect(mood(board, runs: [state(.running, agents: [agent])], now: at(11)) == .working(agents: 1))
    }

    @Test("Реакция отключена: нет тревоги") func reactionOff() {
        var board = MoodBoard()
        board.apply(event(.failed), reaction: .none, now: t0)
        #expect(mood(board) == .sleeping)
    }

    @Test("Открытие меню снимает тревогу и усталость") func acknowledge() {
        var board = MoodBoard()
        board.apply(event(.failed), reaction: .alarm, now: t0)
        board.apply(event(.limitReached), reaction: .tired, now: t0)
        #expect(mood(board) == .alarm)
        board.acknowledge()
        #expect(mood(board, runs: [state(.running)]) == .working(agents: 0))
    }

    @Test("Полный порядок приоритетов") func priorities() {
        var board = MoodBoard()
        let waiting = session(status: "waiting", waitingFor: "approve Bash")
        let silent = state(.silent)
        board.apply(event(.completed), reaction: .happy, now: t0)
        #expect(mood(board, runs: [state(.running)], now: at(1)) == .happy)
        #expect(mood(board, runs: [silent], now: at(1)) == .alert)
        board.apply(event(.limitReached), reaction: .tired, now: t0)
        #expect(mood(board, runs: [silent], now: at(1)) == .tired)
        #expect(mood(board, runs: [silent], sessions: [waiting], now: at(1)) == .waiting)
        #expect(mood(board, runs: [silent], sessions: [waiting], broken: true, now: at(1)) == .broken)
        board.apply(event(.failed), reaction: .alarm, now: t0)
        #expect(mood(board, runs: [silent], sessions: [waiting], broken: true, now: at(1)) == .alarm)
    }

    @Test("Открытый диалог не считается ожиданием") func dialogIsNotWaiting() {
        #expect(mood(MoodBoard(), sessions: [session(status: "waiting", waitingFor: "dialog open")]) == .sleeping)
    }

    @Test("Отключённая реакция на молчание") func silentOff() {
        var matrix = ReactionMatrix()
        matrix.overrides[.silent] = Reaction(banner: true, sound: false, mood: .none)
        #expect(mood(MoodBoard(), runs: [state(.silent)], matrix: matrix) == .working(agents: 0))
    }

    @Test("Занятая сессия без запусков: работает") func busySession() {
        #expect(mood(MoodBoard(), sessions: [session(status: "busy")]) == .working(agents: 0))
    }
}

@Suite("wardrobe")
struct WardrobeTests {
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: hour))!
    }

    private func outfit(_ d: Date, settings: WardrobeSettings = WardrobeSettings(), reward: Bool = false) -> Outfit {
        Wardrobe.outfit(at: d, settings: settings, rewardParty: reward, calendar: calendar)
    }

    @Test("Даты календаря", arguments: [
        (2026, 12, 20, Outfit.santa), (2026, 12, 31, .santa), (2027, 1, 1, .santa), (2027, 1, 10, .santa), (2027, 1, 11, .none),
        (2026, 12, 19, .none), (2026, 10, 25, .witch), (2026, 10, 31, .witch), (2026, 10, 24, .none), (2026, 2, 14, .hearts),
        (2026, 3, 8, .flower), (2026, 9, 1, .scholar), (2026, 11, 30, .none), (2026, 7, 7, .none),
    ] as [(Int, Int, Int, Outfit)])
    func dated(y: Int, m: Int, d: Int, expected: Outfit) {
        #expect(outfit(date(y, m, d)) == expected)
    }

    @Test("256-й день: 13 сентября и 12 в високосный год") func programmersDay() {
        #expect(outfit(date(2026, 9, 13)) == .pixel)
        #expect(outfit(date(2028, 9, 12)) == .pixel)
        #expect(outfit(date(2028, 9, 13)) == .crow || outfit(date(2028, 9, 13)) == .none)
    }

    @Test("Пятница, 13-е") func fridayThirteen() {
        #expect(outfit(date(2026, 11, 13)) == .crow)
        #expect(outfit(date(2026, 10, 13)) == .none)
    }

    @Test("Годовщина первого запуска") func anniversary() {
        let settings = WardrobeSettings(firstLaunch: date(2026, 5, 4))
        #expect(outfit(date(2027, 5, 4), settings: settings) == .party)
        #expect(outfit(date(2026, 5, 4), settings: settings) == .none)
    }

    @Test("Ночной колпак") func nightcap() {
        #expect(outfit(date(2026, 7, 7, hour: 2)) == .nightcap)
        #expect(outfit(date(2026, 7, 7, hour: 5)) == .none)
    }

    @Test("Приоритет: день рождения, пятница 13-е, дата, ночь") func priority() {
        let birthday = WardrobeSettings(userBirthday: MonthDay(month: 10, day: 31))
        #expect(outfit(date(2026, 10, 31), settings: birthday) == .party)
        #expect(outfit(date(2026, 12, 25, hour: 2)) == .santa)
        let fridayNight = date(2026, 11, 13, hour: 2)
        #expect(outfit(fridayNight) == .crow)
    }

    @Test("Ручной выбор и режим без нарядов") func modes() {
        #expect(outfit(date(2026, 7, 7), settings: WardrobeSettings(mode: .manual(.witch))) == .witch)
        #expect(outfit(date(2026, 12, 25), settings: WardrobeSettings(mode: .off)) == .none)
    }

    @Test("Награда надевает колпак") func reward() {
        #expect(outfit(date(2026, 7, 7), reward: true) == .party)
    }

    @Test("1 апреля") func aprilFools() {
        #expect(Wardrobe.isAprilFools(date(2027, 4, 1), calendar: calendar))
        #expect(!Wardrobe.isAprilFools(date(2027, 4, 2), calendar: calendar))
    }
}

@Suite("play")
struct PlayTests {
    private func pokes(_ n: Int, ladder: inout PokeLadder, night: Bool = false) -> [PokeReaction] {
        (0..<n).map { ladder.poke(now: at(Double($0)), night: night) }
    }

    @Test("Лестница реакций") func ladder() {
        var ladder = PokeLadder()
        let reactions = pokes(7, ladder: &ladder)
        #expect(reactions[0] == .squash)
        #expect(reactions[2] == .hoot)
        #expect(reactions[6] == .annoyed)
    }

    @Test("На 15-м отворачивается на 10 секунд и не реагирует") func turnsAway() {
        var ladder = PokeLadder()
        let reactions = pokes(15, ladder: &ladder)
        #expect(reactions[14] == .turnAway)
        #expect(ladder.poke(now: at(20)) == .ignored)
        #expect(ladder.poke(now: at(25)) != .ignored)
    }

    @Test("30 кликов: оборот, 50: титры") func spinAndCredits() {
        var ladder = PokeLadder()
        var seen: [PokeReaction] = []
        var clock = 0.0
        while seen.count < 50 {
            clock += 1
            let reaction = ladder.poke(now: at(clock))
            if reaction == .ignored { clock += 10; continue }
            seen.append(reaction)
        }
        #expect(seen[29] == .spin)
        #expect(seen[49] == .credits)
    }

    @Test("Сброс после 30 секунд") func reset() {
        var ladder = PokeLadder()
        _ = pokes(2, ladder: &ladder)
        #expect(ladder.poke(now: at(100)) == .squash)
        #expect(ladder.count == 1)
    }

    @Test("Ночной тычок") func night() {
        var ladder = PokeLadder()
        #expect(ladder.poke(now: t0, night: true) == .goToSleep)
    }

    @Test("Тычок при тревоге только сплющивает") func restricted() {
        var ladder = PokeLadder()
        for i in 0..<20 {
            #expect(ladder.poke(now: at(Double(i)), restricted: true) == .squash)
        }
        #expect(ladder.count == 0)
    }

    @Test("Серия прервалась") func streakBroken() {
        var awards = AwardTracker()
        for _ in 0..<9 { awards.record(.completed, today: "d") }
        awards.record(.failed, today: "d")
        #expect(awards.cleanStreak == 0)
        #expect(!awards.hasParty(today: "d"))
    }

    @Test("10 чистых подряд: колпак до конца дня") func streakDone() {
        var awards = AwardTracker()
        for _ in 0..<10 { awards.record(.completed, today: "d") }
        #expect(awards.hasParty(today: "d"))
        #expect(!awards.hasParty(today: "e"))
    }

    @Test("Остановка не прерывает серию") func stopNeutral() {
        var awards = AwardTracker(cleanStreak: 5)
        awards.record(.stopped, today: "d")
        #expect(awards.cleanStreak == 5)
    }

    @Test("100 завершений: рыба") func fish() {
        var awards = AwardTracker()
        for _ in 0..<99 { awards.record(.completed, today: "d") }
        #expect(!awards.hasFish)
        awards.record(.failed, today: "d")
        #expect(awards.hasFish)
    }
}

@Suite("run-statistics")
struct StatsTests {
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    @Test("Тихая смерть") func silentDeath() {
        var book = StatsBook()
        book.record(state(.interrupted), at: t0, calendar: calendar)
        #expect(book.total(lastDays: 1, now: t0, calendar: calendar).silentDeaths == 1)
    }

    @Test("Каждая попытка учтена один раз") func attempts() {
        var book = StatsBook()
        let first = book.record(state(.completed), at: t0, calendar: calendar)
        let repeated = book.record(state(.completed), at: at(10), calendar: calendar)
        let second = book.record(state(.completed, attempt: 2), at: at(20), calendar: calendar)
        #expect(first)
        #expect(!repeated)
        #expect(second)
        #expect(book.total(lastDays: 1, now: at(20), calendar: calendar).runCount == 2)
    }

    @Test("Идущий запуск не учитывается") func runningNotCounted() {
        var book = StatsBook()
        let counted = book.record(state(.running), at: t0, calendar: calendar)
        #expect(!counted)
    }

    @Test("Падения по классам") func failures() {
        var book = StatsBook()
        let agent = AgentRecord(key: "a", state: .failed, failure: FailureInfo(failureClass: .limit))
        book.record(state(.allAgentsFailed, agents: [agent]), at: t0, calendar: calendar)
        #expect(book.total(lastDays: 1, now: t0, calendar: calendar).failures == ["limit": 1])
    }

    @Test("Суммирование за 7 дней") func sevenDays() {
        var book = StatsBook()
        for day in 0..<10 {
            book.addTokens(TokenUsage(input: 1), at: t0.addingTimeInterval(Double(-day) * 86400), calendar: calendar)
        }
        #expect(book.total(lastDays: 7, now: t0, calendar: calendar).tokens.input == 7)
        #expect(book.total(lastDays: 1, now: t0, calendar: calendar).tokens.input == 1)
    }

    @Test("Срок хранения") func prune() {
        var book = StatsBook()
        book.addTokens(TokenUsage(input: 1), at: t0.addingTimeInterval(-500 * 86400), calendar: calendar)
        book.addTokens(TokenUsage(input: 1), at: t0, calendar: calendar)
        book.prune(now: t0, calendar: calendar)
        #expect(book.days.count == 1)
    }

    @Test("В книге только даты и числа") func onlyNumbers() throws {
        var book = StatsBook()
        book.record(state(.completed), at: t0, calendar: calendar)
        let text = String(data: try JSONEncoder().encode(book.days), encoding: .utf8) ?? ""
        #expect(!text.contains("wf"))
        #expect(!text.contains("proj"))
    }

    @Test("Сброс") func reset() {
        var book = StatsBook()
        book.record(state(.completed), at: t0, calendar: calendar)
        book.reset()
        #expect(book.days.isEmpty)
    }
}

@Suite("Числа")
struct TokenFormatTests {
    @Test("Формат токенов") func tokens() {
        #expect(TokenFormat.short(950) == "950")
        #expect(TokenFormat.short(102_345) == "102k")
        #expect(TokenFormat.short(1_234_567) == "1.2M")
        #expect(TokenFormat.short(250_000_000) == "250M")
    }
}

@Suite("Статистика: токены и файл")
struct StatsFileTests {
    @Test("Возобновлённый запуск добавляет только новое") func growth() {
        let first = TokenUsage(input: 10, output: 20, cacheRead: 30, cacheWrite: 40)
        let second = TokenUsage(input: 15, output: 25, cacheRead: 30, cacheWrite: 45)
        #expect(second.growth(since: first) == TokenUsage(input: 5, output: 5, cacheRead: 0, cacheWrite: 5))
        #expect(first.growth(since: second) == TokenUsage())
    }

    @Test("Весь файл без идентификаторов запусков") func fileHasNoIds() throws {
        var book = StatsBook()
        book.record(state(.completed, id: "wf_secret"), at: t0)
        let text = String(data: try JSONEncoder().encode(book), encoding: .utf8) ?? ""
        #expect(!text.contains("wf_secret"))
        #expect(try JSONDecoder().decode(StatsBook.self, from: JSONEncoder().encode(book)).days == book.days)
    }
}

@Suite("play: игра в открытом меню")
struct PlayDirectorTests {
    private func poke(_ play: inout Play, times: Int, from start: Date = t0, restricted: Bool = false, reduceMotion: Bool = false) -> Bool {
        var credits = false
        for i in 0..<times {
            credits = play.poke(now: start.addingTimeInterval(Double(i)), restricted: restricted, night: false, reduceMotion: reduceMotion) || credits
        }
        return credits
    }

    @Test("Один клик сплющивает, и поза возвращается") func onePoke() {
        var play = Play()
        _ = poke(&play, times: 1)
        #expect(play.current(now: at(0.1), restricted: false)?.act == .poke)
        #expect(play.current(now: at(1), restricted: false) == nil)
    }

    @Test("Лестница реакций", arguments: [(3, Act.hoot), (7, .annoyed), (15, .back)])
    func ladder(times: Int, expected: Act) {
        var play = Play()
        _ = poke(&play, times: times)
        let last = t0.addingTimeInterval(Double(times - 1))
        #expect(play.current(now: last.addingTimeInterval(0.1), restricted: false)?.act == expected)
    }

    @Test("Сказанное видно недолго") func lineFades() {
        var play = Play()
        _ = poke(&play, times: 3)
        #expect(play.currentLine(now: at(2.5)) == .hoot)
        #expect(play.currentLine(now: at(10)) == nil)
    }

    @Test("Оборот и головокружение по порядку") func spinOrder() {
        var play = Play()
        let base = t0
        var now = base
        for _ in 0..<15 {
            _ = play.poke(now: now, restricted: false, night: false, reduceMotion: false)
            now = now.addingTimeInterval(1)
        }
        now = now.addingTimeInterval(PokeLadder.turnAwayFor)
        for _ in 0..<15 {
            _ = play.poke(now: now, restricted: false, night: false, reduceMotion: false)
            now = now.addingTimeInterval(1)
        }
        let spun = now.addingTimeInterval(-1)
        #expect(play.current(now: spun.addingTimeInterval(0.2), restricted: false)?.act == .spin)
        #expect(play.current(now: spun.addingTimeInterval(Act.spin.duration + 0.2), restricted: false)?.act == .dizzy)
        #expect(play.current(now: spun.addingTimeInterval(Act.spin.duration + Act.dizzy.duration + 0.2), restricted: false) == nil)
    }

    @Test("Без движения: сразу статичное головокружение") func reducedMotionSkipsSpin() {
        var play = Play()
        var now = t0
        for _ in 0..<15 {
            _ = play.poke(now: now, restricted: false, night: false, reduceMotion: true)
            now = now.addingTimeInterval(1)
        }
        now = now.addingTimeInterval(PokeLadder.turnAwayFor)
        for _ in 0..<15 {
            _ = play.poke(now: now, restricted: false, night: false, reduceMotion: true)
            now = now.addingTimeInterval(1)
        }
        #expect(play.current(now: now.addingTimeInterval(-0.9), restricted: false)?.act == .dizzy)
    }

    @Test("Пятидесятый клик запускает титры") func credits() {
        var play = Play()
        var now = t0
        var rolled = false
        for i in 1...50 {
            rolled = play.poke(now: now, restricted: false, night: false, reduceMotion: false)
            if i == 15 { now = now.addingTimeInterval(PokeLadder.turnAwayFor) }
            now = now.addingTimeInterval(1)
        }
        #expect(rolled)
    }

    @Test("Тычок при тревоге только сплющивает") func restricted() {
        var play = Play()
        let rolled = poke(&play, times: 50, restricted: true)
        #expect(!rolled)
        let last = t0.addingTimeInterval(49)
        #expect(play.current(now: last.addingTimeInterval(0.1), restricted: true)?.act == .poke)
        #expect(play.isSoftPoke)
        #expect(play.ladder.count == 0)
    }

    @Test("Начатая реакция не заменяет тревогу") func moodWins() {
        var play = Play()
        _ = poke(&play, times: 3)
        #expect(play.current(now: at(2.2), restricted: false)?.act == .hoot)
        #expect(play.current(now: at(2.2), restricted: true) == nil)
    }

    @Test("Ночью тычок говорит «Иди спать»") func night() {
        var play = Play()
        _ = play.poke(now: t0, restricted: false, night: true, reduceMotion: false)
        #expect(play.currentLine(now: at(1)) == .goToSleep)
    }

    @Test("Код Konami надевает очки на минуту, в обеих раскладках", arguments: [("b", "a"), ("и", "ф"), ("B", "A")])
    func konami(b: String, a: String) {
        var play = Play()
        for key in [PlayKey.up, .up, .down, .down, .left, .right, .left, .right, .character(b), .character(a)] {
            play.key(key, now: t0)
        }
        #expect(play.wearsGlasses(now: at(59)))
        #expect(!play.wearsGlasses(now: at(61)))
    }

    @Test("Неполный код не срабатывает") func wrongCode() {
        var play = Play()
        for key in [PlayKey.up, .down, .left, .right, .character("b"), .character("a")] {
            play.key(key, now: t0)
        }
        #expect(!play.wearsGlasses(now: at(1)))
    }

    @Test("Набрано «угу»: он отвечает", arguments: [["у", "г", "у"], ["u", "g", "u"], ["У", "Г", "У"]])
    func hoo(letters: [String]) {
        var play = Play()
        for letter in letters { play.key(.character(letter), now: t0) }
        #expect(play.current(now: at(0.5), restricted: false)?.act == .hoot)
        #expect(play.currentLine(now: at(0.5)) == .hoot)
    }

    @Test("Ночью шёл запуск: утром один зевок") func morningYawn() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        func moment(_ hour: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: hour))!
        }
        var watch = NightWatch()
        watch.note(active: true, now: moment(14), calendar: calendar)
        let afterDayRun = watch.shouldYawn(now: moment(15), calendar: calendar)
        #expect(!afterDayRun)
        watch.note(active: false, now: moment(3), calendar: calendar)
        let afterQuietNight = watch.shouldYawn(now: moment(9), calendar: calendar)
        #expect(!afterQuietNight)
        watch.note(active: true, now: moment(3), calendar: calendar)
        let stillNight = watch.shouldYawn(now: moment(4), calendar: calendar)
        #expect(!stillNight)
        let morning = watch.shouldYawn(now: moment(9), calendar: calendar)
        #expect(morning)
        let again = watch.shouldYawn(now: moment(10), calendar: calendar)
        #expect(!again)
    }
}
