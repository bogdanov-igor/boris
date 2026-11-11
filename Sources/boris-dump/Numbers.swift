#if DEBUG
import BorisCore
import BorisData
import Foundation

/// `boris-dump numbers`: the counts the pages must agree on, side by side, to hold against a count made some other way.
/// Only counts and the first letters of ids are printed: no names, folders or text.
enum NumbersDump {
    static func run(paths: ClaudePaths, others: @escaping @Sendable () -> [ClaudePaths]) async {
        let now = Date()
        let roots = [paths] + others()
        let engine = WorkEngine(paths: paths, others: others) { _ in }
        let output = await engine.scanOnce()
        let past = await engine.pastSessions()
        let all = ProjectBook.sessions(work: output.model, past: past, logsReadAt: now)
        let index = TokenIndex(cacheFile: BorisPaths.tokenIndex)
        await index.update(roots: roots)
        let records = await index.records()
        let book = TokenBook(records: records, now: now)
        let lossIndex = LossIndex(cacheFile: BorisPaths.support.appendingPathComponent(LossIndex.cacheName))
        await lossIndex.update(roots: roots)
        let live = Set(output.model.sessions.filter(\.state.isCurrent).map(\.id))
        let history = await lossIndex.history(live: live)

        print("sessions: live \(output.model.sessions.count), from the logs \(past.count), on the pages \(all.count)")

        // 1. The period.
        for (name, period, lossPeriod) in [("7 days", WorkPeriod.week, LossPeriod.week), ("30 days", .month, .month)] {
            let projects = ProjectBook.summaries(sessions: all, tokens: records, filter: ProjectFilter(period: period), now: now)
            let losses = LossBook(history: history, period: lossPeriod, agentTokens: [:], now: now)
            print("1. \(name): projects' failures \(projects.reduce(0) { $0 + $1.failures }), losses' failed agents \(losses.crashed)")
        }

        // 2. A running session's page against what its log holds.
        for session in output.model.sessions where session.state.isCurrent {
            let logged = past.first { $0.id == session.id }
            let shown = all.first { $0.id == session.id }
            print("2. running \(session.id.prefix(8)): scan \(counts(session)); logs \(counts(logged)); page \(counts(shown))")
        }

        // 3. One failure, three counts: losses, projects, notifications.
        let crashes = history.entries.filter { $0.kind == .crash }
        var lossBySession: [String: Int] = [:]
        for entry in crashes { lossBySession[entry.sessionId, default: 0] += entry.count }
        var differ = 0
        var treeTotal = 0
        for session in all {
            treeTotal += session.failureCount
            if session.failureCount != lossBySession[session.id, default: 0] { differ += 1 }
        }
        let knownIds = Set(all.map(\.id))
        let lossTotal = crashes.filter { knownIds.contains($0.sessionId) }.reduce(0) { $0 + $1.count }
        print("3. all time: losses' failed agents \(lossTotal), projects' failures \(treeTotal), sessions where they differ \(differ)")
        func treeParts(_ failures: [WorkFailure]) -> String {
            var parts: [String: Int] = [:]
            for failure in failures {
                switch failure.source {
                case .session: parts["session cut off", default: 0] += failure.count
                case .sessionError: parts["session error", default: 0] += failure.count
                case .agent(let kind): parts["agent \(kind.rawValue)", default: 0] += failure.count
                case .workflow: parts["workflow", default: 0] += failure.count
                }
            }
            return parts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        }
        func lossParts(_ entries: [LossEntry]) -> String {
            var parts: [String: Int] = [:]
            for entry in entries {
                let part = entry.id.hasPrefix("session/") ? "session cut off" : entry.runId != nil ? "workflow" : entry.agentId != nil ? "agent" : "session error"
                parts[part, default: 0] += entry.count
            }
            return parts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        }
        print("3.   projects by source: \(treeParts(all.flatMap(\.failures)))")
        print("3.   losses by source: \(lossParts(crashes.filter { knownIds.contains($0.sessionId) }))")
        for session in all where session.failureCount != lossBySession[session.id, default: 0] {
            print("3.   \(session.id.prefix(8)) \(session.state.rawValue) live \(live.contains(session.id)): projects \(treeParts(session.failures)); losses \(lossParts(crashes.filter { $0.sessionId == session.id }))")
            for node in session.root.flattened where node.kind == .workflow {
                guard let details = node.workflow else { continue }
                let rows = crashes.filter { $0.runId == details.runId }
                let lost = details.fallenAgents.count + details.closedAgents.count + (details.scriptFailure == nil ? 0 : 1)
                if lost != rows.reduce(0, { $0 + $1.count }) {
                    print("3.     run \(details.runId.prefix(10)) \(details.status.key): fallen \(details.fallenAgents.count), closed \(details.closedAgents.count), script \(details.scriptFailure != nil); losses \(rows.map { "\($0.reason?.rawValue ?? "?") \($0.count)" }.joined(separator: ", "))")
                }
            }
        }
        let mainErrors = history.entries.filter { $0.kind == .apiError && $0.agentId == nil && knownIds.contains($0.sessionId) }
        print("3.   losses' api errors of main agents \(mainErrors.count), in sessions that ended on one \(mainErrors.filter { entry in all.first { $0.id == entry.sessionId }?.root.state == .failed }.count)")
        var tracker = RunTracker()
        var world = output.world
        world.sessions = []
        let runs = tracker.resolve(world) { _ in nil }
        var runDiffer = 0
        for run in runs where EventKind(status: run.status) != nil {
            let lost = crashes.filter { $0.runId == run.runId }.reduce(0) { $0 + $1.count }
            if run.failed != lost { runDiffer += 1 }
        }
        print("3. runs of the last day: \(runs.count), where a notification's failed agents differ from losses' \(runDiffer)")

        // 4. Projects as each page names them.
        let week = ProjectBook.summaries(sessions: all, tokens: records, filter: ProjectFilter(period: .week), now: now)
        let spend = book.report(.week).lines(.projects)
        let weekLosses = LossBook(history: history, period: .week, agentTokens: [:], now: now)
        let projectPaths = Set(week.compactMap(\.path))
        print("4. 7 days: projects \(week.count), with tokens \(week.filter { $0.inPeriod.total > 0 }.count); spend lines \(spend.count), of them not a project \(spend.filter { line in if case .project(let path?) = line.key { return !projectPaths.contains(path) } else { return false } }.count)")
        let names = Set(week.compactMap(\.name))
        print("4. 7 days: losses' projects \(weekLosses.projects.count), of them not a project \(weekLosses.projects.filter { !projectPaths.contains($0) && !names.contains($0) }.count)")

        // 5. A plain agent that fell.
        let failedAgents = output.world.agents.filter { $0.state == .failed }
        print("5. plain agents of the last day \(output.world.agents.count), fallen \(failedAgents.count)")
        // Each fallen one as if it had been seen at work on the look before.
        var detector = EventDetector()
        let atWork = output.world.agents.map { agent -> AgentSnapshot in
            var agent = agent
            agent.state = .running
            agent.failure = nil
            return agent
        }
        _ = detector.detect(runs: [], sessions: output.world.sessions, usage: nil, now: now, agents: atWork)
        let told = detector.detect(runs: [], sessions: output.world.sessions, usage: nil, now: now, agents: output.world.agents)
        print("5. notifications for them: \(told.filter { $0.id.hasPrefix("agent|") }.count)")

        // 6. Workflow rows against their children.
        var files = 0
        var orphans = 0
        var rowsUnlikeFiles = 0
        var orphanKinds: [String: Int] = [:]
        // What each file spent, from the records: a workflow's files by agent, and the files beside the session by agent.
        var fileTokens: [String: Int] = [:]
        var plainTokens: [String: Int] = [:]
        for record in records {
            guard let agent = record.agentId else { continue }
            if record.runId != nil { fileTokens[agent, default: 0] += record.usage.total } else { plainTokens[agent, default: 0] += record.usage.total }
        }
        var rows = 0
        var rowsOff = 0
        var worst = 0.0
        for session in all {
            for node in session.root.flattened where node.kind == .workflow {
                guard let runId = node.workflow?.runId else { continue }
                rows += 1
                let agents = node.flattened.filter { $0.kind == .workflowAgent }
                let ids = Set(agents.flatMap { [$0.id] + $0.attemptIds })
                let onDisk = agentFiles(session: session.id, run: runId, roots: roots)
                files += onDisk.count
                orphans += onDisk.subtracting(ids).count
                for orphan in onDisk.subtracting(ids) {
                    var journal = JournalReader()
                    if let folder = runFolder(session: session.id, run: runId, roots: roots) { journal.read(folder.appendingPathComponent("journal.jsonl")) }
                    let last = journal.tally.agents.contains { $0.agentId == orphan }
                    let earlier = journal.tally.agents.contains { $0.earlierAgentIds.contains(orphan) }
                    orphanKinds["\(node.workflow?.status.key ?? "?") journal last \(last) earlier \(earlier) live \(live.contains(session.id))", default: 0] += 1
                }
                let row = book.spent(node: node)?.total ?? 0
                let children = agents.reduce(0) { $0 + (book.spent(node: $1)?.total ?? 0) }
                let filesTotal = onDisk.reduce(0) { $0 + (fileTokens[$1] ?? 0) }
                let continuedTotal = agents.filter(\.continued).reduce(0) { $0 + (plainTokens[$1.id] ?? 0) }
                if row != filesTotal + continuedTotal { rowsUnlikeFiles += 1 }
                if row != children {
                    rowsOff += 1
                    worst = max(worst, Double(abs(row - children)) / Double(max(row, children, 1)))
                }
            }
        }
        print("6. workflow rows \(rows), agent files \(files), files without a node \(orphans), rows unlike their children \(rowsOff), worst \(Int(worst * 100))%, rows unlike their files \(rowsUnlikeFiles)")

        for (kind, count) in orphanKinds.sorted(by: { $0.key < $1.key }) { print("6.   files without a node: \(kind): \(count)") }

        // 7. One agent, two files.
        var twice: [String: Int] = [:]
        for id in continuedAgents(roots: roots) {
            let node = all.lazy.flatMap(\.root.flattened).first { $0.id == id }
            twice[node.map { "\($0.kind.rawValue) \($0.state.rawValue)" } ?? "no node", default: 0] += 1
        }
        print("7. agents with two files: \(twice.map { "\($0.key) \($0.value)" }.sorted().joined(separator: ", "))")

        // 8. The number in an agent's row: it was the context whenever that was known, and spend otherwise.
        var agentRows = 0
        var contextRows = 0
        for session in all {
            for node in session.root.flattened where node.kind != .workflow && node.kind != .main {
                agentRows += 1
                if let context = node.contextTokens, context != book.spent(node: node)?.total { contextRows += 1 }
            }
        }
        print("8. agent rows \(agentRows), of them showing the context where spend differs \(contextRows)")

        // 9. The session page's failures against what Losses has for the session.
        var quiet = 0
        var quietRows = 0
        var unlike = 0
        let bySession = Dictionary(grouping: history.entries, by: \.sessionId)
        for session in all {
            let rows = bySession[session.id] ?? []
            let steps = rows.filter { $0.kind != .crash }
            let page = session.failureCount + steps.reduce(0) { $0 + $1.count }
            let losses = rows.reduce(0) { $0 + $1.count }
            if page == 0, !rows.isEmpty {
                quiet += 1
                quietRows += rows.count
            }
            if page != losses { unlike += 1 }
        }
        print("9. sessions saying «no failures» while Losses has rows for them: \(quiet), rows \(quietRows); sessions whose page total differs from Losses' \(unlike)")
    }

    private static func counts(_ session: WorkSession?) -> String {
        guard let session else { return "none" }
        let nodes = session.root.flattened
        let agents = nodes.filter { $0.kind != .workflow && $0.kind != .workflowAgent }.count
        let workflows = nodes.filter { $0.kind == .workflow }.count
        return "agents \(agents), workflows \(workflows), workflow agents \(nodes.filter { $0.kind == .workflowAgent }.count), failures \(session.failureCount)"
    }

    private static func names(in folder: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    }

    private static func runFolder(session: String, run: String, roots: [ClaudePaths]) -> URL? {
        for root in roots {
            for project in names(in: root.projects) {
                let folder = root.projects.appendingPathComponent(project).appendingPathComponent(session).appendingPathComponent("subagents/workflows/\(run)")
                if FileManager.default.fileExists(atPath: folder.path) { return folder }
            }
        }
        return nil
    }

    private static func agentFiles(session: String, run: String, roots: [ClaudePaths]) -> Set<String> {
        for root in roots {
            for project in names(in: root.projects) {
                let folder = root.projects.appendingPathComponent(project).appendingPathComponent(session).appendingPathComponent("subagents/workflows/\(run)")
                let found = names(in: folder).filter { $0.hasPrefix("agent-") && $0.hasSuffix(".jsonl") }
                if !found.isEmpty { return Set(found.map { String($0.dropFirst(6).dropLast(6)) }) }
            }
        }
        return []
    }

    /// Ids with a file of their own next to the session and another one in a workflow.
    private static func continuedAgents(roots: [ClaudePaths]) -> [String] {
        var result: [String] = []
        for root in roots {
            for project in names(in: root.projects) {
                let projectDir = root.projects.appendingPathComponent(project)
                for session in names(in: projectDir) where !session.hasSuffix(".jsonl") {
                    let subagents = projectDir.appendingPathComponent(session).appendingPathComponent("subagents")
                    let plain = Set(names(in: subagents).filter { $0.hasPrefix("agent-") && $0.hasSuffix(".jsonl") })
                    guard !plain.isEmpty else { continue }
                    let workflows = subagents.appendingPathComponent("workflows")
                    for run in names(in: workflows) where run.hasPrefix("wf_") {
                        for name in names(in: workflows.appendingPathComponent(run)) where plain.contains(name) {
                            result.append(String(name.dropFirst(6).dropLast(6)))
                        }
                    }
                }
            }
        }
        return result
    }
}
#endif
