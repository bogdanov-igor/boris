import Foundation
import Testing
@testable import BorisCore

@Suite("hook-integration")
struct HookTests {
    @Test("Промпт и ответ не проходят дальше хука") func payloadIsReduced() {
        let reduced = HookPayload.reduce([
            "hook_event_name": "Stop",
            "session_id": "s",
            "prompt": "SECRET PROMPT",
            "last_assistant_message": "SECRET ANSWER",
            "tool_input": ["command": "SECRET CMD"],
            "transcript_path": "/secret",
        ])
        #expect(reduced.keys.sorted() == ["hook_event_name", "session_id"])
    }

    @Test("Аргументы инструмента только у запроса разрешения") func commandOnlyForPermission() {
        let pre = HookPayload.reduce(["hook_event_name": "PreToolUse", "session_id": "s", "tool_name": "Bash", "tool_input": ["command": "ls"]])
        #expect(pre["command_text"] == nil)
        let ask = HookPayload.reduce(["hook_event_name": "PermissionRequest", "session_id": "s", "tool_name": "Bash", "tool_input": ["command": "rm -rf x"]])
        #expect(ask["command_text"] as? String == "rm -rf x")
    }

    @Test("Код ошибки берётся из error и error_type") func errorFields() {
        #expect(HookPayload.reduce(["error": "billing_error"])["error_type"] as? String == "billing_error")
        #expect(HookPayload.reduce(["error_type": "rate_limit"])["error_type"] as? String == "rate_limit")
    }

    @Test("runId запуска из ответа инструмента Workflow") func workflowLaunch() {
        let reduced = HookPayload.reduce([
            "hook_event_name": "PostToolUse", "session_id": "s", "tool_name": "Workflow",
            "tool_response": ["runId": "wf_1", "summary": "SECRET"],
        ])
        #expect(reduced["run_id"] as? String == "wf_1")
        #expect(reduced["summary"] == nil)
        #expect(HookSignal(payload: reduced) == .workflowLaunched(session: "s", runId: "wf_1"))
    }

    @Test("Неизвестное событие игнорируется") func unknownEvent() {
        #expect(HookSignal(payload: ["hook_event_name": "BrandNewHook", "session_id": "s"]) == nil)
        #expect(HookSignal(payload: ["session_id": "s"]) == nil)
        #expect(HookSignal(payload: ["hook_event_name": "Notification", "session_id": "s", "notification_type": "auth_success"]) == nil)
    }

    @Test("Сигналы разбираются", arguments: [
        (["hook_event_name": "PreToolUse", "session_id": "s", "agent_id": "a", "tool_name": "Bash"], HookSignal.toolStarted(session: "s", agent: "a", tool: "Bash")),
        (["hook_event_name": "PostToolUse", "session_id": "s", "tool_name": "Read"], .toolFinished(session: "s", agent: nil, tool: "Read")),
        (["hook_event_name": "SubagentStop", "session_id": "s", "agent_id": "a"], .agentStopped(session: "s", agent: "a")),
        (["hook_event_name": "Stop", "session_id": "s"], .turnStopped(session: "s")),
        (["hook_event_name": "StopFailure", "session_id": "s", "error_type": "billing_error"], .stopFailure(session: "s", error: "billing_error")),
        (["hook_event_name": "SessionEnd", "session_id": "s", "reason": "clear"], .sessionEnded(session: "s", reason: "clear", cwd: nil)),
        (["hook_event_name": "SessionStart", "session_id": "s", "source": "clear"], .sessionStarted(session: "s", source: "clear", cwd: nil)),
        (["hook_event_name": "Notification", "session_id": "s", "notification_type": "permission_prompt"], .needsUser(session: "s")),
        (["hook_event_name": "PermissionRequest", "session_id": "s", "tool_name": "Bash"], .permissionAsked(session: "s", tool: "Bash")),
    ] as [([String: String], HookSignal)])
    func parsing(payload: [String: String], expected: HookSignal) {
        #expect(HookSignal(payload: payload) == expected)
    }

    @Test("Текущий инструмент: появляется и снимается") func currentTool() {
        var hooks = HookState()
        let agent = AgentRecord(key: "k", agentId: "a", state: .running)
        let runs = [RunState(runId: "r", sessionId: "s", name: "n", status: .running, lastWrite: t0, agents: [agent], phases: [PhaseGroup(title: "P", agents: [agent])])]
        hooks.apply(.toolStarted(session: "s", agent: "a", tool: "Bash"), now: t0)
        let shown = hooks.overlay(runs: runs)
        #expect(shown[0].agents[0].currentTool == "Bash")
        #expect(shown[0].phases[0].agents[0].currentTool == "Bash")
        hooks.apply(.toolFinished(session: "s", agent: "a", tool: "Bash"), now: at(1))
        #expect(hooks.overlay(runs: runs)[0].agents[0].currentTool == nil)
    }

    @Test("Сигнал хука не меняет статус запуска") func signalsDoNotSetStatus() {
        var hooks = HookState()
        hooks.apply(.agentStopped(session: "s", agent: "a"), now: t0)
        hooks.apply(.sessionEnded(session: "s", reason: "other", cwd: nil), now: t0)
        let agent = AgentRecord(key: "k", agentId: "a", state: .running)
        let run = RunState(runId: "r", sessionId: "s", name: "n", status: .running, lastWrite: t0, agents: [agent])
        let shown = hooks.overlay(runs: [run])
        #expect(shown[0].status == .running)
        #expect(shown[0].agents[0].state == .running)
    }

    @Test("Ожидание из хука считается ожиданием сессии") func waitingOverlay() {
        var hooks = HookState()
        hooks.apply(.permissionAsked(session: "s1", tool: "Bash"), now: t0)
        let shown = hooks.overlay(sessions: [session(status: "busy")])
        #expect(shown[0].status == "waiting")
        #expect(WaitingReason(shown[0].waitingFor) == .permission(tool: "Bash"))
        hooks.apply(.toolFinished(session: "s1", agent: nil, tool: "Bash"), now: at(1))
        #expect(hooks.overlay(sessions: [session(status: "busy")])[0].status == "busy")
    }

    @Test("Файл не назвал инструмент, хук знает") func hookNamesTheTool() {
        var hooks = HookState()
        hooks.apply(.permissionAsked(session: "s1", tool: "Bash"), now: t0)
        let shown = hooks.overlay(sessions: [session(status: "waiting", waitingFor: "permission prompt")])
        #expect(WaitingReason(shown[0].waitingFor) == .permission(tool: "Bash"))
    }

    @Test("Оба источника дают одно событие на эпизод") func oneEventFromBothSources() {
        var hooks = HookState()
        var detector = EventDetector()
        hooks.apply(.permissionAsked(session: "s1", tool: "Bash"), now: t0)
        hooks.apply(.needsUser(session: "s1"), now: at(1))
        let file = session(status: "waiting", waitingFor: "approve Bash: x")
        _ = detector.detect(runs: [], sessions: hooks.overlay(sessions: [file]), usage: nil, now: t0)
        let events = detector.detect(runs: [], sessions: hooks.overlay(sessions: [file]), usage: nil, now: at(6))
        #expect(events.map(\.kind) == [.waiting])
        #expect(detector.detect(runs: [], sessions: hooks.overlay(sessions: [file]), usage: nil, now: at(7)).isEmpty)
    }

    @Test("Ожидание снимается само через 10 минут") func waitingExpires() {
        var hooks = HookState()
        hooks.apply(.needsUser(session: "s1"), now: t0)
        hooks.expire(now: at(601))
        #expect(hooks.waiting.isEmpty)
    }

    @Test("Очистка связывает сессии") func clearLinksSessions() {
        var hooks = HookState()
        hooks.apply(.sessionEnded(session: "old", reason: "clear", cwd: "/w"), now: t0)
        hooks.apply(.sessionStarted(session: "new", source: "clear", cwd: "/w"), now: at(1))
        #expect(hooks.successor["old"] == "new")
        #expect(hooks.sessionEnd["old"] == "clear")
    }

    @Test("Обычный старт сессии не связывается") func normalStartNotLinked() {
        var hooks = HookState()
        hooks.apply(.sessionEnded(session: "old", reason: "other", cwd: "/w"), now: t0)
        hooks.apply(.sessionStarted(session: "new", source: "startup", cwd: "/w"), now: at(1))
        #expect(hooks.successor.isEmpty)
    }

    @Test("Ошибка API: своё событие, текста ошибки нет") func sessionError() {
        var detector = EventDetector()
        _ = detector.detect(runs: [], sessions: [], usage: nil, now: t0)
        let failure = HookState.Failure(session: "s1", error: "billing_error")
        let events = detector.detect(runs: [], sessions: [session()], usage: nil, now: t0, failures: [failure])
        #expect(events.map(\.kind) == [.sessionError])
        #expect(events[0].errorType == "billing_error")
    }

    @Test("Лимит из хука объединяется с событием о лимите") func hookLimit() {
        var detector = EventDetector()
        let failure = HookState.Failure(session: "s1", error: "rate_limit")
        let events = detector.detect(runs: [], sessions: [], usage: nil, now: t0, failures: [failure, failure])
        #expect(events.map(\.kind) == [.limitReached])
    }
}
