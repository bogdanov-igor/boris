import AppKit
import BorisCore
import BorisData
import Foundation
import SwiftUI
import Testing
@testable import Boris

/// Stands in for real preferences: a real suite leaves a file in the person's Preferences folder.
private final class MemoryDefaults: UserDefaults, @unchecked Sendable {
    private var stored: [String: Any] = [:]

    override func object(forKey defaultName: String) -> Any? { stored[defaultName] }
    override func data(forKey defaultName: String) -> Data? { stored[defaultName] as? Data }
    override func string(forKey defaultName: String) -> String? { stored[defaultName] as? String }
    override func bool(forKey defaultName: String) -> Bool { stored[defaultName] as? Bool ?? false }
    override func set(_ value: Any?, forKey defaultName: String) { stored[defaultName] = value }
    override func set(_ value: Bool, forKey defaultName: String) { stored[defaultName] = value }
}

@MainActor
private func waitUntil(seconds: Double = 30, _ condition: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

private func event(_ kind: EventKind, environment: WorkEnvironment?, session: String = "s1") -> BorisEvent {
    BorisEvent(id: UUID().uuidString, kind: kind, at: Date(), sessionId: session, project: "demo", environment: environment)
}

private func output(_ events: [BorisEvent] = [], work: WorkModel = WorkModel(), world: WorldSnapshot? = nil) -> WorkEngine.Output {
    WorkEngine.Output(at: Date(), model: work, world: world ?? WorldSnapshot(takenAt: Date()), events: events)
}

@MainActor
private func makeModel() -> AppModel {
    AppModel(settings: AppSettings(defaults: nil), store: nil, live: false)
}

@MainActor
@Suite("Настройки источников в приложении")
struct SourcesSettingsTests {
    @Test("Выбор сохраняется между запусками")
    func persisted() {
        let defaults = MemoryDefaults()
        let first = AppSettings(defaults: defaults)
        #expect(first.sources == SourceSettings())
        first.sources[.cursor].read = false
        first.sources[.vsCode].capture = false
        first.sources.set(.cowork, on: false)
        let second = AppSettings(defaults: defaults)
        #expect(second.sources == first.sources)
        #expect(!second.sources.reads(.cursor))
        #expect(!second.sources.reads(.cowork))
        #expect(second.sources.forbidsCapture(.vsCode))
    }

    @Test("Снимок не трогает выбор человека: настройки только в памяти")
    func snapshotKeepsToMemory() {
        let settings = AppSettings(defaults: nil)
        settings.sources[.cursor].read = false
        #expect(AppSettings(defaults: nil).sources == SourceSettings())
    }
}

@MainActor
@Suite("Уведомления по источникам", .serialized)
struct SourceNotificationTests {
    private let failure = EventKind.failed

    @Test("Для терминала выключены уведомления, там упал агент: сбой виден в Boris, а уведомления и звука нет")
    func muted() {
        let model = makeModel()
        model.settings.sources[.terminal].notify = false
        var heard: [Reaction] = []
        model.onEvent = { heard.append($1) }
        model.apply(output([event(failure, environment: .terminal)]))
        #expect(heard.first?.banner == false)
        #expect(heard.first?.sound == false)
        #expect(model.notifications.bannersPostedForCheck.isEmpty)
        #expect(model.hasAlarm, "в Boris сбой виден")
        #expect(model.walrus.line != nil)
    }

    @Test("Другая среда уведомляет как обычно")
    func othersStillNotify() {
        let model = makeModel()
        model.settings.sources[.terminal].notify = false
        model.apply(output([event(failure, environment: .vsCode)]))
        #expect(model.notifications.bannersPostedForCheck.count == 1)
    }

    @Test("Включение возвращает уведомления, считывание при этом не менялось")
    func backOn() {
        let model = makeModel()
        model.settings.sources[.terminal].notify = false
        #expect(model.settings.sources.reads(.terminal))
        model.apply(output([event(failure, environment: .terminal)]))
        model.settings.sources[.terminal].notify = true
        model.apply(output([event(failure, environment: .terminal)]))
        #expect(model.notifications.bannersPostedForCheck.count == 1)
    }

    @Test("Событие запуска без указания среды находит её по сессии")
    func environmentFromTheSession() {
        let model = makeModel()
        model.settings.sources[.cursor].notify = false
        let session = WorkSession(id: "s1", environment: .cursor, state: .running, root: WorkNode(id: "s1", kind: .main, state: .running))
        model.apply(output(work: WorkModel(projects: [WorkProject(path: "/x", sessions: [session])])))
        model.apply(output([event(failure, environment: nil)], work: WorkModel(projects: [WorkProject(path: "/x", sessions: [session])])))
        #expect(model.notifications.bannersPostedForCheck.isEmpty)
    }

    @Test("В «не беспокоить» заглушённый источник не копится в сводку: она бы позвала за него потом")
    func quietSummaryStaysEmpty() {
        let model = makeModel()
        model.settings.sources[.terminal].notify = false
        model.startQuiet(for: 3600)
        model.apply(output([event(failure, environment: .terminal), event(.completed, environment: .vsCode)]))
        #expect(model.quiet.missed[failure] == nil)
        #expect(model.quiet.missed[.completed] == 1)
    }

    @Test("Лимит одной заглушённой среды молчит, лимит из нескольких сред нет")
    func limits() {
        let model = makeModel()
        model.settings.sources[.terminal].notify = false
        model.apply(output([BorisEvent(id: "l1", kind: .limitReached, at: Date(), environment: .terminal)]))
        #expect(model.notifications.bannersPostedForCheck.isEmpty)
        model.apply(output([BorisEvent(id: "l2", kind: .limitReached, at: Date())]))
        #expect(model.notifications.bannersPostedForCheck.count == 1)
    }
}

@MainActor
@Suite("Запросы по источникам", .serialized)
struct SourceRequestTests {
    private func request(session: String, source: SourceID? = nil) -> PendingPermission {
        PendingPermission(session: session, tool: "Bash", command: "secret", content: .command("secret", unsandboxed: false), project: "demo", deadline: Date().addingTimeInterval(120), source: source)
    }

    @Test("Ответы выключили, пока запрос открыт: карточка уходит без следа в истории, а запрос остаётся в Claude")
    func openRequestLetGo() {
        let model = makeModel()
        model.hooks.showRequestsForSnapshot(open: [request(session: "s1", source: .vsCode), request(session: "s2", source: .terminal)], expired: [], decisions: [])
        model.settings.sources[.vsCode].answer = false
        model.sourcesChanged(reading: false)
        #expect(model.hooks.queue.open.map(\.session) == ["s2"])
        #expect(model.hooks.queue.decisions.isEmpty)
    }

    @Test("Запрос без отметки об источнике решается по его сессии")
    func requestBySession() {
        let model = makeModel()
        let session = WorkSession(id: "s1", environment: .cursor, state: .waiting, waitingFor: .permission(tool: "Bash"), root: WorkNode(id: "s1", kind: .main, state: .waiting))
        model.apply(output(work: WorkModel(projects: [WorkProject(path: "/x", sessions: [session])])))
        model.hooks.showRequestsForSnapshot(open: [request(session: "s1")], expired: [], decisions: [])
        model.settings.sources[.cursor].answer = false
        model.sourcesChanged(reading: false)
        #expect(model.hooks.queue.open.isEmpty)
    }

    @Test("Сессия выключенных ответов остаётся видна как ждущая, и карточка объясняет почему отвечать надо там")
    func stillShownAsWaiting() {
        let model = makeModel()
        model.settings.sources[.vsCode].answer = false
        let session = WorkSession(id: "s1", environment: .vsCode, state: .waiting, waitingFor: .permission(tool: "Bash"), root: WorkNode(id: "s1", kind: .main, state: .waiting))
        model.apply(output(work: WorkModel(projects: [WorkProject(path: "/x", sessions: [session])])))
        #expect(model.requestCount == 1)
        #expect(SourcesRequestWords.notAnswered(session, settings: model.settings.sources)?.contains("VS Code") == true)
        #expect(SourcesRequestWords.notAnswered(session, settings: SourceSettings()) == nil)
    }

    @Test("Запрос, чьё время вышло, тоже уходит, когда источник перестают считывать")
    func expiredGoesWithReading() {
        let model = makeModel()
        let session = WorkSession(id: "s1", environment: .cursor, state: .waiting, waitingFor: .permission(tool: "Bash"), root: WorkNode(id: "s1", kind: .main, state: .waiting))
        model.apply(output(work: WorkModel(projects: [WorkProject(path: "/x", sessions: [session])])))
        model.hooks.showRequestsForSnapshot(open: [], expired: [request(session: "s1")], decisions: [])
        model.settings.sources[.cursor].read = false
        model.hooks.applySources()
        #expect(model.hooks.queue.expired.isEmpty)
    }
}

@MainActor
@Suite("Выключение и включение считывания", .serialized)
struct SourceReadingTests {
    /// A made-up Claude folder with one session in the terminal and one in VS Code. Nothing here reaches the real one.
    private final class Folder: @unchecked Sendable {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("boris-sources-\(UUID().uuidString)")

        init() {
            add("term", entrypoint: "cli", tokens: 100)
            add("code", entrypoint: "claude-vscode", tokens: 500)
        }

        deinit { try? FileManager.default.removeItem(at: url) }

        private func add(_ id: String, entrypoint: String, tokens: Int) {
            let folder = url.appendingPathComponent("projects/-x-\(id)")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let line = #"{"type":"assistant","timestamp":"2026-11-05T12:00:00.000Z","cwd":"/x/\#(id)","entrypoint":"\#(entrypoint)","message":{"id":"\#(id)-m","model":"opus","stop_reason":"end_turn","content":[],"usage":{"input_tokens":\#(tokens),"output_tokens":0}}}"#
            try? (line + "\n").write(to: folder.appendingPathComponent("\(id).jsonl"), atomically: true, encoding: .utf8)
        }
    }

    private func total(_ model: AppModel) -> Int {
        model.usage.records.reduce(0) { $0 + $1.usage.total }
    }

    @Test("Выключение убирает сессии и расход, итоги помечены, а включение восстанавливает всё из логов")
    func roundTrip() async throws {
        let folder = Folder()
        let settings = AppSettings(defaults: nil)
        settings.claudeFolder = folder.url.path
        let model = AppModel(settings: settings, store: nil, live: false)
        model.start()
        model.page = .projects
        model.setLookingClosely(true, from: .mainWindow)
        #expect(await waitUntil { model.pastLoaded && model.usage.book?.spent(session: "code") != nil })
        #expect(total(model) == 600)
        #expect(Set(model.pastSessions.map(\.id)) == ["term", "code"])
        #expect(SourceWords.incompleteNote(settings.sources) == nil)

        settings.sources[.vsCode].read = false
        model.sourcesChanged(reading: true)
        #expect(await waitUntil { model.pastLoaded && model.usage.book != nil && model.usage.book?.spent(session: "code") == nil && model.usage.book?.spent(session: "term") != nil })
        #expect(total(model) == 100)
        #expect(model.pastSessions.map(\.id) == ["term"])
        #expect(!model.usage.records.contains { $0.sessionId == "code" })
        #expect(SourceWords.incompleteNote(settings.sources)?.contains("VS Code") == true)
        #expect(model.sourceFilter.off == [.chat, .vsCode])

        settings.sources[.vsCode].read = true
        model.sourcesChanged(reading: true)
        #expect(await waitUntil { model.pastLoaded && model.usage.book?.spent(session: "code") != nil })
        #expect(total(model) == 600)
        #expect(Set(model.pastSessions.map(\.id)) == ["term", "code"])
        #expect(SourceWords.incompleteNote(settings.sources) == nil)
        await model.stop()
    }

    @Test("Несколько переключателей подряд это одно изменение, а не перезапуск за каждый")
    func severalSwitches() async {
        let folder = Folder()
        let settings = AppSettings(defaults: nil)
        settings.claudeFolder = folder.url.path
        let model = AppModel(settings: settings, store: nil, live: false)
        model.start()
        let first = model.sourceFilter
        settings.sources[.cursor].read = false
        model.sourcesChanged(reading: true)
        settings.sources[.vsCode].read = false
        model.sourcesChanged(reading: true)
        settings.sources[.terminal].read = false
        model.sourcesChanged(reading: true)
        #expect(model.sourceFilter === first, "сразу ничего не перезапускается")
        #expect(await waitUntil { model.sourceFilter !== first })
        #expect(model.sourceFilter.off == [.chat, .cursor, .vsCode, .terminal])
        await model.stop()
    }

    @Test("Чат без файлов не заставляет читать логи заново")
    func chatDoesNotRestart() async {
        let folder = Folder()
        let settings = AppSettings(defaults: nil)
        settings.claudeFolder = folder.url.path
        let model = AppModel(settings: settings, store: nil, live: false)
        model.start()
        let first = model.sourceFilter
        settings.sources.set(.chat, on: true)
        model.sourcesChanged(reading: true)
        try? await Task.sleep(for: .milliseconds(700))
        #expect(model.sourceFilter === first)
        await model.stop()
    }

    @Test("Запоздавшие слова старой проверки не возвращают выключенное")
    func lateOutputIgnored() async {
        let folder = Folder()
        let settings = AppSettings(defaults: nil)
        settings.claudeFolder = folder.url.path
        let model = AppModel(settings: settings, store: nil, live: false)
        model.start()
        #expect(await waitUntil { model.usage.book != nil })
        settings.sources[.terminal].read = false
        settings.sources[.vsCode].read = false
        model.sourcesChanged(reading: true)
        #expect(await waitUntil { model.sourceFilter.off.contains(.vsCode) && model.usage.book != nil })
        // Let anything the old engine still had on the way arrive.
        try? await Task.sleep(for: .milliseconds(600))
        #expect(!model.usage.records.contains { $0.sessionId == "code" || $0.sessionId == "term" })
        await model.stop()
    }

    @Test("Нагрузка получает выключенное: Claude в терминале отдельно от Claude в редакторах")
    func loadOffReachesTheWatch() {
        let model = makeModel()
        model.settings.sources[.terminal].read = false
        var world = WorldSnapshot(takenAt: Date())
        world.hiddenSessions = ["hidden": 321]
        model.apply(output(world: world))
        #expect(model.load.off.claudeOnItsOwn)
        #expect(model.load.off.claudeIn.isEmpty, "Claude в редакторах остаётся Claude")
        #expect(model.load.off.programs.isEmpty)
        #expect(model.load.off.sessions == [321])
        #expect(model.requestCount == 0)
    }
}

/// No window here is ever shown or made key. One goes far off screen, as a snapshot's does, so that the window server can be asked about it.
@MainActor
@Suite("Запрет снимков экрана", .serialized)
struct CaptureTests {
    private func busyModel(page: AppPage = .now) -> AppModel {
        let model = makeModel()
        DevData.busy.fill(model)
        model.page = page
        return model
    }

    @Test("Запретили Cowork и он на странице: окно скрыто. Разрешённая сессия одна на экране: окно видно")
    func sessionPages() {
        let model = busyModel()
        model.settings.sources[.cowork].capture = false
        #expect(model.hidesFromCapture(.main), "на «Сейчас» есть Cowork вместе с другими: скрыто всё окно")

        model.openSession("c1")
        #expect(model.hidesFromCapture(.main), "открыта сама сессия Cowork")

        model.openSession(DevProjects.working)
        #expect(!model.hidesFromCapture(.main), "сессия другого источника без данных Cowork")

        model.choose(.walrus)
        #expect(!model.hidesFromCapture(.main), "на странице моржа нет ничьих данных")
    }

    @Test("Морж может назвать проект на любой странице, поэтому, пока он говорит, окно идёт как окно с работой")
    func walrusLine() {
        let model = busyModel(page: .walrus)
        model.settings.sources[.cowork].capture = false
        #expect(!model.hidesFromCapture(.main))
        model.walrus.sayForSnapshot("Агент упал", count: 1)
        #expect(model.hidesFromCapture(.main))
    }

    @Test("Мини-окно и чёлка показывают работу всех источников")
    func miniAndNotch() {
        let model = busyModel()
        #expect(!model.hidesFromCapture(.mini))
        model.settings.sources[.cowork].capture = false
        #expect(model.hidesFromCapture(.mini))
        #expect(model.hidesFromCapture(.notch))
    }

    @Test("Запрет источника, которого нет на экране, окно не скрывает")
    func nothingOfItShown() {
        let model = makeModel()
        model.settings.sources[.cowork].capture = false
        #expect(!model.hidesFromCapture(.main))
        #expect(!model.hidesFromCapture(.mini))
    }

    @Test("Открытый запрос запрещённого источника считается, пока его сессии ещё нет в работе")
    func openRequest() {
        let model = makeModel()
        model.settings.sources[.vsCode].capture = false
        #expect(!model.hidesFromCapture(.notch))
        model.hooks.showRequestsForSnapshot(open: [PendingPermission(session: "s1", tool: "Bash", content: .command("x", unsandboxed: false), source: .vsCode)], expired: [], decisions: [])
        #expect(model.hidesFromCapture(.notch))
    }

    @Test("Расход тоже данные: итог с запрещённым источником скрывает окно")
    func totals() {
        let model = makeModel()
        model.settings.sources[.vsCode].capture = false
        model.page = .spend
        #expect(!model.hidesFromCapture(.main))
        model.usage.showForSnapshot(book: nil, records: [TokenRecord(sessionId: "s", entrypoint: "claude-vscode", day: "2026-11-05", usage: TokenUsage(input: 1))])
        #expect(model.hidesFromCapture(.main))
    }

    private final class SilentWindow: NSWindow {
        override func keyDown(with event: NSEvent) {}
        override func noResponder(for eventSelector: Selector) {}
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private func offScreenWindow() -> NSWindow {
        _ = NSApplication.shared
        let window = SilentWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.orderBack(nil)
        return window
    }

    private let readOnly = Int(NSWindow.SharingType.readOnly.rawValue)
    private let hidden = Int(NSWindow.SharingType.none.rawValue)

    /// What the window server itself has on record. Asking this needs no permission, unlike taking a picture.
    /// The window's own property cannot be asked: once `.none`, it keeps saying so.
    private func serverSharingState(_ window: NSWindow) -> Int? {
        let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(window.windowNumber)) as? [[String: Any]]
        return info?.first?[kCGWindowSharingState as String] as? Int
    }

    @Test("Окно уходит из снимков, как только в нём появляются данные запрещённого источника, и оконный сервер это знает")
    func keeperHides() async {
        let model = busyModel()
        let window = offScreenWindow()
        defer {
            window.orderOut(nil)
            window.close()
        }
        model.capture.watch(window, as: .main)
        #expect(await waitUntil(seconds: 5) { serverSharingState(window) == readOnly }, "пока запретов нет")
        #expect(!model.capture.wasHidden(window))

        model.settings.sources[.cowork].capture = false
        #expect(await waitUntil(seconds: 5) { serverSharingState(window) == hidden })
        #expect(model.capture.wasHidden(window))
        #expect(!window.isKeyWindow)
        #expect(!NSApp.isActive)
    }

    @Test("Запрет на открытую разрешённую страницу не действует, пока не появятся запрещённые данные")
    func hidesOnlyWhenNeeded() async {
        let model = busyModel()
        model.settings.sources[.cowork].capture = false
        model.openSession(DevProjects.working)
        let window = offScreenWindow()
        defer {
            window.orderOut(nil)
            window.close()
        }
        model.capture.watch(window, as: .main)
        #expect(await waitUntil(seconds: 5) { serverSharingState(window) == readOnly })
        #expect(!model.capture.wasHidden(window))
        model.choose(.now)
        #expect(await waitUntil(seconds: 5) { serverSharingState(window) == hidden })
    }

    /// The system lets a window leave captures once: brought back, it stays visible whatever is asked of it later. So it must never be brought back.
    @Test("Скрытое окно не возвращается в снимки ни при какой смене, иначе его уже не скрыть")
    func neverBroughtBack() async {
        let model = busyModel()
        let window = offScreenWindow()
        defer {
            window.orderOut(nil)
            window.close()
        }
        model.settings.sources[.cowork].capture = false
        model.capture.watch(window, as: .main)
        #expect(await waitUntil(seconds: 5) { serverSharingState(window) == hidden })
        model.openSession(DevProjects.working)
        try? await Task.sleep(for: .milliseconds(150))
        #expect(serverSharingState(window) == hidden, "страница без данных Cowork")
        model.settings.sources[.cowork].capture = true
        try? await Task.sleep(for: .milliseconds(150))
        #expect(serverSharingState(window) == hidden, "запрет снят")
        model.settings.sources[.cowork].capture = false
        model.choose(.now)
        try? await Task.sleep(for: .milliseconds(150))
        #expect(serverSharingState(window) == hidden, "и снова нужно скрывать: получилось бы, только если окно не возвращали")
    }

    @Test("Запрет сняли, и новое окно на этом месте снова видно, а новый запрет его снова скрывает")
    func newWindowComesBack() async {
        let model = busyModel()
        model.settings.sources[.cowork].capture = false
        let old = offScreenWindow()
        model.capture.watch(old, as: .main)
        #expect(await waitUntil(seconds: 5) { serverSharingState(old) == hidden })
        model.settings.sources[.cowork].capture = true

        let new = offScreenWindow()
        defer {
            for window in [old, new] {
                window.orderOut(nil)
                window.close()
            }
        }
        model.capture.watch(new, as: .main)
        #expect(await waitUntil(seconds: 5) { serverSharingState(new) == readOnly })
        #expect(serverSharingState(old) == hidden, "за старым больше никто не следит")
        model.settings.sources[.cowork].capture = false
        #expect(await waitUntil(seconds: 5) { serverSharingState(new) == hidden })
    }

    @Test("То же окно, отданное снова, не считается новым")
    func sameWindowKeepsItsRecord() async {
        let model = busyModel()
        model.settings.sources[.cowork].capture = false
        let window = offScreenWindow()
        defer {
            window.orderOut(nil)
            window.close()
        }
        model.capture.watch(window, as: .mini)
        #expect(await waitUntil(seconds: 5) { serverSharingState(window) == hidden })
        model.settings.sources[.cowork].capture = true
        model.capture.watch(window, as: .mini)
        #expect(model.capture.wasHidden(window))
    }
}

@MainActor
@Suite("Экран источников")
struct SourcesScreenTests {
    @Test("Раздел собирается при любом выборе, ничего не показывая")
    func builds() {
        // The language stays as it is: it is set for the whole process, and other tests are running.
        let settings = AppSettings(defaults: nil)
        settings.sources[.cursor].read = false
        settings.sources.set(.cowork, on: false)
        let model = AppModel(settings: settings, store: nil, live: false)
        let host = NSHostingView(rootView: SourcesSettings(model: model).frame(width: 446))
        host.frame = NSRect(x: 0, y: 0, width: 446, height: 800)
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.height > 300)
    }
}
