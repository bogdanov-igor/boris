import BorisCore
import Foundation
import Testing
@testable import BorisData

/// What the technical view tells about a call and a session, on made-up transcripts.
@Suite("Подробности для технического режима")
struct ToolDetailsTests {
    private func names(_ tool: String, _ input: [String: Any]) -> [String] {
        ActivityReader.input(tool, input).parameters.map(\.name)
    }

    @Test("Параметры инструмента: все, по порядку, с понятными значениями")
    func parameters() throws {
        let input = ActivityReader.input("Grep", ["pattern": "isExpired", "path": "/x/src", "-n": true, "head_limit": 20, "nothing": NSNull(), "empty": ""])
        #expect(input.parameters.map(\.name) == ["-n", "head_limit", "path", "pattern"])
        #expect(input.parameters.map(\.value) == ["true", "20", "/x/src", "isExpired"])
    }

    @Test("Вложенное значение показывается как есть")
    func nested() throws {
        let input = ActivityReader.input("Skill", ["skill": "pdf", "options": ["b": 1, "a": ["x"]]])
        #expect(input.parameters.first { $0.name == "options" }?.value == #"{"a":["x"],"b":1}"#)
    }

    @Test("То, что подробности уже показывают словом в слово, не повторяется", arguments: [
        ("Bash", "command"), ("Edit", "old_string"), ("Edit", "new_string"), ("MultiEdit", "edits"), ("Write", "content"), ("NotebookEdit", "new_source"), ("WebSearch", "query"), ("Agent", "prompt"), ("Task", "prompt"), ("Workflow", "script"),
    ])
    func noRepeats(tool: String, long: String) {
        #expect(names(tool, [long: "x", "kept": "y"]) == ["kept"])
    }

    @Test("Незнакомый инструмент показывает всё в своём тексте, и список не дублирует его")
    func unknownTool() {
        let input = ActivityReader.input("mcp__postgres__query", ["sql": "select 1"])
        #expect(input.command?.contains("select 1") == true)
        #expect(input.parameters.isEmpty)
    }

    @Test("Длинное значение обрезается, а весь текст есть в самом событии")
    func longValue() throws {
        let long = String(repeating: "я", count: 5000)
        let cut = try #require(ActivityReader.input("WebFetch", ["url": "https://x", "prompt": long]).parameters.first { $0.name == "prompt" })
        #expect(cut.value.count == 241)
        #expect(cut.value.hasSuffix("…"))
        let many = Dictionary(uniqueKeysWithValues: (0..<40).map { ("key\($0)", "v") })
        #expect(ActivityReader.input("Read", many).parameters.count == 12)
    }

    @Test("Параметры доходят до ленты и не считаются обрезанной правкой")
    func reachTheFeed() throws {
        let folder = TempFolder()
        let line = #"{"type":"assistant","timestamp":"2026-11-04T13:22:00.000Z","message":{"id":"m","content":[{"type":"tool_use","id":"g","name":"Grep","input":{"pattern":"x","output_mode":"content"}}]}}"#
        let file = folder.write("a.jsonl", line + "\n")
        var reader = ActivityReader()
        reader.read(file)
        guard case .step(let step) = try #require(reader.log.items.first) else {
            Issue.record("no step")
            return
        }
        #expect(step.input.parameters.map(\.name) == ["output_mode", "pattern"])
        #expect(!step.isCut)
    }

    private func prompt(_ mode: String) -> String {
        #"{"type":"user","permissionMode":"\#(mode)","timestamp":"2026-11-04T13:22:00.000Z","message":{"content":"сделай"}}"# + "\n"
    }

    @Test("Режим разрешений берётся из новейшей записи, которая его называет")
    func permissionMode() {
        let folder = TempFolder()
        let file = folder.write("a.jsonl", prompt("default"))
        var reader = ActivityReader()
        #expect(reader.permissionMode == nil)
        reader.read(file)
        #expect(reader.permissionMode == "default")
        folder.append("a.jsonl", prompt("acceptEdits"))
        reader.read(file)
        #expect(reader.permissionMode == "acceptEdits")
        // A record of its own has no message, and a line without one is still looked at for this.
        folder.append("a.jsonl", #"{"type":"permission-mode","permissionMode":"plan","sessionId":"s"}"# + "\n")
        reader.read(file)
        #expect(reader.permissionMode == "plan")
        // What a tool printed is not a setting, even when it looks like one.
        folder.append("a.jsonl", #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t","content":"{\"permissionMode\":\"bypassPermissions\"}"}]}}"# + "\n")
        reader.read(file)
        #expect(reader.permissionMode == "plan")
    }

    @Test("Режим сессии виден через весь её читатель, а незнакомый лог его не выдумывает")
    func throughSessionReader() {
        let folder = TempFolder()
        var known = SessionFeedReader()
        known.read(transcript: folder.write("a.jsonl", prompt("plan")))
        #expect(known.permissionMode == "plan")
        var unknown = SessionFeedReader()
        unknown.read(transcript: folder.write("b.jsonl", #"{"type":"user","message":{"content":"сделай"}}"# + "\n"))
        #expect(unknown.permissionMode == nil)
    }
}
