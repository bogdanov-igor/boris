import BorisCore
import Foundation
import Testing
@testable import BorisData

@Suite("Лента всей сессии из файлов")
struct SessionFeedReaderTests {
    private func toolUse(_ id: String, _ name: String = "Read", _ input: String = #"{"file_path":"/x/a.swift"}"#, second: Int = 0) -> String {
        #"{"type":"assistant","timestamp":"2026-11-04T13:22:\#(String(format: "%02d", second)).000Z","message":{"id":"m\#(id)","model":"a","usage":{"input_tokens":3,"output_tokens":4,"cache_read_input_tokens":5},"content":[{"type":"tool_use","id":"\#(id)","name":"\#(name)","input":\#(input)}]}}"# + "\n"
    }

    private func toolResult(_ id: String, extra: String = "", second: Int = 1) -> String {
        #"{"type":"user","timestamp":"2026-11-04T13:22:\#(String(format: "%02d", second)).000Z","message":{"content":[{"type":"tool_result","tool_use_id":"\#(id)","content":"out"}]}\#(extra)}"# + "\n"
    }

    private func world() -> (TempFolder, URL) {
        let folder = TempFolder()
        let transcript = folder.write("p/s1.jsonl", toolUse("main1", second: 1))
        folder.write("p/s1/subagents/agent-a1.jsonl", toolUse("sub1", second: 2))
        folder.write("p/s1/subagents/agent-a1.meta.json", #"{"description":"Проверка кода","agentType":"reviewer"}"#)
        folder.write("p/s1/subagents/workflows/wf_1/agent-w1.jsonl", toolUse("wf1", second: 3))
        folder.write("p/s1/subagents/workflows/wf_1/journal.jsonl", #"{"type":"started"}"# + "\n")
        return (folder, transcript)
    }

    private func merged(_ reader: SessionFeedReader, live: Bool = true) -> [FeedEntry] {
        SessionFeed.merged(sessionId: "s1", logs: reader.logs { _ in live })
    }

    @Test("Читает главного агента, субагентов и агентов workflow") func allAgents() {
        let (folder, transcript) = world()
        _ = folder
        var reader = SessionFeedReader()
        let first = reader.read(transcript: transcript)
        #expect(first)
        #expect(merged(reader).map(\.agentId) == [nil, "a1", "w1"])
        #expect(merged(reader).map(\.item.id) == ["main1", "sub1", "wf1"])
        #expect(reader.names["a1"] == "Проверка кода")
        #expect(reader.names["w1"] == nil)
        #expect(reader.file(agentId: "w1")?.lastPathComponent == "agent-w1.jsonl")
        #expect(reader.file(agentId: nil) == transcript)
    }

    @Test("Первый взгляд только на главного агента, остальные следом") func firstLook() {
        let (folder, transcript) = world()
        _ = folder
        var reader = SessionFeedReader()
        reader.read(transcript: transcript, withAgents: false)
        #expect(merged(reader).map(\.agentId) == [nil])
        let more = reader.read(transcript: transcript)
        #expect(more)
        #expect(merged(reader).map(\.agentId) == [nil, "a1", "w1"])
    }

    @Test("Дописанные записи приходят, а без них чтение ничего не меняет") func appended() {
        let (folder, transcript) = world()
        var reader = SessionFeedReader()
        reader.read(transcript: transcript)
        let idle = reader.read(transcript: transcript)
        #expect(!idle)
        folder.append("p/s1.jsonl", toolUse("main2", second: 9))
        folder.append("p/s1/subagents/agent-a1.jsonl", toolResult("sub1", second: 4))
        let more = reader.read(transcript: transcript)
        #expect(more)
        #expect(merged(reader).map(\.item.id) == ["main1", "sub1", "wf1", "main2"])
        #expect(merged(reader).compactMap(\.step).first { $0.id == "sub1" }?.state == .done)
    }

    @Test("Новый агент появляется по ходу работы") func newAgent() {
        let (folder, transcript) = world()
        var reader = SessionFeedReader()
        reader.read(transcript: transcript)
        folder.write("p/s1/subagents/workflows/wf_2/agent-w2.jsonl", toolUse("wf2", second: 8))
        let changed = reader.read(transcript: transcript)
        #expect(changed)
        #expect(merged(reader).last?.agentId == "w2")
    }

    @Test("У остановившегося агента незакрытый вызов больше не идёт") func stopped() {
        let (folder, transcript) = world()
        _ = folder
        var reader = SessionFeedReader()
        reader.read(transcript: transcript)
        let logs = reader.logs { $0 != "a1" }
        func state(_ agent: String?) -> StepState? {
            logs.first { $0.agentId == agent }?.log.items.compactMap { item -> StepState? in
                if case .step(let step) = item { return step.state }
                return nil
            }.first
        }
        #expect(state(nil) == .running)
        #expect(state("a1") == .unfinished)
        // The same reader is not changed by this, so a result that comes later still lands.
        #expect(reader.logs { _ in true }.first { $0.agentId == "a1" }?.log.current != nil)
    }

    @Test("Лог удалён: лента пуста и ничего не падает") func missing() {
        let folder = TempFolder()
        var reader = SessionFeedReader()
        let changed = reader.read(transcript: folder.url.appendingPathComponent("gone.jsonl"))
        #expect(!changed)
        #expect(merged(reader).isEmpty)
    }

    // MARK: - Real shapes of records

    /// Shaped like a real `Edit` record from Claude Code 2.1, with invented content.
    private func editResult(_ id: String, lines: String) -> String {
        let extra = #","toolUseResult":{"filePath":"/x/a.swift","oldString":"o","newString":"n","originalFile":"o","structuredPatch":[{"oldStart":41,"oldLines":2,"newStart":41,"newLines":3,"lines":\#(lines)}],"userModified":false,"replaceAll":false}"#
        return toolResult(id, extra: extra)
    }

    private func steps(_ reader: ActivityReader) -> [ActivityStep] {
        reader.log.items.compactMap { if case .step(let step) = $0 { return step } else { return nil } }
    }

    @Test("Счётчик правки берётся из настоящего патча") func realEdit() {
        let folder = TempFolder()
        let file = folder.write("a.jsonl", toolUse("e", "Edit", #"{"file_path":"/x/a.swift","old_string":"one\ntwo\nthree\nfour","new_string":"one\nnew\nthree\nmore\nfour"}"#) + editResult("e", lines: #"[" one","-two","+new"," three","+more"," four"]"#))
        var reader = ActivityReader()
        reader.read(file)
        let step = steps(reader)[0]
        #expect(step.added == 2)
        #expect(step.removed == 1)
        #expect(step.diff().map(\.number) == [42, 42, 44])
        #expect(step.tokens?.input == 3)
        #expect(step.tokens?.output == 4)
    }

    @Test("Перезапись файла считается по патчу, а не как весь файл заново") func realWriteUpdate() {
        let folder = TempFolder()
        let result = toolResult("w", extra: #","toolUseResult":{"type":"update","filePath":"/x/a.swift","content":"c","originalFile":"o","structuredPatch":[{"oldStart":1,"oldLines":1,"newStart":1,"newLines":1,"lines":["-a","+b"," c"]}]}"#)
        let file = folder.write("a.jsonl", toolUse("w", "Write", #"{"file_path":"/x/a.swift","content":"b\nc\nd\ne\n"}"#) + result)
        var reader = ActivityReader()
        reader.read(file)
        #expect(steps(reader)[0].added == 1)
        #expect(steps(reader)[0].removed == 1)
    }

    @Test("Новый файл: патча нет, все строки добавлены") func realWriteCreate() {
        let folder = TempFolder()
        let result = toolResult("w", extra: #","toolUseResult":{"type":"create","filePath":"/x/a.swift","content":"c","structuredPatch":[],"originalFile":null}"#)
        let file = folder.write("a.jsonl", toolUse("w", "Write", #"{"file_path":"/x/a.swift","content":"b\nc\nd\n"}"#) + result)
        var reader = ActivityReader()
        reader.read(file)
        #expect(steps(reader)[0].added == 3)
        #expect(steps(reader)[0].removed == 0)
    }

    /// In an agent's transcript a result has no `toolUseResult`, only these words.
    private func agentResult(_ id: String, _ text: String) -> String {
        #"{"type":"user","timestamp":"2026-11-04T13:22:05.000Z","isSidechain":true,"message":{"content":[{"type":"tool_result","tool_use_id":"\#(id)","content":"\#(text)"}]}}"# + "\n"
    }

    @Test("Транскрипт агента: правка считается сравнением текстов, без лишних строк") func agentEdit() {
        let folder = TempFolder()
        let file = folder.write("a.jsonl", toolUse("e", "Edit", #"{"file_path":"/x/a.swift","old_string":"third\nkeep one\nkeep two\nsixth","new_string":"changed third\nkeep one\nkeep two\nchanged sixth\nadded"}"#) + agentResult("e", "The file /x/a.swift has been updated successfully."))
        var reader = ActivityReader()
        reader.read(file)
        let step = steps(reader)[0]
        #expect(step.added == 3)
        #expect(step.removed == 2)
        #expect(!step.oldTextUnknown)
    }

    @Test("Транскрипт агента: перезапись файла не выдаёт весь файл за новые строки") func agentOverwrite() {
        let folder = TempFolder()
        let file = folder.write("a.jsonl", toolUse("w", "Write", #"{"file_path":"/x/a.swift","content":"b\nc\nd\n"}"#) + agentResult("w", "The file /x/a.swift has been updated successfully."))
        var reader = ActivityReader()
        reader.read(file)
        let step = steps(reader)[0]
        #expect(step.added == nil)
        #expect(step.removed == nil)
        #expect(step.oldTextUnknown)
    }

    @Test("Транскрипт агента: новый файл считается целиком") func agentCreate() {
        let folder = TempFolder()
        let file = folder.write("a.jsonl", toolUse("w", "Write", #"{"file_path":"/x/a.swift","content":"b\nc\nd\n"}"#) + agentResult("w", "File created successfully at: /x/a.swift"))
        var reader = ActivityReader()
        reader.read(file)
        #expect(steps(reader)[0].added == 3)
        #expect(!steps(reader)[0].oldTextUnknown)
    }

    @Test("Весь текст длинной правки читается из файла по запросу") func wholeChange() throws {
        let folder = TempFolder()
        let text = (0..<4000).map { "line \($0)" }.joined(separator: "\\n")
        let patch = "[" + (0..<4000).map { "\"+line \($0)\"" }.joined(separator: ",") + "]"
        let file = folder.write("a.jsonl", toolUse("other") + toolUse("e", "Edit", #"{"file_path":"/x/a.swift","old_string":"x","new_string":"\#(text)"}"#) + editResult("e", lines: patch) + toolUse("after"))
        var reader = ActivityReader()
        reader.read(file)
        let step = try #require(steps(reader).first { $0.id == "e" })
        #expect(step.isCut)
        #expect(step.added == 4000)
        #expect(step.diff().count < 4000)

        let whole = try #require(ActivityReader.fullStep("e", in: file))
        #expect(whole.input.newText?.contains("line 3999") == true)
        #expect(whole.hunks.flatMap(\.lines).count == 4000)
        #expect(whole.output == "out")
        #expect(whole.raw.components(separatedBy: "\n").count == 2)
        #expect(whole.raw.contains("\"tool_use\""))
        #expect(whole.raw.contains("\"tool_result\""))
        #expect(!whole.raw.contains("\"after\""))
        #expect(ActivityReader.fullStep("nothing", in: file) == nil)
    }

    @Test("Каждый инструмент получает верный тип и подпись", arguments: [
        ("Read", #"{"file_path":"/x/a.swift"}"#, WorkAction.read, "/x/a.swift"),
        ("Grep", #"{"pattern":"isExpired","path":"/x"}"#, .read, "isExpired /x"),
        ("Glob", #"{"pattern":"**/*.swift"}"#, .read, "**/*.swift"),
        ("Edit", #"{"file_path":"/x/a.swift","old_string":"a","new_string":"b"}"#, .write, "/x/a.swift"),
        ("MultiEdit", #"{"file_path":"/x/a.swift","edits":[{"old_string":"a","new_string":"b"}]}"#, .write, "/x/a.swift"),
        ("Write", #"{"file_path":"/x/a.swift","content":"b"}"#, .write, "/x/a.swift"),
        ("NotebookEdit", #"{"notebook_path":"/x/a.ipynb","new_source":"b"}"#, .write, "/x/a.ipynb"),
        ("Bash", #"{"command":"swift test","description":"Runs tests"}"#, .command, "swift test"),
        ("Monitor", #"{"command":"tail -f log","description":"Watches"}"#, .command, "tail -f log"),
        ("WebSearch", #"{"query":"swift crypto","mode":"auto"}"#, .webSearch, "swift crypto"),
        ("WebFetch", #"{"url":"https://example.com/a","prompt":"p"}"#, .webFetch, "https://example.com/a"),
        ("Skill", #"{"skill":"swift-testing","args":"x"}"#, .skill, "swift-testing"),
        ("mcp__postgres__query", #"{"sql":"select 1"}"#, .mcp, "postgres · query"),
        ("Agent", #"{"description":"Проверка кода","prompt":"long"}"#, .startAgent, "Проверка кода"),
        ("Task", #"{"description":"Проверка кода","prompt":"long"}"#, .startAgent, "Проверка кода"),
        ("Workflow", #"{"script":"long","scriptPath":"/x/audit.js"}"#, .startAgent, "audit.js"),
    ])
    func types(tool: String, input: String, action: WorkAction, target: String) throws {
        let folder = TempFolder()
        let file = folder.write("a.jsonl", toolUse("t", tool, input))
        var reader = ActivityReader()
        reader.read(file)
        let step = try #require(steps(reader).first)
        #expect(WorkAction(tool: step.tool) == action)
        #expect(WorkPhrases.target(step, cwd: nil) == target)
    }

    @Test("Незнакомый инструмент показывает, о чём его попросили") func unknownTool() throws {
        let folder = TempFolder()
        let file = folder.write("a.jsonl", toolUse("t", "ToolSearch", #"{"query":"select:Read","max_results":1}"#))
        var reader = ActivityReader()
        reader.read(file)
        let step = try #require(steps(reader).first)
        #expect(step.input.command?.contains("select:Read") == true)
        #expect(WorkAction(tool: step.tool) == .other)
    }

    @Test("Узкое окно начинает с конца большого файла") func narrowWindow() {
        let folder = TempFolder()
        let filler = #"{"type":"user","message":{"content":""# + String(repeating: "x", count: 900 * 1024) + #""}}"# + "\n"
        let file = folder.write("a.jsonl", toolUse("old") + filler + toolUse("new"))
        var narrow = ActivityReader(window: 256 * 1024)
        narrow.read(file)
        #expect(narrow.startedPartWay)
        #expect(steps(narrow).map(\.id) == ["new"])
        var wide = ActivityReader()
        wide.read(file)
        #expect(steps(wide).map(\.id) == ["old", "new"])
    }

    @Test("Цепочка родителей процесса идёт снизу вверх и кончается") func processTree() throws {
        let own = ProcessInfo.processInfo.processIdentifier
        let chain = ProcessInspector.ancestors(of: own)
        #expect(chain.first == own)
        #expect(chain.count > 1)
        #expect(chain[1] == ProcessInspector.parent(pid: own))
        #expect(Set(chain).count == chain.count)
        #expect(!chain.contains(1))
        #expect(ProcessInspector.ancestors(of: -1) == [])
    }
}
