import BorisCore
import Foundation
import Testing
@testable import BorisData

@Suite("Всё, что связано с Claude")
struct AllSourcesTests {
    private let turnEnd = #"{"type":"assistant","cwd":"/x/proj","entrypoint":"cli","message":{"id":"m","model":"opus","stop_reason":"end_turn","usage":{"input_tokens":1},"content":[{"type":"text","text":"done"}]}}"#
    private let working = #"{"type":"assistant","cwd":"/x/proj","entrypoint":"cli","message":{"id":"m","model":"opus","stop_reason":"tool_use","usage":{"input_tokens":1},"content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/x/a.ts"}}]}}"#

    private func aged(_ file: URL, _ seconds: TimeInterval) throws {
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-seconds)], ofItemAtPath: file.path)
    }

    private func livePid(_ folder: TempFolder, session: String) throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let start = try #require(ProcessInspector.startTime(pid: pid))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        folder.write("sessions/\(pid).json", #"{"sessionId":"\#(session)","pid":\#(pid),"procStart":"\#(formatter.string(from: start))","status":"busy","name":"my-app-2d","nameSource":"derived"}"#)
    }

    // MARK: folders

    @Test("Находятся другие папки настроек и Cowork, основная не повторяется") func findsFolders() {
        let home = TempFolder()
        home.write(".claude/projects/p/s.jsonl", "")
        home.write(".claude-work/projects/p/s.jsonl", "")
        home.write(".claude-empty/logs/x", "")
        home.write(".claude.json", "{}")
        home.write(".other/projects/p/s.jsonl", "")
        home.write("Library/Application Support/Claude/local-agent-mode-sessions/org/acc/agent/one/.claude/projects/p/s.jsonl", "")
        let main = ClaudePaths(root: home.url.appendingPathComponent(".claude"))
        let found = ClaudeFolders.others(besides: main, environment: [:], home: home.url)
        #expect(found.map { $0.root.lastPathComponent }.sorted() == [".claude", ".claude-work"])
        #expect(found.filter { !$0.processesAreHere }.count == 1)
        #expect(found.filter(\.processesAreHere).map { $0.root.lastPathComponent } == [".claude-work"])
    }

    @Test("Тестовый запуск видит только свою папку") func onlyThisFolder() {
        let home = TempFolder()
        home.write(".claude-work/projects/p/s.jsonl", "")
        let main = ClaudePaths(root: home.url.appendingPathComponent(".claude"))
        #expect(ClaudeFolders.others(besides: main, environment: ["BORIS_ONLY_THIS_FOLDER": "1"], home: home.url).isEmpty)
    }

    @Test("Запуск из другой папки виден, лимиты только из основной") func otherFolderRun() async {
        let main = TempFolder()
        let other = TempFolder()
        main.write("sessions/.keep", "")
        other.write(".claude.json", #"{"cachedUsageUtilization":{"fiveHour":{"utilization":99}}}"#)
        other.write("projects/p/s/subagents/workflows/wf_other/journal.jsonl", #"{"type":"launched"}"# + "\n")
        let paths = ClaudePaths(root: other.url)
        let scanner = RunScanner(paths: ClaudePaths(root: main.url), others: { [paths] })
        let world = await scanner.scan(now: Date())
        #expect(world.runs.contains { $0.runId == "wf_other" })
        #expect(world.usage == nil)
    }

    @Test("Номера процессов Cowork не используются") func coworkProcessesIgnored() async throws {
        let main = TempFolder()
        let cowork = TempFolder()
        main.write("sessions/.keep", "")
        let pid = ProcessInfo.processInfo.processIdentifier
        cowork.write("sessions/\(pid).json", #"{"sessionId":"vm","pid":\#(pid),"status":"busy"}"#)
        var paths = ClaudePaths(root: cowork.url)
        paths.processesAreHere = false
        let found = paths
        let world = await RunScanner(paths: ClaudePaths(root: main.url), others: { [found] }).scan(now: Date())
        #expect(!world.sessions.contains { $0.sessionId == "vm" })
    }

    // MARK: sessions without a file

    @Test("Сессия без файла видна с текущим шагом и откуда запущена") func unlistedVisible() async throws {
        let folder = TempFolder()
        folder.write("sessions/.keep", "")
        let scanner = RunScanner(paths: ClaudePaths(root: folder.url))
        folder.write("projects/p/child.jsonl", working + "\n")
        await scanner.markDiscovery()
        let world = await scanner.scan(now: Date())
        let session = try #require(world.sessions.first { $0.sessionId == "child" })
        #expect(session.isUnlisted)
        #expect(session.status == "busy")
        #expect(session.projectName == "proj")
        #expect(session.currentStep?.fileName == "a.ts")
        #expect(session.environment == .insideClaude)
    }

    @Test("Запись в папке проекта видна сразу, без общего поиска") func unlistedByChange() async throws {
        let folder = TempFolder()
        folder.write("sessions/.keep", "")
        let scanner = RunScanner(paths: ClaudePaths(root: folder.url))
        _ = await scanner.scan(now: Date())
        folder.write("projects/p/child.jsonl", working + "\n")
        await scanner.markProject(folder.url.appendingPathComponent("projects/p").path)
        let world = await scanner.scan(now: Date())
        #expect(world.sessions.contains { $0.sessionId == "child" })
    }

    @Test("Старый транскрипт не считается живой сессией") func oldTranscript() async throws {
        let folder = TempFolder()
        folder.write("sessions/.keep", "")
        let file = folder.write("projects/p/old.jsonl", working + "\n")
        try aged(file, 60)
        let world = await RunScanner(paths: ClaudePaths(root: folder.url)).scan(now: Date())
        #expect(world.sessions.isEmpty)
    }

    @Test("Сессия, у которой файл был и исчез, завершилась") func hadFileAndLostIt() async throws {
        let folder = TempFolder()
        try livePid(folder, session: "s1")
        let scanner = RunScanner(paths: ClaudePaths(root: folder.url))
        let first = await scanner.scan(now: Date())
        #expect(first.sessions.first?.sessionId == "s1")
        #expect(first.sessions.first?.isUnlisted == false)
        let pid = ProcessInfo.processInfo.processIdentifier
        try FileManager.default.removeItem(at: folder.url.appendingPathComponent("sessions/\(pid).json"))
        folder.write("projects/p/s1.jsonl", working + "\n")
        await scanner.markDiscovery()
        let second = await scanner.scan(now: Date())
        #expect(second.sessions.isEmpty)
    }

    @Test("Тишина убирает сессию: 5 минут после конца хода, 15 при незавершённом") func quiet() async throws {
        let folder = TempFolder()
        folder.write("sessions/.keep", "")
        let scanner = RunScanner(paths: ClaudePaths(root: folder.url))
        folder.write("projects/p/done.jsonl", turnEnd + "\n")
        folder.write("projects/p/busy.jsonl", working + "\n")
        await scanner.markDiscovery()
        let now = Date()
        let start = await scanner.scan(now: now)
        #expect(Set(start.sessions.map(\.sessionId)) == ["done", "busy"])
        #expect(start.sessions.first { $0.sessionId == "done" }?.status == "idle")
        let later = await scanner.scan(now: now.addingTimeInterval(6 * 60))
        #expect(later.sessions.map(\.sessionId) == ["busy"])
        let quiet = await scanner.scan(now: now.addingTimeInterval(16 * 60))
        #expect(quiet.sessions.isEmpty)
    }

    @Test("Запуск без главного транскрипта свежим не держит старую сессию живой без записи") func runKeepsSessionAlive() async throws {
        let folder = TempFolder()
        folder.write("sessions/.keep", "")
        let file = folder.write("projects/p/s2.jsonl", turnEnd + "\n")
        try aged(file, 120)
        let scanner = RunScanner(paths: ClaudePaths(root: folder.url))
        // The run is written after the launch, while the session's own transcript stays quiet.
        folder.write("projects/p/s2/subagents/workflows/wf_quiet/journal.jsonl", #"{"type":"launched"}"# + "\n")
        await scanner.markDiscovery()
        _ = await scanner.scan(now: Date())
        await scanner.markDirty(runs: ["wf_quiet"])
        let world = await scanner.scan(now: Date())
        #expect(world.sessions.contains { $0.sessionId == "s2" })
    }

    // MARK: titles

    @Test("Заголовок заменяет автоматическое имя, имя человека остаётся") func titles() async throws {
        let folder = TempFolder()
        try livePid(folder, session: "s1")
        folder.write("projects/p/s1.jsonl", #"{"type":"ai-title","aiTitle":"Старый"}"# + "\n" + #"{"type":"ai-title","aiTitle":"Архитектура проекта"}"# + "\n")
        let world = await RunScanner(paths: ClaudePaths(root: folder.url)).scan(now: Date())
        let session = try #require(world.sessions.first)
        #expect(session.name == "my-app-2d")
        #expect(session.title == "Архитектура проекта")
        #expect(session.displayName == "Архитектура проекта")
        var named = session
        named.nameSource = "user"
        named.name = "Мой проект"
        #expect(named.displayName == "Мой проект")
    }

    // MARK: file changes

    @Test("Запись прямо в папке проекта распознаётся, вложенное не считается") func projectChange() {
        let changes = FileChangeParser.changes(in: [
            "/h/.claude/projects/p/",
            "/h/.claude/projects/q/s1.jsonl",
            "/h/.claude/projects/r/s1/subagents/",
        ])
        #expect(changes.contains(.project("/h/.claude/projects/p")))
        #expect(changes.contains(.project("/h/.claude/projects/q")))
        #expect(!changes.contains(.project("/h/.claude/projects/r")))
    }

    // MARK: the feed

    @Test("Запрос человека и задание агента в ленте, служебные вставки нет") func prompts() {
        func events(_ json: String) -> [ActivityEvent] {
            let record = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
            return ActivityReader.events(from: record)
        }
        #expect(events(#"{"type":"user","message":{"content":"Сделай отчёт"}}"#) == [.prompt("Сделай отчёт", at: nil)])
        #expect(events(#"{"type":"user","message":{"content":[{"type":"text","text":"С блоками"},{"type":"image"}]}}"#) == [.prompt("С блоками", at: nil)])
        #expect(events(#"{"type":"user","message":{"content":"<system-reminder>x</system-reminder>"}}"#).isEmpty)
        #expect(events(#"{"type":"user","message":{"content":"<task-notification>x</task-notification>"}}"#).isEmpty)
        #expect(events(#"{"type":"user","isMeta":true,"message":{"content":"скрытое"}}"#).isEmpty)
        #expect(events(#"{"type":"user","isCompactSummary":true,"message":{"content":"сводка"}}"#).isEmpty)
        let result = events(#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t","content":"out"},{"type":"text","text":"вставка"}]}}"#)
        #expect(result == [.toolResult(id: "t", isError: false, text: "out", at: nil)])
    }

    @Test("Конец хода читается по последнему сообщению, служебные записи не мешают") func turnEnded() {
        let folder = TempFolder()
        let ended = folder.write("a.jsonl", working + "\n" + turnEnd + "\n" + #"{"type":"last-prompt","lastPrompt":"x"}"# + "\n")
        #expect(TranscriptReader.tail(ended).turnEnded)
        let notEnded = folder.write("b.jsonl", turnEnd + "\n" + #"{"type":"user","message":{"content":"ещё"}}"# + "\n")
        #expect(!TranscriptReader.tail(notEnded).turnEnded)
        let tool = folder.write("c.jsonl", working + "\n")
        #expect(!TranscriptReader.tail(tool).turnEnded)
    }
}

@Suite("monitor-menu: система запуска")
struct RunSystemTests {
    @Test("Запуск и обычный агент знают свою систему из транскрипта") func entrypointOfRuns() async throws {
        let folder = TempFolder()
        folder.write("sessions/.keep", "")
        let parent = #"{"type":"user","cwd":"/x/p","entrypoint":"claude-desktop","message":{"content":"x"}}"#
        folder.write("projects/p/s1.jsonl", parent + "\n")
        folder.write("projects/p/s1/subagents/workflows/wf_a/journal.jsonl", #"{"type":"launched"}"# + "\n")
        folder.write("projects/p/s1/subagents/agent-a1.meta.json", #"{"description":"Агент"}"#)
        folder.write("projects/p/s1/subagents/agent-a1.jsonl", parent + "\n")
        let world = await RunScanner(paths: ClaudePaths(root: folder.url)).scan(now: Date())
        #expect(world.runs.first { $0.runId == "wf_a" }?.entrypoint == "claude-desktop")
        #expect(world.agents.first { $0.id == "a1" }?.entrypoint == "claude-desktop")
    }
}
