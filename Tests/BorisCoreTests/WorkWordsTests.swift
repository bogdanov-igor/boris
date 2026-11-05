import BorisCore
import Foundation
import Testing

/// The tests have no translation table, so the English source is what they see.
@Suite("Слова и числа интерфейса")
struct WorkWordsTests {
    private let utc = TimeZone(identifier: "UTC") ?? .current

    @Test("Токены", arguments: [(950, "950"), (12_300, "12.3K"), (250_000, "250K"), (1_840_000, "1.84M"), (250_000_000, "250M")])
    func tokens(value: Int, text: String) {
        #expect(WorkFormat.tokens(value) == text)
    }

    @Test("Длительность и возраст")
    func durations() {
        #expect(WorkFormat.duration(30) == "less than a minute")
        #expect(WorkFormat.duration(420) == "7 min")
        #expect(WorkFormat.duration(3960) == "1 h 6 min")
        #expect(WorkFormat.duration(90000) == "1 d 1 h")
        #expect(WorkFormat.ago(5) == "5 s ago")
        #expect(WorkFormat.ago(720) == "12 min ago")
        #expect(WorkFormat.ago(7500) == "2 h 5 min ago")
        #expect(WorkFormat.percent(61.6) == "62%")
    }

    @Test("Сброс лимита: сегодня по часам, иначе по дню")
    func resets() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(WorkFormat.resets(now.addingTimeInterval(600), now: now, timeZone: utc).hasPrefix("resets at "))
        #expect(!WorkFormat.resets(now.addingTimeInterval(3 * 86400), now: now, timeZone: utc).contains(" at "))
        // 2026-11-05 is a Thursday.
        let thursday = Date(timeIntervalSince1970: 1_793_880_000)
        let days = ["resets Friday", "resets Saturday", "resets Sunday", "resets Monday", "resets Tuesday"]
        for (offset, day) in days.enumerated() {
            #expect(WorkFormat.resets(thursday.addingTimeInterval(Double(offset + 1) * 86400), now: thursday, timeZone: utc) == day)
        }
        #expect(WorkFormat.resets(thursday.addingTimeInterval(8 * 86400), now: thursday, timeZone: utc).hasPrefix("resets "))
        #expect(!WorkFormat.resets(thursday.addingTimeInterval(8 * 86400), now: thursday, timeZone: utc).contains("Friday"))
    }

    @Test("У каждого состояния есть слова для обоих режимов")
    func states() {
        for state in [WorkState.running, .silent, .waiting, .finished, .failed, .stopped, .interrupted] {
            #expect(!WorkPhrases.state(state, mode: .simple).isEmpty)
            #expect(!WorkPhrases.state(state, mode: .technical).isEmpty)
        }
        #expect(WorkPhrases.state(.silent, mode: .simple) != WorkPhrases.state(.silent, mode: .technical))
    }

    @Test("Простой режим говорит словами, технический называет инструмент")
    func steps() {
        let edit = StepBrief(kind: .edit, tool: "Edit", fileName: "auth.swift")
        #expect(WorkPhrases.step(edit, mode: .simple) == "Editing auth.swift")
        #expect(WorkPhrases.step(edit, mode: .technical) == "Edit auth.swift")
        let read = StepBrief(kind: .read, tool: "Read", fileName: "auth.swift")
        #expect(WorkPhrases.step(read, mode: .simple) == "Reading project files")
        #expect(WorkPhrases.step(read, mode: .technical) == "Read auth.swift")
        #expect(WorkPhrases.step(nil, mode: .simple) == nil)
        #expect(WorkPhrases.waiting(.permission(tool: "Bash"), mode: .simple) == "Waiting for you: wants to run a command")
        #expect(WorkPhrases.waiting(.permission(tool: "Bash"), mode: .technical) == "Bash is waiting for permission")
        #expect(WorkPhrases.agents(1) == "1 agent")
        #expect(WorkPhrases.agents(3) == "3 agents")
    }

    @Test("Строка сессии называет шаг и помощников")
    func sessionLine() {
        let helpers = (1...2).map { WorkNode(id: "h\($0)", kind: .subagent, state: .running) }
        let root = WorkNode(id: "m", kind: .main, state: .running, step: StepBrief(kind: .shell, tool: "Bash"), children: helpers)
        let session = WorkSession(id: "s", cwd: "/x/proj", state: .running, root: root)
        #expect(WorkPhrases.line(session, mode: .simple) == "Running a command · 2 agents")
        #expect(session.displayName == "proj")
        #expect(session.nameIsFolder)
    }

    @Test("Сессия с названием и без всего")
    func names() {
        let root = WorkNode(id: "m", kind: .main)
        let titled = WorkSession(id: "s", cwd: "/x/proj", title: "Отчёт", state: .running, root: root)
        #expect(titled.displayName == "Отчёт")
        #expect(!titled.nameIsFolder)
        let bare = WorkSession(id: "0123456789", state: .running, root: root)
        #expect(bare.displayName == "01234567")
    }
}
