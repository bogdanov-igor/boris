import BorisCore
import Foundation
import Testing
@testable import BorisData

/// Keeps what the engine reports, for a test to wait on.
private final class Outputs: @unchecked Sendable {
    private let lock = NSLock()
    private var last: WorkEngine.Output?

    func add(_ output: WorkEngine.Output) {
        lock.lock()
        last = output
        lock.unlock()
    }

    var latest: WorkEngine.Output? {
        lock.lock()
        defer { lock.unlock() }
        return last
    }

    /// Waits for a condition and returns how long it took, or nil when it never came.
    func wait(timeout: TimeInterval, until condition: (WorkEngine.Output) -> Bool) async -> TimeInterval? {
        let began = Date()
        while Date().timeIntervalSince(began) < timeout {
            if let latest, condition(latest) { return Date().timeIntervalSince(began) }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }
}

@Suite("Цикл работы на настоящих файлах", .serialized)
struct WorkEngineTests {
    private func liveSession(_ folder: TempFolder, id: String = "s1") throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let start = try #require(ProcessInspector.startTime(pid: pid))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        folder.write("sessions/\(pid).json", #"{"sessionId":"\#(id)","pid":\#(pid),"procStart":"\#(formatter.string(from: start))","cwd":"/x/proj","entrypoint":"claude-vscode","status":"busy"}"#)
    }

    private func toolLine(_ tool: String, file: String, message: String) -> String {
        #"{"type":"assistant","cwd":"/x/proj","timestamp":"2026-11-05T12:00:00.000Z","message":{"id":"\#(message)","model":"opus","usage":{"input_tokens":100,"output_tokens":5},"content":[{"type":"tool_use","id":"t\#(message)","name":"\#(tool)","input":{"file_path":"\#(file)"}}]}}"# + "\n"
    }

    private func engine(_ folder: TempFolder, outputs: Outputs) -> WorkEngine {
        WorkEngine(paths: ClaudePaths(root: folder.url), others: { [] }, handler: { outputs.add($0) })
    }

    @Test("Новый агент виден без хуков не позже чем через 3 секунды после записи")
    func newAgentWithinThreeSeconds() async throws {
        let folder = TempFolder()
        try liveSession(folder)
        folder.write("projects/p/s1.jsonl", toolLine("Read", file: "/x/a.swift", message: "m1"))
        let outputs = Outputs()
        let engine = engine(folder, outputs: outputs)
        await engine.setFocus(runs: [], lookingClosely: true)
        await engine.start()
        #expect(await outputs.wait(timeout: 5) { $0.model.sessions.count == 1 } != nil)
        try await Task.sleep(for: .seconds(1))

        folder.write("projects/p/s1/subagents/agent-a1.meta.json", #"{"description":"Проверка кода"}"#)
        folder.write("projects/p/s1/subagents/agent-a1.jsonl", toolLine("Edit", file: "/x/invoice.swift", message: "m2"))
        let delay = await outputs.wait(timeout: 10) { output in
            output.model.sessions.first?.root.children.contains { $0.id == "a1" && $0.step?.fileName == "invoice.swift" } == true
        }
        await engine.stop()
        let measured = try #require(delay)
        #expect(measured <= 3, "агент появился через \(measured) с")
    }

    @Test("Текущий шаг сессии обновляется без хуков не позже чем через 3 секунды")
    func stepWithinThreeSeconds() async throws {
        let folder = TempFolder()
        try liveSession(folder)
        folder.write("projects/p/s1.jsonl", toolLine("Read", file: "/x/a.swift", message: "m1"))
        let outputs = Outputs()
        let engine = engine(folder, outputs: outputs)
        await engine.setFocus(runs: [], lookingClosely: true)
        await engine.start()
        #expect(await outputs.wait(timeout: 5) { $0.model.sessions.first?.root.step?.fileName == "a.swift" } != nil)

        folder.append("projects/p/s1.jsonl", toolLine("Edit", file: "/x/b.swift", message: "m2"))
        let delay = await outputs.wait(timeout: 10) { $0.model.sessions.first?.root.step?.fileName == "b.swift" }
        await engine.stop()
        let measured = try #require(delay)
        #expect(measured <= 3, "шаг обновился через \(measured) с")
    }

    @Test("Токены приходят из индекса, а дописанное учитывается не позже чем через 5 секунд")
    func tokensFlow() async throws {
        let folder = TempFolder()
        try liveSession(folder)
        folder.write("projects/p/s1.jsonl", toolLine("Read", file: "/x/a.swift", message: "m1"))
        let outputs = Outputs()
        let engine = engine(folder, outputs: outputs)
        await engine.start()
        #expect(await outputs.wait(timeout: 10) { $0.tokens.reduce(0) { $0 + $1.usage.total } == 105 } != nil)

        folder.append("projects/p/s1.jsonl", toolLine("Read", file: "/x/b.swift", message: "m2"))
        let delay = await outputs.wait(timeout: 15) { $0.tokens.reduce(0) { $0 + $1.usage.total } == 210 }
        await engine.stop()
        let measured = try #require(delay)
        #expect(measured <= 5, "токены обновились через \(measured) с")
    }
}

@Suite("Хуки поверх файлов", .serialized)
struct HookOverlayTests {
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: WorkEngine.Output?

        func set(_ output: WorkEngine.Output) {
            lock.lock()
            stored = output
            lock.unlock()
        }

        var value: WorkEngine.Output? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }

    @Test("Статусы запусков одинаковы с хуками и без них", arguments: [RunStatus.running, .silent, .completed, .completedWithErrors, .allAgentsFailed, .failed, .stopped, .interrupted])
    func statusesDoNotDepend(status: RunStatus) {
        let agent = AgentRecord(key: "k", agentId: "a1", state: .running)
        let run = RunState(runId: "wf", sessionId: "s1", name: "x", status: status, lastWrite: Date(), agents: [agent])
        var hooks = HookState()
        hooks.apply(.toolStarted(session: "s1", agent: "a1", tool: "Bash"), now: Date())
        hooks.apply(.turnStopped(session: "s1"), now: Date())
        hooks.apply(.stopFailure(session: "s1", error: "rate_limit"), now: Date())
        hooks.apply(.sessionEnded(session: "s1", reason: "other", cwd: nil), now: Date())
        #expect(hooks.overlay(runs: [run]).first?.status == status)
    }

    @Test("С хуками текущий шаг виден сразу, ещё до следующего чтения файлов")
    func signalShowsAtOnce() async throws {
        let folder = TempFolder()
        let pid = ProcessInfo.processInfo.processIdentifier
        let start = try #require(ProcessInspector.startTime(pid: pid))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        folder.write("sessions/\(pid).json", #"{"sessionId":"s1","pid":\#(pid),"procStart":"\#(formatter.string(from: start))","cwd":"/x","status":"busy"}"#)
        let box = Box()
        let engine = WorkEngine(paths: ClaudePaths(root: folder.url), others: { [] }, handler: { box.set($0) })
        await engine.start()
        for _ in 0..<100 where box.value == nil { try await Task.sleep(for: .milliseconds(50)) }
        #expect(box.value?.model.sessions.first?.root.step == nil)

        let began = Date()
        await engine.receive(.toolStarted(session: "s1", agent: nil, tool: "Bash"))
        var delay: TimeInterval?
        for _ in 0..<600 where delay == nil {
            if box.value?.model.sessions.first?.root.step?.tool == "Bash" {
                delay = Date().timeIntervalSince(began)
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        await engine.stop()
        // Files have not changed here, so the step can only have come from the hook. The next timed scan is 5 s away.
        let measured = try #require(delay, "шаг так и не появился")
        print("hook step shown in \(Int(measured * 1000)) ms")
        #expect(measured < 2, "шаг появился через \(measured) с")
    }
}

@Suite("События из движка")
struct EngineEventTests {
    private final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [BorisEvent] = []

        func add(_ more: [BorisEvent]) {
            lock.lock()
            stored += more
            lock.unlock()
        }

        var all: [BorisEvent] {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }

    @Test("Сбой из хука доходит до событий ровно один раз")
    func hookFailure() async throws {
        let folder = TempFolder()
        folder.write("sessions/.keep", "")
        let events = Events()
        let engine = WorkEngine(paths: ClaudePaths(root: folder.url), others: { [] }, handler: { events.add($0.events) })
        await engine.start()
        await engine.receive(.stopFailure(session: "s1", error: "billing_error"))
        var failures: [BorisEvent] = []
        for _ in 0..<300 where failures.isEmpty {
            await engine.requestScan()
            try await Task.sleep(for: .milliseconds(20))
            failures = events.all.filter { $0.sessionId == "s1" }
        }
        try await Task.sleep(for: .milliseconds(200))
        await engine.stop()
        #expect(events.all.filter { $0.sessionId == "s1" }.count == 1)
    }
}
