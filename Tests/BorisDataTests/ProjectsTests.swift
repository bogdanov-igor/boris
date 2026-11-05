import BorisCore
import Foundation
import Testing
@testable import BorisData

@Suite("Workflow на реальных запусках")
struct WorkflowFixtureTests {
    /// Read once: a pass over all the fixtures is the heaviest thing here, and the timing tests next door feel it.
    private static let work = Task { () throws -> WorkModel in
        let folder = TempFolder()
        let paths = try Fixtures.world(into: folder)
        var config = RunScanner.Config()
        config.window = .infinity
        var world = await RunScanner(paths: paths, config: config).scan(now: Date().addingTimeInterval(60))
        var tracker = RunTracker()
        let runs = tracker.resolve(world) { _ in nil }
        world.sessions = []
        return WorkBuilder.build(world: world, runs: runs)
    }

    private func model() async throws -> WorkModel {
        try await Self.work.value
    }

    private func workflows(_ model: WorkModel) -> [WorkNode] {
        model.sessions.flatMap { $0.root.flattened }.filter { $0.kind == .workflow }
    }

    @Test("Гистограмма статусов узлов дерева совпадает с независимым подсчётом")
    func statusHistogram() async throws {
        let work = try await model()
        var histogram: [String: Int] = [:]
        for node in workflows(work) { histogram[node.workflow?.status.key ?? "?", default: 0] += 1 }
        #expect(histogram == (try Fixtures.expected()).status)
    }

    @Test("Завершён, но упали все агенты: узел в состоянии сбоя, а не успеха")
    func honestState() async throws {
        let work = try await model()
        let failed = workflows(work).filter { $0.workflow?.status == .allAgentsFailed }
        #expect(failed.count == 11)
        #expect(failed.allSatisfy { $0.state == .failed })
        #expect(failed.allSatisfy { $0.phases.reduce(0) { $0 + $1.done } == 0 })
    }

    @Test("Каждый агент каждого запуска стоит ровно в одной фазе, порядок как в плане")
    func everyAgentInOnePhase() async throws {
        let work = try await model()
        let nodes = workflows(work)
        #expect(nodes.count == (try Fixtures.expected()).runs)
        for node in nodes {
            let phases = node.phases
            let grouped = phases.flatMap(\.agents).map(\.id)
            #expect(grouped.count == Set(grouped).count, "\(node.id): агент в двух фазах")
            #expect(Set(grouped) == Set(node.children.map(\.id)), "\(node.id): агент потерян")
            #expect(phases.reduce(0) { $0 + $1.total } == node.children.count)
            #expect(Set(phases.map(\.id)).count == phases.count, "\(node.id): фаза дважды")
            let plan = node.workflow?.phases.compactMap(\.title) ?? []
            let titles = phases.compactMap(\.title)
            #expect(titles == plan.filter { titles.contains($0) }, "\(node.id): порядок фаз")
            #expect(phases.filter(\.isAhead).isEmpty, "\(node.id): законченный запуск с фазой впереди")
        }
    }

    @Test("Запуск из 219 агентов свёрнут в считанные строки, а раскрытый показывает всех")
    func bigRun() async throws {
        let work = try await model()
        let session = try #require(work.sessions.first { $0.root.children.contains { $0.id == "wf_156c5026-872" } })
        let node = try #require(session.root.children.first { $0.id == "wf_156c5026-872" })
        #expect(node.workflow?.total == 219)
        #expect(node.phases.reduce(0) { $0 + $1.total } == 219)
        #expect(node.workflow?.status == .completedWithErrors)
        // Counted separately from the final file, by hand.
        #expect(node.phases.map(\.title) == ["phase-1", "phase-2", "phase-3"])
        #expect(node.phases.map(\.done) == [8, 53, 0])
        #expect(node.phases.map(\.failed) == [0, 157, 1])

        let root = WorkNode(id: session.id, kind: .main, children: [node])
        let folded = AgentTree.rows(root: root, expanded: [])
        #expect(folded.count == 2 + node.phases.count)
        let keys = Set(node.phases.map { AgentTree.phaseKey(workflow: node.id, phase: $0.title) })
        let open = AgentTree.rows(root: root, expanded: keys)
        #expect(open.count == folded.count + 219)
        #expect(Set(open.map(\.id)).count == open.count, "у каждой строки свой идентификатор")
    }

    @Test("Список строк для 219 агентов собирается быстрее кадра")
    func rowsAreCheap() async throws {
        let work = try await model()
        let session = try #require(work.sessions.first { $0.root.children.contains { $0.id == "wf_156c5026-872" } })
        let node = try #require(session.root.children.first { $0.id == "wf_156c5026-872" })
        let keys = Set(node.phases.map { AgentTree.phaseKey(workflow: node.id, phase: $0.title) })
        let clock = ContinuousClock()
        var fastest = Duration.seconds(10)
        for _ in 0..<20 {
            let began = clock.now
            _ = AgentTree.rows(root: session.root, expanded: keys)
            fastest = min(fastest, clock.now - began)
        }
        // The best of several tries, so that a busy machine does not decide this.
        #expect(fastest < .milliseconds(16), "\(fastest)")
    }

    @Test("Сбои запусков называют причину")
    func failureWords() async throws {
        let work = try await model()
        let failures = work.sessions.flatMap(\.failures)
        #expect(failures.contains { if case .workflow(.allAgentsFailed, _, _) = $0.source { return $0.cause == .limit } else { return false } })
        for failure in failures {
            #expect(!WorkPhrases.failure(failure, mode: .simple).isEmpty)
            #expect(!WorkPhrases.failure(failure, mode: .technical).isEmpty)
        }
    }
}

@Suite("Прошлые сессии")
struct SessionHistoryTests {
    private func transcript(cwd: String, branch: String = "main", end: String = #"{"type":"assistant","message":{"stop_reason":"end_turn","usage":{"input_tokens":5,"output_tokens":7},"model":"opus"}}"#) -> String {
        #"{"type":"user","cwd":"\#(cwd)","entrypoint":"cli","gitBranch":"\#(branch)","message":{"role":"user","content":"x"}}"# + "\n" + end + "\n"
    }

    @Test("Все сессии из логов на месте, запуски внутри своих сессий")
    func fixtures() async throws {
        let folder = TempFolder()
        let paths = try Fixtures.world(into: folder)
        let sessions = await SessionHistory(paths: paths).sessions(now: Date().addingTimeInterval(60))
        #expect(sessions.count == 15)
        #expect(sessions.allSatisfy { !$0.state.isActive })
        let nodes = sessions.flatMap { $0.root.flattened }.filter { $0.kind == .workflow }
        #expect(nodes.count == (try Fixtures.expected()).runs)
        #expect(sessions.allSatisfy { $0.root.flattened.allSatisfy { !$0.state.isActive } })
    }

    @Test("Сессия с удалённым логом исчезает, остальные остаются")
    func deletedLog() async throws {
        let folder = TempFolder()
        folder.write("projects/p/one.jsonl", transcript(cwd: "/x/app"))
        let second = folder.write("projects/p/two.jsonl", transcript(cwd: "/x/app"))
        let history = SessionHistory(paths: ClaudePaths(root: folder.url))
        #expect(Set(await history.sessions().map(\.id)) == ["one", "two"])
        try FileManager.default.removeItem(at: second)
        #expect(await history.sessions().map(\.id) == ["one"])
    }

    @Test("Запуск удалённой сессии исчезает вместе с ней")
    func deletedWithRun() async throws {
        let folder = TempFolder()
        let log = folder.write("projects/p/gone.jsonl", transcript(cwd: "/x/app"))
        folder.write("projects/p/gone/subagents/workflows/wf_1/journal.jsonl", #"{"type":"agent_started","key":"k","agentId":"a"}"# + "\n")
        let history = SessionHistory(paths: ClaudePaths(root: folder.url))
        #expect(await history.sessions().count == 1)
        try FileManager.default.removeItem(at: log)
        #expect(await history.sessions().isEmpty)
    }

    @Test("Новая сессия появляется, а дописанная обновляется")
    func follows() async throws {
        let folder = TempFolder()
        folder.write("projects/p/one.jsonl", transcript(cwd: "/x/app", end: #"{"type":"user","message":{"role":"user","content":"x"}}"#))
        let history = SessionHistory(paths: ClaudePaths(root: folder.url))
        #expect(await history.sessions().first?.state == .interrupted)
        folder.write("projects/p/two.jsonl", transcript(cwd: "/x/other"))
        folder.append("projects/p/one.jsonl", #"{"type":"assistant","message":{"stop_reason":"end_turn"}}"# + "\n")
        // The time of a file changes in steps too coarse for this test without a nudge.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: folder.url.appendingPathComponent("projects/p/one.jsonl").path)
        let sessions = await history.sessions()
        #expect(sessions.count == 2)
        #expect(sessions.first { $0.id == "one" }?.state == .finished)
    }

    @Test("Итог берётся из конца лога", arguments: [
        (#"{"type":"assistant","message":{"stop_reason":"end_turn"}}"#, WorkState.finished),
        (#"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#, .stopped),
        (#"{"type":"assistant","isApiErrorMessage":true,"message":{"content":[{"type":"text","text":"API Error"}]}}"#, .failed),
        (#"{"type":"assistant","message":{"stop_reason":"tool_use","content":[{"type":"tool_use","id":"t","name":"Bash","input":{}}]}}"#, .interrupted),
    ])
    func outcomes(end: String, state: WorkState) async {
        let folder = TempFolder()
        folder.write("projects/p/one.jsonl", transcript(cwd: "/x/app", end: end))
        #expect(await SessionHistory(paths: ClaudePaths(root: folder.url)).sessions().first?.state == state)
    }

    @Test("Незаконченный агент прошлой сессии не выглядит работающим")
    func nothingRunsInThePast() async {
        let folder = TempFolder()
        folder.write("projects/p/one.jsonl", transcript(cwd: "/x/app"))
        folder.write("projects/p/one/subagents/agent-a1.jsonl", #"{"type":"user","cwd":"/x/app"}"# + "\n")
        folder.write("projects/p/one/subagents/agent-a1.meta.json", #"{"agentType":"scout","description":"Разведка"}"#)
        let session = await SessionHistory(paths: ClaudePaths(root: folder.url)).sessions().first
        let agent = session?.root.children.first
        #expect(agent?.title == "Разведка")
        #expect(agent?.state == .stopped)
    }

    @Test("Лог Cowork считается как сессия без проекта")
    func cowork() async {
        let folder = TempFolder()
        folder.write("projects/p/one.jsonl", #"{"type":"user","cwd":"/sessions/some-name","entrypoint":"local-agent"}"# + "\n")
        let session = await SessionHistory(paths: ClaudePaths(root: folder.url)).sessions().first
        #expect(session?.environment == .cowork)
        #expect(session?.projectPath == nil)
    }

    @Test("Сессия из терминала остаётся терминальной, когда процесса уже нет")
    func terminal() async {
        let folder = TempFolder()
        folder.write("projects/p/one.jsonl", transcript(cwd: "/x/app"))
        #expect(await SessionHistory(paths: ClaudePaths(root: folder.url)).sessions().first?.environment == .terminal)
    }
}

@Suite("Отдельная копия проекта")
struct WorktreeTests {
    private func git(_ arguments: [String], in folder: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "user.name=boris", "-c", "user.email=boris@example.invalid"] + arguments
        process.currentDirectoryURL = folder
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "git \(arguments)")
    }

    /// A real repository with a real worktree in Claude Code's place and one of the person's own.
    private func repository() throws -> (folder: TempFolder, main: URL, claudeCopy: URL, ownCopy: URL) {
        let folder = TempFolder()
        let main = folder.url.appendingPathComponent("app")
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        try git(["init", "-q"], in: main)
        try git(["commit", "-q", "--allow-empty", "-m", "start"], in: main)
        let claudeCopy = main.appendingPathComponent(".claude/worktrees/review")
        try git(["worktree", "add", "-q", "-b", "review/token-expiry", claudeCopy.path], in: main)
        let ownCopy = folder.url.appendingPathComponent("app-hotfix")
        try git(["worktree", "add", "-q", "-b", "hotfix", ownCopy.path], in: main)
        return (folder, main, claudeCopy, ownCopy)
    }

    @Test("Копия Claude Code: своя ветка, а проект тот же")
    func claudeCopy() throws {
        let (folder, main, copy, _) = try repository()
        _ = folder
        let place = try #require(GitPlaceReader.place(folder: copy.path, branch: "review/token-expiry"))
        #expect(place.isSeparateCopy)
        #expect(place.label == "review/token-expiry")
        #expect(place.mainFolder == main.path)
    }

    @Test("Своя копия человека видна по файлу .git, в том числе из вложенной папки")
    func ownCopy() throws {
        let (folder, _, _, copy) = try repository()
        _ = folder
        let inner = copy.appendingPathComponent("src/deep")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        for path in [copy.path, inner.path] {
            let place = try #require(GitPlaceReader.place(folder: path, branch: "hotfix"))
            #expect(place.isSeparateCopy)
            #expect(place.label == "hotfix")
            #expect(place.mainFolder == nil)
        }
    }

    @Test("Обычная папка проекта не отмечена, но ветка известна")
    func mainCopy() throws {
        let (folder, main, _, _) = try repository()
        _ = folder
        let place = try #require(GitPlaceReader.place(folder: main.path, branch: "main"))
        #expect(!place.isSeparateCopy)
        #expect(place.label == "main")
    }

    @Test("Папка вне git, без ветки: ничего")
    func noGit() {
        let folder = TempFolder()
        #expect(GitPlaceReader.place(folder: folder.url.path, branch: nil) == nil)
        #expect(GitPlaceReader.place(folder: nil, branch: "main") == nil)
    }

    @Test("Копию уже удалили: по пути всё равно видно, чья она")
    func removedCopy() throws {
        let place = try #require(GitPlaceReader.place(folder: "/nowhere/app/.claude/worktrees/one/sub", branch: nil))
        #expect(place.isSeparateCopy)
        #expect(place.mainFolder == "/nowhere/app")
        #expect(place.label == "one")
    }

    @Test("HEAD это не ветка")
    func detached() throws {
        let place = try #require(GitPlaceReader.place(folder: "/nowhere/app/.claude/worktrees/one", branch: "HEAD"))
        #expect(place.branch == nil)
        #expect(place.label == "one")
    }

    @Test("Сессия в копии числится в своём проекте, а её строка отмечена веткой")
    func sessionInCopy() async throws {
        let (folder, main, copy, _) = try repository()
        let logs = TempFolder()
        logs.write("projects/p/one.jsonl", #"{"type":"user","cwd":"\#(copy.path)","entrypoint":"cli","gitBranch":"review/token-expiry"}"# + "\n")
        logs.write("projects/q/two.jsonl", #"{"type":"user","cwd":"\#(main.path)","entrypoint":"cli","gitBranch":"main"}"# + "\n")
        _ = folder
        let sessions = await SessionHistory(paths: ClaudePaths(root: logs.url)).sessions()
        let inCopy = try #require(sessions.first { $0.id == "one" })
        #expect(inCopy.place?.isSeparateCopy == true)
        #expect(inCopy.place?.label == "review/token-expiry")
        #expect(inCopy.projectPath == main.path)
        let inMain = try #require(sessions.first { $0.id == "two" })
        #expect(inMain.place?.isSeparateCopy == false)
        #expect(inMain.projectPath == main.path)
    }

    @Test("Агент в копии отмечен, а агент в той же папке, что и сессия, нет")
    func agentInCopy() async throws {
        let (folder, main, copy, _) = try repository()
        _ = folder
        let logs = TempFolder()
        logs.write("projects/p/one.jsonl", #"{"type":"user","cwd":"\#(main.path)","entrypoint":"cli","gitBranch":"main"}"# + "\n")
        logs.write("projects/p/one/subagents/agent-a1.jsonl", #"{"type":"user","cwd":"\#(copy.path)","gitBranch":"review/token-expiry"}"# + "\n")
        logs.write("projects/p/one/subagents/agent-a1.meta.json", #"{"agentType":"scout"}"#)
        logs.write("projects/p/one/subagents/agent-a2.jsonl", #"{"type":"user","cwd":"\#(main.path)","gitBranch":"main"}"# + "\n")
        logs.write("projects/p/one/subagents/agent-a2.meta.json", #"{"agentType":"scout"}"#)
        logs.write("projects/p/one/subagents/workflows/wf_1/journal.jsonl", #"{"type":"started","key":"k1","agentId":"w1","label":"Проверка"}"# + "\n")
        logs.write("projects/p/one/subagents/workflows/wf_1/agent-w1.jsonl", #"{"type":"user","cwd":"\#(copy.path)","gitBranch":"review/token-expiry"}"# + "\n")
        let session = try #require(await SessionHistory(paths: ClaudePaths(root: logs.url)).sessions().first)
        let nodes = Dictionary(uniqueKeysWithValues: session.root.flattened.map { ($0.id, $0) })
        #expect(nodes["a1"]?.place?.label == "review/token-expiry")
        #expect(nodes["a2"]?.place == nil)
        #expect(nodes["w1"]?.place?.label == "review/token-expiry")
    }

    @Test("Живая сессия в копии отмечена, а её агент в той же копии нет")
    func liveSession() async throws {
        let (folder, main, copy, _) = try repository()
        _ = folder
        let logs = TempFolder()
        let pid = ProcessInfo.processInfo.processIdentifier
        logs.write("sessions/\(pid).json", #"{"sessionId":"one","pid":\#(pid),"cwd":"\#(copy.path)","entrypoint":"cli","status":"busy"}"#)
        logs.write("projects/p/one.jsonl", #"{"type":"user","cwd":"\#(copy.path)","entrypoint":"cli","gitBranch":"review/token-expiry"}"# + "\n" + #"{"type":"assistant","gitBranch":"review/token-expiry","message":{"model":"opus","usage":{"input_tokens":5,"output_tokens":1}}}"# + "\n")
        logs.write("projects/p/one/subagents/agent-a1.jsonl", #"{"type":"user","cwd":"\#(copy.path)","gitBranch":"review/token-expiry"}"# + "\n")
        logs.write("projects/p/one/subagents/agent-a1.meta.json", #"{"agentType":"scout"}"#)
        let scanner = RunScanner(paths: ClaudePaths(root: logs.url))
        await scanner.setFocus(runs: [], menuOpen: true)
        let world = await scanner.scan(now: Date())
        let model = WorkBuilder.build(world: world, runs: [])
        let session = try #require(model.sessions.first { $0.id == "one" })
        #expect(session.place?.label == "review/token-expiry")
        #expect(session.root.model == "opus")
        #expect(session.root.contextTokens == 5)
        #expect(model.projects.first?.path == main.path)
        #expect(session.root.children.first?.id == "a1")
        #expect(session.root.children.first?.place == nil)
    }
}

@Suite("Параллельные сессии")
struct ParallelSessionsTests {
    private func process() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        return process
    }

    @Test("Терминал и VS Code на настоящих процессах: один проект, две сессии, обе работают, а workflow нет")
    func terminalAndEditor() async throws {
        let folder = TempFolder()
        let first = try process()
        let second = try process()
        defer {
            first.terminate()
            second.terminate()
        }
        let updated = Int(Date().timeIntervalSince1970 * 1000)
        folder.write("sessions/\(first.processIdentifier).json", #"{"sessionId":"cli","pid":\#(first.processIdentifier),"cwd":"/x/app","entrypoint":"cli","status":"busy","statusUpdatedAt":\#(updated)}"#)
        folder.write("sessions/\(second.processIdentifier).json", #"{"sessionId":"code","pid":\#(second.processIdentifier),"cwd":"/x/app","entrypoint":"claude-vscode","status":"busy","statusUpdatedAt":\#(updated)}"#)

        let world = await RunScanner(paths: ClaudePaths(root: folder.url)).scan(now: Date())
        let model = WorkBuilder.build(world: world, runs: [])
        #expect(model.projects.count == 1)
        let digest = NowDigest(model, now: Date())
        #expect(!digest.isQuiet)
        #expect(Set(digest.active.compactMap(\.environment)) == [.terminal, .vsCode])
        #expect(digest.active.allSatisfy { WorkPhrases.line($0, mode: .simple) == "Working" })

        let summary = try #require(ProjectBook.summaries(sessions: ProjectBook.sessions(work: model, past: []), tokens: [], filter: ProjectFilter(), now: Date()).first)
        #expect(summary.active.count == 2)
        #expect(Set(summary.environments) == [.terminal, .vsCode])
    }
}

@Suite("Проекты: сводка")
struct ProjectBookTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }()

    private func session(_ id: String, _ path: String?, state: WorkState = .finished, ago: TimeInterval = 3600, environment: WorkEnvironment = .terminal, children: [WorkNode] = []) -> WorkSession {
        let date = now.addingTimeInterval(-ago)
        return WorkSession(id: id, environment: environment, cwd: path, state: state, startedAt: date, lastActivity: date, root: WorkNode(id: id, kind: .main, state: state, children: children))
    }

    private func record(_ id: String, daysAgo: Int = 0, tokens: Int, cwd: String? = nil, entrypoint: String? = nil, agent: String? = nil) -> TokenRecord {
        let day = calendar.date(byAdding: .day, value: -daysAgo, to: now) ?? now
        return TokenRecord(sessionId: id, agentId: agent, cwd: cwd, entrypoint: entrypoint, day: ProjectBook.dayKey(day, calendar: calendar), usage: TokenUsage(input: tokens))
    }

    private func summaries(_ sessions: [WorkSession], tokens: [TokenRecord] = [], filter: ProjectFilter = ProjectFilter()) -> [ProjectSummary] {
        ProjectBook.summaries(sessions: sessions, tokens: tokens, filter: filter, now: now, calendar: calendar)
    }

    @Test("Сначала ждущие и со сбоями, затем работающие, «Без проекта» в конце")
    func order() {
        let broken = WorkNode(id: "x", kind: .subagent, state: .failed)
        let result = summaries([
            session("quiet", "/x/quiet", ago: 60),
            session("nofolder", nil, state: .running, environment: .cowork),
            session("run", "/x/run", state: .running),
            session("failed", "/x/failed", children: [broken]),
            session("wait", "/x/wait", state: .waiting),
        ])
        #expect(result.map(\.path) == ["/x/wait", "/x/failed", "/x/run", "/x/quiet", nil])
        #expect(result[1].failures == 1)
    }

    @Test("Живые сессии отдельно от прошлых, ждущая первой")
    func activeAndPast() throws {
        let project = try #require(summaries([
            session("a", "/x/app", state: .running, ago: 10),
            session("b", "/x/app", state: .waiting, ago: 500),
            session("c", "/x/app", ago: 100),
            session("d", "/x/app", ago: 50),
        ]).first)
        #expect(project.active.map(\.id) == ["b", "a"])
        #expect(project.past.map(\.id) == ["d", "c"])
        #expect(project.lead?.id == "b")
    }

    @Test("Фильтр по дате убирает сессии вне периода, а идущая остаётся всегда")
    func dateFilter() throws {
        let sessions = [
            session("old", "/x/app", ago: 10 * 86400),
            session("recent", "/x/app", ago: 3600),
            session("alive", "/x/app", state: .running, ago: 40 * 86400),
        ]
        let week = try #require(summaries(sessions).first)
        #expect(week.past.map(\.id) == ["recent"])
        #expect(week.active.map(\.id) == ["alive"])
        let month = try #require(summaries(sessions, filter: ProjectFilter(period: .month)).first)
        #expect(Set(month.past.map(\.id)) == ["old", "recent"])
        let range = WorkPeriod.dates(from: now.addingTimeInterval(-11 * 86400), to: now.addingTimeInterval(-9 * 86400))
        let dates = try #require(summaries(sessions, filter: ProjectFilter(period: range)).first)
        #expect(dates.past.map(\.id) == ["old"])
    }

    @Test("Проект вне периода не показывается, а его страница не ломается")
    func outOfPeriod() {
        let sessions = [session("old", "/x/app", ago: 10 * 86400)]
        #expect(summaries(sessions).isEmpty)
        let page = ProjectBook.summary(path: "/x/app", sessions: sessions, tokens: [], filter: ProjectFilter(), now: now, calendar: calendar)
        #expect(page.path == "/x/app")
        #expect(page.past.isEmpty)
    }

    @Test("Фильтр по среде")
    func environmentFilter() throws {
        let sessions = [session("a", "/x/app", environment: .vsCode), session("b", "/x/app", environment: .terminal), session("c", "/x/other", environment: .terminal)]
        let tokens = [record("a", tokens: 100), record("b", tokens: 10)]
        let result = summaries(sessions, tokens: tokens, filter: ProjectFilter(environment: .vsCode))
        #expect(result.map(\.path) == ["/x/app"])
        #expect(result.first?.past.map(\.id) == ["a"])
        #expect(result.first?.inPeriod.total == 100)
        #expect(ProjectBook.environments(of: sessions) == [.vsCode, .terminal])
    }

    @Test("Токены считаются за период и за сегодня, по сессии в копии идут в её проект")
    func tokens() throws {
        var copy = session("copy", "/x/app/.claude/worktrees/one")
        copy.place = GitPlace(isSeparateCopy: true, mainFolder: "/x/app")
        let tokens = [
            record("copy", tokens: 1),
            record("main", daysAgo: 1, tokens: 10),
            record("main", daysAgo: 6, tokens: 100),
            record("main", daysAgo: 7, tokens: 1000),
        ]
        let project = try #require(summaries([copy, session("main", "/x/app")], tokens: tokens).first)
        #expect(project.today.total == 1)
        #expect(project.inPeriod.total == 111)
        #expect(project.byDay[ProjectBook.dayKey(now, calendar: calendar)] == 1)
        #expect(project.byDay.count == 3)
    }

    @Test("Токены сессии, которой ещё нет в списке, попадают в проект по папке")
    func tokensOfUnknownSession() throws {
        let result = summaries([], tokens: [
            record("x", tokens: 5, cwd: "/x/app/.claude/worktrees/one"),
            record("y", tokens: 7, cwd: "/x/app"),
            record("z", tokens: 9, cwd: "/sessions/name", entrypoint: "local-agent"),
        ])
        #expect(Set(result.map(\.path)) == ["/x/app", nil])
        #expect(result.first { $0.path == "/x/app" }?.inPeriod.total == 12)
        #expect(result.first { $0.path == nil }?.inPeriod.total == 9)
    }

    @Test("Живая сессия берётся из живого скана, остальные из логов")
    func merging() {
        let work = WorkModel(projects: [WorkProject(path: "/x/app", sessions: [
            session("live", "/x/app", state: .running),
            session("idle", "/x/app"),
            session("fresh", "/x/app"),
        ])])
        var fromLog = session("live", "/x/app", state: .interrupted)
        fromLog.title = "из лога"
        var idleFromLog = session("idle", "/x/app")
        idleFromLog.title = "из лога"
        let merged = ProjectBook.sessions(work: work, past: [fromLog, idleFromLog])
        #expect(merged.map(\.id).sorted() == ["fresh", "idle", "live"])
        #expect(merged.first { $0.id == "live" }?.state == .running)
        #expect(merged.first { $0.id == "idle" }?.title == "из лога")
    }

    @Test("Книга токенов складывает по сессиям, агентам и запускам")
    func book() {
        let index = SpendIndex([
            TokenRecord(sessionId: "s", day: "2026-01-01", usage: TokenUsage(input: 1)),
            TokenRecord(sessionId: "s", agentId: "a", runId: "r", day: "2026-01-01", usage: TokenUsage(input: 2)),
            TokenRecord(sessionId: "s", agentId: "a", runId: "r", day: "2026-01-02", usage: TokenUsage(input: 4)),
        ])
        #expect(index.sessions["s"]?.total == 7)
        #expect(index.agents["a"]?.total == 6)
        #expect(index.runs["r"]?.total == 6)
    }
}
