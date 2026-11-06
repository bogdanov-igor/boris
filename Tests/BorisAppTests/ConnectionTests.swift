import AppKit
import BorisCore
import BorisData
import Foundation
import Testing
@testable import Boris

/// A Claude folder that exists only for this test. Nothing here reaches the person's real settings.
private final class ClaudeHome: @unchecked Sendable {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("boris-connect-\(UUID().uuidString)")
    var settings: URL { url.appendingPathComponent("settings.json") }

    /// - Parameter exists: false leaves the folder out altogether, as on a Mac where Claude has never run.
    init(exists: Bool = true) {
        guard exists else { return }
        try? FileManager.default.createDirectory(at: url.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: url.appendingPathComponent("projects"), withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func write(_ path: String, _ text: String) {
        let file = url.appendingPathComponent(path)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: file, atomically: true, encoding: .utf8)
    }

    var settingsText: String? { try? String(contentsOf: settings, encoding: .utf8) }
    var settingsBytes: Data? { try? Data(contentsOf: settings) }
    var hasBackup: Bool { FileManager.default.fileExists(atPath: settings.path + ".boris-backup") }

    /// A session that has ended, with one answer in its log.
    func addSession(_ id: String) {
        let line = #"{"type":"assistant","timestamp":"2026-11-05T12:00:00.000Z","cwd":"/x/secret-project","entrypoint":"cli","message":{"id":"\#(id)-m","model":"opus","stop_reason":"end_turn","content":[{"type":"text","text":"secret words"}],"usage":{"input_tokens":10,"output_tokens":1}}}"#
        write("projects/-x-secret-project/\(id).jsonl", line + "\n")
    }
}

@MainActor
private func model(_ home: ClaudeHome, store: StateStore? = nil) -> AppModel {
    let settings = AppSettings(defaults: nil)
    settings.claudeFolder = home.url.path
    let model = AppModel(settings: settings, store: store, live: false)
    model.hooks.checksSettingsWhileOff = true
    return model
}

@MainActor
private func waitUntil(seconds: Double = 20, _ condition: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

private let ours = "boris-hook"

@MainActor
@Suite("Первый запуск", .serialized)
struct FirstRunTests {
    @Test("На чистых настройках Boris сразу видит работу, предлагает ответы и ничего не меняет сам")
    func cleanSettings() async {
        let home = ClaudeHome()
        home.addSession("s1")
        let boris = model(home)
        #expect(boris.isFirstLaunch)
        boris.start()
        #expect(await waitUntil { boris.loaded })
        boris.hooks.refresh()
        #expect(boris.world.claudeFolderFound)
        #expect(boris.hooks.connection == .notConnected)
        #expect(boris.offerConnecting)
        #expect(boris.connectionStatus.problems.isEmpty, "без хуков ничего не сломано")
        #expect(home.settingsText == nil, "пока человек не согласился, файла настроек как не было, так и нет")
        await boris.stop()
    }

    @Test("Отказ: настройки побайтно те же, предложение не возвращается, а подключить можно позже")
    func refusal() async throws {
        let home = ClaudeHome()
        let original = #"{ "model" : "opus" }"#
        home.write("settings.json", original)
        let folder = home.url.appendingPathComponent("boris-state")
        let first = model(home, store: StateStore(folder: folder))
        first.showForSnapshot(work: WorkModel(), world: WorldSnapshot(takenAt: Date()), today: TokenUsage(), mood: .sleeping, offer: true)
        first.hooks.refresh()
        #expect(first.offerConnecting)
        first.offerConnecting = false
        #expect(!first.offerConnecting)
        #expect(home.settingsText == original)
        first.persistNow()

        let second = model(home, store: StateStore(folder: folder))
        second.apply(WorkEngine.Output(at: Date(), model: WorkModel(), world: WorldSnapshot(takenAt: Date()), runs: [], events: []))
        second.hooks.refresh()
        #expect(!second.isFirstLaunch, "второй запуск уже не первый")
        #expect(!second.offerConnecting, "закрытое предложение не возвращается")
        #expect(second.hooks.connection.canConnect, "в «Подключениях» кнопка остаётся")
        let connect = ConnectFlow()
        connect.begin(second, in: .settings)
        guard case .preview = connect.stage else {
            Issue.record("изменения не показаны")
            return
        }
    }

    @Test("Подключение: сначала точные изменения, запись только после согласия, потом проверка, что событие дошло")
    func connecting() async throws {
        let home = ClaudeHome()
        let boris = model(home)
        boris.hooks.refresh()
        let connect = ConnectFlow()
        connect.begin(boris)
        guard case .preview(let preview) = connect.stage else {
            Issue.record("изменения не показаны")
            return
        }
        #expect(preview.lines.contains { $0.hasPrefix("+") && $0.contains(ours) })
        #expect(preview.lines.allSatisfy { $0.hasPrefix("+") }, "на чистых настройках только добавления")
        #expect(home.settingsText == nil, "показ ничего не пишет")

        connect.close()
        #expect(home.settingsText == nil, "отмена ничего не пишет")

        connect.begin(boris)
        connect.confirm(boris)
        guard case .waiting(let since) = connect.stage else {
            Issue.record("нет ожидания")
            return
        }
        #expect(home.settingsText?.contains(ours) == true)
        #expect(boris.hooks.connection == .connected)
        #expect(boris.settings.hooksWanted)
        #expect(!boris.offerConnecting)

        connect.noteEvent(at: nil)
        connect.noteEvent(at: since.addingTimeInterval(-5))
        guard case .waiting = connect.stage else {
            Issue.record("событие до подключения ничего не доказывает: \(connect.stage)")
            return
        }
        let event = since.addingTimeInterval(5)
        connect.noteEvent(at: event)
        #expect(connect.stage == .connected(firstEvent: event))
    }

    @Test("Чужие настройки и хуки на месте, есть копия, а отключение возвращает файл побайтно")
    func foreignHooks() throws {
        let home = ClaudeHome()
        let original = """
        {
            "model": "opus",
            "statusLine": { "type": "command", "command": "other-tool" },
            "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "other-hook" } ] } ] }
        }

        """
        home.write("settings.json", original)
        let before = try #require(home.settingsBytes)
        let boris = model(home)
        boris.hooks.refresh()
        let connect = ConnectFlow()
        connect.begin(boris)
        connect.confirm(boris)
        let written = try #require(home.settingsText)
        #expect(written.contains(ours))
        #expect(written.contains("other-hook"))
        #expect(written.contains("other-tool"))
        #expect(home.hasBackup)
        try boris.hooks.disconnect()
        #expect(home.settingsBytes == before)
        #expect(boris.hooks.connection == .notConnected)
        #expect(!boris.settings.hooksWanted)
    }

    @Test("Подключённым предлагать нечего, и нельзя предлагать то, что запрещено или негде", arguments: [
        HookInstaller.Status.installed, .outdated, .disabledByPolicy, .disabledInSettings, .unreadable,
    ])
    func noOffer(status: HookInstaller.Status) {
        let boris = AppModel(settings: AppSettings(defaults: nil), store: nil, live: false)
        boris.showForSnapshot(work: WorkModel(), world: WorldSnapshot(takenAt: Date()), today: TokenUsage(), mood: .sleeping, offer: true)
        boris.hooks.showForSnapshot(status: status)
        #expect(!boris.offerConnecting)
    }

    @Test("Без папки Claude предлагать нечего")
    func noFolderNoOffer() {
        let boris = AppModel(settings: AppSettings(defaults: nil), store: nil, live: false)
        boris.showForSnapshot(work: WorkModel(), world: WorldSnapshot(takenAt: Date(), claudeFolderFound: false), today: TokenUsage(), mood: .sleeping, offer: true)
        #expect(!boris.offerConnecting)
    }

    @Test("Запрет политикой не даёт кнопки подключения")
    func policyHasNoButton() {
        #expect(!HookConnection.disabledByPolicy.canConnect)
        #expect(!ConnectionStatus(world: WorldSnapshot(takenAt: Date()), hooks: .disabledByPolicy, hookState: HookState(), hooksSince: Date(), now: Date()).isBroken, "это не поломка")
    }

    @Test("Поток начат в настройках: его лист там, а не в главном окне, которое может быть закрыто")
    func sheetPlace() {
        let home = ClaudeHome()
        let boris = model(home)
        let connect = ConnectFlow()
        connect.begin(boris, in: .settings)
        #expect(connect.place == .settings)
        connect.begin(boris)
        #expect(connect.place == .main)
    }
}

/// Real buttons of the real views, pressed off screen with made-up mouse events, on a made-up Claude folder.
@MainActor
@Suite("Первый запуск: настоящие кнопки", .serialized)
struct FirstRunButtonTests {
    private func offered(_ home: ClaudeHome) -> AppModel {
        let boris = model(home)
        boris.showForSnapshot(work: WorkModel(), world: WorldSnapshot(takenAt: Date()), today: TokenUsage(), mood: .sleeping, offer: true)
        boris.hooks.refresh()
        return boris
    }

    private let size = CGSize(width: 1000, height: 700)

    @Test("«Показать изменения» ничего не пишет, «Подключить» пишет, и лист показывает ожидание")
    func connect() async {
        let home = ClaudeHome()
        let boris = offered(home)
        let flow = ConnectFlow()
        let clicks = OffScreenClicks(MainWindowView(model: boris, connect: flow, openSettings: { _ in }), size: size)
        defer { clicks.close() }
        // The offer's main button sits in the bottom row of its card, at the bottom right of the window.
        let opened = await clicks.press(along: clicks.fromBottomRight(rows: 2...6)) { flow.stage != .closed }
        #expect(opened)
        guard case .preview = flow.stage else {
            Issue.record("изменения не показаны")
            return
        }
        #expect(home.settingsText == nil, "показ ничего не пишет")
        await clicks.settle()
        // The sheet hangs from the top of the page, right of the sidebar. Its main button is at its bottom right, and the rest of the window is under its shade.
        let right = 211 + (size.width - 211) / 2 + 225
        let sheet = stride(from: size.height - 300, through: 20, by: -6).map { NSPoint(x: right, y: $0) }
        let written = await clicks.press(along: sheet) { home.settingsText != nil }
        #expect(written)
        #expect(home.settingsText?.contains(ours) == true)
        guard case .waiting = flow.stage else {
            Issue.record("нет ожидания")
            return
        }
        #expect(boris.hooks.connection == .connected)
    }

    @Test("«Не сейчас» закрывает предложение, а настройки те же")
    func notNow() async {
        let home = ClaudeHome()
        home.write("settings.json", #"{ "model" : "opus" }"#)
        let boris = offered(home)
        let clicks = OffScreenClicks(ConnectOffer(model: boris, connect: ConnectFlow()), size: CGSize(width: 420, height: 200))
        defer { clicks.close() }
        // Past the main button, whose press would change the stage and not this.
        let left = clicks.fromBottomRight(rows: 1...6, step: 12).filter { $0.x < 300 && $0.x > 120 }
        let gone = await clicks.press(along: left) { !boris.offerConnecting }
        #expect(gone)
        #expect(home.settingsText == #"{ "model" : "opus" }"#)
    }

    @Test("Крестик закрывает предложение так же")
    func cross() async {
        let home = ClaudeHome()
        let boris = offered(home)
        let clicks = OffScreenClicks(ConnectOffer(model: boris, connect: ConnectFlow()), size: CGSize(width: 420, height: 200))
        defer { clicks.close() }
        let corner = stride(from: 200, through: 100, by: -6).map { NSPoint(x: 392, y: CGFloat($0)) }
        let gone = await clicks.press(along: corner) { !boris.offerConnecting }
        #expect(gone)
        #expect(home.settingsText == nil)
    }

    @Test("В настройках «Подключить ответы» открывает лист там же, а не в закрытом главном окне")
    func fromSettings() async {
        let home = ClaudeHome()
        let boris = offered(home)
        boris.settingsSection = .connections
        let flow = ConnectFlow()
        let clicks = OffScreenClicks(SettingsView(model: boris, connect: flow, actions: SettingsActions()), size: CGSize(width: 760, height: 720))
        defer { clicks.close() }
        let opened = await clicks.press(along: clicks.downColumn(x: 650, step: 8).prefix(30).map { $0 }) { flow.stage != .closed }
        #expect(opened)
        #expect(flow.place == .settings)
    }
}

@MainActor
@Suite("Починка: настоящая кнопка", .serialized)
struct RepairButtonTests {
    @Test("Хуки удалены руками, и «Починить» в «Подключениях» возвращает их одним нажатием")
    func repairInSettings() async throws {
        let home = ClaudeHome()
        let boris = model(home)
        boris.hooks.refresh()
        let connect = ConnectFlow()
        connect.begin(boris)
        connect.confirm(boris)
        connect.close()
        home.write("settings.json", #"{ "model": "sonnet" }"#)
        boris.hooks.refresh()
        #expect(boris.hooks.connection == .damaged)
        boris.settingsSection = .connections
        let clicks = OffScreenClicks(SettingsView(model: boris, connect: connect, actions: SettingsActions()), size: CGSize(width: 760, height: 720))
        defer { clicks.close() }
        let repaired = await clicks.press(along: clicks.downColumn(x: 670, step: 8).prefix(30).map { $0 }) { boris.hooks.connection == .connected }
        #expect(repaired)
        #expect(connect.stage == .closed)
        let text = try #require(home.settingsText)
        #expect(text.contains(ours))
        #expect(text.contains("sonnet"))
    }
}

@MainActor
@Suite("Диагностика и починка", .serialized)
struct RepairTests {
    private func connected(_ home: ClaudeHome) -> AppModel {
        let boris = model(home)
        boris.hooks.refresh()
        let connect = ConnectFlow()
        connect.begin(boris)
        connect.confirm(boris)
        return boris
    }

    private var world: WorldSnapshot { WorldSnapshot(takenAt: Date()) }

    @Test("Хуки удалены руками: Boris замечает, говорит и чинит одной кнопкой, без вопросов")
    func removedByHand() throws {
        let home = ClaudeHome()
        let boris = connected(home)
        #expect(boris.connectionStatus.problems.isEmpty)
        // What a person or another program leaves behind: their own settings, without ours.
        home.write("settings.json", #"{ "model": "sonnet" }"#)
        boris.hooks.refresh()
        #expect(boris.hooks.connection == .damaged)
        let status = boris.connectionStatus
        #expect(status.problems == [.hooksDamaged])
        #expect(status.isBroken)
        #expect(ConnectionNotices.shown(status.problems, page: .now) == [.hooksDamaged])

        let connect = ConnectFlow()
        connect.repair(boris)
        #expect(connect.stage == .closed, "никаких вопросов и листов: человек уже согласился")
        #expect(boris.hooks.connection == .connected)
        #expect(boris.connectionStatus.problems.isEmpty)
        let text = try #require(home.settingsText)
        #expect(text.contains(ours))
        #expect(text.contains("sonnet"), "чужое, появившееся за это время, остаётся")
    }

    @Test("Хуки изменены: это тоже поломка, и она чинится")
    func changed() throws {
        let home = ClaudeHome()
        let boris = connected(home)
        let text = try #require(home.settingsText)
        home.write("settings.json", text.replacingOccurrences(of: ours, with: "boris-hook-old"))
        boris.hooks.refresh()
        #expect(boris.hooks.connection == .damaged)
        ConnectFlow().repair(boris)
        #expect(boris.hooks.connection == .connected)
    }

    @Test("Повреждённый файл Boris не перезаписывает и говорит об этом")
    func damagedFile() throws {
        let home = ClaudeHome()
        let boris = connected(home)
        let damaged = "{ \"hooks\": not json"
        home.write("settings.json", damaged)
        boris.hooks.refresh()
        #expect(boris.hooks.connection == .settingsUnreadable)
        #expect(boris.connectionStatus.problems == [.settingsUnreadable])
        let connect = ConnectFlow()
        connect.repair(boris, in: .settings)
        guard case .failed = connect.stage else {
            Issue.record("об отказе не сказано: \(connect.stage)")
            return
        }
        #expect(connect.place == .settings, "отказ виден там, где нажали")
        #expect(home.settingsText == damaged)
        connect.close()
        connect.begin(boris)
        guard case .failed = connect.stage else {
            Issue.record("об отказе не сказано: \(connect.stage)")
            return
        }
        #expect(home.settingsText == damaged)
    }

    @Test("Хуки подключены, Claude работает, событий давно нет: это видно, а просто тишина не проблема")
    func silent() {
        let busy = SessionInfo(sessionId: "s", pid: 1, entrypoint: "cli", status: "busy", statusUpdatedAt: Date().addingTimeInterval(-600))
        let boris = AppModel(settings: AppSettings(defaults: nil), store: nil, live: false)
        boris.settings.hooksWanted = true
        boris.hooks.showForSnapshot(status: .installed)
        boris.hooks.showForSnapshot(since: Date().addingTimeInterval(-3600))
        boris.apply(WorkEngine.Output(at: Date(), model: WorkModel(), world: WorldSnapshot(takenAt: Date(), sessions: [busy]), runs: [], events: []))
        #expect(boris.connectionStatus.hooksSilent)
        #expect(boris.connectionStatus.problems == [.hooksSilent])
        #expect(ConnectionNotices.shown(boris.connectionStatus.problems, page: .spend) == [.hooksSilent])
        boris.apply(WorkEngine.Output(at: Date(), model: WorkModel(), world: WorldSnapshot(takenAt: Date()), runs: [], events: []))
        #expect(!boris.connectionStatus.hooksSilent)
    }

    @Test("Записи Boris показываются как добавленное, а ничего при этом не меняется")
    func entries() throws {
        let home = ClaudeHome()
        let boris = connected(home)
        let before = try #require(home.settingsBytes)
        let connect = ConnectFlow()
        connect.showEntries(boris, in: .settings)
        guard case .entries(let lines) = connect.stage else {
            Issue.record("записи не показаны: \(connect.stage)")
            return
        }
        #expect(lines.contains { $0.hasPrefix("+") && $0.contains(ours) })
        #expect(lines.allSatisfy { $0.hasPrefix("+") })
        #expect(home.settingsBytes == before)
    }
}

@MainActor
@Suite("Сообщения о папке и формате", .serialized)
struct ClaudeFolderTests {
    @Test("Папки нет: Boris говорит об этом, называет, где искал, и даёт выбрать другую")
    func folderMissing() async throws {
        let gone = ClaudeHome(exists: false)
        let boris = model(gone)
        boris.start()
        #expect(await waitUntil { boris.loaded })
        #expect(!boris.world.claudeFolderFound)
        let status = boris.connectionStatus
        #expect(status.problems.contains(.claudeFolderMissing))
        #expect(status.isBroken)
        #expect(FolderMissing.explanation(boris).contains(gone.url.lastPathComponent))

        let report = try #require(await boris.diagnosticsReport())
        #expect(report.contains("Claude folder found: false"))

        let found = ClaudeHome()
        boris.chooseClaudeFolder(found.url)
        #expect(await waitUntil { boris.world.claudeFolderFound })
        #expect(!boris.connectionStatus.problems.contains(.claudeFolderMissing))
        await boris.stop()
    }

    @Test("На страницах текущей работы папка названа посередине, а на остальных это плашка", arguments: [
        (AppPage.now, false), (.projects, false), (.spend, true), (.requests, true), (.activity, true), (.losses, true), (.walrus, true),
    ])
    func folderBanner(page: AppPage, banner: Bool) {
        #expect(ConnectionNotices.shown([.claudeFolderMissing], page: page).isEmpty != banner)
    }

    @Test("Нечитаемые файлы: одна плашка про формат, а диагностика это называет и не несёт содержимого")
    func unreadableFiles() async throws {
        let home = ClaudeHome()
        home.write("sessions/123.json", "{not json")
        home.addSession("s1")
        let boris = model(home)
        boris.start()
        #expect(await waitUntil { boris.world.formatIssues.contains(.unreadableSessions) })
        let status = boris.connectionStatus
        #expect(status.problems.contains(.formatChanged))
        #expect(status.problems.contains(.filesUnreadable))
        #expect(ConnectionNotices.shown(status.problems, page: .now) == [.formatChanged])
        let report = try #require(await boris.diagnosticsReport())
        #expect(report.contains("unreadable session files"))
        #expect(!report.contains("secret"))
        #expect(!report.contains(home.url.lastPathComponent))
        await boris.stop()
    }

    @Test("Новый формат журнала: Boris говорит, что формат изменился, и диагностика называет событие, не более")
    func changedFormat() async throws {
        let home = ClaudeHome()
        home.write("projects/-x-secret-project/s1/subagents/workflows/wf_1/journal.jsonl", #"{"type":"launched"}"# + "\n" + #"{"type":"some_new_event","note":"secret words"}"# + "\n")
        let boris = model(home)
        boris.start()
        #expect(await waitUntil { !boris.world.formatIssues.isEmpty })
        let status = boris.connectionStatus
        #expect(status.problems == [.formatChanged])
        #expect(ConnectionNotices.shown(status.problems, page: .spend) == [.formatChanged])
        let report = try #require(await boris.diagnosticsReport())
        #expect(report.contains("some_new_event"))
        #expect(!report.contains("secret"))
        await boris.stop()
    }
}
