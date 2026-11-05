import BorisCore
import Foundation
import Testing
@testable import BorisData

@Suite("Точный подсчёт токенов на всех уровнях")
struct UsageLevelsTests {
    private let utc = TimeZone(identifier: "UTC") ?? .current

    private func line(_ id: String, input: Int = 0, output: Int = 0, read: Int = 0, write: Int = 0, model: String = "claude-opus-5-5", day: String = "2026-11-05", cwd: String = "/x/proj", entrypoint: String = "cli") -> String {
        #"{"type":"assistant","timestamp":"\#(day)T12:00:00.000Z","cwd":"\#(cwd)","entrypoint":"\#(entrypoint)","message":{"id":"\#(id)","model":"\#(model)","usage":{"input_tokens":\#(input),"output_tokens":\#(output),"cache_read_input_tokens":\#(read),"cache_creation_input_tokens":\#(write)}}}"# + "\n"
    }

    /// A session with a repeated message in one file, a subagent, a fork that starts with its parent's messages, and a workflow agent.
    private func world() -> TempFolder {
        let folder = TempFolder()
        folder.write(
            "projects/p/s1.jsonl",
            line("m1", input: 10, output: 1, read: 100, write: 50)
                + line("m1", input: 10, output: 8, read: 100, write: 50)
                + line("m1", input: 10, output: 20, read: 100, write: 50)
                + line("m2", input: 5, output: 7, read: 300, write: 0, model: "claude-sonnet-5-5")
        )
        folder.write("projects/p/s1/subagents/agent-sub.jsonl", line("m3", input: 3, output: 4, cwd: "/x/proj"))
        folder.write(
            "projects/p/s1/subagents/agent-fork.jsonl",
            line("m1", input: 10, output: 20, read: 100, write: 50) + line("m2", input: 5, output: 7, read: 300) + line("m4", input: 2, output: 2)
        )
        folder.write("projects/p/s1/subagents/workflows/wf_1/agent-w1.jsonl", line("m5", input: 1, output: 9, day: "2026-11-04"))
        folder.write("projects/q/s2.jsonl", line("m6", input: 1000, cwd: "/x/other", entrypoint: "claude-vscode"))
        return folder
    }

    private func book(_ folder: TempFolder) async -> TokenBook {
        let index = TokenIndex(cacheFile: nil, timeZone: utc)
        await index.update(roots: [ClaudePaths(root: folder.url)])
        return TokenBook(records: await index.records(), now: Date(timeIntervalSince1970: 1_793_880_000), timeZone: utc)
    }

    @Test("Дубли считаются один раз на всех уровнях, и суммы совпадают с эталоном")
    func levels() async {
        let folder = world()
        let book = await book(folder)
        let all = book.report(.all)

        // Worked out by hand: m1 180, m2 312, m3 7, m4 4, m5 10, m6 1000.
        #expect(all.usage == TokenUsage(input: 1021, output: 42, cacheRead: 400, cacheWrite: 50))
        #expect(all.usage.total == 1513)

        var lines: [TokenLine.Key: Int] = [:]
        for breakdown in TokenBreakdown.allCases {
            for line in all.lines(breakdown) { lines[line.key] = line.usage.total }
        }
        #expect(lines[.project("/x/proj")] == 513)
        #expect(lines[.project("/x/other")] == 1000)
        #expect(lines[.environment(.terminal)] == 513)
        #expect(lines[.environment(.vsCode)] == 1000)
        #expect(lines[.model("claude-opus-5-5")] == 1201)
        #expect(lines[.model("claude-sonnet-5-5")] == 312)
        #expect(lines[.day("2026-11-05")] == 1503)
        #expect(lines[.day("2026-11-04")] == 10)
        #expect(lines[.agents(.main)] == 1492)
        #expect(lines[.agents(.subagents)] == 11)
        #expect(lines[.agents(.workflow)] == 10)

        // And over the live model: the whole session on the root, each agent on its own node.
        let session = WorkSession(id: "s1", state: .running, root: WorkNode(id: "s1", kind: .main, children: [
            WorkNode(id: "sub", kind: .subagent),
            WorkNode(id: "fork", kind: .fork),
            WorkNode(id: "wf_1", kind: .workflow, workflow: nil, children: [WorkNode(id: "w1", kind: .workflowAgent)]),
        ]))
        let laid = book.applied(to: WorkModel(projects: [WorkProject(path: "/x/proj", sessions: [session])])).sessions[0]
        #expect(laid.root.tokens?.total == 513)
        #expect(laid.mainAgentTokens?.total == 492)
        #expect(laid.root.children[0].tokens?.total == 7)
        #expect(laid.root.children[1].tokens?.total == 4)
        #expect(laid.root.children[2].tokens?.total == 10)
        #expect(laid.root.children[2].children[0].tokens?.total == 10)
    }

    @Test("Обезличенные логи дают эталонные суммы, посчитанные отдельно на Python")
    func fixtures() async throws {
        let folder = TempFolder()
        let paths = try Fixtures.world(into: folder)
        let index = TokenIndex(cacheFile: nil, timeZone: utc)
        await index.update(roots: [paths])
        let book = TokenBook(records: await index.records(), now: Date(), timeZone: utc)
        let all = book.report(.all)
        #expect(all.usage == TokenUsage(input: 338, output: 217_102, cacheRead: 4_385_005, cacheWrite: 1_112_830))
        for breakdown in TokenBreakdown.allCases {
            #expect(all.lines(breakdown).reduce(0) { $0 + $1.usage.total } == 5_715_275, "\(breakdown)")
        }
    }

    @Test("Контекст и расход это разные числа")
    func contextIsNotSpend() async throws {
        let folder = TempFolder()
        let pid = ProcessInfo.processInfo.processIdentifier
        let start = try #require(ProcessInspector.startTime(pid: pid))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = utc
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        let updated = Int(Date().timeIntervalSince1970 * 1000)
        folder.write("sessions/\(pid).json", #"{"sessionId":"s1","pid":\#(pid),"procStart":"\#(formatter.string(from: start))","cwd":"/x/proj","entrypoint":"cli","status":"busy","statusUpdatedAt":\#(updated)}"#)
        folder.write(
            "projects/p/s1.jsonl",
            line("m1", input: 10, output: 5, read: 1000, write: 100, day: "2026-11-05")
                + line("m1", input: 10, output: 50, read: 1000, write: 100, day: "2026-11-05")
                + line("m2", input: 20, output: 30, read: 2000, write: 200, model: "claude-sonnet-5-5", day: "2026-11-05")
        )
        let paths = ClaudePaths(root: folder.url)
        let scanner = RunScanner(paths: paths)
        await scanner.markDiscovery()
        await scanner.setFocus(runs: [], menuOpen: true)
        let world = await scanner.scan(now: Date())
        let model = WorkBuilder.build(world: world, runs: [])

        let index = TokenIndex(cacheFile: nil, timeZone: utc)
        await index.update(roots: [paths])
        let book = TokenBook(records: await index.records(), now: Date(), timeZone: utc)
        let root = try #require(book.applied(to: model).sessions.first).root

        // The context is only the newest message. The spend is every message, once.
        #expect(root.contextTokens == 2220)
        #expect(root.model == "claude-sonnet-5-5")
        #expect(root.tokens?.total == 1160 + 2250)
        #expect(root.contextTokens != root.tokens?.total)
    }

    @Test("Контекст простаивающей сессии тоже известен, пока на неё смотрят")
    func contextOfIdleSession() async throws {
        let folder = TempFolder()
        let pid = ProcessInfo.processInfo.processIdentifier
        let start = try #require(ProcessInspector.startTime(pid: pid))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = utc
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        folder.write("sessions/\(pid).json", #"{"sessionId":"s1","pid":\#(pid),"procStart":"\#(formatter.string(from: start))","cwd":"/x/proj","entrypoint":"cli","status":"idle"}"#)
        folder.write("projects/p/s1.jsonl", line("m1", input: 10, output: 5, read: 1000))
        let scanner = RunScanner(paths: ClaudePaths(root: folder.url))
        await scanner.markDiscovery()
        #expect(await scanner.scan(now: Date()).sessions.first?.contextTokens == nil)
        await scanner.setFocus(runs: [], menuOpen: true)
        #expect(await scanner.scan(now: Date()).sessions.first?.contextTokens == 1010)
    }
}
