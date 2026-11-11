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

    @Test("Названная папка читается сама, а остальная история не трогается")
    func readsOnlyNamedFolders() async {
        let folder = TempFolder()
        let paths = ClaudePaths(root: folder.url)
        folder.write("projects/p/a.jsonl", line("a", input: 1, output: 0))
        folder.write("projects/q/b.jsonl", line("b", input: 10, output: 0))
        folder.write("projects/q/b/subagents/agent-1.jsonl", line("c", input: 100, output: 0))
        folder.write("projects/q/b/subagents/workflows/wf_1/agent-2.jsonl", line("d", input: 1000, output: 0))
        let index = TokenIndex(cacheFile: nil, timeZone: utc)
        let root = paths.projects.path

        #expect(await index.update(folders: ["\(root)/p/"], roots: [paths]))
        #expect(await total(index) == 1)
        await index.update(folders: ["\(root)/q/b/subagents/workflows/wf_1"], roots: [paths])
        #expect(await total(index) == 1001)
        await index.update(folders: ["\(root)/q/b/subagents"], roots: [paths])
        #expect(await total(index) == 1101)
        // These hold no transcripts of their own, and a path from elsewhere is not Claude's.
        #expect(await !index.update(folders: [root, "\(root)/q/b", "\(root)/q/b/subagents/workflows", folder.url.appendingPathComponent("sessions").path, "/somewhere/else/p"], roots: [paths]))
        #expect(await total(index) == 1101)
        await index.update(roots: [paths])
        #expect(await total(index) == 1111)
    }

    @Test("Время без долей секунды относит запись к её дню, а не ко дню, когда файл писали последний раз")
    func wholeSecondTimestamp() async throws {
        let folder = TempFolder()
        let file = folder.write("projects/p/a.jsonl", #"{"type":"assistant","timestamp":"2026-11-05T12:00:00Z","message":{"id":"a","model":"opus","usage":{"input_tokens":7,"output_tokens":0}}}"# + "\n")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_794_225_600)], ofItemAtPath: file.path)
        let index = TokenIndex(cacheFile: nil, timeZone: utc)
        await index.update(roots: [ClaudePaths(root: folder.url)])
        #expect(await index.records().map(\.day) == ["2026-11-05"])
    }

    @Test("Скрытая папка обновления лимитов не читается и по названной папке")
    func namedFolderSkipsHidden() async {
        let folder = TempFolder()
        let paths = ClaudePaths(root: folder.url)
        folder.write("projects/\(BorisPaths.usageProbeProject)/probe.jsonl", line("a"))
        let index = TokenIndex(cacheFile: nil, timeZone: utc)
        #expect(await !index.update(folders: [paths.projects.appendingPathComponent(BorisPaths.usageProbeProject).path], roots: [paths]))
        #expect(await total(index) == 0)
    }

    @Test("Кэш переписывается не чаще раза в минуту, а при завершении дописывается")
    func cacheSavedRarely() async throws {
        let folder = TempFolder()
        let paths = ClaudePaths(root: folder.url)
        let cache = folder.url.appendingPathComponent("support/index.json")
        folder.write("projects/p/a.jsonl", line("a", input: 1, output: 0))
        let index = TokenIndex(cacheFile: cache, timeZone: utc)
        await index.update(roots: [paths])
        let first = try Data(contentsOf: cache)

        for number in 1...3 {
            folder.append("projects/p/a.jsonl", line("more\(number)", input: 1, output: 0))
            await index.update(folders: [paths.projects.appendingPathComponent("p").path], roots: [paths])
        }
        #expect(await total(index) == 4)
        #expect(try Data(contentsOf: cache) == first)

        await index.flush()
        let again = TokenIndex(cacheFile: cache, timeZone: utc)
        #expect(await total(again) == 4)
    }

    @Test("Кэш читается при первом обращении, а не при создании, которое бывает на главном потоке")
    func cacheLoadedOnFirstUse() async throws {
        let folder = TempFolder()
        let paths = ClaudePaths(root: folder.url)
        let cache = folder.url.appendingPathComponent("index.json")
        folder.write("projects/p/a.jsonl", line("a", input: 1, output: 0))
        await TokenIndex(cacheFile: cache, timeZone: utc).update(roots: [paths])

        let late = TokenIndex(cacheFile: cache, timeZone: utc)
        try FileManager.default.removeItem(at: cache)
        #expect(await total(late) == 0)

        await TokenIndex(cacheFile: cache, timeZone: utc).update(roots: [paths])
        #expect(await total(TokenIndex(cacheFile: cache, timeZone: utc)) == 1)
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
}
