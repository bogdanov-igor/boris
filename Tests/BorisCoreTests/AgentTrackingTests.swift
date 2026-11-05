import Foundation
import Testing
@testable import BorisCore

@Suite("agent-tracking")
struct AgentTrackingTests {
    private func tally(_ events: [JournalEvent]) -> [AgentRecord] {
        var t = AgentTally()
        events.forEach { t.add($0) }
        return t.agents
    }

    @Test("Повторный старт: один агент, готов") func repeatedStart() {
        let agents = tally([
            JournalEvent(kind: .started, key: "k", agentId: "a1"),
            JournalEvent(kind: .started, key: "k", agentId: "a2"),
            JournalEvent(kind: .result, key: "k", agentId: "a2"),
        ])
        #expect(agents.count == 1)
        #expect(agents[0].state == .done)
        #expect(agents[0].attempts == 2)
        #expect(agents[0].agentId == "a2")
    }

    @Test("Результат после ошибки") func resultAfterFailure() {
        let agents = tally([
            JournalEvent(kind: .started, key: "k"),
            JournalEvent(kind: .failed, key: "k"),
            JournalEvent(kind: .result, key: "k"),
        ])
        #expect(agents[0].state == .done)
    }

    @Test("Попытка 3 в работе, а не ошибка") func attemptThree() {
        let agents = tally([JournalEvent(kind: .started, key: "k"), JournalEvent(kind: .started, key: "k"), JournalEvent(kind: .started, key: "k")])
        #expect(agents[0].state == .running)
        #expect(agents[0].attempts == 3)
    }

    @Test("Неизвестное событие запоминается, остальные обрабатываются") func unknownEvent() {
        var t = AgentTally()
        t.add(JournalEvent(kind: .unknown("paused"), key: "k"))
        t.add(JournalEvent(kind: .started, key: "k"))
        #expect(t.unknownEvents == ["paused"])
        #expect(t.agents.count == 1)
    }

    @Test("Журнал и итог расходятся: верим итогу") func finalWins() {
        var tracker = RunTracker()
        let journal = (0..<52).map { AgentRecord(key: "k\($0)", state: .running) }
        var report = final("completed", entries: (0..<33).map { _ in entry("done") })
        report.agentCount = 33
        let r = resolve(&tracker, run(final: report, agents: journal), now: at(1))
        #expect(r.total == 33)
        #expect(r.agents.count == 33)
    }

    @Test("Фазы во время запуска") func phasesWhileRunning() {
        let agents = [AgentRecord(key: "a", phase: "Search", state: .done), AgentRecord(key: "b", phase: "Verify", state: .running)]
        let groups = RunPresentation.phases(agents: agents, plan: ["Search", "Verify", "Report"], isRunning: true)
        #expect(groups.map(\.title) == ["Search", "Verify", "Report"])
        #expect(groups[1].isCurrent)
        #expect(groups[1].agents.map(\.key) == ["b"])
        #expect(groups[2].agents.isEmpty)
    }

    @Test("Плана нет: общий список") func noPlan() {
        let groups = RunPresentation.phases(agents: [AgentRecord(key: "a")], plan: [], isRunning: true)
        #expect(groups.count == 1)
        #expect(groups[0].title == nil)
    }

    @Test("Фаза вне плана идёт после плана") func phaseOutsidePlan() {
        let groups = RunPresentation.phases(agents: [AgentRecord(key: "a", phase: "X")], plan: ["Search"], isRunning: false)
        #expect(groups.map(\.title) == ["Search", "X"])
    }

    @Test("Классы причин", arguments: [
        ("You've hit your session limit · resets 1:30pm (Europe/London)", "rate_limit", true, FailureClass.limit),
        ("You've hit your monthly spend limit · raise it at https://claude.ai/settings/usage", "rate_limit", true, .limit),
        ("API Error: Can't reach the API server — check your internet or DNS (ENOTFOUND)", "server_error", true, .network),
        ("Request timed out", "server_error", true, .network),
        ("API Error: Connection dropped (ECONNRESET).", "server_error", true, .network),
        ("API Error: Your computer went to sleep mid-response.", "server_error", true, .sleep),
        ("API Error: Connection lost while your computer was asleep", "server_error", true, .sleep),
        ("stalled — no progress for 600000ms", nil, false, .stall),
        ("something else entirely", "weird", true, .api),
        ("no idea", nil, false, .unknown),
    ] as [(String, String?, Bool, FailureClass)])
    func classes(text: String, code: String?, isApi: Bool, expected: FailureClass) {
        let info = FailureClassifier.classify(LastRecord(isApiError: isApi, errorCode: code, text: text))
        #expect(info.failureClass == expected)
    }

    @Test("Лимит: вид и время сброса") func limitDetails() {
        let session = FailureClassifier.classify(LastRecord(isApiError: true, errorCode: "rate_limit", text: "You've hit your session limit · resets 1:30pm (Europe/London)"))
        #expect(session.limitKind == .session)
        #expect(session.resets == "1:30pm (Europe/London)")
        let monthly = FailureClassifier.classify(nil, reason: "You've hit your monthly spend limit. Switch to another model")
        #expect(monthly.failureClass == .limit)
        #expect(monthly.limitKind == .monthly)
        #expect(monthly.resets == nil)
    }

    @Test("Самая частая причина") func topFailure() {
        let agents = [
            AgentRecord(key: "a", state: .failed, failure: FailureInfo(failureClass: .limit)),
            AgentRecord(key: "b", state: .failed, failure: FailureInfo(failureClass: .limit)),
            AgentRecord(key: "c", state: .failed, failure: FailureInfo(failureClass: .network)),
            AgentRecord(key: "d", state: .done),
        ]
        #expect(RunPresentation.topFailure(agents) == .limit)
        #expect(RunPresentation.topFailure([AgentRecord(key: "x")]) == nil)
    }

    @Test("Контекст: вход и оба кеша, без выхода") func contextTokens() {
        #expect(TokenUsage(input: 10, output: 999, cacheRead: 100, cacheWrite: 1000).context == 1110)
    }

    @Test("Сообщение записано несколько раз: последняя запись") func ledgerDedupes() {
        var ledger = TokenLedger()
        for out in [10, 50, 200, 300, 500] {
            ledger.add(messageId: "m1", usage: TokenUsage(input: 5, output: out))
        }
        ledger.add(messageId: "m2", usage: TokenUsage(input: 1, output: 1))
        #expect(ledger.total == TokenUsage(input: 6, output: 501))
    }
}
