import Foundation
import Testing
@testable import BorisCore

@Suite("Уведомление об упавшем обычном агенте")
struct AgentFailureEventTests {
    private func agent(_ id: String, _ state: AgentState, session: String = "s1") -> AgentSnapshot {
        AgentSnapshot(id: id, sessionId: session, description: "Проверка", state: state, failure: state == .failed ? FailureInfo(failureClass: .limit, text: "limit") : nil, cwd: "/x/shop/web", entrypoint: "cli", lastWrite: t0)
    }

    private func session() -> SessionInfo {
        SessionInfo(sessionId: "s1", pid: 1, cwd: "/x/shop", entrypoint: "cli", status: "busy")
    }

    @Test("Обычный агент упал во время работы: одно уведомление, с проектом сессии и причиной")
    func fallenAgentIsNews() {
        var detector = EventDetector()
        _ = detector.detect(runs: [], sessions: [session()], usage: nil, now: t0, agents: [agent("a1", .running)])
        let events = detector.detect(runs: [], sessions: [session()], usage: nil, now: at(5), agents: [agent("a1", .failed)])
        let event = try? #require(events.first)
        #expect(events.count == 1)
        #expect(event?.kind == .failed)
        #expect(event?.name == "Проверка")
        #expect(event?.project == "shop")
        #expect(event?.topFailure == .limit)
        #expect(event?.agentsFailed == 1)
        #expect(detector.detect(runs: [], sessions: [session()], usage: nil, now: at(10), agents: [agent("a1", .failed)]).isEmpty)
    }

    @Test("Агент упал, пока Boris был закрыт: старое, без уведомления")
    func oldFailureIsQuiet() {
        var detector = EventDetector()
        #expect(detector.detect(runs: [], sessions: [], usage: nil, now: t0, agents: [agent("a1", .failed)]).isEmpty)
        #expect(detector.detect(runs: [], sessions: [], usage: nil, now: at(5), agents: [agent("a1", .failed)]).isEmpty)
    }

    @Test("Агент workflow, продолживший работу отдельно: зовётся по workflow, а упавший внутри workflow не повторяется")
    func continuedAgent() {
        var run = state(.stopped, agents: [AgentRecord(key: "k1", agentId: "x", label: "Сборка", state: .cancelled), AgentRecord(key: "k2", agentId: "z", label: "Отчёт", state: .failed)])
        run.fallenAgents = ["z"]
        var detector = EventDetector()
        _ = detector.detect(runs: [run], sessions: [], usage: nil, now: t0, agents: [agent("x", .running), agent("z", .running)])
        let events = detector.detect(runs: [run], sessions: [], usage: nil, now: at(5), agents: [agent("x", .failed), agent("z", .failed)])
        #expect(events.filter { $0.id.hasPrefix("agent|") }.map(\.name) == ["Сборка"])
    }

    @Test("В уведомлении о workflow упавших столько же, сколько на «Потерях»: остановленный вместе с ним не упал")
    func workflowCountsFallen() {
        let snapshot = run(final: final("killed", entries: [entry("error", id: "y", error: "Workflow aborted"), entry("error", id: "z", error: "You've hit your limit")]), finalModified: t0, journalModified: t0)
        var tracker = RunTracker()
        let state = resolve(&tracker, snapshot, now: at(1))
        #expect(state.failed == 2)
        #expect(state.fallenAgents == ["z"])
        var detector = EventDetector()
        var running = state
        running.status = .running
        _ = detector.detect(runs: [running], sessions: [], usage: nil, now: t0)
        #expect(detector.detect(runs: [state], sessions: [], usage: nil, now: at(2)).first?.agentsFailed == 1)
    }
}
