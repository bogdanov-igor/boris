import BorisCore
import Foundation
import Testing
@testable import BorisData

/// What ssh is told, with nothing to connect to.
@Suite("Запуск ssh")
struct SSHToolTests {
    @Test("Имя машины не может стать опцией ssh", arguments: ["-oProxyCommand=evil", "-J", "", " ", "a b", "a;b", "a\nb", "$(evil)", "`evil`", "имя", "a/b", "-"])
    func badNames(name: String) {
        #expect(!RemoteMachine.isAcceptable(name))
    }

    @Test("Обычные имена проходят", arguments: ["build-server", "me@build-server", "gpu_box", "10.0.0.5", "me@10.0.0.5", "[::1]", "host.example.org", "server1"])
    func goodNames(name: String) {
        #expect(RemoteMachine.isAcceptable(name))
    }

    @Test("Запуск не ждёт пароля и не трогает чужие соединения") func options() {
        let arguments = SSHTool.arguments(machine: "build-server", forward: (remote: "/home/me/.boris/hook.sock", local: "/x/y.sock"), command: "true")
        for option in ["BatchMode=yes", "ControlMaster=no", "ControlPath=none", "RemoteCommand=none", "ExitOnForwardFailure=no"] {
            #expect(arguments.contains(option), "Нет \(option)")
        }
        #expect(arguments.contains("-T"))
        // Neither agent nor display: the helper needs neither.
        #expect(arguments.contains("-a"))
        #expect(arguments.contains("-x"))
        // Nothing that could carry a credential.
        #expect(!arguments.contains { $0.lowercased().contains("password") || $0.hasPrefix("-i") })
        let separator = arguments.firstIndex(of: "--") ?? 0
        #expect(arguments[separator + 1] == "build-server")
        #expect(arguments.last == "true")
    }

    /// The real ssh only parses here: `-G` prints what it understood and connects to nothing, and `-F /dev/null` keeps the person's config out of it.
    @Test("Настоящий ssh понимает пробел и двоеточие в пути сокета") func realParser() throws {
        let local = "/Users/me/Library/Application Support/Boris/remote/a1:b2.sock"
        let spec = SSHTool.forwardSpec(remote: "/home/me/.boris/hook.sock", local: local)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-G", "-F", "/dev/null", "-R", spec, "example.invalid"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        let line = text.split(separator: "\n").first { $0.hasPrefix("remoteforward ") }
        #expect(line == "remoteforward /home/me/.boris/hook.sock \(local)")
    }

    /// The options themselves have to mean something to this ssh, or a person's Mac would refuse to start it at all.
    @Test("Настоящий ssh принимает все опции") func realParserTakesOptions() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-G", "-F", "/dev/null"] + SSHTool.options + ["example.invalid"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        for expected in ["batchmode yes", "controlmaster false", "exitonforwardfailure no", "serveraliveinterval 15", "connecttimeout 10", "requesttty false", "forwardagent no", "forwardx11 no"] {
            #expect(text.split(separator: "\n").contains { $0.hasPrefix(expected) }, "Нет \(expected)")
        }
    }

    @Test("Ошибки ssh называются понятной причиной", arguments: [
        ("me@host: Permission denied (publickey).", Int32(255), RemoteFailure.refused),
        ("Host key verification failed.", 255, .hostKey),
        ("@@@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @@@", 255, .hostKey),
        ("ssh: Could not resolve hostname nope: nodename nor servname provided, or not known", 255, .unknownName),
        ("ssh: connect to host x port 22: Connection refused", 255, .unreachable),
        ("ssh: connect to host x port 22: Operation timed out", 255, .unreachable),
        ("ssh: connect to host x port 22: No route to host", 255, .unreachable),
        ("Connection to x closed by remote host.", 255, .dropped),
        ("", 72, .noPython),
        ("sh: python3: not found", 127, .noPython),
        ("some banner that says nothing", 3, .other(3)),
    ])
    func failures(stderr: String, status: Int32, expected: RemoteFailure) {
        #expect(RemoteFailure.classify(status: status, stderr: stderr) == expected)
    }
}

/// A whole connection through the fake ssh, with the real helper and the real socket server on this side.
@Suite("Соединение с машиной", .serialized)
struct RemoteLinkTests {
    private final class Heard: @unchecked Sendable {
        private let lock = NSLock()
        private var states: [RemoteLink.State] = []
        private var messages: [RemoteMessage] = []

        func add(_ state: RemoteLink.State) {
            lock.lock()
            states.append(state)
            lock.unlock()
        }

        func add(_ message: RemoteMessage) {
            lock.lock()
            messages.append(message)
            lock.unlock()
        }

        var state: RemoteLink.State? {
            lock.lock()
            defer { lock.unlock() }
            return states.last
        }

        var allStates: [RemoteLink.State] {
            lock.lock()
            defer { lock.unlock() }
            return states
        }

        var isUp: Bool {
            if case .up? = state { return true }
            return false
        }

        var failure: RemoteFailure? {
            if case .down(let failure)? = state { return failure }
            return nil
        }

        var ups: Int {
            allStates.filter { if case .up = $0 { return true } else { return false } }.count
        }

        var sessions: [RemoteSessionReport]? {
            lock.lock()
            defer { lock.unlock() }
            for message in messages.reversed() {
                if case .sessions(let list) = message { return list }
            }
            return nil
        }

        var vitals: RemoteVitals? {
            lock.lock()
            defer { lock.unlock() }
            for message in messages.reversed() {
                if case .alive(let vitals) = message { return vitals }
            }
            return nil
        }

        var rows: [RemoteSpendRow] {
            lock.lock()
            defer { lock.unlock() }
            return messages.flatMap { message -> [RemoteSpendRow] in
                if case .numbers(_, let rows) = message { return rows }
                return []
            }
        }
    }

    private func timing() -> RemoteLink.Timing {
        var timing = RemoteLink.Timing()
        timing.retries = [0.1]
        return timing
    }

    private func link(_ machine: FakeMachine, heard: Heard, name: String = "build-server", timing: RemoteLink.Timing? = nil) -> RemoteLink {
        RemoteLink(machine: name, localSocket: machine.localSocket, tool: machine.tool, wait: 600, timing: timing ?? self.timing()) {
            heard.add($0)
        } onMessage: {
            heard.add($0)
        }
    }

    private func server(_ machine: FakeMachine) throws -> HookServer {
        let server = HookServer(path: machine.localSocket, host: "build-server")
        #expect(server.start())
        return server
    }

    @Test("Соединение поднимается, и с машины приходят сессии и числа") func connects() async throws {
        let machine = FakeMachine()
        machine.listSession("s-1")
        machine.writeClaudeFile("projects/-srv-app/s-1.jsonl", FakeMachine.assistantLine(id: "m1"))
        let heard = Heard()
        let link = link(machine, heard: heard)
        link.start()
        defer { link.stop() }
        #expect(await arrives { heard.isUp })
        #expect(await arrives { heard.sessions?.first?.id == "s-1" })
        #expect(await arrives { heard.rows.first?.usage.input == 100 })
        #expect(heard.allStates.first == .connecting)
        // The helper went to the machine by itself, and it is the one in this build.
        #expect(try Data(contentsOf: machine.boris.appendingPathComponent("boris-hook")) == RemoteHelper.source)
    }

    @Test("Живые события идут по туннелю и приходят со своей машины") func eventsGoThroughTheTunnel() async throws {
        let machine = FakeMachine()
        let server = try server(machine)
        defer { server.stop() }
        let signals = Signals()
        server.onSignal = { signals.add($0) }
        let heard = Heard()
        let link = link(machine, heard: heard)
        link.start()
        defer { link.stop() }
        #expect(await arrives { heard.vitals?.socket == true })

        // Claude on the machine starts the hook that was installed there.
        let output = try machine.helper([], input: #"{"hook_event_name":"PreToolUse","session_id":"s-1","tool_name":"Bash","tool_input":{"command":"ls"}}"#)
        #expect(output.status == 0)
        #expect(await arrives { signals.all.contains(.toolStarted(session: "s-1", agent: nil, tool: "Bash")) })
    }

    @Test("Запрос с машины получает ответ, и он доходит до Claude там") func requestRoundTrip() async throws {
        let machine = FakeMachine()
        let server = try server(machine)
        defer { server.stop() }
        let requests = Requests()
        server.onPermission = { requests.add($0) }
        let heard = Heard()
        let link = link(machine, heard: heard)
        link.start()
        defer { link.stop() }
        #expect(await arrives { heard.vitals?.socket == true })

        let result = Answer()
        let hook = Thread { result.set(try? machine.helper(["--permission", "60"], input: #"{"hook_event_name":"PermissionRequest","session_id":"s-1","cwd":"/srv/app","tool_name":"Bash","tool_input":{"command":"npm test"}}"#)) }
        hook.start()
        #expect(await arrives { !requests.all.isEmpty })
        let request = try #require(requests.all.first)
        #expect(request.host == "build-server")
        #expect(request.cwd == "/srv/app")
        #expect(request.content == .command("npm test", unsandboxed: false))
        server.answer(request.id, .allow)
        #expect(await arrives { result.value != nil })
        #expect(result.value?.text.contains("\"allow\"") == true)
    }

    @Test("Обрыв виден сразу, запрос остаётся у Claude, а связь возвращается сама") func dropAndReconnect() async throws {
        let machine = FakeMachine()
        machine.listSession("s-1")
        let server = try server(machine)
        defer { server.stop() }
        let requests = Requests()
        server.onPermission = { requests.add($0) }
        let gone = Answer()
        server.onPermissionGone = { _ in gone.set(FakeMachine.Output(status: 0, text: "gone", data: Data())) }
        let heard = Heard()
        let link = link(machine, heard: heard)
        link.start()
        defer { link.stop() }
        #expect(await arrives { heard.vitals?.socket == true })

        let result = Answer()
        Thread { result.set(try? machine.helper(["--permission", "60"], input: #"{"hook_event_name":"PermissionRequest","session_id":"s-1","tool_name":"Bash","tool_input":{"command":"ls"}}"#)) }.start()
        #expect(await arrives { !requests.all.isEmpty })

        machine.failNext("ssh: connect to host x port 22: Connection refused")
        machine.dropConnection()
        #expect(await arrives { heard.failure != nil })
        // Dropped while up, so that is what it says, whatever the next attempt runs into.
        #expect(heard.allStates.contains(.down(.dropped)))

        // The hook goes away without a decision, so the question stays in Claude's own interface.
        #expect(await arrives { result.value != nil })
        #expect(result.value?.status == 0)
        #expect(result.value?.text.isEmpty == true)
        #expect(await arrives { gone.value != nil })

        // While the machine is out of reach the attempts go on, each failing for its own reason.
        #expect(await arrives { heard.failure == .unreachable })

        // The socket file stayed behind on the machine, and a real sshd refuses to forward over it unless it is cleared first.
        #expect(FileManager.default.fileExists(atPath: machine.boris.appendingPathComponent("hook.sock").path))
        machine.allowConnections()
        machine.stopFailing()
        #expect(await arrives { heard.ups == 2 })
        #expect(await arrives { heard.vitals?.socket == true })
        let signals = Signals()
        server.onSignal = { signals.add($0) }
        _ = try machine.helper([], input: #"{"hook_event_name":"Stop","session_id":"s-1"}"#)
        #expect(await arrives { signals.all.contains(.turnStopped(session: "s-1")) })
    }

    @Test("Причина, по которой не подключиться, называется", arguments: [
        ("me@host: Permission denied (publickey).", RemoteFailure.refused),
        ("Host key verification failed.", .hostKey),
        ("ssh: Could not resolve hostname nope: nodename nor servname provided, or not known", .unknownName),
        ("ssh: connect to host x port 22: Connection refused", .unreachable),
    ])
    func namedFailures(message: String, expected: RemoteFailure) async throws {
        let machine = FakeMachine()
        machine.failNext(message)
        let heard = Heard()
        let link = link(machine, heard: heard)
        link.start()
        defer { link.stop() }
        #expect(await arrives { heard.failure == expected })
    }

    @Test("Без python3 на машине так и сказано") func noPython() async throws {
        let machine = FakeMachine()
        // A PATH with what the first step needs and no python3.
        let tools = machine.root.appendingPathComponent("remote-bin")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        for name in ["mkdir", "cat", "chmod", "mv", "rm", "cmp", "sh"] {
            for folder in ["/bin", "/usr/bin"] where FileManager.default.isExecutableFile(atPath: "\(folder)/\(name)") {
                try? FileManager.default.createSymbolicLink(atPath: tools.appendingPathComponent(name).path, withDestinationPath: "\(folder)/\(name)")
            }
        }
        var environment = machine.environment
        environment["FAKE_SSH_REMOTE_PATH"] = tools.path
        let heard = Heard()
        let link = RemoteLink(machine: "build-server", localSocket: machine.localSocket, tool: SSHTool(executable: machine.tool.executable, environment: environment), wait: 600, timing: timing()) {
            heard.add($0)
        } onMessage: {
            heard.add($0)
        }
        link.start()
        defer { link.stop() }
        #expect(await arrives { heard.failure == .noPython })
    }

    @Test("Без ssh на Mac так и сказано") func noSSH() async throws {
        let machine = FakeMachine()
        let heard = Heard()
        let link = RemoteLink(machine: "build-server", localSocket: machine.localSocket, tool: SSHTool(executable: nil, environment: ["PATH": "/nonexistent"]), wait: 600, timing: timing()) {
            heard.add($0)
        } onMessage: {
            heard.add($0)
        }
        link.start()
        defer { link.stop() }
        #expect(await arrives { heard.failure == .noSSH })
    }

    @Test("Машина не разрешает пересылку сокета: связь есть, но живых событий нет, и это видно") func socketForwardRefused() async throws {
        let machine = FakeMachine()
        machine.refuseSocketForward()
        machine.listSession("s-1")
        let heard = Heard()
        let link = link(machine, heard: heard)
        link.start()
        defer { link.stop() }
        #expect(await arrives { heard.isUp })
        #expect(await arrives { heard.vitals != nil })
        #expect(heard.vitals?.socket == false)
        // Status keeps coming anyway.
        #expect(await arrives { heard.sessions?.first?.id == "s-1" })
    }

    @Test("Замолчавший помощник считается потерянной связью") func silenceMeansLost() async throws {
        let machine = FakeMachine()
        var timing = timing()
        timing.silence = 0.4
        var environment = machine.environment
        // Its heartbeat comes far too rarely for this short a limit, as if it had stopped.
        environment["BORIS_REMOTE_TICK"] = "30"
        let heard = Heard()
        let link = RemoteLink(machine: "build-server", localSocket: machine.localSocket, tool: SSHTool(executable: machine.tool.executable, environment: environment), wait: 600, timing: timing) {
            heard.add($0)
        } onMessage: {
            heard.add($0)
        }
        link.start()
        defer { link.stop() }
        #expect(await arrives { heard.isUp })
        #expect(await arrives { heard.allStates.contains(.down(.dropped)) })
    }

    @Test("Остановка завершает ssh и больше не пытается подключиться") func stopEndsEverything() async throws {
        let machine = FakeMachine()
        let heard = Heard()
        let link = link(machine, heard: heard)
        link.start()
        #expect(await arrives { heard.isUp })
        link.stop()
        #expect(await arrives { heard.state == .stopped })
        let calls = machine.calls.count
        try await Task.sleep(for: .milliseconds(600))
        #expect(machine.calls.count == calls)
        #expect(heard.state == .stopped)
    }

    @Test("Помощник обновляется, когда в Boris другая версия, и не трогается, когда та же") func helperUpdates() async throws {
        let machine = FakeMachine()
        machine.installHelper()
        let file = machine.boris.appendingPathComponent("boris-hook")
        let original = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        let same = await machine.tool.run(machine: "m", command: RemoteCommand.prepare(wait: 600), input: RemoteHelper.source)
        #expect(same.failure == nil)
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date == original)

        try "old version".write(to: file, atomically: true, encoding: .utf8)
        let changed = await machine.tool.run(machine: "m", command: RemoteCommand.prepare(wait: 600), input: RemoteHelper.source)
        #expect(changed.failure == nil)
        #expect(try Data(contentsOf: file) == RemoteHelper.source)
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o700)
        #expect(try FileManager.default.attributesOfItem(atPath: machine.boris.path)[.posixPermissions] as? Int == 0o700)
    }

    @Test("Действия с хуками идут через ssh") func hookActions() async throws {
        let machine = FakeMachine()
        machine.installHelper()
        let helper = RemoteHelper(tool: machine.tool, machine: "build-server", wait: 600)
        let preview = await helper.previewHooks()
        #expect(preview?.ok == true)
        #expect(preview?.lines.isEmpty == false)
        #expect(await helper.installHooks()?.ok == true)
        #expect(try String(contentsOf: machine.claude.appendingPathComponent("settings.json"), encoding: .utf8).contains("--permission 600"))
        #expect(await helper.uninstallHooks()?.ok == true)
        machine.failNext("ssh: connect to host x port 22: Connection refused")
        #expect(await helper.purge() == nil)
    }

    private final class Signals: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [HookSignal] = []

        func add(_ signal: HookSignal) {
            lock.lock()
            stored.append(signal)
            lock.unlock()
        }

        var all: [HookSignal] {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }

    private final class Requests: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [PendingPermission] = []

        func add(_ request: PendingPermission) {
            lock.lock()
            stored.append(request)
            lock.unlock()
        }

        var all: [PendingPermission] {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }

    private final class Answer: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: FakeMachine.Output?

        func set(_ output: FakeMachine.Output?) {
            lock.lock()
            stored = output
            lock.unlock()
        }

        var value: FakeMachine.Output? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }
}
