import BorisCore
import Foundation
import Testing

/// The Russian of the catalog, read the way the app's table is made. Tests run in English, so this is the way to see the other language.
private enum Russian {
    private static let parts: [[String: Entry]] = {
        let folder = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Strings")
        return ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".json") }.compactMap { name in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)) else { return nil }
            return try? JSONDecoder().decode([String: Entry].self, from: data)
        }
    }()

    private enum Entry: Decodable, Sendable {
        case plain(String)
        case plural([String: String])

        init(from decoder: Decoder) throws {
            let box = try decoder.singleValueContainer()
            if let text = try? box.decode(String.self) {
                self = .plain(text)
            } else {
                self = .plural(try box.decode([String: String].self))
            }
        }
    }

    private static func entry(_ key: String) -> Entry? {
        parts.lazy.compactMap { $0[key] }.first
    }

    static func text(_ key: String) -> String? {
        if case .plain(let text)? = entry(key) { return text }
        return nil
    }

    /// With a number, by the rules of Russian plurals: 1 файл, 3 файла, 12 файлов.
    static func text(_ key: String, _ count: Int) -> String? {
        let form: String
        switch (count % 10, count % 100) {
        case (1, let rest) where rest != 11: form = "one"
        case (2...4, let rest) where !(12...14).contains(rest): form = "few"
        default: form = "many"
        }
        switch entry(key) {
        case .plural(let forms)?: return forms[form]?.replacingOccurrences(of: "%lld", with: "\(count)")
        case .plain(let text)?: return text.replacingOccurrences(of: "%lld", with: "\(count)")
        case nil: return nil
        }
    }
}

private let allStates: [WorkState] = [.running, .silent, .waiting, .finished, .failed, .stopped, .interrupted]
private let allStatuses: [RunStatus] = [.running, .silent, .completed, .completedWithErrors, .allAgentsFailed, .failed, .stopped, .interrupted, .unknown("paused-by-something-new")]
private let allReasons: [LossReason] = [.limit, .network, .stall, .api, .sleep, .script, .closed, .unknown]
private let allProblems: [ApiProblem] = [.overloaded, .billing, .access, .request, .other]
private let allTools = ["Read", "NotebookRead", "Edit", "MultiEdit", "NotebookEdit", "Write", "Bash", "Monitor", "BashOutput", "Grep", "Glob", "LS", "WebFetch", "WebSearch", "Agent", "Task", "Skill", "Workflow", "StructuredOutput", "TodoWrite", "ToolSearch", "mcp__postgres__query", "SomethingNew"]

/// Names no plain sentence would have. `Read` and `Edit` are also plain English words, so they are left out.
private let insideWords = ["Bash", "Grep", "Glob", "WebFetch", "WebSearch", "Monitor", "mcp__", "NotebookEdit", "MultiEdit", "TodoWrite", "ToolSearch", "StructuredOutput", "wf_", "API", "stderr", "exit code", "paused-by-something-new", "general-purpose"]

@Suite("Справочник фраз простого режима")
struct PhraseBookTests {
    private func failure(_ source: WorkFailure.Source, cause: FailureClass? = nil, problem: ApiProblem? = nil, resets: String? = nil, name: String? = nil, type: String? = nil) -> WorkFailure {
        WorkFailure(id: "f", sessionId: "s", name: name, agentType: type, source: source, cause: cause, problem: problem, resets: resets)
    }

    // MARK: - Every type has words

    @Test("У каждого вида действия есть фраза", arguments: StepKind.allCases)
    func everyKind(kind: StepKind) {
        let brief = StepBrief(kind: kind, tool: "x")
        #expect(!PhraseBook.doing(brief).isEmpty)
        #expect(!PhraseBook.failed(kind).isEmpty)
        #expect(!PhraseBook.done(kind, steps: 2, files: 2).isEmpty)
        #expect(PhraseBook.doing(brief) == WorkPhrases.step(brief, mode: .simple))
    }

    @Test("У каждого запроса есть заголовок", arguments: WorkAction.allCases)
    func everyAction(action: WorkAction) {
        #expect(!PhraseBook.asks(action).isEmpty)
    }

    @Test("Незнакомое действие это «Работает»")
    func unknownAction() {
        #expect(PhraseBook.doing(tool: "SomethingNew") == "Working")
        #expect(PhraseBook.doing(tool: "mcp__postgres__query") == "Working")
        #expect(PhraseBook.asks(WorkAction(tool: "SomethingNew")) == "Asks for permission")
        #expect(Russian.text("Working") == "Работает")
    }

    @Test("Чтение файла это «Читает файлы проекта»")
    func reading() {
        #expect(PhraseBook.doing(tool: "Read") == "Reading project files")
        #expect(Russian.text("Reading project files") == "Читает файлы проекта")
    }

    @Test("Скилл без названия всё равно скилл, а не помощник")
    func skillWithoutName() {
        #expect(PhraseBook.doing(tool: "Skill") == "Using a skill")
        #expect(PhraseBook.doing(tool: "Agent") == "Called in a helper")
    }

    @Test("Статусы называются как в спецификации")
    func statuses() {
        let expected: [(RunStatus, String, String)] = [
            (.running, "Working", "Работает"),
            (.silent, "No news for a while", "Давно без новостей"),
            (.completed, "Done", "Готово"),
            (.completedWithErrors, "Partly done", "Готово не всё"),
            (.allAgentsFailed, "Did not work", "Не получилось"),
            (.failed, "Broke", "Сломалось"),
            (.stopped, "Stopped", "Остановлено"),
            (.interrupted, "Cut off", "Оборвалось"),
        ]
        for (status, english, russian) in expected {
            #expect(PhraseBook.status(status) == english)
            #expect(Russian.text(english) == russian)
            #expect(WorkPhrases.workflow(status, mode: .simple) == english)
        }
    }

    @Test("Незнакомый статус запуска не показывает своё внутреннее имя")
    func unknownStatus() {
        #expect(PhraseBook.status(.unknown("paused-by-something-new")) == "Ended")
        #expect(WorkPhrases.workflow(.unknown("paused-by-something-new"), mode: .technical) == "paused-by-something-new")
    }

    @Test("Причины называются как в спецификации")
    func reasons() {
        let expected: [(FailureClass?, String, String)] = [
            (.limit, "ran out of limit", "кончился лимит"),
            (.network, "no connection to Claude", "нет связи с Claude"),
            (.sleep, "the Mac went to sleep", "Mac уснул"),
            (.stall, "the task got stuck", "задача зависла"),
            (.api, "a Claude error", "ошибка Claude"),
            (.unknown, "reason unknown", "причина неизвестна"),
            (nil, "reason unknown", "причина неизвестна"),
        ]
        for (cause, english, russian) in expected {
            #expect(PhraseBook.reason(cause) == english)
            #expect(Russian.text(english) == russian)
        }
        #expect(Russian.text("an error in the task") == "ошибка в задаче")
        #expect(Russian.text("Claude Code closed") == "Claude Code закрылся")
    }

    @Test("У каждой причины потери есть заголовок и совет", arguments: allReasons)
    func everyLossReason(reason: LossReason) {
        #expect(!PhraseBook.reasonTitle(reason).isEmpty)
        #expect(!PhraseBook.advice(reason: reason).isEmpty)
    }

    @Test("Совет у каждого класса сбоя, и у неизвестного тоже", arguments: FailureClass.allCases)
    func everyClass(cause: FailureClass) {
        #expect(!PhraseBook.advice(cause: cause).isEmpty)
        #expect(!PhraseBook.reason(cause).isEmpty)
    }

    // MARK: - The scenarios of the spec

    @Test("Все агенты упали из-за лимита")
    func allAgentsFailedOnLimit() {
        let fell = failure(.workflow(.allAgentsFailed, failed: 12, total: 12), cause: .limit, resets: "18:40")
        #expect(WorkPhrases.failure(fell, mode: .simple) == "Did not work: ran out of limit, resets at 18:40")
        #expect(WorkPhrases.failure(fell, mode: .technical).hasPrefix("All agents failed"))
        #expect(Russian.text("ran out of limit, resets at %@")?.replacingOccurrences(of: "%@", with: "18:40") == "кончился лимит, сброс в 18:40")
        #expect(Russian.text("All agents failed") == "Упали все агенты")
    }

    @Test("Процесс закрылся")
    func processClosed() {
        #expect(PhraseBook.failure(failure(.workflow(.interrupted, failed: 0, total: 3))) == "Cut off: Claude Code closed")
        #expect(PhraseBook.failure(failure(.session)) == "Cut off: Claude Code closed")
    }

    @Test("Запуск упал сам: ошибка в задаче, а не стек")
    func brokenScript() {
        #expect(PhraseBook.failure(failure(.workflow(.failed, failed: 0, total: 3))) == "Broke: an error in the task")
        #expect(PhraseBook.failure(failure(.workflow(.failed, failed: 2, total: 3))) == "Broke: an error in the task")
        #expect(PhraseBook.failure(failure(.workflow(.failed, failed: 2, total: 3), cause: .network)) == "Broke: failed 2 of 3, no connection to Claude")
    }

    @Test("Перегрузкой называется только перегрузка")
    func overloadIsNamedOnlyWhenSaid() throws {
        #expect(PhraseBook.advice(cause: .api, problem: .overloaded) == "Claude is overloaded right now, try again later")
        #expect(Russian.text("Claude is overloaded right now, try again later") == "Claude сейчас перегружен, попробуйте повторить позже")
        for problem in [ApiProblem.billing, .access, .request, .other] {
            #expect(PhraseBook.advice(cause: .api, problem: problem) != "Claude is overloaded right now, try again later")
        }
        // The same words come out however the failure is known.
        #expect(PhraseBook.advice(cause: .api) == PhraseBook.advice(reason: .api))
        let now = Date()
        func fell(_ text: String?) -> WorkSession {
            WorkSession(id: "s", state: .finished, root: WorkNode(id: "s", kind: .main, state: .finished, children: [
                WorkNode(id: "a", kind: .subagent, title: "x", state: .failed, failure: FailureInfo(failureClass: .api, text: text), lastActivity: now),
            ]))
        }
        #expect(try #require(fell("Overloaded").failures.first).problem == .overloaded)
        #expect(try WorkPhrases.failure(#require(fell("Overloaded").failures.first), mode: .simple) == "Claude is overloaded right now, try again later")
        #expect(try WorkPhrases.failure(#require(fell("credit balance is too low").failures.first), mode: .simple) == "Claude asks to sort out payment, check your account")
        #expect(try WorkPhrases.failure(#require(fell("credit balance is too low").failures.first), mode: .technical) == "API error · billing")
        #expect(try WorkPhrases.failure(#require(fell(nil).failures.first), mode: .simple) == "Claude returned an error, try again")
        #expect(try WorkPhrases.failure(#require(fell(nil).failures.first), mode: .technical) == "API error")
    }

    @Test("Неизвестный сбой")
    func unknownFailure() {
        #expect(PhraseBook.failure(failure(.agent(.subagent), cause: .unknown)) == "Something went wrong")
        #expect(PhraseBook.failure(failure(.sessionError, cause: nil)) == "Something went wrong")
        #expect(PhraseBook.advice(reason: .unknown) == "Something went wrong")
        #expect(Russian.text("Something went wrong") == "Что-то пошло не так")
    }

    @Test("Совет говорит, что делать, а не только что случилось", arguments: [FailureClass.network, .sleep, .stall])
    func adviceSaysWhatToDo(cause: FailureClass) {
        #expect(PhraseBook.advice(cause: cause).contains("try"))
    }

    // MARK: - Names

    @Test("Понятное имя", arguments: [
        ("silktrace-final-verify", "Silktrace final verify"),
        ("plan_header-and_personal", "Plan header and personal"),
        ("audit", "Audit"),
        ("проверка-кода", "Проверка кода"),
        ("Build language mechanism, stages 1-3", "Build language mechanism, stages 1-3"),
    ])
    func names(raw: String, expected: String) {
        #expect(PhraseBook.taskName(raw) == expected)
        #expect(WorkPhrases.workflowName(raw, mode: .technical) == raw)
    }

    @Test("Идентификатор не имя", arguments: ["wf_8f27282d-238", "--", ""])
    func idIsNoName(raw: String) {
        #expect(PhraseBook.taskName(raw) == "A big task")
    }

    @Test("Тип агента не имя для простого режима")
    func agentType() {
        let unnamed = failure(.agent(.subagent), name: nil, type: "general-purpose")
        #expect(WorkPhrases.failureName(unnamed, mode: .simple) == "A helper")
        #expect(WorkPhrases.failureName(unnamed, mode: .technical) == "Subagent «general-purpose»")
        let named = failure(.agent(.subagent), name: "Миграции", type: "general-purpose")
        #expect(WorkPhrases.failureName(named, mode: .simple) == "Helper «Миграции»")
        #expect(WorkPhrases.failureName(named, mode: .technical) == "Subagent «Миграции»")
    }

    @Test("Сессия без названия и папки не показывает идентификатор в списке сбоев")
    func bareSessionFailure() throws {
        let cut = WorkSession(id: "0123456789", state: .interrupted, lastActivity: Date(), root: WorkNode(id: "0123456789", kind: .main, state: .interrupted))
        let found = try #require(cut.failures.first)
        #expect(WorkPhrases.failureName(found, mode: .simple) == "Session")
    }

    @Test("Запуск в чёлке называется понятно, а не внутренним именем")
    func surfaceNamesWorkflow() {
        let run = RunState(runId: "wf_1", sessionId: "s", name: "silktrace-final-verify", status: .failed, lastWrite: Date())
        let node = WorkNode(id: "wf_1", kind: .workflow, title: "silktrace-final-verify", state: .failed, workflow: WorkflowDetails(run), lastActivity: Date())
        let session = WorkSession(id: "s", state: .finished, lastActivity: Date(), root: WorkNode(id: "s", kind: .main, state: .finished, children: [node]))
        let work = WorkModel(projects: [WorkProject(path: nil, sessions: [session])])
        #expect(SurfaceWords.lastFailure(in: work, mode: .simple, now: Date())?.who == "Silktrace final verify")
        #expect(SurfaceWords.lastFailure(in: work, mode: .technical, now: Date())?.who.contains("silktrace-final-verify") == true)
    }

    // MARK: - Nothing from inside gets out

    @Test("Ни одна фраза не называет инструмент, идентификатор или код")
    func noInsideWords() {
        var phrases: [String] = []
        for tool in allTools {
            phrases.append(PhraseBook.doing(tool: tool))
            phrases.append(PhraseBook.waiting(.permission(tool: tool)))
            phrases.append(PhraseBook.asks(WorkAction(tool: tool)))
        }
        for kind in StepKind.allCases {
            phrases += [PhraseBook.failed(kind), PhraseBook.done(kind, steps: 1, files: 1), PhraseBook.done(kind, steps: 3, files: 3)]
        }
        phrases += allStates.map(PhraseBook.state) + allStatuses.map(PhraseBook.status)
        phrases += [WaitingReason.input, .dialog, .other("stderr"), .permission(tool: nil)].map(PhraseBook.waiting)
        phrases.append(PhraseBook.waiting(nil))
        phrases += FailureClass.allCases.flatMap { [PhraseBook.reason($0), PhraseBook.advice(cause: $0)] }
        phrases += allReasons.flatMap { [PhraseBook.reasonTitle($0), PhraseBook.advice(reason: $0)] }
        phrases += allProblems.map { PhraseBook.advice(cause: .api, problem: $0) }
        for status in allStatuses {
            for cause in FailureClass.allCases {
                phrases.append(PhraseBook.failure(failure(.workflow(status, failed: 1, total: 2), cause: cause)))
            }
        }
        for phrase in phrases {
            #expect(!phrase.isEmpty)
            for word in insideWords {
                #expect(!phrase.contains(word), "«\(phrase)» содержит «\(word)»")
            }
        }
    }

    // MARK: - Steps told as one thing

    @Test("Прочитал 12 файлов: и по-английски, и по-русски")
    func twelveFiles() {
        #expect(PhraseBook.done(.read, steps: 12, files: 12) == "Read 12 files")
        #expect(Russian.text("Read %lld files", 12) == "Прочитал 12 файлов")
        #expect(Russian.text("Read %lld files", 3) == "Прочитал 3 файла")
        #expect(Russian.text("Read %lld file", 1) == "Прочитал 1 файл")
        #expect(Russian.text("Changed %lld files", 2) == "Изменил 2 файла")
    }

    @Test("Работают 3 агента, 3 агента работают")
    func agentCounts() {
        #expect(WorkPhrases.agentsWorking(3) == "3 agents working")
        #expect(Russian.text("%lld agents working", 3) == "Работают 3 агента")
        #expect(Russian.text("%lld agents at work", 3) == "3 агента работают")
        #expect(SurfaceWords.working(3) == "3 agents at work")
    }

    /// The three ways the count is worded: on the notch and under the walrus, on the session's page and in its row, and in the technical mode.
    @Test("Число агентов читается правильно на обоих языках", arguments: [
        (1, ["1 агент работает", "Работает 1 агент", "1 агент"], ["1 agent at work", "1 agent working", "1 agent"]),
        (2, ["2 агента работают", "Работают 2 агента", "2 агента"], ["2 agents at work", "2 agents working", "2 agents"]),
        (5, ["5 агентов работают", "Работают 5 агентов", "5 агентов"], ["5 agents at work", "5 agents working", "5 agents"]),
        (11, ["11 агентов работают", "Работают 11 агентов", "11 агентов"], ["11 agents at work", "11 agents working", "11 agents"]),
        (21, ["21 агент работает", "Работает 21 агент", "21 агент"], ["21 agents at work", "21 agents working", "21 agents"]),
        (0, ["0 агентов работают", "Работают 0 агентов", "0 агентов"], ["0 agents at work", "0 agents working", "0 agents"]),
    ])
    func agentPlurals(count: Int, russian: [String], english: [String]) {
        let shown = [SurfaceWords.working(count), WorkPhrases.agentsWorking(count), WorkPhrases.agents(count)]
        #expect(shown == english)
        // Tests run in English, where the text is its own key, so the key each phrase picked for this number can be read back from it.
        #expect(shown.map { Russian.text($0.replacingOccurrences(of: "\(count)", with: "%lld"), count) } == russian)
        // The walrus has words of his own for work with nobody to count.
        if count > 0 { #expect(WalrusLines.standing(mood: .working(agents: count), waiting: 0) == english[0]) }
    }

    @Test("Несколько незавершённых шагов не говорят об одном")
    func unfinishedSteps() {
        var log = ActivityLog()
        for id in ["a", "b", "c"] { log.apply(.toolUse(id: id, tool: "Read", input: ToolInput(target: "/x/\(id)"), at: nil)) }
        log.closeRunning()
        let lines = FeedSummary.lines(SessionFeed.merged(sessionId: "s", logs: [AgentLog(agentId: nil, log: log)]))
        #expect(lines.map(\.text) == ["3 steps did not finish"])
        #expect(lines.first?.steps.count == 3)
        #expect(PhraseBook.unfinished(steps: 1) == "This step did not finish")
        #expect(Russian.text("%lld steps did not finish", 3) == "3 шага не завершены")
    }

    // MARK: - The technical words

    @Test("Подробности сессии: то, что неизвестно, не упоминается")
    func sessionFacts() {
        let root = WorkNode(id: "s1", kind: .main, model: "claude-x")
        let full = WorkSession(id: "s1", cwd: "/x/app", state: .running, place: GitPlace(branch: "main"), root: root)
        #expect(WorkPhrases.sessionFacts(full, permissionMode: "acceptEdits") == "s1 · claude-x · acceptEdits mode · branch main · /x/app")
        let bare = WorkSession(id: "s1", state: .running, root: WorkNode(id: "s1", kind: .main))
        #expect(WorkPhrases.sessionFacts(bare, permissionMode: nil) == "s1")
    }

    @Test("Заполнение контекста в строке сессии")
    func contextLine() {
        var session = WorkSession(id: "s", state: .running, root: WorkNode(id: "s", kind: .main))
        #expect(WorkPhrases.contextLine(session) == nil)
        session.root.contextTokens = 128_000
        #expect(WorkPhrases.contextLine(session) == "context 128K")
    }

    @Test("Тип ошибки шага называется, а сам её текст нет", arguments: [
        ("Exit code 1\nsecret-output", "exit code 1"),
        ("File does not exist: /x/secret", "file not found"),
        ("String to replace not found in file", "text to replace not found"),
        ("Request failed with status code 404", "HTTP 404"),
        ("something else entirely", "returned an error"),
    ])
    func stepError(output: String, words: String) {
        var log = ActivityLog()
        log.apply(.toolUse(id: "a", tool: "Bash", input: ToolInput(command: "x"), at: nil))
        log.apply(.toolResult(id: "a", isError: true, text: output, at: nil))
        guard case .step(let step) = log.items[0] else {
            Issue.record("no step")
            return
        }
        #expect(WorkPhrases.stepError(step) == words)
    }

    @Test("Удачный шаг ошибки не называет")
    func noErrorOnSuccess() {
        var log = ActivityLog()
        log.apply(.toolUse(id: "a", tool: "Bash", input: ToolInput(command: "x"), at: nil))
        log.apply(.toolResult(id: "a", isError: false, text: "Exit code 1", at: nil))
        guard case .step(let step) = log.items[0] else {
            Issue.record("no step")
            return
        }
        #expect(WorkPhrases.stepError(step) == nil)
    }
}
