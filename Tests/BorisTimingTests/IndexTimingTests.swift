import BorisCore
import Foundation
import Testing
@testable import BorisData

/// Lines shaped like the ones Claude Code writes, with made-up content.
private func tokenLine(_ id: String, cwd: String) -> String {
    #"{"type":"assistant","timestamp":"2026-11-05T12:00:00.000Z","cwd":"\#(cwd)","entrypoint":"cli","message":{"id":"\#(id)","model":"opus","usage":{"input_tokens":10,"output_tokens":1}}}"# + "\n"
}

private func toolUse(_ id: String, name: String) -> String {
    #"{"type":"assistant","uuid":"a-\#(id)","timestamp":"2026-11-05T12:00:00.000Z","cwd":"/x/shop-api","entrypoint":"cli","message":{"id":"m-\#(id)","model":"opus","content":[{"type":"tool_use","id":"\#(id)","name":"\#(name)","input":{}}],"stop_reason":"tool_use","usage":{"input_tokens":1,"output_tokens":1}}}"# + "\n"
}

private func failedResult(_ id: String, _ text: String) -> String {
    #"{"type":"user","uuid":"r-\#(id)","timestamp":"2026-11-05T12:00:00.000Z","cwd":"/x/shop-api","entrypoint":"cli","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"\#(id)","is_error":true,"content":"\#(text)"}]}}"# + "\n"
}

extension TimingTests {
    @Suite("Индексы не держат главный поток")
    struct IndexTimingTests {
        private let utc = TimeZone(identifier: "UTC") ?? .current

        @Test("Чтение логов для расхода не держит главный поток")
        @MainActor
        func tokensKeepMainThreadFree() async throws {
            let folder = TempFolder()
            let path = "/x/\(String(repeating: "p", count: 200))"
            for file in 0..<40 {
                let body = (0..<2000).map { tokenLine("f\(file)m\($0)", cwd: path) }.joined()
                folder.write("projects/p/s\(file).jsonl", body)
            }
            let index = TokenIndex(cacheFile: nil, timeZone: utc)
            let roots = [ClaudePaths(root: folder.url)]
            let finished = Flag()
            Task.detached(priority: .utility) {
                await index.update(roots: roots)
                finished.set()
            }

            // The main thread only ticks here and never waits for the index, as in the app. The bound keeps a broken index from hanging the tests.
            let began = Date()
            let watchdog = began.addingTimeInterval(60)
            var longest: TimeInterval = 0
            var last = began
            var ticks = 0
            while !finished.isSet, Date() < watchdog {
                try await Task.sleep(for: .milliseconds(5))
                let now = Date()
                longest = max(longest, now.timeIntervalSince(last))
                last = now
                ticks += 1
            }
            // A stall that lasts until the read ends leaves the loop without being counted.
            longest = max(longest, Date().timeIntervalSince(last))
            let reading = Date().timeIntervalSince(began)
            #expect(finished.isSet)
            #expect(await index.records().reduce(0) { $0 + $1.usage.total } == 40 * 2000 * 11)
            #expect(ticks > 1)
            // Other tests in this process stall the ticks by up to 0.9 s with no index running at all, so a fixed limit says nothing here.
            // A read that holds the main thread shows up differently: as a stall about as long as the read itself.
            #expect(longest < max(1.5, reading / 2), "главный поток простаивал \(longest) с из \(reading) с чтения")
        }

        @Test("Чтение логов для потерь не держит главный поток")
        @MainActor
        func lossesKeepMainThreadFree() async throws {
            let folder = TempFolder()
            for file in 0..<30 {
                let body = (0..<1000).map { toolUse("f\(file)t\($0)", name: "WebFetch") + failedResult("f\(file)t\($0)", "Exit code 1") }.joined()
                folder.write("projects/p/s\(file).jsonl", body)
            }
            let index = LossIndex(cacheFile: nil, timeZone: utc)
            let roots = [ClaudePaths(root: folder.url)]
            let finished = Flag()
            Task.detached(priority: .utility) {
                await index.update(roots: roots)
                finished.set()
            }

            // The same measure as for the token index: a read that holds the main thread shows as a stall about as long as the read.
            let began = Date()
            let watchdog = began.addingTimeInterval(120)
            var longest: TimeInterval = 0
            var last = began
            var ticks = 0
            while !finished.isSet, Date() < watchdog {
                try await Task.sleep(for: .milliseconds(5))
                let now = Date()
                longest = max(longest, now.timeIntervalSince(last))
                last = now
                ticks += 1
            }
            longest = max(longest, Date().timeIntervalSince(last))
            let reading = Date().timeIntervalSince(began)
            #expect(finished.isSet)
            #expect(await index.history(live: []).entries.count == 30 * 1000)
            #expect(ticks > 1)
            #expect(longest < max(1.5, reading / 2), "главный поток простаивал \(longest) с из \(reading) с чтения")
        }
    }
}
