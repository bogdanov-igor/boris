import BorisCore
import Darwin
import Foundation
import Testing
@testable import BorisData

/// Runs the real `boris-hook`, as Claude would, in each source's environment.
@Suite("Посредник и источники", .serialized)
struct HookSourceTests {
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

    /// A short folder of its own, for the socket and the file next to it.
    private final class Place {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("b\(UUID().uuidString.prefix(8))")
        var socket: String { folder.appendingPathComponent("h.sock").path }

        init() {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: folder) }

        func forbid(silent: Set<SourceID> = [], noAnswers: Set<SourceID> = []) throws {
            try HookPolicy(silent: silent, noAnswers: noAnswers).save(to: folder.appendingPathComponent(HookPolicy.fileName))
        }
    }

    private final class Heard: @unchecked Sendable {
        private let lock = NSLock()
        private var signalList: [HookSignal] = []
        private var requestList: [PendingPermission] = []

        func add(_ signal: HookSignal) {
            lock.lock()
            signalList.append(signal)
            lock.unlock()
        }

        func add(_ request: PendingPermission) {
            lock.lock()
            requestList.append(request)
            lock.unlock()
        }

        var signals: [HookSignal] {
            lock.lock()
            defer { lock.unlock() }
            return signalList
        }

        var requests: [PendingPermission] {
            lock.lock()
            defer { lock.unlock() }
            return requestList
        }
    }

    private func server(_ place: Place) throws -> (HookServer, Heard) {
        let server = HookServer(path: place.socket)
        let heard = Heard()
        server.onSignal = { heard.add($0) }
        server.onPermission = { heard.add($0) }
        #expect(server.start())
        return (server, heard)
    }

    private func run(_ place: Place, entrypoint: String?, wait: Int? = nil, input: String) throws -> Result {
        let process = Process()
        process.executableURL = try #require(Self.binary, "boris-hook не собран")
        process.arguments = wait.map { ["--permission", "\($0)"] } ?? []
        var environment = ["BORIS_HOOK_SOCKET": place.socket, "HOME": NSHomeDirectory()]
        if let entrypoint { environment["CLAUDE_CODE_ENTRYPOINT"] = entrypoint }
        process.environment = environment
        return try run(process, input: input)
    }

    private func run(_ process: Process, input: String) throws -> Result {
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

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<400 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    private let permission = #"{"hook_event_name":"PermissionRequest","session_id":"s1","tool_name":"Bash","cwd":"/x/proj","tool_input":{"command":"npm run migrate"}}"#
    private let toolEvent = #"{"hook_event_name":"PreToolUse","session_id":"s1","tool_name":"Bash","tool_input":{"command":"secret"}}"#

    /// A limit far above what any of these should take.
    private let promptly: TimeInterval = 2

    @Test("Ответы выключены: посредник сразу уходит без решения, а Boris узнаёт, что сессия ждёт")
    func answersOff() async throws {
        let place = Place()
        try place.forbid(noAnswers: [.vsCode])
        let (server, heard) = try server(place)
        defer { server.stop() }
        let result = try run(place, entrypoint: "claude-vscode", wait: 30, input: permission)
        #expect(result.status == 0)
        #expect(result.output.isEmpty, "никакого решения, запрос остаётся в Claude")
        #expect(result.seconds < promptly, "Claude не ждёт: \(result.seconds) с")
        #expect(await eventually { heard.signals == [.permissionAsked(session: "s1", tool: "Bash")] })
        #expect(heard.requests.isEmpty, "карточки в Boris нет")
        print("boris-hook with answers off left in \(Int(result.seconds * 1000)) ms")
    }

    @Test("Ответы выключены: текст запроса не покидает посредника")
    func answersOffCarriesNoText() throws {
        let reduced = HookPayload.reduce(try #require(try JSONSerialization.jsonObject(with: Data(permission.utf8)) as? [String: Any]), withRequest: false)
        #expect(reduced["command_text"] == nil)
        #expect(reduced["tool_input"] == nil)
        #expect(reduced["tool_name"] as? String == "Bash")
    }

    @Test("Считывание выключено: ничего не отправляется, ни запрос, ни события")
    func readingOff() async throws {
        let place = Place()
        try place.forbid(silent: [.cursor, .vsCode])
        let (server, heard) = try server(place)
        defer { server.stop() }
        for (wait, input) in [(Optional(30), permission), (nil, toolEvent)] {
            let result = try run(place, entrypoint: "claude-vscode", wait: wait, input: input)
            #expect(result.status == 0)
            #expect(result.output.isEmpty)
            #expect(result.seconds < promptly)
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(heard.signals.isEmpty)
        #expect(heard.requests.isEmpty)
    }

    @Test("Другой источник работает как прежде: запрос ждёт и получает ответ")
    func otherSourceStillAsks() async throws {
        let place = Place()
        try place.forbid(silent: [.cursor], noAnswers: [.vsCode])
        let (server, heard) = try server(place)
        defer { server.stop() }
        let test = self
        let task = Task.detached { try test.run(place, entrypoint: "cli", wait: 20, input: test.permission) }
        #expect(await eventually { !heard.requests.isEmpty })
        let request = try #require(heard.requests.first)
        #expect(request.source == .terminal)
        #expect(request.command == "npm run migrate")
        server.answer(request.id, .allow)
        let result = try await task.value
        #expect(result.output.contains("allow"))
    }

    @Test("Без файла настроек посредник работает как раньше")
    func noPolicyFile() async throws {
        let place = Place()
        let (server, heard) = try server(place)
        defer { server.stop() }
        _ = try run(place, entrypoint: "claude-vscode", input: toolEvent)
        #expect(await eventually { heard.signals == [.toolStarted(session: "s1", agent: nil, tool: "Bash")] })
    }

    @Test("Claude не назвал себя: источник находится по началу журнала")
    func entrypointFromTranscript() async throws {
        let place = Place()
        try place.forbid(noAnswers: [.terminal])
        let (server, heard) = try server(place)
        defer { server.stop() }
        let transcript = place.folder.appendingPathComponent("t.jsonl")
        try Data((#"{"type":"user","entrypoint":"cli","message":{}}"# + "\n").utf8).write(to: transcript)
        let input = #"{"hook_event_name":"PermissionRequest","session_id":"s1","tool_name":"Bash","transcript_path":"\#(transcript.path)","tool_input":{"command":"x"}}"#
        let result = try run(place, entrypoint: nil, wait: 30, input: input)
        #expect(result.seconds < promptly)
        #expect(result.output.isEmpty)
        #expect(heard.requests.isEmpty)
    }

    @Test("Посредник не знает источника, а приложение знает: оно отпускает его сразу, без решения")
    func appTurnsAway() async throws {
        let place = Place()
        let (server, heard) = try server(place)
        defer { server.stop() }
        server.admission = { session, _ in session == "s1" ? .noAnswers : .welcome }
        let result = try run(place, entrypoint: nil, wait: 30, input: permission)
        #expect(result.status == 0)
        #expect(result.output.isEmpty)
        #expect(result.seconds < promptly)
        #expect(heard.requests.isEmpty)
        #expect(await eventually { heard.signals == [.permissionAsked(session: "s1", tool: "Bash")] })
    }

    @Test("Приложение знает, что считывание выключено: события не слышны вообще")
    func appIgnores() async throws {
        let place = Place()
        let (server, heard) = try server(place)
        defer { server.stop() }
        server.admission = { _, _ in .ignore }
        let asked = try run(place, entrypoint: nil, wait: 30, input: permission)
        #expect(asked.seconds < promptly)
        #expect(asked.output.isEmpty)
        _ = try run(place, entrypoint: nil, input: toolEvent)
        try await Task.sleep(for: .milliseconds(300))
        #expect(heard.signals.isEmpty)
        #expect(heard.requests.isEmpty)
    }

    /// Runs a copy of the hook inside a made-up app, so that the line of processes says that app.
    private func runInside(_ app: String, place: Place, input: String) throws -> Result {
        let binary = place.folder.appendingPathComponent("\(app)/Contents/MacOS/boris-hook")
        if !FileManager.default.fileExists(atPath: binary.path) {
            try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: try #require(Self.binary), to: binary)
            // The system looks a new executable over the first time, and that is no part of what the hook costs.
            let first = Process()
            first.executableURL = binary
            first.environment = ["BORIS_HOOK_SOCKET": place.folder.appendingPathComponent("nothing").path]
            try first.run()
            first.waitUntilExit()
        }
        let process = Process()
        process.executableURL = binary
        process.arguments = ["--permission", "20"]
        process.environment = ["BORIS_HOOK_SOCKET": place.socket, "HOME": NSHomeDirectory(), "CLAUDE_CODE_ENTRYPOINT": "claude-vscode"]
        return try run(process, input: input)
    }

    @Test("Одно и то же слово, два редактора: посредник сам видит, что он в Cursor")
    func cursorAndVSCodeInTheHook() async throws {
        let place = Place()
        try place.forbid(noAnswers: [.cursor])
        let (server, heard) = try server(place)
        defer { server.stop() }

        let inCursor = try runInside("Cursor.app", place: place, input: permission)
        #expect(inCursor.seconds < promptly, "в Cursor ответы выключены, и Claude не ждёт")
        #expect(inCursor.output.isEmpty)
        #expect(heard.requests.isEmpty)

        let test = self
        let task = Task.detached { try test.runInside("Visual Studio Code.app", place: place, input: test.permission) }
        #expect(await eventually { !heard.requests.isEmpty }, "в VS Code ответы включены, и запрос ждёт")
        let request = try #require(heard.requests.first)
        #expect(request.source == .vsCode)
        server.answer(request.id, .allow)
        #expect(try await task.value.output.contains("allow"))
    }

    @Test("Команда из настроек Claude тоже уходит сразу")
    func installedCommand() throws {
        let place = Place()
        try place.forbid(noAnswers: [.terminal])
        let (server, _) = try server(place)
        defer { server.stop() }
        let plan = HookInstaller.Plan(helperPath: try #require(Self.binary).path, permissions: true, permissionWait: 600)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", HookInstaller.command(plan, permission: true)]
        process.environment = ["BORIS_HOOK_SOCKET": place.socket, "HOME": NSHomeDirectory(), "CLAUDE_CODE_ENTRYPOINT": "cli"]
        let result = try run(process, input: permission)
        #expect(result.status == 0)
        #expect(result.output.isEmpty)
        #expect(result.seconds < promptly)
    }
}
