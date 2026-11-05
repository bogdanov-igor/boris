#if DEBUG
import BorisCore
import Foundation

/// Made-up failures for looking at the Losses page. Nothing here comes from real sessions.
extension DevData {
    func fillLosses(_ model: AppModel, now: Date) {
        guard self != .empty else {
            model.losses.showForSnapshot(LossHistory(), agentTokens: [:], now: now)
            return
        }
        let agents = (1...646).map { "agent-\($0)" }
        model.losses.showForSnapshot(lossHistory(agents: agents, now: now), agentTokens: Dictionary(uniqueKeysWithValues: agents.map { ($0, 6100) }), now: now)
    }

    private func lossHistory(agents: [String], now: Date) -> LossHistory {
        let long = self == .long
        let shop = long ? "/x/a-very-long-project-name-that-nobody-would-ever-want-to-type-by-hand-more-than-once" : "/x/shop-api"
        let migration = long ? "Миграция данных со всеми проверками, сверками и очень подробным отчётом для каждого отдела компании" : "Миграция данных"
        func entry(_ id: String, _ minutes: Double, _ kind: LossKind, cwd: String = shop, entrypoint: String = "claude-vscode", title: String? = nil) -> LossEntry {
            LossEntry(id: id, at: now.addingTimeInterval(-minutes * 60), kind: kind, sessionId: "session-\(id)", cwd: cwd, entrypoint: entrypoint, title: title)
        }

        var all = entry("c1", 5, .crash, title: migration)
        all.runId = "wf_1"
        all.count = 12
        all.total = 12
        all.agents = Array(agents.prefix(12))
        all.reason = .limit
        all.limit = .session
        all.resets = "6:40pm"

        var big = entry("c2", 3000, .crash, title: "Проверка данных")
        big.runId = "wf_2"
        big.count = 594
        big.total = 610
        big.agents = Array(agents.dropFirst(12).prefix(594))
        big.reason = .limit

        func crash(_ id: String, _ minutes: Double, _ count: Int, _ reason: LossReason, offset: Int, rawText: String? = nil) -> LossEntry {
            var row = entry(id, minutes, .crash, cwd: "/x/deploy-tools", entrypoint: "cli", title: "Сборка релиза")
            row.runId = "wf_\(id)"
            row.count = count
            row.total = 40
            row.agents = Array(agents.dropFirst(offset).prefix(count))
            row.reason = reason
            row.rawText = rawText
            return row
        }
        let unknownText = long
            ? "Cannot create agent worktree: not in a git repository, and no way around that was found after looking at everything that could be looked at"
            : "Cannot create agent worktree"
        let rest = [
            crash("c3", 2000, 16, .network, offset: 606),
            crash("c4", 2100, 9, .stall, offset: 622),
            crash("c5", 2200, 7, .api, offset: 631),
            crash("c6", 2300, 4, .sleep, offset: 638),
            crash("c7", 2400, 3, .script, offset: 642, rawText: "TypeError: x is not a function"),
            crash("c8", 2500, 1, .unknown, offset: 645, rawText: unknownText),
        ] + (long ? [crash("c9", 2600, 2, .closed, offset: 0)] : [])

        var overloaded = entry("a1", 12, .apiError, title: "Миграции")
        overloaded.agentId = "a1"
        overloaded.count = 41
        overloaded.reason = .api
        overloaded.problem = .overloaded
        overloaded.code = "server_error"
        overloaded.status = 529

        var cut = entry("k1", 48, .cut, cwd: "/x/deploy-tools", entrypoint: "cli", title: "Сборка сервера")
        cut.agentId = "k1"
        cut.count = 6
        cut.reason = .sleep

        var tool = entry("t1", 90, .toolError, cwd: "/x/boris", entrypoint: "cli", title: "Проверка кода")
        tool.agentId = "t1"
        tool.count = 73
        tool.tool = "Read"
        tool.toolFailure = .noFile

        var command = entry("t2", 95, .toolError, cwd: "/x/boris", entrypoint: "cli")
        command.tool = long ? "mcp__a-very-long-server-name-for-a-tool__and-an-equally-long-name-of-the-tool-itself" : "Bash"
        command.toolFailure = .exitCode
        command.toolCode = 1

        var retry = entry("r1", 180, .retry, title: "Миграции")
        retry.agentId = "r1"
        retry.count = 128
        retry.reason = .api
        retry.problem = .overloaded
        retry.recovered = true

        var denied = entry("d1", 260, .denied, cwd: "/x/boris", entrypoint: "cli")
        denied.count = 11
        denied.tool = "Bash"
        denied.denial = .person

        let day = StatsBook.dayKey(now)
        let skills = long
            ? [("a-skill-with-a-name-so-long-it-cannot-possibly-fit-in-this-narrow-column", 96), ("pdf", 58), ("xlsx", 37), ("docx", 23), ("pptx", 9), ("swift-testing", 5), ("code-review", 2)]
            : [("swift-testing", 96), ("pdf", 58), ("xlsx", 37), ("docx", 23)]
        var calls = skills.map { LossCalls(day: day, kind: .skill, name: $0.0, calls: $0.1, estimatedTokens: $0.1 * 2900) }
        calls.append(LossCalls(day: day, kind: .search, calls: 58, estimatedTokens: 120_000))
        calls.append(LossCalls(day: day, kind: .fetch, calls: 131, estimatedTokens: 260_000))
        return LossHistory(entries: [all, big] + rest + [overloaded, cut, tool, command, retry, denied], calls: calls)
    }
}
#endif
