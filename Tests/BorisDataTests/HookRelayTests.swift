import BorisCore
import Darwin
import Foundation
import Testing
@testable import BorisData

/// Runs the real `boris-hook`, as Claude would.
@Suite("Посредник для хуков", .serialized)
struct HookRelayTests {
    private static var binary: URL? {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let file = root.appendingPathComponent(".build/debug/boris-hook")
        return FileManager.default.isExecutableFile(atPath: file.path) ? file : nil
    }

    private struct Result {
        var status: Int32
        var output: String
        var seconds: TimeInterval
    }

    private func socketPath() -> String {
        NSTemporaryDirectory() + "b\(UUID().uuidString.prefix(8)).sock"
    }

    private func run(socket: String, arguments: [String] = [], input: String) throws -> Result {
        let binary = try #require(Self.binary, "boris-hook не собран")
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        process.environment = ["BORIS_HOOK_SOCKET": socket, "HOME": NSHomeDirectory()]
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        let began = Date()
        try process.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(status: process.terminationStatus, output: String(decoding: output, as: UTF8.self), seconds: Date().timeIntervalSince(began))
    }

    private let toolEvent = #"{"hook_event_name":"PreToolUse","session_id":"s1","tool_name":"Bash","tool_input":{"command":"secret"},"prompt":"private"}"#
    private let permission = #"{"hook_event_name":"PermissionRequest","session_id":"s1","tool_name":"Bash","cwd":"/x/proj","tool_input":{"command":"npm run migrate"}}"#

    private final class Received: @unchecked Sendable {
        private let lock = NSLock()
        private var signals: [HookSignal] = []
        private var requests: [PendingPermission] = []
        private var gone: [UUID] = []
        private var expired: [UUID] = []
        private var done: [String] = []

        func goneFired(_ id: UUID) {
            lock.lock()
            gone.append(id)
            lock.unlock()
        }

        func expiredFired(_ id: UUID) {
            lock.lock()
            expired.append(id)
            lock.unlock()
        }

        func toolDone(_ digest: String) {
            lock.lock()
            done.append(digest)
            lock.unlock()
        }

        var allGone: [UUID] {
            lock.lock()
            defer { lock.unlock() }
            return gone
        }

        var allExpired: [UUID] {
            lock.lock()
            defer { lock.unlock() }
            return expired
        }

        var allDone: [String] {
            lock.lock()
            defer { lock.unlock() }
            return done
        }

        var allRequests: [PendingPermission] {
            lock.lock()
            defer { lock.unlock() }
            return requests
        }

        func add(_ signal: HookSignal) {
            lock.lock()
            signals.append(signal)
            lock.unlock()
        }

        func add(_ request: PendingPermission) {
            lock.lock()
            requests.append(request)
            lock.unlock()
        }

        var allSignals: [HookSignal] {
            lock.lock()
            defer { lock.unlock() }
            return signals
        }

        var firstRequest: PendingPermission? {
            lock.lock()
            defer { lock.unlock() }
            return requests.first
        }
    }

    private func server(_ path: String) throws -> (HookServer, Received) {
        let server = HookServer(path: path)
        let received = Received()
        server.onSignal = { received.add($0) }
        server.onPermission = { received.add($0) }
        server.onPermissionGone = { received.goneFired($0) }
        server.onPermissionExpired = { received.expiredFired($0) }
        server.onToolDone = { _, digest in received.toolDone(digest) }
        #expect(server.start())
        return (server, received)
    }

    private func eventually(longer: Bool = false, _ condition: () -> Bool) async -> Bool {
        for _ in 0..<(longer ? 600 : 200) {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    @Test("Приложение закрыто: посредник молча выходит, без ошибки и без решения")
    func appClosed() throws {
        let result = try run(socket: socketPath(), input: toolEvent)
        #expect(result.status == 0)
        #expect(result.output.isEmpty)
        let asked = try run(socket: socketPath(), arguments: ["--permission", "5"], input: permission)
        #expect(asked.status == 0)
        #expect(asked.output.isEmpty)
        #expect(asked.seconds < 2)
    }

    @Test("Сокет остался, а приложения нет: то же самое")
    func staleSocket() throws {
        let path = socketPath()
        FileManager.default.createFile(atPath: path, contents: nil)
        defer { unlink(path) }
        let result = try run(socket: path, arguments: ["--permission", "5"], input: permission)
        #expect(result.status == 0)
        #expect(result.output.isEmpty)
        #expect(result.seconds < 2)
    }

    @Test("Мусор на входе не мешает Claude")
    func garbage() throws {
        let path = socketPath()
        let (server, _) = try server(path)
        defer { server.stop() }
        let result = try run(socket: path, input: "not json")
        #expect(result.status == 0)
        #expect(result.output.isEmpty)
    }

    @Test("Событие доходит до приложения, а промпт и текст команды нет")
    func eventArrives() async throws {
        let path = socketPath()
        let (server, received) = try server(path)
        defer { server.stop() }
        let result = try run(socket: path, input: toolEvent)
        #expect(result.status == 0)
        #expect(result.output.isEmpty, "обычное событие ничего не отвечает Claude")
        #expect(await eventually { received.allSignals == [.toolStarted(session: "s1", agent: nil, tool: "Bash")] })
    }

    @Test("Обычное событие не задерживает Claude заметным образом")
    func latency() throws {
        let path = socketPath()
        let (server, _) = try server(path)
        defer { server.stop() }
        var times: [TimeInterval] = []
        for _ in 0..<30 {
            times.append(try run(socket: path, input: toolEvent).seconds)
        }
        times.sort()
        let median = times[times.count / 2]
        print("boris-hook median \(Int(median * 1000)) ms, worst \(Int((times.last ?? 0) * 1000)) ms")
        #expect(median < 0.2, "медиана \(median) с")
    }

    @Test("Разрешение: решение возвращается Claude по соединению этого запроса", arguments: [true, false])
    func permissionAnswered(allow: Bool) async throws {
        let path = socketPath()
        let (server, received) = try server(path)
        defer { server.stop() }
        let test = self
        let task = Task.detached { try test.run(socket: path, arguments: ["--permission", "20"], input: test.permission) }
        #expect(await eventually { received.firstRequest != nil })
        let request = try #require(received.firstRequest)
        #expect(request.command == "npm run migrate")
        #expect(request.project == "proj")
        server.answer(request.id, allow ? .allow : .deny(reason: ""))

        let result = try await task.value
        #expect(result.status == 0)
        let answer = try #require(try JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any])
        let output = try #require(answer["hookSpecificOutput"] as? [String: Any])
        #expect(output["hookEventName"] as? String == "PermissionRequest")
        #expect((output["decision"] as? [String: Any])?["behavior"] as? String == (allow ? "allow" : "deny"))
    }

    private func shell(_ command: String, socket: String, input: String) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ["BORIS_HOOK_SOCKET": socket, "HOME": NSHomeDirectory()]
        let stdin = Pipe()
        let output = Pipe()
        process.standardInput = stdin
        process.standardOutput = output
        process.standardError = output
        let began = Date()
        try process.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self), seconds: Date().timeIntervalSince(began))
    }

    @Test("Команда из настроек Claude доходит до приложения, а после удаления приложения безвредна")
    func installedCommand() async throws {
        let folder = TempFolder()
        let app = folder.url.appendingPathComponent("Bo'ris app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let helper = app.appendingPathComponent("boris-hook")
        try FileManager.default.copyItem(at: try #require(Self.binary), to: helper)
        let plan = HookInstaller.Plan(helperPath: helper.path, permissions: true, permissionWait: 30)
        let observe = HookInstaller.command(plan, permission: false)
        let ask = HookInstaller.command(plan, permission: true)

        let path = socketPath()
        let (server, received) = try server(path)
        defer { server.stop() }
        let sent = try shell(observe, socket: path, input: toolEvent)
        #expect(sent.status == 0)
        #expect(sent.output.isEmpty)
        #expect(await eventually { received.allSignals == [.toolStarted(session: "s1", agent: nil, tool: "Bash")] })

        // The app is gone, and the entries are still in Claude's settings.
        try FileManager.default.removeItem(at: app)
        for (command, input) in [(observe, toolEvent), (ask, permission)] {
            let result = try shell(command, socket: path, input: input)
            #expect(result.status == 0)
            #expect(result.output.isEmpty)
            #expect(result.seconds < 2)
        }
        #expect(received.firstRequest == nil)
    }

    @Test("Нет ответа за отведённое время: запрос остаётся в Claude, решения нет")
    func permissionTimedOut() async throws {
        let path = socketPath()
        let (server, received) = try server(path)
        defer { server.stop() }
        let result = try run(socket: path, arguments: ["--permission", "1"], input: permission)
        #expect(result.status == 0)
        #expect(result.output.isEmpty)
        #expect(result.seconds >= 0.9)
        #expect(received.firstRequest != nil)
    }

    private func ask(_ path: String, _ input: String, limit: Int = 20) -> Task<Result, Error> {
        let test = self
        // On a thread of its own: as many blocked hooks as there are cores would leave the test no thread to answer them with.
        return Task.detached {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global().async {
                    continuation.resume(with: Swift.Result { try test.run(socket: path, arguments: ["--permission", "\(limit)"], input: input) })
                }
            }
        }
    }

    private func decision(_ result: Result) throws -> [String: Any] {
        let answer = try #require(try JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any])
        let output = try #require(answer["hookSpecificOutput"] as? [String: Any])
        return try #require(output["decision"] as? [String: Any])
    }

    private func encoded(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private func request(tool: String, session: String = "s1", input: [String: Any]) throws -> String {
        try encoded(["hook_event_name": "PermissionRequest", "session_id": session, "tool_name": tool, "cwd": "/x/proj", "permission_mode": "default", "tool_input": input])
    }

    @Test("Отказ с причиной: Claude получает эту причину")
    func denyWithReason() async throws {
        let path = socketPath()
        let (server, received) = try server(path)
        defer { server.stop() }
        let task = ask(path, permission)
        #expect(await eventually { received.firstRequest != nil })
        server.answer(try #require(received.firstRequest).id, .deny(reason: "сначала сделай резервную копию"))
        let answer = try decision(try await task.value)
        #expect(answer["behavior"] as? String == "deny")
        #expect(answer["message"] as? String == "сначала сделай резервную копию")
    }

    @Test("Ответ на один запрос не трогает другой: у каждого своё соединение")
    func answersDoNotCross() async throws {
        let path = socketPath()
        let (server, received) = try server(path)
        defer { server.stop() }
        let first = ask(path, try request(tool: "Bash", session: "s1", input: ["command": "первая"]))
        let second = ask(path, try request(tool: "Bash", session: "s2", input: ["command": "вторая"]))
        #expect(await eventually { received.allRequests.count == 2 })
        let requests = received.allRequests
        let one = try #require(requests.first { $0.session == "s1" })
        let two = try #require(requests.first { $0.session == "s2" })
        #expect(one.command == "первая")
        #expect(two.command == "вторая")

        server.answer(two.id, .deny(reason: "нет"))
        #expect(try decision(try await second.value)["behavior"] as? String == "deny")
        server.answer(one.id, .allow)
        #expect(try decision(try await first.value)["behavior"] as? String == "allow")
    }

    @Test("Повторный ответ на закрытый запрос никуда не идёт и никому не мешает")
    func answerTwice() async throws {
        let path = socketPath()
        let (server, received) = try server(path)
        defer { server.stop() }
        let first = ask(path, try request(tool: "Bash", session: "s1", input: ["command": "a"]))
        #expect(await eventually { received.allRequests.count == 1 })
        let id = try #require(received.firstRequest).id
        server.answer(id, .allow)
        server.answer(id, .deny(reason: "поздно"))
        #expect(try decision(try await first.value)["behavior"] as? String == "allow")

        // Another request arrives after that, and the stale answer does not reach it.
        server.setAnswerWindow(1)
        let second = ask(path, try request(tool: "Bash", session: "s2", input: ["command": "b"]))
        #expect(await eventually { received.allRequests.count == 2 })
        server.answer(id, .allow)
        #expect(try await second.value.output.isEmpty)
    }

    @Test("Больше восьми запросов сразу: все видны")
    func manyAtOnce() async throws {
        let path = socketPath()
        let (server, received) = try server(path)
        defer { server.stop() }
        var tasks: [Task<Result, Error>] = []
        for index in 0..<12 {
            tasks.append(ask(path, try request(tool: "Bash", session: "s\(index)", input: ["command": "c\(index)"])))
        }
        #expect(await eventually { received.allRequests.count == 12 })
        for request in received.allRequests { server.answer(request.id, .allow) }
        for task in tasks { #expect(try decision(try await task.value)["behavior"] as? String == "allow") }
    }

    @Test("Правка файла доходит с именем файла и изменениями")
    func editArrives() async throws {
        let path = socketPath()
        let (server, received) = try server(path)
        defer { server.stop() }
        let task = ask(path, try request(tool: "Edit", input: ["file_path": "/x/proj/src/auth.swift", "old_string": "old", "new_string": "new"]))
        #expect(await eventually { received.firstRequest != nil })
        let request = try #require(received.firstRequest)
        #expect(request.content == .file(path: "/x/proj/src/auth.swift", lines: [RequestDiffLine(added: false, text: "old"), RequestDiffLine(added: true, text: "new")], whole: false, everyOccurrence: false))
        #expect(request.mode == "default")
        #expect(request.cwd == "/x/proj")
        server.answer(request.id, .allow)
        #expect(try decision(try await task.value)["updatedInput"] == nil)
    }

    private var questions: [String: Any] {
        ["questions": [
            ["question": "Какую базу?", "header": "База", "multiSelect": false, "options": [["label": "PostgreSQL", "description": "Сервер"], ["label": "SQLite", "description": "Файл"]]],
            ["question": "Что настроить?", "header": "Настройка", "multiSelect": true, "options": [["label": "Миграции", "description": ""], ["label": "Копии", "description": ""]]],
        ]]
    }

    /// Answers the questions as the card would, and returns what Claude reads.
    private func answerQuestions(_ input: [String: Any], picking: (RequestQuestion, inout RequestDraft) -> Void) async throws -> [String: Any] {
        let path = socketPath()
        let (server, received) = try server(path)
        defer { server.stop() }
        let task = ask(path, try request(tool: "AskUserQuestion", input: input))
        #expect(await eventually { received.firstRequest != nil })
        let held = try #require(received.firstRequest)
        guard case .questions(let parsed) = held.content else {
            Issue.record("это вопросы")
            return [:]
        }
        var draft = RequestDraft()
        for question in parsed { picking(question, &draft) }
        server.answer(held.id, .answers(try #require(draft.answers(to: parsed))))
        return try decision(try await task.value)
    }

    @Test("Один вопрос, один вариант")
    func singleChoice() async throws {
        let input: [String: Any] = ["questions": [(questions["questions"] as? [[String: Any]])?[0] ?? [:]]]
        let answer = try await answerQuestions(input) { question, draft in draft.toggle("SQLite", in: question) }
        #expect(answer["behavior"] as? String == "allow")
        let updated = try #require(answer["updatedInput"] as? [String: Any])
        #expect(updated["answers"] as? [String: String] == ["Какую базу?": "SQLite"])
        #expect((updated["questions"] as? [[String: Any]])?.count == 1)
        #expect(answer["updatedPermissions"] == nil)
    }

    @Test("Один вопрос, несколько вариантов")
    func multipleChoice() async throws {
        let input: [String: Any] = ["questions": [(questions["questions"] as? [[String: Any]])?[1] ?? [:]]]
        let answer = try await answerQuestions(input) { question, draft in
            draft.toggle("Копии", in: question)
            draft.toggle("Миграции", in: question)
        }
        let updated = try #require(answer["updatedInput"] as? [String: Any])
        #expect(updated["answers"] as? [String: String] == ["Что настроить?": "Миграции, Копии"])
    }

    @Test("Несколько вопросов сразу: ответы идут вместе, вопросы возвращаются как пришли")
    func severalQuestions() async throws {
        let answer = try await answerQuestions(questions) { question, draft in
            draft.toggle(question.options[0].label, in: question)
        }
        let updated = try #require(answer["updatedInput"] as? [String: Any])
        #expect(updated["answers"] as? [String: String] == ["Какую базу?": "PostgreSQL", "Что настроить?": "Миграции"])
        let returned = try #require(updated["questions"] as? [[String: Any]])
        #expect(returned.map { $0["header"] as? String } == ["База", "Настройка"])
        #expect(((returned[0]["options"] as? [[String: String]])?[1])?["description"] == "Файл")
    }

    @Test("Простое разрешение на вопрос: посредник ничего не решает, и вопрос остаётся в Claude")
    func plainAllowOnQuestion() async throws {
        let path = socketPath()
        let (server, received) = try server(path)
        defer { server.stop() }
        let task = ask(path, try request(tool: "AskUserQuestion", input: questions))
        #expect(await eventually { received.firstRequest != nil })
        server.answer(try #require(received.firstRequest).id, .allow)
        let result = try await task.value
        #expect(result.status == 0)
        #expect(result.output.isEmpty)
    }

    private var planInput: [String: Any] {
        ["plan": "# План\n1. Добавить таблицу.\n2. Перенести строки.", "planFilePath": "/x/proj/plan.md"]
    }

    @Test("План: текст доходит, подтверждение возвращается Claude")
    func planApproved() async throws {
        let path = socketPath()
        let (server, received) = try server(path)
        defer { server.stop() }
        let task = ask(path, try request(tool: "ExitPlanMode", input: planInput))
        #expect(await eventually { received.firstRequest != nil })
        let held = try #require(received.firstRequest)
        #expect(held.content == .plan("# План\n1. Добавить таблицу.\n2. Перенести строки."))
        server.answer(held.id, .allow)
        let answer = try decision(try await task.value)
        #expect(answer["behavior"] as? String == "allow")
        #expect((answer["updatedInput"] as? [String: String])?["plan"] == "# План\n1. Добавить таблицу.\n2. Перенести строки.")
    }

    @Test("План отклонён: Claude получает комментарий")
    func planDenied() async throws {
        let path = socketPath()
        let (server, received) = try server(path)
        defer { server.stop() }
        let task = ask(path, try request(tool: "ExitPlanMode", input: planInput))
        #expect(await eventually { received.firstRequest != nil })
        server.answer(try #require(received.firstRequest).id, .deny(reason: "сначала резервная копия"))
        let answer = try decision(try await task.value)
        #expect(answer["behavior"] as? String == "deny")
        #expect(answer["message"] as? String == "сначала резервная копия")
    }

    @Test("Время на ответ задаёт приложение: посредник уходит без решения, запрос остаётся в Claude")
    func appDecidesTheWait() async throws {
        let path = socketPath()
        let (server, received) = try server(path)
        defer { server.stop() }
        server.setAnswerWindow(1)
        // The limit in Claude's settings is far away, and the app lets go first.
        let result = try await ask(path, permission, limit: 30).value
        #expect(result.status == 0)
        #expect(result.output.isEmpty)
        #expect(result.seconds >= 0.9)
        #expect(result.seconds < 10)
        let held = try #require(received.firstRequest)
        #expect(await eventually { received.allExpired == [held.id] })
        #expect(received.allGone.isEmpty, "это не ответ в Claude")
        #expect(held.deadline.timeIntervalSince(held.askedAt) == 1)
    }

    @Test("Ответ после истечения времени никуда не идёт")
    func answerAfterExpiry() async throws {
        let path = socketPath()
        let (server, received) = try server(path)
        defer { server.stop() }
        server.setAnswerWindow(1)
        let task = ask(path, permission, limit: 30)
        #expect(await eventually { received.firstRequest != nil })
        #expect(await eventually(longer: true) { !received.allExpired.isEmpty })
        server.answer(try #require(received.firstRequest).id, .allow)
        #expect(try await task.value.output.isEmpty)
    }

    @Test("Новое время действует на следующие запросы, а не на открытые")
    func waitChangeKeepsOpenRequests() async throws {
        let path = socketPath()
        let (server, received) = try server(path)
        defer { server.stop() }
        server.setAnswerWindow(30)
        let first = ask(path, try request(tool: "Bash", session: "s1", input: ["command": "a"]))
        #expect(await eventually { received.allRequests.count == 1 })
        server.setAnswerWindow(1)
        let second = ask(path, try request(tool: "Bash", session: "s2", input: ["command": "b"]))
        #expect(try await second.value.output.isEmpty)
        #expect(received.allExpired.count <= 1)
        server.answer(try #require(received.allRequests.first { $0.session == "s1" }).id, .allow)
        #expect(try decision(try await first.value)["behavior"] as? String == "allow", "первый запрос всё ещё можно разрешить")
    }

    @Test("Boris закрылся во время запроса: посредник сразу уходит без решения")
    func appQuitsDuringRequest() async throws {
        let path = socketPath()
        let (server, received) = try server(path)
        let task = ask(path, permission, limit: 30)
        #expect(await eventually { received.firstRequest != nil })
        server.stop()
        let result = try await task.value
        #expect(result.status == 0)
        #expect(result.output.isEmpty)
        #expect(result.seconds < 10)
    }

    @Test("Boris убит во время запроса: то же самое")
    func appKilledDuringRequest() async throws {
        let path = socketPath()
        // Another process holds the socket, so that it really dies with the request open.
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        holder.arguments = ["-I", "-c", """
        import socket, sys, time
        s = socket.socket(socket.AF_UNIX)
        s.bind(sys.argv[1])
        s.listen(1)
        c, _ = s.accept()
        c.recv(65536)
        print("held", flush=True)
        time.sleep(60)
        """, path]
        let out = Pipe()
        holder.standardOutput = out
        try holder.run()
        defer { unlink(path) }
        #expect(await eventually(longer: true) { access(path, F_OK) == 0 })
        let task = ask(path, permission, limit: 30)
        let line = out.fileHandleForReading.availableData
        #expect(String(decoding: line, as: UTF8.self).contains("held"))
        kill(holder.processIdentifier, SIGKILL)
        #expect(await eventually(longer: true) { !holder.isRunning })
        let result = try await task.value
        #expect(result.status == 0)
        #expect(result.output.isEmpty)
        #expect(result.seconds < 10)
    }

    @Test("Посредник прерван, как при ответе в Claude: запрос исчезает из очереди")
    func hookGoesAway() async throws {
        let path = socketPath()
        let (server, received) = try server(path)
        defer { server.stop() }
        let binary = try #require(Self.binary)
        let process = Process()
        process.executableURL = binary
        process.arguments = ["--permission", "30"]
        process.environment = ["BORIS_HOOK_SOCKET": path, "HOME": NSHomeDirectory()]
        let stdin = Pipe()
        process.standardInput = stdin
        process.standardOutput = Pipe()
        try process.run()
        stdin.fileHandleForWriting.write(Data(permission.utf8))
        try stdin.fileHandleForWriting.close()
        #expect(await eventually { received.firstRequest != nil })
        process.terminate()
        #expect(await eventually(longer: true) { !process.isRunning })
        let held = try #require(received.firstRequest)
        #expect(await eventually { received.allGone == [held.id] })
        #expect(received.allExpired.isEmpty)
        // The answer to a hook that has just gone away must not bring the app down.
        server.answer(held.id, .allow)
    }

    @Test("Ответ в соединение, чей посредник уже мёртв, не роняет приложение")
    func answerToDeadHook() async throws {
        let path = socketPath()
        let (server, received) = try server(path)
        defer { server.stop() }
        let binary = try #require(Self.binary)
        let process = Process()
        process.executableURL = binary
        process.arguments = ["--permission", "30"]
        process.environment = ["BORIS_HOOK_SOCKET": path, "HOME": NSHomeDirectory()]
        let stdin = Pipe()
        process.standardInput = stdin
        process.standardOutput = Pipe()
        try process.run()
        stdin.fileHandleForWriting.write(Data(permission.utf8))
        try stdin.fileHandleForWriting.close()
        #expect(await eventually { received.firstRequest != nil })
        let id = try #require(received.firstRequest).id

        // A client that says nothing holds the server's queue for its read timeout, so the answer waits there while the hook dies.
        let silent = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(silent) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(silent, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        #expect(connected == 0)
        try await Task.sleep(for: .milliseconds(300))
        server.answer(id, .allow)
        kill(process.processIdentifier, SIGKILL)
        #expect(await eventually(longer: true) { !process.isRunning })

        // Getting past this line alive is the check: a plain write here ends the whole process with SIGPIPE.
        #expect(server.start())
        #expect(received.allGone.isEmpty, "ответ был записан раньше, чем сервер заметил смерть посредника")
    }

    @Test("Claude перестал слушать ответ: посредник всё равно выходит тихо, а не падает")
    func nobodyReadsTheAnswer() async throws {
        let path = socketPath()
        let (server, received) = try server(path)
        defer { server.stop() }
        let binary = try #require(Self.binary)
        let process = Process()
        process.executableURL = binary
        process.arguments = ["--permission", "30"]
        process.environment = ["BORIS_HOOK_SOCKET": path, "HOME": NSHomeDirectory()]
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        stdin.fileHandleForWriting.write(Data(permission.utf8))
        try stdin.fileHandleForWriting.close()
        #expect(await eventually { received.firstRequest != nil })
        try stdout.fileHandleForReading.close()
        server.answer(try #require(received.firstRequest).id, .allow)
        #expect(await eventually(longer: true) { !process.isRunning })
        #expect(process.terminationReason == .exit)
        #expect(process.terminationStatus == 0)
    }

    @Test("Приложение пропало посреди длинной записи: тихий выход, а не сигнал")
    func appVanishesWhileWriting() async throws {
        let path = socketPath()
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        #expect(bound == 0)
        #expect(listen(listener, 1) == 0)
        defer {
            close(listener)
            unlink(path)
        }
        // Larger than a socket's buffer, so the hook is still writing when the other end closes.
        let big = try request(tool: "Write", input: ["file_path": "/x/a", "content": String(repeating: "x", count: 200 * 1024)])
        let task = ask(path, big, limit: 5)
        let client = accept(listener, nil, nil)
        close(client)
        let result = try await task.value
        #expect(result.status == 0, "посредник не должен умирать от SIGPIPE")
        #expect(result.output.isEmpty)
    }

    @Test("Запрос, который не дочитать в Boris, виден как нечитаемый")
    func tooLongToRead() async throws {
        let path = socketPath()
        let (server, received) = try server(path)
        defer { server.stop() }
        let task = ask(path, try request(tool: "Write", input: ["file_path": "/x/a", "content": String(repeating: "y", count: 300 * 1024)]))
        #expect(await eventually { received.firstRequest != nil })
        let held = try #require(received.firstRequest)
        guard case .unreadable(let text) = held.content else {
            Issue.record("такой запрос нельзя разрешить из Boris: \(held.content)")
            return
        }
        #expect(!text.isEmpty)
        server.answer(held.id, .deny(reason: ""))
        #expect(try decision(try await task.value)["behavior"] as? String == "deny")
    }

    @Test("Конец инструмента находит свой запрос по отпечатку, без текста")
    func toolDoneFindsRequest() async throws {
        let path = socketPath()
        let (server, received) = try server(path)
        defer { server.stop() }
        let input = ["command": "npm run migrate"]
        let task = ask(path, try request(tool: "Bash", input: input))
        #expect(await eventually { received.firstRequest != nil })
        let held = try #require(received.firstRequest)
        let done = try encoded(["hook_event_name": "PostToolUse", "session_id": "s1", "tool_name": "Bash", "tool_input": input, "tool_response": ["stdout": "SECRET"]])
        _ = try run(socket: path, input: done)
        let digest = try #require(held.digest)
        #expect(await eventually { received.allDone == [digest] })
        server.release(held.id)
        #expect(try await task.value.output.isEmpty, "отпущенный посредник ничего не решает")
    }
}
