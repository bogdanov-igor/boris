import AppKit
import BorisCore
import BorisData
import Foundation
import Testing
@testable import Boris

/// A made-up Claude folder that goes away with the value. Nothing here reaches the person's real one.
private final class ClaudeFolder: @unchecked Sendable {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("boris-model-\(UUID().uuidString)")

    init() {
        try? FileManager.default.createDirectory(at: url.appendingPathComponent("projects"), withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    /// A session that has ended, with one answer in its log.
    func addSession(_ id: String, tokens: Int = 100) {
        let folder = url.appendingPathComponent("projects/-x-demo")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let line = #"{"type":"assistant","timestamp":"2026-11-05T12:00:00.000Z","cwd":"/x/demo","entrypoint":"cli","message":{"id":"\#(id)-m","model":"opus","stop_reason":"end_turn","content":[],"usage":{"input_tokens":\#(tokens),"output_tokens":1}}}"#
        try? (line + "\n").write(to: folder.appendingPathComponent("\(id).jsonl"), atomically: true, encoding: .utf8)
    }
}

@MainActor
private func makeModel(folder: ClaudeFolder? = nil) -> AppModel {
    // In memory: a real store leaves a file in the person's preferences folder.
    let settings = AppSettings(defaults: nil)
    if let folder { settings.claudeFolder = folder.url.path }
    return AppModel(settings: settings, store: nil, live: false)
}

/// Lets the engine and its answers run until the condition holds.
@MainActor
private func waitUntil(seconds: Double = 20, _ condition: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

private func work(_ sessions: WorkSession...) -> WorkModel {
    WorkModel(projects: [WorkProject(path: "/x", sessions: sessions)])
}

private func event(_ kind: EventKind, session: String = "s1", run: String? = nil, at: Date = Date()) -> BorisEvent {
    BorisEvent(id: UUID().uuidString, kind: kind, at: at, runId: run, sessionId: session, project: "demo")
}

@MainActor
@Suite("Модель приложения: переходы")
struct AppModelNavigationTests {
    @Test("Сессия открывается с любой поверхности и приводит в главное окно")
    func openSession() {
        let model = makeModel()
        var shown = 0
        model.onShowMainWindow = { shown += 1 }
        model.page = .now
        model.feedAgent = "old"
        model.openSession("s1")
        #expect(model.page == .projects)
        #expect(model.projectsRoute == .session("s1"))
        #expect(model.feedAgent == nil)
        #expect(shown == 1)
    }

    @Test("Строка потерь открывает сессию на упавшем агенте")
    func openOnAgent() {
        let model = makeModel()
        model.openSession("s1", agent: "a7")
        #expect(model.projectsRoute == .session("s1"))
        #expect(model.feedAgent == "a7")
    }

    @Test("Нажатие на уведомление ведёт туда, куда оно зовёт, и показывает окно", arguments: [
        (NotificationRoute.now, AppPage.now),
        (.usage, .spend),
        (.session("s1"), .projects),
        (.requests(session: nil), .requests),
    ])
    func notificationRoute(route: NotificationRoute, page: AppPage) {
        let model = makeModel()
        var shown = 0
        model.onShowMainWindow = { shown += 1 }
        model.page = .losses
        model.open(route)
        #expect(model.page == page)
        #expect(shown == 1)
    }

    @Test("Уведомление о сессии открывает именно её")
    func notificationOpensTheSession() {
        let model = makeModel()
        model.open(.session("s9"))
        #expect(model.projectsRoute == .session("s9"))
    }

    @Test("Уведомление о запросе выбирает запрос этой сессии")
    func notificationChoosesTheRequest() {
        let model = makeModel()
        let first = PendingPermission(session: "s1", tool: "Bash", content: .command("a", unsandboxed: false), project: "p", askedAt: Date().addingTimeInterval(-20))
        let second = PendingPermission(session: "s2", tool: "Bash", content: .command("b", unsandboxed: false), project: "p", askedAt: Date().addingTimeInterval(-10))
        model.hooks.showRequestsForSnapshot(open: [first, second], expired: [], decisions: [])
        model.open(.requests(session: "s2"))
        let row = model.hooks.queue.rows(now: Date()).first { $0.session == "s2" }
        #expect(model.page == .requests)
        #expect(row != nil)
        #expect(model.hooks.selectedRow == row?.id)
    }

    @Test("Повторный выбор страницы проектов возвращает к их списку, а другие страницы маршрут не трогают")
    func choosingAgain() {
        let model = makeModel()
        model.openSession("s1")
        model.choose(.now)
        #expect(model.projectsRoute == .session("s1"))
        model.choose(.projects)
        #expect(model.projectsRoute == .session("s1"))
        model.choose(.projects)
        #expect(model.projectsRoute == .list)
    }
}

@MainActor
@Suite("Запуск рядом с настоящей копией", .serialized)
struct LaunchCoordinatorTests {
    @Test("Отладочная копия уходит сама и ничего не говорит настоящей")
    func debugCopyLeavesTheRealOneAlone() {
        final class Heard: @unchecked Sendable { var count = 0 }
        let heard = Heard()
        let center = DistributedNotificationCenter.default()
        let observers = [LaunchCoordinator.openMenuNotification, LaunchCoordinator.handOverNotification].map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { _ in heard.count += 1 }
        }
        defer { observers.forEach(center.removeObserver) }
        #expect(!LaunchCoordinator().claimInstance(others: [NSRunningApplication.current]))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        #expect(heard.count == 0)
    }

    @Test("Когда других копий нет, отладочная работает")
    func aloneItRuns() {
        #expect(LaunchCoordinator().claimInstance(others: []))
    }
}

@MainActor
@Suite("Модель приложения: что читается и когда")
struct AppModelFreshnessTests {
    @Test("Закрытие одного окна не лишает свежих данных другое")
    func eachWindowCounts() {
        let model = makeModel()
        #expect(!model.focusWanted.closely)
        model.setLookingClosely(true, from: .mainWindow)
        model.setLookingClosely(true, from: .miniWindow)
        model.setLookingClosely(false, from: .mainWindow)
        #expect(model.focusWanted.closely)
        model.setLookingClosely(false, from: .miniWindow)
        #expect(!model.focusWanted.closely)
    }

    @Test("Запуски открытой сессии читаются чаще, только пока главное окно открыто")
    func focusNeedsTheMainWindow() {
        let model = makeModel()
        model.focus(on: ["wf_1"])
        model.setLookingClosely(true, from: .miniWindow)
        #expect(model.focusWanted.runs.isEmpty)
        model.setLookingClosely(true, from: .mainWindow)
        #expect(model.focusWanted.runs == ["wf_1"])
        model.setLookingClosely(false, from: .mainWindow)
        #expect(model.focusWanted.runs.isEmpty)
        #expect(model.mainWindowIsOpen == false)
    }

    @Test("Закрытое окно не читает логи, даже оставшись на странице проектов, а открытое читает")
    func closedWindowReadsNothing() async throws {
        let folder = ClaudeFolder()
        folder.addSession("s1")
        let model = makeModel(folder: folder)
        model.start()
        model.page = .projects
        // Open and closed again: it remembers the page, and that must cost nothing.
        model.setLookingClosely(true, from: .mainWindow)
        model.setLookingClosely(false, from: .mainWindow)
        #expect(await waitUntil { model.loaded })
        let scansSeen = model.now
        #expect(await waitUntil { model.now > scansSeen.addingTimeInterval(0.2) })
        #expect(!model.pastLoaded)
        #expect(model.pastSessions.isEmpty)

        model.setLookingClosely(true, from: .mainWindow)
        #expect(await waitUntil { model.pastLoaded })
        #expect(model.pastSessions.map(\.id) == ["s1"])
        await model.stop()
    }

    @Test("Другая папка Claude сбрасывает прошлые сессии и расход, и старые числа не возвращаются")
    func anotherFolder() async throws {
        let first = ClaudeFolder()
        first.addSession("old", tokens: 500)
        let second = ClaudeFolder()
        second.addSession("new", tokens: 7)
        let model = makeModel(folder: first)
        model.start()
        model.page = .projects
        model.setLookingClosely(true, from: .mainWindow)
        #expect(await waitUntil { model.pastLoaded && model.usage.book?.spent(session: "old") != nil })
        #expect(model.usage.records.contains { $0.sessionId == "old" })

        model.chooseClaudeFolder(second.url)
        // At once: nothing of the old folder is left on the screen while the new one is read.
        #expect(!model.pastLoaded)
        #expect(model.pastSessions.isEmpty)
        #expect(model.usage.book == nil)
        #expect(model.usage.records.isEmpty)
        #expect(model.today.total == 0)
        #expect(model.usage.todayText(model.today) == UsageFormat.total(nil))

        #expect(await waitUntil { model.pastLoaded && model.usage.book?.spent(session: "new") != nil })
        #expect(model.pastSessions.map(\.id) == ["new"])
        #expect(model.usage.book?.spent(session: "old") == nil)
        #expect(!model.usage.records.contains { $0.sessionId == "old" })
        await model.stop()
    }

    @Test("То, что старая папка успела отправить, после смены папки не показывается")
    func lateOutputIsDropped() async {
        let first = ClaudeFolder()
        let second = ClaudeFolder()
        let model = makeModel(folder: first)
        let generation = model.pastGeneration
        model.chooseClaudeFolder(second.url)
        let old = WorkEngine.Output(at: Date(), model: work(WorkSession(id: "old", state: .running, root: WorkNode(id: "old", kind: .main, state: .running))), world: WorldSnapshot(takenAt: Date()), tokensVersion: 1, tokens: [TokenRecord(sessionId: "old", day: "2026-11-05", usage: TokenUsage(input: 500))])
        model.received(old, generation: generation)
        #expect(!model.work.sessions.contains { $0.id == "old" })
        #expect(!model.usage.records.contains { $0.sessionId == "old" })
        model.received(old, generation: model.pastGeneration)
        #expect(model.work.sessions.contains { $0.id == "old" }, "от нынешнего движка данные принимаются")
        await model.stop()
    }

    @Test("Сборка книги токенов, начатая для старой папки, не возвращает её числа")
    func lateBuildIsDropped() async {
        let usage = UsageModel()
        usage.read([TokenRecord(sessionId: "old", day: "2026-11-05", usage: TokenUsage(input: 500))])
        usage.reset()
        try? await Task.sleep(for: .milliseconds(300))
        #expect(usage.book == nil)
        #expect(usage.records.isEmpty)
    }

    @Test("Без настоящего запуска модель не читает папки Claude вокруг")
    func keepsToItsFolder() async {
        let folder = ClaudeFolder()
        let model = makeModel(folder: folder)
        model.start()
        model.page = .projects
        model.setLookingClosely(true, from: .mainWindow)
        #expect(await waitUntil { model.pastLoaded })
        #expect(model.pastSessions.isEmpty)
        await model.stop()
    }
}

@MainActor
@Suite("Модель приложения: события", .serialized)
struct AppModelEventsTests {
    private let waiting = WorkSession(id: "w1", state: .waiting, waitingFor: .permission(tool: "Bash"), root: WorkNode(id: "w1", kind: .main, state: .waiting))

    private func output(_ events: [BorisEvent] = [], work: WorkModel = WorkModel(), runs: [RunState] = [], at: Date = Date()) -> WorkEngine.Output {
        WorkEngine.Output(at: at, model: work, world: WorldSnapshot(takenAt: at), runs: runs, events: events)
    }

    @Test("Событие доходит до всех: реакция по настройкам, морж, тревога и баннер")
    func eventReachesEveryone() {
        let model = makeModel()
        var heard: [(BorisEvent, Reaction)] = []
        model.onEvent = { heard.append(($0, $1)) }
        let failed = event(.failed, run: "wf_1")
        model.apply(output([failed]))
        #expect(heard.map(\.0.id) == [failed.id])
        #expect(heard.first?.1.banner == true)
        #expect(heard.first?.1.sound == true)
        #expect(model.hasAlarm)
        #expect(model.walrus.line != nil)
        #expect(model.notifications.bannersPostedForCheck.count == 1)
        #expect(model.loaded)
    }

    @Test("Настройка уведомлений важнее значений по умолчанию")
    func choiceWins() {
        let model = makeModel()
        model.settings.notifications.channels[.failure] = ChannelChoice(mac: false, sound: false, telegram: false)
        var heard: [Reaction] = []
        model.onEvent = { heard.append($1) }
        model.apply(output([event(.failed)]))
        #expect(heard.first?.banner == false)
        #expect(heard.first?.sound == false)
        #expect(model.notifications.bannersPostedForCheck.isEmpty)
    }

    @Test("В тишине никто не зовёт: ни баннер, ни морж, ни тревога, а по её концу приходит одна сводка")
    func quietHoldsEverything() {
        let model = makeModel()
        var heard: [Reaction] = []
        model.onEvent = { heard.append($1) }
        model.startQuiet(for: 3600)
        model.apply(output([event(.failed), event(.completed)]))
        #expect(heard.count == 2)
        #expect(heard.allSatisfy { !$0.banner && !$0.sound })
        #expect(!model.hasAlarm)
        #expect(model.walrus.line == nil)
        #expect(model.notifications.bannersPostedForCheck.isEmpty)
        #expect(model.quiet.missed[.failed] == 1)

        model.stopQuiet()
        #expect(model.notifications.bannersPostedForCheck.count == 1)
    }

    @Test("Тишина, закончившаяся сама, тоже приносит одну сводку")
    func quietEndsByItself() {
        let model = makeModel()
        let began = Date()
        model.startQuiet(for: 60)
        model.apply(output([event(.failed)], at: began.addingTimeInterval(1)))
        #expect(model.notifications.bannersPostedForCheck.isEmpty)
        model.apply(output([], at: began.addingTimeInterval(120)))
        #expect(model.notifications.bannersPostedForCheck.count == 1)
    }

    @Test("Сессия, ждущая человека, попадает в очередь запросов и счётчик")
    func waitingReachesTheQueue() {
        let model = makeModel()
        #expect(model.requestCount == 0)
        model.apply(output(work: work(waiting)))
        #expect(model.requestCount == 1)
        model.apply(output(work: WorkModel()))
        #expect(model.requestCount == 0)
    }

    @Test("Завершённый запуск засчитывается, идущий нет")
    func runsAreCounted() {
        let model = makeModel()
        let done = RunState(runId: "wf_1", sessionId: "s1", name: "wf", status: .completed, lastWrite: Date())
        let going = RunState(runId: "wf_2", sessionId: "s1", name: "wf", status: .running, lastWrite: Date())
        let scan = output([event(.completed, run: "wf_1"), event(.silent, run: "wf_2")], runs: [done, going])
        for _ in 1..<AwardTracker.fishGoal { model.apply(scan) }
        #expect(!model.hasFish)
        model.apply(scan)
        #expect(model.hasFish)
    }

    @Test("Числа сессии берутся из книги токенов, а до первого прохода логов известных чисел нет")
    func tokensComeFromTheBook() async {
        let model = makeModel()
        #expect(model.usage.todayText(model.today) == UsageFormat.total(nil))
        #expect(model.surfaceNumbers.tokensToday == nil)
        let day = UsageModel.dayKey(Date())
        let session = WorkSession(id: "s1", state: .running, root: WorkNode(id: "s1", kind: .main, state: .running))
        model.apply(WorkEngine.Output(at: Date(), model: work(session), world: WorldSnapshot(takenAt: Date()), tokensVersion: 1, tokens: [
            TokenRecord(sessionId: "s1", day: day, usage: TokenUsage(input: 40)),
            TokenRecord(sessionId: "s1", agentId: "a1", day: day, usage: TokenUsage(input: 2)),
        ]))
        #expect(await waitUntil { model.usage.book != nil })
        #expect(model.today.total == 42)
        #expect(model.surfaceNumbers.tokensToday == 42)
        #expect(model.work.sessions.first?.root.tokens?.total == 42)
        #expect(model.work.sessions.first?.mainAgentTokens?.total == 40)
    }
}
