import BorisCore
import BorisData
import Foundation

// Prints what Boris sees right now, without any interface. The text of prompts, commands and results is never printed.
// `boris-dump` looks at the work, `boris-dump tokens` adds up the logs, `boris-dump losses` adds up what went wrong, using the cache in `BORIS_STATE_DIR` if it is set,
// `boris-dump load` shows the load on this Mac by group, and with a number takes that many readings 3 seconds apart,
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

func losses() async {
    let index = LossIndex(cacheFile: BorisPaths.support.appendingPathComponent(LossIndex.cacheName))
    let roots = [paths] + others()
    let clock = ContinuousClock()
    let began = clock.now
    await index.update(roots: roots)
    let first = clock.now - began
    let secondBegan = clock.now
    await index.update(roots: roots)
    let second = clock.now - secondBegan
    let tokens = TokenIndex(cacheFile: BorisPaths.tokenIndex)
    await tokens.update(roots: roots)
    let live = Set(roots.filter(\.processesAreHere).flatMap { SessionReader.read($0).sessions }.filter { SessionReader.isLive($0) }.map(\.sessionId))
    print("update \(first), next update \(second)")
    for period in LossPeriod.allCases {
        let book = await index.book(period: period, tokens: await tokens.records(), live: live, now: Date())
        print("\(period.rawValue): \(book.entries.count) rows")
        print("  kinds: \(LossKind.allCases.map { "\($0.rawValue) \(book.kinds[$0] ?? 0)" }.joined(separator: ", "))")
        print("  reasons: \(book.reasons.map { "\($0.reason.rawValue) \($0.count)" }.joined(separator: ", "))")
        print("  lost tokens \(book.lostTokens.map(String.init) ?? "unknown")")
        print("  skills \(book.skillCalls), tokens \(book.skillTokens); searches \(book.searches), page loads \(book.fetches), tokens \(book.webTokens)")
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

func load() async {
    // Only the session files: the engine would add up the logs in the background, and this very process would show up as a loaded Boris.
    let sessions = ([paths] + others().filter(\.processesAreHere))
        .flatMap { SessionReader.read($0).sessions }
        .filter { SessionReader.isLive($0) }
    let pids = Dictionary(sessions.map { ($0.sessionId, $0.pid) }) { first, _ in first }
    let sampler = MacLoadSampler(logRoots: { ([paths] + others()).map(\.projects) })
    func show(_ title: String, _ split: LoadSplit?) {
        guard let split else { return print("\(title): no data") }
        print("\(title): \(split.points)% = " + split.parts.map { "\($0.group.rawValue) \($0.points)" }.joined(separator: " + "))
    }
    _ = await sampler.read(LoadRequest(sessions: pids, restart: true))
    for _ in 0..<max(arguments.dropFirst().first.flatMap(Int.init) ?? 1, 0) {
        try? await Task.sleep(for: .seconds(3))
        let load = await sampler.read(LoadRequest(sessions: pids))
        show("cpu", load.cpu)
        show("memory", load.memory)
        print("disk: \(load.diskPercent.map { "\(Int($0))%" } ?? "no data"), Claude logs: \(load.claudeLogs.map { WorkFormat.byteCount($0) } ?? "no data")")
        for session in sessions {
            let place = session.environment.map { "\($0)" } ?? "?"
            let taken = load.sessions[session.sessionId].map { "cpu \(String(format: "%.1f", $0.cpu))%, memory \(WorkFormat.byteCount($0.memory))" } ?? "no process"
            print("  session \(session.sessionId.prefix(8)) · \(place) · \(taken)")
        }
    }
}

if arguments.first == "tokens" {
    await tokens()
} else if arguments.first == "load" {
    await load()
} else if arguments.first == "losses" {
    await losses()
} else if arguments.first == "limits" {
    limits()
} else {
    await work()
}
