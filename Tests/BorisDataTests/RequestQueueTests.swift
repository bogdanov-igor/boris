import BorisCore
import Foundation
import Testing
@testable import BorisData

@Suite("Очередь запросов")
struct RequestQueueTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func request(_ session: String = "s1", agent: String? = nil, tool: String = "Bash", at seconds: TimeInterval = 0, digest: String? = "d1", content: RequestContent = .command("SECRET-CMD", unsandboxed: false)) -> PendingPermission {
        PendingPermission(session: session, agent: agent, tool: tool, command: "SECRET-CMD", content: content, project: "proj", askedAt: t0.addingTimeInterval(seconds), deadline: t0.addingTimeInterval(seconds + 120), digest: digest)
    }

    private func session(_ id: String, _ state: WorkState, environment: WorkEnvironment? = .terminal, lastActivity: Date? = nil) -> WorkSession {
        WorkSession(id: id, environment: environment, cwd: "/x/\(id)", state: state, lastActivity: lastActivity, root: WorkNode(id: id, kind: .main, state: state))
    }

    private func work(_ sessions: WorkSession...) -> WorkModel {
        WorkModel(projects: sessions.map { WorkProject(path: $0.cwd, sessions: [$0]) })
    }

    private func ids(_ rows: [RequestRow]) -> [String] {
        rows.map(\.session)
    }

    @Test("Начиная с самого старого, а ответ на один не трогает другой") func oldestFirst() {
        var queue = RequestQueue()
        let newer = request("newer", at: 30)
        let older = request("older", at: 10)
        queue.add(newer)
        queue.add(older)
        #expect(ids(queue.rows(now: t0)) == ["older", "newer"])
        let accepted = queue.answered(older.id, with: .allow, place: .window, now: t0.addingTimeInterval(40))
        #expect(accepted)
        #expect(queue.open == [newer])
    }

    @Test("Ответ на закрытый запрос не проходит") func answerOnce() {
        var queue = RequestQueue()
        let asked = request()
        queue.add(asked)
        let first = queue.answered(asked.id, with: .allow, place: .window, now: t0)
        let second = queue.answered(asked.id, with: .deny(reason: ""), place: .window, now: t0)
        #expect(first)
        #expect(!second)
        #expect(queue.decisions.count == 1)
        #expect(queue.decisions[0].outcome == .allowed)
    }

    @Test("Сессия ждёт, а запроса здесь нет: показывается как ожидание без кнопок") func waitingWithoutRequest() {
        var queue = RequestQueue()
        queue.note(work: work(session("s1", .waiting), session("s2", .running)), now: t0)
        #expect(queue.rows(now: t0) == [.waiting(session("s1", .waiting))])
    }

    @Test("Сессия с запросом не показывается второй раз") func noDuplicate() {
        var queue = RequestQueue()
        queue.add(request("s1"))
        queue.note(work: work(session("s1", .waiting)), now: t0)
        let rows = queue.rows(now: t0)
        #expect(rows.count == 1)
        if case .open = rows[0] {} else { Issue.record("это открытый запрос") }
    }

    @Test("Сначала открытые, потом истёкшие, потом ждущие в сессии") func groups() {
        var queue = RequestQueue()
        let gone = request("expired", at: 0)
        queue.add(gone)
        queue.expire(gone.id)
        queue.add(request("open", at: 50))
        queue.note(work: work(session("expired", .waiting), session("open", .waiting), session("elsewhere", .waiting)), now: t0)
        #expect(ids(queue.rows(now: t0)) == ["open", "expired", "elsewhere"])
    }

    @Test("Сразу после ответа сессия не выглядит ожидающей, пока файлы догоняют") func settlingAfterAnswer() {
        var queue = RequestQueue()
        let asked = request("s1")
        queue.add(asked)
        queue.note(work: work(session("s1", .waiting)), now: t0)
        _ = queue.answered(asked.id, with: .allow, place: .window, now: t0)
        #expect(queue.rows(now: t0.addingTimeInterval(1)).isEmpty)
        #expect(queue.rows(now: t0.addingTimeInterval(RequestQueue.settling + 1)).count == 1, "если сессия всё ещё ждёт, это уже новый вопрос")
    }

    @Test("Время истекло: запрос остаётся на виду, без своего текста") func expiry() {
        var queue = RequestQueue()
        let asked = request()
        queue.add(asked)
        queue.note(work: work(session("s1", .waiting)), now: t0)
        queue.expire(asked.id)
        #expect(queue.open.isEmpty)
        #expect(queue.decisions.isEmpty, "решения ещё нет: запрос ждёт в Claude")
        guard case .expired(let expired) = queue.rows(now: t0).first else {
            Issue.record("карточка истёкшего запроса")
            return
        }
        #expect(expired.brief == RequestBrief(tool: "Bash", kind: .command))
        #expect(!"\(expired)".contains("SECRET-CMD"))
    }

    @Test("Истёкший запрос нельзя разрешить") func noAnswerAfterExpiry() {
        var queue = RequestQueue()
        let asked = request()
        queue.add(asked)
        queue.expire(asked.id)
        let accepted = queue.answered(asked.id, with: .allow, place: .window, now: t0)
        #expect(!accepted)
        #expect(queue.decisions.isEmpty)
    }

    @Test("Время вышло, а весть об этом ещё в пути: ответ не принимается и в историю не идёт") func noAnswerAtDeadline() {
        var queue = RequestQueue()
        let asked = request()
        queue.add(asked)
        for answer in [HookAnswer.allow, .deny(reason: "")] {
            let accepted = queue.answered(asked.id, with: answer, place: .window, now: asked.deadline)
            #expect(!accepted)
        }
        #expect(queue.open == [asked], "посредника уже отпустили, и карточка сейчас станет истёкшей")
        #expect(queue.decisions.isEmpty)
    }

    @Test("Разрешить можно только то, что можно прочитать, а вопрос принимает только ответы") func answerMustFit() {
        let question = RequestContent.questions([RequestQuestion(text: "q", options: [.init(label: "a")])])
        let cases: [(RequestContent, HookAnswer, Bool)] = [
            (.unreadable("x"), .allow, false),
            (.unreadable("x"), .answers(["q": "a"]), false),
            (.unreadable("x"), .deny(reason: ""), true),
            (question, .allow, false),
            (question, .deny(reason: ""), true),
            (.command("x", unsandboxed: false), .answers(["q": "a"]), false),
            (.plan("p"), .answers(["q": "a"]), false),
        ]
        for (content, answer, fits) in cases {
            var queue = RequestQueue()
            let asked = request(content: content)
            queue.add(asked)
            let accepted = queue.answered(asked.id, with: answer, place: .window, now: t0)
            #expect(accepted == fits, "\(content) \(answer)")
            #expect(queue.decisions.count == (fits ? 1 : 0))
            #expect(queue.open.count == (fits ? 0 : 1), "непринятый ответ не убирает запрос")
        }
    }

    @Test("Ответили в Claude после истечения: карточка исчезает", arguments: [
        HookSignal.turnStopped(session: "s1"),
        .sessionEnded(session: "s1", reason: "other", cwd: nil),
        .toolStarted(session: "s1", agent: nil, tool: "Read"),
    ])
    func expiredClosedBySignal(signal: HookSignal) {
        var queue = RequestQueue()
        let asked = request()
        queue.add(asked)
        queue.expire(asked.id)
        let released = queue.note(signal, now: t0.addingTimeInterval(200))
        #expect(released.isEmpty)
        #expect(queue.expired.isEmpty)
        #expect(queue.decisions.first?.outcome == .expired)
        #expect(queue.decisions.first?.place == .session)
        #expect(queue.decisions.first?.waited == 120)
    }

    @Test("Другая сессия и другой агент не закрывают истёкшую карточку", arguments: [
        HookSignal.turnStopped(session: "s2"),
        .toolStarted(session: "s2", agent: nil, tool: "Read"),
        .toolStarted(session: "s1", agent: "helper", tool: "Read"),
        .agentStopped(session: "s1", agent: "helper"),
        .toolFinished(session: "s1", agent: nil, tool: "Bash"),
    ])
    func expiredStays(signal: HookSignal) {
        var queue = RequestQueue()
        let asked = request()
        queue.add(asked)
        queue.expire(asked.id)
        _ = queue.note(signal, now: t0.addingTimeInterval(200))
        #expect(queue.expired.count == 1)
    }

    @Test("Сессия перестала ждать по файлам: истёкшая карточка исчезает") func expiredClosedByFiles() {
        var queue = RequestQueue()
        let asked = request()
        queue.add(asked)
        queue.expire(asked.id)
        queue.note(work: work(session("s1", .waiting)), now: t0.addingTimeInterval(130))
        #expect(queue.expired.count == 1)
        queue.note(work: work(session("s1", .running)), now: t0.addingTimeInterval(140))
        #expect(queue.expired.isEmpty)
    }

    @Test("Незнакомая сессия не держит карточку вечно") func expiredUnknownSession() {
        var queue = RequestQueue()
        let asked = request()
        queue.add(asked)
        queue.expire(asked.id)
        queue.note(work: work(), now: t0.addingTimeInterval(130))
        #expect(queue.expired.count == 1, "сессию просто ещё не видно")
        queue.note(work: work(), now: t0.addingTimeInterval(120 + HookState.waitingExpiry + 1))
        #expect(queue.expired.isEmpty)
    }

    @Test("Посредник ушёл раньше срока: это ответ в Claude") func hookGone() {
        var queue = RequestQueue()
        let asked = request()
        queue.add(asked)
        queue.gone(asked.id, now: t0.addingTimeInterval(37))
        #expect(queue.open.isEmpty)
        #expect(queue.expired.isEmpty)
        #expect(queue.decisions.first?.outcome == .closedInClaude)
        #expect(queue.decisions.first?.place == .session)
        #expect(queue.decisions.first?.waited == 37)
    }

    @Test("Инструмент выполнился: значит, разрешили в Claude, а посредника можно отпустить") func allowedInClaude() {
        var queue = RequestQueue()
        let asked = request(digest: "d1")
        queue.add(asked)
        let released = queue.toolDone(session: "s1", digest: "d1", now: t0.addingTimeInterval(9))
        #expect(released == [asked.id])
        #expect(queue.open.isEmpty)
        #expect(queue.decisions.first?.outcome == .allowed)
        #expect(queue.decisions.first?.place == .session)
    }

    @Test("Соседняя команда того же агента не закрывает запрос") func parallelToolIsNotTheRequest() {
        var queue = RequestQueue()
        let asked = request(digest: "asking")
        queue.add(asked)
        let neighbour = queue.toolDone(session: "s1", digest: "neighbour", now: t0)
        let elsewhere = queue.toolDone(session: "s2", digest: "asking", now: t0)
        #expect(neighbour.isEmpty)
        #expect(elsewhere.isEmpty)
        #expect(queue.open == [asked])
    }

    @Test("Конец хода и конец сессии закрывают открытые запросы") func turnEnds() {
        var queue = RequestQueue()
        let main = request("s1")
        let helper = request("s1", agent: "h1", digest: "d2")
        let other = request("s2", digest: "d3")
        queue.add(main)
        queue.add(helper)
        queue.add(other)
        let turn = queue.note(.turnStopped(session: "s1"), now: t0)
        let agent = queue.note(.agentStopped(session: "s1", agent: "h1"), now: t0)
        let ended = queue.note(.sessionEnded(session: "s2", reason: "other", cwd: nil), now: t0)
        #expect(turn == [main.id], "ход главного агента не закрывает запрос помощника")
        #expect(agent == [helper.id])
        #expect(ended == [other.id])
        #expect(queue.open.isEmpty)
    }

    @Test("Начало инструмента не закрывает открытый запрос: так и начинается вызов") func toolStartKeepsRequest() {
        var queue = RequestQueue()
        queue.add(request())
        let released = queue.note(.toolStarted(session: "s1", agent: nil, tool: "Bash"), now: t0)
        #expect(released.isEmpty)
        #expect(queue.open.count == 1)
    }

    @Test("Итог зависит от вида запроса", arguments: [
        (RequestContent.command("x", unsandboxed: false), HookAnswer.allow, RequestOutcome.allowed),
        (.command("x", unsandboxed: false), .deny(reason: "y"), .denied),
        (.plan("p"), .allow, .planApproved),
        (.plan("p"), .deny(reason: ""), .planDenied),
        (.questions([RequestQuestion(text: "q", options: [.init(label: "a")])]), .answers(["q": "a"]), .answered),
    ])
    func outcomes(content: RequestContent, answer: HookAnswer, outcome: RequestOutcome) {
        var queue = RequestQueue()
        let asked = request(content: content)
        queue.add(asked)
        let accepted = queue.answered(asked.id, with: answer, place: .mini, now: t0.addingTimeInterval(19))
        #expect(accepted)
        #expect(queue.decisions.first?.outcome == outcome)
        #expect(queue.decisions.first?.place == .mini)
        #expect(queue.decisions.first?.waited == 19)
    }

    @Test("История: только имя файла, ни команды, ни причины, ни ответа") func historyHoldsNoText() throws {
        var queue = RequestQueue()
        queue.note(work: work(session("s1", .waiting, environment: .vsCode)), now: t0)
        let contents: [(RequestContent, HookAnswer)] = [
            (.command("SECRET-CMD", unsandboxed: false), .deny(reason: "SECRET-REASON")),
            (.file(path: "/SECRET-FOLDER/auth.swift", lines: [RequestDiffLine(added: true, text: "SECRET-LINE")], whole: false, everyOccurrence: false), .allow),
            (.questions([RequestQuestion(text: "SECRET-QUESTION", options: [.init(label: "SECRET-LABEL")])]), .answers(["SECRET-QUESTION": "SECRET-LABEL"])),
            (.plan("SECRET-PLAN"), .deny(reason: "SECRET-COMMENT")),
        ]
        for (content, answer) in contents {
            let asked = request(content: content)
            queue.add(asked)
            let accepted = queue.answered(asked.id, with: answer, place: .window, now: t0)
            #expect(accepted)
        }
        let folder = TempFolder()
        let file = folder.url.appendingPathComponent("decisions.json")
        RequestLog.save(queue.decisions, to: file)
        RequestLog.flush()
        let written = try String(contentsOf: file, encoding: .utf8)
        #expect(!written.contains("SECRET"))
        #expect(written.contains("auth.swift"))
        #expect(queue.decisions[1].brief.fileName == "auth.swift")
        #expect(queue.decisions[0].environment == "VS Code")
        #expect(RequestLog.load(from: file) == queue.decisions)
    }

    @Test("Сломанный файл истории ничего не ломает") func brokenLog() {
        let folder = TempFolder()
        let file = folder.write("decisions.json", "{ not json")
        #expect(RequestLog.load(from: file).isEmpty)
        #expect(RequestLog.load(from: folder.url.appendingPathComponent("absent.json")).isEmpty)
    }

    @Test("Решено сегодня: только сегодня, свежие сверху") func today() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        var queue = RequestQueue()
        for (index, day) in [-1, 0, 0].enumerated() {
            let asked = request(at: TimeInterval(index))
            queue.add(asked)
            _ = queue.answered(asked.id, with: .allow, place: .window, now: t0.addingTimeInterval(TimeInterval(day) * 86400 + TimeInterval(index)))
        }
        let shown = queue.decisions(on: t0, calendar: calendar)
        #expect(shown.count == 2)
        #expect(shown[0].at > shown[1].at)
    }

    @Test("Длинная история не растёт без конца") func historyLimit() {
        var queue = RequestQueue()
        for index in 0..<(RequestQueue.historyLimit + 3) {
            let asked = request(at: TimeInterval(index))
            queue.add(asked)
            _ = queue.answered(asked.id, with: .allow, place: .window, now: t0)
        }
        #expect(queue.decisions.count == RequestQueue.historyLimit)
    }

    @Test("Режим «не беспокоить» и всё остальное: сама очередь никогда не отвечает") func neverAnswersByItself() {
        var queue = RequestQueue()
        let asked = request()
        queue.add(asked)
        for offset in stride(from: 0.0, through: 3600, by: 60) {
            queue.note(work: work(session("s1", .waiting)), now: t0.addingTimeInterval(offset))
        }
        #expect(queue.open == [asked], "только ответ, истечение или уход посредника убирают запрос")
        #expect(queue.decisions.isEmpty)
    }

    @Test("Запрос в кратком виде не теряет своего типа, даже когда его нельзя прочитать", arguments: [
        ("AskUserQuestion", RequestBrief.Kind.questions),
        ("ExitPlanMode", .plan),
        ("Bash", .command),
        ("Write", .file),
        ("mcp__x__y", .other),
    ])
    func briefOfUnreadable(tool: String, kind: RequestBrief.Kind) {
        #expect(RequestBrief(request(tool: tool, content: .unreadable("x"))).kind == kind)
    }
}
