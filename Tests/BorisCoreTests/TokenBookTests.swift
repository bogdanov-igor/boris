import BorisCore
import Foundation
import Testing

@Suite("Цены и оценка")
struct PriceTests {
    @Test("Известные модели и их написания в логах", arguments: [
        ("claude-opus-5-5", 4.0),
        ("claude-opus-4-5-20251101", 5.0),
        ("us.anthropic.claude-sonnet-4-5-20250929-v1:0", 3.0),
        ("anthropic.claude-opus-5-5", 4.0),
        ("claude-sonnet-5-5[1m]", 2.0),
        ("claude-opus-4-20250514", 15.0),
        ("claude-3-5-haiku-20241022", 0.8),
        ("claude-haiku-4-5@20251001", 1.0),
    ])
    func known(model: String, input: Double) {
        #expect(PriceTable.price(for: model)?.input == input)
    }

    @Test("Незнакомая модель не получает цену", arguments: ["some-gateway-model", "claude-next-9", "sonnet", "<synthetic>", ""])
    func unknown(model: String) {
        #expect(PriceTable.price(for: model) == nil)
    }

    @Test("Похожее имя не берёт чужую цену: Opus 4 и Opus 4.5 стоят по-разному")
    func notByPrefix() {
        #expect(PriceTable.price(for: "claude-opus-4")?.input == 15)
        #expect(PriceTable.price(for: "claude-opus-4-5")?.input == 5)
        #expect(PriceTable.price(for: "claude-sonnet-5")?.cacheRead == 0.2)
        #expect(PriceTable.price(for: "claude-sonnet-5-5")?.cacheRead == 0.1)
    }

    @Test("Стоимость считается по четырём видам токенов")
    func cost() throws {
        let price = try #require(PriceTable.price(for: "claude-opus-5-5"))
        let million = 1_000_000
        #expect(abs(price.cost(of: TokenUsage(input: million, output: million, cacheRead: million, cacheWrite: million)) - 29.2) < 0.000001)
        #expect(price.cost(of: TokenUsage()) == 0)
    }

    @Test("У таблицы есть дата, когда взяты цены")
    func takenOn() {
        #expect(PriceTable.takenOn.wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil)
    }

    @Test("Имя модели для людей", arguments: [
        ("claude-opus-5-5", "Opus 5.5"),
        ("claude-sonnet-4-5-20250929", "Sonnet 4.5"),
        ("claude-3-5-haiku-20241022", "Haiku 3.5"),
        ("claude-fable-5-1", "Fable 5.1"),
        ("claude-opus-4", "Opus 4"),
    ])
    func display(model: String, name: String) {
        #expect(ModelName.display(model) == name)
    }

    @Test("Незнакомое имя не превращается в выдуманное", arguments: ["gpt-thing", "claude-a-b", ""])
    func displayUnknown(model: String) {
        #expect(ModelName.display(model) == nil)
    }
}

@Suite("Книга токенов")
struct TokenBookTests {
    private let utc = TimeZone(identifier: "UTC") ?? .current
    /// 2026-11-05, noon by UTC.
    private let now = Date(timeIntervalSince1970: 1_793_880_000)

    private func usage(_ total: Int) -> TokenUsage {
        TokenUsage(input: total)
    }

    private func book(_ records: [TokenRecord]) -> TokenBook {
        TokenBook(records: records, now: now, timeZone: utc)
    }

    private func record(day: String, tokens: Int = 100, session: String = "s", agent: String? = nil, run: String? = nil, cwd: String? = "/x/a", entrypoint: String? = "cli", model: String? = "claude-opus-5-5") -> TokenRecord {
        TokenRecord(sessionId: session, agentId: agent, runId: run, cwd: cwd, entrypoint: entrypoint, day: day, model: model, usage: usage(tokens))
    }

    private var spread: [TokenRecord] {
        [
            record(day: "2026-11-05", tokens: 1, session: "a", cwd: "/x/a", entrypoint: "cli", model: "claude-opus-5-5"),
            record(day: "2026-11-05", tokens: 2, session: "b", agent: "b1", cwd: "/x/b", entrypoint: "claude-vscode", model: "claude-sonnet-5-5"),
            record(day: "2026-10-30", tokens: 4, session: "a", cwd: "/x/a", entrypoint: "cli", model: "claude-opus-5-5"),
            record(day: "2026-10-29", tokens: 8, session: "c", agent: "c1", run: "wf_1", cwd: nil, entrypoint: nil, model: "unknown"),
            record(day: "2026-10-07", tokens: 16, session: "d", cwd: "/x/b", entrypoint: "local-agent", model: nil),
            record(day: "2026-10-06", tokens: 32, session: "d", cwd: "/x/b", entrypoint: "local-agent", model: "claude-opus-5-5"),
        ]
    }

    @Test("Каждый период берёт ровно свои дни", arguments: [
        (UsagePeriod.today, 3),
        (.week, 7),
        (.month, 31),
        (.all, 63),
    ])
    func periods(period: UsagePeriod, total: Int) {
        #expect(book(spread).report(period).usage.total == total)
    }

    @Test("Сумма каждой разбивки равна итогу за период")
    func breakdownsAddUp() {
        let book = book(spread)
        for period in UsagePeriod.allCases {
            let report = book.report(period)
            for breakdown in TokenBreakdown.allCases {
                let lines = report.lines(breakdown)
                #expect(lines.reduce(0) { $0 + $1.usage.total } == report.usage.total, "\(period) \(breakdown)")
                #expect(abs(lines.reduce(0) { $0 + $1.estimate.dollars } - report.estimate.dollars) < 0.0001, "\(period) \(breakdown)")
                #expect(lines.reduce(0) { $0 + $1.estimate.unpricedTokens } == report.estimate.unpricedTokens, "\(period) \(breakdown)")
            }
        }
    }

    @Test("Дни идут от новых к старым, остальное от большего к меньшему")
    func order() {
        let report = book(spread).report(.all)
        #expect(report.lines(.days).first?.key == .day("2026-11-05"))
        #expect(report.lines(.days).last?.key == .day("2026-10-06"))
        let projects = report.lines(.projects).map(\.usage.total)
        #expect(projects == projects.sorted(by: >))
    }

    @Test("Запись агента без папки и среды получает их от своей сессии")
    func agentInherits() {
        let book = book([
            record(day: "2026-11-05", tokens: 10, session: "s", cwd: "/x/a", entrypoint: "claude-vscode"),
            record(day: "2026-11-05", tokens: 5, session: "s", agent: "a1", cwd: nil, entrypoint: nil),
        ])
        let report = book.report(.today)
        #expect(report.lines(.projects).map(\.key) == [.project("/x/a")])
        #expect(report.lines(.projects).first?.usage.total == 15)
        #expect(report.lines(.environments).map(\.key) == [.environment(.vsCode)])
    }

    @Test("Запись без модели и запись незнакомой модели цены не получают")
    func noModelNoPrice() {
        let report = book([
            record(day: "2026-11-05", tokens: 1_000_000, model: "claude-opus-5-5"),
            record(day: "2026-11-05", tokens: 16, model: nil),
            record(day: "2026-11-05", tokens: 8, model: "some-gateway-model"),
        ]).report(.today)
        #expect(report.estimate.unpricedTokens == 24)
        #expect(report.estimate.pricedTokens == 1_000_000)
        #expect(abs(report.estimate.dollars - 4) < 0.000001)
    }

    @Test("Разные написания одной модели это одна строка разбивки")
    func oneRowPerModel() {
        let report = book([
            record(day: "2026-11-05", tokens: 1, model: "claude-sonnet-4-5-20250929"),
            record(day: "2026-11-05", tokens: 2, model: "us.anthropic.claude-sonnet-4-5-20250929-v1:0"),
            record(day: "2026-11-05", tokens: 4, model: "claude-sonnet-4-5[1m]"),
            record(day: "2026-11-05", tokens: 8, model: "some-gateway-model"),
        ]).report(.today)
        let rows = report.lines(.models)
        #expect(rows.map(\.key) == [.model("some-gateway-model"), .model("claude-sonnet-4-5")])
        #expect(rows.map(\.usage.total) == [8, 7])
    }

    @Test("Агенты делятся на главных, помощников и агентов workflow")
    func agentGroups() {
        let report = book([
            record(day: "2026-11-05", tokens: 1),
            record(day: "2026-11-05", tokens: 2, agent: "a"),
            record(day: "2026-11-05", tokens: 4, agent: "b", run: "wf_1"),
        ]).report(.today)
        let totals = Dictionary(uniqueKeysWithValues: report.lines(.agents).map { ($0.key, $0.usage.total) })
        #expect(totals[.agents(.main)] == 1)
        #expect(totals[.agents(.subagents)] == 2)
        #expect(totals[.agents(.workflow)] == 4)
    }

    @Test("На графике есть и дни без работы, а период старше логов начинается с самого старого лога")
    func chartDays() {
        let book = book([record(day: "2026-11-05"), record(day: "2026-11-02")])
        #expect(book.earliestDay == "2026-11-02")
        let week = book.report(.week).chartDays
        #expect(week.map(\.key) == [.day("2026-11-02"), .day("2026-11-03"), .day("2026-11-04"), .day("2026-11-05")])
        #expect(week.map(\.usage.total) == [100, 0, 0, 100])
        // The table shows only days with work.
        #expect(book.report(.month).lines(.days).count == 2)
    }

    @Test("Полный период неделя и месяц дают 7 и 30 дней на графике")
    func fullChart() {
        let book = book([record(day: "2026-01-01"), record(day: "2026-11-05")])
        #expect(book.report(.week).chartDays.count == 7)
        #expect(book.report(.month).chartDays.count == 30)
        #expect(book.report(.today).chartDays.count == 1)
        #expect(book.report(.all).chartDays.count == 180)
        #expect(book.report(.all).chartDays.last?.key == .day("2026-11-05"))
        // A chart can be cut, a sum cannot, and the page has to say so.
        #expect(book.report(.all).usage.total == 200)
        #expect(book.chartLeavesOutDays(.all))
        #expect(!book.chartLeavesOutDays(.week))
        #expect(!self.book([record(day: "2026-11-01"), record(day: "2026-11-05")]).chartLeavesOutDays(.all))
        #expect(!self.book([]).chartLeavesOutDays(.all))
    }

    @Test("Дата из будущего не попадает в сегодня и неделю, но не теряется")
    func futureDay() {
        let book = book([record(day: "2026-12-31", tokens: 7)])
        #expect(book.report(.today).usage.total == 0)
        #expect(book.report(.week).usage.total == 0)
        #expect(book.report(.all).usage.total == 7)
    }

    @Test("Без логов всё по нулям, и это настоящий ноль")
    func empty() {
        let book = book([])
        #expect(book.earliestDay == nil)
        #expect(book.report(.all).usage.total == 0)
        #expect(book.report(.all).estimate.isKnown)
        #expect(book.report(.all).chartDays.isEmpty)
        #expect(book.spent(onDay: "2026-11-05").total == 0)
    }

    @Test("Сегодня берётся из книги мгновенно")
    func spentToday() {
        let book = book(spread)
        #expect(book.today == "2026-11-05")
        #expect(book.spent(onDay: "2026-11-05").total == 3)
        #expect(book.spent(onDay: "2026-11-04").total == 0)
    }

    @Test("Точные числа ложатся на сессию и на каждого агента в дереве")
    func levels() {
        let records = [
            record(day: "2026-11-05", tokens: 100, session: "s1"),
            record(day: "2026-11-05", tokens: 20, session: "s1", agent: "sub"),
            record(day: "2026-11-04", tokens: 3, session: "s1", agent: "sub"),
            record(day: "2026-11-05", tokens: 40, session: "s1", agent: "w1", run: "wf_1"),
            record(day: "2026-11-05", tokens: 50, session: "s1", agent: "w2", run: "wf_1"),
            record(day: "2026-11-05", tokens: 1000, session: "other"),
        ]
        let live = TokenUsage(input: 7)
        let workflow = WorkNode(id: "wf_1", kind: .workflow, tokens: live, children: [
            WorkNode(id: "w1", kind: .workflowAgent),
            WorkNode(id: "w2", kind: .workflowAgent),
        ])
        let root = WorkNode(id: "s1", kind: .main, children: [
            WorkNode(id: "sub", kind: .subagent, tokens: live),
            WorkNode(id: "new", kind: .subagent, tokens: live),
            workflow,
        ])
        let model = WorkModel(projects: [WorkProject(path: "/x/a", sessions: [WorkSession(id: "s1", state: .running, root: root)])])

        let session = book(records).applied(to: model).sessions[0]
        #expect(session.root.tokens?.total == 213)
        #expect(session.mainAgentTokens?.total == 100)
        let children = session.root.children
        #expect(children[0].tokens?.total == 23)
        // The book has not seen this one yet, so its live number stays.
        #expect(children[1].tokens == live)
        #expect(children[2].tokens?.total == 90)
        #expect(children[2].children[0].tokens?.total == 40)
        #expect(children[2].children[1].tokens?.total == 50)
    }

    @Test("Сессия, которой книга не знает, остаётся без чисел, а не с нулём")
    func unknownSession() {
        let model = WorkModel(projects: [WorkProject(path: nil, sessions: [WorkSession(id: "x", state: .running, root: WorkNode(id: "x", kind: .main))])])
        let session = book([record(day: "2026-11-05")]).applied(to: model).sessions[0]
        #expect(session.root.tokens == nil)
        #expect(session.mainAgentTokens == nil)
    }

    @Test("Сессия в отдельной копии проекта считается в основном проекте, а Cowork без проекта")
    func projectsFollowTheSameRule() {
        let book = TokenBook(records: [
            TokenRecord(sessionId: "a", cwd: "/x/app", entrypoint: "cli", day: "2026-11-05", usage: TokenUsage(input: 1)),
            TokenRecord(sessionId: "b", cwd: "/x/app/.claude/worktrees/fix", entrypoint: "cli", day: "2026-11-05", usage: TokenUsage(input: 2)),
            TokenRecord(sessionId: "c", cwd: "/sessions/vm/outputs", entrypoint: "local-agent", day: "2026-11-05", usage: TokenUsage(input: 4)),
        ], now: Date(timeIntervalSince1970: 1_793_000_000), timeZone: TimeZone(identifier: "UTC") ?? .current)
        let lines = book.report(.all).lines(.projects)
        #expect(lines.first { $0.key == .project("/x/app") }?.usage.total == 3)
        #expect(lines.first { $0.key == .project(nil) }?.usage.total == 4)
        #expect(lines.count == 2)
    }

    @Test("Оценка сессии считается по ценам её моделей, а без цены её нет")
    func sessionEstimate() throws {
        let priced = try #require(PriceTable.price(for: "claude-opus-5-5"))
        let usage = TokenUsage(input: 1_000_000)
        let book = TokenBook(records: [
            TokenRecord(sessionId: "s", day: "2026-11-05", model: "claude-opus-5-5", usage: usage),
            TokenRecord(sessionId: "u", day: "2026-11-05", model: "made-up-model", usage: usage),
        ], now: Date(timeIntervalSince1970: 1_793_000_000), timeZone: TimeZone(identifier: "UTC") ?? .current)
        #expect(book.estimate(session: "s")?.dollars == priced.cost(of: usage))
        #expect(UsageFormat.estimateLine(book.estimate(session: "u")) == nil)
        #expect(UsageFormat.estimateShort(book.estimate(session: "u")) == nil)
        #expect(UsageFormat.estimateCell(book.estimate(session: "u")) == "–")
        #expect(UsageFormat.estimateCell(nil) == "–")
    }

    @Test("Оценка всегда подписана как оценка")
    func estimateIsLabelled() throws {
        var estimate = SpendEstimate()
        estimate.add(TokenUsage(input: 1_000_000), price: try #require(PriceTable.price(for: "claude-opus-5-5")))
        let line = try #require(UsageFormat.estimateLine(estimate, locale: Locale(identifier: "en")))
        #expect(line.hasPrefix("≈ "))
        #expect(line.hasSuffix("at API prices · estimate"))
        let short = try #require(UsageFormat.estimateShort(estimate, locale: Locale(identifier: "en")))
        #expect(short.hasPrefix("≈ "))
        #expect(short.hasSuffix(" estimate"))
    }
}
