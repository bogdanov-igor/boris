import BorisCore
import Foundation
import Testing
@testable import BorisData

/// Lines shaped like the ones Claude Code writes, with made-up content.
private enum Log {
    static let stamp = "\"timestamp\":\"2026-11-05T12:00:00.000Z\",\"cwd\":\"/x/shop-api\",\"entrypoint\":\"cli\""

    static func toolUse(_ id: String, name: String, input: String = "{}", message: String? = nil) -> String {
        #"{"type":"assistant","uuid":"a-\#(id)",\#(stamp),"message":{"id":"\#(message ?? "m-\(id)")","model":"opus","content":[{"type":"tool_use","id":"\#(id)","name":"\#(name)","input":\#(input)}],"stop_reason":"tool_use","usage":{"input_tokens":1,"output_tokens":1}}}"# + "\n"
    }

    static func say(_ id: String = "m1", stop: String = "end_turn") -> String {
        #"{"type":"assistant","uuid":"a-\#(id)",\#(stamp),"message":{"id":"\#(id)","model":"opus","content":[{"type":"text","text":"SECRET-ANSWER"}],"stop_reason":"\#(stop)","usage":{"input_tokens":1,"output_tokens":1}}}"# + "\n"
    }

    static func result(_ id: String, _ text: String, error: Bool = false, extra: String = "") -> String {
        #"{"type":"user","uuid":"r-\#(id)",\#(stamp),\#(extra)"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"\#(id)",\#(error ? "\"is_error\":true," : "")"content":\#(quoted(text))}]}}"# + "\n"
    }

    static func person(_ text: String) -> String {
        #"{"type":"user","uuid":"\#(UUID().uuidString)",\#(stamp),"message":{"role":"user","content":\#(quoted(text))}}"# + "\n"
    }

    static func skillText(_ source: String, bytes: Int) -> String {
        #"{"type":"user","uuid":"x-\#(source)",\#(stamp),"isMeta":true,"sourceToolUseID":"\#(source)","message":{"role":"user","content":[{"type":"text","text":"\#(String(repeating: "s", count: bytes))"}]}}"# + "\n"
    }

    static func apiError(_ id: String = "e1", code: String? = "rate_limit", status: Int? = nil, text: String, extra: String = "") -> String {
        let codePart = code.map { "\"error\":\"\($0)\"," } ?? ""
        let statusPart = status.map { "\"apiErrorStatus\":\($0)," } ?? ""
        return #"{"type":"assistant","uuid":"\#(id)",\#(stamp),"isApiErrorMessage":true,\#(codePart)\#(statusPart)\#(extra)"message":{"id":"\#(id)","model":"<synthetic>","content":[{"type":"text","text":\#(quoted(text))}],"stop_reason":"stop_sequence","usage":{"input_tokens":0,"output_tokens":0}}}"# + "\n"
    }

    static func retry(_ id: String, text: String = "Connection dropped (ECONNRESET)", status: Int? = nil) -> String {
        let statusPart = status.map { "\"status\":\($0)," } ?? ""
        return #"{"type":"system","subtype":"api_error","uuid":"\#(id)",\#(stamp),"level":"error","retryAttempt":1,"maxRetries":10,"source":"request_retry","error":{\#(statusPart)"message":"x","formatted":\#(quoted(text))}}"# + "\n"
    }

    private static func quoted(_ text: String) -> String {
        String(decoding: (try? JSONEncoder().encode(text)) ?? Data(), as: UTF8.self)
    }
}

@Suite("Учёт потерь")
struct LossIndexTests {
    private let utc = TimeZone(identifier: "UTC") ?? .current

    private func history(_ folder: TempFolder, live: Set<String> = []) async -> LossHistory {
        let index = LossIndex(cacheFile: nil, timeZone: utc)
        await index.update(roots: [ClaudePaths(root: folder.url)])
        return await index.history(live: live)
    }

    private func entries(_ log: String) async -> [LossEntry] {
        let folder = TempFolder()
        folder.write("projects/p/s1.jsonl", log)
        return await history(folder).entries
    }

    // MARK: Types

    @Test("Ход прервался из-за лимита: сбой с типом и временем сброса")
    func apiLimit() async throws {
        let found = try #require(await entries(Log.apiError(text: "You've hit your session limit · resets 2pm", extra: #""quotaLimits":{"resetsAt":1793900000},"#)).first)
        #expect(found.kind == .apiError)
        #expect(found.reason == .limit)
        #expect(found.limit == .session)
        #expect(found.resets == "2pm")
        #expect(found.resetsAt == Date(timeIntervalSince1970: 1_793_900_000))
        #expect(found.sessionId == "s1")
        #expect(found.agentId == nil)
        #expect(found.project == "shop-api")
        #expect(found.environment == .terminal)
        #expect(found.at == ISO8601DateFormatter().date(from: "2026-11-05T12:00:00Z"))
    }

    @Test("Перегрузка и биллинг отличаются от сети, хотя приходят как ошибка сервера")
    func apiProblems() async throws {
        let overloaded = try #require(await entries(Log.apiError(code: "server_error", status: 529, text: "API Error: 529 Overloaded")).first)
        #expect(overloaded.reason == .api)
        #expect(overloaded.problem == .overloaded)
        let billing = try #require(await entries(Log.apiError(code: "billing_error", text: "Your credit balance is too low")).first)
        #expect(billing.reason == .api)
        #expect(billing.problem == .billing)
        let network = try #require(await entries(Log.apiError(code: "server_error", text: "API Error: Can't reach the API server")).first)
        #expect(network.reason == .network)
        #expect(network.problem == nil)
        let access = try #require(await entries(Log.apiError(code: "authentication_failed", status: 403, text: "Failed to authenticate.")).first)
        #expect(access.problem == .access)
    }

    @Test("Ошибка инструмента: с названием инструмента и агентом")
    func toolError() async throws {
        let folder = TempFolder()
        folder.write("projects/p/s1/subagents/agent-a1.jsonl", Log.toolUse("t1", name: "Bash") + Log.result("t1", "Exit code 3\nSECRET-OUTPUT", error: true) + Log.say())
        folder.write("projects/p/s1/subagents/agent-a1.meta.json", #"{"description":"Проверка кода"}"#)
        let found = try #require(await history(folder).entries.first)
        #expect(found.kind == .toolError)
        #expect(found.tool == "Bash")
        #expect(found.toolFailure == .exitCode)
        #expect(found.toolCode == 3)
        #expect(found.agentId == "a1")
        #expect(found.title == "Проверка кода")
    }

    @Test("Вид ошибки инструмента определяется по её началу", arguments: [
        ("Exit code 1", ToolFailure.exitCode, 1),
        ("<tool_use_error>File does not exist.</tool_use_error>", .noFile, nil),
        ("<tool_use_error>File has not been read yet.</tool_use_error>", .notRead, nil),
        ("<tool_use_error>String to replace not found in file.</tool_use_error>", .noMatch, nil),
        ("<tool_use_error>InputValidationError: x</tool_use_error>", .badCall, nil),
        ("File content (30000 tokens) exceeds maximum allowed tokens", .tooLarge, nil),
        ("Request failed with status code 404", .http, 404),
        ("getaddrinfo ENOTFOUND example.invalid", .network, nil),
        ("Command timed out after 2m", .timeout, nil),
        ("something else", .other, nil),
    ] as [(String, ToolFailure, Int?)])
    func toolFailures(head: String, kind: ToolFailure, code: Int?) {
        let failure = LossIndex.toolFailure(head)
        #expect(failure.kind == kind)
        #expect(failure.code == code)
    }

    @Test("Ошибка загрузки страницы считается и как вызов, и как сбой")
    func failedFetchCountsTwice() async throws {
        let folder = TempFolder()
        folder.write("projects/p/s1.jsonl", Log.toolUse("t1", name: "WebFetch") + Log.result("t1", "Request failed with status code 403", error: true))
        let found = await history(folder)
        #expect(found.entries.map(\.kind) == [.toolError])
        #expect(found.calls.first?.calls == 1)
    }

    @Test("Повторы подряд это одна строка, а её исход известен по следующему ответу")
    func retries() async throws {
        let worked = await entries(Log.retry("r1") + Log.retry("r2") + Log.retry("r3") + Log.say())
        #expect(worked.count == 1)
        #expect(worked.first?.kind == .retry)
        #expect(worked.first?.count == 3)
        #expect(worked.first?.reason == .network)
        #expect(worked.first?.recovered == true)

        let failed = await entries(Log.retry("r1") + Log.apiError(code: "server_error", text: "API Error: Connection dropped (ECONNRESET)"))
        #expect(failed.first { $0.kind == .retry }?.recovered == false)
        #expect(failed.contains { $0.kind == .apiError })

        let going = await entries(Log.retry("r1"))
        #expect(going.first?.recovered == nil)

        let two = await entries(Log.retry("r1") + Log.say("m1") + Log.retry("r2", text: "503 Service temporarily unavailable", status: 503) + Log.say("m2"))
        #expect(two.count == 2)
        #expect(two.first { $0.id == "r2" }?.problem == .overloaded)
    }

    @Test("Обрыв ответа: по причине обрыва и по пределу длины, по одному разу")
    func cuts() async throws {
        let stream = try #require(await entries(Log.apiError(code: "server_error", text: "API Error: Your computer went to sleep mid-response.", extra: #""streamCutCause":"stream_suspended","truncatedAfterOutput":true,"#)).first)
        #expect(stream.kind == .cut)
        #expect(stream.reason == .sleep)

        let long = await entries(Log.say("m1", stop: "max_tokens") + Log.say("m1", stop: "max_tokens"))
        #expect(long.count == 1)
        #expect(long.first?.kind == .cut)
        #expect(long.first?.code == "max_tokens")
    }

    @Test("Отказ в разрешении: вашим решением и правилом")
    func denials() async throws {
        let person = try #require(await entries(
            Log.toolUse("t1", name: "Bash") + Log.result("t1", "The user doesn't want to proceed with this tool use.", error: true, extra: #""toolDenialKind":"user-rejected","#)
        ).first)
        #expect(person.kind == .denied)
        #expect(person.denial == .person)
        #expect(person.tool == "Bash")

        let rule = try #require(await entries(
            Log.toolUse("t1", name: "Edit") + Log.result("t1", "denied", error: true, extra: #""toolDenialKind":"permission-rule","#)
        ).first)
        #expect(rule.denial == .rule)

        let older = try #require(await entries(
            Log.toolUse("t1", name: "Bash") + Log.result("t1", "The user doesn't want to proceed with this tool use.", error: true)
        ).first)
        #expect(older.denial == .person)
    }

    // MARK: Stopping by the person

    @Test("Остановка человеком не сбой", arguments: [
        Log.say() + Log.person("[Request interrupted by user]"),
        Log.toolUse("t1", name: "Bash") + Log.result("t1", "The user doesn't want to take this action right now.", error: true) + Log.person("[Request interrupted by user for tool use]"),
        Log.toolUse("t1", name: "Bash") + Log.result("t1", "[Request interrupted by user for tool use]", error: true),
        // The command died because of the stop, so its exit code says nothing about the command.
        Log.toolUse("t1", name: "Bash") + Log.result("t1", "Exit code 143", error: true) + Log.person("[Request interrupted by user for tool use]"),
    ])
    func personStops(log: String) async {
        #expect(await entries(log).isEmpty)
    }

    @Test("Отказ, за которым идёт остановка, остаётся отказом, а старые ошибки не исчезают")
    func stopKeepsTheRest() async {
        let denied = await entries(
            Log.toolUse("t1", name: "Bash") + Log.result("t1", "The user doesn't want to proceed with this tool use.", error: true, extra: #""toolDenialKind":"user-rejected","#) + Log.person("[Request interrupted by user for tool use]")
        )
        #expect(denied.map(\.kind) == [.denied])

        let earlier = await entries(
            Log.toolUse("t1", name: "Bash") + Log.result("t1", "Exit code 1", error: true) + Log.say("m2") + Log.person("[Request interrupted by user]")
        )
        #expect(earlier.map(\.kind) == [.toolError])
    }

    @Test("Вызов, отменённый из-за соседнего, не считается отдельным сбоем")
    func cascade() async {
        let found = await entries(
            Log.toolUse("t1", name: "Bash") + Log.toolUse("t2", name: "Read") + Log.result("t1", "Exit code 1", error: true) + Log.result("t2", "<tool_use_error>Cancelled: parallel tool call Bash(x) errored</tool_use_error>", error: true)
        )
        #expect(found.map(\.tool) == ["Bash"])
    }

    @Test("Агент, остановленный вместе с запуском, не сбой, и прерывание с его слов тоже")
    func stoppedRun() async throws {
        let folder = TempFolder()
        let final = #"{"status":"killed","error":"Error: Workflow aborted","workflowProgress":[{"type":"workflow_agent","agentId":"a1","state":"progress"},{"type":"workflow_agent","agentId":"a2","state":"error","error":"Error: Workflow aborted"},{"type":"workflow_agent","agentId":"a3","state":"done"}]}"#
        folder.write("projects/p/s1/workflows/wf_1.json", final)
        #expect(await history(folder).entries.isEmpty)
    }

    @Test("Остановкой считается только прерванный запуск: другое «aborted» остаётся сбоем со своим текстом")
    func otherAborts() async throws {
        let folder = TempFolder()
        folder.write("projects/p/s1/workflows/wf_1.json", #"{"status":"completed","workflowProgress":[{"type":"workflow_agent","agentId":"a1","state":"error","error":"The operation was aborted due to timeout"}]}"#)
        folder.write("projects/p/s1/workflows/wf_2.json", #"{"status":"failed","error":"Script aborted: x is missing","workflowProgress":[{"type":"workflow_agent","agentId":"a2","state":"done"}]}"#)
        let found = await history(folder).entries
        let agent = try #require(found.first { $0.runId == "wf_1" })
        #expect(agent.reason == .unknown)
        #expect(agent.rawText == "The operation was aborted due to timeout")
        #expect(found.first { $0.runId == "wf_2" }?.reason == .script)
    }

    @Test("Агент, упавший от своей причины до остановки запуска, остаётся сбоем")
    func fellBeforeTheStop() async throws {
        let folder = TempFolder()
        folder.write("projects/p/s1/workflows/wf_1.json", #"{"status":"killed","workflowProgress":[{"type":"workflow_agent","agentId":"a1","state":"error","error":"API Error: Your computer went to sleep mid-response."}]}"#)
        let found = await history(folder).entries
        #expect(found.map(\.reason) == [.sleep])
    }

    // MARK: Crashes

    @Test("Агент, закончивший ошибкой API, упал. Продолживший работу не падал")
    func agentCrash() async throws {
        let folder = TempFolder()
        folder.write("projects/p/s1/subagents/agent-a1.jsonl", Log.say("m1") + Log.apiError(text: "You've hit your session limit · resets 2pm"))
        folder.write("projects/p/s1/subagents/agent-a2.jsonl", Log.apiError("e2", text: "You've hit your session limit · resets 2pm") + Log.say("m2"))
        let found = await history(folder).entries
        let crash = try #require(found.first { $0.agentId == "a1" })
        #expect(crash.kind == .crash)
        #expect(crash.agents == ["a1"])
        #expect(crash.reason == .limit)
        #expect(found.first { $0.agentId == "a2" }?.kind == .apiError)
    }

    @Test("Сессия с ошибкой API в конце не падала: её можно продолжить")
    func mainAgentEndsInError() async throws {
        let found = await entries(Log.apiError(text: "You've hit your session limit · resets 2pm"))
        #expect(found.map(\.kind) == [.apiError])
    }

    @Test("Запуск: упавшие собраны в одну строку по причине, с названием и всего агентов")
    func workflowRows() async throws {
        let folder = TempFolder()
        let limit = #"{"type":"workflow_agent","agentId":"a%d","label":"step","state":"error","error":"You've hit your session limit · resets 2pm"}"#
        let agents = (1...3).map { limit.replacingOccurrences(of: "a%d", with: "a\($0)") }
        let net = #"{"type":"workflow_agent","agentId":"a4","state":"error","error":"Request timed out"}"#
        let done = #"{"type":"workflow_agent","agentId":"a5","label":"ok","state":"done"}"#
        let start = 1_793_900_000_000
        folder.write("projects/p/s1/workflows/wf_1.json", #"{"status":"completed","workflowName":"Миграция данных","startTime":\#(start),"durationMs":5000,"workflowProgress":[\#((agents + [net, done]).joined(separator: ","))]}"#)
        // The end of a failed agent's transcript is the same failure and must not count twice, while its earlier troubles stay.
        folder.write("projects/p/s1/subagents/workflows/wf_1/agent-a1.jsonl", Log.toolUse("t1", name: "Read") + Log.result("t1", "<tool_use_error>File does not exist.</tool_use_error>", error: true) + Log.apiError(text: "You've hit your session limit · resets 2pm"))
        folder.write("projects/p/s1.jsonl", Log.say())

        let found = await history(folder).entries
        let limitRow = try #require(found.first { $0.kind == .crash && $0.reason == .limit })
        #expect(limitRow.count == 3)
        #expect(limitRow.total == 5)
        #expect(limitRow.title == "Миграция данных")
        #expect(Set(limitRow.agents) == ["a1", "a2", "a3"])
        #expect(limitRow.resets == "2pm")
        #expect(limitRow.project == "shop-api")
        #expect(limitRow.at == Date(timeIntervalSince1970: 1_793_900_005))
        #expect(found.first { $0.kind == .crash && $0.reason == .network }?.count == 1)
        #expect(!found.contains { $0.kind == .apiError })
        let tool = try #require(found.first { $0.kind == .toolError })
        #expect(tool.title == "step")
    }

    @Test("Агент, упавший в прошлой попытке, есть только в журнале, и он тоже упал, один раз и со своими токенами")
    func fellInAnEarlierAttempt() async throws {
        let folder = TempFolder()
        let run = "projects/p/s1/subagents/workflows/wf_1"
        folder.write("\(run)/journal.jsonl", [
            #"{"type":"started","key":"k1","agentId":"a1","label":"one"}"#,
            #"{"type":"failed","key":"k1","agentId":"a1"}"#,
            #"{"type":"started","key":"k2","agentId":"a2","label":"two"}"#,
            #"{"type":"result","key":"k2","agentId":"a2"}"#,
        ].joined(separator: "\n") + "\n")
        folder.write("\(run)/agent-a1.jsonl", Log.apiError(text: "You've hit your session limit · resets 2pm"))
        folder.write("projects/p/s1/workflows/wf_1.json", #"{"status":"completed","workflowProgress":[{"type":"workflow_agent","agentId":"a2","state":"done"}]}"#)

        let index = LossIndex(cacheFile: nil, timeZone: utc)
        await index.update(roots: [ClaudePaths(root: folder.url)])
        let found = await index.history(live: []).entries
        let crash = try #require(found.first { $0.kind == .crash })
        #expect(crash.reason == .limit)
        #expect(crash.agents == ["a1"])
        #expect(crash.count == 1)
        #expect(crash.total == 2)
        #expect(!found.contains { $0.kind == .apiError })

        let tokens = [TokenRecord(sessionId: "s1", agentId: "a1", day: "2026-11-05", usage: TokenUsage(input: 70))]
        #expect(await index.book(period: .all, tokens: tokens, live: [], now: Date()).lostTokens == 70)
    }

    @Test("Агент, который не успел появиться, в итоге без номера, а в журнале с пустым номером, и считается один раз")
    func agentThatNeverStarted() async throws {
        let folder = TempFolder()
        let failed = #"{"type":"failed","key":"k%d","agentId":""}"#
        folder.write("projects/p/s1/subagents/workflows/wf_1/journal.jsonl", (1...3).map { failed.replacingOccurrences(of: "%d", with: "\($0)") }.joined(separator: "\n") + "\n")
        let entry = #"{"type":"workflow_agent","label":"step","state":"error","error":"Cannot create agent worktree","promptPreview":"SECRET-PROMPT"}"#
        folder.write("projects/p/s1/workflows/wf_1.json", #"{"status":"completed","workflowProgress":[\#([entry, entry, entry].joined(separator: ","))]}"#)
        let found = await history(folder).entries
        #expect(found.count == 1)
        let row = try #require(found.first)
        #expect(row.reason == .unknown)
        #expect(row.count == 3)
        #expect(row.total == 3)
        #expect(!String(describing: found).contains("SECRET"))
    }

    @Test("В остановленном запуске агент только из журнала и без своей ошибки остановлен, а с ошибкой упал")
    func journalOnlyInStoppedRun() async throws {
        let folder = TempFolder()
        let run = "projects/p/s1/subagents/workflows/wf_1"
        folder.write("\(run)/journal.jsonl", [
            #"{"type":"failed","key":"k1","agentId":"a1"}"#,
            #"{"type":"failed","key":"k2","agentId":"a2"}"#,
            #"{"type":"result","key":"k3","agentId":"a3"}"#,
        ].joined(separator: "\n") + "\n")
        folder.write("\(run)/agent-a1.jsonl", Log.say("m1"))
        folder.write("\(run)/agent-a2.jsonl", Log.apiError(code: "server_error", text: "API Error: Can't reach the API server"))
        folder.write("projects/p/s1/workflows/wf_1.json", #"{"status":"killed","workflowProgress":[{"type":"workflow_agent","agentId":"a3","state":"done"}]}"#)
        let crashes = await history(folder).entries.filter { $0.kind == .crash }
        #expect(crashes.map(\.agents) == [["a2"]])
        #expect(crashes.map(\.reason) == [.network])
    }

    @Test("Запуск без итога: упавшие считаются сразу, работающие пропали, только если сессии больше нет")
    func runWithoutResult() async throws {
        let folder = TempFolder()
        let journal = [
            #"{"type":"started","key":"k1","agentId":"a1","label":"one"}"#,
            #"{"type":"failed","key":"k1","agentId":"a1"}"#,
            #"{"type":"started","key":"k2","agentId":"a2","label":"two"}"#,
            #"{"type":"started","key":"k3","agentId":"a3","label":"three"}"#,
            #"{"type":"result","key":"k3","agentId":"a3"}"#,
        ].joined(separator: "\n") + "\n"
        folder.write("projects/p/s1/subagents/workflows/wf_1/journal.jsonl", journal)
        folder.write("projects/p/s1/subagents/workflows/wf_1/agent-a1.jsonl", Log.apiError(code: "server_error", text: "API Error: Can't reach the API server"))

        let index = LossIndex(cacheFile: nil, timeZone: utc)
        await index.update(roots: [ClaudePaths(root: folder.url)])

        let alive = await index.history(live: ["s1"]).entries.filter { $0.kind == .crash }
        #expect(alive.map(\.reason) == [.network])

        let dead = await index.history(live: []).entries.filter { $0.kind == .crash }
        let closed = try #require(dead.first { $0.reason == .closed })
        #expect(closed.count == 1)
        #expect(closed.agents == ["a2"])
        #expect(closed.total == 3)
        #expect(dead.contains { $0.reason == .network })
    }

    @Test("Запуск из файла называется так, как записано при его старте")
    func runNamedAtLaunch() async throws {
        let folder = TempFolder()
        folder.write("projects/p/s1.jsonl", #"{"type":"user","cwd":"/x/shop-api","entrypoint":"cli","toolUseResult":{"runId":"wf_1","workflowName":"Миграция данных"},"message":{"content":"x"}}"# + "\n")
        folder.write("projects/p/s1/subagents/workflows/wf_1/journal.jsonl", #"{"type":"started","key":"k1","agentId":"a1"}"# + "\n")
        let found = try #require(await history(folder).entries.first { $0.reason == .closed })
        #expect(found.title == "Миграция данных")
        #expect(found.project == "shop-api")
        #expect(found.environment == .terminal)
    }

    @Test("Ошибка самого скрипта это одно падение с её текстом. Ошибка из-за агентов не считается ещё раз")
    func scriptError() async throws {
        let folder = TempFolder()
        folder.write("projects/p/s1/workflows/wf_1.json", #"{"status":"failed","error":"TypeError: x is not a function\nsecond line","workflowProgress":[{"type":"workflow_agent","agentId":"a1","state":"done"}]}"#)
        folder.write("projects/p/s1/workflows/wf_2.json", #"{"status":"failed","error":"Error: agent stalled on all 6 attempts","workflowProgress":[{"type":"workflow_agent","agentId":"a2","state":"error","error":"stalled — no progress for 600000ms"}]}"#)
        let found = await history(folder).entries
        let script = try #require(found.first { $0.reason == .script })
        #expect(script.rawText == "TypeError: x is not a function")
        #expect(script.count == 1)
        #expect(script.agents.isEmpty)
        #expect(found.filter { $0.runId == "wf_2" }.map(\.reason) == [.stall])
    }

    @Test("Неизвестная причина сохраняет свой текст, а известная нет")
    func rawText() async throws {
        let folder = TempFolder()
        folder.write("projects/p/s1/workflows/wf_1.json", #"{"status":"completed","workflowProgress":[{"type":"workflow_agent","agentId":"a1","state":"error","error":"Cannot create agent worktree\nmore"},{"type":"workflow_agent","agentId":"a2","state":"error","error":"Request timed out"}]}"#)
        let found = await history(folder).entries
        #expect(found.first { $0.reason == .unknown }?.rawText == "Cannot create agent worktree")
        #expect(found.first { $0.reason == .network }?.rawText == nil)
    }

    @Test("Итог старше журнала относится к прошлой попытке")
    func staleFinal() async throws {
        let folder = TempFolder()
        let final = folder.write("projects/p/s1/workflows/wf_1.json", #"{"status":"completed","workflowProgress":[{"type":"workflow_agent","agentId":"a1","state":"error","error":"Request timed out"}]}"#)
        folder.write("projects/p/s1/subagents/workflows/wf_1/journal.jsonl", #"{"type":"started","key":"k1","agentId":"a1"}"# + "\n")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-600)], ofItemAtPath: final.path)
        let found = await history(folder, live: ["s1"]).entries
        #expect(found.isEmpty)
    }

    @Test("Сессия, чей процесс исчез во время работы, упала. Простаивавшая и живая нет")
    func deadSessions() async throws {
        let folder = TempFolder()
        // A pid that cannot exist on macOS, whose limit is under a hundred thousand.
        folder.write("sessions/99999999.json", #"{"sessionId":"dead-busy","pid":99999999,"status":"busy","cwd":"/x/shop-api","entrypoint":"cli","statusUpdatedAt":1793900000000}"#)
        folder.write("sessions/99999998.json", #"{"sessionId":"dead-idle","pid":99999998,"status":"idle","cwd":"/x/shop-api"}"#)
        folder.write("sessions/99999997.json", #"{"sessionId":"dead-waiting","pid":99999997,"status":"waiting","cwd":"/x/shop-api"}"#)
        let own = ProcessInfo.processInfo.processIdentifier
        folder.write("sessions/\(own).json", #"{"sessionId":"alive","pid":\#(own),"status":"busy","cwd":"/x/shop-api"}"#)
        let found = await history(folder).entries
        #expect(found.map(\.sessionId) == ["dead-busy"])
        #expect(found.first?.reason == .closed)
        #expect(found.first?.at == Date(timeIntervalSince1970: 1_793_900_000))

        // Came back under the same id, so the person is already past it.
        #expect(await history(folder, live: ["dead-busy"]).entries.isEmpty)
    }

    @Test("Скрытые сессии самого Boris не считаются")
    func ownSessions() async throws {
        let folder = TempFolder()
        let own = BorisPaths.usageProbeFolder.path
        folder.write("projects/p/s1.jsonl", Log.apiError(text: "API Error: x").replacingOccurrences(of: "/x/shop-api", with: own))
        #expect(await history(folder).entries.isEmpty)
    }

    // MARK: Skills and the internet

    @Test("Вызовы считаются точно: повтор строки и копия в форке не прибавляют")
    func exactCalls() async throws {
        let folder = TempFolder()
        let skill = Log.toolUse("s1", name: "Skill", input: #"{"skill":"pdf"}"#)
        let search = Log.toolUse("w1", name: "WebSearch")
        let main = skill + skill + Log.toolUse("s2", name: "Skill", input: #"{"skill":"pdf"}"#) + Log.toolUse("s3", name: "Skill", input: #"{"skill":"xlsx"}"#)
            + search + search + Log.toolUse("f1", name: "WebFetch") + Log.toolUse("f2", name: "WebFetch") + Log.toolUse("b1", name: "Bash")
        folder.write("projects/p/s1.jsonl", main)
        folder.write("projects/p/s1/subagents/agent-fork.jsonl", main + Log.toolUse("f3", name: "WebFetch"))

        let index = LossIndex(cacheFile: nil, timeZone: utc)
        await index.update(roots: [ClaudePaths(root: folder.url)])
        let book = await index.book(period: .all, tokens: [], live: [], now: Date())
        #expect(book.skills.map(\.name) == ["pdf", "xlsx"])
        #expect(book.skills.map(\.calls) == [2, 1])
        #expect(book.skillCalls == 3)
        #expect(book.searches == 1)
        #expect(book.fetches == 3)
    }

    @Test("Токены оцениваются по размеру принесённого текста, один раз")
    func estimatedTokens() async throws {
        let folder = TempFolder()
        let page = String(repeating: "p", count: 4000)
        let main = Log.toolUse("s1", name: "Skill", input: #"{"skill":"pdf"}"#)
            + Log.result("s1", "Launching skill: pdf")
            + Log.skillText("s1", bytes: 8000)
            + Log.toolUse("f1", name: "WebFetch")
            + Log.result("f1", page)
            + Log.toolUse("w1", name: "WebSearch")
            + Log.result("w1", String(page.prefix(400)))
            + Log.toolUse("b1", name: "Bash")
            + Log.result("b1", String(repeating: "o", count: 100_000))
        folder.write("projects/p/s1.jsonl", main)
        folder.write("projects/p/s1/subagents/agent-fork.jsonl", main)

        let index = LossIndex(cacheFile: nil, timeZone: utc)
        await index.update(roots: [ClaudePaths(root: folder.url)])
        let book = await index.book(period: .all, tokens: [], live: [], now: Date())
        #expect(book.skillTokens == 2000)
        #expect(book.webTokens == 1100)
    }

    @Test("Вызовы и токены раскладываются по дням")
    func callsByDay() async throws {
        let folder = TempFolder()
        let today = Log.toolUse("f1", name: "WebFetch")
        let old = Log.toolUse("f2", name: "WebFetch").replacingOccurrences(of: "2026-11-05", with: "2026-09-01")
        folder.write("projects/p/s1.jsonl", old + today)
        let index = LossIndex(cacheFile: nil, timeZone: utc)
        await index.update(roots: [ClaudePaths(root: folder.url)])
        let now = try #require(ISO8601DateFormatter().date(from: "2026-11-05T18:00:00Z"))
        #expect(await index.book(period: .week, tokens: [], live: [], now: now).fetches == 1)
        #expect(await index.book(period: .all, tokens: [], live: [], now: now).fetches == 2)
    }

    // MARK: Lost tokens

    @Test("Потерянные токены это настоящий расход упавших агентов, и только их")
    func lostTokens() async throws {
        let folder = TempFolder()
        folder.write("projects/p/s1/subagents/agent-a1.jsonl", Log.say("m1") + Log.apiError(text: "You've hit your session limit · resets 2pm"))
        folder.write("projects/p/s1/subagents/agent-a2.jsonl", Log.say("m2"))
        let index = LossIndex(cacheFile: nil, timeZone: utc)
        await index.update(roots: [ClaudePaths(root: folder.url)])
        let tokens = [
            TokenRecord(sessionId: "s1", agentId: "a1", day: "2026-11-05", usage: TokenUsage(input: 100, output: 20)),
            TokenRecord(sessionId: "s1", agentId: "a1", day: "2026-11-04", model: "other", usage: TokenUsage(cacheRead: 3)),
            TokenRecord(sessionId: "s1", agentId: "a2", day: "2026-11-05", usage: TokenUsage(input: 5000)),
            TokenRecord(sessionId: "s1", day: "2026-11-05", usage: TokenUsage(input: 7000)),
        ]
        let book = await index.book(period: .all, tokens: tokens, live: [], now: Date())
        #expect(book.lostTokens == 123)
        // Without the index there is nothing to say, which is not the same as zero.
        #expect(await index.book(period: .all, tokens: [], live: [], now: Date()).lostTokens == nil)
    }

    // MARK: What is kept

    @Test("Текст запросов, результатов и команд не попадает ни в кэш, ни в записи")
    func keepsNoText() async throws {
        let folder = TempFolder()
        let cache = folder.url.appendingPathComponent("support/losses.json")
        let log = Log.person("SECRET-PROMPT")
            + Log.toolUse("t1", name: "Bash", input: #"{"command":"SECRET-COMMAND"}"#)
            + Log.result("t1", "Exit code 1\nSECRET-OUTPUT", error: true)
            + Log.toolUse("f1", name: "WebFetch", input: #"{"url":"https://example.invalid/SECRET-URL"}"#)
            + Log.result("f1", "SECRET-PAGE")
            + Log.apiError(text: "API Error: SECRET-ERROR")
        folder.write("projects/p/s1.jsonl", log)
        folder.write("projects/p/s1/subagents/agent-a1.jsonl", Log.say("m1") + Log.apiError("e2", text: "API Error: SECRET-ERROR"))
        folder.write("projects/p/s1/subagents/agent-a1.meta.json", #"{"description":"SECRET-TITLE"}"#)

        let index = LossIndex(cacheFile: cache, timeZone: utc)
        await index.update(roots: [ClaudePaths(root: folder.url)])
        let history = await index.history(live: [])
        #expect(!history.entries.isEmpty)
        let stored = try String(contentsOf: cache, encoding: .utf8)
        #expect(!stored.contains("SECRET"))
        // The agent's name is shown, from its own file, without being stored.
        #expect(history.entries.contains { $0.title == "SECRET-TITLE" })
        let shown = history.entries.map { entry -> LossEntry in
            var entry = entry
            entry.title = nil
            return entry
        }
        #expect(!String(describing: shown).contains("SECRET"))
    }

    // MARK: Reading

    @Test("Дописанное читается с места чтения, в том числе после перезапуска и через границу чтения")
    func incremental() async throws {
        let folder = TempFolder()
        let cache = folder.url.appendingPathComponent("losses.json")
        folder.write("projects/p/s1.jsonl", Log.toolUse("t1", name: "Bash") + Log.retry("r1"))
        let first = LossIndex(cacheFile: cache, timeZone: utc)
        await first.update(roots: [ClaudePaths(root: folder.url)])
        #expect(await first.history(live: []).entries.first?.recovered == nil)

        // The tool's name, the open retry and what is awaited all have to survive the restart.
        folder.append("projects/p/s1.jsonl", Log.retry("r2") + Log.say("m2") + Log.result("t1", "Exit code 1", error: true))
        let second = LossIndex(cacheFile: cache, timeZone: utc)
        await second.update(roots: [ClaudePaths(root: folder.url)])
        let found = await second.history(live: []).entries
        let retry = try #require(found.first { $0.kind == .retry })
        #expect(retry.count == 2)
        #expect(retry.recovered == true)
        #expect(found.first { $0.kind == .toolError }?.tool == "Bash")
    }

    @Test("Кэш можно удалить или испортить: всё строится заново")
    func disposableCache() async throws {
        let folder = TempFolder()
        let cache = folder.url.appendingPathComponent("losses.json")
        folder.write("projects/p/s1.jsonl", Log.apiError(text: "API Error: x") + Log.toolUse("f1", name: "WebFetch"))
        let first = LossIndex(cacheFile: cache, timeZone: utc)
        await first.update(roots: [ClaudePaths(root: folder.url)])
        let before = await first.history(live: [])
        #expect(FileManager.default.fileExists(atPath: cache.path))

        try FileManager.default.removeItem(at: cache)
        let rebuilt = LossIndex(cacheFile: cache, timeZone: utc)
        await rebuilt.update(roots: [ClaudePaths(root: folder.url)])
        #expect(await rebuilt.history(live: []) == before)

        folder.write("losses.json", "{not json")
        let afterDamage = LossIndex(cacheFile: cache, timeZone: utc)
        await afterDamage.update(roots: [ClaudePaths(root: folder.url)])
        #expect(await afterDamage.history(live: []) == before)
    }

    @Test("Лог, удалённый Claude, уходит из учёта, а его записи можно встретить снова")
    func deletedLog() async throws {
        let folder = TempFolder()
        let file = folder.write("projects/p/s1.jsonl", Log.apiError(text: "API Error: x") + Log.toolUse("f1", name: "WebFetch"))
        let index = LossIndex(cacheFile: nil, timeZone: utc)
        await index.update(roots: [ClaudePaths(root: folder.url)])
        #expect(await index.history(live: []).entries.count == 1)

        try FileManager.default.removeItem(at: file)
        await index.update(roots: [ClaudePaths(root: folder.url)])
        let empty = await index.history(live: [])
        #expect(empty.entries.isEmpty)
        #expect(empty.calls.isEmpty)

        folder.write("projects/p/s2.jsonl", Log.apiError(text: "API Error: x"))
        await index.update(roots: [ClaudePaths(root: folder.url)])
        #expect(await index.history(live: []).entries.count == 1)
    }

    @Test("Уход со страницы останавливает чтение: прочитанное сохранено, а в следующий раз читается только остальное")
    func stoppedReading() async throws {
        let folder = TempFolder()
        let cache = folder.url.appendingPathComponent("losses.json")
        for file in 0..<3 { folder.write("projects/p/s\(file).jsonl", Log.apiError("e\(file)", text: "API Error: x")) }
        let roots = [ClaudePaths(root: folder.url)]

        // Its own task, as a cancelled one stays cancelled. The page does the same by cancelling the reader.
        let stopped = LossIndex(cacheFile: cache, timeZone: utc)
        await Task {
            await stopped.update(roots: roots) { _ in withUnsafeCurrentTask { $0?.cancel() } }
        }.value

        let resumed = LossIndex(cacheFile: cache, timeZone: utc)
        #expect(await resumed.history(live: []).entries.count == 1)
        await resumed.update(roots: roots)
        #expect(await resumed.history(live: []).entries.map(\.id).sorted() == ["e0", "e1", "e2"])
    }

    @Test("Недописанная строка ждёт конца записи")
    func unfinishedLine() async {
        let folder = TempFolder()
        let line = Log.apiError(text: "API Error: x")
        folder.write("projects/p/s1.jsonl", String(line.prefix(40)))
        let index = LossIndex(cacheFile: nil, timeZone: utc)
        await index.update(roots: [ClaudePaths(root: folder.url)])
        #expect(await index.history(live: []).entries.isEmpty)
        folder.append("projects/p/s1.jsonl", String(line.dropFirst(40)))
        await index.update(roots: [ClaudePaths(root: folder.url)])
        #expect(await index.history(live: []).entries.count == 1)
    }
}

/// The numbers here were counted by a separate pass in Python over the fixture files, with its own rules, not by this code.
@Suite("Потери на настоящих запусках")
struct LossFixtureTests {
    private func book() async throws -> LossBook {
        let folder = TempFolder()
        let paths = try Fixtures.world(into: folder)
        let index = LossIndex(cacheFile: nil)
        await index.update(roots: [paths])
        return await index.book(period: .all, tokens: [], live: [], now: Date())
    }

    @Test("Причины падений совпадают с независимым подсчётом и с эталоном всего приложения, главная это лимит")
    func reasons() async throws {
        let book = try await book()
        var histogram: [String: Int] = [:]
        for row in book.reasons { histogram[row.reason.rawValue] = row.count }
        #expect(histogram == ["limit": 606, "stall": 17, "network": 19, "closed": 5, "sleep": 4, "script": 1])
        #expect(book.crashed == 652)
        #expect(book.reasons.first?.reason == .limit)

        // The other screens must tell the same story. The golden file knows no stalls by name, and neither closed Claude Code nor a broken script, which are not failed agents there.
        let golden = try Fixtures.expected().failureClass
        #expect(histogram["limit"] == golden["limit"])
        #expect(histogram["network"] == golden["network"])
        #expect(histogram["sleep"] == golden["sleep"])
        #expect(histogram["stall"] == golden["unknown"])
    }

    @Test("От семи остановленных запусков остаются только трое упавших сами по себе, а 28 работавших не считаются")
    func stoppedRuns() async throws {
        let folder = TempFolder()
        let paths = try Fixtures.world(into: folder)
        let stopped = HistoryReader.finishedRuns(paths: paths, since: .distantPast).filter { $0.run.status == .stopped }
        #expect(stopped.count == 7)
        #expect(stopped.reduce(0) { $0 + $1.run.agents.filter { $0.state == .running }.count } == 28)

        let index = LossIndex(cacheFile: nil)
        await index.update(roots: [paths])
        let ids = Set(stopped.map(\.run.runId))
        let rows = await index.history(live: []).entries.filter { $0.kind == .crash && ids.contains($0.runId ?? "") }
        #expect(rows.reduce(0) { $0 + $1.count } == 3)
        #expect(rows.filter { $0.reason == .sleep }.reduce(0) { $0 + $1.count } == 2)
        #expect(rows.filter { $0.reason == .network }.reduce(0) { $0 + $1.count } == 1)
    }
}
