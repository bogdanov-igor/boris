#if DEBUG
import BorisCore
import Foundation
import SwiftUI

/// Made-up feed records for looking at screens. Nothing here comes from real sessions.
struct DevFeed {
    var entries: [FeedEntry] = []
    var thinking: [FeedStore.Thinker] = []
    var names: [String: String] = [:]
    /// Steps shown open, as if the person had clicked on them.
    var opened: Set<String> = []
    var permissionMode: String?
}

extension DevData {
    @MainActor
    func feed(now: Date) -> DevFeed {
        guard self != .empty else { return DevFeed() }
        let long = self == .long
        func at(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }
        func use(_ log: inout ActivityLog, _ id: String, _ tool: String, _ input: ToolInput, ago: TimeInterval, took: TimeInterval? = 0.8, error: Bool = false, output: String? = nil) {
            log.apply(.toolUse(id: id, tool: tool, input: input, at: at(ago)))
            log.apply(.tokens(id: id, TokenUsage(input: 12, output: 340, cacheRead: 84_000, cacheWrite: 1_200)))
            if let took { log.apply(.toolResult(id: id, isError: error, text: output, at: at(ago - took))) }
        }

        let auth = long ? "/x/boris/src/a-folder-with-a-rather-long-name/another-folder-inside-it/a-file-with-a-name-so-long-that-it-cannot-possibly-fit-anywhere-on-one-line.swift" : "/x/boris/src/auth.swift"
        var main = ActivityLog()
        main.apply(.prompt(long ? String(repeating: "Проверь авторизацию и почини проверку срока токена, а потом пройдись по всем соседним файлам. ", count: 12) : "Проверь авторизацию и почини проверку срока токена.", at: at(300)))
        for index in 0..<12 {
            use(&main, "r\(index)", "Read", ToolInput(target: "/x/boris/src/part\(index).swift"), ago: 290 - Double(index), took: 0.4)
        }
        use(&main, "g1", "Grep", ToolInput(target: "isExpired", note: "/x/boris/src", parameters: [ToolParameter(name: "output_mode", value: "content"), ToolParameter(name: "path", value: "/x/boris/src"), ToolParameter(name: "pattern", value: "isExpired")]), ago: 270, took: 0.4)
        main.apply(.text(long ? String(repeating: "Срок токена проверяется после разбора подписи. ", count: 20) : "Срок токена проверяется после разбора подписи. Переставлю проверку в начало и добавлю тест на **просроченный** токен.", at: at(250)))
        use(&main, "t1", "Task", ToolInput(note: "Проверка кода", command: "Проверь правку авторизации."), ago: 240, took: nil)
        use(&main, "e1", "Edit", ToolInput(target: auth, oldText: "old", newText: "new"), ago: 200, took: 2)
        main.apply(.patch(id: "e1", [DiffHunk(oldStart: 40, newStart: 40, lines: [
            "     func check(_ token: Token) throws -> Result {",
            "-        if try verifySignature(token) {",
            "-            guard !token.isExpired else { return .expired }",
            "+        guard !token.isExpired else { return .expired }",
            "+        guard try verifySignature(token) else { return .invalid }",
        ] + (0..<14).map { "+        log(\"шаг \($0)\")" } + ["     }"])]))
        // A change that failed, in the long data set: it says why, and it has no counts.
        if long { use(&main, "e2", "Edit", ToolInput(target: auth, oldText: "guard token.isValid\nelse", newText: "guard token.isFresh"), ago: 170, took: 0.1, error: true, output: "String to replace not found in file.") }
        use(&main, "b0", "Bash", ToolInput(note: "Сборка", command: "swift build --product Boris", parameters: [ToolParameter(name: "description", value: "Сборка"), ToolParameter(name: "timeout", value: "120000")]), ago: 150, took: 3, error: true, output: "Exit code 1\nerror: cannot find 'verifySignature' in scope\nerror: fatal error encountered during compilation")
        use(&main, "b1", "Bash", ToolInput(note: "Запускает тесты", command: long ? "swift test --filter AuthTests --parallel --num-workers 4 --enable-code-coverage --very-long-flag-that-goes-on-and-on-and-on-without-end" : "swift test"), ago: 14, took: nil, output: nil)

        var review = ActivityLog()
        review.apply(.prompt("Проверь правку авторизации.", at: at(240)))
        use(&review, "h1", "Read", ToolInput(target: "/x/boris/src/session.swift"), ago: 120, took: 0.9)
        var finding = ActivityLog()
        use(&finding, "h2", "Grep", ToolInput(target: "isExpired", note: "/x/boris/src"), ago: 60, took: 0.3)

        var shop = ActivityLog()
        // A session of another day, in the long data set.
        if long { use(&shop, "s0", "Read", ToolInput(target: "/x/shop-api/schema.sql"), ago: 3 * 86400, took: 0.3) }
        use(&shop, "s1", "mcp__postgres__query", ToolInput(target: "postgres · query", command: "sql: select count(*) from orders"), ago: 2600, took: 0.8)
        use(&shop, "s2", "Bash", ToolInput(command: "npm run migrate"), ago: 2500, took: nil)
        var landing = ActivityLog()
        use(&landing, "l1", "Write", ToolInput(target: "/x/landing/index.html", newText: "<html>\n</html>\n"), ago: 2000, took: 0.6)
        landing.apply(.patch(id: "l1", [DiffHunk(oldStart: 1, newStart: 1, lines: (0..<12).map { "-<div>старое \($0)</div>" } + (0..<48).map { "+<div>новое \($0)</div>" })]))
        var audit = ActivityLog()
        use(&audit, "w1", "WebSearch", ToolInput(command: "swift-crypto advisories"), ago: 900, took: 2.1)
        use(&audit, "w2", "Skill", ToolInput(target: "swift-testing"), ago: 500, took: nil)
        audit.closeRunning()
        use(&audit, "w3", "Agent", ToolInput(note: "Проверка находки", command: "Проверь находку."), ago: 100, took: 0.2)
        var report = ActivityLog()
        use(&report, "c1", "Read", ToolInput(target: "/x/выручка-Q3.xlsx"), ago: 23, took: nil)

        let entries = SessionFeed.merged([
            SessionFeed.merged(sessionId: "b1", logs: [AgentLog(agentId: nil, log: main), AgentLog(agentId: "code-review", log: review), AgentLog(agentId: "finding", log: finding), AgentLog(agentId: "audit", log: audit)]),
            SessionFeed.merged(sessionId: "a1", logs: [AgentLog(agentId: nil, log: shop)]),
            SessionFeed.merged(sessionId: "d1", logs: [AgentLog(agentId: nil, log: landing)]),
            SessionFeed.merged(sessionId: "c1", logs: [AgentLog(agentId: nil, log: report)]),
        ])
        return DevFeed(
            entries: entries,
            thinking: [FeedStore.Thinker(sessionId: "b1", agentId: "finding")],
            names: ["code-review": "Проверка кода", "finding": "Проверка находки", "audit": long ? "Аудит зависимостей со всеми подробностями и длинным названием · Поиск" : "Аудит зависимостей · Поиск"],
            opened: ["e1"],
            permissionMode: "acceptEdits"
        )
    }
}

/// The feed on its own, for the screens the session page will hold.
@MainActor
enum DevFeedScreens {
    private static func session(_ model: AppModel, id: String = "b1") -> WorkSession {
        model.work.sessions.first { $0.id == id } ?? WorkSession(id: "none", state: .finished, root: WorkNode(id: "none", kind: .main, state: .finished))
    }

    /// - Parameter id: "a1" is the session waiting for the person.
    static func feed(_ model: AppModel, id: String = "b1") -> AnyView {
        AnyView(SessionFeedView(model: model, session: session(model, id: id)).background(Palette.window).foregroundStyle(Palette.text1))
    }

    static func changes(_ model: AppModel) -> AnyView {
        AnyView(
            SessionChangesView(model: model, session: session(model))
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(Palette.window)
                .foregroundStyle(Palette.text1)
        )
    }

    /// The type filter on, as on the board.
    static func commands(_ model: AppModel) -> AnyView {
        AnyView(ActivityPage(model: model, type: .command).background(Palette.window).foregroundStyle(Palette.text1))
    }

    static func diff(_ model: AppModel) -> AnyView {
        let store = FeedStore.forSession(session(model), model: model)
        let edits = store.entries.filter { $0.step?.isChange == true && $0.step?.state != .failed }
        return AnyView(DiffSheet(title: "src/auth.swift", entries: edits, store: store))
    }
}
#endif
