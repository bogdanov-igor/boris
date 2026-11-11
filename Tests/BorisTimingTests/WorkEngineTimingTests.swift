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

extension TimingTests {
    @Suite("Цикл работы на настоящих файлах: сроки")
    struct WorkEngineTimingTests {
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
}
