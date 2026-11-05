import BorisCore
import Foundation
import Testing
@testable import BorisData

@Suite("Индекс токенов")
struct TokenIndexTests {
    private func line(_ id: String, input: Int = 10, output: Int = 1, model: String = "opus", day: String = "2026-11-05", cwd: String = "/x/proj") -> String {
        #"{"type":"assistant","timestamp":"\#(day)T12:00:00.000Z","cwd":"\#(cwd)","entrypoint":"cli","message":{"id":"\#(id)","model":"\#(model)","usage":{"input_tokens":\#(input),"output_tokens":\#(output)}}}"# + "\n"
    }

    private let utc = TimeZone(identifier: "UTC") ?? .current

    private func total(_ index: TokenIndex) async -> Int {
        await index.records().reduce(0) { $0 + $1.usage.total }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        func set() {
            lock.lock()
            value = true
            lock.unlock()
        }

        var isSet: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    @Test("Агент с двумя файлами под одним именем считается целиком и без повторов")
    func agentWithTwoFiles() async {
        let folder = TempFolder()
        folder.write("projects/p/s.jsonl", line("main", input: 1000, output: 0))
        folder.write("projects/p/s/subagents/workflows/wf_1/agent-x.jsonl", line("in-run", input: 10, output: 0) + line("both", input: 5, output: 0))
        // Goes on after the workflow, with one message written in both.
        folder.write("projects/p/s/subagents/agent-x.jsonl", line("both", input: 5, output: 0) + line("after", input: 200, output: 0))
        let index = TokenIndex(cacheFile: nil, timeZone: utc)
        await index.update(roots: [ClaudePaths(root: folder.url)])
        let book = TokenBook(records: await index.records(), now: Date(timeIntervalSince1970: 1_793_000_000), timeZone: utc)
        #expect(book.spent(agent: "x")?.total == 215)
        #expect(book.spent(session: "s")?.total == 1215)
        #expect(book.spent(mainAgentOf: "s")?.total == 1000)
    }

    @Test("Один ответ, записанный несколько раз, считается один раз")
    func repeatsInFile() async {
        let folder = TempFolder()
        folder.write("projects/p/s1.jsonl", line("m1", input: 10, output: 1) + line("m1", input: 10, output: 5) + line("m2", input: 20, output: 2))
        let index = TokenIndex(cacheFile: nil, timeZone: utc)
        await index.update(roots: [ClaudePaths(root: folder.url)])
        #expect(await total(index) == 37)
    }

    @Test("Ответ, повторённый в файле форка, считается один раз")
    func repeatsAcrossFiles() async {
        let folder = TempFolder()
        folder.write("projects/p/s1.jsonl", line("m1", input: 100, output: 0))
        folder.write("projects/p/s1/subagents/agent-f1.jsonl", line("m1", input: 100, output: 0) + line("m2", input: 7, output: 0))
        let index = TokenIndex(cacheFile: nil, timeZone: utc)
        await index.update(roots: [ClaudePaths(root: folder.url)])
        #expect(await total(index) == 107)
        let records = await index.records()
        #expect(records.first { $0.agentId == nil }?.usage.total == 100)
        #expect(records.first { $0.agentId == "f1" }?.usage.total == 7)
    }

    @Test("Дописанное читается с места последнего чтения, в том числе после перезапуска")
    func incremental() async {
        let folder = TempFolder()
        let cache = folder.url.appendingPathComponent("support/index.json")
        folder.write("projects/p/s1.jsonl", line("m1"))
        let first = TokenIndex(cacheFile: cache, timeZone: utc)
        await first.update(roots: [ClaudePaths(root: folder.url)])
        #expect(await total(first) == 11)

        folder.append("projects/p/s1.jsonl", line("m2"))
        let second = TokenIndex(cacheFile: cache, timeZone: utc)
        #expect(await total(second) == 11)
        await second.update(roots: [ClaudePaths(root: folder.url)])
        #expect(await total(second) == 22)
    }

    @Test("Ответ, начатый до перезапуска и выросший после, не считается заново")
    func growsAcrossRestart() async {
        let folder = TempFolder()
        let cache = folder.url.appendingPathComponent("index.json")
        folder.write("projects/p/s1.jsonl", line("m1", input: 10, output: 1))
        let first = TokenIndex(cacheFile: cache, timeZone: utc)
        await first.update(roots: [ClaudePaths(root: folder.url)])
        folder.append("projects/p/s1.jsonl", line("m1", input: 10, output: 9))
        let second = TokenIndex(cacheFile: cache, timeZone: utc)
        await second.update(roots: [ClaudePaths(root: folder.url)])
        #expect(await total(second) == 19)
    }

    @Test("Кэш можно удалить: те же суммы строятся заново из логов")
    func cacheIsDisposable() async throws {
        let folder = TempFolder()
        let cache = folder.url.appendingPathComponent("index.json")
        folder.write("projects/p/s1.jsonl", line("m1") + line("m2", model: "sonnet"))
        folder.write("projects/p/s1/subagents/agent-a1.jsonl", line("m3"))
        let first = TokenIndex(cacheFile: cache, timeZone: utc)
        await first.update(roots: [ClaudePaths(root: folder.url)])
        let before = await total(first)
        #expect(FileManager.default.fileExists(atPath: cache.path))

        try FileManager.default.removeItem(at: cache)
        let rebuilt = TokenIndex(cacheFile: cache, timeZone: utc)
        #expect(await total(rebuilt) == 0)
        await rebuilt.update(roots: [ClaudePaths(root: folder.url)])
        #expect(await total(rebuilt) == before)
    }

    @Test("Повреждённый кэш не мешает: всё строится заново")
    func brokenCache() async {
        let folder = TempFolder()
        let cache = folder.write("index.json", "{not json")
        folder.write("projects/p/s1.jsonl", line("m1"))
        let index = TokenIndex(cacheFile: cache, timeZone: utc)
        await index.update(roots: [ClaudePaths(root: folder.url)])
        #expect(await total(index) == 11)
    }

    @Test("Недописанная строка ждёт конца записи")
    func unfinishedLine() async {
        let folder = TempFolder()
        let complete = line("m1")
        let second = line("m2")
        folder.write("projects/p/s1.jsonl", complete + String(second.prefix(30)))
        let index = TokenIndex(cacheFile: nil, timeZone: utc)
        await index.update(roots: [ClaudePaths(root: folder.url)])
        #expect(await total(index) == 11)
        folder.append("projects/p/s1.jsonl", String(second.dropFirst(30)))
        await index.update(roots: [ClaudePaths(root: folder.url)])
        #expect(await total(index) == 22)
    }

    @Test("Лог, удалённый Claude, уходит из сумм, а его ответы можно встретить снова")
    func deletedLog() async throws {
        let folder = TempFolder()
        let file = folder.write("projects/p/s1.jsonl", line("m1"))
        folder.write("projects/p/s2.jsonl", line("m2"))
        let index = TokenIndex(cacheFile: nil, timeZone: utc)
        await index.update(roots: [ClaudePaths(root: folder.url)])
        #expect(await total(index) == 22)
        try FileManager.default.removeItem(at: file)
        await index.update(roots: [ClaudePaths(root: folder.url)])
        #expect(await total(index) == 11)
        folder.write("projects/p/s3.jsonl", line("m1"))
        await index.update(roots: [ClaudePaths(root: folder.url)])
        #expect(await total(index) == 22)
    }

    @Test("Сумма раскладывается по дням и моделям и знает, чья она")
    func attribution() async throws {
        let folder = TempFolder()
        folder.write("projects/p/s1.jsonl", line("m1", model: "opus", day: "2026-11-04") + line("m2", model: "opus", day: "2026-11-05") + line("m3", model: "sonnet", day: "2026-11-05"))
        folder.write("projects/p/s1/subagents/workflows/wf_1/agent-w1.jsonl", line("m4", day: "2026-11-05"))
        let index = TokenIndex(cacheFile: nil, timeZone: utc)
        await index.update(roots: [ClaudePaths(root: folder.url)])
        let records = await index.records()
        #expect(records.filter { $0.agentId == nil }.count == 3)
        let worker = try #require(records.first { $0.agentId == "w1" })
        #expect(worker.runId == "wf_1")
        #expect(worker.sessionId == "s1")
        #expect(worker.cwd == "/x/proj")
        #expect(worker.entrypoint == "cli")
        #expect(await index.earliestDay() == "2026-11-04")
    }

    @Test("Служебные ответы без настоящей модели не считаются")
    func synthetic() async {
        let folder = TempFolder()
        folder.write("projects/p/s1.jsonl", line("m1", model: "<synthetic>") + line("m2"))
        let index = TokenIndex(cacheFile: nil, timeZone: utc)
        await index.update(roots: [ClaudePaths(root: folder.url)])
        #expect(await total(index) == 11)
    }

    @Test("Чтение логов не держит главный поток")
    @MainActor
    func mainThreadStaysFree() async throws {
        let folder = TempFolder()
        let path = "/x/\(String(repeating: "p", count: 200))"
        for file in 0..<40 {
            let body = (0..<2000).map { line("f\(file)m\($0)", cwd: path) }.joined()
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
        #expect(await total(index) == 40 * 2000 * 11)
        #expect(ticks > 1)
        // Other tests in this process stall the ticks by up to 0.9 s with no index running at all, so a fixed limit says nothing here.
        // A read that holds the main thread shows up differently: as a stall about as long as the read itself.
        #expect(longest < max(1.5, reading / 2), "главный поток простаивал \(longest) с из \(reading) с чтения")
    }
}
