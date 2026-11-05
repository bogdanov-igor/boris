import BorisCore
import Foundation
import Testing
@testable import BorisData

@Suite("agent-tracking: обычные агенты")
struct SingleAgentTests {
    private func live(_ folder: TempFolder, session: String = "s1") throws -> ClaudePaths {
        let pid = ProcessInfo.processInfo.processIdentifier
        let start = try #require(ProcessInspector.startTime(pid: pid))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        folder.write("sessions/\(pid).json", #"{"sessionId":"\#(session)","pid":\#(pid),"procStart":"\#(formatter.string(from: start))","cwd":"/x/proj","status":"busy"}"#)
        folder.write("projects/p/\(session).jsonl", "")
        return ClaudePaths(root: folder.url)
    }

    private func tool(_ name: String, _ input: String) -> String {
        #"{"type":"assistant","cwd":"/x/proj","message":{"id":"m1","model":"opus","usage":{"input_tokens":100,"output_tokens":5},"content":[{"type":"tool_use","id":"t1","name":"\#(name)","input":\#(input)}]}}"#
    }

    @Test("Идущий агент виден, с описанием и текущим шагом") func running() async throws {
        let folder = TempFolder()
        let paths = try live(folder)
        folder.write("projects/p/s1/subagents/agent-a1.meta.json", #"{"description":"Build the mechanism, stages 1-3","requestShape":"background"}"#)
        folder.write("projects/p/s1/subagents/agent-a1.jsonl", tool("Edit", #"{"file_path":"/x/invoice.ts"}"#) + "\n")
        let world = await RunScanner(paths: paths).scan(now: Date())
        let agent = try #require(world.agents.first { $0.id == "a1" })
        #expect(agent.description == "Build the mechanism, stages 1-3")
        #expect(agent.sessionId == "s1")
        #expect(agent.state == .running)
        #expect(agent.currentStep?.fileName == "invoice.ts")
        #expect(world.agentTokens["a1"]?.total == 105)
    }

    @Test("Закончивший агент завершён") func finished() async throws {
        let folder = TempFolder()
        let paths = try live(folder)
        folder.write("projects/p/s1/subagents/agent-a1.meta.json", #"{"description":"Plan","finished":true}"#)
        folder.write("projects/p/s1/subagents/agent-a1.jsonl", tool("Read", #"{"file_path":"/x/a.ts"}"#) + "\n")
        let world = await RunScanner(paths: paths).scan(now: Date())
        let agent = try #require(world.agents.first { $0.id == "a1" })
        #expect(agent.state == .done)
        #expect(world.agentTokens["a1"] == nil)
    }

    @Test("Агент появляется и заканчивает на глазах") func becomesFinished() async throws {
        let folder = TempFolder()
        let paths = try live(folder)
        let scanner = RunScanner(paths: paths)
        let empty = await scanner.scan(now: Date())
        #expect(empty.agents.isEmpty)
        folder.write("projects/p/s1/subagents/agent-a1.meta.json", #"{"description":"Plan"}"#)
        folder.write("projects/p/s1/subagents/agent-a1.jsonl", tool("Read", #"{"file_path":"/x/a.ts"}"#) + "\n")
        let first = await scanner.scan(now: Date())
        #expect(first.agents.first?.state == .running)
        try await Task.sleep(for: .milliseconds(1100))
        folder.write("projects/p/s1/subagents/agent-a1.meta.json", #"{"description":"Plan","finished":true}"#)
        let second = await scanner.scan(now: Date())
        #expect(second.agents.first?.state == .done)
    }

    @Test("Папка агента находится для ленты") func folderForFeed() async throws {
        let folder = TempFolder()
        let paths = try live(folder)
        folder.write("projects/p/s1/subagents/agent-a1.meta.json", #"{"description":"Plan"}"#)
        folder.write("projects/p/s1/subagents/agent-a1.jsonl", "{}\n")
        let scanner = RunScanner(paths: paths)
        _ = await scanner.scan(now: Date())
        let found = await scanner.runFolder("a1")
        #expect(found?.lastPathComponent == "subagents")
    }

    @Test("Токены одного агента, а не всей папки") func tokensOfOne() {
        let folder = TempFolder()
        let line = #"{"type":"assistant","message":{"id":"m","model":"a","usage":{"input_tokens":10}}}"#
        folder.write("subagents/agent-a1.jsonl", line + "\n")
        folder.write("subagents/agent-a2.jsonl", line + "\n")
        let dir = folder.url.appendingPathComponent("subagents")
        #expect(AgentDetailReader.runTokens(runDir: dir, onlyAgent: "a1").total == 10)
        #expect(AgentDetailReader.runTokens(runDir: dir).total == 20)
    }

    @Test("Последние слова агента это его результат") func lastWords() {
        let folder = TempFolder()
        let text = #"{"type":"assistant","message":{"content":[{"type":"text","text":"Done: 3 files"}]}}"#
        let later = #"{"type":"user","message":{"content":"assistant"}}"#
        let file = folder.write("a.jsonl", text + "\n" + later + "\n")
        #expect(TranscriptReader.lastText(file) == "Done: 3 files")
    }
}

@Suite("agent-tracking: конец без отметки и вложенность")
struct AgentEndTests {
    private let ended = #"{"type":"assistant","cwd":"/x/proj","message":{"id":"m","model":"opus","stop_reason":"end_turn","usage":{"input_tokens":1},"content":[{"type":"text","text":"готово"}]}}"#
    private let more = #"{"type":"user","message":{"content":"продолжай"}}"#

    private func setDates(_ file: URL, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
    }

    @Test("Без отметки: конец хода и тишина означают конец") func noMark() async throws {
        let folder = TempFolder()
        folder.write("sessions/.keep", "")
        folder.write("projects/p/s1/subagents/agent-a1.meta.json", #"{"description":"Старый агент"}"#)
        let file = folder.write("projects/p/s1/subagents/agent-a1.jsonl", ended + "\n")
        try setDates(file, Date().addingTimeInterval(-60))
        let world = await RunScanner(paths: ClaudePaths(root: folder.url)).scan(now: Date())
        let agent = try #require(world.agents.first { $0.id == "a1" })
        #expect(agent.state == .done)
    }

    @Test("Без отметки: только что закончил ход, ещё не конец") func noMarkTooSoon() async throws {
        let folder = TempFolder()
        folder.write("sessions/.keep", "")
        folder.write("projects/p/s1/subagents/agent-a1.meta.json", #"{"description":"Агент"}"#)
        folder.write("projects/p/s1/subagents/agent-a1.jsonl", ended + "\n")
        let world = await RunScanner(paths: ClaudePaths(root: folder.url)).scan(now: Date())
        #expect(world.agents.first { $0.id == "a1" }?.state == .running)
    }

    @Test("Запись после отметки: агента продолжили") func continued() async throws {
        let folder = TempFolder()
        folder.write("sessions/.keep", "")
        let meta = folder.write("projects/p/s1/subagents/agent-a1.meta.json", #"{"description":"Агент","finished":true}"#)
        let file = folder.write("projects/p/s1/subagents/agent-a1.jsonl", ended + "\n" + more + "\n")
        try setDates(meta, Date().addingTimeInterval(-60))
        try setDates(file, Date().addingTimeInterval(-10))
        let world = await RunScanner(paths: ClaudePaths(root: folder.url)).scan(now: Date())
        let agent = try #require(world.agents.first { $0.id == "a1" })
        #expect(agent.state == .running)
    }

    @Test("Отметка на месте: чтение хвоста не нужно, агент завершён") func marked() async throws {
        let folder = TempFolder()
        folder.write("sessions/.keep", "")
        let file = folder.write("projects/p/s1/subagents/agent-a1.jsonl", more + "\n")
        try setDates(file, Date().addingTimeInterval(-60))
        folder.write("projects/p/s1/subagents/agent-a1.meta.json", #"{"description":"Агент","finished":true}"#)
        let world = await RunScanner(paths: ClaudePaths(root: folder.url)).scan(now: Date())
        #expect(world.agents.first { $0.id == "a1" }?.state == .done)
    }

    @Test("Родитель и вид агента записаны, общие виды скрыты") func parentAndKind() async throws {
        let folder = TempFolder()
        folder.write("sessions/.keep", "")
        folder.write("projects/p/s1/subagents/agent-a2.meta.json", #"{"description":"Вложенный","parentAgentId":"a1","agentType":"scout","spawnDepth":2}"#)
        folder.write("projects/p/s1/subagents/agent-a2.jsonl", more + "\n")
        folder.write("projects/p/s1/subagents/agent-a3.meta.json", #"{"description":"Обычный","agentType":"general-purpose"}"#)
        folder.write("projects/p/s1/subagents/agent-a3.jsonl", more + "\n")
        let world = await RunScanner(paths: ClaudePaths(root: folder.url)).scan(now: Date())
        let nested = try #require(world.agents.first { $0.id == "a2" })
        #expect(nested.parentAgentId == "a1")
        #expect(nested.agentType == "scout")
        #expect(world.agents.first { $0.id == "a3" }?.agentType == nil)
    }

    @Test("Форк отмечен") func fork() async throws {
        let folder = TempFolder()
        folder.write("sessions/.keep", "")
        folder.write("projects/p/s1/subagents/agent-f1.meta.json", #"{"description":"Копия","isFork":true}"#)
        folder.write("projects/p/s1/subagents/agent-f1.jsonl", more + "\n")
        let world = await RunScanner(paths: ClaudePaths(root: folder.url)).scan(now: Date())
        #expect(world.agents.first { $0.id == "f1" }?.isFork == true)
    }

    @Test("Обычные агенты больше не притворяются запусками") func notRuns() async throws {
        let folder = TempFolder()
        folder.write("sessions/.keep", "")
        folder.write("projects/p/s1/subagents/agent-a1.meta.json", #"{"description":"Агент"}"#)
        folder.write("projects/p/s1/subagents/agent-a1.jsonl", more + "\n")
        let world = await RunScanner(paths: ClaudePaths(root: folder.url)).scan(now: Date())
        #expect(world.runs.isEmpty)
        #expect(world.agents.count == 1)
    }

    @Test("Вид специального агента workflow берётся из его метаданных") func workflowKind() async throws {
        let folder = TempFolder()
        folder.write("sessions/.keep", "")
        let run = "projects/p/s1/subagents/workflows/wf_a"
        folder.write("\(run)/journal.jsonl", #"{"type":"launched"}"# + "\n" + #"{"type":"started","key":"k","agentId":"w1","label":"Разведка"}"# + "\n")
        folder.write("\(run)/agent-w1.meta.json", #"{"agentType":"scout"}"#)
        folder.write("\(run)/agent-w1.jsonl", more + "\n")
        let world = await RunScanner(paths: ClaudePaths(root: folder.url)).scan(now: Date())
        #expect(world.runs.first { $0.runId == "wf_a" }?.agents.first?.agentType == "scout")
    }
}
