import BorisCore
import Foundation
import Testing

@Suite("Дерево агентов списком")
struct AgentTreeTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func run(_ phases: [PhaseGroup], status: RunStatus = .running, plan: [String] = []) -> WorkflowDetails {
        var state = RunState(runId: "wf", sessionId: "s", name: "Аудит", status: status, lastWrite: now, phases: phases, plannedPhases: plan)
        state.total = phases.reduce(0) { $0 + $1.agents.count }
        return WorkflowDetails(state)
    }

    private func agent(_ id: String, phase: String?, state: WorkState = .finished) -> WorkNode {
        WorkNode(id: id, kind: .workflowAgent, parentId: "wf", title: id, state: state, phase: phase)
    }

    private func workflow(_ agents: [WorkNode], phases: [String?], current: String? = nil, status: RunStatus = .running, plan: [String] = []) -> WorkNode {
        let groups = phases.map { PhaseGroup(title: $0, agents: [], isCurrent: $0 == current) }
        return WorkNode(id: "wf", kind: .workflow, parentId: "s", title: "Аудит", workflow: run(groups, status: status, plan: plan), children: agents)
    }

    @Test("Субагент субагента стоит на уровень глубже своего родителя")
    func nestedDepth() {
        let inner = WorkNode(id: "b", kind: .subagent, parentId: "a")
        let outer = WorkNode(id: "a", kind: .subagent, parentId: "s", children: [inner])
        let root = WorkNode(id: "s", kind: .main, children: [outer])
        let rows = AgentTree.rows(root: root, expanded: [])
        #expect(rows.map(\.id) == ["s", "a", "b"])
        #expect(rows.map(\.depth) == [0, 1, 2])
    }

    @Test("Фазы свёрнуты, по нажатию раскрывается только нажатая")
    func foldedPhases() throws {
        let agents = (1...100).map { agent("a\($0)", phase: $0 <= 60 ? "Поиск" : "Проверка") }
        let root = WorkNode(id: "s", kind: .main, children: [workflow(agents, phases: ["Поиск", "Проверка"])])

        let folded = AgentTree.rows(root: root, expanded: [])
        // Main agent, the workflow and its two phases, however many agents there are.
        #expect(folded.count == 4)

        let key = AgentTree.phaseKey(workflow: "wf", phase: "Проверка")
        let open = AgentTree.rows(root: root, expanded: [key])
        #expect(open.count == 44)
        #expect(open.last?.id == "a100")
        #expect(open.contains { $0.id == "a1" } == false)
    }

    @Test("Края карточки workflow идут по его строкам")
    func cardEdges() {
        let root = WorkNode(id: "s", kind: .main, children: [workflow([agent("a1", phase: "Поиск")], phases: ["Поиск"])])
        let rows = AgentTree.rows(root: root, expanded: [AgentTree.phaseKey(workflow: "wf", phase: "Поиск")])
        #expect(rows.map(\.edge) == [.none, .top, .middle, .bottom])
        let bare = WorkNode(id: "s", kind: .main, children: [workflow([], phases: [])])
        #expect(AgentTree.rows(root: bare, expanded: []).map(\.edge) == [.none, .whole])
    }

    @Test("Счётчики фазы складываются по состояниям агентов")
    func phaseCounts() throws {
        let node = workflow([
            agent("a", phase: "Поиск", state: .finished),
            agent("b", phase: "Поиск", state: .failed),
            agent("c", phase: "Поиск", state: .running),
            agent("d", phase: "Поиск", state: .silent),
            agent("e", phase: "Поиск", state: .stopped),
        ], phases: ["Поиск"], current: "Поиск")
        let phase = try #require(node.phases.first)
        #expect((phase.done, phase.failed, phase.running, phase.cancelled) == (1, 1, 2, 1))
        #expect(phase.total == 5)
        #expect(phase.isCurrent)
    }

    @Test("Вложенный агент считается в фазе своего родителя")
    func nestedCountsInPhase() throws {
        var parent = agent("a", phase: "Поиск", state: .finished)
        parent.children = [WorkNode(id: "b", kind: .subagent, parentId: "a", state: .failed)]
        let phase = try #require(workflow([parent], phases: ["Поиск"]).phases.first)
        #expect((phase.done, phase.failed, phase.total) == (1, 1, 2))
    }

    @Test("Фаза впереди видна, пока запуск идёт, и исчезает в конце")
    func phaseAhead() {
        let agents = [agent("a", phase: "Поиск")]
        let going = workflow(agents, phases: ["Поиск", "Итог"]).phases
        #expect(going.map(\.title) == ["Поиск", "Итог"])
        #expect(going.last?.isAhead == true)
        let ended = workflow(agents, phases: ["Поиск", "Итог"], status: .completed).phases
        #expect(ended.map(\.title) == ["Поиск"])
    }

    @Test("Запуск без агентов показывает план скрипта")
    func onlyPlan() {
        let phases = workflow([], phases: [], plan: ["Поиск", "Итог"]).phases
        #expect(phases.map(\.title) == ["Поиск", "Итог"])
        #expect(phases.allSatisfy { $0.isAhead })
    }

    @Test("Агенты без фазы не теряются")
    func noPhase() {
        let phases = workflow([agent("a", phase: nil), agent("b", phase: "Поиск")], phases: ["Поиск"]).phases
        #expect(phases.map(\.title) == ["Поиск", nil])
        #expect(phases.reduce(0) { $0 + $1.total } == 2)
    }
}

@Suite("Сейчас и сбои")
struct NowDigestTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func session(_ id: String = "s", state: WorkState, last: TimeInterval = -60, children: [WorkNode] = [], rootState: WorkState? = nil) -> WorkSession {
        WorkSession(id: id, cwd: "/x/proj", state: state, lastActivity: now.addingTimeInterval(last), root: WorkNode(id: id, kind: .main, state: rootState ?? state, children: children))
    }

    private func digest(_ sessions: WorkSession...) -> NowDigest {
        NowDigest(WorkModel(projects: [WorkProject(path: "/x/proj", sessions: sessions)]), now: now)
    }

    @Test("Занятая сессия без workflow это работа, а не «ничего не идёт»")
    func busyWithoutWorkflow() throws {
        let result = digest(session(state: .running))
        #expect(!result.isQuiet)
        #expect(result.active.count == 1)
        let busy = try #require(result.active.first)
        #expect(WorkPhrases.line(busy, mode: .simple) == "Working")
        #expect(WorkPhrases.occupation(busy, mode: .simple) == "Working")
        #expect(WorkPhrases.occupation(busy, mode: .technical) == "Running")
    }

    @Test("Завершённая сессия не считается активной")
    func finishedIsQuiet() {
        let result = digest(session(state: .finished))
        #expect(result.isQuiet)
        #expect(result.finished.count == 1)
    }

    @Test("Сбой workflow это одна запись, сколько бы агентов ни упало")
    func oneLineForWorkflow() throws {
        let agents = (1...12).map { WorkNode(id: "a\($0)", kind: .workflowAgent, state: .failed, failure: FailureInfo(failureClass: .limit, resets: "18:40")) }
        let run = RunState(runId: "wf", sessionId: "s", name: "Миграция", status: .allAgentsFailed, lastWrite: now, topFailure: .limit, total: 12)
        let node = WorkNode(id: "wf", kind: .workflow, title: "Миграция", state: .failed, workflow: WorkflowDetails(run), lastActivity: now, children: agents)
        let failed = session(state: .finished, children: [node])
        let result = digest(failed)
        #expect(result.failures.count == 1)
        #expect(failed.failureCount == 12)
        let failure = try #require(result.failures.first)
        #expect(WorkPhrases.failure(failure, mode: .simple) == "Did not work: ran out of limit, resets at 18:40")
        #expect(WorkPhrases.failure(failure, mode: .technical) == "All agents failed · 12 of 12 · limit, resets at 18:40")
    }

    @Test("Простой режим называет причину сбоя агента и подсказывает, что делать")
    func agentFailureWords() throws {
        let broken = WorkNode(id: "a", kind: .subagent, title: "Миграции", state: .failed, failure: FailureInfo(failureClass: .api), lastActivity: now)
        let failure = try #require(session(state: .finished, children: [broken]).failures.first)
        #expect(WorkPhrases.failure(failure, mode: .simple) == "Claude is overloaded right now, try again later")
        #expect(WorkPhrases.failure(failure, mode: .technical) == "API error")
        #expect(WorkPhrases.failureName(failure, mode: .simple) == "Helper «Миграции»")
        #expect(WorkPhrases.failureName(failure, mode: .technical) == "Subagent «Миграции»")
    }

    @Test("Неизвестный сбой")
    func unknownFailure() {
        #expect(WorkPhrases.hint(.unknown, resets: nil) == "Something went wrong")
        #expect(WorkPhrases.hint(nil, resets: nil) == "Something went wrong")
    }

    @Test("Процесс закрылся")
    func cutOff() throws {
        let failure = try #require(session(state: .interrupted).failures.first)
        #expect(WorkPhrases.failure(failure, mode: .simple) == "Cut off: Claude Code closed")
    }

    @Test("Старые сбои и давно завершённые сессии не свежие")
    func oldIsNotFresh() {
        let old = session("old", state: .interrupted, last: -7 * 3600)
        let result = digest(old, session("done", state: .finished, last: -4 * 3600))
        #expect(result.failures.isEmpty)
        #expect(result.finished.isEmpty)
        #expect(result.isQuiet)
    }

    @Test("Остановленный workflow это не сбой")
    func stoppedIsNotFailure() {
        let run = RunState(runId: "wf", sessionId: "s", name: "x", status: .stopped, lastWrite: now)
        let node = WorkNode(id: "wf", kind: .workflow, state: .stopped, workflow: WorkflowDetails(run), lastActivity: now)
        #expect(session(state: .finished, children: [node]).failures.isEmpty)
    }
}

@Suite("Слова о workflow")
struct WorkflowWordsTests {
    @Test("У каждого статуса свои слова в каждом режиме", arguments: [
        (RunStatus.running, "Working", "Running"),
        (.silent, "No news for a while", "Silent"),
        (.completed, "Done", "Finished"),
        (.completedWithErrors, "Partly done", "Finished with errors"),
        (.allAgentsFailed, "Did not work", "All agents failed"),
        (.failed, "Broke", "Failed"),
        (.stopped, "Stopped", "Halted"),
        (.interrupted, "Cut off", "Interrupted"),
    ])
    func statuses(status: RunStatus, simple: String, technical: String) {
        #expect(WorkPhrases.workflow(status, mode: .simple) == simple)
        #expect(WorkPhrases.workflow(status, mode: .technical) == technical)
    }

    @Test("Причины простыми словами", arguments: [
        (FailureClass.limit, "ran out of limit"),
        (.network, "no connection to Claude"),
        (.sleep, "the Mac went to sleep"),
        (.stall, "the task got stuck"),
        (.api, "a Claude error"),
        (.unknown, "reason unknown"),
    ])
    func causes(cause: FailureClass, words: String) {
        #expect(WorkPhrases.cause(cause, mode: .simple) == words)
    }

    @Test("Простой режим не показывает ни идентификатор, ни машинное имя")
    func names() {
        #expect(WorkPhrases.workflowName("wf_123", mode: .simple) == "A big task")
        #expect(WorkPhrases.workflowName("wf_123", mode: .technical) == "wf_123")
        #expect(WorkPhrases.workflowName(nil, mode: .technical) == "Workflow")
        #expect(WorkPhrases.workflowName("deps-audit", mode: .simple) == "Deps audit")
        #expect(WorkPhrases.workflowName("deps-audit", mode: .technical) == "deps-audit")
        #expect(WorkPhrases.workflowName("Аудит зависимостей", mode: .simple) == "Аудит зависимостей")
    }

    @Test("Имя агента не повторяет фазу из заголовка над ним")
    func agentName() {
        #expect(WorkPhrases.agentName(WorkNode(id: "a", kind: .workflowAgent, title: "search:form", phase: "Search")) == "form")
        #expect(WorkPhrases.agentName(WorkNode(id: "a", kind: .main)) == "Main agent")
        #expect(WorkPhrases.agentName(WorkNode(id: "a", kind: .subagent, agentType: "scout")) == "scout")
        #expect(WorkPhrases.agentName(WorkNode(id: "a", kind: .fork)) == "Fork")
    }

    @Test("Агент работает, но шага нет: думает, а не молчит")
    func activity() {
        #expect(WorkPhrases.agentActivity(WorkNode(id: "a", kind: .subagent, state: .running), mode: .technical) == "Thinking…")
        let reading = WorkNode(id: "a", kind: .subagent, state: .running, step: StepBrief(kind: .read, tool: "Read", fileName: "x.swift"))
        #expect(WorkPhrases.agentActivity(reading, mode: .technical) == "Read x.swift")
    }

    @Test("Итог сессии в техническом режиме про сессию")
    func outcome() {
        #expect(WorkPhrases.outcome(.finished, mode: .technical) == "Session ended")
        #expect(WorkPhrases.outcome(.stopped, mode: .technical) == "Stopped by you")
        #expect(WorkPhrases.outcome(.finished, mode: .simple) == "Done")
    }

    @Test("Сколько работает")
    func working() {
        #expect(WorkPhrases.agentsWorking(1) == "1 agent working")
        #expect(WorkPhrases.agentsWorking(3) == "3 agents working")
    }
}

@Suite("Период")
struct WorkPeriodTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Сегодня это весь день, неделя это семь дней вместе с сегодняшним")
    func ranges() {
        let today = WorkPeriod.today.days(now: now, calendar: calendar)
        #expect(today.lowerBound == calendar.startOfDay(for: now))
        #expect(today.contains(now))
        #expect(today.upperBound.timeIntervalSince(today.lowerBound) == 86399)
        let week = WorkPeriod.week.days(now: now, calendar: calendar)
        #expect(week.upperBound.timeIntervalSince(week.lowerBound) == 7 * 86400 - 1)
    }

    @Test("Даты можно выбрать в любом порядке")
    func swapped() {
        let earlier = now.addingTimeInterval(-3 * 86400)
        let range = WorkPeriod.dates(from: now, to: earlier).days(now: now, calendar: calendar)
        #expect(range.contains(earlier))
        #expect(range.contains(now))
    }

    @Test("Проект считается по главной копии, а Cowork без проекта")
    func projectPath() {
        let root = WorkNode(id: "s", kind: .main)
        let copy = WorkSession(id: "s", cwd: "/x/app/.claude/worktrees/one", state: .running, place: GitPlace(isSeparateCopy: true, mainFolder: "/x/app"), root: root)
        #expect(copy.projectPath == "/x/app")
        let cowork = WorkSession(id: "s", environment: .cowork, cwd: "/sessions/some-name", state: .running, root: root)
        #expect(cowork.projectPath == nil)
        let plain = WorkSession(id: "s", cwd: "/x/app", state: .running, root: root)
        #expect(plain.projectPath == "/x/app")
    }
}
