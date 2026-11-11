import BorisCore
import Foundation
import Testing

/// The tests have no translation table, so the English source is what they see.
@Suite("Сводка потерь")
struct LossBookTests {
    private let utc = TimeZone(identifier: "UTC") ?? .current
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar
    }
    private let now = Date(timeIntervalSince1970: 1_793_900_000)

    private func entry(_ id: String = UUID().uuidString, ago days: Double = 0, kind: LossKind = .crash, count: Int = 1, reason: LossReason? = .limit, agents: [String] = [], cwd: String? = "/x/shop-api", entrypoint: String? = "cli") -> LossEntry {
        LossEntry(id: id, at: now.addingTimeInterval(-days * 86400), kind: kind, count: count, sessionId: "s", cwd: cwd, entrypoint: entrypoint, agents: agents, reason: reason)
    }

    private func book(_ entries: [LossEntry], calls: [LossCalls] = [], period: LossPeriod = .all, tokens: [String: Int] = [:]) -> LossBook {
        LossBook(history: LossHistory(entries: entries, calls: calls), period: period, agentTokens: tokens, now: now, calendar: calendar)
    }

    @Test("Массовое падение: сразу видно главную причину и сколько по каждой")
    func massCrash() {
        let result = book([entry(count: 606, reason: .limit), entry(count: 16, reason: .network), entry(reason: .unknown), entry(count: 3, reason: .network), entry(kind: .toolError, reason: nil)])
        #expect(result.reasons.map(\.reason) == [.limit, .network, .unknown])
        #expect(result.reasons.map(\.count) == [606, 19, 1])
        #expect(result.crashed == 626)
        #expect(result.kinds[.toolError] == 1)
    }

    @Test("Только падения попадают в сводку по причинам")
    func reasonsAreCrashes() {
        let result = book([entry(kind: .apiError, reason: .limit), entry(kind: .retry, reason: .network), entry(kind: .cut, reason: .sleep)])
        #expect(result.reasons.isEmpty)
        #expect(result.crashed == 0)
    }

    @Test("Период: целые дни, сегодняшний тоже считается")
    func periods() {
        let entries = [entry("today"), entry("six", ago: 6), entry("eight", ago: 8), entry("thirty", ago: 29), entry("forty", ago: 40)]
        #expect(book(entries, period: .week).entries.map(\.id) == ["today", "six"])
        #expect(book(entries, period: .month).entries.map(\.id) == ["today", "six", "eight", "thirty"])
        #expect(book(entries, period: .all).entries.count == 5)
    }

    @Test("Период относится и к вызовам, и к потерянным токенам")
    func periodCoversCalls() {
        let calls = [
            LossCalls(day: "2026-11-05", kind: .fetch, calls: 3, estimatedTokens: 300),
            LossCalls(day: "2026-09-01", kind: .fetch, calls: 7, estimatedTokens: 700),
            LossCalls(day: "2026-11-05", kind: .search, calls: 2, estimatedTokens: 20),
            LossCalls(day: "2026-09-01", kind: .skill, name: "pdf", calls: 4, estimatedTokens: 40),
        ]
        let entries = [entry(agents: ["fresh"]), entry(ago: 40, agents: ["old"])]
        let week = book(entries, calls: calls, period: .week, tokens: ["fresh": 10, "old": 1000])
        #expect(week.fetches == 3)
        #expect(week.searches == 2)
        #expect(week.webTokens == 320)
        #expect(week.skills.isEmpty)
        #expect(week.skillTokens == 0)
        #expect(week.lostTokens == 10)
        let all = book(entries, calls: calls, tokens: ["fresh": 10, "old": 1000])
        #expect(all.fetches == 10)
        #expect(all.skills.map(\.calls) == [4])
        #expect(all.skillCalls == 4)
        #expect(all.lostTokens == 1010)
    }

    @Test("Нет данных о токенах это не ноль, а без падений терять нечего")
    func lostTokensUnknown() {
        #expect(book([entry(agents: ["a"])]).lostTokens == nil)
        #expect(book([entry(reason: nil, agents: [])]).lostTokens == 0)
        #expect(book([]).lostTokens == 0)
        #expect(book([entry(agents: ["a"])], tokens: ["b": 5]).lostTokens == 0)
    }

    @Test("Списки для фильтров собраны из записей периода")
    func filters() {
        let entries = [entry(cwd: "/x/shop-api", entrypoint: "cli"), entry(cwd: "/y/boris", entrypoint: "claude-vscode"), entry(cwd: "/z/shop-api", entrypoint: "cli"), entry(cwd: nil, entrypoint: nil), entry(ago: 40, cwd: "/x/old")]
        let result = book(entries, period: .week)
        // A project is its folder, as on the Projects page: two folders of one name are two projects.
        #expect(result.projects == ["/x/shop-api", "/y/boris", "/z/shop-api"])
        #expect(result.environments.contains(.terminal))
        #expect(result.environments.contains(.vsCode))
        #expect(result.environments.count == 2)
    }

    @Test("Фильтры сужают список, но не сводку")
    func filtering() {
        let entries = [
            entry("a", kind: .crash, cwd: "/x/shop-api", entrypoint: "cli"),
            entry("b", ago: 1, kind: .toolError, reason: nil, cwd: "/x/shop-api", entrypoint: "claude-vscode"),
            entry("c", ago: 2, kind: .toolError, reason: nil, cwd: "/y/boris", entrypoint: "cli"),
            entry("d", ago: 3, kind: .denied, reason: nil, cwd: nil, entrypoint: nil),
        ]
        let result = book(entries)
        #expect(result.entries(kind: nil, project: nil, environment: nil).map(\.id) == ["a", "b", "c", "d"])
        #expect(result.entries(kind: .toolError, project: nil, environment: nil).map(\.id) == ["b", "c"])
        #expect(result.entries(kind: nil, project: "/x/shop-api", environment: nil).map(\.id) == ["a", "b"])
        #expect(result.entries(kind: nil, project: nil, environment: .vsCode).map(\.id) == ["b"])
        #expect(result.entries(kind: .toolError, project: "/y/boris", environment: .terminal).map(\.id) == ["c"])
        #expect(result.entries(kind: .denied, project: "/y/boris", environment: nil).isEmpty)
        #expect(result.kinds[.toolError] == 2)
        #expect(result.crashed == 1)
    }

    @Test("Проект или среда, которых нет в этом периоде, ничего не прячут: меню в это время говорит «все»")
    func filterGoneFromThePeriod() {
        let entries = [entry("fresh", cwd: "/x/shop-api", entrypoint: "cli"), entry("old", ago: 40, cwd: "/y/boris", entrypoint: "claude-vscode")]
        let week = book(entries, period: .week)
        #expect(week.entries(kind: nil, project: "/y/boris", environment: nil).map(\.id) == ["fresh"])
        #expect(week.entries(kind: nil, project: nil, environment: .vsCode).map(\.id) == ["fresh"])
        // In a period that has it, the same choice works again.
        #expect(book(entries).entries(kind: nil, project: "/y/boris", environment: nil).map(\.id) == ["old"])
    }

    @Test("Новые записи идут первыми")
    func order() {
        #expect(book([entry("old", ago: 3), entry("new"), entry("mid", ago: 1)]).entries.map(\.id) == ["new", "mid", "old"])
    }

    // MARK: Words

    @Test("Оценка всегда говорит о себе, что она оценка")
    func estimates() {
        #expect(LossPhrases.estimate(3_900_000) == "≈ 3.9M")
        #expect(LossPhrases.estimate(0) == "≈ 0")
    }

    @Test("Страница «Потери» называет все виды сбоев и все причины")
    func names() {
        #expect(LossKind.allCases.count == 6)
        #expect(Set(LossKind.allCases.map(LossPhrases.kind)).count == 6)
        #expect(Set(LossReason.allCases.map { LossPhrases.reason($0, mode: .technical) }).count == LossReason.allCases.count)
        #expect(Set(LossReason.allCases.map { LossPhrases.reason($0, mode: .simple) }).count == LossReason.allCases.count)
    }

    @Test("Причины простыми словами, как в требованиях")
    func simpleReasons() {
        #expect(LossPhrases.reason(.limit, mode: .simple) == "Out of limit")
        #expect(LossPhrases.reason(.closed, mode: .simple) == "Claude Code closed")
        #expect(LossPhrases.reason(.unknown, mode: .simple) == "Reason unknown")
        #expect(LossPhrases.reason(.limit, mode: .technical) == "Limit")
        #expect(LossPhrases.reason(.script, mode: .technical) == "Script error")
    }

    @Test("Подсказки в простом режиме: что случилось и что делать, без названий инструментов и кодов")
    func advice() {
        var overloaded = entry(kind: .crash, reason: .api)
        overloaded.problem = .overloaded
        overloaded.code = "server_error"
        #expect(LossPhrases.advice(overloaded) == "Claude is overloaded right now, try again later")
        #expect(LossPhrases.advice(entry(reason: .unknown)) == "Something went wrong")
        #expect(LossPhrases.advice(entry(reason: nil)) == "Something went wrong")

        var limit = entry(reason: .limit)
        limit.resetsAt = now.addingTimeInterval(600)
        #expect(LossPhrases.advice(limit).hasPrefix("Out of limit, resets"))

        var tool = entry(kind: .toolError, reason: nil)
        tool.tool = "Bash"
        tool.toolFailure = .exitCode
        tool.toolCode = 3
        #expect(!LossPhrases.advice(tool).contains("Bash"))
        #expect(!LossPhrases.advice(tool).contains("3"))
    }

    @Test("Строка списка в техническом режиме")
    func details() {
        var crash = entry(count: 12, reason: .limit)
        crash.total = 12
        crash.limit = .session
        crash.resets = "2pm"
        #expect(LossPhrases.detail(crash) == "all 12 failed · session limit, resets 2pm")
        crash.count = 3
        #expect(LossPhrases.detail(crash) == "3 of 12 agents failed · session limit, resets 2pm")
        crash.total = 1
        crash.count = 1
        #expect(LossPhrases.detail(crash) == "session limit, resets 2pm")

        var tool = entry(kind: .toolError, reason: nil)
        tool.tool = "Read"
        tool.toolFailure = .noFile
        #expect(LossPhrases.detail(tool) == "Read: file not found")
        tool.tool = "Bash"
        tool.toolFailure = .exitCode
        tool.toolCode = 1
        #expect(LossPhrases.detail(tool) == "Bash: exit code 1")

        var retry = entry(kind: .retry, reason: .api)
        retry.problem = .overloaded
        retry.recovered = true
        #expect(LossPhrases.detail(retry) == "retry after an overload, it worked")
        retry.recovered = false
        #expect(LossPhrases.detail(retry) == "retry after an overload, it did not help")

        var denied = entry(kind: .denied, reason: nil)
        denied.tool = "Bash"
        denied.denial = .person
        #expect(LossPhrases.detail(denied) == "you declined the command")
        denied.denial = .rule
        #expect(LossPhrases.detail(denied) == "Bash: forbidden by a rule")
    }

    @Test("Скилл, не вошедший в короткий список, всё равно назван со своим точным числом вызовов")
    func skillsLeftOut() {
        let calls = [
            LossCalls(day: "2026-11-05", kind: .skill, name: "pdf", calls: 9),
            LossCalls(day: "2026-11-05", kind: .skill, name: "xlsx", calls: 3),
            LossCalls(day: "2026-11-05", kind: .skill, calls: 2),
        ]
        #expect(LossPhrases.skillCounts(book([], calls: calls).skills.dropFirst()) == "xlsx 3\nUnnamed skill 2")
    }

    @Test("Неизвестная причина показывает исходный текст в техническом режиме и ничего лишнего в простом")
    func unknownText() {
        var unknown = entry(reason: .unknown)
        unknown.rawText = "Cannot create agent worktree"
        #expect(LossPhrases.detail(unknown) == "unknown: Cannot create agent worktree")
        #expect(!LossPhrases.advice(unknown).contains("worktree"))
    }

    @Test("Дата строки: сегодня только время, раньше ещё и день")
    func dates() {
        #expect(LossPhrases.when(now, now: now, timeZone: utc).count == 5)
        #expect(LossPhrases.when(now.addingTimeInterval(-3 * 86400), now: now, timeZone: utc).count > 5)
    }

    @Test("Причины падения определяются как в первой версии, с добавлением перегрузки")
    func classifier() {
        func reason(_ text: String, code: String? = nil, isApi: Bool = false) -> FailureClass {
            FailureClassifier.classify(LastRecord(isApiError: isApi, errorCode: code, text: text)).failureClass
        }
        #expect(reason("You've hit your monthly spend limit · raise it", code: "rate_limit") == .limit)
        #expect(reason("API Error: Connection lost while your computer was asleep", code: "server_error") == .sleep)
        #expect(reason("API Error: Your computer went to sleep mid-response.", code: "server_error") == .sleep)
        #expect(reason("API Error: Can't reach the API server", code: "server_error") == .network)
        #expect(reason("API Error: No response from API", code: "server_error") == .network)
        #expect(reason("stalled — no progress for 600000ms") == .stall)
        #expect(reason("API Error: 529 Overloaded", code: "server_error") == .api)
        #expect(reason("Failed to authenticate. API Error: 403") == .api)
        #expect(reason("Cannot create agent worktree") == .unknown)
    }

    @Test("Время сброса берётся без советов, которые идут после него")
    func resetsText() {
        let info = FailureClassifier.classify(LastRecord(isApiError: true, errorCode: "rate_limit", text: "You've hit your session limit · resets 2pm (Asia/Example) · upgrade at example"))
        #expect(info.resets == "2pm (Asia/Example)")
        #expect(info.limitKind == .session)
    }
}
