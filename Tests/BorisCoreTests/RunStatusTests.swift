import Foundation
import Testing
@testable import BorisCore

private let processStart = t0.addingTimeInterval(-3600)
private let live: [Int32: Date] = [100: processStart]

@Suite("run-status")
struct RunStatusTests {
    @Test("Завершён: нет агентов с ошибкой") func completedClean() {
        var tracker = RunTracker()
        let r = resolve(&tracker, run(final: final("completed", entries: [entry("done"), entry("done")])), now: at(1))
        #expect(r.status == .completed)
    }

    @Test("Завершён с ошибками: упала часть") func completedWithErrors() {
        var tracker = RunTracker()
        let r = resolve(&tracker, run(final: final("completed", entries: [entry("done"), entry("error")])), now: at(1))
        #expect(r.status == .completedWithErrors)
        #expect(r.failed == 1)
    }

    @Test("Упали все агенты") func allFailed() {
        var tracker = RunTracker()
        let r = resolve(&tracker, run(final: final("completed", entries: [entry("error"), entry("error")])), now: at(1))
        #expect(r.status == .allAgentsFailed)
    }

    @Test("Агенты прошлой попытки не считаются упавшими") func previousAttemptAgents() {
        var tracker = RunTracker()
        let old = AgentRecord(key: "k", state: .failed)
        let r = resolve(&tracker, run(final: final("completed", entries: [entry("done")]), agents: [old]), now: at(1))
        #expect(r.status == .completed)
    }

    @Test("Без workflowProgress решает журнал") func journalFallback() {
        var tracker = RunTracker()
        let r = resolve(&tracker, run(final: final("completed"), agents: [AgentRecord(key: "a", state: .done), AgentRecord(key: "b", state: .failed)]), now: at(1))
        #expect(r.status == .completedWithErrors)
    }

    @Test("failed показывает первую строку ошибки") func failedRun() {
        var tracker = RunTracker()
        var report = final("failed")
        report.errorFirstLine = "TypeError: boom"
        let r = resolve(&tracker, run(final: report), now: at(1))
        #expect(r.status == .failed)
        #expect(r.errorFirstLine == "TypeError: boom")
    }

    @Test("killed это Остановлен, а не Прерван") func stopped() {
        var tracker = RunTracker()
        #expect(resolve(&tracker, run(final: final("killed")), now: at(1)).status == .stopped)
    }

    @Test("Неизвестный статус показан как есть и не считается идущим") func unknownStatus() {
        var tracker = RunTracker()
        let r = resolve(&tracker, run(final: final("paused")), now: at(1))
        #expect(r.status == .unknown("paused"))
        #expect(!r.status.isActive)
    }

    @Test("Устаревший итог игнорируется") func staleFinal() {
        var tracker = RunTracker()
        let snapshot = run(lastWrite: t0, final: final("completed"), finalModified: at(-100), journalModified: t0)
        let r = resolve(&tracker, snapshot, sessions: [session()], now: at(1), processes: live)
        #expect(r.status == .running)
    }

    @Test("Владелец жив при всех условиях") func ownerAlive() {
        var tracker = RunTracker()
        let r = resolve(&tracker, run(), sessions: [session()], now: at(1), processes: live)
        #expect(r.ownerAlive)
        #expect(r.status == .running)
    }

    @Test("PID занят другим процессом") func pidReused() {
        var tracker = RunTracker()
        let r = resolve(&tracker, run(lastWrite: at(-100)), sessions: [session()], now: at(1), processes: [100: processStart.addingTimeInterval(60)])
        #expect(!r.ownerAlive)
    }

    @Test("Допуск 2 секунды при сравнении старта") func clockTolerance() {
        var tracker = RunTracker()
        let r = resolve(&tracker, run(), sessions: [session()], now: at(1), processes: [100: processStart.addingTimeInterval(1.5)])
        #expect(r.ownerAlive)
    }

    @Test("Сессия возобновлена без запуска") func resumedWithoutRun() {
        var tracker = RunTracker()
        let newStart = at(500)
        let r = resolve(&tracker, run(lastWrite: t0), sessions: [session(start: newStart)], now: at(600), processes: [100: newStart])
        #expect(!r.ownerAlive)
        #expect(r.status == .interrupted)
    }

    @Test("Запуск возобновлён в новом процессе") func resumedInNewProcess() {
        var tracker = RunTracker()
        let newStart = at(500)
        let r = resolve(&tracker, run(lastWrite: at(550)), sessions: [session(start: newStart)], now: at(600), processes: [100: newStart])
        #expect(r.ownerAlive)
        #expect(r.status == .running)
    }

    @Test("Без procStart проверка старта пропускается") func noProcStart() {
        var tracker = RunTracker()
        let r = resolve(&tracker, run(), sessions: [session(start: nil)], now: at(1), processes: live)
        #expect(r.ownerAlive)
    }

    @Test("Запомненный процесс: сессия сменила sessionId") func rememberedProcess() {
        var tracker = RunTracker()
        _ = resolve(&tracker, run(), sessions: [session()], now: at(1), processes: live)
        let later = resolve(&tracker, run(lastWrite: at(10)), sessions: [session(id: "s2")], now: at(20), processes: live)
        #expect(later.ownerAlive)
        #expect(later.status == .running)
    }

    @Test("Прерван только после 8 секунд без владельца") func interruptedAfterGrace() {
        var tracker = RunTracker()
        _ = resolve(&tracker, run(), sessions: [session()], now: at(1), processes: live)
        let early = resolve(&tracker, run(), now: at(4))
        #expect(early.status == .running)
        let late = resolve(&tracker, run(), now: at(13))
        #expect(late.status == .interrupted)
    }

    @Test("Итог успел появиться за 8 секунд") func finalWithinGrace() {
        var tracker = RunTracker()
        _ = resolve(&tracker, run(), sessions: [session()], now: at(1), processes: live)
        _ = resolve(&tracker, run(), now: at(4))
        let r = resolve(&tracker, run(lastWrite: at(5), final: final("completed", entries: [entry("done")])), now: at(6))
        #expect(r.status == .completed)
    }

    @Test("Старая смерть при первом взгляде не ждёт 8 секунд") func oldDeathAtStartup() {
        var tracker = RunTracker()
        let r = resolve(&tracker, run(lastWrite: at(-1000)), now: t0)
        #expect(r.status == .interrupted)
    }

    @Test("Порог молчания") func silence() {
        var tracker = RunTracker()
        let r = resolve(&tracker, run(lastWrite: t0), sessions: [session()], now: at(13 * 60), processes: live)
        #expect(r.status == .silent)
    }

    @Test("Запись вернула запуск в работу") func backToRunning() {
        var tracker = RunTracker()
        _ = resolve(&tracker, run(lastWrite: t0), sessions: [session()], now: at(13 * 60), processes: live)
        let r = resolve(&tracker, run(lastWrite: at(13 * 60)), sessions: [session()], now: at(13 * 60 + 1), processes: live)
        #expect(r.status == .running)
    }

    @Test("Молчание не становится завершением") func silenceNeverFinishes() {
        var tracker = RunTracker()
        let r = resolve(&tracker, run(lastWrite: t0), sessions: [session()], now: at(100_000), processes: live)
        #expect(r.status == .silent)
    }

    @Test("Молчание считается с пробуждения") func wakeResetsSilence() {
        var tracker = RunTracker()
        tracker.lastWake = at(7200)
        let early = resolve(&tracker, run(lastWrite: t0), sessions: [session()], now: at(7200 + 60), processes: live)
        #expect(early.status == .running)
        let late = resolve(&tracker, run(lastWrite: t0), sessions: [session()], now: at(7200 + 13 * 60), processes: live)
        #expect(late.status == .silent)
    }

    @Test("Настраиваемый порог") func customThreshold() {
        var tracker = RunTracker(config: StatusConfig(silenceThreshold: 20 * 60))
        let r = resolve(&tracker, run(lastWrite: t0), sessions: [session()], now: at(13 * 60), processes: live)
        #expect(r.status == .running)
    }

    @Test("Возобновление увеличивает попытку") func attemptGrows() {
        var tracker = RunTracker()
        let done = run(lastWrite: t0, final: final("completed", entries: [entry("done")]), finalModified: t0, journalModified: t0)
        #expect(resolve(&tracker, done, now: at(1)).attempt == 1)
        let resumed = run(lastWrite: at(100), final: final("completed", entries: [entry("done")]), finalModified: t0, journalModified: at(100))
        let r = resolve(&tracker, resumed, sessions: [session()], now: at(101), processes: live)
        #expect(r.status == .running)
        #expect(r.attempt == 2)
    }

    @Test("Попытка не растёт, пока ничего не менялось") func attemptStable() {
        var tracker = RunTracker()
        let done = run(final: final("completed"))
        _ = resolve(&tracker, done, now: at(1))
        #expect(resolve(&tracker, done, now: at(2)).attempt == 1)
    }

    @Test("Завершение между двумя проверками тоже новая попытка") func attemptBetweenChecks() {
        var tracker = RunTracker()
        _ = resolve(&tracker, run(lastWrite: t0, final: final("completed"), finalModified: t0, journalModified: t0), now: at(1))
        let again = run(lastWrite: at(500), final: final("completed"), finalModified: at(500), journalModified: at(499))
        #expect(resolve(&tracker, again, now: at(501)).attempt == 2)
    }

    @Test("У завершившегося запуска нет агентов в работе") func noRunningAfterEnd() {
        var tracker = RunTracker()
        let report = final("killed", entries: [entry("progress"), entry("done")])
        let r = resolve(&tracker, run(final: report), now: at(1))
        #expect(r.running == 0)
        #expect(r.done == 1)
        #expect(r.agents[0].state == .cancelled)
        var dead = RunTracker()
        let lost = resolve(&dead, run(lastWrite: at(-1000), agents: [AgentRecord(key: "k", state: .running)]), now: t0)
        #expect(lost.status == .interrupted)
        #expect(lost.running == 0)
    }

    @Test("Разбор procStart в UTC") func parseProcStart() {
        let date = ProcStart.parse("Wed Nov  4 06:51:16 2026")
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let c = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date!)
        #expect([c.year, c.month, c.day, c.hour, c.minute, c.second] == [2026, 11, 4, 6, 51, 16])
        #expect(ProcStart.parse("garbage") == nil)
        #expect(ProcStart.parse(nil) == nil)
    }
}

@Suite("session-monitoring: сессии без файла")
struct UnlistedOwnerTests {
    @Test("Запуск сессии без файла не прерван, пока она в списке; без неё прерван") func unlistedOwner() {
        var tracker = RunTracker()
        let session = SessionInfo(sessionId: "s1", pid: 0, status: "busy")
        // The process table must not be asked: number zero is the kernel, which is always there.
        let world = WorldSnapshot(takenAt: at(600), sessions: [session], runs: [run(lastWrite: at(590))])
        let alive = tracker.resolve(world) { _ in Issue.record("no process to look at"); return nil }
        #expect(alive.first?.status == .running)
        #expect(alive.first?.ownerAlive == true)

        let gone = WorldSnapshot(takenAt: at(700), sessions: [], runs: [run(lastWrite: at(590))])
        _ = tracker.resolve(gone) { _ in nil }
        let later = WorldSnapshot(takenAt: at(800), sessions: [], runs: [run(lastWrite: at(590))])
        #expect(tracker.resolve(later) { _ in nil }.first?.status == .interrupted)
    }
}
