import Foundation
import Testing
@testable import BorisCore

@Suite("Содержимое запроса и ответ для Claude")
struct RequestContentTests {
    private func json(_ data: Data?) throws -> [String: Any] {
        let bytes = try #require(data)
        return try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    }

    private func decision(_ data: Data?) throws -> [String: Any] {
        let output = try #require(try json(data)["hookSpecificOutput"] as? [String: Any])
        #expect(output["hookEventName"] as? String == "PermissionRequest")
        return try #require(output["decision"] as? [String: Any])
    }

    // MARK: What leaves the hook

    @Test("Аргументы инструмента уходят только с запросом разрешения") func inputOnlyForPermission() {
        for event in ["PreToolUse", "PostToolUse", "PostToolUseFailure", "Stop"] {
            let reduced = HookPayload.reduce(["hook_event_name": event, "session_id": "s", "tool_name": "Bash", "tool_input": ["command": "SECRET"]])
            #expect(reduced["tool_input"] == nil, "\(event)")
            #expect(reduced["command_text"] == nil, "\(event)")
        }
        let asked = HookPayload.reduce(["hook_event_name": "PermissionRequest", "session_id": "s", "tool_name": "Bash", "tool_input": ["command": "ls"], "permission_mode": "default", "prompt": "SECRET", "permission_suggestions": [["type": "addRules"]]])
        #expect((asked["tool_input"] as? [String: String])?["command"] == "ls")
        #expect(asked["permission_mode"] as? String == "default")
        #expect(asked["prompt"] == nil)
        #expect(asked["permission_suggestions"] == nil, "предложения «всегда разрешать» Boris не использует")
    }

    @Test("Отпечаток находит тот самый вызов и не содержит его текста") func digest() {
        let input = ["command": "npm run migrate", "description": "миграция"]
        let asked = HookPayload.reduce(["hook_event_name": "PermissionRequest", "session_id": "s", "tool_input": input])
        let done = HookPayload.reduce(["hook_event_name": "PostToolUse", "session_id": "s", "tool_input": input])
        let other = HookPayload.reduce(["hook_event_name": "PostToolUse", "session_id": "s", "tool_input": ["command": "ls"]])
        let digest = asked["input_digest"] as? String
        #expect(digest != nil)
        #expect(digest == done["input_digest"] as? String)
        #expect(digest != other["input_digest"] as? String)
        #expect(digest?.contains("npm") == false)
        #expect(HookPayload.reduce(["hook_event_name": "PreToolUse", "session_id": "s", "tool_input": input])["input_digest"] == nil)
    }

    @Test("Слишком длинный запрос не идёт целиком, и разрешить его нельзя") func tooLong() {
        let huge = String(repeating: "x", count: 300 * 1024)
        let reduced = HookPayload.reduce(["hook_event_name": "PermissionRequest", "session_id": "s", "tool_name": "Write", "tool_input": ["file_path": "/a", "content": huge]])
        #expect(reduced["tool_input"] == nil)
        let flat = reduced["command_text"] as? String ?? ""
        #expect(flat.utf8.count < 70 * 1024)
        let content = RequestContent.parse(tool: "Write", input: reduced["tool_input"] as? [String: Any], flat: flat)
        #expect(content == .unreadable(flat))
        #expect(!content.canAllow)
    }

    // MARK: Parsing

    @Test("Команда видна целиком, вместе с признаком работы вне песочницы") func command() {
        #expect(RequestContent.parse(tool: "Bash", input: ["command": "ls -la", "description": "list"], flat: "") == .command("ls -la", unsandboxed: false))
        #expect(RequestContent.parse(tool: "Bash", input: ["command": "ls", "dangerouslyDisableSandbox": true], flat: "") == .command("ls", unsandboxed: true))
    }

    @Test("Правка файла показывает только изменённые строки") func edit() {
        let content = RequestContent.parse(tool: "Edit", input: [
            "file_path": "/p/a.swift",
            "old_string": "keep\nold one\nold two\nkeep too\n",
            "new_string": "keep\nnew\nkeep too\n",
            "replace_all": true,
        ], flat: "")
        #expect(content == .file(path: "/p/a.swift", lines: [
            RequestDiffLine(added: false, text: "old one"),
            RequestDiffLine(added: false, text: "old two"),
            RequestDiffLine(added: true, text: "new"),
        ], whole: false, everyOccurrence: true))
    }

    @Test("Правка не прячет разницу", arguments: [
        ("a", "a", 0, 0),
        ("", "new", 0, 1),
        ("old", "", 1, 0),
        ("a\nb", "a\n  b", 1, 1),
        ("a\r\nb", "a\r\nc", 1, 1),
        ("x\nx\nx", "x\nx", 1, 0),
        ("a\n", "a", 1, 0),
        ("a", "a\n", 0, 1),
        ("a\r\nb", "a\nb", 1, 1),
        ("# note\u{2028}rm -rf x", "# note\nrm -rf x", 1, 2),
        ("", "new\n", 0, 1),
    ])
    func diffCounts(old: String, new: String, removed: Int, added: Int) {
        let lines = RequestContent.diff(old: old, new: new)
        #expect(lines.filter { !$0.added }.count == removed)
        #expect(lines.filter(\.added).count == added)
    }

    @Test("Конец строки сравнивается, но в показанный текст не попадает") func lineEndingsAreNotShown() {
        #expect(RequestContent.diff(old: "a\r\nb", new: "a\nb") == [RequestDiffLine(added: false, text: "a"), RequestDiffLine(added: true, text: "a")])
        #expect(RequestContent.diff(old: "keep\r\nold\r\n", new: "keep\r\nnew\r\n") == [RequestDiffLine(added: false, text: "old"), RequestDiffLine(added: true, text: "new")])
    }

    @Test("Запись файла показывает всё, что будет записано") func write() {
        #expect(RequestContent.parse(tool: "Write", input: ["file_path": "/p/n.txt", "content": "one\n\ntwo\n"], flat: "") == .file(
            path: "/p/n.txt",
            lines: [RequestDiffLine(added: true, text: "one"), RequestDiffLine(added: true, text: ""), RequestDiffLine(added: true, text: "two")],
            whole: true,
            everyOccurrence: false
        ))
    }

    @Test("Незнакомый инструмент показывается со всеми полями, а не только с командой") func unknownTool() {
        guard case .other(let text) = RequestContent.parse(tool: "mcp__x__y", input: ["command": "status", "target": "/prod/db"], flat: "status") else {
            Issue.record("это обычный запрос")
            return
        }
        #expect(text.contains("status"))
        #expect(text.contains("/prod/db"), "разрешают то, что видно, а не только поле command")
        guard case .other(let partial) = RequestContent.parse(tool: "Edit", input: ["file_path": "/a"], flat: "cut") else {
            Issue.record("неполная правка показывается как есть")
            return
        }
        #expect(partial.contains("file_path"))
    }

    @Test("Длинный запрос незнакомого инструмента виден до конца, раз его можно разрешить") func longOtherIsWhole() {
        let input = ["payload": String(repeating: "x", count: 100 * 1024) + "THE-END"]
        let reduced = HookPayload.reduce(["hook_event_name": "PermissionRequest", "session_id": "s", "tool_name": "mcp__x__y", "tool_input": input])
        let flat = reduced["command_text"] as? String ?? ""
        #expect(!flat.contains("THE-END"), "короткий текст обрезан, поэтому показывать его нельзя")
        let content = RequestContent.parse(tool: "mcp__x__y", input: reduced["tool_input"] as? [String: Any], flat: flat)
        guard case .other(let text) = content else {
            Issue.record("такой запрос помещается и его можно разрешить")
            return
        }
        #expect(text.contains("THE-END"))
        #expect(content.canAllow)
    }

    private let questionsInput: [String: Any] = [
        "questions": [
            ["question": "Какую базу?", "header": "База", "multiSelect": false, "options": [["label": "PostgreSQL", "description": "Отдельный сервер"], ["label": "SQLite", "description": ""]]],
            ["question": "Что настроить?", "header": "Настройка", "multiSelect": true, "options": [["label": "Миграции"], ["label": "Копии"], ["label": "Логи"]]],
        ],
    ]

    @Test("Вопросы разбираются вместе с вариантами") func questions() throws {
        guard case .questions(let questions) = RequestContent.parse(tool: "AskUserQuestion", input: questionsInput, flat: "") else {
            Issue.record("это вопросы")
            return
        }
        #expect(questions.map(\.text) == ["Какую базу?", "Что настроить?"])
        #expect(questions.map(\.multiple) == [false, true])
        #expect(questions[0].options == [.init(label: "PostgreSQL", detail: "Отдельный сервер"), .init(label: "SQLite")])
    }

    @Test("Вопрос непонятного вида нельзя подтвердить") func brokenQuestions() {
        let inputs: [[String: Any]] = [
            ["questions": [[String: Any]]()],
            ["questions": [["question": "Без вариантов"]]],
            ["questions": [["question": "Без подписи", "options": [["description": "нет label"]]]]],
            ["questions": [["question": "Два раза", "options": [["label": "a"]]], ["question": "Два раза", "options": [["label": "b"]]]]],
            ["questions": [["question": "Одинаковые варианты", "options": [["label": "a"], ["label": "a"]]]]],
        ]
        for input in inputs {
            #expect(RequestContent.parse(tool: "AskUserQuestion", input: input, flat: "f") == .unreadable("f"))
        }
    }

    @Test("План берётся из plan, а без него его нельзя подтвердить") func plan() {
        #expect(RequestContent.parse(tool: "ExitPlanMode", input: ["plan": "# План\n1. Шаг", "planFilePath": "/p"], flat: "") == .plan("# План\n1. Шаг"))
        #expect(RequestContent.parse(tool: "ExitPlanMode", input: [:], flat: "{}") == .unreadable("{}"))
        #expect(RequestContent.parse(tool: "ExitPlanMode", input: ["plan": ""], flat: "x") == .unreadable("x"))
    }

    // MARK: Answers to questions

    @Test("Пока есть вопрос без ответа, отвечать нечем") func incompleteAnswers() throws {
        guard case .questions(let questions) = RequestContent.parse(tool: "AskUserQuestion", input: questionsInput, flat: "") else {
            Issue.record("это вопросы")
            return
        }
        var draft = RequestDraft()
        #expect(draft.answers(to: questions) == nil, "ничего не выбрано заранее")
        draft.toggle("SQLite", in: questions[0])
        #expect(draft.answers(to: questions) == nil)
        draft.toggle("Логи", in: questions[1])
        #expect(draft.answers(to: questions) != nil)
        draft.toggle("Логи", in: questions[1])
        #expect(draft.answers(to: questions) == nil, "снятая галочка снова оставляет вопрос без ответа")
    }

    @Test("Один вариант заменяет другой, а несколько идут в порядке Claude") func picking() throws {
        guard case .questions(let questions) = RequestContent.parse(tool: "AskUserQuestion", input: questionsInput, flat: "") else {
            Issue.record("это вопросы")
            return
        }
        var draft = RequestDraft()
        draft.toggle("PostgreSQL", in: questions[0])
        draft.toggle("SQLite", in: questions[0])
        draft.toggle("Логи", in: questions[1])
        draft.toggle("Миграции", in: questions[1])
        #expect(draft.answers(to: questions) == ["Какую базу?": "SQLite", "Что настроить?": "Миграции, Логи"])
    }

    // MARK: The answer on its way

    @Test("Ответ проходит по сокету без потерь", arguments: [
        HookAnswer.allow,
        .deny(reason: ""),
        .deny(reason: "сначала\nсделай копию"),
        .answers(["Какую базу?": "SQLite", "Что настроить?": "Миграции, Логи"]),
    ])
    func wire(answer: HookAnswer) {
        let line = answer.line
        #expect(line.last == 0x0A)
        #expect(line.dropLast().contains(0x0A) == false, "ответ занимает ровно одну строку")
        #expect(HookAnswer(line: line) == answer)
    }

    @Test("Мусор вместо ответа ничего не решает", arguments: ["", "allow\n", "{}", "{\"behavior\":\"always\"}", "{\"behavior\":\"allow\",\"answers\":{}}", "{\"behavior\":\"allow\",\"answers\":\"x\"}"])
    func garbageLine(text: String) {
        #expect(HookAnswer(line: Data(text.utf8)) == nil)
    }

    @Test("Разрешение: ни слова о правилах на будущее") func allowOutput() throws {
        let result = try decision(HookAnswer.allow.output(tool: "Bash", input: ["command": "ls"]))
        #expect(result["behavior"] as? String == "allow")
        #expect(result["updatedInput"] == nil, "команда выполняется ровно такой, как её показали")
        #expect(result["updatedPermissions"] == nil)
    }

    @Test("Отказ несёт причину словами человека, а без неё обычные слова") func denyOutput() throws {
        let given = try decision(HookAnswer.deny(reason: "  сначала копию \n").output(tool: "Bash", input: nil))
        #expect(given["behavior"] as? String == "deny")
        #expect(given["message"] as? String == "The user denied this in Boris and said: сначала копию")
        let none = try decision(HookAnswer.deny(reason: " ").output(tool: "Bash", input: nil))
        #expect(none["message"] as? String == "Denied in Boris")
    }

    /// Exactly what Claude Code 2.1.319 sent for two questions in one call and accepted back: it told the model
    /// `"Which fruit do you want?"="Pear", "Which colors do you like?"="Red, Blue"`.
    @Test("Несколько вопросов и множественный выбор в том виде, который принял настоящий Claude") func realAnswers() throws {
        let input: [String: Any] = ["questions": [
            ["question": "Which fruit do you want?", "header": "Fruit", "multiSelect": false, "options": [["label": "Apple", "description": "Apple"], ["label": "Pear", "description": "Pear"]]],
            ["question": "Which colors do you like?", "header": "Colors", "multiSelect": true, "options": [["label": "Red", "description": "Red"], ["label": "Green", "description": "Green"], ["label": "Blue", "description": "Blue"]]],
        ]]
        guard case .questions(let questions) = RequestContent.parse(tool: "AskUserQuestion", input: input, flat: "") else {
            Issue.record("это вопросы")
            return
        }
        var draft = RequestDraft()
        draft.toggle("Pear", in: questions[0])
        draft.toggle("Blue", in: questions[1])
        draft.toggle("Red", in: questions[1])
        let answers = try #require(draft.answers(to: questions))
        #expect(answers == ["Which fruit do you want?": "Pear", "Which colors do you like?": "Red, Blue"])
        let result = try decision(HookAnswer.answers(answers).output(tool: "AskUserQuestion", input: input))
        #expect(result["behavior"] as? String == "allow")
        let updated = try #require(result["updatedInput"] as? [String: Any])
        #expect(updated["answers"] as? [String: String] == answers)
        #expect((updated["questions"] as? [[String: Any]])?.count == 2)
    }

    @Test("Вопрос: разрешение плюс исходные вопросы и ответы") func answersOutput() throws {
        let result = try decision(HookAnswer.answers(["Какую базу?": "SQLite"]).output(tool: "AskUserQuestion", input: questionsInput))
        #expect(result["behavior"] as? String == "allow")
        let updated = try #require(result["updatedInput"] as? [String: Any])
        #expect(updated["answers"] as? [String: String] == ["Какую базу?": "SQLite"])
        let questions = try #require(updated["questions"] as? [[String: Any]])
        #expect(questions.count == 2)
        #expect(questions[0]["header"] as? String == "База", "вопросы возвращаются как пришли")
        #expect(result["updatedPermissions"] == nil)
    }

    @Test("Простое разрешение не отвечает на вопрос, а ответы не годятся для другого инструмента") func answerMismatch() {
        #expect(HookAnswer.allow.output(tool: "AskUserQuestion", input: questionsInput) == nil)
        #expect(HookAnswer.answers(["a": "b"]).output(tool: "Bash", input: ["command": "ls"]) == nil)
        #expect(HookAnswer.answers(["a": "b"]).output(tool: "AskUserQuestion", input: nil) == nil)
        #expect(HookAnswer.answers(["a": "b"]).output(tool: "AskUserQuestion", input: ["other": 1]) == nil)
    }

    @Test("План: подтверждение возвращает его ввод, отказ несёт комментарий") func planOutput() throws {
        let input: [String: Any] = ["plan": "1. Шаг", "planFilePath": "/p/plan.md"]
        let approved = try decision(HookAnswer.allow.output(tool: "ExitPlanMode", input: input))
        #expect(approved["behavior"] as? String == "allow")
        #expect((approved["updatedInput"] as? [String: String])?["plan"] == "1. Шаг")
        #expect((approved["updatedInput"] as? [String: String])?["planFilePath"] == "/p/plan.md")
        let denied = try decision(HookAnswer.deny(reason: "не трогай orders").output(tool: "ExitPlanMode", input: input))
        #expect(denied["behavior"] as? String == "deny")
        // Claude Code 2.1.319 took a bare comment for a failed call and offered the same plan again.
        #expect(denied["message"] as? String == "The user did not approve this plan in Boris and said: не трогай orders")
    }

    // MARK: The waiting overlay

    @Test("Ответ снимает ожидание сразу, не дожидаясь файлов") func answeredClearsWaiting() {
        var hooks = HookState()
        let now = Date()
        hooks.apply(.permissionAsked(session: "s", tool: "Bash"), now: now)
        #expect(hooks.waiting["s"] != nil)
        hooks.apply(.permissionAnswered(session: "s"), now: now)
        #expect(hooks.waiting["s"] == nil)
        #expect(hooks.waitingTool["s"] == nil)
    }
}
