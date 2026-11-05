import Foundation
import Testing
@testable import BorisCore

/// The tests have no translation table, so the English source is what they see.
@Suite("Лента сессии")
struct SessionFeedTests {
    private func log(_ events: ActivityEvent...) -> ActivityLog {
        var log = ActivityLog()
        events.forEach { log.apply($0) }
        return log
    }

    private func use(_ id: String, _ tool: String = "Read", target: String? = nil, ago: Double = 0) -> ActivityEvent {
        .toolUse(id: id, tool: tool, input: ToolInput(target: target), at: at(ago))
    }

    private func done(_ id: String, error: Bool = false) -> ActivityEvent {
        .toolResult(id: id, isError: error, text: nil, at: nil)
    }

    private func entries(_ events: ActivityEvent...) -> [FeedEntry] {
        var log = ActivityLog()
        events.forEach { log.apply($0) }
        return SessionFeed.merged(sessionId: "s", logs: [AgentLog(agentId: nil, log: log)])
    }

    private func session(main: WorkState = .running, children: [WorkNode] = []) -> WorkSession {
        WorkSession(id: "s", state: main, root: WorkNode(id: "s", kind: .main, state: main, children: children))
    }

    // MARK: - Merging

    @Test("Записи агентов идут в порядке времени") func merging() {
        let main = log(use("a", ago: 1), use("c", ago: 3))
        let agent = log(use("b", ago: 2), use("d", ago: 4))
        let merged = SessionFeed.merged(sessionId: "s", logs: [AgentLog(agentId: nil, log: main), AgentLog(agentId: "x", log: agent)])
        #expect(merged.map(\.item.id) == ["a", "b", "c", "d"])
        #expect(merged.map(\.agentId) == [nil, "x", nil, "x"])
    }

    @Test("Запись без времени остаётся за предыдущей") func noTime() {
        let main = log(use("a", ago: 1), .text("note", at: nil), use("c", ago: 3))
        let merged = SessionFeed.merged(sessionId: "s", logs: [AgentLog(agentId: nil, log: main), AgentLog(agentId: "x", log: log(use("b", ago: 2)))])
        #expect(merged.map(\.item.id) == ["a", "note-1", "b", "c"])
    }

    @Test("Лимит оставляет самые новые записи") func limit() {
        let main = log(use("a", ago: 1), use("b", ago: 2), use("c", ago: 3))
        #expect(SessionFeed.merged(sessionId: "s", logs: [AgentLog(agentId: nil, log: main)], limit: 2).map(\.item.id) == ["b", "c"])
    }

    @Test("Записи разных агентов с одинаковым номером не сливаются") func uniqueIds() {
        let merged = SessionFeed.merged(sessionId: "s", logs: [AgentLog(agentId: nil, log: log(.text("a", at: nil))), AgentLog(agentId: "x", log: log(.text("b", at: nil)))])
        #expect(Set(merged.map(\.id)).count == 2)
    }

    @Test("Задача агента видна только в его собственной ленте") func agentPrompt() {
        let main = log(.prompt("person", at: at(1)))
        let agent = log(.prompt("task", at: at(2)), use("a", ago: 3))
        let merged = SessionFeed.merged(sessionId: "s", logs: [AgentLog(agentId: nil, log: main), AgentLog(agentId: "x", log: agent)])
        #expect(SessionFeed.visible(merged, agent: .all).map(\.item.id) == ["prompt-1", "a"])
        #expect(SessionFeed.visible(merged, agent: .one("x")).count == 2)
        #expect(SessionFeed.visible(merged, agent: .one(nil)).count == 1)
    }

    // MARK: - Thinking

    @Test("Занятый агент без открытого вызова думает") func thinking() {
        let busy = log(use("a"), done("a"))
        let calling = log(use("a"))
        #expect(SessionFeed.thinking(session: session(), logs: [AgentLog(agentId: nil, log: busy)]) == [nil])
        #expect(SessionFeed.thinking(session: session(), logs: [AgentLog(agentId: nil, log: calling)]).isEmpty)
        #expect(SessionFeed.thinking(session: session(main: .finished), logs: [AgentLog(agentId: nil, log: busy)]).isEmpty)
        #expect(SessionFeed.thinking(session: session(main: .waiting), logs: [AgentLog(agentId: nil, log: busy)]).isEmpty)
    }

    @Test("Думают и агенты под сессией, а сам workflow нет") func thinkingBelow() {
        let tree = session(main: .finished, children: [
            WorkNode(id: "helper", kind: .subagent, state: .running),
            WorkNode(id: "stopped", kind: .subagent, state: .finished),
            WorkNode(id: "wf", kind: .workflow, state: .running, children: [WorkNode(id: "worker", kind: .workflowAgent, state: .running)]),
        ])
        let idle = log(use("a"), done("a"))
        let logs = ["helper", "stopped", "wf", "worker"].map { AgentLog(agentId: $0, log: idle) }
        #expect(SessionFeed.thinking(session: tree, logs: logs) == ["helper", "worker"])
    }

    @Test("Открытый вызов ждёт человека, только когда ждёт сам главный агент") func waitingCall() throws {
        let open = try #require(entries(use("a")).first)
        let closed = try #require(entries(use("a"), done("a")).first)
        let ofAgent = FeedEntry(sessionId: "s", agentId: "x", item: open.item)
        #expect(SessionFeed.isWaiting(open, session: session(main: .waiting)))
        #expect(!SessionFeed.isWaiting(closed, session: session(main: .waiting)))
        #expect(!SessionFeed.isWaiting(ofAgent, session: session(main: .waiting)))
        #expect(!SessionFeed.isWaiting(open, session: session(main: .running)))
        #expect(!SessionFeed.isWaiting(open, session: nil))
        // The session is marked as waiting because of something under it, and the main agent's own call really runs.
        let below = WorkSession(id: "s", state: .waiting, root: WorkNode(id: "s", kind: .main, state: .running))
        #expect(!SessionFeed.isWaiting(open, session: below))
    }

    // MARK: - Scrolling

    @Test("Счётчик новых записей после прокрутки вверх") func newRecords() {
        #expect(SessionFeed.newCount(ids: ["a", "b", "c"], seen: nil) == 0)
        #expect(SessionFeed.newCount(ids: ["a", "b", "c"], seen: ["a", "b", "c"]) == 0)
        #expect(SessionFeed.newCount(ids: ["a", "b", "c"], seen: ["a"]) == 2)
    }

    @Test("Счётчик новых: исчезнувшая запись не делает новыми все остальные") func newRecordsWhenSomethingWent() {
        // The oldest were dropped while new ones came.
        #expect(SessionFeed.newCount(ids: ["c", "d", "e"], seen: ["a", "b", "c"]) == 2)
        // A filter was turned on: the rest is hidden, and nothing shown is new.
        #expect(SessionFeed.newCount(ids: ["b", "d"], seen: ["a", "b", "c", "d"]) == 0)
    }

    @Test("Счётчик новых в простом виде: идущий шаг закончился и влился в строку перед ним") func newRecordsWhenLinesJoin() {
        let before = FeedSummary.lines(entries(use("a", target: "/x/a"), done("a"), use("b", target: "/x/b")))
        #expect(before.count == 2)
        let after = FeedSummary.lines(entries(use("a", target: "/x/a"), done("a"), use("b", target: "/x/b"), done("b")))
        #expect(after.count == 1)
        #expect(SessionFeed.newCount(ids: after.map(\.id), seen: Set(before.map(\.id))) == 0)
    }

    @Test("Пока человек читает старое, записи у предела остаются на своих местах") func keepingOlder() {
        func feed(_ events: ActivityEvent...) -> [FeedEntry] {
            var log = ActivityLog()
            events.forEach { log.apply($0) }
            return SessionFeed.merged(sessionId: "s", logs: [AgentLog(agentId: nil, log: log)])
        }
        let shown = feed(use("a", ago: 1), use("b", ago: 2), use("c", ago: 3))
        // "a" has been dropped and "b" got its result.
        let next = feed(use("b", ago: 2), done("b"), use("c", ago: 3), use("d", ago: 4))
        let kept = SessionFeed.keepingOlder(shown, next: next)
        #expect(kept.map(\.item.id) == ["a", "b", "c", "d"])
        #expect(kept[1].step?.state == .done)
        #expect(SessionFeed.keepingOlder(next, next: next) == next)
        // A record dropped from the middle goes back to the middle, as agents reach their limits separately.
        let middle = feed(use("a", ago: 1), use("c", ago: 3))
        #expect(SessionFeed.keepingOlder(shown, next: middle).map(\.item.id) == ["a", "b", "c"])
    }

    // MARK: - Opening steps

    private func step(_ id: String, _ state: StepState) -> ActivityStep {
        ActivityStep(id: id, tool: "Bash", kind: .shell, input: ToolInput(), state: state)
    }

    @Test("Упавший и идущий шаги раскрыты сразу, остальные нет") func openByDefault() {
        let folding = FeedFolding()
        #expect(folding.isOpen(step("a", .running)))
        #expect(folding.isOpen(step("a", .failed)))
        #expect(!folding.isOpen(step("a", .done)))
        #expect(!folding.isOpen(step("a", .unfinished)))
    }

    @Test("Успешный шаг раскрывается по нажатию и сворачивается обратно") func openByClick() {
        var folding = FeedFolding()
        folding.toggle(step("a", .done))
        #expect(folding.isOpen(step("a", .done)))
        #expect(!folding.isOpen(step("b", .done)))
        folding.toggle(step("a", .done))
        #expect(!folding.isOpen(step("a", .done)))
    }

    @Test("То, что человек сделал руками, остаётся, когда шаг закончился") func foldingKeepsChoice() {
        var folding = FeedFolding()
        // Closed while running: it does not jump open when it finishes.
        folding.toggle(step("a", .running))
        #expect(!folding.isOpen(step("a", .running)))
        #expect(!folding.isOpen(step("a", .done)))
        #expect(!folding.isOpen(step("a", .failed)))
        // Left alone while running: it folds away when it finishes well.
        #expect(folding.isOpen(step("b", .running)))
        #expect(!folding.isOpen(step("b", .done)))
        // Opened after it finished, and a state change does not close it.
        folding.toggle(step("c", .done))
        #expect(folding.isOpen(step("c", .failed)))
    }

    // MARK: - An agent written to two files

    @Test("Два файла одного агента становятся одним журналом") func joinedParts() {
        let older = log(use("a", ago: 1), done("a"), .text("first", at: at(2)), use("open", ago: 3), use("both", ago: 4))
        let newer = log(use("both", ago: 5), done("both"), .text("second", at: at(6)), use("b", ago: 7))
        let joined = ActivityLog.joined([older, newer])
        #expect(joined.items.map(\.id) == ["a", "note-1", "open", "both", "1-note-1", "b"])
        let states = Dictionary(uniqueKeysWithValues: joined.items.compactMap { item -> (String, StepState)? in
            if case .step(let step) = item { return (step.id, step.state) }
            return nil
        })
        // The older file gets no more results, the call found in both is told by the newer one, and the newer file is still going.
        #expect(states["open"] == .unfinished)
        #expect(states["both"] == .done)
        #expect(states["b"] == .running)
        #expect(Set(joined.items.map(\.id)).count == joined.items.count)
    }

    @Test("Один файл и ни одного: ничего лишнего") func joinedSimple() {
        let one = log(use("a"))
        #expect(ActivityLog.joined([one]) == one)
        #expect(ActivityLog.joined([one]).current != nil)
        #expect(ActivityLog.joined([]).items.isEmpty)
    }

    @Test("Вместе не больше предела, и видно, что старое отброшено") func joinedLimit() {
        var first = ActivityLog()
        var second = ActivityLog()
        for index in 0..<300 {
            first.apply(use("a\(index)"))
            second.apply(use("b\(index)"))
        }
        let joined = ActivityLog.joined([first, second])
        #expect(joined.items.count == ActivityLog.limit)
        #expect(joined.items.last?.id == "b299")
        #expect(joined.dropped)
    }

    // MARK: - Long texts

    @Test("Обрезка длинного текста не ломает букву", arguments: [0, 1])
    func cutInsideLetter(shift: Int) {
        // Two bytes to a letter, so one of these two puts the limit inside a letter on each side.
        let text = String(repeating: "a", count: shift) + String(repeating: "я", count: 5000)
        var log = ActivityLog()
        log.apply(.prompt(text, at: nil))
        log.apply(.toolUse(id: "a", tool: "Bash", input: ToolInput(command: text), at: nil))
        log.apply(.toolResult(id: "a", isError: false, text: text, at: nil))
        guard case .prompt(_, let prompt, _) = log.items[0], case .step(let step) = log.items[1] else {
            Issue.record("no records")
            return
        }
        #expect(prompt.hasSuffix("\n…"))
        #expect(!prompt.contains("\u{FFFD}"))
        #expect(step.input.command?.contains("\u{FFFD}") == false)
        #expect(step.output?.hasPrefix("…\n") == true)
        #expect(step.output?.contains("\u{FFFD}") == false)
        #expect(step.isCut)
    }

    // MARK: - Changed files

    @Test("Правки одного файла складываются, неудачная не считается") func changedFiles() {
        let list = entries(
            .toolUse(id: "a", tool: "Edit", input: ToolInput(target: "/x/a.swift", oldText: "1", newText: "2"), at: at(1)),
            done("a"),
            .toolUse(id: "b", tool: "Write", input: ToolInput(target: "/x/b.swift", newText: "1\n2\n"), at: at(2)),
            done("b"),
            .toolUse(id: "c", tool: "Edit", input: ToolInput(target: "/x/a.swift", oldText: "x\ny", newText: "x\nz\nw"), at: at(3)),
            done("c"),
            .toolUse(id: "d", tool: "Edit", input: ToolInput(target: "/x/failed.swift", oldText: "1", newText: "2"), at: at(4)),
            done("d", error: true),
            use("e", "Read", target: "/x/read.swift", ago: 5)
        )
        let files = SessionFeed.changedFiles(list)
        #expect(files.map(\.name) == ["b.swift", "a.swift"])
        #expect(files[1].added == 3)
        #expect(files[1].removed == 2)
        #expect(files[1].steps.count == 2)
        #expect(files[0].added == 2)
    }

    // MARK: - Simple view

    @Test("12 чтений подряд это одна строка") func twelveReads() {
        var log = ActivityLog()
        for index in 0..<12 {
            log.apply(use("r\(index)", target: "/x/\(index).swift", ago: Double(index)))
            log.apply(done("r\(index)"))
        }
        let lines = FeedSummary.lines(SessionFeed.merged(sessionId: "s", logs: [AgentLog(agentId: nil, log: log)]))
        #expect(lines.map(\.text) == ["Read 12 files"])
        #expect(lines[0].state == .done)
        #expect(lines[0].files.count == 12)
        #expect(lines[0].at == at(0))
    }

    @Test("Один файл, прочитанный дважды, это один файл") func sameFileTwice() {
        let lines = FeedSummary.lines(entries(use("a", target: "/x/a"), done("a"), use("b", target: "/x/a"), done("b")))
        #expect(lines.map(\.text) == ["Read 1 file"])
    }

    @Test("Другое действие разрывает ряд, правки складываются") func grouping() {
        let lines = FeedSummary.lines(entries(
            use("a", target: "/x/a"), done("a"),
            .toolUse(id: "b", tool: "Edit", input: ToolInput(target: "/x/b", oldText: "1", newText: "2"), at: at(1)), done("b"),
            .toolUse(id: "c", tool: "Write", input: ToolInput(target: "/x/c", newText: "1\n"), at: at(2)), done("c"),
            use("d", target: "/x/d", ago: 3), done("d")
        ))
        #expect(lines.map(\.text) == ["Read 1 file", "Changed 2 files", "Read 1 file"])
        #expect(lines[1].added == 2)
        #expect(lines[1].removed == 1)
    }

    @Test("Заметки и запросы не разрывают ряд") func notesDoNotSplit() {
        let lines = FeedSummary.lines(entries(use("a", target: "/x/a"), done("a"), .text("note", at: nil), .prompt("more", at: nil), use("b", target: "/x/b"), done("b")))
        #expect(lines.map(\.text) == ["Read 2 files"])
    }

    @Test("Идущий шаг не склеивается с готовыми, упавший стоит отдельно") func states() {
        let lines = FeedSummary.lines(entries(
            use("a", target: "/x/a"), done("a"),
            use("b", target: "/x/b"), done("b", error: true),
            use("c", target: "/x/c"), done("c", error: true),
            use("d", target: "/x/d.swift"), done("d"),
            use("e", target: "/x/e.swift")
        ))
        #expect(lines.map(\.state) == [.done, .failed, .failed, .done, .running])
        #expect(lines[1].text == "Could not read a file")
        #expect(lines[4].text == "Reading e.swift")
    }

    @Test("Команда говорит своими словами, несколько команд считаются") func commands() {
        func command(_ id: String, _ note: String?) -> ActivityEvent {
            .toolUse(id: id, tool: "Bash", input: ToolInput(note: note, command: "SECRET"), at: at(0))
        }
        #expect(FeedSummary.lines(entries(command("a", "Runs the tests"), done("a"))).map(\.text) == ["Runs the tests"])
        #expect(FeedSummary.lines(entries(command("a", nil), done("a"))).map(\.text) == ["Ran 1 command"])
        #expect(FeedSummary.lines(entries(command("a", "One"), done("a"), command("b", "Two"), done("b"))).map(\.text) == ["Ran 2 commands"])
        #expect(FeedSummary.lines(entries(command("a", "Runs the tests"))).map(\.text) == ["Runs the tests"])
        #expect(FeedSummary.lines(entries(command("a", nil))).map(\.text) == ["Running a command"])
        #expect(FeedSummary.lines(entries(command("a", nil), done("a", error: true))).map(\.text) == ["A command failed"])
    }

    @Test("Незнакомое действие: пока идёт, это «Работает», потом его нет") func unknownAction() {
        #expect(FeedSummary.lines(entries(use("a", "SomethingNew"))).map(\.text) == ["Working"])
        #expect(FeedSummary.lines(entries(use("a", "SomethingNew"), done("a"))).isEmpty)
        #expect(FeedSummary.lines(entries(use("a", "StructuredOutput"), done("a"))).isEmpty)
    }

    @Test("Каждый помощник рассказан отдельно") func helpers() {
        func helper(_ id: String, _ note: String) -> ActivityEvent {
            .toolUse(id: id, tool: "Agent", input: ToolInput(note: note, command: "SECRET"), at: at(0))
        }
        let lines = FeedSummary.lines(entries(helper("a", "review"), done("a"), helper("b", "tests"), done("b"), use("c", "Skill", target: "pdf"), done("c")))
        #expect(lines.map(\.text) == ["Asked a helper: review", "Asked a helper: tests", "Used a skill"])
    }

    /// "Read" and "Edit" are also plain English words, so these are the names no plain sentence would have.
    @Test("В простых словах нет названий инструментов и текста команд", arguments: ["Bash", "Grep", "Glob", "WebSearch", "WebFetch", "Monitor", "mcp__x__y", "NotebookEdit", "ToolSearch", "TodoWrite"])
    func plainWords(tool: String) {
        for finished in [false, true] {
            var events: [ActivityEvent] = [.toolUse(id: "a", tool: tool, input: ToolInput(command: "SECRET"), at: at(0))]
            if finished { events.append(done("a")) }
            var log = ActivityLog()
            events.forEach { log.apply($0) }
            for line in FeedSummary.lines(SessionFeed.merged(sessionId: "s", logs: [AgentLog(agentId: nil, log: log)])) {
                #expect(!line.text.contains(tool))
                #expect(!line.text.contains("SECRET"))
            }
        }
    }

    // MARK: - Changes

    private let hunks = [DiffHunk(oldStart: 40, newStart: 40, lines: [" same", "-old one", "-old two", "+new one", "\\ No newline at end of file", " end"])]

    @Test("Счётчик и номера строк берутся из настоящего патча") func patch() {
        var log = ActivityLog()
        log.apply(.toolUse(id: "a", tool: "Write", input: ToolInput(target: "/x/a", newText: "whole\nfile\nthat\nguesses\nwrong"), at: nil))
        #expect(log.current?.added == 5)
        log.apply(done("a"))
        log.apply(.patch(id: "a", hunks))
        guard case .step(let step) = log.items[0] else {
            Issue.record("no step")
            return
        }
        #expect(step.added == 1)
        #expect(step.removed == 2)
        #expect(step.diff().map(\.number) == [41, 42, 41])
        #expect(step.diff().map(\.text) == ["old one", "old two", "new one"])
        #expect(step.diff(context: true).map(\.kind) == [.context, .removed, .removed, .added, .context])
        #expect(step.diff(context: true).map(\.number) == [40, 41, 42, 41, 42])
        #expect(!step.isCut)
    }

    @Test("Неудавшаяся правка ничего не изменила: строк для счёта нет, а текст попытки виден") func failedChange() {
        var log = ActivityLog()
        log.apply(.toolUse(id: "a", tool: "Edit", input: ToolInput(target: "/x/a", oldText: "1", newText: "2\n3"), at: nil))
        #expect(log.current?.added == 2)
        #expect(log.current?.removed == 1)
        log.apply(.toolResult(id: "a", isError: true, text: "String to replace not found", at: nil))
        guard case .step(let step) = log.items[0] else {
            Issue.record("no step")
            return
        }
        #expect(step.state == .failed)
        #expect(step.added == nil)
        #expect(step.removed == nil)
        #expect(!step.diff().isEmpty)
        let lines = FeedSummary.lines(SessionFeed.merged(sessionId: "s", logs: [AgentLog(agentId: nil, log: log)]))
        #expect(lines.first?.added == 0)
        #expect(lines.first?.removed == 0)
        // Only a change is forgotten: a failed command never had counts.
        var shell = ActivityLog()
        shell.apply(.toolUse(id: "b", tool: "Bash", input: ToolInput(command: "ls"), at: nil))
        shell.apply(.toolResult(id: "b", isError: true, text: "no", at: nil))
        #expect(shell.items.count == 1)
    }

    @Test("Длинная правка обрезана, а счётчик верный") func cutPatch() {
        let many = DiffHunk(oldStart: 1, newStart: 1, lines: (0..<5000).map { "+line number \($0)" })
        var log = ActivityLog()
        log.apply(.toolUse(id: "a", tool: "Write", input: ToolInput(target: "/x/a"), at: nil))
        log.apply(.patch(id: "a", [many]))
        guard case .step(let step) = log.items[0] else {
            Issue.record("no step")
            return
        }
        #expect(step.added == 5000)
        #expect(step.isCut)
        #expect(step.hunks.flatMap(\.lines).count < 1000)
    }

    @Test("Длинный текст на входе тоже помечен как обрезанный") func cutInput() {
        var log = ActivityLog()
        log.apply(.toolUse(id: "a", tool: "Write", input: ToolInput(target: "/x/a", newText: String(repeating: "line\n", count: 5000)), at: nil))
        #expect(log.current?.isCut == true)
        #expect(log.current?.added == 5000)
        log.apply(.toolUse(id: "b", tool: "Write", input: ToolInput(target: "/x/a", newText: "line\n"), at: nil))
        #expect(log.current?.isCut == false)
    }

    @Test("Новый файл: последний перенос строки не считается строкой, номера с единицы") func newFile() {
        let lines = DiffLines.changed(old: nil, new: "a\nb\n")
        #expect(lines.map(\.text) == ["a", "b"])
        #expect(lines.map(\.number) == [1, 2])
        #expect(DiffLines.stat(old: nil, new: "a\nb\n")?.added == 2)
        #expect(DiffLines.changed(old: "x\n", new: "y\n").map(\.number) == [nil, nil])
    }

    @Test("Без патча считаются только настоящие различия, общие строки в середине не правка") func comparison() {
        let old = "third\nkeep one\nkeep two\nsixth"
        let new = "changed third\nkeep one\nkeep two\nchanged sixth\nadded"
        let stat = DiffLines.stat(old: old, new: new)
        #expect(stat?.added == 3)
        #expect(stat?.removed == 2)
        let lines = DiffLines.changed(old: old, new: new)
        #expect(lines.map(\.kind) == [.removed, .added, .context, .context, .removed, .added, .added])
        #expect(lines.map(\.text) == ["third", "changed third", "keep one", "keep two", "sixth", "changed sixth", "added"])
    }

    @Test("Сравнение текстов: перестановка, только добавление, только удаление") func comparisonShapes() {
        #expect(DiffLines.stat(old: "a\nb", new: "b\na")?.added == 1)
        #expect(DiffLines.stat(old: "a\nb", new: "b\na")?.removed == 1)
        #expect(DiffLines.stat(old: "a\nc", new: "a\nb\nc")?.added == 1)
        #expect(DiffLines.stat(old: "a\nc", new: "a\nb\nc")?.removed == 0)
        #expect(DiffLines.stat(old: "a\nb\nc", new: "a\nc")?.removed == 1)
        #expect(DiffLines.stat(old: "same", new: "same")?.added == 0)
        #expect(DiffLines.stat(old: "", new: "a\nb")?.removed == 0)
    }

    @Test("Огромные тексты сравнивать слишком дорого: считаются заменой, и быстро") func comparisonLimit() {
        let old = (0..<3000).map { "old \($0)" }.joined(separator: "\n")
        let new = (0..<3000).map { "new \($0)" }.joined(separator: "\n")
        let began = ContinuousClock.now
        let stat = DiffLines.stat(old: old, new: new)
        #expect(ContinuousClock.now - began < .seconds(1))
        #expect(stat?.added == 3000)
        #expect(stat?.removed == 3000)
    }

    @Test("Файл перезаписан, а прежний текст неизвестен: счётчика нет") func overwritten() {
        var log = ActivityLog()
        log.apply(.toolUse(id: "a", tool: "Write", input: ToolInput(target: "/x/a", newText: "1\n2\n"), at: nil))
        log.apply(done("a"))
        log.apply(.overwrote(id: "a"))
        guard case .step(let step) = log.items[0] else {
            Issue.record("no step")
            return
        }
        #expect(step.added == nil)
        #expect(step.removed == nil)
        #expect(step.oldTextUnknown)
        #expect(!step.diff().isEmpty)
        // An edit knows both texts, so this says nothing about it.
        log.apply(.toolUse(id: "b", tool: "Edit", input: ToolInput(target: "/x/a", oldText: "1", newText: "2"), at: nil))
        log.apply(.overwrote(id: "b"))
        #expect(log.current?.added == 1)
        #expect(log.current?.oldTextUnknown == false)
    }

    @Test("Токены сообщения попадают в шаг") func tokens() {
        var log = ActivityLog()
        log.apply(use("a"))
        log.apply(.tokens(id: "a", TokenUsage(input: 5)))
        #expect(log.current?.tokens?.input == 5)
        log.apply(.tokens(id: "unknown", TokenUsage(input: 9)))
        #expect(log.items.count == 1)
    }

    // MARK: - Words for the technical view

    @Test("Что показывает строка шага") func targets() {
        func step(_ tool: String, _ input: ToolInput) -> ActivityStep {
            var log = ActivityLog()
            log.apply(.toolUse(id: "a", tool: tool, input: input, at: nil))
            return log.current ?? ActivityStep(id: "", tool: "", kind: .other, input: ToolInput(), state: .done)
        }
        #expect(WorkPhrases.target(step("Read", ToolInput(target: "/x/p/src/a.swift")), cwd: "/x/p") == "src/a.swift")
        #expect(WorkPhrases.target(step("Read", ToolInput(target: "/other/a.swift")), cwd: "/x/p") == "/other/a.swift")
        #expect(WorkPhrases.target(step("Read", ToolInput(target: "/x/pp/a.swift")), cwd: "/x/p") == "/x/pp/a.swift")
        #expect(WorkPhrases.target(step("Bash", ToolInput(note: "tests", command: "swift test\nsecond line")), cwd: nil) == "swift test")
        #expect(WorkPhrases.target(step("Agent", ToolInput(note: "review", command: "long prompt")), cwd: nil) == "review")
        #expect(WorkPhrases.target(step("Grep", ToolInput(target: "isExpired", note: "/x/p/src")), cwd: "/x/p") == "isExpired src")
        #expect(WorkPhrases.target(step("WebSearch", ToolInput(command: "swift crypto")), cwd: nil) == "swift crypto")
        #expect(WorkPhrases.target(step("mcp__pg__query", ToolInput(target: "pg · query", command: "sql: x")), cwd: nil) == "pg · query")
        #expect(WorkPhrases.target(step("ToolSearch", ToolInput(command: "query: x")), cwd: nil) == nil)
    }

    @Test("Время шага") func times() {
        let utc = TimeZone(identifier: "UTC") ?? .current
        #expect(WorkPhrases.stepDuration(0.44) == "0.4 s")
        #expect(WorkPhrases.stepDuration(59.9) == "59.9 s")
        #expect(WorkPhrases.stepDuration(83) == "1:23")
        #expect(WorkPhrases.stepDuration(3723) == "1:02:03")
        #expect(WorkPhrases.clock(14) == "0:14")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(WorkPhrases.time(now, now: now, seconds: true, timeZone: utc).count == 8)
        #expect(WorkPhrases.time(now, now: now, seconds: false, timeZone: utc).count == 5)
        #expect(WorkPhrases.time(now.addingTimeInterval(-2 * 86400), now: now, seconds: true, timeZone: utc).contains(" "))
    }

    @Test("Весь текст для копирования") func plain() {
        let list = entries(
            .prompt("Fix it", at: nil),
            .toolUse(id: "a", tool: "Read", input: ToolInput(target: "/x/p/a.swift"), at: nil),
            .toolResult(id: "a", isError: false, text: "file text", at: nil),
            .text("Done", at: nil),
            .toolUse(id: "b", tool: "Bash", input: ToolInput(command: "ls\n-l"), at: nil),
            .toolResult(id: "b", isError: false, text: "output", at: nil),
            .toolUse(id: "c", tool: "Edit", input: ToolInput(target: "/x/p/b.swift", oldText: "1", newText: "2"), at: nil)
        )
        let text = WorkPhrases.plainText(list, names: [:], cwd: "/x/p")
        #expect(text.contains("Fix it"))
        #expect(text.contains("Main agent · Read a.swift"))
        #expect(!text.contains("file text"))
        #expect(text.contains("Done"))
        #expect(text.contains("ls\n-l"))
        #expect(text.contains("output"))
        #expect(text.contains("- 1\n+ 2"))
    }

    // MARK: - Types

    @Test("Фильтр показывает только свой тип", arguments: [
        (ActivityFilter.read, ["Read", "Grep", "Glob"]),
        (.write, ["Edit", "Write", "MultiEdit", "NotebookEdit"]),
        (.command, ["Bash", "Monitor"]),
        (.web, ["WebSearch", "WebFetch"]),
        (.skill, ["Skill"]),
        (.mcp, ["mcp__postgres__query"]),
        (.startAgent, ["Agent", "Task", "Workflow"]),
    ])
    func filters(filter: ActivityFilter, tools: [String]) {
        let all = ["Read", "Grep", "Glob", "Edit", "Write", "MultiEdit", "NotebookEdit", "Bash", "Monitor", "WebSearch", "WebFetch", "Skill", "mcp__postgres__query", "Agent", "Task", "Workflow", "ToolSearch"]
        #expect(all.filter { filter.matches(WorkAction(tool: $0)) } == tools)
        #expect(all.allSatisfy { ActivityFilter.all.matches(WorkAction(tool: $0)) })
    }

    @Test("Фильтры страницы складываются, а записи без шага в неё не попадают") func query() throws {
        func session(_ id: String, _ environment: WorkEnvironment?, cwd: String?) -> WorkSession {
            WorkSession(id: id, environment: environment, cwd: cwd, state: .running, root: WorkNode(id: id, kind: .main, state: .running))
        }
        let inTerminal = session("a", .terminal, cwd: "/x/one")
        let inEditor = session("b", .vsCode, cwd: "/x/two")
        let noFolder = session("c", .cowork, cwd: nil)
        var log = ActivityLog()
        log.apply(.prompt("words", at: nil))
        log.apply(.text("note", at: nil))
        log.apply(.toolUse(id: "read", tool: "Read", input: ToolInput(target: "/x/f"), at: nil))
        log.apply(.toolUse(id: "shell", tool: "Bash", input: ToolInput(command: "ls"), at: nil))
        let items = SessionFeed.merged(sessionId: "a", logs: [AgentLog(agentId: nil, log: log)])

        func shown(_ query: ActivityQuery, _ owner: WorkSession?) -> [String] {
            items.filter { query.matches($0, session: owner) }.map(\.item.id)
        }
        #expect(shown(ActivityQuery(), inTerminal) == ["read", "shell"])
        #expect(shown(ActivityQuery(type: .command), inTerminal) == ["shell"])
        #expect(shown(ActivityQuery(project: "/x/one"), inTerminal) == ["read", "shell"])
        #expect(shown(ActivityQuery(project: "/x/one"), inEditor).isEmpty)
        #expect(shown(ActivityQuery(project: ""), noFolder) == ["read", "shell"])
        #expect(shown(ActivityQuery(project: ""), inTerminal).isEmpty)
        #expect(shown(ActivityQuery(place: "VS Code"), inEditor) == ["read", "shell"])
        #expect(shown(ActivityQuery(place: "VS Code"), inTerminal).isEmpty)
        #expect(shown(ActivityQuery(type: .read, project: "/x/two", place: "VS Code"), inEditor) == ["read"])
        #expect(shown(ActivityQuery(type: .read, project: "/x/one", place: "VS Code"), inEditor).isEmpty)
        // A session that has left the list has no folder and no known place.
        #expect(shown(ActivityQuery(project: ""), nil) == ["read", "shell"])
        #expect(shown(ActivityQuery(project: "/x/one"), nil).isEmpty)
    }

    @Test("Подпись типа на странице") func actionNames() {
        #expect(WorkPhrases.action(.mcp, tool: "mcp__a__b") == "MCP")
        #expect(WorkPhrases.action(.webFetch, tool: "WebFetch") == WorkPhrases.action(.webSearch, tool: "WebSearch"))
        #expect(WorkPhrases.action(.other, tool: "ToolSearch") == "ToolSearch")
        #expect(ActivityFilter.web.title == WorkPhrases.action(.webSearch, tool: "WebSearch"))
    }
}
