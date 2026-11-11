import BorisCore
import Foundation
import Testing
@testable import BorisData

/// The promise of the helper: numbers of spend leave the machine, the text of a conversation does not.
@Suite("Помощник: наружу только числа")
struct RemoteHelperPrivacyTests {
    /// Words that stand for what must never leave. Each sits in a place Claude really writes to.
    private static let secrets = [
        "SECRETprompt", "SECRETanswer", "SECRETthinking", "SECRETcommand", "SECRETresult", "SECRETsummary", "SECRETtitle",
        "SECRETfile", "SECRETname", "SECRETapprove", "SECRETkey", "SECRETmodel", "SECRETtool", "SECRETpath", "SECRETversion", "SECRETstatus",
    ]

    /// A transcript with the conversation in every place it can be.
    private func writeConversation(_ machine: FakeMachine) {
        let lines = [
            #"{"type":"user","timestamp":"2026-11-05T12:00:00.000Z","cwd":"/srv/app","message":{"role":"user","content":"SECRETprompt"},"usage":"none","note":"assistant"}"#,
            #"{"type":"assistant","timestamp":"2026-11-05T12:01:00.000Z","cwd":"/srv/app","message":{"id":"m1","model":"claude-sonnet-5-5","content":[{"type":"thinking","thinking":"SECRETthinking"},{"type":"text","text":"SECRETanswer"},{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"SECRETcommand","file_path":"/x/SECRETfile"}}],"usage":{"input_tokens":100,"output_tokens":20,"cache_read_input_tokens":3,"cache_creation_input_tokens":4}}}"#,
            #"{"type":"user","timestamp":"2026-11-05T12:02:00.000Z","cwd":"/srv/app","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"SECRETresult"}]},"toolUseResult":{"stdout":"SECRETresult"},"usage":{"input_tokens":1},"role":"assistant"}"#,
            #"{"type":"summary","summary":"SECRETsummary","leafUuid":"x","usage":{},"assistant":true}"#,
            #"{"type":"ai-title","title":"SECRETtitle","usage":{},"role":"assistant"}"#,
            // Text where a word of a known kind should be: the helper only passes what looks like what it should.
            #"{"type":"assistant","timestamp":"2026-11-05T12:03:00.000Z","cwd":"relative SECRETpath","message":{"id":"m2","model":"a model with SECRETmodel in it","content":[],"usage":{"input_tokens":7,"output_tokens":1}}}"#,
        ]
        machine.writeClaudeFile("projects/-srv-app/s-1.jsonl", lines.joined(separator: "\n") + "\n")
        machine.writeClaudeFile("projects/-srv-app/s-1/subagents/agent-a1.jsonl", FakeMachine.assistantLine(id: "m3", text: "SECRETanswer"))
        let pid = ProcessInfo.processInfo.processIdentifier
        machine.writeClaudeFile("sessions/\(pid).json", #"{"pid":\#(pid),"sessionId":"s-1","cwd":"/srv/app","status":"waiting","waitingFor":"approve Bash: rm -rf SECRETapprove","name":"SECRETname","title":"SECRETtitle","version":"bad version SECRETversion","startedAt":1762400000000,"statusUpdatedAt":1762400100000}"#)
        machine.writeClaudeFile("sessions/\(pid).key", "SECRETkey")
    }

    private func assertClean(_ text: String) {
        #expect(!text.isEmpty)
        for secret in Self.secrets { #expect(!text.contains(secret), "В вывод попало: \(secret)") }
    }

    @Test("Числа и список сессий не содержат ни слова из переписки") func numbersCarryNoText() throws {
        let machine = FakeMachine()
        writeConversation(machine)
        let numbers = try machine.helper(["numbers"])
        #expect(numbers.status == 0)
        assertClean(numbers.text)
        // The test proves something only if spend really came through.
        guard case .numbers(_, let rows)? = RemoteMessage(line: numbers.data) else {
            Issue.record("Нет чисел в выводе")
            return
        }
        let total = rows.reduce(0) { $0 + $1.usage.total }
        #expect(total == 262)

        let sessions = try machine.helper(["sessions"])
        assertClean(sessions.text)
        guard case .sessions(let reports)? = RemoteMessage(line: sessions.data) else {
            Issue.record("Нет списка сессий")
            return
        }
        #expect(reports.map(\.id) == ["s-1"])
        // What is being approved is cut off at the tool, and the tool is all the Mac needs.
        #expect(reports.first?.waitingFor == "approve Bash")
    }

    /// Whatever the helper says, in its long-running form as well: only these fields, and only what they should hold.
    @Test("В потоке наблюдения только разрешённые поля") func watchCarriesOnlyAllowedFields() async throws {
        let machine = FakeMachine()
        writeConversation(machine)
        machine.installHelper()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", machine.boris.appendingPathComponent("boris-hook").path, "watch"]
        process.environment = ["HOME": machine.home.path, "PATH": "/usr/bin:/bin", "BORIS_REMOTE_TICK": "0.02"]
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let received = Collected()
        // At the end of the output it is called again and again with nothing, so it lets go then.
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { received.add(data) }
        }
        try process.run()
        defer { if process.isRunning { process.terminate() } }

        // Something changes while it watches, so a line of new numbers goes through as well.
        #expect(await arrives { received.text.contains("\"numbers\"") })
        machine.appendClaudeFile("projects/-srv-app/s-1.jsonl", FakeMachine.assistantLine(id: "m9", input: 5, text: "SECRETanswer"))
        #expect(await arrives { received.text.components(separatedBy: "\"numbers\"").count > 2 })
        process.terminate()
        waitUntilGone(process)
        output.fileHandleForReading.readabilityHandler = nil

        let allowedFields: [String: Set<String>] = [
            "hello": ["k"],
            "alive": ["k", "socket", "claude", "hooks"],
            "sessions": ["k", "list"],
            "numbers": ["k", "full", "rows"],
        ]
        let lines = received.text.split(separator: "\n").map(String.init)
        // The last line may have been cut off by stopping it.
        for line in lines.dropLast() {
            let object = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            let kind = try #require(object["k"] as? String)
            #expect(Set(object.keys).isSubset(of: allowedFields[kind] ?? []), "Лишние поля в \(kind)")
            for session in object["list"] as? [[String: Any]] ?? [] {
                #expect(Set(session.keys).isSubset(of: ["id", "status", "waiting", "cwd", "version", "started", "updated", "gone"]))
            }
            for row in object["rows"] as? [[Any]] ?? [] {
                #expect(row.count == 10)
                #expect(row[6...].allSatisfy { $0 is NSNumber })
            }
        }
        assertClean(received.text)
        // Its memory on the machine holds numbers and ids as well, so the next connection does not read everything again.
        let cache = try String(contentsOf: machine.boris.appendingPathComponent("numbers.json"), encoding: .utf8)
        assertClean(cache)
        let permissions = try FileManager.default.attributesOfItem(atPath: machine.boris.appendingPathComponent("numbers.json").path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }

    @Test("Файлы с ключами рядом с сессиями не открываются") func keyFilesStayClosed() throws {
        let machine = FakeMachine()
        machine.listSession("s-1")
        let pid = ProcessInfo.processInfo.processIdentifier
        let key = machine.writeClaudeFile("sessions/\(pid).key", "SECRETkey")
        // Unreadable, so that opening it would show as an error, and a session next to it still comes through.
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: key.path)
        let sessions = try machine.helper(["sessions"])
        #expect(sessions.text.contains("s-1"))
        #expect(!sessions.text.contains("SECRETkey"))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: key.path)
    }

    /// Runs the helper as a hook and reads what it would send to the Mac.
    private func sent(by machine: FakeMachine, event: String) async throws -> String {
        let path = machine.boris.appendingPathComponent("hook.sock").path
        machine.installHelper()
        let listener = SocketListener(path: path)
        defer { listener.close() }
        _ = try machine.helper([], input: event)
        return await listener.nextLine()
    }

    @Test("Событие хука уносит только служебные поля") func hookEventsCarryNoText() async throws {
        let machine = FakeMachine()
        let event = #"{"hook_event_name":"PostToolUse","session_id":"s-1","cwd":"/srv/app","tool_name":"Bash","tool_input":{"command":"SECRETcommand"},"tool_response":{"stdout":"SECRETresult"},"prompt":"SECRETprompt","last_assistant_message":"SECRETanswer","transcript_path":"/x/SECRETfile"}"#
        let line = try await sent(by: machine, event: event)
        assertClean(line)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(object["session_id"] as? String == "s-1")
        #expect(object["tool_name"] as? String == "Bash")
        #expect(object["input_digest"] is String)
    }

    @Test("Запрос уносит то, на что надо ответить, но не переписку") func requestsCarryOnlyTheirOwnInput() async throws {
        let machine = FakeMachine()
        let event = #"{"hook_event_name":"PermissionRequest","session_id":"s-1","tool_name":"Bash","tool_input":{"command":"npm test"},"prompt":"SECRETprompt","last_assistant_message":"SECRETanswer"}"#
        let listener = SocketListener(path: machine.boris.appendingPathComponent("hook.sock").path, answer: #"{"behavior":"deny","reason":"no"}"#)
        defer { listener.close() }
        machine.installHelper()
        let result = try machine.helper(["--permission", "30"], input: event)
        let line = await listener.nextLine()
        assertClean(line)
        #expect(line.contains("npm test"))
        #expect(result.text.contains("\"deny\""))
    }

    @Test("Подсчёт на машине совпадает с подсчётом на Mac") func countsLikeTheMac() async throws {
        let machine = FakeMachine()
        // Grows while it streams, repeats in a fork, a synthetic message, one with no id, and one with no fractional seconds.
        var main = FakeMachine.assistantLine(id: "m1", input: 100, output: 1)
        main += FakeMachine.assistantLine(id: "m1", input: 100, output: 30)
        main += FakeMachine.assistantLine(id: "m2", input: 5, output: 5, model: "<synthetic>")
        main += #"{"type":"assistant","timestamp":"2026-11-05T23:50:00.000Z","cwd":"/srv/app","message":{"model":"claude-opus-5-5","usage":{"input_tokens":9,"output_tokens":2}}}"# + "\n"
        main += #"{"type":"assistant","timestamp":"2026-11-06T00:10:00Z","cwd":"/srv/app","message":{"id":"m3","model":"claude-opus-5-5","usage":{"input_tokens":11}}}"# + "\n"
        machine.writeClaudeFile("projects/-srv-app/s-1.jsonl", main)
        machine.writeClaudeFile("projects/-srv-app/s-1/subagents/agent-a1.jsonl", FakeMachine.assistantLine(id: "m1", input: 100, output: 30) + FakeMachine.assistantLine(id: "m4", input: 40, output: 8))
        machine.writeClaudeFile("projects/-srv-app/s-1/subagents/workflows/wf_1/agent-a2.jsonl", FakeMachine.assistantLine(id: "m5", input: 70, output: 6, model: "claude-haiku-5-5"))
        machine.writeClaudeFile("projects/-other/s-2.jsonl", FakeMachine.assistantLine(id: "m6", input: 1000, output: 100, cwd: "/srv/other/.claude/worktrees/copy", timestamp: "2026-11-04T01:00:00.000Z"))
        machine.writeClaudeFile("projects/-other/not-a-transcript.txt", "SECRETprompt")

        let index = TokenIndex(cacheFile: nil, timeZone: TimeZone(identifier: "Asia/Kolkata") ?? .gmt)
        await index.update(roots: [ClaudePaths(root: machine.claude)])
        let onTheMac = await index.records()

        let output = try machine.helper(["numbers"])
        guard case .numbers(_, let rows)? = RemoteMessage(line: output.data) else {
            Issue.record("Нет чисел в выводе")
            return
        }
        // An offset of half an hour is what a quarter of an hour in the rows exists for.
        let fromTheMachine = RemoteBook(host: "m", rows: rows).records(timeZone: TimeZone(identifier: "Asia/Kolkata") ?? .gmt)

        func key(_ record: TokenRecord) -> String {
            "\(record.sessionId)|\(record.agentId ?? "-")|\(record.runId ?? "-")|\(record.day)|\(record.model ?? "-")|\(record.cwd ?? "-")"
        }
        let expected = Dictionary(onTheMac.filter { $0.usage.total > 0 }.map { (key($0), $0.usage) }) { first, _ in first }
        let actual = Dictionary(fromTheMachine.filter { $0.usage.total > 0 }.map { (key($0), $0.usage) }) { first, _ in first }
        #expect(!expected.isEmpty)
        #expect(actual == expected)
    }

    @Test("Подсчёт совпадает и на настоящем наборе файлов из тестов") func countsLikeTheMacOnFixtures() async throws {
        let machine = FakeMachine()
        let fixtures = Fixtures.root.appendingPathComponent("world")
        try FileManager.default.removeItem(at: machine.claude)
        try FileManager.default.copyItem(at: fixtures, to: machine.claude)

        let index = TokenIndex(cacheFile: nil, timeZone: .gmt)
        await index.update(roots: [ClaudePaths(root: machine.claude)])
        let onTheMac = await index.records().map(\.usage).reduce(TokenUsage(), +)

        let output = try machine.helper(["numbers"])
        guard case .numbers(_, let rows)? = RemoteMessage(line: output.data) else {
            Issue.record("Нет чисел в выводе")
            return
        }
        #expect(rows.map(\.usage).reduce(TokenUsage(), +) == onTheMac)
    }

    @Test("Обрыв и новая запись читаются с места остановки, а удалённый лог уходит из сумм") func readsOnlyWhatWasAdded() async throws {
        let machine = FakeMachine()
        machine.writeClaudeFile("projects/-srv-app/s-1.jsonl", FakeMachine.assistantLine(id: "m1", input: 100, output: 0, cacheRead: 0, cacheWrite: 0))
        machine.writeClaudeFile("projects/-srv-app/s-2.jsonl", FakeMachine.assistantLine(id: "m2", input: 10, output: 0, cacheRead: 0, cacheWrite: 0))
        machine.installHelper()
        let received = Collected()
        let process = try startWatch(machine, into: received)
        defer { if process.isRunning { process.terminate() } }
        #expect(await arrives { received.lines(ofKind: "numbers").count >= 1 })

        machine.appendClaudeFile("projects/-srv-app/s-1.jsonl", FakeMachine.assistantLine(id: "m3", input: 7, output: 0, cacheRead: 0, cacheWrite: 0))
        #expect(await arrives { received.lines(ofKind: "numbers").count >= 2 })
        let added = try #require(received.lines(ofKind: "numbers").last.flatMap { RemoteMessage(line: Data($0.utf8)) })
        guard case .numbers(let full, let rows) = added else {
            Issue.record("Нет чисел в строке")
            return
        }
        #expect(!full)
        #expect(rows.count == 1)
        #expect(rows.first?.usage.input == 107)

        try FileManager.default.removeItem(at: machine.claude.appendingPathComponent("projects/-srv-app/s-2.jsonl"))
        #expect(await arrives { received.lines(ofKind: "numbers").count >= 3 })
        let after = try #require(received.lines(ofKind: "numbers").last.flatMap { RemoteMessage(line: Data($0.utf8)) })
        guard case .numbers(let wasFull, let left) = after else {
            Issue.record("Нет чисел в строке")
            return
        }
        #expect(wasFull)
        #expect(Set(left.map(\.session)) == ["s-1"])
    }

    private func startWatch(_ machine: FakeMachine, into received: Collected) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", machine.boris.appendingPathComponent("boris-hook").path, "watch"]
        process.environment = ["HOME": machine.home.path, "PATH": "/usr/bin:/bin", "BORIS_REMOTE_TICK": "0.02"]
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        // At the end of the output it is called again and again with nothing, so it lets go then.
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { received.add(data) }
        }
        try process.run()
        return process
    }
}

/// Output of a process, as it comes.
final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func add(_ more: Data) {
        lock.lock()
        data.append(more)
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }

    /// Complete lines of one kind of message.
    func lines(ofKind kind: String) -> [String] {
        let all = text
        guard let end = all.lastIndex(of: "\n") else { return [] }
        return all[..<end].split(separator: "\n").map(String.init).filter { $0.contains("\"k\":\"\(kind)\"") }
    }
}

/// A socket where the Mac would be: it takes one line at a time, and can answer it.
final class SocketListener: @unchecked Sendable {
    private let fd: Int32
    private let path: String
    private let lock = NSLock()
    private var lines: [String] = []
    private let answer: String?

    init(path: String, answer: String? = nil) {
        self.path = path
        self.answer = answer
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        unlink(path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        _ = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        listen(fd, 8)
        let listener = fd
        Thread.detachNewThread { [weak self] in
            while true {
                let client = accept(listener, nil, nil)
                guard client >= 0 else { return }
                var noSignal: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 16 * 1024)
                while !data.contains(0x0A) {
                    let count = read(client, &buffer, buffer.count)
                    guard count > 0 else { break }
                    data.append(contentsOf: buffer[0..<count])
                }
                self?.received(String(decoding: data, as: UTF8.self), client: client)
            }
        }
    }

    private func received(_ line: String, client: Int32) {
        lock.lock()
        lines.append(line)
        lock.unlock()
        if let answer {
            let bytes = Array((answer + "\n").utf8)
            _ = write(client, bytes, bytes.count)
        }
        Darwin.close(client)
    }

    private func take() -> String? {
        lock.withLock { lines.isEmpty ? nil : lines.removeFirst() }
    }

    func nextLine() async -> String {
        let end = Date().addingTimeInterval(40)
        while Date() < end {
            if let line = take() { return line }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return ""
    }

    func close() {
        shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
        unlink(path)
    }
}
