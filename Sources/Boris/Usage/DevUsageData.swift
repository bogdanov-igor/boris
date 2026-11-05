#if DEBUG
import BorisCore
import BorisData
import Foundation

/// Made-up spend for looking at the usage page. Nothing here comes from real logs.
@MainActor
enum DevUsageData {
    static func dayKey(_ date: Date) -> String {
        UsageModel.dayKey(date)
    }

    static func book(for data: DevData, now: Date) -> TokenBook {
        guard data != .empty else { return TokenBook(records: [], now: now) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let projects = data == .long
            ? ["/x/a-very-long-project-name-that-nobody-would-ever-want-to-type-by-hand-more-than-once", "/x/shop-api", "/x/boris"]
            : ["/x/shop-api", "/x/boris", "/x/landing"]
        let entrypoints = ["claude-vscode", "cli", "local-agent"]
        let models = data == .long
            ? ["claude-opus-5-5", "claude-sonnet-5-5", "some-gateway-model-with-a-long-and-unknown-name-v2"]
            : ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"]
        let shape = [1.12, 0.86, 1.45, 2.03, 0.64, 1.27, 1.84, 0.4, 0, 0.9, 1.6, 0.2, 1.1, 0.7]
        var records: [TokenRecord] = []
        for back in 0..<54 {
            guard let date = Calendar.current.date(byAdding: .day, value: -back, to: now) else { continue }
            let amount = Int(shape[back % shape.count] * 1_000_000)
            guard amount > 0 else { continue }
            for index in projects.indices {
                let share = amount / (index + 2)
                records.append(TokenRecord(
                    sessionId: "s\(index)",
                    agentId: index == 2 ? "a\(index)" : nil,
                    runId: index == 2 && back % 2 == 0 ? "wf_\(index)" : nil,
                    cwd: projects[index],
                    entrypoint: entrypoints[index],
                    day: formatter.string(from: date),
                    model: models[index],
                    usage: TokenUsage(input: share / 90, output: share / 30, cacheRead: share * 8 / 10, cacheWrite: share / 10)
                ))
            }
        }
        return TokenBook(records: records, now: now)
    }

    /// The accounts and states the page has to get right, on invented data.
    @MainActor
    enum Scenario: String {
        case spendUltra, spendTeam, spendGateway, spendApiKey, spendExtraOff, spendExtraNoLimit, spendFilling, spendFailed, spendZero, spendAncient
        case spendProjects, spendModels, spendPlaces, spendAgents, spendToday, spendMonth, spendEverything

        func fill(_ model: AppModel, now: Date = Date()) {
            var world = model.world
            let week = UsageWindow(id: "seven_day", kind: .week, percent: 34, resetsAt: now.addingTimeInterval(4 * 86400))
            switch self {
            case .spendUltra:
                world.account = .signedIn
                world.usage = UsageSnapshot(fetchedAt: now.addingTimeInterval(-720), windows: [
                    week,
                    UsageWindow(id: "seven_day_opus", kind: .weekModel("Opus"), percent: 18),
                ], extra: .on(used: 12.4, limit: 50, currency: "USD"))
            case .spendTeam:
                world.account = .signedIn
                world.usage = UsageSnapshot(fetchedAt: now.addingTimeInterval(-720))
            case .spendGateway:
                world.account = .gateway
                world.usage = nil
            case .spendApiKey:
                world.account = .apiKey
                world.usage = nil
            case .spendExtraOff:
                world.account = .signedIn
                world.usage?.extra = .off
            case .spendExtraNoLimit:
                world.account = .signedIn
                world.usage?.extra = .on(used: 87.5, limit: nil, currency: "EUR")
            case .spendFilling:
                model.usage.showForSnapshot(book: nil, progress: WorkEngine.TokenProgress(done: 640, total: 1000))
            case .spendFailed:
                world.usage?.fetchedAt = now.addingTimeInterval(-(3 * 3600 + 12 * 60))
                model.usageRefresher.showForSnapshot(failed: true)
            case .spendZero:
                world.usage = UsageSnapshot(fetchedAt: now.addingTimeInterval(-60), windows: [
                    UsageWindow(id: "five_hour", kind: .fiveHour, percent: 0, resetsAt: now.addingTimeInterval(8000)),
                    UsageWindow(id: "seven_day", kind: .week, percent: 0),
                ], extra: .on(used: 0, limit: 50, currency: "USD"))
                model.usage.showForSnapshot(book: TokenBook(records: [], now: now))
            case .spendAncient:
                // The oldest log is much older than the period chosen, and from another year.
                let old = TokenRecord(sessionId: "s", day: "2024-03-25", model: "claude-3-5-haiku-20241022", usage: TokenUsage(input: 1000, output: 500))
                let recent = TokenRecord(sessionId: "s", day: DevUsageData.dayKey(now), model: "claude-sonnet-5-5", usage: TokenUsage(input: 2000, output: 300))
                model.usage.showForSnapshot(book: TokenBook(records: [old, recent], now: now))
                model.usage.period = .all
            case .spendProjects:
                model.usage.breakdown = .projects
            case .spendModels:
                model.usage.breakdown = .models
            case .spendPlaces:
                model.usage.breakdown = .environments
            case .spendAgents:
                model.usage.breakdown = .agents
            case .spendToday:
                model.usage.period = .today
            case .spendMonth:
                model.usage.period = .month
            case .spendEverything:
                model.usage.period = .all
            }
            model.showForSnapshot(work: model.work, world: world, today: model.today, mood: model.mood, outfit: model.outfit)
        }
    }
}
#endif
