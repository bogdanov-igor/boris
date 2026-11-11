import BorisCore
import Foundation
import Testing
@testable import BorisData

/// One made-up session with every shape that once made the pages disagree: an agent working in a subfolder that fell on a limit,
/// a stopped workflow with an agent stopped together with it, one that fell, one that fell once and was tried again, and one that went on
/// after the workflow in a file of its own, and a session that ends on a slash command. Nothing here comes from real logs.
private enum World {
    static let started = Date().addingTimeInterval(-3 * 86400)

    static func stamp(_ offset: TimeInterval) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: started.addingTimeInterval(offset))
    }

    static func say(_ id: String, tokens: Int, cwd: String, at offset: TimeInterval, stop: String = "end_turn") -> String {
        #"{"type":"assistant","uuid":"u-\#(id)","timestamp":"\#(stamp(offset))","cwd":"\#(cwd)","entrypoint":"cli","message":{"id":"\#(id)","model":"claude-opus-4-1","content":[{"type":"text","text":"made up"}],"stop_reason":"\#(stop)","usage":{"input_tokens":\#(tokens),"output_tokens":0}}}"# + "\n"
    }

    static func person(_ text: String, cwd: String, at offset: TimeInterval) -> String {
        #"{"type":"user","uuid":"p-\#(UUID().uuidString)","timestamp":"\#(stamp(offset))","cwd":"\#(cwd)","entrypoint":"cli","message":{"role":"user","content":"\#(text)"}}"# + "\n"
    }

    static func limit(_ id: String, cwd: String, at offset: TimeInterval) -> String {
        #"{"type":"assistant","uuid":"\#(id)","timestamp":"\#(stamp(offset))","cwd":"\#(cwd)","entrypoint":"cli","isApiErrorMessage":true,"error":"rate_limit","message":{"id":"\#(id)","model":"<synthetic>","content":[{"type":"text","text":"You've hit your session limit · resets 2pm"}],"stop_reason":"stop_sequence","usage":{"input_tokens":0,"output_tokens":0}}}"# + "\n"
    }

    /// Returns the folder Claude would keep.
    static func make(_ folder: TempFolder) -> ClaudePaths {
        let shop = "/x/shop"
        let copy = "/x/shop/.claude/worktrees/w1"
        folder.write("projects/p/s1.jsonl", person("start", cwd: shop, at: 0) + say("m-main", tokens: 1, cwd: shop, at: 10) + person("<local-command-stdout>Bye!</local-command-stdout>", cwd: shop, at: 4000))
        // An ordinary agent in a subfolder that fell on a limit.
        folder.write("projects/p/s1/subagents/agent-a1.jsonl", say("m-a1", tokens: 2, cwd: "\(shop)/web", at: 20, stop: "tool_use") + limit("e-a1", cwd: "\(shop)/web", at: 30))
        folder.write("projects/p/s1/subagents/agent-a1.meta.json", #"{"description":"Проверка","agentType":"general-purpose"}"#)
        // The workflow: x went on after it, y was stopped with it, z fell after an earlier attempt z0.
        folder.write("projects/p/s1/subagents/workflows/wf_1/journal.jsonl", [
            #"{"type":"started","key":"kx","agentId":"x","label":"Сборка"}"#,
            #"{"type":"started","key":"ky","agentId":"y","label":"Тесты"}"#,
            #"{"type":"started","key":"kz","agentId":"z0","label":"Отчёт"}"#,
            #"{"type":"started","key":"kz","agentId":"z","label":"Отчёт"}"#,
            #"{"type":"failed","key":"kz","agentId":"z"}"#,
        ].joined(separator: "\n") + "\n")
        folder.write("projects/p/s1/subagents/workflows/wf_1/agent-x.jsonl", say("m-x", tokens: 10, cwd: copy, at: 100, stop: "tool_use"))
        folder.write("projects/p/s1/subagents/workflows/wf_1/agent-y.jsonl", say("m-y", tokens: 20, cwd: copy, at: 110, stop: "tool_use"))
        folder.write("projects/p/s1/subagents/workflows/wf_1/agent-z.jsonl", say("m-z", tokens: 40, cwd: copy, at: 120, stop: "tool_use"))
        folder.write("projects/p/s1/subagents/workflows/wf_1/agent-z0.jsonl", say("m-z0", tokens: 80, cwd: copy, at: 115, stop: "tool_use"))
        let start = Int(started.addingTimeInterval(100).timeIntervalSince1970 * 1000)
        folder.write("projects/p/s1/workflows/wf_1.json", #"{"status":"killed","workflowName":"Выпуск","startTime":\#(start),"durationMs":60000,"agentCount":3,"workflowProgress":[{"type":"workflow_agent","agentId":"x","label":"Сборка","state":"progress"},{"type":"workflow_agent","agentId":"y","label":"Тесты","state":"error","error":"Workflow aborted"},{"type":"workflow_agent","agentId":"z","label":"Отчёт","state":"error","error":"You've hit your session limit · resets 2pm"}]}"#)
        // x goes on after the workflow, in a file beside the session's, with no description of its own.
        folder.write("projects/p/s1/subagents/agent-x.jsonl", say("m-x2", tokens: 160, cwd: copy, at: 300))
        return ClaudePaths(root: folder.url)
    }
}

@Suite("Числа сходятся между страницами")
struct NumbersAgreeTests {
    private let later = Date().addingTimeInterval(120)

    private func session(_ paths: ClaudePaths) async throws -> WorkSession {
        let sessions = await SessionHistory(paths: paths).sessions(now: later)
        return try #require(sessions.first { $0.id == "s1" })
    }

    private func losses(_ paths: ClaudePaths, live: Set<String> = []) async -> LossHistory {
        let index = LossIndex(cacheFile: nil)
        await index.update(roots: [paths])
        return await index.history(live: live)
    }

    @Test("Одна потеря одинакова на «Потерях», в «Проектах», на странице сессии и в уведомлении")
    func sameCount() async throws {
        let folder = TempFolder()
        let paths = World.make(folder)
        let session = try await session(paths)
        let crashes = await losses(paths).entries.filter { $0.kind == .crash }
        // a1 fell on the limit, and z fell in the workflow. y was stopped with it, and x went on and finished.
        #expect(crashes.reduce(0) { $0 + $1.count } == 2)
        #expect(session.failureCount == 2)
        #expect(Set(session.failures.map(\.id)) == ["a1", "wf_1"])
        #expect(Set(crashes.flatMap(\.agents)) == ["a1", "z"])
        let workflow = try #require(session.root.flattened.first { $0.kind == .workflow })
        #expect(workflow.workflow?.fallenAgents == ["z"])
        // A notification says as many failed as the two pages do.
        var detector = EventDetector()
        var world = await RunScanner(paths: paths, config: { var config = RunScanner.Config(); config.window = .infinity; return config }()).scan(now: later)
        world.sessions = []
        var tracker = RunTracker()
        let runs = tracker.resolve(world) { _ in nil }
        #expect(runs.first?.fallenAgents.count == 1)
        _ = detector.detect(runs: runs.map { run in var run = run; run.status = .running; return run }, sessions: [], usage: nil, now: later)
        let told = detector.detect(runs: runs, sessions: [], usage: nil, now: later)
        #expect(told.first { $0.runId == "wf_1" }?.agentsFailed == 1)
    }

    @Test("Сессия, закончившаяся командой /exit, не оборвана")
    func slashCommandIsNoCut() async throws {
        let folder = TempFolder()
        let session = try await session(World.make(folder))
        #expect(session.state == .finished)
        #expect(!session.failures.contains { $0.source == .session })
        #expect(await losses(World.make(folder)).entries.allSatisfy { !$0.id.hasPrefix("session/") })
    }

    @Test("Агент, продолживший работу после workflow, один: закончил, а не «остановлен», и потерь за ним нет")
    func continuedAgentIsOne() async throws {
        let folder = TempFolder()
        let paths = World.make(folder)
        let session = try await session(paths)
        let x = session.root.flattened.filter { $0.id == "x" }
        #expect(x.count == 1)
        #expect(x.first?.kind == .workflowAgent)
        #expect(x.first?.state == .finished)
        #expect(x.first?.title == "Сборка")
        #expect(await losses(paths).entries.allSatisfy { !$0.agents.contains("x") })
    }

    @Test("Строка workflow равна сумме своих агентов, и у каждого файла запуска есть строка")
    func workflowAddsUp() async throws {
        let folder = TempFolder()
        let paths = World.make(folder)
        let session = try await session(paths)
        let index = TokenIndex(cacheFile: nil)
        await index.update(roots: [paths])
        let book = TokenBook(records: await index.records(), now: Date())
        let workflow = try #require(session.root.flattened.first { $0.kind == .workflow })
        let agents = workflow.flattened.filter { $0.kind == .workflowAgent }
        #expect(Set(agents.flatMap { [$0.id] + $0.attemptIds }) == ["x", "y", "z", "z0"])
        #expect(agents.first { $0.id == "z" }?.attemptIds == ["z0"])
        let children = agents.compactMap { book.spent(node: $0)?.total }.reduce(0, +)
        // Every file of the run and the file x went on in: 10 + 20 + 40 + 80 + 160.
        #expect(book.spent(node: workflow)?.total == 310)
        #expect(children == 310)
        #expect(book.spent(node: try #require(agents.first { $0.id == "x" }))?.total == 170)
    }

    @Test("Проект один и тот же везде: по папке сессии, а не по папке агента или копии")
    func oneProjectEverywhere() async throws {
        let folder = TempFolder()
        let paths = World.make(folder)
        let session = try await session(paths)
        #expect(session.projectPath == "/x/shop")
        let index = TokenIndex(cacheFile: nil)
        await index.update(roots: [paths])
        let book = TokenBook(records: await index.records(), now: Date())
        #expect(book.report(.all).lines(.projects).map(\.key) == [.project("/x/shop")])
        let rows = await losses(paths).entries
        #expect(!rows.isEmpty)
        #expect(rows.allSatisfy { $0.project == "/x/shop" })
        var run = RunState(runId: "wf_9", sessionId: "s1", name: "wf", cwd: "/x/shop/.claude/worktrees/w1", status: .failed, lastWrite: Date())
        run.entrypoint = "cli"
        #expect(run.projectName == "shop")
    }

    @Test("Страница сессии читает только свою сессию и видит её упавшие шаги")
    func sessionSteps() async throws {
        let folder = TempFolder()
        let paths = World.make(folder)
        folder.write("projects/p/s2.jsonl", #"{"type":"user","cwd":"/x/other","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","is_error":true,"content":"Exit code 1"}]}}"# + "\n" + World.say("m-s2", tokens: 1, cwd: "/x/other", at: 50))
        folder.write("projects/p/s3.jsonl", #"{"type":"user","cwd":"/x/other","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t2","is_error":true,"content":"Exit code 2"}]}}"# + "\n" + World.say("m-s3", tokens: 1, cwd: "/x/other", at: 50))
        let index = LossIndex(cacheFile: nil)
        await index.update(session: "s2", roots: [paths])
        let found = await index.history(session: "s2", live: [])
        #expect(found.map(\.kind) == [.toolError])
        // Nothing of the other sessions was read.
        #expect(await index.history(live: []).entries.allSatisfy { $0.sessionId == "s2" })
    }
}

@Suite("Проекты и идущая сессия")
struct ProjectNumbersTests {
    private let now = Date()

    private func failedAgent(_ id: String, daysAgo: Double) -> WorkNode {
        WorkNode(id: id, kind: .subagent, state: .failed, failure: FailureInfo(failureClass: .limit), lastActivity: now.addingTimeInterval(-daysAgo * 86400))
    }

    @Test("«Сбои» проекта считают только упавшее в выбранный период")
    func failuresFollowThePeriod() {
        var session = WorkSession(id: "s1", cwd: "/x/shop", state: .finished, startedAt: now.addingTimeInterval(-20 * 86400), lastActivity: now.addingTimeInterval(-86400), root: WorkNode(id: "s1", kind: .main, state: .finished))
        session.root.children = [failedAgent("old", daysAgo: 12), failedAgent("new", daysAgo: 1)]
        let week = ProjectBook.summaries(sessions: [session], tokens: [], filter: ProjectFilter(period: .week), now: now)
        let month = ProjectBook.summaries(sessions: [session], tokens: [], filter: ProjectFilter(period: .month), now: now)
        #expect(week.first?.failures == 1)
        #expect(month.first?.failures == 2)
    }

    @Test("Идущая сессия не теряет старых агентов, workflow и сбоев, а живое состояние берёт из скана")
    func runningSessionKeepsItsPast() {
        let old = failedAgent("old", daysAgo: 3)
        var flow = WorkNode(id: "wf_1", kind: .workflow, state: .finished, lastActivity: now.addingTimeInterval(-2 * 86400))
        flow.children = [WorkNode(id: "w1", kind: .workflowAgent, parentId: "wf_1", state: .stopped)]
        var logged = WorkSession(id: "s1", cwd: "/x/shop", state: .interrupted, startedAt: now.addingTimeInterval(-4 * 86400), root: WorkNode(id: "s1", kind: .main, state: .interrupted))
        logged.root.children = [old, flow, WorkNode(id: "fresh", kind: .subagent, state: .stopped)]
        // The scan sees only the last day: the newest agent, at work, and the workflow agent going on in a file of its own.
        var live = WorkSession(id: "s1", cwd: "/x/shop", state: .running, startedAt: now.addingTimeInterval(-3600), root: WorkNode(id: "s1", kind: .main, state: .running))
        live.root.children = [WorkNode(id: "fresh", kind: .subagent, state: .running), WorkNode(id: "w1", kind: .subagent, state: .running)]
        let work = WorkModel(projects: [WorkProject(path: "/x/shop", sessions: [live])])
        let shown = try? #require(ProjectBook.sessions(work: work, past: [logged]).first { $0.id == "s1" })
        let nodes = shown?.root.flattened ?? []
        #expect(shown?.state == .running)
        #expect(Set(nodes.map(\.id)) == ["s1", "old", "wf_1", "w1", "fresh"])
        #expect(nodes.first { $0.id == "fresh" }?.state == .running)
        let w1 = nodes.first { $0.id == "w1" }
        #expect(w1?.kind == .workflowAgent)
        #expect(w1?.state == .running)
        #expect(w1?.parentId == "wf_1")
        // The old failure stays, and being at work now is no failure.
        #expect(shown?.failureCount == 1)
        #expect(shown?.startedAt == logged.startedAt)
    }
}
