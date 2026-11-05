import Foundation
import Testing
@testable import BorisCore

@Suite("event-notifications")
struct EventTests {
    private func detect(_ d: inout EventDetector, _ runs: [RunState] = [], sessions: [SessionInfo] = [], usage: UsageSnapshot? = nil, now: Date = t0) -> [BorisEvent] {
        d.detect(runs: runs, sessions: sessions, usage: usage, now: now)
    }

    private func started() -> EventDetector {
        var d = EventDetector()
        _ = d.detect(runs: [], sessions: [], usage: nil, now: t0)
        return d
    }

    @Test("Завершение создаёт событие") func completion() {
        var d = started()
        _ = detect(&d, [state(.running)])
        let events = detect(&d, [state(.completed)], now: at(5))
        #expect(events.map(\.kind) == [.completed])
        #expect(events[0].name == "wf")
        #expect(events[0].project == "proj")
    }

    @Test("Статус не менялся: события нет") func noRepeat() {
        var d = started()
        _ = detect(&d, [state(.running)])
        _ = detect(&d, [state(.failed)], now: at(1))
        #expect(detect(&d, [state(.failed)], now: at(2)).isEmpty)
    }

    @Test("Новая попытка даёт новое событие") func newAttempt() {
        var d = started()
        _ = detect(&d, [state(.running)])
        #expect(detect(&d, [state(.completed)], now: at(1)).count == 1)
        _ = detect(&d, [state(.running, attempt: 2)], now: at(2))
        #expect(detect(&d, [state(.completed, attempt: 2)], now: at(3)).count == 1)
    }

    @Test("Возврат к работе без шума") func backToWork() {
        var d = started()
        _ = detect(&d, [state(.running)])
        #expect(detect(&d, [state(.silent)], now: at(1)).map(\.kind) == [.silent])
        #expect(detect(&d, [state(.running)], now: at(2)).isEmpty)
    }

    @Test("Запуск, появившийся уже завершённым во время работы, тоже новость") func newFinishedRun() {
        var d = started()
        #expect(detect(&d, [state(.completed)], now: at(1)).map(\.kind) == [.completed])
    }

    @Test("Перезагрузка: шедший запуск умер") func rebootReportsDeath() {
        var first = EventDetector()
        _ = first.detect(runs: [state(.running)], sessions: [], usage: nil, now: t0)
        var second = EventDetector(memory: first.memory)
        let events = second.detect(runs: [state(.interrupted)], sessions: [], usage: nil, now: at(100))
        #expect(events.map(\.kind) == [.interrupted])
        #expect(second.detect(runs: [state(.interrupted)], sessions: [], usage: nil, now: at(200)).isEmpty)
    }

    @Test("Старый неизвестный запуск: без уведомления") func oldUnknownRun() {
        var d = EventDetector()
        #expect(d.detect(runs: [state(.completed)], sessions: [], usage: nil, now: t0).isEmpty)
    }

    @Test("Запуск уже идёт при старте: уведомит о следующем") func runningAtStartup() {
        var d = EventDetector()
        #expect(d.detect(runs: [state(.running)], sessions: [], usage: nil, now: t0).isEmpty)
        #expect(d.detect(runs: [state(.failed)], sessions: [], usage: nil, now: at(1)).map(\.kind) == [.failed])
    }

    @Test("Молчание при старте считается увиденным") func silentAtStartup() {
        var d = EventDetector()
        #expect(d.detect(runs: [state(.silent)], sessions: [], usage: nil, now: t0).isEmpty)
    }

    @Test("Память переживает кодирование") func memoryRoundTrip() throws {
        var d = EventDetector()
        _ = d.detect(runs: [state(.running)], sessions: [], usage: nil, now: t0)
        let data = try JSONEncoder().encode(d.memory)
        let memory = try JSONDecoder().decode(DetectorMemory.self, from: data)
        #expect(memory == d.memory)
    }

    @Test("Волна: от трёх событий за 10 секунд одна сводка") func wave() {
        var grouper = WaveGrouper()
        let make = { (i: Int, s: TimeInterval) in BorisEvent(id: "e\(i)", kind: .interrupted, at: at(s)) }
        #expect(grouper.add(make(1, 0), now: at(0)) == .show(make(1, 0)))
        #expect(grouper.add(make(2, 1), now: at(1)) == .show(make(2, 1)))
        #expect(grouper.add(make(3, 2), now: at(2)) == .summarize(counts: [.interrupted: 3], replacing: ["e1", "e2", "e3"]))
        #expect(grouper.add(make(4, 3), now: at(3)) == .summarize(counts: [.interrupted: 4], replacing: ["e1", "e2", "e3", "e4"]))
    }

    @Test("События вне окна не группируются") func waveWindow() {
        var grouper = WaveGrouper()
        let make = { (i: Int, s: TimeInterval) in BorisEvent(id: "e\(i)", kind: .completed, at: at(s)) }
        _ = grouper.add(make(1, 0), now: at(0))
        _ = grouper.add(make(2, 1), now: at(1))
        #expect(grouper.add(make(3, 20), now: at(20)) == .show(make(3, 20)))
    }
}

@Suite("usage-limits")
struct UsageTests {
    private let failedLimit = AgentRecord(
        key: "k",
        state: .failed,
        failure: FailureClassifier.classify(LastRecord(isApiError: true, errorCode: "rate_limit", text: "You've hit your session limit · resets 1:30pm"))
    )

    @Test("Первый упавший агент сразу даёт событие со временем сброса") func firstFailure() {
        var d = EventDetector()
        let events = d.detect(runs: [state(.running, agents: [failedLimit])], sessions: [], usage: nil, now: t0)
        #expect(events.map(\.kind) == [.limitReached])
        #expect(events[0].resets == "1:30pm")
        #expect(events[0].affectedRuns == 1)
    }

    @Test("Шесть запусков разом: одно событие") func sixRuns() {
        var d = EventDetector()
        let runs = (0..<6).map { state(.running, id: "wf_\($0)", agents: [failedLimit]) }
        let events = d.detect(runs: runs, sessions: [], usage: nil, now: t0)
        #expect(events.count == 1)
        #expect(events[0].affectedRuns == 6)
        #expect(d.detect(runs: runs, sessions: [], usage: nil, now: at(60)).isEmpty)
    }

    @Test("Завершённые запуски не дают событие о лимите") func finishedRunsSilent() {
        var d = EventDetector()
        #expect(d.detect(runs: [state(.allAgentsFailed, agents: [failedLimit])], sessions: [], usage: nil, now: t0).isEmpty)
    }

    private func usage(_ percent: Double, resets: Date = at(1000)) -> UsageSnapshot {
        UsageSnapshot(fetchedAt: t0, windows: [UsageWindow(id: "seven_day", kind: .week, percent: percent, resetsAt: resets)])
    }

    @Test("Порог пройден: одно событие") func threshold() {
        var d = EventDetector()
        #expect(d.detect(runs: [], sessions: [], usage: usage(79), now: t0).isEmpty)
        #expect(d.detect(runs: [], sessions: [], usage: usage(81), now: at(1)).map(\.kind) == [.limitNear])
        #expect(d.detect(runs: [], sessions: [], usage: usage(82), now: at(2)).isEmpty)
    }

    @Test("Сброс окна разрешает новое событие") func thresholdAfterReset() {
        var d = EventDetector()
        _ = d.detect(runs: [], sessions: [], usage: usage(79), now: t0)
        _ = d.detect(runs: [], sessions: [], usage: usage(81), now: at(1))
        _ = d.detect(runs: [], sessions: [], usage: usage(5, resets: at(9000)), now: at(2))
        #expect(d.detect(runs: [], sessions: [], usage: usage(81, resets: at(9000)), now: at(3)).count == 1)
    }

    @Test("При первом взгляде порог не срабатывает") func noThresholdAtFirstLook() {
        var d = EventDetector()
        #expect(d.detect(runs: [], sessions: [], usage: usage(90), now: t0).isEmpty)
    }

    @Test("Возраст данных показывается только у старого кеша") func staleAge() {
        #expect(UsageSnapshot(fetchedAt: t0).staleAge(now: at(45 * 60)) == TimeInterval(2700))
        #expect(UsageSnapshot(fetchedAt: t0).staleAge(now: at(10 * 60)) == nil)
    }
}

@Suite("session-monitoring")
struct SessionTests {
    @Test("Причина ожидания", arguments: [
        ("approve Bash: rm -rf x", WaitingReason.permission(tool: "Bash")),
        ("permission prompt", .permission(tool: nil)),
        ("input needed", .input),
        ("dialog open", .dialog),
        ("goal proposal", .other("goal proposal")),
    ] as [(String, WaitingReason)])
    func reason(raw: String, expected: WaitingReason) {
        #expect(WaitingReason(raw) == expected)
    }

    @Test("Быстрый ответ: события нет") func quickAnswer() {
        var d = EventDetector()
        let waiting = session(status: "waiting", waitingFor: "approve Bash: x")
        #expect(d.detect(runs: [], sessions: [waiting], usage: nil, now: t0).isEmpty)
        #expect(d.detect(runs: [], sessions: [session(status: "busy")], usage: nil, now: at(3)).isEmpty)
    }

    @Test("Длинное ожидание: одно событие на эпизод, только инструмент") func longWait() {
        var d = EventDetector()
        let waiting = session(status: "waiting", waitingFor: "approve Bash: rm -rf secret")
        _ = d.detect(runs: [], sessions: [waiting], usage: nil, now: t0)
        let events = d.detect(runs: [], sessions: [waiting], usage: nil, now: at(6))
        #expect(events.map(\.kind) == [.waiting])
        #expect(events[0].toolName == "Bash")
        #expect(d.detect(runs: [], sessions: [waiting], usage: nil, now: at(7)).isEmpty)
        _ = d.detect(runs: [], sessions: [session(status: "busy")], usage: nil, now: at(8))
        _ = d.detect(runs: [], sessions: [waiting], usage: nil, now: at(9))
        #expect(d.detect(runs: [], sessions: [waiting], usage: nil, now: at(15)).count == 1)
    }

    @Test("Открытый диалог: без события") func dialogOpen() {
        var d = EventDetector()
        let waiting = session(status: "waiting", waitingFor: "dialog open")
        _ = d.detect(runs: [], sessions: [waiting], usage: nil, now: t0)
        #expect(d.detect(runs: [], sessions: [waiting], usage: nil, now: at(60)).isEmpty)
    }

    @Test("Длинный ход: событие") func longTurn() {
        var d = EventDetector()
        _ = d.detect(runs: [], sessions: [session(status: "busy")], usage: nil, now: t0)
        let events = d.detect(runs: [], sessions: [session(status: "idle")], usage: nil, now: at(12 * 60))
        #expect(events.map(\.kind) == [.sessionFinished])
    }

    @Test("Короткий ход: без события") func shortTurn() {
        var d = EventDetector()
        _ = d.detect(runs: [], sessions: [session(status: "busy")], usage: nil, now: t0)
        #expect(d.detect(runs: [], sessions: [session(status: "idle")], usage: nil, now: at(40)).isEmpty)
    }

    @Test("Закончился workflow: событие о сессии не дублируется") func turnAfterRun() {
        var d = EventDetector()
        _ = d.detect(runs: [state(.running)], sessions: [session(status: "busy")], usage: nil, now: t0)
        let events = d.detect(runs: [state(.completed)], sessions: [session(status: "idle")], usage: nil, now: at(12 * 60))
        #expect(events.map(\.kind) == [.completed])
    }
}
