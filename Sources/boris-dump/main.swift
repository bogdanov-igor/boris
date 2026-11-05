import BorisCore
import BorisData
import Foundation

// Prints what Boris sees right now, without any interface. The text of prompts, commands and results is never printed.
// `boris-dump` looks at the work, `boris-dump tokens` adds up the logs, using the cache in `BORIS_STATE_DIR` if it is set,
// and `boris-dump limits` reads the limits. Money is never printed, only percent.

let arguments = Array(CommandLine.arguments.dropFirst())
let paths = ClaudePaths.resolve()
let others: @Sendable () -> [ClaudePaths] = { ClaudeFolders.others(besides: paths) }

func tokens() async {
    let index = TokenIndex(cacheFile: BorisPaths.tokenIndex)
    let clock = ContinuousClock()
    let began = clock.now
    await index.update(roots: [paths] + others())
    let first = clock.now - began
    let secondBegan = clock.now
    await index.update(roots: [paths] + others())
    let records = await index.records()
    let total = records.reduce(TokenUsage()) { $0 + $1.usage }
    print("update \(first), next update \(clock.now - secondBegan), since \(await index.earliestDay() ?? "-")")
    print("total \(total.total): input \(total.input), output \(total.output), cache read \(total.cacheRead), cache write \(total.cacheWrite)")
    let byDay = Dictionary(grouping: records, by: \.day).mapValues { $0.reduce(0) { $0 + $1.usage.total } }
    for day in byDay.keys.sorted().suffix(5) { print("  \(day): \(byDay[day] ?? 0)") }
    let byModel = Dictionary(grouping: records, by: { $0.model ?? "?" }).mapValues { $0.reduce(0) { $0 + $1.usage.total } }
    for model in byModel.keys.sorted() {
        print("  \(model): \(byModel[model] ?? 0)\(PriceTable.price(for: model) == nil ? " (no price)" : "")")
    }
    let building = clock.now
    let book = TokenBook(records: records, now: Date())
    print("records \(records.count), book built in \(clock.now - building), all time ≈ $\(Int(book.report(.all).estimate.dollars))")
}

func limits() {
    guard let profile = UsageReader.profile(paths.profile, settings: paths.settings) else {
        print("profile: cannot be read")
        return
    }
    print("account: \(profile.account)")
    guard let usage = profile.usage else {
        print("limits: none reported")
        return
    }
    print("limits, fetched \(usage.fetchedAt.map { "\(Int(Date().timeIntervalSince($0) / 60)) min ago" } ?? "?"):")
    for window in usage.windows {
        print("  \(window.id): \(String(format: "%.1f", window.percent))%")
    }
    switch usage.extra {
    case .noData: print("extra: no data")
    case .off: print("extra: off")
    case .on(let used, let limit, _): print("extra: on, \(limit.map { String(format: "%.1f%% of the limit", used / $0 * 100) } ?? "no limit")")
    }
}

func describe(_ node: WorkNode, depth: Int) {
    let indent = String(repeating: "  ", count: depth + 2)
    var line = "\(indent)\(node.kind.rawValue) · \(node.state.rawValue)"
    if let type = node.agentType { line += " · \(type)" }
    if let step = node.step { line += " · now \(step.tool)\(step.fileName.map { " \($0)" } ?? "")" }
    if let context = node.contextTokens { line += " · context \(context)" }
    if let workflow = node.workflow { line += " · \(workflow.status.key) \(workflow.done)/\(workflow.total)" }
    if let failure = node.failure { line += " · failed: \(failure.failureClass.rawValue)" }
    print(line)
    for child in node.children { describe(child, depth: depth + 1) }
}

func work() async {
    let engine = WorkEngine(paths: paths, others: others) { _ in }
    // Current steps are read only while someone looks closely, and here someone does.
    await engine.setFocus(runs: [], lookingClosely: true)
    let output = await engine.scanOnce()
    print("working: \(output.model.isWorking), agents at work: \(output.model.workingAgents), waiting: \(output.model.waitingSessions.count)")
    for project in output.model.projects {
        print("\(project.name ?? "(no project)")")
        for session in project.sessions {
            let place = session.environment.map { "\($0)" } ?? "?"
            print("  session \(session.id.prefix(8)) · \(place) · \(session.state.rawValue)\(session.waitingFor.map { " (\($0))" } ?? "")")
            describe(session.root, depth: 0)
        }
    }
    if let usage = output.world.usage {
        let age = usage.fetchedAt.map { "\(Int(Date().timeIntervalSince($0) / 60)) min ago" } ?? "?"
        print("limits, fetched \(age):")
        for window in usage.windows {
            print("  \(window.id): \(String(format: "%.1f", window.percent))%")
        }
    }
    if !output.world.formatIssues.isEmpty { print("format issues: \(output.world.formatIssues)") }
    let plan = HookInstaller.Plan(helperPath: "/Applications/Boris.app/Contents/MacOS/boris-hook", permissions: false, permissionWait: 120)
    let hooks = HookConnection(wanted: false, status: HookInstaller.status(at: paths.settings, plan: plan))
    let connection = ConnectionStatus(world: output.world, hooks: hooks, hookState: output.hooks, hooksSince: Date(), now: Date())
    print("hooks: \(hooks), problems: \(connection.problems)")
}

if arguments.first == "tokens" {
    await tokens()
} else if arguments.first == "limits" {
    limits()
} else {
    await work()
}
