import BorisCore
import Foundation
import Testing
@testable import BorisData

/// The helper on a machine does in Python what `boris-hook` and `HookInstaller` do on the Mac. These keep the two from drifting apart.
@Suite("Помощник ведёт себя как boris-hook")
struct RemoteHookParityTests {
    private func object(_ text: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    /// What the helper would send to the Mac for this event.
    private func reduced(_ machine: FakeMachine, _ event: String, permission: Bool = false) async throws -> [String: Any] {
        let listener = SocketListener(path: machine.boris.appendingPathComponent("hook.sock").path, answer: permission ? "{}" : nil)
        defer { listener.close() }
        _ = try machine.helper(permission ? ["--permission", "5"] : [], input: event)
        return try object(await listener.nextLine())
    }

    @Test("Поля, которые уходят с машины, те же, что и на Mac", arguments: [
        #"{"hook_event_name":"PreToolUse","session_id":"s1","cwd":"/x/p","tool_name":"Bash","permission_mode":"default","tool_input":{"command":"secret"},"prompt":"private"}"#,
        #"{"hook_event_name":"PostToolUse","session_id":"s1","tool_name":"Workflow","tool_response":{"runId":"wf_1","other":"x"},"tool_input":{"a":1}}"#,
        #"{"hook_event_name":"PostToolUseFailure","session_id":"s1","tool_name":"Bash","agent_id":"agent-a1","agent_type":"scout","tool_input":{"command":"x"}}"#,
        #"{"hook_event_name":"SubagentStart","session_id":"s1","agent_id":"agent-a1"}"#,
        #"{"hook_event_name":"StopFailure","session_id":"s1","error":"rate_limit"}"#,
        #"{"hook_event_name":"Notification","session_id":"s1","notification_type":"permission_prompt","message":"private"}"#,
        #"{"hook_event_name":"SessionStart","session_id":"s1","source":"clear","cwd":"/x/p","number_field":7}"#,
        #"{"hook_event_name":"SessionEnd","session_id":"s1","reason":"other"}"#,
    ])
    func sameFields(event: String) async throws {
        let machine = FakeMachine()
        machine.installHelper()
        let expected = HookPayload.reduce(try object(event))
        var actual = try await reduced(machine, event)
        // Its digest only has to be the same between events of one machine, and those all come from the helper.
        #expect((actual["input_digest"] != nil) == (expected["input_digest"] != nil))
        actual["input_digest"] = nil
        var clean = expected
        clean["input_digest"] = nil
        #expect(NSDictionary(dictionary: actual).isEqual(to: clean))
    }

    @Test("Запрос собирается так же, как на Mac") func sameRequest() async throws {
        let machine = FakeMachine()
        machine.installHelper()
        let event = #"{"hook_event_name":"PermissionRequest","session_id":"s1","tool_name":"Bash","cwd":"/x/p","tool_input":{"command":"npm run migrate","description":"d"}}"#
        let expected = HookPayload.reduce(try object(event))
        let actual = try await reduced(machine, event, permission: true)
        #expect(actual["command_text"] as? String == expected["command_text"] as? String)
        #expect(NSDictionary(dictionary: actual["tool_input"] as? [String: Any] ?? [:]).isEqual(to: expected["tool_input"] as? [String: Any] ?? ["none": true]))
        #expect(actual["wait"] as? Bool == true)
        #expect(actual["input_digest"] is String)
    }

    @Test("Один и тот же вызов узнаётся по одному отпечатку, другой нет") func digestTellsCallsApart() async throws {
        let machine = FakeMachine()
        machine.installHelper()
        let asked = try await reduced(machine, #"{"hook_event_name":"PermissionRequest","session_id":"s1","tool_name":"Bash","tool_input":{"command":"a","x":"я"}}"#, permission: true)
        let done = try await reduced(machine, #"{"hook_event_name":"PostToolUse","session_id":"s1","tool_name":"Bash","tool_input":{"x":"я","command":"a"}}"#)
        let other = try await reduced(machine, #"{"hook_event_name":"PostToolUse","session_id":"s1","tool_name":"Bash","tool_input":{"command":"b","x":"я"}}"#)
        #expect(asked["input_digest"] as? String == done["input_digest"] as? String)
        #expect(asked["input_digest"] as? String != other["input_digest"] as? String)
    }

    @Test("Слишком большой запрос не передаётся целиком и потому не может быть разрешён") func tooLongRequest() async throws {
        let machine = FakeMachine()
        machine.installHelper()
        let long = String(repeating: "x", count: 300 * 1024)
        let actual = try await reduced(machine, #"{"hook_event_name":"PermissionRequest","session_id":"s1","tool_name":"Bash","tool_input":{"command":"\#(long)"}}"#, permission: true)
        #expect(actual["tool_input"] == nil)
        #expect((actual["command_text"] as? String)?.utf8.count ?? 0 <= 64 * 1024 + 4)
    }

    private static let answers: [(answer: HookAnswer, tool: String, input: String)] = [
        (.allow, "Bash", #"{"command":"ls"}"#),
        (.allow, "AskUserQuestion", #"{"questions":[]}"#),
        (.allow, "ExitPlanMode", #"{"plan":"p"}"#),
        (.deny(reason: ""), "Bash", #"{"command":"ls"}"#),
        (.deny(reason: "  сначала копию \n"), "Bash", #"{"command":"ls"}"#),
        (.answers(["Q": "A"]), "AskUserQuestion", #"{"questions":[{"question":"Q"}]}"#),
        (.answers(["Q": "A"]), "Bash", #"{"command":"ls"}"#),
    ]

    @Test("Ответ доходит до Claude в том же виде, что и на Mac", arguments: 0..<7)
    func sameAnswer(index: Int) async throws {
        let case_ = Self.answers[index]
        let machine = FakeMachine()
        machine.installHelper()
        let input = try object(case_.input)
        let line = String(decoding: case_.answer.line.dropLast(), as: UTF8.self)
        let listener = SocketListener(path: machine.boris.appendingPathComponent("hook.sock").path, answer: line)
        defer { listener.close() }
        let event = #"{"hook_event_name":"PermissionRequest","session_id":"s1","tool_name":"\#(case_.tool)","tool_input":\#(case_.input)}"#
        let output = try machine.helper(["--permission", "30"], input: event)
        let expected = case_.answer.output(tool: case_.tool, input: input)
        if let expected {
            let wanted = try #require(try JSONSerialization.jsonObject(with: expected) as? [String: Any])
            #expect(NSDictionary(dictionary: try object(output.text)).isEqual(to: wanted))
        } else {
            #expect(output.text.isEmpty)
        }
        #expect(output.status == 0)
    }

    @Test("Обрезанная строка и чепуха вместо ответа не решают ничего", arguments: [#"{"behavior":"allow""#, "nonsense", #"{"behavior":"maybe"}"#, #"["allow"]"#, #"{"behavior":"allow","answers":{}}"#])
    func nonsenseDecidesNothing(answer: String) async throws {
        let machine = FakeMachine()
        machine.installHelper()
        let listener = SocketListener(path: machine.boris.appendingPathComponent("hook.sock").path, answer: answer)
        defer { listener.close() }
        let output = try machine.helper(["--permission", "30"], input: #"{"hook_event_name":"PermissionRequest","session_id":"s1","tool_name":"Bash","tool_input":{"command":"ls"}}"#)
        #expect(output.status == 0)
        #expect(output.text.isEmpty)
    }

    @Test("Без связи хук выходит сразу и молча", arguments: [[], ["--permission", "600"]])
    func noConnectionMeansSilentExit(arguments: [String]) throws {
        let machine = FakeMachine()
        let began = Date()
        let output = try machine.helper(arguments, input: #"{"hook_event_name":"PermissionRequest","session_id":"s1","tool_name":"Bash","tool_input":{"command":"ls"}}"#)
        #expect(output.status == 0)
        #expect(output.text.isEmpty)
        #expect(Date().timeIntervalSince(began) < 30)
    }

    @Test("Сокет от оборвавшейся связи не задерживает Claude") func staleSocketMeansSilentExit() throws {
        let machine = FakeMachine()
        machine.installHelper()
        // A file with nobody listening, as a dropped connection leaves it.
        let listener = SocketListener(path: machine.boris.appendingPathComponent("hook.sock").path)
        let path = machine.boris.appendingPathComponent("hook.sock").path
        listener.close()
        let leftover = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
        _ = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(leftover, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        close(leftover)
        #expect(FileManager.default.fileExists(atPath: path))
        let output = try machine.helper(["--permission", "600"], input: #"{"hook_event_name":"PermissionRequest","session_id":"s1","tool_name":"Bash","tool_input":{"command":"ls"}}"#)
        #expect(output.status == 0)
        #expect(output.text.isEmpty)
    }

    @Test("Сломанный ввод не мешает Claude", arguments: ["", "not json", "[1,2]"])
    func brokenInput(input: String) throws {
        let machine = FakeMachine()
        machine.installHelper()
        let listener = SocketListener(path: machine.boris.appendingPathComponent("hook.sock").path)
        defer { listener.close() }
        let output = try machine.helper([], input: input)
        #expect(output.status == 0)
        #expect(output.text.isEmpty)
    }
}

/// Claude's settings on a machine get the same care as on the Mac: exact changes first, others' entries kept, a clean way back.
@Suite("Настройки Claude на удалённой машине")
struct RemoteSettingsTests {
    private static let wait = 600

    private func plan(_ machine: FakeMachine) -> HookInstaller.Plan {
        HookInstaller.Plan(helperPath: machine.boris.appendingPathComponent("boris-hook").path, permissions: true, permissionWait: Self.wait)
    }

    private var noPolicy: ManagedSettings { ManagedSettings(folder: URL(fileURLWithPath: "/nonexistent"), profiles: []) }

    private func status(_ machine: FakeMachine) -> HookInstaller.Status {
        HookInstaller.status(at: machine.claude.appendingPathComponent("settings.json"), plan: plan(machine), managed: noPolicy)
    }

    private func result(_ output: FakeMachine.Output) -> RemoteHookResult? {
        RemoteHookResult(line: output.data)
    }

    private func helperStatus(_ machine: FakeMachine) throws -> String? {
        let output = try machine.helper(["info"])
        guard case .info(_, let vitals)? = RemoteMessage(line: output.data) else { return nil }
        return vitals.hooks?.rawValue
    }

    @Test("Записи помощника принимает проверка с Mac: те же события и команды") func sameEntriesAsTheMac() throws {
        let machine = FakeMachine()
        #expect(try helperStatus(machine) == "notInstalled")
        #expect(result(try machine.helper(["install"]))?.ok == true)
        #expect(status(machine) == .installed)
        #expect(try helperStatus(machine) == "installed")
    }

    @Test("Записи с Mac помощник тоже считает своими") func entriesOfTheMacCount() throws {
        let machine = FakeMachine()
        machine.installHelper()
        try HookInstaller.install(at: machine.claude.appendingPathComponent("settings.json"), plan: plan(machine))
        #expect(try helperStatus(machine) == "installed")
    }

    @Test("Сначала показываются точные изменения, и ничего не записано") func previewChangesNothing() throws {
        let machine = FakeMachine()
        let settings = #"{"model":"opus","env":{"ANTHROPIC_API_KEY":"SECRETkey"}}"#
        let file = machine.writeClaudeFile("settings.json", settings)
        let output = try machine.helper(["preview"])
        let preview = try #require(result(output))
        #expect(preview.ok)
        #expect(preview.lines.contains { $0.hasPrefix("+ ") && $0.contains("boris-hook") })
        #expect(preview.lines.allSatisfy { $0.hasPrefix("+ ") || $0.hasPrefix("- ") })
        #expect(preview.reformats)
        // What is in the settings has no business leaving the machine.
        #expect(!output.text.contains("SECRETkey"))
        #expect(try String(contentsOf: file, encoding: .utf8) == settings)
        #expect(!FileManager.default.fileExists(atPath: file.path + ".boris-backup"))
    }

    @Test("Чужие хуки и настройки остаются, копия сохранена, отключение возвращает файл побайтно") func cleanWayBack() throws {
        let machine = FakeMachine()
        // A layout of its own, which only the exact copy can bring back.
        let original = #"{ "model": "opus",   "hooks": { "PreToolUse": [ { "matcher": "Bash", "hooks": [ { "type": "command", "command": "my-own-hook" } ] } ] } }"#
        let file = machine.writeClaudeFile("settings.json", original)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file.path)
        #expect(result(try machine.helper(["install"]))?.ok == true)

        let installed = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(installed["model"] as? String == "opus")
        let pre = (installed["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]]
        #expect(pre?.count == 2)
        #expect((pre?.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String == "my-own-hook")
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o640)
        #expect(try FileManager.default.attributesOfItem(atPath: file.path + ".boris-backup")[.posixPermissions] as? Int == 0o640)
        #expect(try String(contentsOfFile: file.path + ".boris-backup", encoding: .utf8) == original)

        #expect(result(try machine.helper(["uninstall"]))?.ok == true)
        #expect(try String(contentsOf: file, encoding: .utf8) == original)
        #expect(!FileManager.default.fileExists(atPath: file.path + ".boris-backup"))
    }

    @Test("Починка не портит копию исходного файла") func repairKeepsTheBackup() throws {
        let machine = FakeMachine()
        let original = #"{"model":"opus"}"#
        let file = machine.writeClaudeFile("settings.json", original)
        #expect(result(try machine.helper(["install"]))?.ok == true)
        #expect(result(try machine.helper(["install"]))?.ok == true)
        #expect(try String(contentsOfFile: file.path + ".boris-backup", encoding: .utf8) == original)
        #expect(status(machine) == .installed)
    }

    @Test("Файла не было: после отключения его снова нет") func noFileBefore() throws {
        let machine = FakeMachine()
        let file = machine.claude.appendingPathComponent("settings.json")
        #expect(result(try machine.helper(["install"]))?.ok == true)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(result(try machine.helper(["uninstall"]))?.ok == true)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test("Файл поменяли после подключения: уходят только записи Boris") func changedAfterInstall() throws {
        let machine = FakeMachine()
        let file = machine.writeClaudeFile("settings.json", #"{"model":"opus"}"#)
        #expect(result(try machine.helper(["install"]))?.ok == true)
        var settings = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        settings["theme"] = "dark"
        try JSONSerialization.data(withJSONObject: settings).write(to: file)
        #expect(result(try machine.helper(["uninstall"]))?.ok == true)
        let after = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(after["theme"] as? String == "dark")
        #expect(after["model"] as? String == "opus")
        #expect(after["hooks"] == nil)
    }

    @Test("В повреждённый файл ничего не пишется", arguments: ["{ not json", "[1,2,3]", #"{"hooks":"oops"}"#, #"{"hooks":{"PreToolUse":{"a":1}}}"#])
    func damagedFileStaysUntouched(text: String) throws {
        let machine = FakeMachine()
        let file = machine.writeClaudeFile("settings.json", text)
        #expect(try helperStatus(machine) == "unreadable")
        #expect(result(try machine.helper(["preview"]))?.ok == false)
        #expect(result(try machine.helper(["install"]))?.ok == false)
        #expect(result(try machine.helper(["uninstall"]))?.ok == false)
        #expect(try String(contentsOf: file, encoding: .utf8) == text)
    }

    @Test("Файл настроек по ссылке остаётся там, где его держит владелец") func settingsBehindALink() throws {
        let machine = FakeMachine()
        let real = machine.home.appendingPathComponent("dotfiles/claude-settings.json")
        try FileManager.default.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"model":"opus"}"#.write(to: real, atomically: true, encoding: .utf8)
        let link = machine.claude.appendingPathComponent("settings.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(result(try machine.helper(["install"]))?.ok == true)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == real.path)
        #expect(try String(contentsOf: real, encoding: .utf8).contains("boris-hook"))
    }

    @Test("Запрет хуков виден отдельно от настройки владельца") func policyAndChoice() throws {
        let machine = FakeMachine()
        machine.writeClaudeFile("settings.json", #"{"disableAllHooks":true}"#)
        #expect(try helperStatus(machine) == "disabledInSettings")
        let managed = machine.root.appendingPathComponent("managed")
        try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
        try #"{"allowManagedHooksOnly":true}"#.write(to: managed.appendingPathComponent("managed-settings.json"), atomically: true, encoding: .utf8)
        #expect(try helperStatus(machine) == "disabledByPolicy")
    }

    @Test("Хуки с помощником работают, пока его не убрали, и безвредны после") func removedHelperIsHarmless() throws {
        let machine = FakeMachine()
        #expect(result(try machine.helper(["install"]))?.ok == true)
        let settings = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: machine.claude.appendingPathComponent("settings.json"))) as? [String: Any])
        let command = try #require((((settings["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String)
        try FileManager.default.removeItem(at: machine.boris)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    @Test("Уборка снимает хуки и всё своё, а чужое оставляет") func purgeTakesEverythingOff() throws {
        let machine = FakeMachine()
        let file = machine.writeClaudeFile("settings.json", #"{"model":"opus"}"#)
        machine.writeClaudeFile("projects/-x/s.jsonl", FakeMachine.assistantLine())
        #expect(result(try machine.helper(["install"]))?.ok == true)
        try "cache".write(to: machine.boris.appendingPathComponent("numbers.json"), atomically: true, encoding: .utf8)
        #expect(result(try machine.helper(["purge"]))?.ok == true)
        #expect(!FileManager.default.fileExists(atPath: machine.boris.path))
        #expect(try String(contentsOf: file, encoding: .utf8) == #"{"model":"opus"}"#)
        #expect(FileManager.default.fileExists(atPath: machine.claude.appendingPathComponent("projects/-x/s.jsonl").path))
    }
}
