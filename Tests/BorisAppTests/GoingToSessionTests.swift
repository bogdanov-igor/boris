import AppKit
import BorisCore
import BorisData
import Foundation
import SwiftUI
import Testing
@testable import Boris

private func session(_ id: String, _ state: WorkState = .running) -> WorkSession {
    WorkSession(id: id, environment: .terminal, cwd: "/x/\(id)", state: state, root: WorkNode(id: id, kind: .main, state: state))
}

@MainActor
@Suite("Мини-окно")
struct MiniWindowTests {
    @Test("Строка сессии закрывает окно и открывает эту сессию в главном окне")
    func rowOpensTheSession() {
        let model = AppModel(settings: AppSettings(defaults: nil), store: nil, live: false)
        var closed = 0
        var shown = 0
        model.onShowMainWindow = { shown += 1 }
        let mini = MiniWindowView(model: model, close: { closed += 1 }, openMain: {})
        mini.open(session("s7"))
        #expect(closed == 1)
        #expect(shown == 1)
        #expect(model.page == .projects)
        #expect(model.projectsRoute == .session("s7"))
    }

    @Test("Настоящая строка в окне нажимается", arguments: [DisplayMode.simple, .technical])
    func realRowIsPressed(mode: DisplayMode) async {
        let settings = AppSettings(defaults: nil)
        settings.displayMode = mode
        let model = AppModel(settings: settings, store: nil, live: false)
        model.showForSnapshot(work: WorkModel(projects: [WorkProject(path: "/x/one", sessions: [session("one")])]), world: WorldSnapshot(takenAt: Date()), today: TokenUsage(), mood: .working(agents: 1))
        var closed = 0
        var shown = 0
        model.onShowMainWindow = { shown += 1 }
        let clicks = OffScreenClicks(MiniWindowView(model: model, close: { closed += 1 }, openMain: {}), size: CGSize(width: 360, height: 500))
        defer { clicks.close() }
        // Down the middle of the window: nothing above the sessions answers to a click there.
        let opened = await clicks.press(along: clicks.downColumn(x: 180)) { model.projectsRoute == .session("one") }
        #expect(opened)
        #expect(closed == 1)
        #expect(shown == 1)
    }

    @Test("Живые данные доходят до окна: сессия из логов считается за сегодня")
    func liveData() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("boris-mini-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = folder.appendingPathComponent("projects/-x-demo/s1.jsonl")
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        let time = ISO8601DateFormatter().string(from: Date())
        let line = #"{"type":"assistant","timestamp":"\#(time)","cwd":"/x/demo","entrypoint":"cli","message":{"id":"m1","model":"opus","stop_reason":"end_turn","content":[],"usage":{"input_tokens":100,"output_tokens":1}}}"#
        try (line + "\n").write(to: log, atomically: true, encoding: .utf8)
        let settings = AppSettings(defaults: nil)
        settings.claudeFolder = folder.path
        let model = AppModel(settings: settings, store: nil, live: false)
        model.start()
        let end = Date().addingTimeInterval(20)
        while model.usage.book == nil, Date() < end { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.usage.book?.sessionsToday == 1)
        #expect(model.today.total > 0)
        let host = NSHostingView(rootView: MiniWindowView(model: model, openMain: {}))
        host.frame = NSRect(x: 0, y: 0, width: 360, height: 600)
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.height > 100)
        await model.stop()
    }

    @Test("Все блоки на месте, и длинные данные не ломают окно", arguments: [DevData.busy, .empty, .long], [DisplayMode.simple, .technical])
    func blocks(data: DevData, mode: DisplayMode) async {
        let settings = AppSettings(defaults: nil)
        settings.displayMode = mode
        let model = AppModel(settings: settings, store: nil, live: false)
        data.fill(model)
        let host = NSHostingView(rootView: MiniWindowView(model: model, openMain: {}))
        host.frame = NSRect(x: 0, y: 0, width: 360, height: 600)
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width == 360)
        #expect(host.fittingSize.height > 100)
    }

    @Test("Сегодняшние сессии считаются один раз, вчерашние нет")
    func sessionsToday() {
        let now = Date()
        let today = TokenBook(records: [], now: now).today
        func record(_ session: String, _ day: String) -> TokenRecord {
            TokenRecord(sessionId: session, day: day, usage: TokenUsage(input: 5))
        }
        let book = TokenBook(records: [record("a", today), record("a", today), record("b", today), record("c", "2020-01-01")], now: now)
        #expect(book.sessionsToday == 2)
    }
}

@MainActor
@Suite("История запросов")
struct RequestHistoryTests {
    private func decision(session: String?) -> RequestDecision {
        RequestDecision(id: UUID(), at: Date(), session: session, project: "p", environment: "VS Code", agentType: nil, isMainAgent: true, brief: RequestBrief(tool: "Bash", kind: .command), outcome: .allowed, place: .window, waited: 3)
    }

    private func page(_ decisions: [RequestDecision]) -> (AppModel, OffScreenClicks) {
        let model = AppModel(settings: AppSettings(defaults: nil), store: nil, live: false)
        model.hooks.showRequestsForSnapshot(open: [], expired: [], decisions: decisions)
        model.page = .requests
        return (model, OffScreenClicks(RequestsPage(model: model), size: CGSize(width: 1000, height: 600)))
    }

    @Test("Строка истории открывает свою сессию")
    func opens() async {
        let (model, clicks) = page([decision(session: "s5")])
        defer { clicks.close() }
        let opened = await clicks.press(along: clicks.downColumn(x: 500)) { model.projectsRoute == .session("s5") }
        #expect(opened)
        #expect(model.page == .projects)
    }

    @Test("Строка из прежней версии никуда не ведёт и ничего не ломает")
    func oldLine() async {
        let (model, clicks) = page([decision(session: nil)])
        defer { clicks.close() }
        let moved = await clicks.press(along: clicks.downColumn(x: 500)) { model.page != .requests }
        #expect(!moved)
    }
}

@MainActor
@Suite("Куда ведёт сбой")
struct FeedTargetModelTests {
    @Test("Страница потерь передаёт сбой, а обычное открытие его сбрасывает")
    func model() {
        let model = AppModel(settings: AppSettings(defaults: nil), store: nil, live: false)
        let target = FeedTarget(stepId: "t", at: Date())
        model.openSession("s", agent: "a", target: target)
        #expect(model.feedTarget == target)
        #expect(model.feedAgent == "a")
        model.openSession("s2")
        #expect(model.feedTarget == nil)
    }
}
