import Foundation
import Testing
@testable import BorisCore

@Suite("live-activity")
struct ActivityTests {
    private func use(_ id: String, _ tool: String = "Bash", input: ToolInput = ToolInput()) -> ActivityEvent {
        .toolUse(id: id, tool: tool, input: input, at: t0)
    }

    private func steps(_ log: ActivityLog) -> [ActivityStep] {
        log.items.compactMap { if case .step(let step) = $0 { return step } else { return nil } }
    }

    @Test("Шаг идёт, пока нет результата") func runningStep() {
        var log = ActivityLog()
        log.apply(use("a", "Read", input: ToolInput(target: "/x/src/invoice.ts")))
        #expect(log.current?.id == "a")
        #expect(log.current?.brief == StepBrief(kind: .read, tool: "Read", fileName: "invoice.ts"))
        log.apply(.toolResult(id: "a", isError: false, text: "file text", at: at(2)))
        #expect(log.current == nil)
        #expect(steps(log)[0].state == .done)
        #expect(steps(log)[0].finishedAt == at(2))
    }

    @Test("Ошибка в результате") func failedStep() {
        var log = ActivityLog()
        log.apply(use("a"))
        log.apply(.toolResult(id: "a", isError: true, text: "boom", at: nil))
        #expect(steps(log)[0].state == .failed)
    }

    @Test("Повтор записи не дублирует шаг") func noDuplicates() {
        var log = ActivityLog()
        log.apply(use("a"))
        log.apply(use("a"))
        #expect(log.items.count == 1)
    }

    @Test("Результат без шага не ломает ленту") func orphanResult() {
        var log = ActivityLog()
        log.apply(.toolResult(id: "nope", isError: false, text: "x", at: nil))
        #expect(log.items.isEmpty)
    }

    @Test("Агент остановился: незакрытый шаг не считается ошибкой") func unfinished() {
        var log = ActivityLog()
        log.apply(use("a"))
        log.apply(use("b"))
        log.apply(.toolResult(id: "a", isError: false, text: nil, at: nil))
        log.closeRunning()
        #expect(steps(log).map(\.state) == [.done, .unfinished])
        #expect(log.current == nil)
    }

    @Test("Не больше 400 элементов") func limit() {
        var log = ActivityLog()
        for i in 0..<500 { log.apply(use("s\(i)")) }
        #expect(log.items.count == 400)
        #expect(log.items.first?.id == "s100")
        log.apply(.toolResult(id: "s499", isError: false, text: nil, at: nil))
        #expect(log.current?.id == "s498")
    }

    @Test("Длинный вывод обрезается, конец важнее") func longOutput() {
        var log = ActivityLog()
        log.apply(use("a"))
        log.apply(.toolResult(id: "a", isError: false, text: String(repeating: "x", count: 100_000) + "END", at: nil))
        let output = steps(log)[0].output ?? ""
        #expect(output.utf8.count < 5000)
        #expect(output.hasSuffix("END"))
    }

    @Test("Пояснения Claude попадают в ленту, пустые нет") func notes() {
        var log = ActivityLog()
        log.apply(.text("Now checking the tests.", at: t0))
        log.apply(.text("   \n", at: t0))
        #expect(log.items.count == 1)
    }

    @Test("Виды шагов", arguments: [
        ("Read", StepKind.read), ("Edit", .edit), ("MultiEdit", .edit), ("Write", .write), ("Bash", .shell),
        ("Grep", .search), ("Glob", .search), ("WebFetch", .web), ("WebSearch", .web), ("Agent", .helper),
        ("Skill", .helper), ("StructuredOutput", .answer), ("ToolSearch", .other), ("mcp__x__y", .other),
    ])
    func kinds(tool: String, expected: StepKind) {
        #expect(StepKind(tool: tool) == expected)
    }

    @Test("У команды в кратком описании нет её текста") func briefHasNoCommand() {
        var log = ActivityLog()
        log.apply(use("a", "Bash", input: ToolInput(note: "Deploy", command: "curl -H 'token: SECRET'")))
        let brief = log.current?.brief
        #expect(brief?.fileName == nil)
        #expect(!String(describing: brief).contains("SECRET"))
    }

    @Test("Дифф: только изменённые строки") func diff() {
        let old = "import x\nconst TVA = 0.196\nexport y"
        let new = "import x\nconst TVA\nexport y"
        let lines = DiffLines.changed(old: old, new: new)
        #expect(lines.map(\.kind) == [.removed, .added])
        #expect(lines.map(\.text) == ["const TVA = 0.196", "const TVA"])
        let stat = DiffLines.stat(old: old, new: new)
        #expect(stat?.added == 1)
        #expect(stat?.removed == 1)
    }

    @Test("Новый файл: только добавленные") func diffNewFile() {
        let lines = DiffLines.changed(old: nil, new: "a\nb")
        #expect(lines.map(\.kind) == [.added, .added])
        #expect(DiffLines.stat(old: nil, new: nil) == nil)
    }

    @Test("Счётчик правки попадает в шаг") func editStat() {
        var log = ActivityLog()
        log.apply(use("a", "Edit", input: ToolInput(target: "/x/a.ts", oldText: "1\n2", newText: "1\n3\n4")))
        #expect(log.current?.added == 2)
        #expect(log.current?.removed == 1)
    }

    @Test("JSON становится читаемым: настоящие переносы и отступы") func readableJSON() {
        let text = ResultFormat.pretty(#"{"summary":"first\nsecond","ok":true,"count":3,"none":null,"items":["x",{"name":"y"}]}"#)
        #expect(text.components(separatedBy: "\n") == [
            "count: 3",
            "items:",
            "  - x",
            "  - name: y",
            "none: —",
            "ok: true",
            "summary:",
            "  first",
            "  second",
        ])
    }

    @Test("JSON получает отступы, текст остаётся") func prettyResult() {
        #expect(ResultFormat.pretty(#"{"b":1,"a":[2]}"#).contains("\n"))
        #expect(ResultFormat.pretty("plain {text}") == "plain {text}")
        #expect(ResultFormat.pretty("{broken") == "{broken")
    }
}
