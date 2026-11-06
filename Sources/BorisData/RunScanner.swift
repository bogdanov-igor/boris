import Foundation
import BorisCore

/// Turns the folder into a snapshot of the world, reading as little as possible.
public actor RunScanner {
    public struct Config: Sendable {
        /// Older runs without a live session are left out.
        public var window: TimeInterval = 24 * 3600
        public var rediscoveryInterval: TimeInterval = 60
        public var finishedRecheckInterval: TimeInterval = 60
        public var tokensRefreshInterval: TimeInterval = 10
        public var focusRefreshInterval: TimeInterval = 1
        public var usageRefreshInterval: TimeInterval = 60
        public var finalGiveUpAfter: TimeInterval = 60
        /// How long an ended turn must stay the last thing written before an agent without a mark counts as finished.
        public var agentSettle: TimeInterval = 5
        public var titleRefreshInterval: TimeInterval = 60
        public var continuedAfter: TimeInterval = 2

        public init() {}
    }

    private struct RunCache {
        let runId: String
        let sessionId: String
        let sessionDir: URL
        let runDir: URL
        let finalURL: URL
        let scriptsDir: URL
        let parent: URL

        var journal = JournalReader()
        var journalModified: Date?
        var dirModified: Date?
        var finalModified: Date?
        var final: FinalReport?
        var finalBrokenSince: Date?
        var lastWrite: Date = .distantPast
        var scriptName: String?
        var scriptDescription: String?
        var phases: [String] = []
        var scriptRead = false
        var launchChecks = 0
        var cwd: String?
        var entrypoint: String?
        var cwdRead = false
        var stoppedByClaude = false
        var stopChecked = false
        var failures: [String: FailureInfo] = [:]
        var agentTypes: [String: String] = [:]
        var tokens: [String: (at: Date, tokens: Int, model: String?)] = [:]
        var steps: [String: StepBrief] = [:]
        /// Agents whose first record has been read for where they work, and those of them in a separate copy.
        var placesRead: Set<String> = []
        var places: [String: GitPlace] = [:]
        var lastChecked: Date = .distantPast
        var loaded = false

        var journalURL: URL { runDir.appendingPathComponent("journal.jsonl") }
    }

    public nonisolated let paths: ClaudePaths
    private let config: Config
    private var runs: [String: RunCache] = [:]
    private var dirty: Set<String> = []
    private var discoverNow = true
    private var lastDiscovery: Date = .distantPast
    private var usage: UsageSnapshot?
    private var account = ClaudeAccount.unknown
    /// The main agent's last known context and model. It does not change while a session is idle, so one read is enough then.
    private var usageModified: Date?
    private var usageChecked: Date = .distantPast
    private var focusRuns: Set<String> = []
    private var followSessions = false
    private var sessionFiles: [String: URL] = [:]
    private var meter = LiveTokenMeter()
    private var meteredRuns: [String: [URL]] = [:]
    /// Ordinary agents seen so far, so that one whose session has died can still be reported.
    private var singleAgents: [String: SingleAgent] = [:]
    private let startedAt: Date
    private let findOthers: @Sendable () -> [ClaudePaths]
    private var others: [ClaudePaths] = []
    private var unlisted: UnlistedSessions
    private var changedProjects: Set<String> = []
    private var titles: [String: (checked: Date, title: String?)] = [:]
    private var sessionTails: [String: (modified: Date?, tail: TranscriptReader.Tail)] = [:]
    private var coworkFiles: [String: (modified: Date?, file: CoworkSessionFile?)] = [:]
    private var coworkStamps: [URL: Date] = [:]

    /// - Parameter others: finds the other places Claude keeps files. Only `paths` is the source of usage limits.
    public init(paths: ClaudePaths, config: Config = Config(), others: @escaping @Sendable () -> [ClaudePaths] = { [] }) {
        self.paths = paths
        self.config = config
        self.findOthers = others
        let now = Date()
        self.startedAt = now
        self.unlisted = UnlistedSessions(startedAt: now)
    }

    private var roots: [ClaudePaths] { [paths] + others }

    /// What has to be watched for changes. The list grows when Claude starts using a new place.
    public func watchedFolders() -> [URL] {
        roots.flatMap { $0.processesAreHere ? [$0.projects, $0.sessions] : [$0.projects] }
    }

    public func markProject(_ folder: String) {
        changedProjects.insert(folder)
    }

    public func markDirty(runs ids: Set<String>) {
        dirty.formUnion(ids)
    }

    /// The usage cache has just been rewritten, so it is read at the next scan.
    public func markUsageChanged() {
        usageChecked = .distantPast
    }

    public func markDiscovery() {
        discoverNow = true
    }

    public func markDirty(session sessionId: String) {
        dirty.formUnion(runs.values.filter { $0.sessionId == sessionId }.map(\.runId))
    }

    public func runFolder(_ runId: String) -> URL? {
        runs[runId]?.runDir ?? singleAgents[runId]?.folder
    }

    /// Runs that are expanded in the open menu are read more often. Nothing extra happens while it is closed.
    public func setFocus(runs ids: Set<String>, menuOpen: Bool) {
        focusRuns = ids
        followSessions = menuOpen
    }

    public func sessionTranscript(_ sessionId: String) -> URL? {
        if let known = sessionFiles[sessionId] { return known }
        for root in roots {
            for project in FileInfo.names(in: root.projects) where !project.hasPrefix(".") {
                let file = root.projects.appendingPathComponent(project).appendingPathComponent("\(sessionId).jsonl")
                if FileManager.default.fileExists(atPath: file.path) {
                    sessionFiles[sessionId] = file
                    return file
                }
            }
        }
        return nil
    }

    public func scan(now: Date) -> WorldSnapshot {
        let folderFound = paths.isValid
        if coworkFoldersChanged() { discoverNow = true }
        if discoverNow || now.timeIntervalSince(lastDiscovery) >= config.rediscoveryInterval {
            discover()
            discoverNow = false
            lastDiscovery = now
        }
        var read = SessionReader.read(paths)
        for other in others where other.processesAreHere {
            let more = SessionReader.read(other)
            read.sessions += more.sessions
            read.unreadable += more.unreadable
        }
        var sessions = read.sessions.filter { SessionReader.isLive($0) && !BorisPaths.isUsageProbe(cwd: $0.cwd) }
        let ended = read.sessions.filter { !SessionReader.isLive($0) && !BorisPaths.isUsageProbe(cwd: $0.cwd) && recentlyActive($0, now: now) }
        sessions += unlistedSessions(listed: Set(read.sessions.map(\.sessionId)), now: now).filter { !BorisPaths.isUsageProbe(cwd: $0.cwd) }
        applyTitles(&sessions, now: now)
        var places: [String: GitPlace] = [:]
        for index in sessions.indices {
            let idle = sessions[index].status == "idle"
            let unnamedTool = !idle && WaitingReason(sessions[index].waitingFor) == .permission(tool: nil)
            let id = sessions[index].sessionId
            guard followSessions || unnamedTool, let file = sessionTranscript(id) else { continue }
            let tail = sessionTail(id, file: file)
            if followSessions {
                if !idle { sessions[index].currentStep = tail.running }
                sessions[index].contextTokens = tail.usage?.context
                sessions[index].model = tail.model ?? coworkFile(id, transcript: file)?.model
                places[id] = GitPlaceReader.place(folder: sessions[index].cwd, branch: tail.gitBranch)
            }
            // A request from a workflow agent is not in this file, so its tool stays unnamed.
            if unnamedTool, let tool = tail.running?.tool { sessions[index].waitingFor = "approve \(tool)" }
        }
        for session in sessions + ended where places[session.sessionId] == nil {
            places[session.sessionId] = GitPlaceReader.place(folder: session.cwd, branch: nil)
        }
        sessionTails = sessionTails.filter { id, _ in sessions.contains { $0.sessionId == id } }
        var sessionGrowth = TokenUsage()
        for session in sessions {
            guard let file = sessionTranscript(session.sessionId) else { continue }
            // A file older than this launch holds a past that was not seen live: a resumed session must not count it all again.
            sessionGrowth = sessionGrowth + meter.read(file, fromStart: (FileInfo.created(file) ?? .distantPast) >= startedAt)
        }
        var runTokens: [String: TokenUsage] = [:]
        let liveIds = Set(sessions.map(\.sessionId))

        var issues: Set<FormatIssue> = []
        if read.sessions.isEmpty, read.unreadable > 0 { issues.insert(.unreadableSessions) }

        var snapshots: [RunSnapshot] = []
        for id in Array(runs.keys) {
            guard var cache = runs[id] else { continue }
            let isDirty = dirty.contains(id)
            let unfinished = cache.final == nil || isStale(cache)
            let liveOwner = liveIds.contains(cache.sessionId) && unfinished
            let sinceCheck = now.timeIntervalSince(cache.lastChecked)
            let due = isDirty || liveOwner || focusRuns.contains(id) || (cache.loaded && unfinished && sinceCheck >= 5) || sinceCheck >= config.finishedRecheckInterval
            if due {
                refresh(&cache, now: now, recentEnough: liveOwner || isDirty)
                runs[id] = cache
            }
            let stillUnfinished = cache.final == nil || isStale(cache)
            if liveIds.contains(cache.sessionId), stillUnfinished {
                runTokens[id] = meterRun(cache)
            } else if let files = meteredRuns.removeValue(forKey: id) {
                files.forEach { meter.forget($0) }
            }
            let shown = (liveIds.contains(cache.sessionId) && stillUnfinished) || now.timeIntervalSince(cache.lastWrite) <= config.window
            guard cache.loaded, shown else { continue }
            issues.formUnion(formatIssues(cache, now: now))
            snapshots.append(snapshot(cache, session: sessions.first { $0.sessionId == cache.sessionId }))
            places.merge(cache.places) { own, _ in own }
        }
        dirty.removeAll()
        refreshUsage(now: now)
        var agentTokens: [String: TokenUsage] = [:]
        let agents = singleAgentSnapshots(sessions: sessions, now: now, tokens: &agentTokens, places: &places)

        var world = WorldSnapshot(takenAt: now, sessions: sessions, runs: snapshots, usage: usage, claudeFolderFound: folderFound, formatIssues: issues)
        world.account = account
        world.endedSessions = ended
        world.agents = agents
        world.sessionTokenGrowth = sessionGrowth
        world.runTokens = runTokens
        world.agentTokens = agentTokens
        world.places = places
        return world
    }

    /// A file that has not changed says the same as last time.
    private func sessionTail(_ id: String, file: URL) -> TranscriptReader.Tail {
        let modified = FileInfo.modified(file)
        if let known = sessionTails[id], known.modified == modified { return known.tail }
        var tail = TranscriptReader.tail(file)
        // A long result can push the last usage out of what the reader looks at, and the context has not gone anywhere.
        if tail.usage == nil, let known = sessionTails[id]?.tail {
            tail.usage = known.usage
            tail.model = tail.model ?? known.model
        }
        sessionTails[id] = (modified, tail)
        return tail
    }

    /// A file left behind long ago says nothing about the work of today.
    private func recentlyActive(_ session: SessionInfo, now: Date) -> Bool {
        guard let last = session.statusUpdatedAt ?? session.startedAt else { return false }
        return now.timeIntervalSince(last) <= config.window
    }

    /// A new Cowork task only adds a folder beside the others, and nothing watches that place: an active task rewrites a file there all the time.
    /// So the folders are looked for again when that place changes, and the full search over the logs runs only if there is a new one.
    private func coworkFoldersChanged() -> Bool {
        // `.../agent/<session>/.claude` and `.../<session>/.claude`: the kinds of task live one level apart.
        let holders = others.filter { !$0.processesAreHere }.map { $0.root.deletingLastPathComponent().deletingLastPathComponent() }
        var stamps: [URL: Date] = [:]
        for folder in Set(holders + holders.map { $0.deletingLastPathComponent() }) { stamps[folder] = FileInfo.modified(folder) }
        guard stamps != coworkStamps else { return false }
        let isFirstLook = coworkStamps.isEmpty
        coworkStamps = stamps
        return !isFirstLook && Set(findOthers().map(\.root)) != Set(others.map(\.root))
    }

    /// What Claude Desktop keeps about a Cowork task. Nil for any other session.
    private func coworkFile(_ id: String, transcript: URL) -> CoworkSessionFile? {
        guard let url = CoworkSessionFile.url(forTranscript: transcript) else { return nil }
        let modified = FileInfo.modified(url)
        if let known = coworkFiles[id], known.modified == modified { return known.file }
        let file = CoworkSessionFile.read(url)
        coworkFiles[id] = (modified, file)
        return file
    }

    private func discover() {
        others = findOthers()
        for root in roots {
            for project in FileInfo.names(in: root.projects) where !project.hasPrefix(".") {
                let projectDir = root.projects.appendingPathComponent(project)
                unlisted.look(in: projectDir, now: Date())
                for session in FileInfo.names(in: projectDir) where !session.hasSuffix(".jsonl") && !session.hasPrefix(".") {
                    let sessionDir = projectDir.appendingPathComponent(session)
                    discoverSingleAgents(in: sessionDir.appendingPathComponent("subagents"), session: nil, sessionId: session, now: Date())
                    let workflows = sessionDir.appendingPathComponent("subagents/workflows")
                    for run in FileInfo.names(in: workflows) where run.hasPrefix("wf_") && runs[run] == nil {
                        runs[run] = RunCache(
                            runId: run,
                            sessionId: session,
                            sessionDir: sessionDir,
                            runDir: workflows.appendingPathComponent(run),
                            finalURL: sessionDir.appendingPathComponent("workflows/\(run).json"),
                            scriptsDir: sessionDir.appendingPathComponent("workflows/scripts"),
                            parent: projectDir.appendingPathComponent("\(session).jsonl")
                        )
                    }
                }
            }
        }
    }

    /// Sessions without a file, kept alive by what they and their unfinished runs write.
    private func unlistedSessions(listed: Set<String>, now: Date) -> [SessionInfo] {
        for folder in changedProjects { unlisted.look(in: URL(fileURLWithPath: folder), now: now) }
        changedProjects.removeAll()
        var writes: [String: Date] = [:]
        for cache in runs.values where cache.lastWrite > startedAt && (cache.final == nil || isStale(cache)) {
            writes[cache.sessionId] = max(writes[cache.sessionId] ?? .distantPast, cache.lastWrite)
            unlisted.notice(session: cache.sessionId, transcript: cache.parent, now: now)
        }
        for agent in singleAgents.values where agent.lastWrite > startedAt && !agent.finished {
            writes[agent.sessionId] = max(writes[agent.sessionId] ?? .distantPast, agent.lastWrite)
            unlisted.notice(session: agent.sessionId, transcript: agent.folder.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("\(agent.sessionId).jsonl"), now: now)
        }
        return unlisted.sessions(listed: listed, unfinishedWrites: writes, now: now)
    }

    /// A title takes a read of the file's end, and a busy session writes all the time, so it is looked for once a minute at most.
    private func applyTitles(_ sessions: inout [SessionInfo], now: Date) {
        titles = titles.filter { id, _ in sessions.contains { $0.sessionId == id } }
        coworkFiles = coworkFiles.filter { id, _ in sessions.contains { $0.sessionId == id } }
        for index in sessions.indices {
            let id = sessions[index].sessionId
            let known = titles[id]
            if known == nil || now.timeIntervalSince(known?.checked ?? .distantPast) >= config.titleRefreshInterval, let file = sessionTranscript(id) {
                titles[id] = (now, coworkFile(id, transcript: file)?.name ?? TranscriptReader.title(in: file) ?? known?.title)
            }
            sessions[index].title = titles[id]?.title
        }
    }

    private func isStale(_ cache: RunCache) -> Bool {
        guard let finalModified = cache.finalModified, let journalModified = cache.journalModified else { return false }
        return finalModified < journalModified
    }

    private func refresh(_ cache: inout RunCache, now: Date, recentEnough: Bool) {
        cache.lastChecked = now
        let journalModified = FileInfo.modified(cache.journalURL)
        let finalModified = FileInfo.modified(cache.finalURL)
        let newest = [journalModified, finalModified].compactMap { $0 }.max() ?? .distantPast

        // Old finished runs stay untouched: nothing in them will be shown.
        if !cache.loaded, !recentEnough, now.timeIntervalSince(newest) > config.window {
            cache.lastWrite = newest
            return
        }
        cache.loaded = true

        if journalModified != cache.journalModified {
            cache.journal.read(cache.journalURL)
            cache.journalModified = journalModified
        }
        if finalModified != cache.finalModified || (cache.final == nil && finalModified != nil) {
            if let report = FinalReader.read(cache.finalURL) {
                cache.final = report
                cache.finalModified = finalModified
                cache.finalBrokenSince = nil
            } else if finalModified != nil, cache.finalBrokenSince == nil {
                cache.finalBrokenSince = now
            }
        }
        if !cache.scriptRead || cache.phases.isEmpty {
            if let info = ScriptReader.read(scripts: cache.scriptsDir, runId: cache.runId) {
                cache.scriptName = info.name
                cache.phases = info.phases
                cache.scriptDescription = info.description
                cache.scriptRead = true
            }
        }
        if cache.scriptName == nil, cache.final == nil, cache.launchChecks < 3, let info = TranscriptReader.launchInfo(in: cache.parent, runId: cache.runId) {
            cache.scriptName = info.workflowName
            if let path = info.scriptPath {
                let url = URL(fileURLWithPath: path)
                cache.phases = ScriptReader.phases(at: url)
                cache.scriptDescription = ScriptReader.description(at: url)
            }
            cache.launchChecks = 3
        } else if cache.scriptName == nil {
            cache.launchChecks += 1
        }
        if !cache.cwdRead {
            let origin = TranscriptReader.origin(in: cache.parent)
            cache.cwd = origin.cwd
            cache.entrypoint = origin.entrypoint
            cache.cwdRead = true
        }
        if cache.final?.status == "killed", !cache.stopChecked {
            let ids = [cache.runId, cache.final?.taskId].compactMap { $0 }
            cache.stoppedByClaude = TranscriptReader.hasStopCall(in: cache.parent, ids: ids)
            cache.stopChecked = true
        }
        readAgents(&cache, now: now)

        var write = [journalModified, FileInfo.modified(cache.runDir)].compactMap { $0 }.max() ?? cache.lastWrite
        for agent in cache.journal.tally.agents where agent.state == .running {
            if let id = agent.agentId, let modified = FileInfo.modified(cache.runDir.appendingPathComponent("agent-\(id).jsonl")) {
                write = max(write, modified)
            }
        }
        cache.lastWrite = max(cache.lastWrite, write)
    }

    /// An agent started with the `Agent` tool: not a workflow, but what a person wants to see just the same.
    private struct SingleAgent {
        let id: String
        let sessionId: String
        let folder: URL
        var cwd: String?
        var entrypoint: String?
        var description: String?
        var parentId: String?
        var type: String?
        var isFork = false
        /// The agent's own mark. Not every agent gets one.
        var marked = false
        var finished = false
        var failure: FailureInfo?
        var metaModified: Date?
        var lastWrite = Date.distantPast
        var checked = Date.distantPast
        /// What the transcript said when last read, and how new the file was then.
        var turnEnded = false
        var readAt: Date?
        var step: StepBrief?
        var contextTokens: Int?
        var model: String?
        var placeRead = false
        var place: GitPlace?

        var file: URL { folder.appendingPathComponent("agent-\(id).jsonl") }
        var meta: URL { folder.appendingPathComponent("agent-\(id).meta.json") }
    }

    private func subagentsFolder(project: URL, session: String) -> URL {
        project.appendingPathComponent(session).appendingPathComponent("subagents")
    }

    /// Notices agents in a folder. Ones that ended long ago are left out, so old sessions cost nothing later.
    private func discoverSingleAgents(in folder: URL, session: SessionInfo?, sessionId: String, now: Date) {
        for name in FileInfo.names(in: folder) where name.hasPrefix("agent-") && name.hasSuffix(".meta.json") {
            let id = String(name.dropFirst("agent-".count).dropLast(".meta.json".count))
            guard singleAgents[id] == nil else { continue }
            let file = folder.appendingPathComponent("agent-\(id).jsonl")
            guard let modified = FileInfo.modified(file), now.timeIntervalSince(modified) <= config.window else { continue }
            singleAgents[id] = SingleAgent(id: id, sessionId: sessionId, folder: folder, cwd: session?.cwd)
        }
    }

    private func singleAgentSnapshots(sessions: [SessionInfo], now: Date, tokens: inout [String: TokenUsage], places: inout [String: GitPlace]) -> [AgentSnapshot] {
        for session in sessions {
            guard let transcript = sessionTranscript(session.sessionId) else { continue }
            let folder = subagentsFolder(project: transcript.deletingLastPathComponent(), session: session.sessionId)
            discoverSingleAgents(in: folder, session: session, sessionId: session.sessionId, now: now)
        }
        let live = Set(sessions.map(\.sessionId))
        var result: [AgentSnapshot] = []
        for (id, known) in singleAgents {
            var agent = known
            guard let modified = FileInfo.modified(agent.file) else {
                singleAgents[id] = nil
                continue
            }
            let metaModified = FileInfo.modified(agent.meta)
            if metaModified != agent.metaModified {
                agent.metaModified = metaModified
                let meta = (try? Data(contentsOf: agent.meta)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                agent.description = meta?["description"] as? String
                agent.parentId = meta?["parentAgentId"] as? String
                agent.type = AgentKind.shown(meta?["agentType"] as? String)
                agent.marked = meta?["finished"] as? Bool ?? false
                agent.isFork = meta?["isFork"] as? Bool ?? false
            }
            // The mark is written last. A transcript written well after it means the agent was continued.
            let marked = agent.marked && modified.timeIntervalSince(metaModified ?? .distantPast) <= config.continuedAfter
            let interval = focusRuns.contains(id) ? config.focusRefreshInterval : config.tokensRefreshInterval
            if !marked, agent.readAt != modified, now.timeIntervalSince(agent.checked) >= interval {
                let tail = TranscriptReader.tail(agent.file)
                agent.checked = now
                agent.readAt = modified
                agent.turnEnded = tail.turnEnded
                agent.step = tail.running
                if let usage = tail.usage { agent.contextTokens = usage.context }
                agent.model = tail.model ?? agent.model
            }
            // Without a mark, a finished turn followed by silence is the end. An answer from the file read earlier says nothing about newer writes.
            let finished = marked || (agent.turnEnded && agent.readAt == modified && now.timeIntervalSince(modified) >= config.agentSettle)
            if finished, !agent.finished, let last = TranscriptReader.tail(agent.file).last, last.isApiError {
                agent.failure = FailureClassifier.classify(last)
            } else if !finished {
                agent.failure = nil
            }
            agent.finished = finished
            let lastWrite = max(modified, metaModified ?? .distantPast)
            agent.lastWrite = lastWrite
            guard agent.finished ? now.timeIntervalSince(lastWrite) <= config.window : (live.contains(agent.sessionId) || now.timeIntervalSince(lastWrite) <= config.window) else {
                singleAgents[id] = nil
                meter.forget(agent.file)
                continue
            }
            if agent.cwd == nil || agent.entrypoint == nil {
                let origin = TranscriptReader.origin(in: agent.file)
                agent.cwd = agent.cwd ?? origin.cwd
                agent.entrypoint = origin.entrypoint
            }
            if !agent.finished {
                if live.contains(agent.sessionId) {
                    _ = meter.read(agent.file, fromStart: true)
                    tokens[id] = meter.total(of: agent.file)
                }
            } else {
                agent.step = nil
                meter.forget(agent.file)
            }
            if !agent.placeRead {
                let origin = TranscriptReader.origin(in: agent.file)
                agent.placeRead = origin.cwd != nil
                agent.place = GitPlaceReader.place(folder: origin.cwd, branch: origin.gitBranch)
            }
            if let place = agent.place, place.isSeparateCopy { places[id] = place }
            singleAgents[id] = agent
            result.append(snapshot(agent, lastWrite: lastWrite))
        }
        return result
    }

    private func snapshot(_ agent: SingleAgent, lastWrite: Date) -> AgentSnapshot {
        AgentSnapshot(
            id: agent.id,
            sessionId: agent.sessionId,
            parentAgentId: agent.parentId,
            description: agent.description,
            agentType: agent.type,
            isFork: agent.isFork,
            state: agent.failure != nil ? .failed : agent.finished ? .done : .running,
            failure: agent.failure,
            contextTokens: agent.contextTokens,
            model: agent.model,
            currentStep: agent.step,
            cwd: agent.cwd,
            entrypoint: agent.entrypoint,
            startedAt: FileInfo.created(agent.file),
            lastWrite: lastWrite
        )
    }

    /// What a running run has spent so far, across all its agents.
    private func meterRun(_ cache: RunCache) -> TokenUsage {
        let files = cache.journal.tally.agents.compactMap(\.agentId).map { cache.runDir.appendingPathComponent("agent-\($0).jsonl") }
        meteredRuns[cache.runId] = files
        return files.reduce(TokenUsage()) { total, file in
            _ = meter.read(file, fromStart: true)
            return total + meter.total(of: file)
        }
    }

    private func readAgents(_ cache: inout RunCache, now: Date) {
        for agent in cache.journal.tally.agents {
            guard let id = agent.agentId else { continue }
            let file = cache.runDir.appendingPathComponent("agent-\(id).jsonl")
            if !cache.placesRead.contains(id) {
                let origin = TranscriptReader.origin(in: file)
                if origin.cwd != nil { cache.placesRead.insert(id) }
                if let place = GitPlaceReader.place(folder: origin.cwd, branch: origin.gitBranch), place.isSeparateCopy { cache.places[id] = place }
            }
            if agent.state == .running, cache.agentTypes[id] == nil {
                let meta = (try? Data(contentsOf: cache.runDir.appendingPathComponent("agent-\(id).meta.json"))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                cache.agentTypes[id] = AgentKind.shown(meta?["agentType"] as? String) ?? ""
            }
            switch agent.state {
            case .failed where cache.failures[id] == nil:
                let tail = TranscriptReader.tail(file)
                cache.failures[id] = FailureClassifier.classify(tail.last)
                if let usage = tail.usage { cache.tokens[id] = (now, usage.context, tail.model) }
            case .running:
                let interval = focusRuns.contains(cache.runId) ? config.focusRefreshInterval : config.tokensRefreshInterval
                if let known = cache.tokens[id], now.timeIntervalSince(known.at) < interval { continue }
                let tail = TranscriptReader.tail(file)
                cache.steps[id] = tail.running
                if let usage = tail.usage {
                    cache.tokens[id] = (now, usage.context, tail.model)
                } else if let known = cache.tokens[id] {
                    cache.tokens[id] = (now, known.tokens, known.model)
                } else {
                    cache.tokens[id] = (now, 0, nil)
                }
            case .done where cache.tokens[id] == nil && cache.final == nil:
                let tail = TranscriptReader.tail(file)
                cache.tokens[id] = (now, tail.usage?.context ?? 0, tail.model)
            default:
                break
            }
        }
    }

    private func formatIssues(_ cache: RunCache, now: Date) -> Set<FormatIssue> {
        var issues = Set(cache.journal.tally.unknownEvents.map { FormatIssue.unknownJournalEvent($0) })
        if let since = cache.finalBrokenSince, now.timeIntervalSince(since) > config.finalGiveUpAfter {
            issues.insert(.unreadableFinal(runId: cache.runId))
        }
        return issues
    }

    private func snapshot(_ cache: RunCache, session: SessionInfo?) -> RunSnapshot {
        let agents = cache.journal.tally.agents.map { agent -> AgentRecord in
            var record = agent
            if let id = agent.agentId {
                record.failure = cache.failures[id]
                if let known = cache.tokens[id] {
                    record.contextTokens = known.tokens > 0 ? known.tokens : nil
                    record.model = known.model
                }
                if agent.state == .running { record.currentStep = cache.steps[id] }
                if let type = cache.agentTypes[id], !type.isEmpty { record.agentType = type }
            }
            return record
        }
        var snapshot = RunSnapshot(
            runId: cache.runId,
            sessionId: cache.sessionId,
            cwd: session?.cwd ?? cache.cwd,
            scriptName: cache.scriptName,
            description: cache.scriptDescription,
            plannedPhases: cache.phases,
            lastWrite: cache.lastWrite,
            journalModified: cache.journalModified,
            final: cache.final,
            finalModified: cache.finalModified,
            agents: agents,
            stoppedByClaude: cache.stoppedByClaude
        )
        snapshot.startedAt = FileInfo.created(cache.journalURL)
        snapshot.entrypoint = cache.entrypoint
        return snapshot
    }

    private func refreshUsage(now: Date) {
        guard now.timeIntervalSince(usageChecked) >= config.usageRefreshInterval else { return }
        usageChecked = now
        let modified = FileInfo.modified(paths.profile)
        guard modified != usageModified else { return }
        usageModified = modified
        guard let profile = UsageReader.profile(paths.profile, settings: paths.settings) else { return }
        // Once something is known, a failed read must not wipe it: the old value stays with its true age.
        // Without a sign-in it is someone else's limits, and they go.
        usage = profile.usage ?? (profile.account == .signedIn ? usage : nil)
        account = profile.account
    }
}
