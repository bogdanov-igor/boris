import BorisCore
import BorisData
import Foundation

// Prints what Boris sees right now, without any interface. The text of prompts, commands and results is never printed.
// `boris-dump` looks at the work, `boris-dump tokens` adds up the logs, `boris-dump losses` adds up what went wrong, using the cache in `BORIS_STATE_DIR` if it is set,
// `boris-dump load` shows the load on this Mac by group, and with a number takes that many readings 3 seconds apart,
// and `boris-dump limits` reads the limits. Money is never printed, only percent.
// `boris-dump cost [seconds]` runs the real engine with no window open and says what that costs once the first pass over the logs is over: CPU, disk and memory.
// `boris-dump activity [transcript]` says how each action in the logs is typed and what reading them costs. `boris-dump edits <session>` lists the changes of a session with their counts.
// `boris-dump past [environment]` lists the sessions in the logs, by their environment if one is named, with their actions and tokens as counts.

// A release build has no `BORIS_STATE_DIR`, so its caches would land in Boris's real folder without a word.
#if !DEBUG
if let stray = BorisPaths.checkVariable(in: ProcessInfo.processInfo.environment) {
    print("A release build knows no check modes and \(stray) is set, so it does not start.")
    exit(2)
}
#endif

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

/// `boris-dump sources`: what each source has, counts only. `BORIS_SOURCES_OFF=cursor,cowork` looks at it the way Boris would with those turned off.
func sources() async {
    let off = Set((ProcessInfo.processInfo.environment["BORIS_SOURCES_OFF"] ?? "").split(separator: ",").compactMap { SourceID(rawValue: String($0)) })
    let filter = SourceFilter(off: off)
    let roots = ([paths] + others()).filter(filter.reads(root:))
    print("off: \(off.map(\.rawValue).sorted())")
    print("roots read: \(roots.count), of them not this Mac's processes: \(roots.filter { !$0.processesAreHere }.count)")
    let live = roots.filter(\.processesAreHere).flatMap { SessionReader.read($0).sessions }.filter { SessionReader.isLive($0) }.map(filter.editors.identified)
    let shown = live.filter(filter.allows(session:))
    func count<T>(_ items: [T], by key: (T) -> String) -> String {
        Dictionary(grouping: items, by: key).map { "\($0.key) \($0.value.count)" }.sorted().joined(separator: ", ")
    }
    print("running sessions seen \(live.count): \(count(live) { SourceID($0.environment)?.rawValue ?? "?" })")
    print("running sessions shown \(shown.count), hidden \(live.count - shown.count)")
    let index = TokenIndex(cacheFile: nil)
    await index.update(roots: roots, filter: filter)
    let records = await index.records()
    let bySource = Dictionary(grouping: records) { SourceID(entrypoint: $0.entrypoint)?.rawValue ?? "?" }.mapValues { $0.reduce(0) { $0 + $1.usage.total } }
    print("tokens by source: \(bySource.map { "\($0.key) \($0.value)" }.sorted().joined(separator: ", "))")
    print("sessions in token records: \(Set(records.map(\.sessionId)).count)")
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

func typed(_ tools: [String: Int]) {
    for (tool, count) in tools.sorted(by: { $0.value > $1.value }) {
        print("  \(WorkAction(tool: tool).rawValue.padding(toLength: 11, withPad: " ", startingAt: 0)) \(tool) \(count)")
    }
}

/// One transcript, for a look at an older log.
func activity(transcript: URL) {
    var reader = ActivityReader(window: UInt64.max / 2)
    reader.read(transcript)
    var byTool: [String: Int] = [:]
    for item in reader.log.items {
        if case .step(let step) = item { byTool[step.tool, default: 0] += 1 }
    }
    typed(byTool)
}

/// How much memory this process holds right now, in megabytes.
func footprint() -> Int {
    var usage = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &usage) { pointer in
        pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
    }
    return result == 0 ? Int(usage.ri_phys_footprint) / (1024 * 1024) : 0
}

/// Reads every session the way the Activity page does, and counts instead of showing.
func activity() async {
    let engine = WorkEngine(paths: paths, others: others) { _ in }
    let output = await engine.scanOnce()
    let clock = ContinuousClock()
    let began = clock.now
    var byTool: [String: Int] = [:]
    var files = 0
    var feeds: [[FeedEntry]] = []
    var readers: [String: SessionFeedReader] = [:]
    for session in output.model.sessions {
        guard let transcript = await engine.sessionTranscript(session.id) else { continue }
        var reader = SessionFeedReader(window: 512 * 1024)
        reader.read(transcript: transcript)
        let logs = reader.logs { _ in false }
        files += logs.count
        feeds.append(SessionFeed.merged(sessionId: session.id, logs: logs))
        readers[session.id] = reader
    }
    let first = clock.now - began
    let merged = SessionFeed.merged(feeds)
    let secondBegan = clock.now
    for session in output.model.sessions {
        guard let transcript = await engine.sessionTranscript(session.id) else { continue }
        readers[session.id]?.read(transcript: transcript)
    }
    print("sessions \(feeds.count), files \(files), records \(feeds.reduce(0) { $0 + $1.count }), first read \(first), next read \(clock.now - secondBegan), shown \(merged.count), memory held \(footprint()) MB")
    for entry in merged {
        if let step = entry.step { byTool[step.tool, default: 0] += 1 }
    }
    typed(byTool)
}

func edits(_ prefix: String) async {
    let engine = WorkEngine(paths: paths, others: others) { _ in }
    let output = await engine.scanOnce()
    let session = output.model.sessions.first { $0.id.hasPrefix(prefix) }?.id ?? prefix
    guard let transcript = await engine.sessionTranscript(session) else {
        print("no transcript for \(prefix)")
        return
    }
    var reader = SessionFeedReader()
    reader.read(transcript: transcript)
    for log in reader.logs(live: { _ in true }) {
        for item in log.log.items {
            guard case .step(let step) = item, step.isChange else { continue }
            let whole = reader.files(agentId: log.agentId).lazy.compactMap { ActivityReader.fullStep(step.id, in: $0) }.first
            print("\(step.tool) \(step.fileName ?? "?") · \(step.state) · +\(step.added.map(String.init) ?? "?") -\(step.removed.map(String.init) ?? "?") · hunks \(step.hunks.count) · cut \(step.isCut) · whole patch +\(whole?.hunks.flatMap(\.lines).filter { $0.hasPrefix("+") }.count ?? 0) -\(whole?.hunks.flatMap(\.lines).filter { $0.hasPrefix("-") }.count ?? 0), new text \(whole?.input.newText?.components(separatedBy: "\n").count ?? 0) lines · agent \(log.agentId?.prefix(8) ?? "main")")
        }
    }
}

/// What the engine costs with all windows closed. Nothing here says what the logs hold.
final class CostBox: @unchecked Sendable {
    private let lock = NSLock()
    private var outputs = 0
    private var version = 0

    func note(_ output: WorkEngine.Output) {
        lock.withLock {
            outputs += 1
            version = output.tokensVersion
        }
    }

    var seen: (outputs: Int, version: Int) { lock.withLock { (outputs, version) } }
}

func processCost() -> (cpu: Double, written: UInt64, read: UInt64, memory: Int, peak: Int) {
    var info = rusage_info_v4()
    _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) } }
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    return (cpu, info.ri_diskio_byteswritten, info.ri_diskio_bytesread, Int(info.ri_phys_footprint) / (1024 * 1024), Int(info.ri_lifetime_max_phys_footprint) / (1024 * 1024))
}

func cost(seconds: Int) async {
    let box = CostBox()
    let engine = WorkEngine(paths: paths, tokenCache: BorisPaths.tokenIndex, others: others) { box.note($0) }
    let began = Date()
    await engine.start()
    while box.seen.version == 0, Date().timeIntervalSince(began) < 500 { try? await Task.sleep(for: .milliseconds(200)) }
    print(String(format: "first pass: %.1f s, memory %d MB, peak %d MB", Date().timeIntervalSince(began), processCost().memory, processCost().peak))
    try? await Task.sleep(for: .seconds(10))
    let before = processCost()
    let outputs = box.seen.outputs
    try? await Task.sleep(for: .seconds(seconds))
    let after = processCost()
    let spent = Double(seconds)
    print(String(format: "%d s: CPU %.2f%% of one core, written %.1f KB/s, read %.1f KB/s, %d scans, memory %d MB, peak %d MB", seconds, (after.cpu - before.cpu) / spent * 100, Double(after.written - before.written) / 1024 / spent, Double(after.read - before.read) / 1024 / spent, box.seen.outputs - outputs, after.memory, after.peak))
    await engine.stop()
}

/// Which environments the logs hold, and with a name such as `cowork`, each session of that one. Names, folders and titles stay out.
func past(only: String?) async {
    let history = SessionHistory(paths: paths, others: others)
    let sessions = await history.sessions()
    let index = TokenIndex(cacheFile: BorisPaths.tokenIndex)
    await index.update(roots: [paths] + others())
    let book = TokenBook(records: await index.records(), now: Date())
    let byPlace = Dictionary(grouping: sessions) { $0.environment.map { "\($0)" } ?? "unknown" }
    for (place, group) in byPlace.sorted(by: { $0.key < $1.key }) {
        print("\(place): \(group.count) sessions")
        guard place == only else { continue }
        let engine = WorkEngine(paths: paths, others: others) { _ in }
        // The engine learns about the other folders on its first look.
        _ = await engine.scanOnce()
        for session in group {
            let applied = book.applied(to: WorkModel(projects: [WorkProject(path: nil, sessions: [session])])).sessions.first
            var actions = 0
            if let transcript = await engine.sessionTranscript(session.id) {
                var reader = ActivityReader(window: UInt64.max / 2)
                reader.read(transcript)
                actions = reader.log.items.filter { if case .step = $0 { true } else { false } }.count
            }
            print("  \(session.id.prefix(8)) · \(session.state.rawValue) · has name \(session.title != nil) · project \(session.projectPath != nil) · model \(session.root.model ?? "no data") · actions \(actions) · tokens \(applied?.root.tokens.map { String($0.total) } ?? "no data")")
        }
    }
}

if arguments.first == "sources" {
    await sources()
} else if arguments.first == "tokens" {
    await tokens()
} else if arguments.first == "past" {
    await past(only: arguments.dropFirst().first)
} else if arguments.first == "load" {
    await load()
} else if arguments.first == "losses" {
    await losses()
} else if arguments.first == "limits" {
    limits()
} else if arguments.first == "cost" {
    await cost(seconds: arguments.dropFirst().first.flatMap(Int.init) ?? 60)
} else if arguments.first == "activity", arguments.count > 1 {
    activity(transcript: URL(fileURLWithPath: arguments[1]))
} else if arguments.first == "activity" {
    await activity()
} else if arguments.first == "edits", arguments.count > 1 {
    await edits(arguments[1])
} else {
    await work()
}
