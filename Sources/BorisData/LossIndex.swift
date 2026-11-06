import BorisCore
import Foundation

/// Everything that went wrong, and the calls of skills and web tools, from every transcript and workflow Claude still keeps.
///
/// Like `TokenIndex`, it reads only what was added since last time and remembers that in a cache file, and nothing is lost without it.
/// The file holds ids, numbers, project folders, the names of tools and skills and the time a limit resets. Names of agents and the text of errors are taken from Claude's files when needed and stay in memory.
public actor LossIndex {
    private struct AwaitedCall: Codable {
        var kind: LossCallKind
        var name: String?
    }

    /// What one transcript has given so far, and what is needed to go on reading it.
    private struct Transcript: Codable {
        var size: UInt64 = 0
        var offset: UInt64 = 0
        var cwd: String?
        var entrypoint: String?
        var entries: [LossEntry] = []
        var calls: [LossCalls] = []
        /// Everything counted from this file, so a repeat in another file is not counted again.
        var ids: [String] = []
        /// The newest tool calls, to name the tool when its error arrives.
        var tools: [String: String] = [:]
        var toolOrder: [String] = []
        /// Web and skill calls whose result is still to come, which is what their tokens are estimated from.
        var awaited: [String: AwaitedCall] = [:]
        var openRetry: String?
        /// Tool errors since Claude last spoke: if the person interrupted right after them, they were caused by that.
        var recentToolErrors: [String] = []
        var lastApiError: String?
        var endsWithApiError = false
    }

    private struct Cache: Codable {
        var version: Int
        var transcripts: [String: Transcript]
    }

    /// What a workflow's result says about its agents. It is cheap to read, so it lives in memory only.
    private struct Run {
        var sessionId: String
        var finalModified: Date?
        var journalModified: Date?
        var labels: [String: String] = [:]
        var failed: Set<String> = []
        /// Rows that hold whatever happens next.
        var rows: [LossEntry] = []
        /// Agents still at work with no result yet. They are lost if the session is gone.
        var unfinished: [String] = []
        var template: LossEntry
    }

    public struct Progress: Sendable, Equatable {
        public var done: Int
        public var total: Int

        public init(done: Int, total: Int) {
            self.done = done
            self.total = total
        }
    }

    /// Where it goes among Boris's own files. Only a cache: it is built again if it goes away.
    public static let cacheName = "loss-index.json"
    private static let version = 1
    private static let chunk = 1024 * 1024
    private static let recentTools = 32
    private static let rawTextLimit = 300
    /// A file this old is finished with, so what was kept for reading on can go, and the cache stays small.
    private static let settledAfter: TimeInterval = 3600
    /// A character of a page or a skill is about a quarter of a token in English, and text in other languages takes more bytes per character.
    private static let bytesPerToken = 4
    /// The whole cache is rewritten each time. Losing a minute of it only means reading that minute again.
    private static let saveInterval: TimeInterval = 60

    private let cacheFile: URL?
    private let calendar: Calendar
    private let timestamps: ISO8601DateFormatter
    private let dayKeys: DateFormatter
    private var loaded = false
    private var unsaved = false
    private var lastSaved: Date?
    private var transcripts: [String: Transcript] = [:]
    private var seen: Set<String> = []
    private var runs: [String: Run] = [:]
    private var diedSessions: [SessionInfo] = []
    private var meta: [String: String?] = [:]
    private var filter = SourceFilter()

    /// - Parameter cacheFile: nil keeps everything in memory.
    public init(cacheFile: URL?, timeZone: TimeZone = .current) {
        self.cacheFile = cacheFile
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        self.calendar = calendar
        let timestamps = ISO8601DateFormatter()
        timestamps.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.timestamps = timestamps
        let dayKeys = DateFormatter()
        dayKeys.locale = Locale(identifier: "en_US_POSIX")
        dayKeys.timeZone = timeZone
        dayKeys.dateFormat = "yyyy-MM-dd"
        self.dayKeys = dayKeys
    }

    /// Brings the index up to date. Read off the main thread, as nothing here is quick on the first pass.
    /// - Returns: true if anything changed.
    @discardableResult
    public func update(roots: [ClaudePaths], filter: SourceFilter = SourceFilter(), progress: (@Sendable (Progress) -> Void)? = nil) async -> Bool {
        loadCache()
        self.filter = filter
        let roots = roots.filter(filter.reads(root:))
        let files = TokenIndex.transcripts(in: roots, filter: filter)
        var changed = false

        let existing = Set(files.map(\.path))
        for path in transcripts.keys where !existing.contains(path) {
            forget(path)
            changed = true
        }
        for (index, file) in files.enumerated() {
            if Task.isCancelled { break }
            // Without its own pool a long pass keeps every buffer it has read until it ends.
            if autoreleasepool(invoking: { read(file) }) { changed = true }
            progress?(Progress(done: index + 1, total: files.count))
            // Other work gets its turn, however many logs there are.
            await Task.yield()
        }
        saveWhenDue(changed: changed)
        if Task.isCancelled { return changed }
        if readRuns(roots) { changed = true }
        let died = roots.filter(\.processesAreHere).flatMap { SessionReader.read($0).sessions }
            .filter { Self.diedAtWork($0) && filter.allows(session: filter.editors.identified($0)) }
        if died != diedSessions {
            diedSessions = died
            changed = true
        }
        return changed
    }

    /// A session that was idle or waiting lost nothing when it went away.
    private static func diedAtWork(_ session: SessionInfo) -> Bool {
        guard let status = session.status, status != "idle", status != "waiting" else { return false }
        return !SessionReader.isLive(session)
    }

    /// - Parameter live: sessions at work now. Whatever belongs to them is not over yet, unless it says so itself.
    public func history(live: Set<String>) -> LossHistory {
        loadCache()
        var entries: [LossEntry] = []
        var calls: [LossCalls] = []
        var labels: [String: String] = [:]
        var failed: Set<String> = []
        for run in runs.values {
            labels.merge(run.labels) { first, _ in first }
            failed.formUnion(run.failed)
            entries += run.rows
            if !run.unfinished.isEmpty, !live.contains(run.sessionId) {
                var closed = run.template
                closed.id += "/closed"
                closed.count = run.unfinished.count
                closed.agents = run.unfinished
                closed.reason = .closed
                entries.append(closed)
            }
        }

        for (path, transcript) in transcripts {
            let owner = TokenIndex.owner(ofTranscript: path)
            calls += transcript.calls
            for var entry in transcript.entries {
                let isTheEnd = transcript.endsWithApiError && entry.id == transcript.lastApiError
                if let agent = owner.agent {
                    if owner.run != nil {
                        // The workflow's own row already tells this agent's end.
                        if isTheEnd, failed.contains(agent) { continue }
                        entry.title = labels[agent]
                    } else {
                        entry.title = title(ofAgent: agent, transcript: path)
                        if isTheEnd {
                            entry.kind = .crash
                            entry.agents = [agent]
                        }
                    }
                }
                entries.append(entry)
            }
        }

        for session in diedSessions where !live.contains(session.sessionId) {
            entries.append(LossEntry(
                id: "session/\(session.sessionId)/\(session.pid)",
                at: session.statusUpdatedAt ?? session.startedAt ?? .distantPast,
                kind: .crash,
                sessionId: session.sessionId,
                cwd: session.cwd,
                entrypoint: session.entrypoint,
                reason: .closed
            ))
        }

        // Boris's own hidden sessions are not the person's work.
        let shown = entries.filter { !BorisPaths.isUsageProbe(cwd: $0.cwd) }.map { entry in
            var entry = entry
            entry.entrypoint = filter.editors.entrypoint(entry.entrypoint, session: entry.sessionId)
            return entry
        }
        return LossHistory(entries: shown, calls: calls)
    }

    /// What the page shows. All the adding up happens here, off the main thread.
    public func book(period: LossPeriod, tokens: [TokenRecord], live: Set<String>, now: Date) -> LossBook {
        var agentTokens: [String: Int] = [:]
        for record in tokens {
            guard let agent = record.agentId else { continue }
            agentTokens[agent, default: 0] += record.usage.total
        }
        return LossBook(history: history(live: live), period: period, agentTokens: agentTokens, now: now, calendar: calendar)
    }

    // MARK: - Transcripts

    private func read(_ url: URL) -> Bool {
        guard let size = FileInfo.size(url) else { return false }
        if let known = transcripts[url.path], size == known.size { return false }
        // A file that shrank was rewritten, so it starts over.
        if let known = transcripts[url.path], size < known.offset { forget(url.path) }

        var transcript = transcripts[url.path] ?? Transcript()
        let owner = TokenIndex.owner(ofTranscript: url.path)
        let modified = FileInfo.modified(url) ?? Date()
        guard let handle = try? FileHandle(forReadingFrom: url), (try? handle.seek(toOffset: transcript.offset)) != nil else { return false }
        defer { try? handle.close() }

        var pending = Data()
        // Each chunk and what was parsed from it go before the next one comes, or a first pass holds on to all of them.
        while autoreleasepool(invoking: {
            guard let data = try? handle.read(upToCount: Self.chunk), !data.isEmpty else { return false }
            pending.append(data)
            guard let newline = pending.lastIndex(of: 0x0A) else { return true }
            let end = pending.index(after: newline)
            pending[pending.startIndex..<end].withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                var start = 0
                while start < bytes.count, let found = memchr(base + start, 0x0A, bytes.count - start) {
                    let length = UnsafeRawPointer(found) - (base + start)
                    let line = UnsafeRawBufferPointer(start: base + start, count: length)
                    if length > 0, wanted(line, in: &transcript), let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] {
                        add(record, owner: owner, modified: modified, to: &transcript)
                    }
                    start += length + 1
                }
            }
            transcript.offset += UInt64(end - pending.startIndex)
            pending = Data(pending[end...])
            return true
        }) {}
        transcript.size = size
        if Date().timeIntervalSince(modified) > Self.settledAfter {
            transcript.tools = [:]
            transcript.toolOrder = []
            transcript.awaited = [:]
        }
        transcripts[url.path] = transcript
        return true
    }

    /// Most lines cost only a look at their bytes, so a first pass over gigabytes stays short.
    /// A real message from Claude needs no parsing to know that the turn went on, and that any retries before it worked.
    private func wanted(_ line: UnsafeRawBufferPointer, in transcript: inout Transcript) -> Bool {
        // These hold whole requests, so they mention everything the markers below look for.
        if Self.has("\"type\":\"api-request", line) { return false }
        if Self.has("\"type\":\"assistant\"", line) {
            if Self.has("\"isApiErrorMessage\"", line) { return true }
            transcript.endsWithApiError = false
            transcript.recentToolErrors = []
            closeRetry(recovered: true, in: &transcript)
            return Self.has("\"tool_use\"", line) || Self.has("\"max_tokens\"", line)
        }
        return Self.has("\"is_error\":true", line)
            || Self.has("\"sourceToolUseID\"", line)
            || Self.has("[Request interrupted", line)
            || Self.has("\"api_error\"", line)
            || (!transcript.awaited.isEmpty && Self.has("\"tool_result\"", line))
    }

    private static func has(_ marker: StaticString, _ line: UnsafeRawBufferPointer) -> Bool {
        memmem(line.baseAddress, line.count, marker.utf8Start, marker.utf8CodeUnitCount) != nil
    }

    private func add(_ record: [String: Any], owner: (session: String, agent: String?, run: String?), modified: Date, to transcript: inout Transcript) {
        transcript.cwd = transcript.cwd ?? record["cwd"] as? String
        transcript.entrypoint = transcript.entrypoint ?? record["entrypoint"] as? String
        let at = (record["timestamp"] as? String).flatMap { timestamps.date(from: $0) } ?? modified
        var base = LossEntry(id: "", at: at, kind: .retry, sessionId: owner.session, agentId: owner.agent, runId: owner.run, cwd: transcript.cwd, entrypoint: transcript.entrypoint)

        switch record["type"] as? String {
        case "system":
            retry(record, base: base, to: &transcript)
        case "assistant":
            guard let message = record["message"] as? [String: Any] else { return }
            if record["isApiErrorMessage"] as? Bool == true {
                apiError(record, message: message, base: base, to: &transcript)
            } else {
                if message["stop_reason"] as? String == "max_tokens", let id = message["id"] as? String, note(id, in: &transcript) {
                    base.id = id
                    base.kind = .cut
                    base.code = "max_tokens"
                    transcript.entries.append(base)
                }
                calls(in: message, at: at, to: &transcript)
            }
        case "user":
            guard let message = record["message"] as? [String: Any] else { return }
            user(record, message: message, base: base, to: &transcript)
        default:
            break
        }
    }

    /// Claude asks again by itself. Attempts in a row until the next message are one row.
    private func retry(_ record: [String: Any], base: LossEntry, to transcript: inout Transcript) {
        guard record["subtype"] as? String == "api_error", let id = record["uuid"] as? String, note(id, in: &transcript) else { return }
        if let open = transcript.openRetry, let index = transcript.entries.lastIndex(where: { $0.id == open }) {
            transcript.entries[index].count += 1
            return
        }
        let error = record["error"] as? [String: Any]
        let text = error?["formatted"] as? String ?? error?["message"] as? String
        let status = error?["status"] as? Int
        let info = FailureClassifier.classify(LastRecord(isApiError: true, errorCode: status == 429 ? "rate_limit" : nil, text: text))
        var entry = base
        entry.id = id
        entry.kind = .retry
        entry.reason = LossReason(info.failureClass)
        entry.problem = info.failureClass == .api ? ApiProblem(code: nil, status: status, text: text) : nil
        entry.status = status
        transcript.entries.append(entry)
        transcript.openRetry = id
    }

    private func closeRetry(recovered: Bool, in transcript: inout Transcript) {
        guard let open = transcript.openRetry else { return }
        if let index = transcript.entries.lastIndex(where: { $0.id == open }) { transcript.entries[index].recovered = recovered }
        transcript.openRetry = nil
    }

    /// A turn that ended in an error. The text is read to name the cause and is not kept.
    private func apiError(_ record: [String: Any], message: [String: Any], base: LossEntry, to transcript: inout Transcript) {
        transcript.endsWithApiError = true
        transcript.recentToolErrors = []
        closeRetry(recovered: false, in: &transcript)
        guard let id = record["uuid"] as? String ?? message["id"] as? String else { return }
        transcript.lastApiError = id
        guard note(id, in: &transcript) else { return }

        let code = record["error"] as? String
        let status = record["apiErrorStatus"] as? Int
        let blocks = message["content"] as? [[String: Any]]
        let text = message["content"] as? String ?? blocks?.first { $0["type"] as? String == "text" }?["text"] as? String
        let info = FailureClassifier.classify(LastRecord(isApiError: true, errorCode: code, text: text))
        var entry = base
        entry.id = id
        entry.kind = record["streamCutCause"] != nil || record["truncatedAfterOutput"] as? Bool == true ? .cut : .apiError
        entry.reason = LossReason(info.failureClass)
        entry.problem = info.failureClass == .api ? ApiProblem(code: code, status: status, text: text) : nil
        entry.limit = info.limitKind
        entry.resets = info.resets
        if let seconds = (record["quotaLimits"] as? [String: Any])?["resetsAt"] as? NSNumber {
            entry.resetsAt = Date(timeIntervalSince1970: seconds.doubleValue)
        }
        entry.code = code
        entry.status = status
        transcript.entries.append(entry)
    }

    private func calls(in message: [String: Any], at: Date, to transcript: inout Transcript) {
        for block in message["content"] as? [[String: Any]] ?? [] where block["type"] as? String == "tool_use" {
            guard let id = block["id"] as? String, let tool = block["name"] as? String else { continue }
            if transcript.tools[id] == nil { transcript.toolOrder.append(id) }
            transcript.tools[id] = tool
            if transcript.toolOrder.count > Self.recentTools { transcript.tools[transcript.toolOrder.removeFirst()] = nil }

            let kind: LossCallKind
            switch WorkAction(tool: tool) {
            case .skill: kind = .skill
            case .webSearch: kind = .search
            case .webFetch: kind = .fetch
            default: continue
            }
            // A fork starts with its parent's messages, and those calls were made only once.
            guard note(id, in: &transcript) else { continue }
            let name = kind == .skill ? (block["input"] as? [String: Any])?["skill"] as? String : nil
            count(kind, name: name, at: at, calls: 1, tokens: 0, to: &transcript)
            transcript.awaited[id] = AwaitedCall(kind: kind, name: name)
        }
    }

    private func count(_ kind: LossCallKind, name: String?, at: Date, calls: Int, tokens: Int, to transcript: inout Transcript) {
        let day = dayKeys.string(from: at)
        if let index = transcript.calls.firstIndex(where: { $0.day == day && $0.kind == kind && $0.name == name }) {
            transcript.calls[index].calls += calls
            transcript.calls[index].estimatedTokens += tokens
        } else {
            transcript.calls.append(LossCalls(day: day, kind: kind, name: name, calls: calls, estimatedTokens: tokens))
        }
    }

    private func user(_ record: [String: Any], message: [String: Any], base: LossEntry, to transcript: inout Transcript) {
        let content = message["content"]
        let blocks = content as? [[String: Any]] ?? []

        // A skill's text comes as a message of its own that names the call.
        if let source = record["sourceToolUseID"] as? String, let call = transcript.awaited[source], call.kind == .skill {
            transcript.awaited[source] = nil
            count(.skill, name: call.name, at: base.at, calls: 0, tokens: Self.textBytes(content) / Self.bytesPerToken, to: &transcript)
        }

        let said = content as? String ?? blocks.first { $0["type"] as? String == "text" }?["text"] as? String
        if said?.hasPrefix("[Request interrupted") == true {
            // What the person's stop broke is not a failure.
            let broken = Set(transcript.recentToolErrors)
            transcript.entries.removeAll { broken.contains($0.id) }
            transcript.recentToolErrors = []
        }

        for block in blocks where block["type"] as? String == "tool_result" {
            guard let id = block["tool_use_id"] as? String else { continue }
            if let call = transcript.awaited[id], call.kind != .skill {
                transcript.awaited[id] = nil
                count(call.kind, name: call.name, at: base.at, calls: 0, tokens: Self.textBytes(block["content"]) / Self.bytesPerToken, to: &transcript)
            }
            guard block["is_error"] as? Bool == true else { continue }
            toolError(id: id, record: record, result: block["content"], base: base, to: &transcript)
        }
    }

    private func toolError(id: String, record: [String: Any], result: Any?, base: LossEntry, to transcript: inout Transcript) {
        let head = Self.textHead(result)
        // The call itself may have been counted under this id already.
        if Self.isStopOrEcho(head) || !note("error/\(id)", in: &transcript) { return }
        var entry = base
        entry.id = id
        entry.tool = transcript.tools[id]
        if let denial = Self.denial(record, head: head) {
            entry.kind = .denied
            entry.denial = denial
        } else {
            let failure = Self.toolFailure(head)
            entry.kind = .toolError
            entry.toolFailure = failure.kind
            entry.toolCode = failure.code
            transcript.recentToolErrors.append(id)
        }
        transcript.entries.append(entry)
    }

    /// True for what the person's interruption leaves behind, and for calls cancelled because another call next to them failed.
    static func isStopOrEcho(_ head: String) -> Bool {
        head.hasPrefix("[Request interrupted")
            || head.contains("doesn't want to take this action")
            || head.contains("Interrupted by user")
            || head.contains("Cancelled: parallel tool call")
            || head.contains("Sibling tool call errored")
    }

    private static func denial(_ record: [String: Any], head: String) -> LossDenial? {
        if let kind = record["toolDenialKind"] as? String {
            return kind == "user-rejected" ? .person : .rule
        }
        if head.contains("doesn't want to proceed") { return .person }
        if (record["permissionDecision"] as? [String: Any])?["decision"] as? String == "reject" { return .rule }
        return nil
    }

    static func toolFailure(_ head: String) -> (kind: ToolFailure, code: Int?) {
        ToolFailure.classify(head)
    }

    /// Only the start of a tool's output is ever looked at.
    private static func textHead(_ content: Any?) -> String {
        let text = content as? String ?? (content as? [[String: Any]])?.first { $0["text"] != nil }?["text"] as? String ?? ""
        return String(text.prefix(300))
    }

    private static func textBytes(_ content: Any?) -> Int {
        if let text = content as? String { return text.utf8.count }
        let blocks = content as? [[String: Any]] ?? []
        return blocks.reduce(0) { $0 + (($1["text"] as? String)?.utf8.count ?? 0) }
    }

    /// Returns false for what was already counted, here or in another file.
    private func note(_ id: String, in transcript: inout Transcript) -> Bool {
        guard seen.insert(id).inserted else { return false }
        transcript.ids.append(id)
        return true
    }

    private func forget(_ path: String) {
        guard let transcript = transcripts.removeValue(forKey: path) else { return }
        seen.subtract(transcript.ids)
    }

    /// An ordinary agent's name lies next to its transcript.
    private func title(ofAgent agent: String, transcript path: String) -> String? {
        if let known = meta[agent] { return known }
        let file = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("agent-\(agent).meta.json")
        let object = (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let title = object?["description"] as? String ?? AgentKind.shown(object?["agentType"] as? String)
        meta[agent] = title
        return title
    }

    // MARK: - Workflows

    private func readRuns(_ roots: [ClaudePaths]) -> Bool {
        var changed = false
        var present: Set<String> = []
        for root in roots {
            for project in FileInfo.names(in: root.projects) where !project.hasPrefix(".") {
                let projectDir = root.projects.appendingPathComponent(project)
                for session in FileInfo.names(in: projectDir) where !session.hasSuffix(".jsonl") && !session.hasPrefix(".") {
                    guard filter.allows(transcript: projectDir.appendingPathComponent("\(session).jsonl")) else { continue }
                    let sessionDir = projectDir.appendingPathComponent(session)
                    let finals = sessionDir.appendingPathComponent("workflows")
                    let journals = sessionDir.appendingPathComponent("subagents/workflows")
                    var ids = Set(FileInfo.names(in: journals).filter { $0.hasPrefix("wf_") })
                    ids.formUnion(FileInfo.names(in: finals).filter { $0.hasPrefix("wf_") && $0.hasSuffix(".json") }.map { String($0.dropLast(5)) })
                    for id in ids {
                        present.insert(id)
                        if readRun(id, session: session, sessionDir: sessionDir, parent: projectDir.appendingPathComponent("\(session).jsonl")) { changed = true }
                    }
                }
            }
        }
        for id in runs.keys where !present.contains(id) {
            runs[id] = nil
            changed = true
        }
        return changed
    }

    private func readRun(_ id: String, session: String, sessionDir: URL, parent: URL) -> Bool {
        let finalURL = sessionDir.appendingPathComponent("workflows/\(id).json")
        let runDir = sessionDir.appendingPathComponent("subagents/workflows/\(id)")
        let journalURL = runDir.appendingPathComponent("journal.jsonl")
        let finalModified = FileInfo.modified(finalURL)
        let journalModified = FileInfo.modified(journalURL)
        if let known = runs[id], known.finalModified == finalModified, known.journalModified == journalModified { return false }

        // A final file older than the journal belongs to an earlier attempt.
        let stale = finalModified.flatMap { final in journalModified.map { final < $0 } } ?? false
        let final = stale ? nil : FinalReader.read(finalURL)
        var journal = JournalReader()
        journal.read(journalURL)
        var agents: [AgentRecord]
        if let final, !final.entries.isEmpty {
            agents = final.entries.map(\.record)
            // The result lists only the attempts it kept, so an agent that fell in an earlier one is left in the journal alone.
            // One that never got to start has an empty id in the journal and is listed in the result without one.
            let listed = Set(agents.compactMap(\.agentId))
            agents += journal.tally.agents.filter { agent in
                agent.state == .failed && agent.agentId.map { !$0.isEmpty && !listed.contains($0) } == true
            }
        } else {
            agents = journal.tally.agents
        }
        for index in agents.indices where agents[index].state == .failed && agents[index].failure == nil {
            guard let agent = agents[index].agentId else { continue }
            // Only an error message of Claude Code's can be trusted to say why: whatever else came last may be a result.
            let last = TranscriptReader.tail(runDir.appendingPathComponent("agent-\(agent).jsonl")).last
            agents[index].failure = FailureClassifier.classify(last?.isApiError == true ? last : nil)
        }

        let ended = finalEnd(final) ?? finalModified ?? journalModified ?? Date()
        let needsOrigin = final == nil || final?.status == "failed" || agents.contains { $0.state == .failed }
        let origin = needsOrigin ? TranscriptReader.origin(in: parent) : (cwd: nil, entrypoint: nil, gitBranch: nil)
        // A run started from a file has no script copy here, and only its launch in the parent transcript names it.
        let name = final?.workflowName
            ?? runs[id]?.template.title
            ?? ScriptReader.read(scripts: sessionDir.appendingPathComponent("workflows/scripts"), runId: id)?.name
            ?? (needsOrigin ? TranscriptReader.launchInfo(in: parent, runId: id)?.workflowName : nil)
        let template = LossEntry(id: id, at: ended, kind: .crash, sessionId: session, runId: id, cwd: origin.cwd, entrypoint: origin.entrypoint, title: name, total: agents.count)

        var run = Run(sessionId: session, finalModified: finalModified, journalModified: journalModified, template: template)
        for agent in agents {
            if let agentId = agent.agentId, let label = agent.label { run.labels[agentId] = label }
        }
        // Agents at work when a run was stopped were stopped with it. An abort is that same stop as told by the agent, and an agent with no error of its own has nothing else to tell.
        let wasStopped = final?.status == "killed"
        let fallen = agents.filter { agent in
            agent.state == .failed && !Self.isRunStop(agent.failure?.text) && !(wasStopped && agent.failure?.text == nil)
        }
        run.failed = Set(fallen.compactMap(\.agentId))
        let byReason = Dictionary(grouping: fallen) { LossReason($0.failure?.failureClass ?? .unknown) }
        for reason in LossReason.allCases {
            guard let group = byReason[reason], let first = group.first else { continue }
            var row = template
            row.id = "\(id)/\(reason.rawValue)"
            row.count = group.count
            row.agents = group.compactMap(\.agentId)
            row.reason = reason
            row.limit = first.failure?.limitKind
            row.resets = first.failure?.resets
            if reason == .unknown { row.rawText = group.lazy.compactMap { Self.firstLine($0.failure?.text) }.first }
            run.rows.append(row)
        }
        if let row = scriptRow(final, template: template, anyFallen: !fallen.isEmpty) { run.rows.append(row) }
        if final == nil { run.unfinished = agents.filter { $0.state == .running }.map { $0.agentId ?? $0.key } }
        runs[id] = run
        return true
    }

    /// Only these words mean the run was stopped. Something else that was aborted, such as a request on a timeout, is a real failure.
    private static func isRunStop(_ text: String?) -> Bool {
        text?.lowercased().contains("workflow aborted") == true
    }

    /// A failed run's own error. When its agents failed, that error is usually just theirs, and only something else is worth a row.
    private func scriptRow(_ final: FinalReport?, template: LossEntry, anyFallen: Bool) -> LossEntry? {
        guard let final, final.status == "failed", !Self.isRunStop(final.errorFirstLine) else { return nil }
        let failure = FailureClassifier.classify(nil, reason: final.errorFirstLine).failureClass
        guard failure == .unknown || !anyFallen else { return nil }
        var row = template
        row.id += "/run"
        row.reason = failure == .unknown ? .script : LossReason(failure)
        row.rawText = Self.firstLine(final.errorFirstLine)
        row.total = nil
        return row
    }

    private func finalEnd(_ final: FinalReport?) -> Date? {
        guard let start = final?.startTime, let duration = final?.durationMs else { return nil }
        return start.addingTimeInterval(Double(duration) / 1000)
    }

    private static func firstLine(_ text: String?) -> String? {
        guard let line = text?.split(separator: "\n", maxSplits: 1).first else { return nil }
        return String(line.prefix(rawTextLimit))
    }

    // MARK: - Cache

    /// Done on the first use rather than when created, which can be on the main thread.
    private func loadCache() {
        guard !loaded else { return }
        loaded = true
        guard let cacheFile,
              let data = try? Data(contentsOf: cacheFile),
              let cache = try? JSONDecoder().decode(Cache.self, from: data),
              cache.version == Self.version
        else { return }
        transcripts = cache.transcripts
        seen = Set(cache.transcripts.values.flatMap(\.ids))
    }

    private func saveWhenDue(changed: Bool, now: Date = Date()) {
        if changed { unsaved = true }
        guard unsaved else { return }
        if let lastSaved, now.timeIntervalSince(lastSaved) < Self.saveInterval { return }
        lastSaved = now
        unsaved = false
        save()
    }

    private func save() {
        guard let cacheFile else { return }
        try? FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(Cache(version: Self.version, transcripts: transcripts)) {
            do {
                try data.write(to: cacheFile, options: .atomic)
            } catch {
                AppLog.note(.fileWriteFailed, .word(.lossCache), .failure(error))
            }
        }
    }
}
