import BorisCore
import Foundation
import Testing
@testable import BorisData

/// Claude's files are internal and can change with any update. Boris must keep working and say what it could not read.
@Suite("Устойчивость к смене форматов")
struct FormatToleranceTests {
    private func scan(_ folder: TempFolder) async -> WorldSnapshot {
        await RunScanner(paths: ClaudePaths(root: folder.url)).scan(now: Date())
    }

    private func liveProcStart() throws -> (pid: Int32, text: String) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let start = try #require(ProcessInspector.startTime(pid: pid))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return (pid, formatter.string(from: start))
    }

    @Test("Незнакомые поля в файле сессии не мешают")
    func unknownSessionFields() async throws {
        let folder = TempFolder()
        let live = try liveProcStart()
        folder.write("sessions/\(live.pid).json", #"{"sessionId":"s1","pid":\#(live.pid),"procStart":"\#(live.text)","cwd":"/x","status":"busy","futureField":{"a":[1,2]},"another":true}"#)
        let world = await scan(folder)
        #expect(world.sessions.map(\.sessionId) == ["s1"])
        #expect(world.formatIssues.isEmpty)
    }

    @Test("Сессия без необязательных полей всё равно видна")
    func missingSessionFields() async throws {
        let folder = TempFolder()
        let live = try liveProcStart()
        folder.write("sessions/\(live.pid).json", #"{"sessionId":"s1","pid":\#(live.pid)}"#)
        let world = await scan(folder)
        let session = try #require(WorkBuilder.build(world: world, runs: []).sessions.first)
        #expect(session.id == "s1")
        #expect(session.cwd == nil)
        #expect(session.environment == nil)
        #expect(session.title == nil)
    }

    @Test("Все файлы сессий нечитаемы: об этом сказано, а не показан пустой список молча")
    func unreadableSessions() async {
        let folder = TempFolder()
        folder.write("sessions/123.json", "{not json")
        let world = await scan(folder)
        #expect(world.sessions.isEmpty)
        #expect(world.formatIssues.contains(.unreadableSessions))
    }

    @Test("Сломанные метаданные агента: агент виден, но без описания")
    func brokenAgentMeta() async {
        let folder = TempFolder()
        folder.write("sessions/.keep", "")
        folder.write("projects/p/s1/subagents/agent-a1.meta.json", "{not json")
        folder.write("projects/p/s1/subagents/agent-a1.jsonl", #"{"type":"user","message":{"content":"go"}}"# + "\n")
        let world = await scan(folder)
        let agent = world.agents.first { $0.id == "a1" }
        #expect(agent != nil)
        #expect(agent?.description == nil)
    }

    @Test("Незнакомый итог workflow сохраняется как есть и ничего не ломает")
    func unknownFinalStatus() throws {
        let run = RunSnapshot(runId: "wf", sessionId: "s", lastWrite: Date(), final: FinalReport(status: "teleported"))
        var tracker = RunTracker()
        let world = WorldSnapshot(takenAt: Date(), runs: [run])
        let state = try #require(tracker.resolve(world) { _ in nil }.first)
        #expect(state.status == .unknown("teleported"))
        let model = WorkBuilder.build(world: world, runs: [state])
        #expect(model.sessions.first?.root.children.first?.workflow?.status == .unknown("teleported"))
    }

    @Test("Мусор между строками лога не теряет остальное")
    func garbageInTranscript() async {
        let folder = TempFolder()
        let good = #"{"type":"assistant","timestamp":"2026-11-05T12:00:00.000Z","message":{"id":"m1","model":"opus","usage":{"input_tokens":10,"output_tokens":1}}}"#
        let weird = #"{"type":"assistant","message":{"id":"m2","model":"opus","usage":"not an object"}}"#
        let wrongTypes = #"{"type":"assistant","message":{"id":"m3","model":"opus","usage":{"input_tokens":"ten"}}}"#
        folder.write("projects/p/s1.jsonl", "not json at all usage assistant\n" + weird + "\n" + wrongTypes + "\n" + good + "\n")
        let index = TokenIndex(cacheFile: nil)
        await index.update(roots: [ClaudePaths(root: folder.url)])
        let total = await index.records().reduce(0) { $0 + $1.usage.total }
        #expect(total == 11)
    }

    @Test("Лимиты: незнакомые окна пропускаются, отсутствие кэша не ошибка")
    func usageTolerance() {
        let folder = TempFolder()
        let known = folder.write("a.json", #"{"cachedUsageUtilization":{"fetchedAtMs":1000,"utilization":{"seven_day":{"utilization":34,"resets_at":"2026-11-09T10:00:00.123456Z"},"five_hour":null,"amber_ladder":{"utilization":99},"limits":"strange"}}}"#)
        let usage = UsageReader.read(known)
        #expect(usage?.windows.map(\.id) == ["seven_day"])

        let empty = folder.write("b.json", #"{"somethingElse":1}"#)
        #expect(UsageReader.read(empty) == nil)
        #expect(UsageReader.read(folder.url.appendingPathComponent("missing.json")) == nil)
    }

    @Test("Доплаты: все три состояния и незнакомая форма")
    func extraSpend() {
        let folder = TempFolder()
        func read(_ extra: String) -> UsageSnapshot? {
            let file = folder.write("u.json", #"{"cachedUsageUtilization":{"utilization":{"extra_usage":\#(extra)}}}"#)
            return UsageReader.read(file)
        }
        let on = read(#"{"is_enabled":true,"monthly_limit":5000,"used_credits":1240,"decimal_places":2}"#)
        let window = on?.windows.first { $0.kind == .extraSpend }
        #expect(window?.usedDollars == 12.4)
        #expect(window?.limitDollars == 50)

        #expect(read(#"{"is_enabled":false,"monthly_limit":5000,"used_credits":0,"decimal_places":2}"#)?.windows.isEmpty == true)
        #expect(read(#""something new""#)?.windows.isEmpty == true)
    }
}
