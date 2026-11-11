import AppKit
import BorisData
import Foundation
import SwiftUI
import Testing
@testable import Boris
@testable import BorisCore

/// Invented, so that no real text is anywhere near this. Each one is unlikely enough that finding it can mean only a leak.
private enum Secret {
    static let prompt = "SECRETprompt-zebra-orchid"
    static let command = "SECRETcommand-curl-mallow"
    static let result = "SECRETresult-tundra-plum"
    static let plan = "SECRETplan-quartz-river"
    static let answer = "SECRETanswer-maple-frost"
    static let reason = "SECRETreason-ember-willow"
    static let content = "SECRETcontent-falcon-moss"
    static let projectName = "SECRETproject-lantern"
    static let projectPath = "/Users/nobody/\(projectName)"
    static let filePath = "\(projectPath)/SECRETfile-gravel.swift"
    static let token = "4242424:SECRETtokenAAxx-yy_zz"
    static let chat = "@SECRETchat_cobalt"
    static let question = "SECRETquestion-saffron"
    static let tool = "mcp__SECRETserver-ivory__run"
    static let plainToolName = "SECRETToolName"
    static let sessionTail = "SECRET-tail-of-session"
    /// A real id starts with hex digits, and only those may be seen.
    static let session = "3f9a11c2\(sessionTail)"
    static let formatName = "SECRETformat-event"
    static let runId = "SECRETrun-id"
    static let word = "SECRET"

    static let all = [prompt, command, result, plan, answer, reason, content, projectName, filePath, token, chat, question, plainToolName, sessionTail, formatName, runId, word, "/Users/nobody", "ivory"]
}

private final class FakeTransport: TelegramTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var statuses: [Int]

    init(_ statuses: Int...) { self.statuses = statuses }

    func send(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        (lock.withLock { statuses.isEmpty ? 200 : statuses.removeFirst() }, Data())
    }
}

private final class FakeKeychain: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    var refuses = false

    func read() -> String? { lock.withLock { value } }
    func write(_ value: String) -> Bool {
        lock.withLock {
            if refuses { return false }
            self.value = value
            return true
        }
    }
    func delete() { lock.withLock { value = nil } }
}

/// Stands in for the speakers: a check must never make a sound.
@MainActor
private final class FakeSpeakers: SoundOutput {
    var works = true
    private(set) var played: [WalrusSound] = []

    func play(_ sound: WalrusSound, volume: Double) -> Bool {
        played.append(sound)
        return works
    }
}

private final class ThreadCapture: LogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var heard: [LogRecord] = []
    private let thread = pthread_self()

    init() { AppLog.add(self) }

    func stop() { AppLog.remove(self) }

    func write(_ record: LogRecord) {
        guard pthread_equal(thread, pthread_self()) != 0 else { return }
        lock.withLock { heard.append(record) }
    }

    func flush() {}

    var records: [LogRecord] { lock.withLock { heard } }
    var messages: [LogMessage] { records.map(\.message) }
}

private final class TempDir: @unchecked Sendable {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("boris-log-\(UUID().uuidString)")

    init() {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }
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

@MainActor
private func memoryModel(claudeFolder: String = "") -> AppModel {
    let settings = AppSettings(defaults: nil)
    settings.claudeFolder = claudeFolder
    return AppModel(settings: settings, store: nil, live: false)
}

@MainActor
@Suite("Журнал: полный прогон", .serialized)
struct AppLogRunTests {
    /// A Claude folder with a session whose log is full of text that must not get out.
    private func makeClaudeFolder(in root: URL) throws -> URL {
        let claude = root.appendingPathComponent("\(Secret.projectName)/.claude")
        let project = claude.appendingPathComponent("projects/-Users-nobody-\(Secret.projectName)")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: claude.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        let lines = [
            #"{"type":"user","timestamp":"2026-11-05T12:00:00.000Z","cwd":"\#(Secret.projectPath)","entrypoint":"cli","message":{"role":"user","content":"\#(Secret.prompt)"}}"#,
            #"{"type":"assistant","timestamp":"2026-11-05T12:00:05.000Z","cwd":"\#(Secret.projectPath)","entrypoint":"cli","message":{"id":"m1","model":"opus","stop_reason":"end_turn","content":[{"type":"text","text":"\#(Secret.result)"}],"usage":{"input_tokens":10,"output_tokens":1}}}"#,
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: project.appendingPathComponent("\(Secret.session).jsonl"), atomically: true, encoding: .utf8)
        return claude
    }

    /// Every part of the app that writes a line, with invented secrets in every field a real run would have them.
    private func runEverything(model: AppModel, keychain: FakeKeychain) async throws {
        let settings = model.settings
        let hooks = model.hooks
        // Each answer comes after the pause a new card gets, or it would not count.
        var moment = Date()
        func later() -> Date {
            moment = moment.addingTimeInterval(5)
            return moment
        }

        try hooks.connect(asker: .connectSheet)

        // Requests: asked, answered in each way, expired, gone.
        let command = PendingPermission(session: Secret.session, tool: "Bash", command: Secret.command, content: .command(Secret.command, unsandboxed: false), project: Secret.projectName, cwd: Secret.projectPath)
        let edit = PendingPermission(session: Secret.session, tool: "Edit", content: .file(path: Secret.filePath, lines: [RequestDiffLine(added: true, text: Secret.content)], whole: false, everyOccurrence: false), project: Secret.projectName, cwd: Secret.projectPath)
        let plan = PendingPermission(session: Secret.session, tool: "ExitPlanMode", content: .plan(Secret.plan), project: Secret.projectName)
        let question = PendingPermission(session: Secret.session, tool: "AskUserQuestion", content: .questions([RequestQuestion(text: Secret.question, options: [.init(label: Secret.answer)])]), project: Secret.projectName)
        let foreign = PendingPermission(session: Secret.session, tool: Secret.tool, content: .other(Secret.content), project: Secret.projectName)
        let oddTool = PendingPermission(session: Secret.session, tool: Secret.plainToolName, content: .other(Secret.content), project: Secret.projectName)
        for request in [command, edit, plan, question, foreign, oddTool] { hooks.add(request) }
        hooks.answer(command.id, .allow, via: .mini, now: later())
        hooks.answer(edit.id, .deny(reason: Secret.reason), via: .notch, now: later())
        hooks.answer(plan.id, .deny(reason: Secret.reason), via: .window, now: later())
        hooks.answer(question.id, .answers([Secret.question: Secret.answer]), via: .hotKey, now: later())
        // Refused: right after the card appeared, and after it was already answered.
        hooks.answer(foreign.id, .allow, via: .window)
        hooks.answer(command.id, .allow, via: .window, now: later())
        hooks.answer(oddTool.id, .allow, via: .window, now: later())

        // What the engine reports: format problems with names from the logs, and events about a project.
        let event = BorisEvent(id: "e1", kind: .failed, at: Date(), runId: Secret.runId, sessionId: Secret.session, project: Secret.projectName)
        let finished = BorisEvent(id: "e2", kind: .completed, at: Date(), sessionId: Secret.session, project: Secret.projectName, toolName: Secret.tool)
        let world = WorldSnapshot(takenAt: Date(), claudeFolderFound: true, formatIssues: [.unknownJournalEvent(Secret.formatName), .unreadableFinal(runId: Secret.runId)])
        model.apply(WorkEngine.Output(at: Date(), model: WorkModel(), world: world, events: [event, finished]))
        model.notifications.quietEnded(missed: [.failed: 2], requestsWaiting: 1)

        // Quiet, and sound through a fake.
        model.startQuiet(for: 3600)
        model.stopQuiet()
        model.startQuiet(for: QuietMode.indefinitely)
        model.stopQuiet()
        let speakers = FakeSpeakers()
        let voice = Voice(output: speakers)
        voice.play(.alarm)
        speakers.works = false
        voice.play(.done)

        // Telegram with an invented token and recipient, working and failing.
        let telegram = TelegramChannel(transport: FakeTransport(200, 200, 401, 200), secret: keychain) { _ in }
        #expect(await telegram.connect(token: Secret.token, chat: "-100200300", test: NotificationWords.telegramTest) == nil)
        await telegram.send(NotificationWords.telegram(event), chat: Secret.chat)
        await telegram.send(NotificationWords.telegram(finished), chat: Secret.chat)
        _ = await telegram.test(NotificationWords.telegramTest, chat: Secret.chat)
        _ = await telegram.connect(token: "not a token \(Secret.token)", chat: Secret.chat, test: NotificationWords.telegramTest)
        keychain.refuses = true
        _ = await telegram.connect(token: Secret.token, chat: "-100200300", test: NotificationWords.telegramTest)
        keychain.refuses = false
        await telegram.disconnect()

        // Settings, secret ones among them.
        settings.notifications.telegramChat = Secret.chat
        settings.notifications.volume = 0.25
        settings.notifications.voiceOn = false
        settings.notifications.channels[.failure] = ChannelChoice(mac: false, sound: false, telegram: false)
        settings.surfaces = SurfaceSwitches(icon: true, notch: false, mini: true)
        settings.surfaceScreen = .screen(id: Secret.projectName, name: Secret.projectName)
        settings.wardrobe.userBirthday = MonthDay(month: 3, day: 14)
        settings.wardrobe.pack = Secret.projectName
        settings.theme = .dark
        settings.keepAwake = true
        settings.allowKey = .denyStandard
        settings.permissionWaitSeconds = 300
        SettingsLog.flush()

        // Limits in a debug build, the panel, the Mac kept awake, and taking the hooks out again.
        model.usageRefresher.refreshNow()
        var panel = PanelLogTrack()
        panel.note(isOpen: true, hovering: false)
        panel.note(isOpen: false, hovering: false)
        let guardian = PowerGuard()
        guardian.update(shouldHold: false)

        // Speed, with the secret session, project and agent open, and every timing let through. All in one stretch, so no other test runs meanwhile.
        SpeedLog.isWatching = true
        SpeedLog.thresholds = .everything
        model.openSession(Secret.session, agent: Secret.sessionTail)
        SpeedLog.appeared(.session)
        SpeedLog.mainThread(.waking)
        usleep(60_000)
        SpeedLog.mainThread(.sleeping)
        model.openProject(Secret.projectPath)
        SpeedLog.appeared(.project)
        SpeedLog.mainThread(.sleeping)
        model.chooseAgent(Secret.sessionTail)
        SpeedLog.mainThread(.sleeping)
        _ = model.allSessions
        SpeedLog.thresholds = .standard
        SpeedLog.isWatching = false

        try hooks.disconnect(asker: .disconnectInConnections)
    }

    @Test("Ни в файле, ни в скопированном, ни в диагностике нет ни одного секрета")
    func noSecretAnywhere() async throws {
        let root = TempDir()
        let claude = try makeClaudeFolder(in: root.url)
        let store = AppLogStore(file: root.url.appendingPathComponent("logs/app.log"))
        AppLog.add(store)
        defer { AppLog.remove(store) }
        let model = memoryModel(claudeFolder: claude.path)
        model.start()
        #expect(await waitUntil { model.loaded })

        let keychain = FakeKeychain()
        try await runEverything(model: model, keychain: keychain)
        await model.stop()
        store.flush()

        // 1. The file itself, as bytes.
        let raw = try String(decoding: Data(contentsOf: store.file), as: UTF8.self)
        for secret in Secret.all { #expect(!raw.contains(secret), "в файле: \(secret)") }

        // 2. It is not empty for the wrong reason: each part really wrote its line.
        let written = Set(store.records().map(\.message))
        let expected: [LogMessage] = [
            .firstRead, .formatIssue, .hooksConnected, .hooksDisconnected, .claudeSettingsWritten, .requestAsked, .requestEnded, .requestAnswerRefused,
            .bannerSent, .telegramSent, .telegramFailed, .telegramConnected, .telegramConnectFailed, .keychainFailed, .telegramDisconnected,
            .soundPlayed, .soundFailed, .settingChanged, .settingChangedHidden, .limitsRefreshSkipped, .panelOpened, .panelClosed, .quietStarted, .quietUntilOff, .quietEnded,
            .pageShown, .actionSlow, .loadSlow, .mainThreadStalled,
        ]
        for message in expected { #expect(written.contains(message), "нет строки: \(message.rawValue)") }
        #expect(raw.contains("t:Bash"))
        #expect(raw.contains("t:mcp"))
        #expect(raw.contains("t:other"))
        #expect(raw.contains("i:3f9a11c2"))
        #expect(raw.contains("c:notifications.telegramChat") || raw.contains("notifications.telegramChat"))

        // 3. What the viewer shows and copies.
        let feed = LogFeed()
        feed.period = .everything
        let viewer = UUID()
        feed.open(from: store, owner: viewer)
        #expect(await waitUntil { feed.loaded && !feed.rows.isEmpty })
        let copied = await feed.copyText()
        for secret in Secret.all { #expect(!copied.contains(secret), "в скопированном: \(secret)") }
        #expect(copied.contains("Boris log"))
        feed.close(owner: viewer)

        // 4. The tail in the diagnostics report.
        let diagnostics = Diagnostics.adding(log: store.newest(Diagnostics.logLines), to: "Boris")
        for secret in Secret.all { #expect(!diagnostics.contains(secret), "в диагностике: \(secret)") }
        #expect(diagnostics.contains("Log:"))

        // 5. No line is a line of text from anywhere else: each one comes back whole from the strict reader.
        let lines = raw.split(separator: "\n").filter { $0.split(separator: "\t").dropFirst().first != "+" }
        #expect(LogFile.parse(Data(raw.utf8)).count == lines.count)
    }
}

@MainActor
@Suite("Журнал: кнопки и хуки", .serialized)
struct AppLogHookTests {
    /// A settings file in a temporary folder, the only place a debug build may touch.
    private func model(in root: TempDir) -> AppModel {
        memoryModel(claudeFolder: root.url.path)
    }

    @Test("Видно, какая кнопка подключила хуки")
    func connecting() throws {
        let root = TempDir()
        let app = model(in: root)
        let capture = ThreadCapture()
        defer { capture.stop() }
        try app.hooks.connect(asker: .connectSheet)
        #expect(capture.messages.contains(.hooksConnected))
        #expect(capture.records.first { $0.message == .hooksConnected }?.values == [.word(.connectSheet)])
        #expect(capture.messages.contains(.claudeSettingsWritten))
    }

    @Test("Починка и отключение называют свою кнопку")
    func repairAndDisconnect() throws {
        let root = TempDir()
        let app = model(in: root)
        let flow = ConnectFlow()
        let capture = ThreadCapture()
        defer { capture.stop() }
        flow.confirm(app)
        #expect(capture.records.first { $0.message == .hooksConnected }?.values == [.word(.connectSheet)])

        // The person wants them, and they are gone: what the status check would say.
        app.hooks.showForSnapshot(status: .notInstalled)
        flow.repair(app, asker: .repairInMainWindow)
        #expect(capture.records.first { $0.message == .hooksRepaired }?.values == [.word(.repairInMainWindow)])

        try app.hooks.disconnect(asker: .disconnectInConnections)
        #expect(capture.records.first { $0.message == .hooksDisconnected }?.values == [.word(.disconnectInConnections)])
    }

    @Test("Отказ отладочной сборки и сбой записи видны как разные вещи")
    func refusals() {
        // Not under the temporary folder, so a debug build refuses before reading anything.
        let refused = memoryModel(claudeFolder: "/nonexistent/invented-folder")
        let capture = ThreadCapture()
        defer { capture.stop() }
        #expect(throws: (any Error).self) { try refused.hooks.connect(asker: .repairInConnections) }
        #expect(capture.records.last?.message == .hooksChangeRefused)
        #expect(capture.records.last?.values == [.word(.repairInConnections)])
        #expect(!capture.messages.contains(.claudeSettingsWritten))

        let root = TempDir()
        try? "{ broken".write(to: root.url.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        let broken = model(in: root)
        #expect(throws: (any Error).self) { try broken.hooks.connect(asker: .connectSheet) }
        #expect(capture.messages.contains(.claudeSettingsUnreadable))
        #expect(capture.records.last?.message == .hooksChangeFailed)
    }

    @Test("Вызов без указания кнопки так и называется, а не молчит")
    func unknownCaller() throws {
        let root = TempDir()
        let app = model(in: root)
        let capture = ThreadCapture()
        defer { capture.stop() }
        try app.hooks.connect()
        #expect(capture.records.first { $0.message == .hooksConnected }?.values == [.word(.unknownCaller)])
    }

    @Test("Запрос: от вопроса до ответа, с инструментом, местом и сессией")
    func requests() {
        let app = memoryModel()
        let capture = ThreadCapture()
        defer { capture.stop() }
        let request = PendingPermission(session: "3f9a11c2-0000", tool: "Bash", content: .command("x", unsandboxed: false))
        app.hooks.add(request)
        app.hooks.answer(request.id, .allow, via: .mini, now: Date().addingTimeInterval(5))
        let ended = capture.records.first { $0.message == .requestEnded }
        #expect(capture.messages.contains(.requestAsked))
        #expect(ended?.values.first == .tool("Bash"))
        #expect(ended?.values.contains(.word(.allowed)) == true)
        #expect(ended?.values.contains(.word(.miniWindow)) == true)
        #expect(ended?.values.last == .session("3f9a11c2"))
    }

    @Test("Истёкшая просьба и закрытая в Claude описаны по-разному")
    func requestsThatEndElsewhere() {
        let app = memoryModel()
        let capture = ThreadCapture()
        defer { capture.stop() }
        let request = PendingPermission(session: "aaaa", tool: "Read", content: .other("x"))
        app.hooks.add(request)
        app.hooks.stopServer()
        #expect(capture.messages.contains(.requestTimedOut))
        #expect(!capture.messages.contains(.hookServerStopped))
    }

    @Test("Каждый звук записан по имени, в том числе тот, что не прозвучал")
    func sounds() {
        let capture = ThreadCapture()
        defer { capture.stop() }
        let speakers = FakeSpeakers()
        let voice = Voice(output: speakers)
        voice.play(.bellow)
        speakers.works = false
        voice.play(.poke)
        #expect(speakers.played == [.bellow, .poke])
        #expect(capture.records.map(\.message) == [.soundPlayed, .soundFailed])
        #expect(capture.records.map(\.values) == [[.choice(WalrusSound.bellow)], [.choice(WalrusSound.poke)]])
    }

    @Test("Уведомление записано по виду события, без своего текста")
    func banners() {
        let app = memoryModel()
        let capture = ThreadCapture()
        defer { capture.stop() }
        let event = BorisEvent(id: "e1", kind: .failed, at: Date(), sessionId: "s", project: "invented-project")
        app.notifications.scanned([(event, Reaction(banner: true, sound: false, mood: .none))], quiet: false, now: Date())
        #expect(capture.records.first { $0.message == .bannerSent }?.values == [.choice(EventKind.failed)])
        #expect(!capture.records.flatMap(\.values).map(\.stored).joined().contains("invented-project"))
    }

    @Test("Смена настроек видна по имени и значению, а папка Claude только как факт")
    func settings() {
        let capture = ThreadCapture()
        defer { capture.stop() }
        let settings = AppSettings(defaults: nil)
        settings.keepAwake = true
        settings.claudeFolder = "/Users/nobody/invented-secret-folder"
        settings.hotKey = .allowStandard
        SettingsLog.flush()
        let lines = capture.records
        #expect(lines.contains { $0.message == .settingChanged && $0.values == [.settingForTest("keepAwake"), .flag(true)] })
        #expect(lines.contains { $0.message == .settingChangedHidden && $0.values == [.settingForTest("claudeFolder")] })
        #expect(lines.contains { $0.message == .settingChanged && $0.values.first == .settingForTest("hotKey") })
        #expect(!lines.flatMap(\.values).map(\.stored).joined().contains("invented-secret"))
    }

    @Test("Без установленного журнала никто ничего не пишет на диск")
    func silentByDefault() {
        // What every test, snapshot and tool relies on. The app adds the store itself, and only when it starts for real.
        let inSources = AppLogRunSource.text(of: "App/DevSnapshot.swift")
        #expect(!inSources.contains("AppLog.add"))
        #expect(AppLogRunSource.text(of: "App/AppDelegate.swift").contains("AppLog.add(AppLogStore())"))
    }
}

private enum AppLogRunSource {
    static func text(of path: String) -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return (try? String(contentsOf: root.appendingPathComponent("Sources/Boris/\(path)"), encoding: .utf8)) ?? ""
    }
}

private extension LogValue {
    /// A setting's name, as it reads back from the file.
    static func settingForTest(_ name: String) -> LogValue {
        LogValue.choice(Named(rawValue: name))
    }
}

/// Lets a test spell a setting's name without a way to do that in the app itself.
private struct Named: RawRepresentable, CaseIterable {
    var rawValue: String
    static let allCases: [Named] = []
}

/// The system says no to keeping the Mac awake, every time. No real power setting is touched.
@MainActor
private final class RefusingBlocker: SleepBlocker {
    var refuses = true
    func hold(reason: String) -> UInt32? { refuses ? nil : 1 }
    func release(_ id: UInt32) {}
}

@MainActor
@Suite("Журнал: не на каждом проходе")
struct AppLogRepeatTests {
    @Test("Отказ системы держать Mac бодрым записан один раз, хотя попытка повторяется с каждым проходом")
    func refusalOnce() {
        let capture = ThreadCapture()
        defer { capture.stop() }
        let blocker = RefusingBlocker()
        let guardian = PowerGuard(blocker: blocker)
        for _ in 0..<5 { guardian.update(shouldHold: true) }
        #expect(capture.messages == [.keepAwakeFailed])
        // Work stopped and came back: that is news again.
        guardian.update(shouldHold: false)
        guardian.update(shouldHold: true)
        blocker.refuses = false
        guardian.update(shouldHold: true)
        #expect(capture.messages == [.keepAwakeFailed, .keepAwakeFailed, .keepAwakeOn])
    }
}

@MainActor
@Suite("Журнал: окно просмотра", .serialized)
struct LogViewerTests {
    private func rows(_ count: Int, _ text: (Int) -> LogRecord) -> [LogRow] {
        var renderer = LogRenderer()
        return (0..<count).map { renderer.row(text($0)) }
    }

    private func simple(_ index: Int) -> LogRecord {
        LogRecord(at: Date().addingTimeInterval(Double(index - 100_000)), message: .firstRead, values: [.seconds(1), .number(index)])
    }

    /// A controller in a real window far off screen. It is never made key and takes no keys.
    @MainActor
    private final class OffScreen {
        let controller = LogTableController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)

        init() {
            window.isReleasedWhenClosed = false
            controller.scroll.frame = window.contentLayoutRect
            controller.scroll.autoresizingMask = [.width, .height]
            window.contentView?.addSubview(controller.scroll)
            window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
            window.orderBack(nil)
        }

        func settle() {
            window.contentView?.layoutSubtreeIfNeeded()
            controller.table.layoutSubtreeIfNeeded()
        }

        var visibleLastRow: Int {
            let visible = controller.table.rows(in: controller.scroll.contentView.bounds)
            return visible.location + visible.length - 1
        }

        /// Draws what is in view into a picture, which is real work even in a window nobody sees.
        @discardableResult
        func draw() -> NSBitmapImageRep? {
            guard let view = window.contentView, let picture = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
            view.cacheDisplay(in: view.bounds, to: picture)
            return picture
        }

        func close() {
            window.orderOut(nil)
        }
    }

    @Test("Новая строка снизу, и список идёт за ней")
    func follows() {
        let screen = OffScreen()
        defer { screen.close() }
        var shown = rows(500, simple)
        screen.controller.update(rows: shown, generation: 1, jumps: 0)
        screen.settle()
        #expect(screen.visibleLastRow == 499)
        shown += rows(3) { simple($0 + 500) }
        screen.controller.update(rows: shown, generation: 1, jumps: 0)
        screen.settle()
        #expect(screen.controller.table.numberOfRows == 503)
        #expect(screen.visibleLastRow == 502)
        #expect(screen.controller.following)
    }

    @Test("Кто прокрутил вверх, того не тащит вниз, а кнопка возвращает")
    func staysWhenScrolledUp() async {
        let screen = OffScreen()
        defer { screen.close() }
        var shown = rows(500, simple)
        screen.controller.update(rows: shown, generation: 1, jumps: 0)
        screen.settle()
        var reported: [Bool] = []
        screen.controller.onFollowing = { reported.append($0) }

        screen.controller.scroll.contentView.scroll(to: NSPoint(x: 0, y: 200))
        screen.controller.scroll.reflectScrolledClipView(screen.controller.scroll.contentView)
        #expect(await waitUntil { !screen.controller.following })
        let before = screen.controller.scroll.contentView.bounds.origin.y

        shown += rows(3) { simple($0 + 500) }
        screen.controller.update(rows: shown, generation: 1, jumps: 0)
        screen.settle()
        #expect(screen.controller.scroll.contentView.bounds.origin.y == before)
        #expect(await waitUntil { reported == [false] })

        screen.controller.update(rows: shown, generation: 1, jumps: 1)
        screen.settle()
        #expect(screen.controller.following)
        #expect(screen.visibleLastRow == 502)
    }

    @Test("Счётчик повторов обновляет последнюю строку на месте")
    func recount() {
        let screen = OffScreen()
        defer { screen.close() }
        var renderer = LogRenderer()
        var record = simple(1)
        var shown = rows(50, simple) + [renderer.row(record)]
        screen.controller.update(rows: shown, generation: 1, jumps: 0)
        screen.settle()
        record.count = 7
        record.lastAt = record.at.addingTimeInterval(30)
        shown[shown.count - 1] = renderer.row(record)
        screen.controller.update(rows: shown, generation: 1, jumps: 0)
        screen.settle()
        let cell = screen.controller.table.view(atColumn: 0, row: 50, makeIfNecessary: true) as? LogCell
        #expect(cell?.field.stringValue.contains("×7") == true)
        #expect(screen.controller.table.numberOfRows == 51)
    }

    @Test("Высота строки точно вмещает текст на любой ширине и на обоих языках")
    func heights() {
        let layout = LogRowLayout()
        let cell = LogCell()
        // The real lines of the English catalogue, the longest words in it, and Russian text of the same kind: a monospaced font has one width for all of them.
        var samples: [LogRow] = []
        var renderer = LogRenderer()
        for message in LogMessage.allCases {
            samples.append(renderer.row(LogRecord(at: Date(), message: message, values: Array(repeating: .word(.expiredThenAnswered), count: 5))))
        }
        let russian = "Запрос AskUserQuestion: отвечен в Claude после конца ожидания, на странице «Запросы», через 10 мин, сессия ffffffff"
        samples.append(LogRow(at: Date(), lastAt: Date(), level: .warning, isDay: false, day: 0, time: "12:00:00", levelWord: "внимание", area: "уведомления", text: russian))
        samples.append(LogRow(at: Date(), lastAt: Date(), level: .error, isDay: false, day: 0, time: "12:00:00", levelWord: "ошибка", area: "хуки", text: String(repeating: "Оченьдлинноеслово", count: 12)))

        for width in [300.0, 446, 526, 700] as [CGFloat] {
            let perLine = layout.charactersPerLine(inRowOfWidth: width)
            for row in samples {
                cell.frame = NSRect(x: 0, y: 0, width: width, height: 400)
                cell.layout()
                cell.show(row, layout: layout)
                let fieldWidth = width - 2 * LogRowLayout.sidePadding
                let needed = cell.field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: fieldWidth, height: 10_000)).height ?? 0
                let given = layout.height(of: row, perLine: perLine) - 2 * LogRowLayout.rowPadding
                #expect(needed <= given + 1, "\(row.text) на ширине \(width): нужно \(needed), дано \(given)")
                // One spare line at most, where a line may break after a hyphen that the count does not know about.
                #expect(given <= needed + LogRowLayout.lineHeight + 1, "\(row.text) на ширине \(width): нужно \(needed), дано \(given)")
            }
        }
    }

    @Test("Цвета следуют теме окна")
    func colours() {
        let text = NSColor(Palette.text1)
        func resolved(_ name: NSAppearance.Name) -> NSColor? {
            var colour: NSColor?
            NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
                colour = text.usingColorSpace(.sRGB)
            }
            return colour
        }
        #expect(resolved(.aqua) != nil)
        #expect(resolved(.aqua) != resolved(.darkAqua))
    }

    @Test("Журнал виден в настройках")
    func section() {
        #expect(SettingsSection.allCases.contains(.log))
        #expect(!SettingsSection.log.title.isEmpty)
    }

    @Test("Лента читает файл, слышит новые строки и сворачивает повторы")
    func feedHearsStore() async {
        let root = TempDir()
        var limits = AppLogStore.Limits()
        limits.repeatFlush = 0.05
        let store = AppLogStore(file: root.url.appendingPathComponent("app.log"), limits: limits)
        store.write(LogRecord(message: .appStarted, values: [.version("1.0"), .word(.debugBuild)]))
        store.write(LogRecord(message: .hooksLost))
        store.flush()

        let feed = LogFeed()
        let viewer = UUID()
        feed.open(from: store, owner: viewer)
        #expect(await waitUntil { feed.loaded })
        #expect(feed.rows.count == 2)

        store.write(LogRecord(message: .macWoke))
        #expect(await waitUntil { feed.rows.count == 3 })

        store.write(LogRecord(message: .macWoke))
        store.write(LogRecord(message: .macWoke))
        #expect(await waitUntil { feed.rows.last?.text.contains("×3") == true })
        #expect(feed.rows.count == 3)

        feed.onlyProblems = true
        #expect(await waitUntil { feed.rows.count == 1 })
        #expect(feed.rows.first?.level == .warning)

        // A line that the filter hides does not change what is shown, nor does its count land on another line.
        store.write(LogRecord(message: .macSleeping))
        store.write(LogRecord(message: .macSleeping))
        store.flush()
        try? await Task.sleep(for: .milliseconds(300))
        #expect(feed.rows.count == 1)
        #expect(feed.rows.first?.text.contains("×") == false)

        feed.onlyProblems = false
        #expect(await waitUntil { feed.rows.count == 4 })

        feed.close(owner: viewer)
        #expect(feed.rows.isEmpty)
        store.write(LogRecord(message: .appQuit))
        store.flush()
        try? await Task.sleep(for: .milliseconds(200))
        #expect(feed.rows.isEmpty)
    }

    @Test("Лента, закрытая раньше, чем файл прочитан, не оживает")
    func closedEarly() async {
        let root = TempDir()
        let store = AppLogStore(file: root.url.appendingPathComponent("app.log"))
        store.write(LogRecord(message: .appQuit))
        let feed = LogFeed()
        let viewer = UUID()
        feed.open(from: store, owner: viewer)
        feed.close(owner: viewer)
        try? await Task.sleep(for: .milliseconds(300))
        #expect(feed.rows.isEmpty)
        #expect(!feed.loaded)
    }

    @Test("Смена языка: старый вид прощается после того, как новый поздоровался, а лента остаётся открытой")
    func newViewBeforeOldGoes() async {
        let root = TempDir()
        let store = AppLogStore(file: root.url.appendingPathComponent("app.log"))
        store.write(LogRecord(message: .appQuit))
        let feed = LogFeed()
        let old = UUID()
        let new = UUID()
        feed.open(from: store, owner: old)
        #expect(await waitUntil { feed.loaded })
        let readBefore = feed.generation
        feed.open(from: store, owner: new)
        feed.close(owner: old)
        #expect(await waitUntil { feed.loaded && feed.generation > readBefore && !feed.rows.isEmpty })
        store.write(LogRecord(message: .macWoke))
        #expect(await waitUntil { feed.rows.count == 2 })
        feed.close(owner: new)
    }

    @Test("Сломанный файл: приложение живёт, а окно об этом говорит")
    func brokenFile() async throws {
        let root = TempDir()
        let file = root.url.appendingPathComponent("app.log")
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        let store = AppLogStore(file: file)
        store.write(LogRecord(message: .appQuit))
        let feed = LogFeed()
        let viewer = UUID()
        feed.open(from: store, owner: viewer)
        #expect(await waitUntil { feed.loaded })
        #expect(feed.cannotWrite)
        #expect(feed.rows.isEmpty)
        feed.close(owner: viewer)
    }

    @Test("Файл заработал снова: предупреждение уходит само, пока раздел открыт")
    func savingComesBack() async throws {
        let root = TempDir()
        let file = root.url.appendingPathComponent("app.log")
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        var limits = AppLogStore.Limits()
        limits.reopenAfter = 0
        let store = AppLogStore(file: file, limits: limits)
        store.write(LogRecord(message: .appQuit))
        let feed = LogFeed()
        let viewer = UUID()
        feed.open(from: store, owner: viewer)
        #expect(await waitUntil { feed.loaded && feed.cannotWrite })
        try FileManager.default.removeItem(at: file)
        store.write(LogRecord(message: .macWoke))
        #expect(await waitUntil { !feed.cannotWrite && feed.rows.count == 1 })
        feed.close(owner: viewer)
    }

    /// What a full file holds: about sixty thousand lines, some of them long enough to wrap in a narrow window.
    private func fullFile() -> [LogRow] {
        let now = Date()
        return rows(60_000) { index in
            let at = now.addingTimeInterval(Double(index - 60_000))
            switch index % 5 {
            case 0: return LogRecord(at: at, message: .requestEnded, values: [.tool("AskUserQuestion"), .word(.expiredThenAnswered), .word(.requestsPage), .seconds(599), .session("3f9a11c2")])
            case 1: return LogRecord(at: at, message: .soundPlayed, values: [.choice(WalrusSound.done)])
            case 2: return LogRecord(at: at, message: .telegramFailed, values: [.choice(EventKind.failed), .word(.noConnection)])
            case 3: return LogRecord(at: at, message: .hooksChangeRefused, values: [.word(.repairInConnections)])
            default: return LogRecord(at: at, message: .fileWriteFailed, values: [.word(.tokenCache), .failure(CocoaError(.fileWriteOutOfSpace))])
            }
        }
    }

    private func percentile(_ times: [Duration], _ part: Double) -> Duration {
        times.sorted()[min(times.count - 1, Int(Double(times.count) * part))]
    }

    @Test("Шестьдесят тысяч строк: открытие, прокрутка, новая строка и смена ширины не заметны")
    func fullFileStaysSmooth() {
        let screen = OffScreen()
        defer { screen.close() }
        var shown = fullFile()
        let clock = ContinuousClock()
        let controller = screen.controller

        let opening = clock.measure {
            controller.update(rows: shown, generation: 1, jumps: 0)
            screen.settle()
            screen.draw()
        }
        #expect(screen.visibleLastRow == shown.count - 1)

        // From the bottom to the top of the whole list, the table laid out and drawn at each step, as a long flick would ask.
        let clip = controller.scroll.contentView
        let height = controller.table.bounds.height
        var frames: [Duration] = []
        for step in 1...600 {
            let target = max(0, height - clip.bounds.height) * (1 - Double(step) / 600)
            frames.append(clock.measure {
                clip.scroll(to: NSPoint(x: 0, y: target))
                controller.scroll.reflectScrolledClipView(clip)
                screen.settle()
                screen.draw()
            })
        }
        #expect(clip.bounds.origin.y == 0)
        #expect(controller.table.rows(in: clip.bounds).location == 0)
        let topCell = controller.table.view(atColumn: 0, row: 0, makeIfNecessary: false) as? LogCell
        #expect(topCell?.field.stringValue.contains("AskUserQuestion") == true)
        #expect(controller.table.frame.height >= 60_000 * LogRowLayout.lineHeight)

        // Back at the bottom a new line comes in.
        controller.update(rows: shown, generation: 1, jumps: 1)
        screen.settle()
        shown += rows(1) { _ in LogRecord(message: .macWoke) }
        let adding = clock.measure {
            controller.update(rows: shown, generation: 1, jumps: 1)
            screen.settle()
            screen.draw()
        }
        #expect(screen.visibleLastRow == shown.count - 1)

        // A wider window changes how every line wraps.
        let widening = clock.measure {
            screen.window.setContentSize(NSSize(width: 760, height: 300))
            screen.settle()
            screen.draw()
        }
        #expect(screen.visibleLastRow == shown.count - 1)

        // A debug build on a busy machine. In an optimized build these came to 8 ms, 2 ms a frame, 2 ms and 37 ms.
        let median = percentile(frames, 0.5)
        #expect(median < .milliseconds(16), "кадр: \(median), худший \(percentile(frames, 1))")
        #expect(opening < .milliseconds(500), "открытие: \(opening)")
        #expect(adding < .milliseconds(100), "новая строка: \(adding)")
        #expect(widening < .seconds(2), "смена ширины: \(widening)")
    }

    @Test("Файл на 5 МБ читается, не держа главный поток")
    func fullFileDoesNotHoldTheMainThread() async throws {
        let root = TempDir()
        let file = root.url.appendingPathComponent("app.log")
        let now = Date()
        var text = ""
        // Long lines, so fewer of them fit than in the usual mix.
        for index in 0..<50_000 {
            let at = now.addingTimeInterval(Double(index - 50_000))
            text += LogFile.line(LogRecord(at: at, message: .requestEnded, values: [.tool("Bash"), .word(.allowed), .word(.miniWindow), .seconds(4), .session("3f9a11c2")]))
        }
        #expect(text.utf8.count > 4 * 1024 * 1024)
        #expect(text.utf8.count <= 5 * 1024 * 1024)
        try Data(text.utf8).write(to: file)

        let store = AppLogStore(file: file)
        let feed = LogFeed()
        feed.period = .everything
        let viewer = UUID()
        let clock = ContinuousClock()
        let began = clock.now
        var last = began
        var longestGap = Duration.zero
        feed.open(from: store, owner: viewer)
        while !feed.loaded, clock.now - began < .seconds(120) {
            try? await Task.sleep(for: .milliseconds(5))
            longestGap = max(longestGap, clock.now - last)
            last = clock.now
        }
        let total = clock.now - began
        #expect(feed.rows.filter { !$0.isDay }.count == 50_000)
        // However long the read takes on a busy machine, the main thread keeps turning through it.
        #expect(longestGap < max(.milliseconds(250), total / 3), "пауза \(longestGap) из \(total)")

        let reading = clock.now
        feed.onlyProblems = true
        #expect(await waitUntil { feed.rows.isEmpty })
        #expect(clock.now - reading < .seconds(20))
        feed.close(owner: viewer)
    }

    @Test("Старые строки уходят из последнего часа, но не из-под читающего")
    func expiring() async {
        let root = TempDir()
        let store = AppLogStore(file: root.url.appendingPathComponent("app.log"))
        store.write(LogRecord(at: Date().addingTimeInterval(-1800), message: .appQuit))
        store.flush()
        let feed = LogFeed()
        let viewer = UUID()
        feed.open(from: store, owner: viewer)
        #expect(await waitUntil { feed.loaded })
        #expect(feed.rows.filter { !$0.isDay }.count == 1)

        feed.following = false
        feed.dropExpired(now: Date().addingTimeInterval(3600))
        try? await Task.sleep(for: .milliseconds(200))
        #expect(feed.rows.filter { !$0.isDay }.count == 1)

        feed.following = true
        feed.dropExpired(now: Date().addingTimeInterval(1800 - 60))
        try? await Task.sleep(for: .milliseconds(200))
        #expect(feed.rows.filter { !$0.isDay }.count == 1)

        feed.dropExpired(now: Date().addingTimeInterval(3600))
        #expect(await waitUntil { feed.rows.isEmpty })
        feed.close(owner: viewer)
    }
}
