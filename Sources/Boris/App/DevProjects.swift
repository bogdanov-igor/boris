#if DEBUG
import BorisCore
import BorisData
import Foundation

/// Made-up projects, sessions and runs for looking at the pages. Nothing here comes from real sessions.
@MainActor
enum DevProjects {
    /// The session a snapshot of the session page opens.
    static let working = "b1"
    static let troubled = "a1"
    static let big = "big"
    static let pastBroken = "p7"

    private static func run(_ id: String, name: String, status: RunStatus, phases: [PhaseGroup], plan: [String] = [], topFailure: FailureClass? = nil, now: Date) -> WorkflowDetails {
        let agents = phases.flatMap(\.agents)
        var state = RunState(runId: id, sessionId: "", name: name, status: status, lastWrite: now, agents: agents, phases: phases, plannedPhases: plan, topFailure: topFailure)
        state.total = agents.count
        return WorkflowDetails(state)
    }

    private static func record(_ key: String, phase: String, state: AgentState = .done, failure: FailureInfo? = nil) -> AgentRecord {
        AgentRecord(key: key, agentId: key, label: key, phase: phase, state: state, failure: failure)
    }

    private static func node(_ run: WorkflowDetails, title: String, now: Date, tokens: Int, children: [AgentRecord], parent: String) -> WorkNode {
        WorkNode(
            id: run.runId,
            kind: .workflow,
            parentId: parent,
            title: title,
            state: run.status.isActive ? .running : run.status.isFailure ? .failed : .finished,
            tokens: TokenUsage(input: tokens),
            workflow: run,
            lastActivity: now,
            children: children.map { agent in
                WorkNode(
                    id: agent.key,
                    kind: .workflowAgent,
                    parentId: run.runId,
                    title: agent.label,
                    state: agent.state == .done ? .finished : agent.state == .failed ? .failed : agent.state == .running ? .running : .stopped,
                    step: agent.state == .running ? StepBrief(kind: .read, tool: "Read", fileName: "session.swift") : nil,
                    contextTokens: 40_000,
                    failure: agent.failure,
                    phase: agent.phase,
                    lastActivity: now
                )
            }
        )
    }

    /// A session with a nested helper, one working in a separate copy, and a workflow on its way.
    static func workingSession(now: Date, long: Bool) -> WorkSession {
        let review = WorkNode(
            id: "h2",
            kind: .subagent,
            parentId: "h1",
            title: long ? "Проверка находки со слишком длинным названием, которое никуда не помещается целиком" : "Проверка находки",
            state: .running,
            contextTokens: 6_300,
            place: GitPlace(branch: long ? "review/a-very-long-branch-name-that-goes-on-and-on-and-on" : "review/token-expiry", isSeparateCopy: true, folderName: "review")
        )
        let helper = WorkNode(id: "h1", kind: .subagent, parentId: "b1", title: "Проверка кода", state: .running, step: StepBrief(kind: .read, tool: "Read", fileName: long ? "a-file-with-a-name-so-long-that-it-cannot-possibly-fit-anywhere-on-one-line.swift" : "session.swift"), contextTokens: 21_700, model: "model-name", children: [review])
        let forked = WorkNode(id: "h3", kind: .fork, parentId: "b1", title: "Поиск примеров", state: .finished, contextTokens: 9_800)
        let phases = [
            PhaseGroup(title: "Поиск", agents: (1...8).map { record("search:\($0)", phase: "Поиск") }),
            PhaseGroup(title: "Проверка", agents: [record("check:1", phase: "Проверка")] + (2...4).map { record("check:\($0)", phase: "Проверка", state: .running) }, isCurrent: true),
            PhaseGroup(title: "Итог", agents: []),
        ]
        let details = run("wf_deps", name: "Аудит зависимостей", status: .running, phases: phases, plan: ["Поиск", "Проверка", "Итог"], now: now)
        let flow = node(details, title: "Аудит зависимостей", now: now, tokens: 52_000, children: phases.flatMap(\.agents), parent: "b1")
        return WorkSession(
            id: working,
            environment: .terminal,
            cwd: "/x/boris",
            state: .running,
            startedAt: now.addingTimeInterval(-3960),
            lastActivity: now,
            place: GitPlace(branch: "main"),
            root: WorkNode(id: working, kind: .main, state: .running, step: StepBrief(kind: .edit, tool: "Edit", fileName: long ? "a-file-with-a-name-so-long-that-it-cannot-possibly-fit-anywhere-on-one-line.swift" : "auth.swift"), contextTokens: 84_200, model: "model-name", children: [helper, forked, flow])
        )
    }

    /// A session waiting for the person, in which a run has failed for good and a helper has stumbled.
    static func troubledSession(now: Date, long: Bool) -> WorkSession {
        let limit = FailureInfo(failureClass: .limit, resets: "18:40")
        let phases = [PhaseGroup(title: "Перенос", agents: (1...12).map { record("move:\($0)", phase: "Перенос", state: .failed, failure: limit) })]
        let failed = run("wf_move", name: "Миграция данных", status: .allAgentsFailed, phases: phases, topFailure: .limit, now: now.addingTimeInterval(-960))
        var flow = node(failed, title: "Миграция данных", now: now.addingTimeInterval(-960), tokens: 18_000, children: phases.flatMap(\.agents), parent: troubled)
        flow.state = .failed
        let partPhases = [PhaseGroup(title: "Сбор", agents: (1...5).map { record("part:\($0)", phase: "Сбор") }), PhaseGroup(title: "Сверка", agents: [record("sum:1", phase: "Сверка", state: .failed, failure: FailureInfo(failureClass: .network)), record("sum:2", phase: "Сверка")])]
        let part = run("wf_part", name: "weekly-report", status: .completedWithErrors, phases: partPhases, topFailure: .network, now: now.addingTimeInterval(-3000))
        let partly = node(part, title: "weekly-report", now: now.addingTimeInterval(-3000), tokens: 41_000, children: partPhases.flatMap(\.agents), parent: troubled)
        let helper = WorkNode(id: "t1", kind: .subagent, parentId: troubled, title: "Миграции", state: .failed, failure: FailureInfo(failureClass: .api), lastActivity: now.addingTimeInterval(-540))
        return WorkSession(
            id: troubled,
            environment: .vsCode,
            cwd: long ? "/x/a-very-long-project-name-that-nobody-would-ever-want-to-type-by-hand-more-than-once" : "/x/shop-api",
            state: .waiting,
            waitingFor: .permission(tool: "Bash"),
            startedAt: now.addingTimeInterval(-4260),
            lastActivity: now.addingTimeInterval(-2520),
            place: GitPlace(branch: "main"),
            root: WorkNode(id: troubled, kind: .main, state: .waiting, contextTokens: 52_000, model: "model-name", children: [helper, flow, partly])
        )
    }

    /// One run of 219 agents, with the same shape as the largest one in the fixtures.
    static func bigSession(now: Date) -> WorkSession {
        let limit = FailureInfo(failureClass: .limit, resets: "18:40")
        let phases = [
            PhaseGroup(title: "Подготовка", agents: (1...8).map { record("prep:\($0)", phase: "Подготовка") }),
            PhaseGroup(title: "Аудит", agents: (1...53).map { record("audit:\($0)", phase: "Аудит") } + (54...210).map { record("audit:\($0)", phase: "Аудит", state: .failed, failure: limit) }),
            PhaseGroup(title: "Итог", agents: [record("sum:1", phase: "Итог", state: .failed, failure: limit)]),
        ]
        let details = run("wf_big", name: "Большой аудит", status: .completedWithErrors, phases: phases, topFailure: .limit, now: now)
        return WorkSession(
            id: big,
            environment: .terminal,
            cwd: "/x/big-audit",
            state: .finished,
            startedAt: now.addingTimeInterval(-7200),
            lastActivity: now.addingTimeInterval(-600),
            root: WorkNode(id: big, kind: .main, state: .finished, children: [node(details, title: "Большой аудит", now: now, tokens: 9_400_000, children: phases.flatMap(\.agents), parent: big)])
        )
    }

    /// A session that ended a little while ago.
    static func finishedSession(now: Date) -> WorkSession {
        let last = now.addingTimeInterval(-1500)
        return WorkSession(id: "e1", environment: .claudeDesktop, cwd: "/x/landing", title: "Новая главная", state: .finished, startedAt: last.addingTimeInterval(-1200), lastActivity: last, root: WorkNode(id: "e1", kind: .main, state: .finished))
    }

    /// What the logs of past sessions would say.
    static func past(now: Date, long: Bool) -> [WorkSession] {
        func session(_ id: String, _ path: String, _ environment: WorkEnvironment, daysAgo: Double, minutes: Double, state: WorkState = .finished, title: String? = nil, children: [WorkNode] = []) -> WorkSession {
            let start = now.addingTimeInterval(-daysAgo * 86400)
            return WorkSession(id: id, environment: environment, cwd: path, title: title, state: state, startedAt: start, lastActivity: start.addingTimeInterval(minutes * 60), root: WorkNode(id: id, kind: .main, state: state, children: children))
        }
        let shop = long ? "/x/a-very-long-project-name-that-nobody-would-ever-want-to-type-by-hand-more-than-once" : "/x/shop-api"
        var copy = session("p4", shop, .terminal, daysAgo: 3, minutes: 58, state: .stopped, title: long ? "Очень длинное название сессии, которое Claude придумал сам и которое не помещается ни в одну колонку таблицы" : "Починить оплату")
        copy.place = GitPlace(branch: "fix/payments", isSeparateCopy: true, mainFolder: shop, folderName: "payments")
        let inner = WorkNode(id: "p7b", kind: .subagent, parentId: "p7a", title: "Проверка схемы", state: .finished, contextTokens: 8_100)
        var broken = session(pastBroken, shop, .vsCode, daysAgo: 5, minutes: 12, state: .failed, title: "Перенос базы", children: [WorkNode(id: "p7a", kind: .subagent, parentId: pastBroken, title: "Разбор миграций", state: .stopped, contextTokens: 31_000, children: [inner])])
        broken.root.failure = FailureInfo(failureClass: .limit, resets: "18:40")
        return [
            session("p1", shop, .terminal, daysAgo: 1, minutes: 92, title: "Обновить зависимости", children: (1...4).map { WorkNode(id: "p1a\($0)", kind: .subagent, state: .finished) }),
            session("p2", shop, .vsCode, daysAgo: 2, minutes: 22, title: "Проверка заказов"),
            session("p3", shop, .vsCode, daysAgo: 3.2, minutes: 47),
            copy,
            session("p5", shop, .vsCode, daysAgo: 4, minutes: 34, state: .interrupted),
            broken,
            session("p6", shop, .vsCode, daysAgo: 12, minutes: 6),
            session("e2", "/x/landing", .claudeDesktop, daysAgo: 2, minutes: 15),
            session("d9", "/x/boris", .terminal, daysAgo: 1.5, minutes: 40),
        ]
    }

    static func tokens(now: Date) -> [TokenRecord] {
        let calendar = Calendar.current
        func day(_ ago: Int) -> String { ProjectBook.dayKey(calendar.date(byAdding: .day, value: -ago, to: now) ?? now) }
        var records: [TokenRecord] = []
        func add(_ session: String, ago: Int, _ total: Int) {
            records.append(TokenRecord(sessionId: session, cwd: "/x/shop-api", day: day(ago), usage: TokenUsage(input: total * 22 / 100, output: total * 3 / 100, cacheRead: total * 70 / 100, cacheWrite: total * 5 / 100)))
        }
        add(troubled, ago: 0, 52_000)
        add("p1", ago: 1, 880_000)
        add("p2", ago: 2, 138_000)
        add("p3", ago: 3, 610_000)
        add("p4", ago: 3, 420_000)
        add("p5", ago: 4, 290_000)
        add("p6", ago: 12, 40_000)
        add(pastBroken, ago: 5, 75_000)
        add(working, ago: 0, 1_750_000)
        add("d9", ago: 1, 3_110_000)
        add("e1", ago: 0, 24_000)
        add("e2", ago: 2, 1_090_000)
        add("c1", ago: 0, 14_000)
        return records
    }
}
#endif
