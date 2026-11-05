import Foundation
import BorisCore
import Testing
@testable import BorisData

@Suite("claude-data-access")
struct ReaderTests {
    @Test("Обрыв строки ждёт следующего чтения") func partialLine() {
        let folder = TempFolder()
        let file = folder.write("journal.jsonl", "{\"type\":\"started\",\"key\":\"a\"}\n{\"type\":\"res")
        var reader = JournalReader()
        reader.read(file)
        #expect(reader.tally.agents.map(\.state) == [.running])
        folder.append("journal.jsonl", "ult\",\"key\":\"a\"}\n")
        reader.read(file)
        #expect(reader.tally.agents.map(\.state) == [.done])
    }

    @Test("Журнал стал короче: читается заново") func truncatedJournal() {
        let folder = TempFolder()
        let file = folder.write("journal.jsonl", "{\"type\":\"started\",\"key\":\"a\"}\n{\"type\":\"started\",\"key\":\"b\"}\n")
        var reader = JournalReader()
        reader.read(file)
        #expect(reader.tally.agents.count == 2)
        folder.write("journal.jsonl", "{\"type\":\"started\",\"key\":\"c\"}\n")
        reader.read(file)
        #expect(reader.tally.agents.map(\.key) == ["c"])
    }

    @Test("Дописывание не перечитывает старое") func incremental() {
        let folder = TempFolder()
        let file = folder.write("journal.jsonl", "{\"type\":\"started\",\"key\":\"a\"}\n")
        var reader = JournalReader()
        reader.read(file)
        let first = reader.offset
        reader.read(file)
        #expect(reader.offset == first)
        folder.append("journal.jsonl", "{\"type\":\"started\",\"key\":\"a\"}\n")
        reader.read(file)
        #expect(reader.tally.agents[0].attempts == 2)
    }

    @Test("Неизвестное событие не мешает известным") func unknownEvent() {
        let folder = TempFolder()
        let file = folder.write("journal.jsonl", "{\"type\":\"paused\"}\n{\"type\":\"started\",\"key\":\"a\"}\n")
        var reader = JournalReader()
        reader.read(file)
        #expect(reader.tally.unknownEvents == ["paused"])
        #expect(reader.tally.agents.count == 1)
    }

    @Test("Неполный итог не читается") func partialFinal() {
        let folder = TempFolder()
        let file = folder.write("x.json", "{\"status\":\"compl")
        #expect(FinalReader.read(file) == nil)
    }

    @Test("Итог: агенты, фазы, первая строка ошибки") func finalParsing() throws {
        let json = """
        {"status":"failed","workflowName":"n","agentCount":1,"durationMs":5,"totalTokens":9,"taskId":"t",
         "error":"Error: boom\\n   at x","startTime":1000,
         "workflowProgress":[{"type":"workflow_phase","index":1,"title":"B"},{"type":"workflow_phase","index":0,"title":"A"},
         {"type":"workflow_agent","agentId":"a","label":"l","phaseTitle":"A","state":"error","tokens":3,"error":"stalled — no progress for 600000ms"}]}
        """
        let report = try #require(FinalReader.parse(Data(json.utf8)))
        #expect(report.status == "failed")
        #expect(report.errorFirstLine == "Error: boom")
        #expect(report.phaseTitles == ["A", "B"])
        #expect(report.entries.count == 1)
        #expect(report.entries[0].record.state == .failed)
        #expect(report.entries[0].record.failure?.failureClass == .stall)
    }

    @Test("Нет поля entrypoint или name: сессия показана") func missingFields() throws {
        let session = try #require(SessionReader.parse(Data(#"{"sessionId":"s","pid":12}"#.utf8), fileName: "12.json"))
        #expect(session.entrypoint == nil)
        #expect(session.name == nil)
    }

    @Test("PID берётся из имени файла, если его нет внутри") func pidFromName() throws {
        let session = try #require(SessionReader.parse(Data(#"{"sessionId":"s"}"#.utf8), fileName: "77.json"))
        #expect(session.pid == 77)
    }

    @Test("Файлы ключей не читаются") func keyFilesIgnored() {
        let folder = TempFolder()
        folder.write("sessions/12.json", #"{"sessionId":"s","pid":12}"#)
        folder.write("sessions/12.abc.key", "not json at all")
        let result = SessionReader.read(ClaudePaths(root: folder.url))
        #expect(result.sessions.count == 1)
        #expect(result.unreadable == 0)
    }

    @Test("Папка не найдена") func missingFolder() async {
        let paths = ClaudePaths(root: URL(fileURLWithPath: "/nonexistent/boris"))
        #expect(!paths.isValid)
        let world = await RunScanner(paths: paths).scan(now: Date())
        #expect(!world.claudeFolderFound)
    }

    @Test("Настройка важнее окружения") func pathPriority() {
        #expect(ClaudePaths.resolve(custom: "/a", environment: ["CLAUDE_CONFIG_DIR": "/b"]).root.path == "/a")
        #expect(ClaudePaths.resolve(custom: nil, environment: ["CLAUDE_CONFIG_DIR": "/b"]).root.path == "/b")
        #expect(ClaudePaths.resolve(custom: nil, environment: [:]).root.lastPathComponent == ".claude")
    }

    @Test("Поиск запуска при сложном пути", arguments: ["my_app", "my.project", "with space", "проект"])
    func oddProjectNames(name: String) async {
        let folder = TempFolder()
        let dir = "projects/-Users-x-\(name)/s1/subagents/workflows/wf_abc/journal.jsonl"
        folder.write(dir, "{\"type\":\"started\",\"key\":\"a\"}\n")
        folder.write("sessions/.keep", "")
        let world = await RunScanner(paths: ClaudePaths(root: folder.url)).scan(now: Date())
        #expect(world.runs.map(\.runId) == ["wf_abc"])
    }

    @Test("План фаз из скрипта") func scriptPhases() {
        let script = "export const meta = { name: 'x', phases: [{ title: 'Search', detail: 'a ] b' }, { title: \"Verify\" }] }\nconst schema = { phases: [{ title: 'NOPE' }] }"
        #expect(ScriptReader.phaseTitles(in: script) == ["Search", "Verify"])
        #expect(ScriptReader.phaseTitles(in: "export const meta = { name: 'x' }").isEmpty)
    }

    @Test("Описание из meta") func scriptDescription() {
        let script = #"export const meta = { name: 'x', description: 'Check the \'form\' works', phases: [{ title: 'A', detail: 'd' }] }"#
        #expect(ScriptReader.description(in: script) == "Check the 'form' works")
        #expect(ScriptReader.description(in: "export const meta = { name: 'x', phases: [{ title: 'A', description: 'no' }] }") == nil)
        #expect(ScriptReader.description(in: "const x = 1") == nil)
    }

    @Test("Имя запуска из файла скрипта") func scriptName() {
        let folder = TempFolder()
        folder.write("scripts/find-claude-app-wf_abc.js", "export const meta = { phases: [{ title: 'A' }] }")
        let info = ScriptReader.read(scripts: folder.url.appendingPathComponent("scripts"), runId: "wf_abc")
        #expect(info?.name == "find-claude-app")
        #expect(info?.phases == ["A"])
    }

    @Test("Лимиты: окна, пустое, кодовое имя, учётная запись отброшена") func usage() throws {
        let json = """
        {"oauthAccount":{"emailAddress":"secret@x"},"cachedUsageUtilization":{"fetchedAtMs":1000,"accountUuid":"secret",
        "utilization":{"five_hour":null,"seven_day":{"utilization":16,"resets_at":"2026-11-10T12:59:59.679217+00:00"},
        "iguana_necktie":{"utilization":0.05,"limit_dollars":250,"used_dollars":0.13,"resets_at":"2026-11-05T07:59:00+00:00"},
        "extra_usage":{"is_enabled":false,"monthly_limit":0,"used_credits":0},
        "wattle":{"utilization":3},"tangelo":null}}}
        """
        let usage = try #require(UsageReader.parse(Data(json.utf8)))
        #expect(usage.windows.map(\.id) == ["seven_day"])
        #expect(usage.windows[0].kind == .week)
        #expect(usage.windows[0].percent == 16)
        #expect(usage.windows[0].resetsAt != nil)
        #expect(!String(describing: usage).contains("secret"))
    }

    private func usageJSON(_ body: String) -> Data {
        Data(#"{"cachedUsageUtilization":{"fetchedAtMs":1000,"utilization":{\#(body)}}}"#.utf8)
    }

    @Test("Доп. расходы только когда включены") func extraSpend() throws {
        let on = #""extra_usage":{"is_enabled":true,"monthly_limit":10000,"used_credits":2500,"decimal_places":2}"#
        let window = try #require(UsageReader.parse(usageJSON(on))?.windows.first)
        #expect(window.kind == .extraSpend)
        #expect(window.percent == 25)
        #expect(window.usedDollars == 25)
        #expect(window.limitDollars == 100)
        let off = #""extra_usage":{"is_enabled":false,"monthly_limit":10000,"used_credits":2500,"decimal_places":2}"#
        #expect(try #require(UsageReader.parse(usageJSON(off))).windows.isEmpty)
    }

    @Test("Окна по моделям из limits") func modelWindows() throws {
        let body = #""seven_day":{"utilization":25},"limits":[{"kind":"weekly_all","percent":25,"is_active":true,"scope":null},{"kind":"weekly_scoped","percent":40,"is_active":true,"resets_at":"2026-11-10T13:00:00+00:00","scope":{"model":{"display_name":"Fable"}}},{"kind":"weekly_scoped","percent":0,"is_active":false,"scope":{"model":{"display_name":"Opus"}}}]"#
        let usage = try #require(UsageReader.parse(usageJSON(body)))
        #expect(usage.windows.map(\.kind) == [.week, .weekModel("Fable")])
        #expect(usage.windows[1].percent == 40)
        #expect(usage.windows[1].resetsAt != nil)
    }

    @Test("Кеша лимитов нет") func noUsage() {
        #expect(UsageReader.parse(Data("{}".utf8)) == nil)
        #expect(UsageReader.parse(Data("not json".utf8)) == nil)
    }

    @Test("Конец транскрипта: ошибка API и настоящий расход") func tail() {
        let folder = TempFolder()
        let lines = [
            #"{"type":"user","message":{"content":"PROMPT"}}"#,
            #"{"type":"assistant","message":{"id":"m1","model":"haiku","usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":100,"cache_creation_input_tokens":20}}}"#,
            #"{"type":"assistant","isApiErrorMessage":true,"error":"rate_limit","message":{"model":"<synthetic>","usage":{"input_tokens":0},"content":[{"type":"text","text":"You've hit your session limit · resets 2pm"}]}}"#,
        ]
        let file = folder.write("a.jsonl", lines.joined(separator: "\n") + "\n")
        let tail = TranscriptReader.tail(file)
        #expect(tail.last?.isApiError == true)
        #expect(tail.last?.errorCode == "rate_limit")
        #expect(tail.usage?.context == 130)
        #expect(tail.model == "haiku")
        #expect(TranscriptReader.firstPrompt(file) == "PROMPT")
    }

    @Test("Полный проход: дубли и инструменты") func summary() {
        let folder = TempFolder()
        let line = { (out: Int, tool: String) in
            #"{"type":"assistant","message":{"id":"m1","model":"opus","usage":{"input_tokens":1,"output_tokens":\#(out)},"content":[{"type":"tool_use","name":"\#(tool)"}]}}"#
        }
        let file = folder.write("a.jsonl", [line(1, "Read"), line(9, "Bash"), #"{"type":"user"}"#].joined(separator: "\n"))
        let summary = TranscriptReader.summary(file)
        #expect(summary.tokens == TokenUsage(input: 1, output: 9))
        #expect(summary.tools == ["Read": 1, "Bash": 1])
        #expect(summary.model == "opus")
    }

    @Test("Опрос файла на 27 МБ читает только конец") func hugeFileTail() {
        let folder = TempFolder()
        let file = folder.url.appendingPathComponent("big.jsonl")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = FileHandle(forWritingAtPath: file.path)
        let filler = Data(("{\"type\":\"user\",\"message\":{\"content\":\"" + String(repeating: "x", count: 1000) + "\"}}\n").utf8)
        for _ in 0..<27_000 { handle?.write(filler) }
        handle?.write(Data(#"{"type":"assistant","message":{"id":"m","model":"a","usage":{"input_tokens":7}}}"#.utf8))
        try? handle?.close()
        let memoryBefore = residentBytes()
        let began = ContinuousClock.now
        let tail = TranscriptReader.tail(file)
        let elapsed = ContinuousClock.now - began
        let growth = residentBytes() - memoryBefore
        #expect(tail.usage?.input == 7)
        #expect(elapsed < .milliseconds(200))
        #expect(growth < 2 * 1024 * 1024)
    }

    @Test("Диагностика без содержимого и путей") func diagnostics() {
        let folder = TempFolder()
        folder.write("sessions/1.json", #"{"sessionId":"s","pid":1,"cwd":"/secret/project"}"#)
        let session = SessionInfo(sessionId: "s", pid: 1, cwd: "/secret/project", version: "2.1.312")
        let world = WorldSnapshot(
            takenAt: Date(),
            sessions: [session],
            runs: [RunSnapshot(runId: "wf_1", sessionId: "s", cwd: "/secret/project", lastWrite: Date())],
            formatIssues: [.unknownJournalEvent("paused")]
        )
        let report = Diagnostics.report(world: world, paths: ClaudePaths(root: folder.url), appVersion: "1.0.0")
        #expect(report.contains("2.1.312"))
        #expect(report.contains("paused"))
        #expect(report.contains("cwd"))
        #expect(!report.contains("secret"))
        #expect(!report.contains(folder.url.path))
    }

    @Test("Смена формата попадает в снимок") func unknownEventReachesWorld() async {
        let folder = TempFolder()
        folder.write("sessions/.keep", "")
        folder.write("projects/p/s/subagents/workflows/wf_a/journal.jsonl", "{\"type\":\"mystery\"}\n{\"type\":\"started\",\"key\":\"k\"}\n")
        let world = await RunScanner(paths: ClaudePaths(root: folder.url)).scan(now: Date())
        #expect(world.formatIssues == [.unknownJournalEvent("mystery")])
        #expect(world.runs.first?.agents.count == 1)
    }

    @Test("Классификация путей FSEvents") func changeParser() {
        let changes = FileChangeParser.changes(in: [
            "/h/.claude/projects/p/s/subagents/workflows/wf_abc/",
            "/h/.claude/projects/p/s/subagents/workflows/wf_abc/agent-1.jsonl",
            "/h/.claude/sessions/",
            "/h/.claude/projects/p/s/workflows/",
            "/h/.claude/projects/p/",
        ])
        #expect(changes == [.run("wf_abc"), .sessions, .session("s"), .discovery, .project("/h/.claude/projects/p")])
    }

    @Test("Дерево запусков: только нужные файлы, ограничение окна") func windowFilter() async {
        let folder = TempFolder()
        let journal = folder.write("projects/p/s1/subagents/workflows/wf_old/journal.jsonl", "{\"type\":\"launched\"}\n")
        folder.write("projects/p/s1/workflows/wf_old.json", #"{"status":"completed"}"#)
        let old = Date(timeIntervalSinceNow: -48 * 3600)
        try? FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: journal.path)
        try? FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: folder.url.appendingPathComponent("projects/p/s1/workflows/wf_old.json").path)
        try? FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: journal.deletingLastPathComponent().path)
        folder.write("sessions/.keep", "")
        let world = await RunScanner(paths: ClaudePaths(root: folder.url)).scan(now: Date())
        #expect(world.runs.isEmpty)
    }

    @Test("Всплеск записей: не больше одного прохода за 2 секунды") func scanGate() {
        var gate = ScanGate()
        var runs: [TimeInterval] = []
        var planned: TimeInterval?
        // 500 changes per second for 10 seconds.
        for step in 0..<5000 {
            let clock = Double(step) / 500
            if let due = planned, clock >= due {
                gate.didRun(now: Date(timeIntervalSince1970: clock))
                runs.append(clock)
                planned = nil
            }
            switch gate.request(now: Date(timeIntervalSince1970: clock)) {
            case .runNow: runs.append(clock)
            case .runAfter(let delay): planned = clock + delay
            case .alreadyPending: break
            }
        }
        #expect(runs.count <= 6)
        #expect(runs.count >= 5)
        for (a, b) in zip(runs, runs.dropFirst()) {
            #expect(b - a >= 1.99)
        }
    }

    @Test("Файловая подписка сообщает о записи в запуск") func realWatcher() async throws {
        let folder = TempFolder()
        let run = "projects/p/s/subagents/workflows/wf_x/journal.jsonl"
        folder.write(run, "{}\n")
        let root = folder.url.resolvingSymlinksInPath()
        let received = Received()
        let watcher = FileWatcher { paths in
            received.add(FileChangeParser.changes(in: paths))
        }
        watcher.start(paths: [root.appendingPathComponent("projects")], latency: 0.2)
        try await Task.sleep(for: .milliseconds(400))
        folder.write("projects/p/s/subagents/workflows/wf_x/agent-1.jsonl", "{}\n")
        for _ in 0..<40 where !received.value.contains(.run("wf_x")) {
            try await Task.sleep(for: .milliseconds(100))
        }
        watcher.stop()
        #expect(received.value.contains(.run("wf_x")))
    }

    @Test("Имя и план запуска, начатого из файла") func launchFromFile() {
        let folder = TempFolder()
        let script = folder.write("elsewhere/x.js", "export const meta = { phases: [{ title: 'Check' }] }")
        let line = #"{"type":"user","toolUseResult":{"runId":"wf_a","workflowName":"my-flow","scriptPath":"\#(script.path)"}}"#
        let parent = folder.write("parent.jsonl", line + "\n")
        let info = TranscriptReader.launchInfo(in: parent, runId: "wf_a")
        #expect(info?.workflowName == "my-flow")
        #expect(ScriptReader.phases(at: URL(fileURLWithPath: info?.scriptPath ?? "")) == ["Check"])
        #expect(TranscriptReader.launchInfo(in: parent, runId: "wf_b") == nil)
    }

    @Test("Старый завершённый запуск живой сессии не показан") func oldRunOfLiveSession() async throws {
        let folder = TempFolder()
        let me = ProcessInfo.processInfo.processIdentifier
        folder.write("sessions/\(me).json", #"{"sessionId":"s1","pid":\#(me)}"#)
        let journal = folder.write("projects/p/s1/subagents/workflows/wf_old/journal.jsonl", "{\"type\":\"launched\"}\n")
        let finalFile = folder.write("projects/p/s1/workflows/wf_old.json", #"{"status":"completed"}"#)
        let old = Date(timeIntervalSinceNow: -48 * 3600)
        for path in [journal.path, finalFile.path, journal.deletingLastPathComponent().path] {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: path)
        }
        folder.write("projects/p/s1/subagents/workflows/wf_live/journal.jsonl", "{\"type\":\"started\",\"key\":\"a\"}\n")
        let world = await RunScanner(paths: ClaudePaths(root: folder.url)).scan(now: Date())
        #expect(world.sessions.count == 1)
        #expect(world.runs.map(\.runId) == ["wf_live"])
    }

    @Test("Живой процесс определяется ядром, занятый PID нет") func processInspector() {
        let me = ProcessInfo.processInfo.processIdentifier
        let start = ProcessInspector.startTime(pid: me)
        #expect(start != nil)
        #expect((start ?? .distantFuture) < Date())
        #expect(ProcessInspector.startTime(pid: 999_999) == nil)
        let reused = SessionInfo(sessionId: "s", pid: me, procStart: Date(timeIntervalSince1970: 1000))
        #expect(!SessionReader.isLive(reused))
        let genuine = SessionInfo(sessionId: "s", pid: me, procStart: start)
        #expect(SessionReader.isLive(genuine))
    }
}

private func residentBytes() -> Int {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
    }
    return result == KERN_SUCCESS ? Int(info.resident_size) : 0
}

private final class Received: @unchecked Sendable {
    private let lock = NSLock()
    private var changes: Set<FileChange> = []

    func add(_ new: Set<FileChange>) {
        lock.lock()
        changes.formUnion(new)
        lock.unlock()
    }

    var value: Set<FileChange> {
        lock.lock()
        defer { lock.unlock() }
        return changes
    }
}

@Suite("Чтение ленты")
struct ActivityReaderTests {
    private func toolUse(_ id: String, _ name: String, _ input: String) -> String {
        #"{"type":"assistant","timestamp":"2026-11-04T13:22:22.948Z","message":{"id":"m\#(id)","content":[{"type":"tool_use","id":"\#(id)","name":"\#(name)","input":\#(input)}]}}"#
    }

    private func toolResult(_ id: String, error: Bool = false) -> String {
        #"{"type":"user","timestamp":"2026-11-04T13:22:25.948Z","message":{"content":[{"type":"tool_result","tool_use_id":"\#(id)","is_error":\#(error),"content":[{"type":"text","text":"out"}]}]}}"#
    }

    private func steps(_ log: ActivityLog) -> [ActivityStep] {
        log.items.compactMap { if case .step(let step) = $0 { return step } else { return nil } }
    }

    @Test("Лента растёт вместе с файлом") func follows() {
        let folder = TempFolder()
        let file = folder.write("a.jsonl", #"{"type":"user","message":{"content":"PROMPT"}}"# + "\n" + toolUse("1", "Read", #"{"file_path":"/x/a.ts"}"#) + "\n")
        var reader = ActivityReader()
        let first = reader.read(file)
        #expect(first)
        #expect(steps(reader.log).map(\.state) == [.running])
        #expect(steps(reader.log)[0].input.target == "/x/a.ts")
        #expect(steps(reader.log)[0].startedAt != nil)
        folder.append("a.jsonl", toolResult("1") + "\n")
        let second = reader.read(file)
        #expect(second)
        #expect(steps(reader.log).map(\.state) == [.done])
        #expect(steps(reader.log)[0].output == "out")
        let third = reader.read(file)
        #expect(!third)
    }

    @Test("Недописанная строка ждёт") func partialLine() {
        let folder = TempFolder()
        let line = toolUse("1", "Bash", #"{"command":"ls","description":"List"}"#)
        let file = folder.write("a.jsonl", String(line.prefix(40)))
        var reader = ActivityReader()
        reader.read(file)
        #expect(reader.log.items.isEmpty)
        folder.append("a.jsonl", String(line.dropFirst(40)) + "\n")
        reader.read(file)
        #expect(steps(reader.log)[0].input.command == "ls")
        #expect(steps(reader.log)[0].input.note == "List")
    }

    @Test("Правка: тексты и счётчик") func edit() {
        let folder = TempFolder()
        let file = folder.write("a.jsonl", toolUse("1", "Edit", #"{"file_path":"/x/a.ts","old_string":"a\nb","new_string":"a\nc\nd"}"#) + "\n")
        var reader = ActivityReader()
        reader.read(file)
        #expect(steps(reader.log)[0].added == 2)
        #expect(steps(reader.log)[0].removed == 1)
    }

    @Test("Служебные записи не попадают в ленту") func otherRecords() {
        let folder = TempFolder()
        let file = folder.write("a.jsonl", #"{"type":"api-request-blob","message":{"content":[{"type":"tool_use","id":"x","name":"Read"}]}}"# + "\n" + #"{"type":"attachment"}"# + "\n")
        var reader = ActivityReader()
        reader.read(file)
        #expect(reader.log.items.isEmpty)
    }

    @Test("Файл на 80 МБ: только конец, быстро и без роста памяти") func hugeFile() {
        let folder = TempFolder()
        let file = folder.url.appendingPathComponent("big.jsonl")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = FileHandle(forWritingAtPath: file.path)
        let filler = Data(("{\"type\":\"user\",\"message\":{\"content\":\"" + String(repeating: "x", count: 4000) + "\"}}\n").utf8)
        for _ in 0..<20_000 { handle?.write(filler) }
        handle?.write(Data((toolUse("last", "Read", #"{"file_path":"/x/end.ts"}"#) + "\n").utf8))
        try? handle?.close()
        var reader = ActivityReader()
        let began = ContinuousClock.now
        reader.read(file)
        #expect(ContinuousClock.now - began < .seconds(1))
        #expect(reader.startedPartWay)
        #expect(steps(reader.log).map(\.id) == ["last"])
    }

    @Test("Текущий шаг из конца файла") func runningFromTail() {
        let folder = TempFolder()
        let usage = #"{"type":"assistant","message":{"id":"m","model":"a","usage":{"input_tokens":1}}}"#
        let done = folder.write("a.jsonl", [usage, toolUse("1", "Read", #"{"file_path":"/x/a.ts"}"#), toolResult("1"), usage].joined(separator: "\n") + "\n")
        #expect(TranscriptReader.tail(done).running == nil)
        let running = folder.write("b.jsonl", [usage, toolUse("1", "Read", #"{"file_path":"/x/a.ts"}"#), toolResult("1"), toolUse("2", "Edit", #"{"file_path":"/x/secret/b.ts","old_string":"p","new_string":"q"}"#)].joined(separator: "\n") + "\n")
        #expect(TranscriptReader.tail(running).running == StepBrief(kind: .edit, tool: "Edit", fileName: "b.ts"))
        let shell = folder.write("c.jsonl", [usage, toolUse("1", "Bash", #"{"command":"curl SECRET"}"#)].joined(separator: "\n") + "\n")
        let brief = TranscriptReader.tail(shell).running
        #expect(brief?.kind == .shell)
        #expect(!String(describing: brief).contains("SECRET"))
    }
}

@Suite("Текущий шаг в сканере")
struct ScannerStepTests {
    private func world(_ folder: TempFolder, agentTranscript: String) -> ClaudePaths {
        let run = "projects/p/s1/subagents/workflows/wf_1"
        folder.write("\(run)/journal.jsonl", #"{"type":"started","key":"k1","agentId":"a1","label":"one","phase":"P"}"# + "\n")
        folder.write("\(run)/agent-a1.jsonl", agentTranscript)
        return ClaudePaths(root: folder.url)
    }

    private func toolUse(_ id: String, _ name: String, _ input: String) -> String {
        #"{"type":"assistant","message":{"id":"m\#(id)","model":"a","usage":{"input_tokens":1},"content":[{"type":"tool_use","id":"\#(id)","name":"\#(name)","input":\#(input)}]}}"#
    }

    @Test("Раскрытый запуск обновляется быстро, остальные как раньше") func focusedRunRefreshes() async throws {
        let folder = TempFolder()
        let paths = world(folder, agentTranscript: toolUse("1", "Read", #"{"file_path":"/x/one.ts"}"#) + "\n")
        let scanner = RunScanner(paths: paths)
        let start = Date()
        let first = await scanner.scan(now: start)
        #expect(first.runs.first?.agents.first?.currentStep?.fileName == "one.ts")

        folder.append("projects/p/s1/subagents/workflows/wf_1/agent-a1.jsonl", toolUse("2", "Edit", #"{"file_path":"/x/two.ts"}"#) + "\n")
        let unfocused = await scanner.scan(now: start.addingTimeInterval(2))
        #expect(unfocused.runs.first?.agents.first?.currentStep?.fileName == "one.ts")

        await scanner.setFocus(runs: ["wf_1"], menuOpen: true)
        let focused = await scanner.scan(now: start.addingTimeInterval(4))
        #expect(focused.runs.first?.agents.first?.currentStep?.fileName == "two.ts")
    }
}

@Suite("Лента и большие записи")
struct ActivityWindowTests {
    private func toolUse(_ id: String) -> String {
        #"{"type":"assistant","message":{"id":"m\#(id)","content":[{"type":"tool_use","id":"\#(id)","name":"Read","input":{"file_path":"/x/\#(id).ts"}}]}}"#
    }

    private func big(_ megabytes: Int) -> String {
        #"{"type":"user","message":{"content":""# + String(repeating: "x", count: megabytes * 1024 * 1024) + #""}}"#
    }

    private func ids(_ reader: ActivityReader) -> [String] {
        reader.log.items.map(\.id)
    }

    @Test("Окно начинается внутри записи: разбор не ломается") func cutRecord() {
        let folder = TempFolder()
        let file = folder.write("a.jsonl", big(6) + "\n" + toolUse("after") + "\n")
        var reader = ActivityReader()
        reader.read(file)
        #expect(reader.startedPartWay)
        #expect(ids(reader) == ["after"])
    }

    @Test("Последняя запись больше окна: шаги перед ней видны") func lastRecordFillsWindow() {
        let folder = TempFolder()
        let file = folder.write("a.jsonl", toolUse("before") + "\n" + big(6) + "\n")
        var reader = ActivityReader()
        reader.read(file)
        #expect(ids(reader).first == "before")
    }

    @Test("Запись больше самого широкого окна: лента пуста и дальше читает дописанное") func recordBeyondWidest() {
        let folder = TempFolder()
        let file = folder.write("a.jsonl", toolUse("lost") + "\n" + big(17) + "\n")
        var reader = ActivityReader()
        reader.read(file)
        #expect(ids(reader).isEmpty)
        folder.append("a.jsonl", toolUse("next") + "\n")
        reader.read(file)
        #expect(ids(reader) == ["next"])
    }
}

@Suite("Ожидание разрешения по файлам")
struct WaitingToolTests {
    private func world(_ folder: TempFolder, transcript: String) throws -> ClaudePaths {
        let pid = ProcessInfo.processInfo.processIdentifier
        let start = try #require(ProcessInspector.startTime(pid: pid))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        folder.write("sessions/\(pid).json", #"{"sessionId":"s1","pid":\#(pid),"procStart":"\#(formatter.string(from: start))","cwd":"/x/p","status":"waiting","waitingFor":"permission prompt"}"#)
        folder.write("projects/p/s1.jsonl", transcript)
        return ClaudePaths(root: folder.url)
    }

    @Test("Инструмент берётся из конца транскрипта") func namedFromTranscript() async throws {
        let folder = TempFolder()
        let paths = try world(folder, transcript: #"{"type":"assistant","message":{"id":"m","model":"a","usage":{"input_tokens":1},"content":[{"type":"tool_use","id":"1","name":"Bash","input":{"command":"SECRET"}}]}}"# + "\n")
        let scan = await RunScanner(paths: paths).scan(now: Date())
        #expect(WaitingReason(scan.sessions.first?.waitingFor) == .permission(tool: "Bash"))
        #expect(scan.sessions.first?.waitingFor?.contains("SECRET") == false)
    }

    @Test("Запрос агента: инструмент не назван, но это разрешение") func agentRequest() async throws {
        let folder = TempFolder()
        let paths = try world(folder, transcript: #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"1","content":"ok"}]}}"# + "\n")
        let scan = await RunScanner(paths: paths).scan(now: Date())
        #expect(WaitingReason(scan.sessions.first?.waitingFor) == .permission(tool: nil))
    }
}

@Suite("Живой счёт токенов")
struct LiveTokenMeterTests {
    private func spent(_ id: String, input: Int = 100, output: Int) -> String {
        #"{"type":"assistant","message":{"id":"\#(id)","model":"a","usage":{"input_tokens":\#(input),"output_tokens":\#(output)},"content":[]}}"#
    }

    @Test("Считается только дописанное") func growsWithFile() {
        let folder = TempFolder()
        let file = folder.write("a.jsonl", spent("1", output: 10) + "\n")
        var meter = LiveTokenMeter()
        #expect(meter.read(file, fromStart: true).total == 110)
        #expect(meter.read(file, fromStart: true).total == 0)
        folder.append("a.jsonl", spent("2", output: 20) + "\n")
        #expect(meter.read(file, fromStart: true).total == 120)
        #expect(meter.total(of: file).total == 230)
    }

    @Test("Повтор сообщения считается на величину роста") func streamingRepeat() {
        let folder = TempFolder()
        let file = folder.write("a.jsonl", spent("1", output: 10) + "\n" + spent("1", output: 50) + "\n")
        var meter = LiveTokenMeter()
        #expect(meter.read(file, fromStart: true).total == 150)
        folder.append("a.jsonl", spent("1", output: 60) + "\n")
        #expect(meter.read(file, fromStart: true).total == 10)
    }

    @Test("Старый файл не считает своё прошлое") func oldFileStartsAtEnd() {
        let folder = TempFolder()
        let file = folder.write("a.jsonl", spent("1", output: 1000) + "\n")
        var meter = LiveTokenMeter()
        #expect(meter.read(file, fromStart: false).total == 0)
        folder.append("a.jsonl", spent("2", output: 5) + "\n")
        #expect(meter.read(file, fromStart: false).total == 105)
    }

    @Test("Недописанная строка ждёт") func partialLine() {
        let folder = TempFolder()
        let line = spent("1", output: 10)
        let file = folder.write("a.jsonl", String(line.prefix(30)))
        var meter = LiveTokenMeter()
        #expect(meter.read(file, fromStart: true).total == 0)
        folder.append("a.jsonl", String(line.dropFirst(30)) + "\n")
        #expect(meter.read(file, fromStart: true).total == 110)
    }

    @Test("Служебные записи не считаются") func syntheticAndOthers() {
        let folder = TempFolder()
        let synthetic = #"{"type":"assistant","message":{"id":"x","model":"<synthetic>","usage":{"input_tokens":999}}}"#
        let user = #"{"type":"user","message":{"usage":{"input_tokens":999},"content":"assistant"}}"#
        let file = folder.write("a.jsonl", synthetic + "\n" + user + "\n")
        var meter = LiveTokenMeter()
        #expect(meter.read(file, fromStart: true).total == 0)
    }

    @Test("Файл короче прежнего читается заново") func truncated() {
        let folder = TempFolder()
        let file = folder.write("a.jsonl", spent("1", output: 10) + "\n" + spent("2", output: 10) + "\n")
        var meter = LiveTokenMeter()
        _ = meter.read(file, fromStart: true)
        _ = folder.write("a.jsonl", spent("3", output: 1) + "\n")
        #expect(meter.read(file, fromStart: true).total == 101)
    }

    @Test("Большой файл читается без потерь") func bigFile() {
        let folder = TempFolder()
        let file = folder.url.appendingPathComponent("big.jsonl")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = FileHandle(forWritingAtPath: file.path)
        for i in 0..<3000 {
            let filler = String(repeating: "x", count: 2000)
            handle?.write(Data(#"{"type":"assistant","message":{"id":"m\#(i)","model":"a","usage":{"input_tokens":1,"output_tokens":1},"content":"\#(filler)"}}"#.utf8))
            handle?.write(Data("\n".utf8))
        }
        try? handle?.close()
        var meter = LiveTokenMeter()
        #expect(meter.read(file, fromStart: true).total == 6000)
    }
}
