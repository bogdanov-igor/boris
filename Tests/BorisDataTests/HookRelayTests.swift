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
        #expect(server.start())
        return (server, received)
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 {
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
        server.answer(request.id, allow: allow)

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
}
