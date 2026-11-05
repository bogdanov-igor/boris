import BorisCore
import Foundation
import Testing

@Suite("Модель работы")
struct WorkModelTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func agent(_ id: String, session: String = "s1", parent: String? = nil, fork: Bool = false, state: AgentState = .running) -> AgentSnapshot {
        AgentSnapshot(id: id, sessionId: session, parentAgentId: parent, description: id, isFork: fork, state: state, lastWrite: now)
    }

    private func info(_ id: String = "s1", cwd: String? = "/x/shop-api", entrypoint: String? = "claude-vscode", status: String? = "busy", waitingFor: String? = nil) -> SessionInfo {
        SessionInfo(sessionId: id, pid: 100, cwd: cwd, entrypoint: entrypoint, status: status, waitingFor: waitingFor, statusUpdatedAt: now)
    }

    private func workflow(_ id: String = "wf_1", session: String = "s1", status: RunStatus = .running, agents: [AgentRecord] = []) -> RunState {
        RunState(runId: id, sessionId: session, name: "Аудит", cwd: "/x/shop-api", status: status, lastWrite: now, agents: agents)
    }

    @Test("Вложенность любой глубины")
    func deepNesting() throws {
        var world = WorldSnapshot(takenAt: now, sessions: [info()])
        world.agents = [agent("a1"), agent("a2", parent: "a1"), agent("a3", parent: "a2"), agent("a4", parent: "a3"), agent("a5", parent: "a4")]
        let session = try #require(WorkBuilder.build(world: world, runs: []).sessions.first)
        var node = session.root
        for id in ["a1", "a2", "a3", "a4", "a5"] {
            node = try #require(node.children.first)
            #expect(node.id == id)
            #expect(node.kind == .subagent)
        }
        #expect(node.children.isEmpty)
        #expect(session.root.flattened.count == 6)
    }

    @Test("Все типы узлов на своих местах, workflow это обычный узел дерева")
    func allKinds() throws {
        var world = WorldSnapshot(takenAt: now, sessions: [info()])
        world.agents = [agent("sub"), agent("forked", fork: true)]
        let run = workflow(agents: [
            AgentRecord(key: "k1", agentId: "w1", label: "Поиск", phase: "Поиск", state: .running),
            AgentRecord(key: "k2", agentId: "w2", label: "Проверка", phase: "Проверка", state: .done),
        ])
        let session = try #require(WorkBuilder.build(world: world, runs: [run]).sessions.first)
        #expect(session.root.kind == .main)
        let kinds = Dictionary(uniqueKeysWithValues: session.root.flattened.map { ($0.id, $0.kind) })
        #expect(kinds["sub"] == .subagent)
        #expect(kinds["forked"] == .fork)
        #expect(kinds["wf_1"] == .workflow)
        #expect(kinds["w1"] == .workflowAgent)
        #expect(Set(kinds.values) == Set(WorkNodeKind.allCases))

        let node = try #require(session.root.children.first { $0.id == "wf_1" })
        #expect(node.children.map(\.id) == ["w1", "w2"])
        #expect(node.children.first?.phase == "Поиск")
        #expect(node.workflow?.status == .running)
    }

    @Test("Субагент может запустить workflow, а агент workflow субагента")
    func mixedNesting() throws {
        let inner = WorkNode(id: "wf", kind: .workflow, parentId: "a1")
        let tree = WorkBuilder.tree([
            WorkNode(id: "a1", kind: .subagent, parentId: "root"),
            inner,
            WorkNode(id: "w1", kind: .workflowAgent, parentId: "wf"),
            WorkNode(id: "a2", kind: .subagent, parentId: "w1"),
        ], rootId: "root")
        #expect(tree.first?.children.first?.children.first?.children.first?.id == "a2")
    }

    @Test("Узел с неизвестным родителем не теряется")
    func orphan() {
        let tree = WorkBuilder.tree([WorkNode(id: "a", kind: .subagent, parentId: "gone")], rootId: "root")
        #expect(tree.map(\.id) == ["a"])
        #expect(tree.first?.parentId == "root")
    }

    @Test("Петля родителей не зависает и не теряет узлы")
    func loop() {
        let tree = WorkBuilder.tree([
            WorkNode(id: "a", kind: .subagent, parentId: "b"),
            WorkNode(id: "b", kind: .subagent, parentId: "a"),
            WorkNode(id: "c", kind: .subagent, parentId: "root"),
        ], rootId: "root")
        #expect(Set(tree.flatMap(\.flattened).map(\.id)) == ["a", "b", "c"])
    }

    @Test("Агенты и запуски стоят по времени старта, а не как попало от скана к скану")
    func stableOrder() throws {
        var world = WorldSnapshot(takenAt: now, sessions: [info()])
        var late = agent("late")
        late.startedAt = now
        var early = agent("early")
        early.startedAt = now.addingTimeInterval(-100)
        world.agents = [late, early]
        var second = workflow("wf_b")
        second.startedAt = now
        var first = workflow("wf_a")
        first.startedAt = now.addingTimeInterval(-50)
        let session = try #require(WorkBuilder.build(world: world, runs: [second, first]).sessions.first)
        #expect(session.root.children.map(\.id) == ["early", "late", "wf_a", "wf_b"])
    }

    @Test("Агент в той же копии, что и сессия, не отмечен, какую бы ветку ни застало чтение, а агент в другой копии отмечен")
    func sameCopyWhateverTheBranch() throws {
        var world = WorldSnapshot(takenAt: now, sessions: [info()])
        world.agents = [agent("same"), agent("other")]
        world.places["s1"] = GitPlace(isSeparateCopy: true, mainFolder: "/x/shop-api", folderName: "one")
        world.places["same"] = GitPlace(branch: "feature", isSeparateCopy: true, mainFolder: "/x/shop-api", folderName: "one")
        world.places["other"] = GitPlace(branch: "review", isSeparateCopy: true, mainFolder: "/x/shop-api", folderName: "two")
        let session = try #require(WorkBuilder.build(world: world, runs: []).sessions.first)
        let nodes = Dictionary(uniqueKeysWithValues: session.root.flattened.map { ($0.id, $0) })
        #expect(nodes["same"]?.place == nil)
        #expect(nodes["other"]?.place?.label == "review")
    }

    @Test("Занятая сессия без workflow это работа, а не «ничего не идёт»")
    func busyWithoutWorkflow() {
        let model = WorkBuilder.build(world: WorldSnapshot(takenAt: now, sessions: [info()]), runs: [])
        #expect(model.isWorking)
        #expect(model.workingAgents == 1)
    }

    @Test("Сессия, закончившая ход, работает, пока работает её агент")
    func idleWithBackgroundAgent() throws {
        var world = WorldSnapshot(takenAt: now, sessions: [info(status: "idle")])
        world.agents = [agent("a1")]
        let session = try #require(WorkBuilder.build(world: world, runs: []).sessions.first)
        #expect(session.root.state == .finished)
        #expect(session.state == .running)
        #expect(session.workingAgents == 1)
    }

    @Test("Ожидание видно на сессии, а открытый диалог это не ожидание ответа")
    func waiting() throws {
        let asking = WorldSnapshot(takenAt: now, sessions: [info(status: "waiting", waitingFor: "approve Bash: npm run migrate")])
        let session = try #require(WorkBuilder.build(world: asking, runs: []).sessions.first)
        #expect(session.state == .waiting)
        #expect(session.waitingFor == .permission(tool: "Bash"))

        let dialog = WorldSnapshot(takenAt: now, sessions: [info(status: "waiting", waitingFor: "dialog open")])
        #expect(WorkBuilder.build(world: dialog, runs: []).sessions.first?.state == .running)
    }

    @Test("Процесс исчез, а файл сессии остался: сессия прервана")
    func died() {
        var world = WorldSnapshot(takenAt: now)
        world.endedSessions = [info()]
        let model = WorkBuilder.build(world: world, runs: [])
        #expect(model.sessions.first?.state == .interrupted)
        #expect(!model.isWorking)
    }

    @Test("Сессия известна только по запуску, и всё равно на своём месте")
    func sessionOnlyFromRun() throws {
        let model = WorkBuilder.build(world: WorldSnapshot(takenAt: now), runs: [workflow(status: .completed)])
        let session = try #require(model.sessions.first)
        #expect(session.id == "s1")
        #expect(session.cwd == "/x/shop-api")
        #expect(session.state == .finished)
    }

    @Test("Один проект в двух средах это один проект и две сессии")
    func oneProjectTwoEnvironments() throws {
        let world = WorldSnapshot(takenAt: now, sessions: [info("s1", entrypoint: "claude-vscode"), info("s2", entrypoint: "cli")])
        let model = WorkBuilder.build(world: world, runs: [])
        #expect(model.projects.count == 1)
        let project = try #require(model.projects.first)
        #expect(project.name == "shop-api")
        #expect(Set(project.sessions.compactMap(\.environment)) == [.vsCode, .terminal])
    }

    @Test("Сессия без папки попадает в проект без пути")
    func noProject() {
        let model = WorkBuilder.build(world: WorldSnapshot(takenAt: now, sessions: [info(cwd: nil)]), runs: [])
        #expect(model.projects.first?.path == nil)
        #expect(model.projects.first?.name == nil)
    }

    @Test("Кто ждёт ответа, идёт первым, потом кто работает, потом остальные")
    func order() {
        let world = WorldSnapshot(takenAt: now, sessions: [
            info("done", cwd: "/x/a", status: "idle"),
            info("busy", cwd: "/x/b", status: "busy"),
            info("asks", cwd: "/x/c", status: "waiting", waitingFor: "input needed"),
        ])
        let model = WorkBuilder.build(world: world, runs: [])
        #expect(model.projects.compactMap(\.name) == ["c", "b", "a"])
    }

    @Test("Среда определяется по entrypoint", arguments: [
        ("cli", false, WorkEnvironment.terminal), ("cli", true, .insideClaude), ("claude-vscode", false, .vsCode),
        ("claude-desktop", false, .claudeDesktop), ("local-agent", true, .cowork), ("sdk-ts", true, .program),
    ])
    func environment(entrypoint: String, unlisted: Bool, expected: WorkEnvironment) {
        #expect(WorkEnvironment(entrypoint: entrypoint, unlisted: unlisted) == expected)
    }

    @Test("Продукт следует из среды")
    func product() {
        #expect(WorkEnvironment.vsCode.product == .claudeCode)
        #expect(WorkEnvironment.remote(host: "build-server").product == .claudeCode)
        #expect(WorkEnvironment.cowork.product == .cowork)
        #expect(WorkEnvironment.chat.product == .chat)
    }

    @Test("Действие определяется по инструменту", arguments: [
        ("Read", WorkAction.read), ("Grep", .read), ("Edit", .write), ("Write", .write), ("Bash", .command),
        ("WebSearch", .webSearch), ("WebFetch", .webFetch), ("Skill", .skill), ("Agent", .startAgent),
        ("Workflow", .startAgent), ("mcp__postgres__query", .mcp), ("SomethingNew", .other),
    ])
    func action(tool: String, expected: WorkAction) {
        #expect(WorkAction(tool: tool) == expected)
    }

    @Test("Событие из нового источника выглядит так же, как событие Claude")
    func eventFromAnySource() {
        let event = WorkEvent(id: "e1", environment: .remote(host: "x"), sessionId: "s", tool: "Read", target: "a.swift")
        #expect(event.action == .read)
        #expect(event.state == .running)
    }
}
