import BorisCore
import BorisData
import Foundation
import Testing
@testable import Boris

/// The whole way: a machine added to the list, a fake ssh, the real helper, the socket, the queue of requests and the model the screens read.
/// No real machine, no real ssh, and the model keeps nothing of the person's.
@MainActor
@Suite("Удалённые машины в приложении", .serialized)
struct RemoteHubTests {
    private final class Machine: @unchecked Sendable {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("h\(UUID().uuidString.prefix(8))")
        var home: URL { root.appendingPathComponent("home") }
        var control: URL { root.appendingPathComponent("control") }
        var claude: URL { home.appendingPathComponent(".claude") }
        var boris: URL { home.appendingPathComponent(".boris") }
        var support: URL { root.appendingPathComponent("s") }
        private var bin: URL { root.appendingPathComponent("bin") }

        init() {
            for folder in [home, control, bin, claude.appendingPathComponent("sessions"), support] {
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/fake-ssh")
            try? FileManager.default.copyItem(at: script, to: bin.appendingPathComponent("ssh"))
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        var environment: [String: String] {
            ["PATH": "\(bin.path):/usr/bin:/bin", "FAKE_SSH_CONTROL": control.path, "FAKE_SSH_HOME": home.path, "BORIS_REMOTE_TICK": "0.05", "BORIS_REMOTE_MANAGED": root.appendingPathComponent("managed").path]
        }

        var tool: SSHTool { SSHTool(executable: SSHTool.find(in: environment), environment: environment) }

        func listSession(_ id: String, status: String = "busy", cwd: String = "/srv/app") throws {
            let pid = ProcessInfo.processInfo.processIdentifier
            try #"{"pid":\#(pid),"sessionId":"\#(id)","cwd":"\#(cwd)","status":"\#(status)","startedAt":1762400000000,"statusUpdatedAt":1762400100000}"#.write(to: claude.appendingPathComponent("sessions/\(pid).json"), atomically: true, encoding: .utf8)
        }

        func writeSpend(session: String, input: Int) throws {
            let folder = claude.appendingPathComponent("projects/-srv-app")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: "Z", with: ".000Z")
            let line = #"{"type":"assistant","timestamp":"\#(stamp)","cwd":"/srv/app","message":{"id":"m-\#(session)","model":"claude-sonnet-5-5","usage":{"input_tokens":\#(input),"output_tokens":1}}}"# + "\n"
            try line.write(to: folder.appendingPathComponent("\(session).jsonl"), atomically: true, encoding: .utf8)
        }

        func drop() {
            FileManager.default.createFile(atPath: control.appendingPathComponent("drop").path, contents: Data())
        }

        func allow() {
            try? FileManager.default.removeItem(at: control.appendingPathComponent("drop"))
        }

        func refuse(_ message: String) {
            try? message.write(to: control.appendingPathComponent("fail"), atomically: true, encoding: .utf8)
        }

        func stopRefusing() {
            try? FileManager.default.removeItem(at: control.appendingPathComponent("fail"))
        }

        /// Starts a hook the way Claude does on that machine. It runs on until it has its answer.
        func runHook(_ arguments: [String], input: String, finished: @escaping @Sendable (String) -> Void) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", boris.appendingPathComponent("boris-hook").path] + arguments
            process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
            let file = root.appendingPathComponent("in-\(UUID().uuidString)")
            try input.write(to: file, atomically: true, encoding: .utf8)
            process.standardInput = try FileHandle(forReadingFrom: file)
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            Thread.detachNewThread {
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                finished(String(decoding: data, as: UTF8.self))
            }
        }
    }

    private final class Text: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: String?

        func set(_ text: String) {
            lock.lock()
            stored = text
            lock.unlock()
        }

        var value: String? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }

    /// A model that reads an empty Claude folder of its own, with the hub pointed at the fake machine.
    private func makeModel(_ machine: Machine) -> AppModel {
        let settings = AppSettings(defaults: nil)
        // A real, empty Claude folder on this Mac: a missing one would be a problem of its own, whatever the machines do.
        let here = machine.root.appendingPathComponent("here")
        try? FileManager.default.createDirectory(at: here.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        settings.claudeFolder = here.path
        let model = AppModel(settings: settings, store: nil, live: false)
        var timing = RemoteLink.Timing()
        timing.retries = [0.1]
        model.remote.useForCheck(tool: machine.tool, store: RemoteStore(folder: machine.support), timing: timing)
        return model
    }

    private func waitUntil(seconds: Double = 40, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    @Test("Сессия с машины появляется на экранах, а расход в суммах") func sessionAndSpendReachTheScreens() async throws {
        let machine = Machine()
        try machine.listSession("s-1")
        try machine.writeSpend(session: "s-1", input: 1234)
        let model = makeModel(machine)
        model.start()
        defer { model.remote.quit() }
        #expect(model.remote.add("build-server") == .added)

        #expect(await waitUntil { model.work.sessions.contains { $0.id == "s-1" } })
        let session = try #require(model.work.sessions.first { $0.id == "s-1" })
        #expect(session.environment == .remote(host: "build-server"))
        #expect(session.state == .running)
        #expect(model.remote.rows.first?.isUp == true)
        #expect(await waitUntil { model.usage.book?.spent(session: "s-1")?.input == 1234 })
        #expect(await waitUntil { model.today.input == 1234 })
        #expect(model.usage.book?.report(.today).lines(.environments).contains { $0.key == .environment(.remote(host: "build-server")) } == true)
    }

    @Test("Запрос с машины стоит в общей очереди и отвечается отсюда") func requestIsAnsweredFromHere() async throws {
        let machine = Machine()
        try machine.listSession("s-1")
        let model = makeModel(machine)
        model.start()
        defer { model.remote.quit() }
        model.remote.add("build-server")
        #expect(await waitUntil { model.remote.rows.first?.vitals?.socket == true })

        let answer = Text()
        try machine.runHook(["--permission", "60"], input: #"{"hook_event_name":"PermissionRequest","session_id":"s-1","cwd":"/srv/app","tool_name":"Bash","tool_input":{"command":"npm test"}}"#) { answer.set($0) }
        #expect(await waitUntil { !model.hooks.pending.isEmpty })
        let request = try #require(model.hooks.pending.first)
        #expect(request.host == "build-server")
        #expect(request.session == "s-1")
        #expect(await waitUntil { model.work.waitingSessions.contains { $0.id == "s-1" } })
        // Where it asks from is on the card, from the session it belongs to.
        #expect(model.hooks.queue.session("s-1")?.environment == .remote(host: "build-server"))

        // Past the guard against a press meant for the card before.
        model.hooks.answer(request.id, .allow, via: .window, now: Date().addingTimeInterval(HookController.settleTime + 1))
        #expect(await waitUntil { answer.value != nil })
        #expect(answer.value?.contains("\"allow\"") == true)
        #expect(model.hooks.pending.isEmpty)
        #expect(model.hooks.queue.decisions.last?.outcome == .allowed)
        #expect(model.hooks.queue.decisions.last?.environment == "build-server")
        #expect(await waitUntil { !model.work.waitingSessions.contains { $0.id == "s-1" } })
        #expect(model.remote.events(session: "s-1").contains { $0.kind == .answered })
    }

    @Test("Обновление хуков этого Mac не закрывает запросы с машины") func localHooksDoNotCloseRemoteRequests() async throws {
        let machine = Machine()
        let model = makeModel(machine)
        model.start()
        defer { model.remote.quit() }
        model.remote.add("build-server")
        #expect(await waitUntil { model.remote.rows.first?.vitals?.socket == true })

        let answer = Text()
        try machine.runHook(["--permission", "60"], input: #"{"hook_event_name":"PermissionRequest","session_id":"s-1","tool_name":"Bash","tool_input":{"command":"ls"}}"#) { answer.set($0) }
        #expect(await waitUntil { !model.hooks.pending.isEmpty })
        // This runs twice a minute on a Mac without hooks of its own.
        model.hooks.stopServer()
        #expect(model.hooks.pending.count == 1)
        #expect(model.hooks.queue.expired.isEmpty)
        model.hooks.deny(try #require(model.hooks.pending.first).id, via: .window)
        #expect(await waitUntil { answer.value != nil })
        #expect(answer.value?.contains("\"deny\"") == true)
    }

    @Test("Живое событие с машины не считается событием хуков этого Mac") func signalsDoNotCountAsLocalHooks() async throws {
        let machine = Machine()
        try machine.listSession("s-1")
        let model = makeModel(machine)
        model.start()
        defer { model.remote.quit() }
        model.remote.add("build-server")
        #expect(await waitUntil { model.remote.rows.first?.vitals?.socket == true })
        #expect(await waitUntil { model.work.sessions.contains { $0.id == "s-1" } })

        let done = Text()
        try machine.runHook([], input: #"{"hook_event_name":"PreToolUse","session_id":"s-1","tool_name":"Bash","tool_input":{"command":"SECRET"}}"#) { done.set($0) }
        #expect(await waitUntil { model.remote.events(session: "s-1").contains { $0.kind == .tool("Bash") } })
        #expect(await waitUntil { model.work.sessions.first { $0.id == "s-1" }?.root.step?.tool == "Bash" })
        #expect(model.hookState.lastEventAt == nil)
        #expect(model.connectionStatus.lastHookEvent == nil)
    }

    @Test("Обрыв отмечается как «нет связи» и проходит сам") func dropIsShownAndHeals() async throws {
        let machine = Machine()
        try machine.listSession("s-1")
        let model = makeModel(machine)
        model.start()
        defer { model.remote.quit() }
        model.remote.add("build-server")
        #expect(await waitUntil { model.work.sessions.first?.state == .running })

        machine.refuse("ssh: connect to host x port 22: Connection refused")
        machine.drop()
        #expect(await waitUntil { model.work.sessions.first?.state == .unreachable })
        #expect(model.remote.rows.first?.failure != nil)
        #expect(model.remote.summary == RemoteSummary(machines: 1, connected: 0, failures: [model.remote.rows.first?.failure ?? .dropped]))
        #expect(!model.work.isWorking)
        // A machine out of reach does not make Boris look broken.
        #expect(!model.connectionStatus.isBroken)
        #expect(model.allSessions.contains { $0.id == "s-1" && $0.state == .unreachable })

        machine.allow()
        machine.stopRefusing()
        #expect(await waitUntil { model.work.sessions.first?.state == .running })
        #expect(model.remote.rows.first?.isUp == true)
    }

    @Test("Подключение хуков: сначала строки, потом запись, потом обратно") func hooksFlow() async throws {
        let machine = Machine()
        let model = makeModel(machine)
        model.start()
        defer { model.remote.quit() }
        model.remote.add("build-server")
        #expect(await waitUntil { model.remote.rows.first?.hooks == .notInstalled })
        let id = try #require(model.remote.rows.first?.id)
        let settings = machine.claude.appendingPathComponent("settings.json")

        model.remote.askHooks(id)
        #expect(await waitUntil { model.remote.rows.first?.preview != nil })
        #expect(model.remote.rows.first?.preview?.lines.contains { $0.contains("boris-hook") } == true)
        #expect(!FileManager.default.fileExists(atPath: settings.path))

        model.remote.cancelHooks(id)
        #expect(model.remote.rows.first?.preview == nil)
        #expect(!FileManager.default.fileExists(atPath: settings.path))

        model.remote.confirmHooks(id)
        #expect(await waitUntil { model.remote.rows.first?.hooks == .installed })
        #expect(FileManager.default.fileExists(atPath: settings.path))
        #expect(model.remote.rows.first?.machine.hooksWanted == true)
        // The wait on the machine is the same limit as on this Mac.
        #expect(try String(contentsOf: settings, encoding: .utf8).contains("--permission \(HookController.hookLimit)"))
        #expect(model.remote.hooksConnected(host: "build-server"))
        #expect(RemoteStore(folder: machine.support).machines().first?.hooksWanted == true)

        // Another program took them away: that is noticed, and a repair needs no second agreement.
        try "{}".write(to: settings, atomically: true, encoding: .utf8)
        #expect(await waitUntil { model.remote.rows.first?.hooksDamaged == true })
        model.remote.confirmHooks(id)
        #expect(await waitUntil { model.remote.rows.first?.hooksDamaged == false })

        model.remote.disconnectHooks(id)
        #expect(await waitUntil { model.remote.rows.first?.machine.hooksWanted == false })
        #expect(try String(contentsOf: settings, encoding: .utf8).contains("boris-hook") == false)
    }

    @Test("Без согласия настройки Claude на машине не меняются") func nothingWithoutConsent() async throws {
        let machine = Machine()
        let settings = machine.claude.appendingPathComponent("settings.json")
        let model = makeModel(machine)
        model.start()
        defer { model.remote.quit() }
        model.remote.add("build-server")
        #expect(await waitUntil { model.remote.rows.first?.isUp == true })
        try await Task.sleep(for: .milliseconds(300))
        #expect(!FileManager.default.fileExists(atPath: settings.path))
    }

    @Test("Машину можно убрать: уходят с неё хуки и помощник, а отсюда её числа") func removal() async throws {
        let machine = Machine()
        try machine.writeSpend(session: "s-1", input: 50)
        let model = makeModel(machine)
        model.start()
        defer { model.remote.quit() }
        model.remote.add("build-server")
        #expect(await waitUntil { model.remote.rows.first?.hooks == .notInstalled })
        let id = try #require(model.remote.rows.first?.id)
        model.remote.confirmHooks(id)
        #expect(await waitUntil { model.remote.rows.first?.hooks == .installed })
        #expect(await waitUntil { model.usage.book?.spent(session: "s-1")?.input == 50 })

        model.remote.remove(id)
        #expect(model.remote.rows.isEmpty)
        #expect(await waitUntil { !FileManager.default.fileExists(atPath: machine.boris.path) })
        #expect(await waitUntil { model.usage.book?.spent(session: "s-1") == nil })
        #expect(model.remote.leftBehind == nil)
        #expect(RemoteStore(folder: machine.support).machines().isEmpty)
    }

    @Test("Машина недоступна при удалении: сказано, что её хуки остались") func removalOutOfReach() async throws {
        let machine = Machine()
        let model = makeModel(machine)
        model.start()
        defer { model.remote.quit() }
        model.remote.add("build-server")
        #expect(await waitUntil { model.remote.rows.first?.isUp == true })
        machine.refuse("ssh: connect to host x port 22: Connection refused")
        let id = try #require(model.remote.rows.first?.id)
        model.remote.remove(id)
        #expect(await waitUntil { model.remote.leftBehind == "build-server" })
        model.remote.dismissLeftBehind()
        #expect(model.remote.leftBehind == nil)
    }

    @Test("Список машин и числа переживают перезапуск, а связи при старте возвращаются") func survivesRestart() async throws {
        let machine = Machine()
        try machine.writeSpend(session: "s-1", input: 77)
        do {
            let model = makeModel(machine)
            model.start()
            model.remote.add("build-server")
            #expect(await waitUntil { model.usage.book?.spent(session: "s-1")?.input == 77 })
            model.remote.quit()
            // Writing is off the main thread.
            let store = RemoteStore(folder: machine.support)
            let id = try #require(store.machines().first?.id)
            #expect(await waitUntil { store.rows(of: id).first?.usage.input == 77 })
        }

        // The machine is out of reach on the next launch, and what it spent is still known.
        machine.refuse("ssh: connect to host x port 22: Connection refused")
        let store = RemoteStore(folder: machine.support)
        let hooks = HookController(settings: AppSettings(defaults: nil), live: false)
        let hub = RemoteHub(hooks: hooks, store: store, tool: machine.tool)
        hub.loadNumbers()
        #expect(hub.rows.map(\.machine.name) == ["build-server"])
        #expect(hub.pastSessions.first?.root.tokens?.input == 77)
        #expect(hub.pastSessions.first?.environment == .remote(host: "build-server"))
        hub.start()
        defer { hub.quit() }
        #expect(await waitUntil { hub.rows.first?.failure == .unreachable })
    }

    @Test("Имя с опцией вместо машины не запускает ssh") func badNameRunsNothing() {
        let machine = Machine()
        let model = makeModel(machine)
        #expect(model.remote.add("-oProxyCommand=evil") == .invalidName)
        #expect(model.remote.rows.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: machine.control.appendingPathComponent("calls").path))
        #expect(model.remote.add("  build-server  ") == .added)
        #expect(model.remote.add("build-server") == .alreadyThere)
        model.remote.quit()
    }

    @Test("Срок ожидания на машине равен сроку на Mac, и в проверке пустое окружение") func snapshotModelConnectsToNothing() {
        // A model made for a snapshot has no ssh to call, whatever is added to it.
        let settings = AppSettings(defaults: nil)
        let model = AppModel(settings: settings, store: nil, live: false)
        #expect(model.remote.add("build-server") == .added)
        #expect(model.remote.rows.first?.state == .stopped)
        model.remote.quit()
    }
}
