import BorisCore
import Darwin
import Foundation
import Testing
@testable import BorisData

/// A made-up Claude Desktop folder, laid out as version 4.29 lays it out.
private struct CoworkHome {
    let home = TempFolder()
    let id: String
    var main: ClaudePaths { ClaudePaths(root: home.url.appendingPathComponent(".claude")) }
    var others: @Sendable () -> [ClaudePaths] {
        let (main, url) = (main, home.url)
        return { ClaudeFolders.others(besides: main, environment: [:], home: url) }
    }

    init(id: String = "local_task") {
        self.id = id
        home.write(".claude/sessions/.keep", "")
    }

    private var holder: String { "Library/Application Support/Claude/local-agent-mode-sessions/org/acc" }

    @discardableResult
    func transcript(_ lines: [String], session: String = "s1", id: String? = nil) -> URL {
        home.write("\(holder)/\(id ?? self.id)/.claude/projects/-sessions-made-up-name/\(session).jsonl", lines.joined(separator: "\n") + "\n")
    }

    func describe(_ json: String) {
        home.write("\(holder)/\(id).json", json)
    }

    func scanner() -> RunScanner {
        RunScanner(paths: main, others: others)
    }

    /// Lets a scanner find what was written after it was made.
    func scan(_ scanner: RunScanner, at date: Date = Date()) async -> WorldSnapshot {
        await scanner.markDiscovery()
        return await scanner.scan(now: date)
    }
}

private func user(_ text: String = "Сделай") -> String {
    #"{"type":"user","cwd":"/sessions/made-up-name","entrypoint":"local-agent","message":{"role":"user","content":"\#(text)"}}"#
}

private func call(_ tool: String, id: String = "t1") -> String {
    #"{"type":"assistant","cwd":"/sessions/made-up-name","entrypoint":"local-agent","message":{"id":"m-\#(id)","model":"claude-sonnet-4-6","stop_reason":"tool_use","usage":{"input_tokens":3,"output_tokens":2},"content":[{"type":"tool_use","id":"\#(id)","name":"\#(tool)","input":{}}]}}"#
}

private func result(of id: String = "t1") -> String {
    #"{"type":"user","cwd":"/sessions/made-up-name","entrypoint":"local-agent","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"\#(id)","content":"ok"}]}}"#
}

private let turnEnd = #"{"type":"assistant","cwd":"/sessions/made-up-name","entrypoint":"local-agent","message":{"id":"m-end","model":"claude-sonnet-4-6","stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1},"content":[{"type":"text","text":"готово"}]}}"#

@Suite("Cowork: сессии из папки Claude Desktop")
struct CoworkSessionTests {
    @Test("Обе раскладки папок находятся как отдельные корни, процессы их не читаются")
    func bothLayouts() {
        let place = CoworkHome()
        place.home.write("Library/Application Support/Claude/local-agent-mode-sessions/org/acc/local_plain/.claude/projects/p/a.jsonl", "")
        place.home.write("Library/Application Support/Claude/local-agent-mode-sessions/org/acc/agent/local_ditto_x/.claude/projects/p/b.jsonl", "")
        let found = place.others()
        #expect(found.filter { !$0.processesAreHere }.count == 2)
        #expect(found.allSatisfy { !$0.processesAreHere })
    }

    @Test("Идущая сессия видна со средой Cowork, названием задачи и моделью, но не как проект")
    func live() async throws {
        let place = CoworkHome()
        place.describe(#"{"title":"Отчёт за квартал","model":"claude-sonnet-4-6","emailAddress":"someone@example.com","systemPrompt":"секрет","initialMessage":"текст"}"#)
        let scanner = place.scanner()
        place.transcript([user(), call("Read")])
        let world = await place.scan(scanner)
        let info = try #require(world.sessions.first { $0.sessionId == "s1" })
        #expect(info.environment == .cowork)
        #expect(info.isUnlisted)
        #expect(info.status == "busy")
        #expect(info.title == "Отчёт за квартал")
        #expect(info.projectName == nil)

        let session = try #require(WorkBuilder.build(world: world, runs: []).sessions.first)
        #expect(session.environment == .cowork)
        #expect(session.displayName == "Отчёт за квартал")
        #expect(session.projectPath == nil)
        #expect(session.state == .running)
    }

    @Test("Модель берётся из лога, а пока в логе её нет, из файла задачи")
    func model() async throws {
        let place = CoworkHome()
        place.describe(#"{"model":"claude-from-the-file"}"#)
        let scanner = place.scanner()
        await scanner.setFocus(runs: [], menuOpen: true)
        place.transcript([user()])
        let early = await place.scan(scanner)
        #expect(early.sessions.first?.model == "claude-from-the-file")
        place.transcript([user(), call("Read")])
        let later = await place.scan(scanner)
        #expect(later.sessions.first?.model == "claude-sonnet-4-6")
    }

    @Test("Без названия показывается выбранная папка", arguments: [
        (#"{"userSelectedFolders":["/Users/someone/Documents/Отчёты"]}"#, "Отчёты"),
        (#"{"title":"","userSelectedFolders":["/Users/someone/Documents/Отчёты"]}"#, "Отчёты"),
        (#"{"title":"Задача","userSelectedFolders":["/Users/someone/Documents/Отчёты"]}"#, "Задача"),
    ])
    func folderName(json: String, expected: String) async throws {
        let place = CoworkHome()
        place.describe(json)
        let scanner = place.scanner()
        place.transcript([user()])
        let world = await place.scan(scanner)
        #expect(world.sessions.first?.title == expected)
    }

    @Test("Файл задачи пропал или испорчен: сессия всё равно видна, а имя не выдумано из папки машины", arguments: [nil, "не json", #"{"title":12,"userSelectedFolders":"x","model":[]}"#, #"{"userSelectedFolders":[]}"#])
    func brokenFile(json: String?) async throws {
        let place = CoworkHome()
        if let json { place.describe(json) }
        let scanner = place.scanner()
        place.transcript([user()])
        let world = await place.scan(scanner)
        let session = try #require(WorkBuilder.build(world: world, runs: []).sessions.first)
        #expect(session.environment == .cowork)
        #expect(session.displayName == "Cowork task")
        #expect(!session.nameIsFolder)
    }

    @Test("Лог без поля среды в папке Cowork всё равно считается Cowork")
    func noEntrypoint() async throws {
        let place = CoworkHome()
        let scanner = place.scanner()
        place.transcript([#"{"type":"user","cwd":"/sessions/made-up-name","message":{"content":"x"}}"#])
        let world = await place.scan(scanner)
        #expect(world.sessions.first?.environment == .cowork)
    }

    @Test("Нечитаемый лог: сессия видна и явно не знает модель и токены")
    func unreadableLog() async throws {
        let place = CoworkHome()
        let scanner = place.scanner()
        place.transcript(["это не json", "{обрыв"])
        let world = await place.scan(scanner)
        let session = try #require(WorkBuilder.build(world: world, runs: []).sessions.first)
        #expect(session.environment == .cowork)
        #expect(session.root.model == nil)
        #expect(session.root.tokens == nil)
    }

    @Test("Новая задача замечается сразу, без минуты до общего поиска")
    func newTaskNoticed() async throws {
        let place = CoworkHome()
        place.transcript([user()], session: "first", id: "local_old")
        let scanner = place.scanner()
        await scanner.markDiscovery()
        _ = await scanner.scan(now: Date())
        _ = await scanner.scan(now: Date())
        place.transcript([user()], session: "second", id: "local_new")
        let world = await scanner.scan(now: Date())
        #expect(world.sessions.contains { $0.sessionId == "second" })
    }

    @Test("Запущенный при идущей задаче Boris видит её сразу, даже если она молчит", arguments: [
        (40.0 * 60, "waiting"), (3.0 * 60, "busy"),
    ])
    func alreadyRunning(age: TimeInterval, status: String) async throws {
        let place = CoworkHome()
        let file = place.transcript([user(), call(status == "waiting" ? "AskUserQuestion" : "Read")])
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: file.path)
        let world = await place.scan(place.scanner())
        #expect(world.sessions.first?.status == status)
    }

    @Test("Давно замолчавшая при запуске задача идущей не считается", arguments: [
        (2.0 * 3600, "AskUserQuestion"), (20.0 * 60, "Read"),
    ])
    func longQuietAtLaunch(age: TimeInterval, tool: String) async throws {
        let place = CoworkHome()
        let file = place.transcript([user(), call(tool)])
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: file.path)
        let world = await place.scan(place.scanner())
        #expect(world.sessions.isEmpty)
    }

    @Test("Токены и действия считаются из папки Cowork, без проекта")
    func tokensAndActions() async throws {
        let place = CoworkHome()
        let file = place.transcript([user(), call("Read"), result(), turnEnd])
        let index = TokenIndex(cacheFile: nil)
        await index.update(roots: [place.main] + place.others())
        let records = await index.records()
        #expect(records.reduce(0) { $0 + $1.usage.total } == 7)
        #expect(Set(records.map(\.entrypoint)) == ["local-agent"])
        var feed = ActivityReader()
        feed.read(file)
        #expect(feed.log.items.contains { if case .step(let step) = $0 { step.tool == "Read" } else { false } })
    }

    @Test("В прошлых сессиях Cowork есть среда, название и модель")
    func past() async throws {
        let place = CoworkHome()
        place.describe(#"{"title":"Отчёт за квартал"}"#)
        place.transcript([user(), call("Read"), result(), turnEnd])
        let history = SessionHistory(paths: place.main, others: place.others)
        let session = try #require(await history.sessions().first)
        #expect(session.environment == .cowork)
        #expect(session.title == "Отчёт за квартал")
        #expect(session.root.model == "claude-sonnet-4-6")
        #expect(session.state == .finished)
    }

    @Test("Ход агента, закончившийся сообщением человеку, не считается оборванным")
    func spokeLast() async throws {
        let place = CoworkHome()
        place.transcript([user(), call("SendUserMessage"), result()])
        let history = SessionHistory(paths: place.main, others: place.others)
        #expect(try #require(await history.sessions().first).state == .finished)

        let cut = CoworkHome()
        cut.transcript([user(), call("Read"), result()])
        let other = SessionHistory(paths: cut.main, others: cut.others)
        #expect(try #require(await other.sessions().first).state == .interrupted)
    }

    @Test("Живой агент после сообщения человеку ещё работает, а через 10 секунд тишины закончил ход")
    func spokeLastLive() async throws {
        let place = CoworkHome()
        let scanner = place.scanner()
        place.transcript([user(), call("SendUserMessage"), result()])
        let now = Date()
        #expect(await place.scan(scanner, at: now).sessions.first?.status == "busy")
        #expect(await place.scan(scanner, at: now.addingTimeInterval(11)).sessions.first?.status == "idle")
    }

    @Test("Ключи и учётные данные рядом с задачей не открываются, хотя всё остальное читается")
    func keysStayClosed() async throws {
        let place = CoworkHome()
        let task = "Library/Application Support/Claude/local-agent-mode-sessions/org/acc/\(place.id)"
        let keys = [
            place.home.write("\(task)/.audit-key", "made-up key"),
            place.home.write("\(task)/.claude/.credentials.json", #"{"made":"up"}"#),
            place.home.write("\(task)/.claude/.claude.json", #"{"cachedUsageUtilization":{}}"#),
            place.home.write("\(task)/.claude/mcp-needs-auth-cache.json", "{}"),
        ]
        place.describe(#"{"title":"Отчёт"}"#)
        let transcript = place.transcript([user(), call("Read"), result(), turnEnd])
        let long = timespec(tv_sec: 1_000_000_000, tv_nsec: 0)
        func atime(_ file: URL) -> Int {
            var info = stat()
            stat(file.path, &info)
            return info.st_atimespec.tv_sec
        }
        for file in keys + [transcript] {
            var info = stat()
            stat(file.path, &info)
            var times = [long, info.st_mtimespec]
            utimensat(AT_FDCWD, file.path, &times, 0)
        }

        let roots = [place.main] + place.others()
        _ = await place.scan(place.scanner())
        _ = await TokenIndex(cacheFile: nil).update(roots: roots)
        _ = await SessionHistory(paths: place.main, others: place.others).sessions()
        let losses = LossIndex(cacheFile: nil)
        await losses.update(roots: roots)

        // The check is not blind: the transcript was read, so its time moved, if this disk keeps such times at all.
        guard atime(transcript) != long.tv_sec else { return }
        for file in keys {
            #expect(atime(file) == long.tv_sec, "\(file.lastPathComponent) открыт")
        }
    }

    @Test("Читаются только нужные поля файла задачи")
    func onlyNeededFields() throws {
        let folder = TempFolder()
        let file = folder.write("local_x.json", #"{"title":"Т","model":"m","userSelectedFolders":["/a/b"],"emailAddress":"someone@example.com","accountName":"Кто-то","systemPrompt":"секрет","initialMessage":"текст"}"#)
        #expect(CoworkSessionFile.read(file) == CoworkSessionFile(title: "Т", folders: ["/a/b"], model: "m"))
    }

    @Test("Файл задачи есть только у лога из папки Cowork")
    func fileOnlyForCowork() {
        let plain = URL(fileURLWithPath: "/h/.claude/projects/p/s.jsonl")
        #expect(CoworkSessionFile.url(forTranscript: plain) == nil)
        let inside = URL(fileURLWithPath: "/h/local-agent-mode-sessions/o/a/agent/local_x/.claude/projects/p/s.jsonl")
        #expect(CoworkSessionFile.url(forTranscript: inside)?.path == "/h/local-agent-mode-sessions/o/a/agent/local_x.json")
    }
}

@Suite("Cowork: ожидание ответа")
struct CoworkWaitingTests {
    private func waiting(_ lines: [String], after seconds: TimeInterval = 0) async throws -> SessionInfo {
        let place = CoworkHome()
        let scanner = place.scanner()
        place.transcript(lines)
        let world = await place.scan(scanner, at: Date().addingTimeInterval(seconds))
        return try #require(world.sessions.first)
    }

    @Test("Вопрос и план это ожидание сразу")
    func questions() async throws {
        let question = try await waiting([user(), call("AskUserQuestion")])
        #expect(question.status == "waiting")
        #expect(WaitingReason(question.waitingFor) == .input)
        let plan = try await waiting([user(), call("ExitPlanMode")])
        #expect(plan.status == "waiting")
        #expect(WaitingReason(plan.waitingFor) == .permission(tool: "ExitPlanMode"))
    }

    @Test("То, что Cowork выполняет без спроса, ожиданием не считается, сколько бы ни шло", arguments: ["Bash", "Read", "Edit", "Write", "Task", "WebSearch", "mcp__workspace__bash", "mcp__computer-use__screenshot", "SendUserMessage"])
    func neverAsks(tool: String) async throws {
        let session = try await waiting([user(), call(tool)], after: 14 * 60)
        #expect(session.status == "busy")
        #expect(session.waitingFor == nil)
    }

    @Test("Вызов инструмента, который может спросить, становится ожиданием после 20 секунд тишины")
    func mayAsk() async throws {
        let place = CoworkHome()
        let scanner = place.scanner()
        place.transcript([user(), call("mcp__tracker__create")])
        let now = Date()
        #expect(await place.scan(scanner, at: now).sessions.first?.status == "busy")
        let later = await place.scan(scanner, at: now.addingTimeInterval(21))
        #expect(later.sessions.first?.status == "waiting")
        #expect(WaitingReason(later.sessions.first?.waitingFor) == .permission(tool: "mcp__tracker__create"))
    }

    @Test("После ответа ожидание кончается")
    func answered() async throws {
        let place = CoworkHome()
        let scanner = place.scanner()
        place.transcript([user(), call("AskUserQuestion")])
        #expect(await place.scan(scanner).sessions.first?.status == "waiting")
        place.transcript([user(), call("AskUserQuestion"), result()])
        #expect(await place.scan(scanner).sessions.first?.status == "busy")
    }

    @Test("Ждущая сессия держится час, работающая 15 минут")
    func holding() async throws {
        let place = CoworkHome()
        let scanner = place.scanner()
        place.transcript([user(), call("AskUserQuestion")])
        let now = Date()
        #expect(await place.scan(scanner, at: now).sessions.count == 1)
        #expect(await place.scan(scanner, at: now.addingTimeInterval(59 * 60)).sessions.first?.status == "waiting")
        #expect(await place.scan(scanner, at: now.addingTimeInterval(61 * 60)).sessions.isEmpty)
    }

    @Test("Ожидание видно в запросах: ответить можно только в Claude Desktop")
    func reachesRequests() async throws {
        let session = try await waiting([user(), call("AskUserQuestion")])
        let world = WorldSnapshot(takenAt: Date(), sessions: [session])
        let work = WorkBuilder.build(world: world, runs: [])
        #expect(work.waitingSessions.count == 1)
        #expect(work.sessions.first?.waitingFor == .input)
        var queue = RequestQueue()
        queue.note(work: work, now: Date())
        let rows = queue.rows(now: Date())
        guard case .waiting(let row)? = rows.first else {
            Issue.record("no row: \(rows.count)")
            return
        }
        #expect(row.environment == .cowork)
        #expect(SessionJump.plan(environment: row.environment, sessionId: row.id, cwd: row.cwd, folderExists: false, owner: nil) == .openApp(bundleId: "com.anthropic.claudefordesktop"))
    }

    @Test("Уведомление об ожидании говорит только «Cowork»: ни папки машины, ни названия задачи")
    func notification() throws {
        var detector = EventDetector(memory: DetectorMemory(), config: DetectorConfig())
        var session = SessionInfo(sessionId: "s1", pid: 0, cwd: "/sessions/made-up-name", entrypoint: "local-agent", status: "waiting", waitingFor: "input needed")
        session.title = "Секретное название задачи"
        let start = Date()
        _ = detector.detect(runs: [], sessions: [session], usage: nil, now: start, failures: [], endedSessions: [])
        let events = detector.detect(runs: [], sessions: [session], usage: nil, now: start.addingTimeInterval(60), failures: [], endedSessions: [])
        let event = try #require(events.first { $0.kind == .waiting })
        #expect(event.project == nil)
        let banner = NotificationWords.banner(event)
        #expect(banner.title.hasPrefix("Cowork"))
        #expect(!"\(banner.title) \(banner.body)".contains("made-up-name"))
        #expect(!"\(banner.title) \(banner.body)".contains("Секретное"))
    }
}
