import Foundation

/// The log of one agent. `agentId` is nil for the main agent of a session.
public struct AgentLog: Sendable, Equatable {
    public var agentId: String?
    public var log: ActivityLog

    public init(agentId: String?, log: ActivityLog) {
        self.agentId = agentId
        self.log = log
    }
}

/// One record of a feed and whose it is: a feed can hold many agents and, on the Activity page, many sessions.
public struct FeedEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let sessionId: String
    public let agentId: String?
    public let item: ActivityItem

    public init(sessionId: String, agentId: String?, item: ActivityItem) {
        id = "\(sessionId)/\(agentId ?? "")/\(item.id)"
        self.sessionId = sessionId
        self.agentId = agentId
        self.item = item
    }

    public var step: ActivityStep? {
        if case .step(let step) = item { return step }
        return nil
    }
}

/// Which agents a feed shows.
public enum AgentFilter: Sendable, Hashable {
    case all
    /// Nil is the main agent.
    case one(String?)
}

public enum SessionFeed {
    /// More than this is of no use on one screen and would only slow every update down.
    public static let limit = 1000

    /// The records of several agents in the order they happened, newest last.
    public static func merged(sessionId: String, logs: [AgentLog], limit: Int = SessionFeed.limit) -> [FeedEntry] {
        merged(logs.map { log in log.log.items.map { FeedEntry(sessionId: sessionId, agentId: log.agentId, item: $0) } }, limit: limit)
    }

    /// Several feeds as one, in the order things happened. A record without a time stays right after the one before it.
    public static func merged(_ feeds: [[FeedEntry]], limit: Int = SessionFeed.limit) -> [FeedEntry] {
        var dated: [(at: Date, source: Int, index: Int, entry: FeedEntry)] = []
        for (source, feed) in feeds.enumerated() {
            var last = Date.distantPast
            for (index, entry) in feed.enumerated() {
                last = entry.item.at ?? last
                dated.append((last, source, index, entry))
            }
        }
        dated.sort { a, b in
            if a.at != b.at { return a.at < b.at }
            if a.source != b.source { return a.source < b.source }
            return a.index < b.index
        }
        return dated.suffix(limit).map(\.entry)
    }

    /// What a feed shows while the person reads older records. Those the limit has just dropped stay where they were, or what they are reading would move under them.
    public static func keepingOlder(_ shown: [FeedEntry], next: [FeedEntry]) -> [FeedEntry] {
        let ids = Set(next.map(\.id))
        let gone = shown.filter { !ids.contains($0.id) }
        return gone.isEmpty ? next : merged([gone, next], limit: .max)
    }

    /// The task an agent was given is shown only when that agent is looked at alone: among all agents it would read as the person's own words.
    public static func visible(_ entries: [FeedEntry], agent: AgentFilter) -> [FeedEntry] {
        switch agent {
        case .all:
            return entries.filter { entry in
                if case .prompt = entry.item { return entry.agentId == nil }
                return true
            }
        case .one(let id):
            return entries.filter { $0.agentId == id }
        }
    }

    /// Agents that are busy with no call open, which between two calls means thinking.
    public static func thinking(session: WorkSession, logs: [AgentLog]) -> [String?] {
        var result: [String?] = []
        let byAgent = Dictionary(logs.map { ($0.agentId ?? "", $0.log) }, uniquingKeysWith: { _, last in last })
        if session.root.state == .running, let main = byAgent[""], main.current == nil {
            result.append(nil)
        }
        for node in session.root.children.flatMap(\.flattened) where node.kind != .workflow && node.state == .running {
            if let log = byAgent[node.id], log.current == nil { result.append(node.id) }
        }
        return result
    }

    /// A session waits on its main agent's open call, so that call is not running but waiting for the person.
    public static func isWaiting(_ entry: FeedEntry, session: WorkSession?) -> Bool {
        session?.root.state == .waiting && entry.agentId == nil && entry.step?.state == .running
    }

    /// What the tree calls each agent of a session.
    public static func agentNames(_ session: WorkSession) -> [String: String] {
        var names: [String: String] = [:]
        for node in session.root.children.flatMap(\.flattened) {
            if let name = node.title ?? node.agentType, !name.isEmpty { names[node.id] = name }
        }
        return names
    }

    /// How many records came after the person left the end. `seen` is what was there at that moment, nil while they are at the end.
    /// A record that has gone says nothing: the oldest get dropped, a line of the simple view joins the one before it, and a filter hides records that are not new.
    public static func newCount(ids: [String], seen: Set<String>?) -> Int {
        guard let seen else { return 0 }
        return ids.filter { !seen.contains($0) }.count
    }

    /// The files a session changed, each once, most recently changed last. A call that failed changed nothing.
    public static func changedFiles(_ entries: [FeedEntry]) -> [ChangedFile] {
        var files: [ChangedFile] = []
        for entry in entries {
            guard let step = entry.step, step.isChange, step.state != .failed, let path = step.input.target else { continue }
            let file = files.firstIndex { $0.path == path }.map { files.remove(at: $0) } ?? ChangedFile(path: path)
            var updated = file
            updated.added += step.added ?? 0
            updated.removed += step.removed ?? 0
            updated.steps.append(entry)
            files.append(updated)
        }
        return files
    }
}

/// Which steps of a feed are open. A step that failed or is still going starts open, as that is what the person came to see.
/// What they did by hand stays as they left it, also once the step has finished.
public struct FeedFolding: Sendable, Equatable {
    private var opened: Set<String>
    private var closed: Set<String> = []

    public init(opened: Set<String> = []) {
        self.opened = opened
    }

    public func isOpen(_ step: ActivityStep) -> Bool {
        if opened.contains(step.id) { return true }
        if closed.contains(step.id) { return false }
        return step.state == .running || step.state == .failed
    }

    public mutating func toggle(_ step: ActivityStep) {
        if isOpen(step) {
            opened.remove(step.id)
            closed.insert(step.id)
        } else {
            closed.remove(step.id)
            opened.insert(step.id)
        }
    }
}

/// A file and everything done to it in a session.
public struct ChangedFile: Sendable, Equatable, Identifiable {
    public var id: String { path }
    public let path: String
    public var added = 0
    public var removed = 0
    /// Each change to this file, oldest first.
    public var steps: [FeedEntry] = []

    public init(path: String) {
        self.path = path
    }

    public var name: String { URL(fileURLWithPath: path).lastPathComponent }
}

/// A line of the simple view: steps of one kind in a row, told as one thing.
public struct FeedLine: Sendable, Equatable, Identifiable {
    public var id: String
    public var kind: StepKind
    public var state: StepState
    public var text: String
    public var added: Int
    public var removed: Int
    public var at: Date?
    public var finishedAt: Date?
    public var steps: [FeedEntry]

    /// Files named by the steps of this line, each once.
    public var files: [String] {
        var seen: Set<String> = []
        return steps.compactMap { $0.step?.input.target }.filter { seen.insert($0).inserted }
    }
}

/// Puts a list of steps into plain words. Tool names never get here.
public enum FeedSummary {
    public static func lines(_ entries: [FeedEntry]) -> [FeedLine] {
        var groups: [[FeedEntry]] = []
        for entry in entries {
            guard let step = entry.step, isTold(step) else { continue }
            if let last = groups.last?.last?.step, canJoin(last, step) {
                groups[groups.count - 1].append(entry)
            } else {
                groups.append([entry])
            }
        }
        return groups.compactMap(line)
    }

    /// An action with no words of its own says nothing once it is over, while it runs it is at least "Working".
    /// A prepared answer is the agent's own bookkeeping.
    private static func isTold(_ step: ActivityStep) -> Bool {
        switch step.kind {
        case .answer: return false
        case .other: return step.state == .running || step.state == .failed
        default: return true
        }
    }

    private static func category(_ kind: StepKind) -> StepKind {
        kind == .write ? .edit : kind
    }

    /// Only finished or only running steps join, a failure always stands alone, and each helper has its own task to tell.
    private static func canJoin(_ a: ActivityStep, _ b: ActivityStep) -> Bool {
        guard a.state == b.state, a.state != .failed, category(a.kind) == category(b.kind) else { return false }
        return a.kind != .helper && a.kind != .other
    }

    private static func line(_ group: [FeedEntry]) -> FeedLine? {
        let steps = group.compactMap(\.step)
        guard let first = steps.first, let entry = group.first else { return nil }
        return FeedLine(
            id: entry.id,
            kind: first.kind,
            state: first.state,
            text: text(steps, first: first),
            added: steps.reduce(0) { $0 + ($1.added ?? 0) },
            removed: steps.reduce(0) { $0 + ($1.removed ?? 0) },
            at: first.startedAt,
            finishedAt: steps.last?.finishedAt,
            steps: group
        )
    }

    private static func distinctTargets(_ steps: [ActivityStep]) -> Int {
        max(Set(steps.compactMap(\.input.target)).count, 1)
    }

    private static func text(_ steps: [ActivityStep], first: ActivityStep) -> String {
        switch first.state {
        case .running: return running(steps, first: first)
        case .failed: return PhraseBook.failed(first.kind)
        case .unfinished: return PhraseBook.unfinished(steps: steps.count)
        case .done: return PhraseBook.done(first.kind, steps: steps.count, files: distinctTargets(steps), isSkill: first.tool == "Skill", note: first.input.note)
        }
    }

    private static func running(_ steps: [ActivityStep], first: ActivityStep) -> String {
        if steps.count == 1, first.kind == .shell, let note = first.input.note { return note }
        if steps.count == 1, first.kind == .helper, first.tool != "Skill", let note = first.input.note { return PhraseBook.helperWorking(on: note) }
        // A row in a list says only that files are being read, and the feed is where the step is told in full.
        if first.kind == .read, distinctTargets(steps) == 1, let file = first.brief.fileName { return PhraseBook.readingFile(file) }
        if steps.count > 1, distinctTargets(steps) > 1 {
            // Several at once are told without a name, as there is no one file to name.
            return PhraseBook.doing(StepBrief(kind: first.kind, tool: first.tool))
        }
        return PhraseBook.doing(first.brief)
    }
}
