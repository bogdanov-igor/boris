import BorisCore
import Foundation
import Testing
@testable import BorisData

private let t0 = Date(timeIntervalSince1970: 1_762_400_000)

/// What the Mac accepts from a machine, whatever is really running there under the helper's name.
@Suite("Что Mac принимает от машины")
struct RemoteMessageTests {
    private func message(_ text: String) -> RemoteMessage? {
        RemoteMessage(line: Data(text.utf8))
    }

    @Test("Лишние поля отбрасываются, а слова чужого вида не проходят") func dropsWhatItDoesNotKnow() {
        let line = #"{"k":"sessions","list":[{"id":"s-1","status":"Fixed the bug in auth","waiting":"approve Bash: rm -rf /","cwd":"not a path","version":"two words","prompt":"text","text":"more"},{"id":"bad id with words"},{"id":"s-2","status":"busy","waiting":"approve Bash","cwd":"/srv/app","version":"2.1.0","started":1762400000000,"updated":1762400100000}]}"#
        guard case .sessions(let list)? = message(line) else {
            Issue.record("Строка не разобрана")
            return
        }
        #expect(list.map(\.id) == ["s-1", "s-2"])
        #expect(list[0].status == nil)
        #expect(list[0].waitingFor == nil)
        #expect(list[0].cwd == nil)
        #expect(list[0].version == nil)
        #expect(list[1].status == "busy")
        #expect(list[1].waitingFor == "approve Bash")
        #expect(list[1].startedAt == Date(timeIntervalSince1970: 1_762_400_000))
    }

    @Test("Строка с числами проверяется поле за полем") func rowsAreChecked() {
        let good = #"["s-1",null,null,"/srv/app",1762400700,"claude-sonnet-5-5",1,2,3,4]"#
        let cases = [
            good,
            #"["s-1","a1","wf_1","/srv/app",1762400700,null,1,2,3,4]"#,
            // Each of these breaks one rule.
            #"["two words",null,null,"/srv/app",1762400700,"m",1,2,3,4]"#,
            #"["s-1",null,null,"/srv/app",1762400700,"m",1,2,3]"#,
            #"["s-1",null,null,"/srv/app",1762400700,"m",-1,2,3,4]"#,
            #"["s-1",null,null,"/srv/app",1762400700,"m",1.5,2,3,4]"#,
            #"["s-1",null,null,"/srv/app",1762400700,"m",true,2,3,4]"#,
            #"["s-1",null,null,"/srv/app",1762400700,"m","1",2,3,4]"#,
            #"["s-1",null,null,"/srv/app",1e30,"m",1,2,3,4]"#,
            #"["s-1",null,null,"/srv/app","now","m",1,2,3,4]"#,
        ]
        let line = #"{"k":"numbers","full":true,"rows":[\#(cases.joined(separator: ","))]}"#
        guard case .numbers(let full, let rows)? = message(line) else {
            Issue.record("Строка не разобрана")
            return
        }
        #expect(full)
        #expect(rows.count == 2)
        #expect(rows[0].usage == TokenUsage(input: 1, output: 2, cacheRead: 3, cacheWrite: 4))
        #expect(rows[1].agent == "a1")
        #expect(rows[1].run == "wf_1")
    }

    @Test("Текст вместо модели и пути не становится словом на экране") func textInPlaceOfWords() {
        let line = #"{"k":"numbers","rows":[["s-1",null,null,"relative/path with words",1762400700,"some words about a secret",1,2,3,4]]}"#
        guard case .numbers(_, let rows)? = message(line) else {
            Issue.record("Строка не разобрана")
            return
        }
        #expect(rows.first?.cwd == nil)
        #expect(rows.first?.model == nil)
        #expect(rows.first?.usage.input == 1)
    }

    @Test("Неизвестное и чепуха просто не считаются", arguments: ["", "nonsense", "[1]", #"{"k":"new-kind-from-the-future"}"#, #"{"k":"numbers"}"#, #"{"k":"sessions","list":"x"}"#, #"{"k":"info"}"#])
    func nonsense(line: String) {
        #expect(message(line) == nil)
    }

    @Test("Состояние хуков только из известных слов") func hooksWord() {
        guard case .alive(let vitals)? = message(#"{"k":"alive","socket":true,"claude":true,"hooks":"something new"}"#) else {
            Issue.record("Строка не разобрана")
            return
        }
        #expect(vitals.hooks == nil)
        #expect(vitals.socket)
    }
}

@Suite("Сессии на удалённой машине")
struct RemoteBookTests {
    private func book(_ reports: [RemoteSessionReport] = []) -> RemoteBook {
        var book = RemoteBook(host: "build-server")
        book.linkUp()
        book.take(sessions: reports, now: t0)
        return book
    }

    private func model(_ book: RemoteBook, now: Date = t0) -> WorkModel {
        let world = book.world(now: now)
        var snapshot = WorldSnapshot(takenAt: now, sessions: world.sessions)
        snapshot.endedSessions = world.ended
        snapshot.agents = world.agents
        snapshot.places = world.places
        return WorkBuilder.build(world: snapshot, runs: [])
    }

    private func session(_ book: RemoteBook, _ id: String = "s-1", now: Date = t0) -> WorkSession? {
        model(book, now: now).sessions.first { $0.id == id }
    }

    @Test("Сессия показывается с именем машины как средой") func hostIsTheEnvironment() throws {
        let book = book([RemoteSessionReport(id: "s-1", status: "busy", cwd: "/srv/app", startedAt: t0, updatedAt: t0)])
        let found = try #require(session(book))
        #expect(found.environment == .remote(host: "build-server"))
        #expect(WorkPhrases.environment(found.environment) == "build-server")
        #expect(found.state == .running)
        #expect(found.cwd == "/srv/app")
        #expect(found.displayName == "app")
    }

    @Test("Номер процесса с машины не попадает на Mac") func noProcessNumberHere() {
        let book = book([RemoteSessionReport(id: "s-1", status: "busy")])
        // A number from another machine could well be a process on this Mac.
        #expect(book.world(now: t0).sessions.allSatisfy { $0.pid == 0 })
    }

    @Test("Обрыв: живые сессии «нет связи», законченные остаются законченными") func dropMarksLiveSessions() throws {
        var book = book([
            RemoteSessionReport(id: "busy", status: "busy"),
            RemoteSessionReport(id: "waits", status: "waiting", waitingFor: "approve Bash"),
            RemoteSessionReport(id: "idle", status: "idle"),
        ])
        book.linkDown(now: t0)
        #expect(session(book, "busy")?.state == .unreachable)
        let waits = try #require(session(book, "waits"))
        #expect(waits.state == .unreachable)
        #expect(waits.waitingFor == nil)
        #expect(session(book, "idle")?.state == .finished)
        #expect(book.world(now: t0).lost == ["busy", "waits"])
    }

    @Test("Нет связи не означает работы и не ждёт человека") func noConnectionIsNotWork() throws {
        var book = book([RemoteSessionReport(id: "s-1", status: "waiting", waitingFor: "approve Bash")])
        book.linkDown(now: t0)
        let work = model(book)
        #expect(!work.isWorking)
        #expect(work.waitingSessions.isEmpty)
        #expect(work.workingAgents == 0)
        #expect(MoodBoard().mood(work: work, broken: false, matrix: ReactionMatrix(), now: t0) == .sleeping)
        // Still on the list of what is going on, with the words from the design.
        let digest = NowDigest(work, now: t0)
        #expect(digest.active.map(\.id) == ["s-1"])
        #expect(!digest.isQuiet)
        let found = try #require(work.sessions.first)
        Localizer.use(.en)
        #expect(WorkPhrases.line(found, mode: .simple) == "No connection to the remote machine")
        #expect(WorkPhrases.state(.unreachable, mode: .technical) == "No connection")
    }

    @Test("Связь вернулась: сессии снова говорят правду") func reconnectTellsTheTruth() {
        var book = book([RemoteSessionReport(id: "s-1", status: "busy"), RemoteSessionReport(id: "s-2", status: "busy")])
        book.linkDown(now: t0)
        book.linkUp()
        book.take(sessions: [RemoteSessionReport(id: "s-1", status: "busy")], now: t0.addingTimeInterval(600))
        #expect(session(book, "s-1")?.state == .running)
        // It ended while nobody could see, so all that is known is that it is over.
        #expect(session(book, "s-2")?.state == .finished)
        #expect(book.world(now: t0).lost.isEmpty)
    }

    @Test("Сутки без связи: сессия уходит из текущих") func aDayWithoutConnection() {
        var book = book([RemoteSessionReport(id: "s-1", status: "busy")])
        book.linkDown(now: t0)
        #expect(session(book, now: t0.addingTimeInterval(23 * 3600))?.state == .unreachable)
        #expect(session(book, now: t0.addingTimeInterval(25 * 3600)) == nil)
    }

    @Test("Процесс исчез, оставив файл: сессия прервана") func vanishedProcess() {
        let book = book([RemoteSessionReport(id: "s-1", status: "busy", gone: true)])
        #expect(session(book)?.state == .interrupted)
    }

    @Test("Сессия ушла из списка: закончена") func leftTheList() {
        var book = book([RemoteSessionReport(id: "s-1", status: "busy")])
        book.take(sessions: [], now: t0.addingTimeInterval(5))
        let found = session(book)
        #expect(found?.state == .finished)
        #expect(found?.lastActivity == t0.addingTimeInterval(5))
    }

    @Test("Хук сообщает о сессии раньше списка") func hooksComeFirst() throws {
        var book = book()
        book.take(.sessionStarted(session: "s-1", source: "startup", cwd: "/srv/app"), now: t0)
        book.take(.toolStarted(session: "s-1", agent: nil, tool: "Bash"), now: t0)
        let found = try #require(session(book))
        #expect(found.state == .running)
        #expect(found.cwd == "/srv/app")
        book.take(.turnStopped(session: "s-1"), now: t0.addingTimeInterval(1))
        #expect(session(book)?.state == .finished)
        book.take(.toolStarted(session: "s-1", agent: nil, tool: "Read"), now: t0.addingTimeInterval(2))
        #expect(session(book)?.state == .running)
        book.take(.sessionEnded(session: "s-1", reason: "other", cwd: nil), now: t0.addingTimeInterval(3))
        #expect(session(book)?.state == .finished)
    }

    @Test("Сессия, известная только по хукам, не работает вечно") func hookOnlySessionGoesQuiet() {
        var book = book()
        book.take(.toolStarted(session: "s-1", agent: "a1", tool: "Bash"), now: t0)
        #expect(session(book)?.state == .running)
        #expect(session(book, now: t0.addingTimeInterval(RemoteBook.hookQuiet + 1))?.state == .finished)
    }

    @Test("Агенты видны по хукам и заканчиваются") func agents() throws {
        var book = book([RemoteSessionReport(id: "s-1", status: "busy")])
        book.take(.agentStarted(session: "s-1", agent: "a1"), now: t0)
        var found = try #require(session(book))
        #expect(found.workingAgents == 2)
        book.take(.agentStopped(session: "s-1", agent: "a1"), now: t0.addingTimeInterval(1))
        found = try #require(session(book))
        #expect(found.root.children.first?.state == .finished)
        #expect(found.workingAgents == 1)

        // A connection that drops ends what is known about agents, not the session.
        book.take(.agentStarted(session: "s-1", agent: "a2"), now: t0.addingTimeInterval(2))
        book.linkDown(now: t0.addingTimeInterval(3))
        book.linkUp()
        found = try #require(session(book))
        #expect(found.root.flattened.first { $0.id == "a2" }?.state == .finished)
    }

    @Test("Отдельная копия проекта относится к главной") func separateCopy() {
        let book = book([RemoteSessionReport(id: "s-1", status: "busy", cwd: "/srv/app/.claude/worktrees/feature")])
        #expect(session(book)?.projectPath == "/srv/app")
    }

    @Test("События записываются без слов, и их не становится слишком много") func eventsAreBounded() {
        var book = book()
        for index in 0..<(RemoteBook.eventsKept + 50) {
            book.take(.toolStarted(session: "s-1", agent: nil, tool: "T\(index)"), now: t0)
        }
        let events = book.events(session: "s-1")
        #expect(events.count == RemoteBook.eventsKept)
        #expect(events.last?.kind == .tool("T\(RemoteBook.eventsKept + 49)"))
        book.take(.permissionAsked(session: "s-1", tool: "Bash"), now: t0)
        #expect(book.events(session: "s-1").last?.kind == .waiting(tool: "Bash"))
    }

    // MARK: - Spend

    private func row(_ session: String = "s-1", agent: String? = nil, time: Int = 1_762_400_700, model: String? = "claude-sonnet-5-5", input: Int = 10) -> RemoteSpendRow {
        RemoteSpendRow(session: session, agent: agent, cwd: "/srv/app", time: time, model: model, usage: TokenUsage(input: input))
    }

    @Test("Строка заменяет прежнюю, а полный список всё целиком") func rowsReplace() {
        var book = RemoteBook(host: "m")
        book.take(rows: [row(input: 10), row("s-2", input: 5)])
        book.take(rows: [row(input: 30)])
        #expect(book.spendRows.map(\.usage.input).sorted() == [5, 30])
        book.take(rows: [row(input: 7)], full: true)
        #expect(book.spendRows.map(\.usage.input) == [7])
    }

    @Test("День считается по часам этого Mac") func dayOfThisMac() {
        // 23:50 in London, and already tomorrow in Tokyo.
        let time = 1_762_473_000
        var book = RemoteBook(host: "m")
        book.take(rows: [row(time: time)])
        let london = book.records(timeZone: TimeZone(identifier: "Europe/London") ?? .gmt)
        let tokyo = book.records(timeZone: TimeZone(identifier: "Asia/Tokyo") ?? .gmt)
        #expect(london.first?.day != tokyo.first?.day)
        #expect(london.first?.host == "m")
    }

    @Test("Расход виден по среде с именем машины и складывается с местным") func spendByEnvironment() throws {
        var book = RemoteBook(host: "build-server")
        let day = TokenBook(records: [], now: t0).today
        let time = Int(t0.timeIntervalSince1970)
        book.take(rows: [row(time: time, input: 1000)])
        let records = book.records() + [TokenRecord(sessionId: "here", cwd: "/x/local", entrypoint: "cli", day: day, model: "claude-sonnet-5-5", usage: TokenUsage(input: 5))]
        let ledger = TokenBook(records: records, now: t0)
        let places = ledger.report(.today).lines(.environments)
        #expect(places.first { $0.key == .environment(.remote(host: "build-server")) }?.usage.input == 1000)
        #expect(places.first { $0.key == .environment(.terminal) }?.usage.input == 5)
        #expect(ledger.report(.today).usage.input == 1005)
        #expect(ledger.spent(session: "s-1")?.input == 1000)
        #expect(ledger.report(.today).lines(.projects).contains { $0.key == .project("/srv/app") })
        #expect(ledger.report(.today).estimate.pricedTokens == 1005)
    }

    @Test("Старые сессии с машины видны в проектах по числам") func pastSessions() throws {
        var book = RemoteBook(host: "build-server")
        book.take(rows: [row(time: 900, input: 1), row(time: 1800, input: 2), row(agent: "a1", time: 2700, input: 4)])
        let past = try #require(book.pastSessions().first)
        #expect(past.environment == .remote(host: "build-server"))
        #expect(past.state == .finished)
        #expect(past.root.tokens?.input == 7)
        #expect(past.startedAt == Date(timeIntervalSince1970: 900))
        #expect(past.lastActivity == Date(timeIntervalSince1970: 3600))
        #expect(past.cwd == "/srv/app")
    }

    @Test("Сессия без связи стоит в проекте среди текущих") func projectsListThemAsCurrent() throws {
        var book = book([RemoteSessionReport(id: "s-1", status: "busy", cwd: "/srv/app", startedAt: t0, updatedAt: t0)])
        book.take(rows: [row(time: Int(t0.timeIntervalSince1970))])
        book.linkDown(now: t0)
        let sessions = ProjectBook.sessions(work: model(book), past: book.pastSessions(), logsReadAt: t0)
        #expect(sessions.count == 1)
        #expect(sessions.first?.state == .unreachable)
        let project = try #require(ProjectBook.summaries(sessions: sessions, tokens: book.records(), filter: ProjectFilter(period: .week), now: t0).first)
        #expect(project.active.map(\.id) == ["s-1"])
        #expect(project.path == "/srv/app")
        #expect(project.inPeriod.input == 10)
    }

    @Test("Фильтр по машине находит и расход, и сессии") func filterByMachine() {
        var book = book([RemoteSessionReport(id: "s-1", status: "busy", cwd: "/srv/app", startedAt: t0, updatedAt: t0)])
        book.take(rows: [row(time: Int(t0.timeIntervalSince1970))])
        let sessions = ProjectBook.sessions(work: model(book), past: [])
        let filter = ProjectFilter(period: .week, environment: .remote(host: "build-server"))
        #expect(ProjectBook.summaries(sessions: sessions, tokens: book.records(), filter: filter, now: t0).first?.inPeriod.input == 10)
        let other = ProjectFilter(period: .week, environment: .remote(host: "another"))
        #expect(ProjectBook.summaries(sessions: sessions, tokens: book.records(), filter: other, now: t0).isEmpty)
    }

    @Test("Отчёт диагностики не называет машины") func diagnosticsNamesNoMachines() {
        var status = ConnectionStatus(world: WorldSnapshot(takenAt: t0), hooks: .notConnected, hookState: HookState(), hooksSince: t0, now: t0)
        status.remote = RemoteSummary(machines: 2, connected: 1, failures: [.refused])
        let report = Diagnostics.report(world: WorldSnapshot(takenAt: t0), paths: ClaudePaths(root: URL(fileURLWithPath: "/nonexistent")), appVersion: "1", connection: status, now: t0)
        #expect(report.contains("Remote machines: 2, connected: 1, problems: refused"))
    }
}

/// The engine treats remote sessions as it treats those on this Mac.
@Suite("Удалённые сессии в общей картине")
struct RemoteInEngineTests {
    private final class Last: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: WorkEngine.Output?

        func set(_ output: WorkEngine.Output) {
            lock.lock()
            stored = output
            lock.unlock()
        }

        var value: WorkEngine.Output? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }

    private func engine(_ folder: TempFolder, last: Last) -> WorkEngine {
        WorkEngine(paths: ClaudePaths(root: folder.url), others: { [] }) { last.set($0) }
    }

    private func world(_ reports: [RemoteSessionReport], up: Bool = true) -> RemoteWorld {
        var book = RemoteBook(host: "build-server")
        if up { book.linkUp() }
        book.take(sessions: reports, now: t0)
        if !up { book.linkDown(now: t0) }
        return book.world(now: t0)
    }

    @Test("Ждущая сессия с машины уведомляет с именем машины") func waitingBecomesAnEvent() async {
        let folder = TempFolder()
        let last = Last()
        let engine = engine(folder, last: last)
        await engine.setRemote(world([RemoteSessionReport(id: "s-1", status: "waiting", waitingFor: "approve Bash", cwd: "/srv/app")]))
        _ = await engine.scanOnce()
        try? await Task.sleep(for: .milliseconds(10))
        var output = await engine.scanOnce()
        #expect(output.model.sessions.first?.environment == .remote(host: "build-server"))
        #expect(output.model.waitingSessions.map(\.id) == ["s-1"])
        // Past the delay a session gets before it counts as waiting.
        await engine.configure(status: StatusConfig(), events: DetectorConfig(waitingDelay: 0))
        output = await engine.scanOnce()
        let event = output.events.first { $0.kind == .waiting }
        #expect(event?.environment == .remote(host: "build-server"))
        #expect(event?.toolName == "Bash")
    }

    @Test("Сигнал с машины ложится на её сессию и не говорит ничего о хуках этого Mac") func signalsFromAMachine() async throws {
        let folder = TempFolder()
        let last = Last()
        let engine = engine(folder, last: last)
        await engine.setRemote(world([RemoteSessionReport(id: "s-1", status: "busy")]))
        _ = await engine.scanOnce()
        await engine.receive(.permissionAsked(session: "s-1", tool: "Bash"), fromThisMac: false)
        #expect(await arrives { last.value?.model.waitingSessions.first?.id == "s-1" })
        #expect(last.value?.hooks.lastEventAt == nil)
    }

    @Test("Когда связь пропала, прежнее «ждёт» больше не считается") func lostSessionsForgetWhatHooksSaid() async throws {
        let folder = TempFolder()
        let last = Last()
        let engine = engine(folder, last: last)
        await engine.setRemote(world([RemoteSessionReport(id: "s-1", status: "busy")]))
        _ = await engine.scanOnce()
        await engine.receive(.permissionAsked(session: "s-1", tool: "Bash"), fromThisMac: false)
        #expect(await arrives { last.value?.model.waitingSessions.count == 1 })

        await engine.setRemote(world([RemoteSessionReport(id: "s-1", status: "busy")], up: false))
        #expect(await arrives { last.value?.model.sessions.first?.state == .unreachable })

        // Back up and busy. The answer was given on the machine meanwhile, and nothing here may still say it waits.
        await engine.setRemote(world([RemoteSessionReport(id: "s-1", status: "busy")]))
        #expect(await arrives { last.value?.model.sessions.first?.state == .running })
    }

    @Test("Машина не может подменить сессию этого Mac") func cannotReplaceALocalSession() async throws {
        let folder = TempFolder()
        let pid = ProcessInfo.processInfo.processIdentifier
        folder.write("sessions/\(pid).json", #"{"pid":\#(pid),"sessionId":"here","cwd":"/x/local","status":"busy","entrypoint":"cli"}"#)
        let last = Last()
        let engine = engine(folder, last: last)
        await engine.setRemote(world([RemoteSessionReport(id: "here", status: "idle", cwd: "/srv/evil")]))
        let output = await engine.scanOnce()
        let found = try #require(output.model.sessions.first { $0.id == "here" })
        #expect(found.environment == .terminal)
        #expect(found.cwd == "/x/local")
        #expect(output.world.sessions.filter { $0.sessionId == "here" }.count == 1)
    }

    @Test("Удалённая сессия не считается ожившим процессом на Mac") func noLocalProcessBookkeeping() async throws {
        let folder = TempFolder()
        let last = Last()
        let engine = engine(folder, last: last)
        await engine.setRemote(world([RemoteSessionReport(id: "s-1", status: "busy")]))
        _ = await engine.scanOnce()
        let output = await engine.scanOnce()
        #expect(output.detectorMemory.liveSessions?.isEmpty != false)
        #expect(output.world.sessions.allSatisfy { $0.pid == 0 && $0.isUnlisted })
    }
}
