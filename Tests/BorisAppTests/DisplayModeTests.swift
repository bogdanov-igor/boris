import AppKit
import BorisCore
import BorisData
import Testing
@testable import Boris

/// Settings that live only in memory, like a person's own between two launches, without leaving a file behind.
private final class MemoryDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]

    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func object(forKey key: String) -> Any? { values[key] }
    override func data(forKey key: String) -> Data? { values[key] as? Data }
    override func string(forKey key: String) -> String? { values[key] as? String }
    override func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
}

@MainActor
private func makeModel(mode: DisplayMode = .simple) -> AppModel {
    let settings = AppSettings(defaults: nil)
    settings.displayMode = mode
    return AppModel(settings: settings, store: nil, live: false)
}

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

@MainActor
private func sampleWork() -> WorkModel {
    let helper = WorkNode(id: "h", kind: .subagent, parentId: "s", title: "Проверка", state: .running)
    let session = WorkSession(id: "s", environment: .terminal, cwd: "/x/demo", state: .running, startedAt: t0, lastActivity: t0, root: WorkNode(id: "s", kind: .main, state: .running, children: [helper]))
    return WorkModel(projects: [WorkProject(path: "/x/demo", sessions: [session])])
}

private func request() -> PendingPermission {
    PendingPermission(session: "s", tool: "Bash", content: .command("make deploy && rm -rf build", unsandboxed: false), project: "demo", askedAt: Date().addingTimeInterval(-30))
}

@Suite("Два режима", .serialized)
@MainActor
struct DisplayModeTests {
    @Test("Первый запуск: простой режим")
    func firstLaunch() {
        #expect(AppSettings(defaults: MemoryDefaults()).displayMode == .simple)
    }

    @Test("Выбор сохраняется между запусками")
    func survivesRestart() {
        let store = MemoryDefaults()
        let model = AppModel(settings: AppSettings(defaults: store), store: nil, live: false)
        model.setDisplayMode(.technical)
        #expect(AppSettings(defaults: store).displayMode == .technical)
        model.setDisplayMode(.simple)
        #expect(AppSettings(defaults: store).displayMode == .simple)
    }

    @Test("Сохранённое непонятное значение не ломает запуск")
    func damagedValue() {
        let store = MemoryDefaults()
        store.set("something-else", forKey: "displayMode")
        #expect(AppSettings(defaults: store).displayMode == .simple)
    }

    @Test("В простом режиме нет Активности и Потерь, в техническом есть всё")
    func pages() {
        #expect(AppPage.allCases.filter { $0.isShown(in: .simple) } == [.now, .projects, .spend, .requests, .walrus])
        #expect(AppPage.allCases.filter { $0.isShown(in: .technical) } == AppPage.allCases)
    }

    @Test("Со скрытой страницы человек попадает на «Сейчас»", arguments: [AppPage.losses, .activity])
    func hiddenPageGivesWay(page: AppPage) {
        let model = makeModel(mode: .technical)
        model.page = page
        model.setDisplayMode(.simple)
        #expect(model.page == .now)
    }

    @Test("Открытая страница остаётся, если она есть и в новом режиме", arguments: [AppPage.now, .projects, .spend, .requests, .walrus])
    func pageStays(page: AppPage) {
        let model = makeModel(mode: .simple)
        model.page = page
        model.setDisplayMode(.technical)
        #expect(model.page == page)
        model.setDisplayMode(.simple)
        #expect(model.page == page)
    }

    @Test("Открытая сессия и выбор агента не теряются")
    func sessionStays() {
        let model = makeModel(mode: .technical)
        model.openSession("s", agent: "h")
        model.expandedPhases = ["wf/Поиск"]
        model.setDisplayMode(.simple)
        #expect(model.page == .projects)
        #expect(model.projectsRoute == .session("s"))
        #expect(model.feedAgent == "h")
        model.setDisplayMode(.technical)
        #expect(model.projectsRoute == .session("s"))
        #expect(model.feedAgent == "h")
        #expect(model.expandedPhases == ["wf/Поиск"])
    }

    @Test("Работа, запросы и начатый ответ переживают переключение туда и обратно")
    func nothingIsLost() {
        let model = makeModel(mode: .simple)
        let work = sampleWork()
        let today = TokenUsage(input: 5, output: 6, cacheRead: 7, cacheWrite: 8)
        let asked = request()
        model.showForSnapshot(work: work, world: WorldSnapshot(takenAt: t0), today: today, mood: .working(agents: 2))
        model.hooks.showRequestsForSnapshot(open: [asked], expired: [], decisions: [])
        model.hooks.updateDraft(asked.id) { $0.denying = true; $0.reason = "сначала копию" }
        let mood = model.mood

        for mode in [DisplayMode.technical, .simple, .technical] {
            model.setDisplayMode(mode)
            #expect(model.work == work)
            #expect(model.today == today)
            #expect(model.mood == mood)
            #expect(model.requestCount == 1)
            #expect(model.hooks.pending == [asked])
            #expect(model.hooks.queue.decisions.isEmpty)
            #expect(model.hooks.draft(asked.id).denying)
            #expect(model.hooks.draft(asked.id).reason == "сначала копию")
        }
    }

    /// The hub is given no mode at all. This holds that in place, on what really leaves it.
    @Test("Упавший агент даёт одно и то же уведомление в обоих режимах")
    func notificationsDoNotCare() {
        func banners(_ mode: DisplayMode) -> [MacBanner] {
            let model = makeModel(mode: mode)
            let event = BorisEvent(id: "e1", kind: .failed, at: t0, sessionId: "s", project: "demo")
            model.notifications.scanned([(event, Reaction(banner: true, sound: false, mood: .alarm))], quiet: false, now: t0)
            return model.notifications.bannersPostedForCheck
        }
        let simple = banners(.simple)
        #expect(!simple.isEmpty)
        #expect(simple == banners(.technical))
    }

    @Test("Счётчики чёлки одни и те же, режим меняет только показ")
    func surfaceNumbers() {
        let model = makeModel(mode: .simple)
        model.showForSnapshot(work: sampleWork(), world: WorldSnapshot(takenAt: t0), today: TokenUsage(input: 1_000_000), mood: .working(agents: 2))
        let numbers = model.surfaceNumbers
        #expect(SurfaceWords.closedLine(numbers, mode: .simple, onNotch: false).main == "2 agents at work")
        model.setDisplayMode(.technical)
        #expect(model.surfaceNumbers == numbers)
    }

    @Test("Карточка запроса в простом режиме: заголовок словами и сама команда")
    func requestCardWords() {
        let asked = request()
        #expect(RequestWords.title(asked, denying: false, mode: .simple) == "Wants to run a command")
        // The words change with the mode, and what is being agreed to does not: the card has one view of it for both.
        guard case .command(let command, _) = asked.content else {
            Issue.record("not a command")
            return
        }
        #expect(command == "make deploy && rm -rf build")
        #expect(RequestWords.title(asked, denying: false, mode: .technical).contains("Bash"))
    }

    /// The boxes of a card are the same in both modes because they do not know about modes. If that changes, it has to be on purpose.
    @Test("Что человек разрешает, показывается без оглядки на режим")
    func cardContentIgnoresTheMode() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Boris/Requests/RequestContentViews.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        #expect(text.contains("struct RequestTextBox"))
        #expect(text.contains("struct RequestDiffBox"))
        #expect(!text.contains("DisplayMode"))
        #expect(!text.contains("displayMode"))
    }

    @Test("Запрос без проекта в простом режиме не показывает идентификатор")
    func requestProject() {
        let bare = WorkSession(id: "0123456789", state: .waiting, root: WorkNode(id: "0123456789", kind: .main))
        #expect(RequestWords.project("demo", session: bare, id: bare.id, mode: .simple) == "demo")
        #expect(RequestWords.project(nil, session: bare, id: bare.id, mode: .simple) == "Session")
        #expect(RequestWords.project(nil, session: bare, id: bare.id, mode: .technical) == "01234567")
        #expect(RequestWords.project(nil, session: nil, id: bare.id, mode: .simple) == "Session")
        #expect(RequestWords.project(nil, session: nil, id: bare.id, mode: .technical) == "01234567")
    }
}
