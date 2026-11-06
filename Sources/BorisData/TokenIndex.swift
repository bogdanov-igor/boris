import BorisCore
import Foundation

/// Real spend from every transcript Claude still keeps.
///
/// It reads only what was added since last time and remembers that in a cache file. The file holds nothing but numbers and ids,
/// and nothing is lost without it: the next update builds everything again from the logs.
public actor TokenIndex {
    private struct Bucket: Codable {
        var day: String
        var model: String?
        var usage: TokenUsage
    }

    private struct Entry: Codable {
        var size: UInt64
        var offset: UInt64
        var cwd: String?
        var entrypoint: String?
        var buckets: [Bucket]
        /// Every message counted in this file, so a repeat in another file is not counted again.
        var ids: [String]
        /// The newest messages with what they showed last: a message grows while it streams.
        var recent: [String: TokenUsage]
        var order: [String]
    }

    private struct Cache: Codable {
        var version: Int
        var entries: [String: Entry]
    }

    private static let version = 1
    private static let recentLimit = 64
    private static let chunk = 1024 * 1024
    /// The whole cache is rewritten each time, which costs far more than reading what was added. Losing a minute of it only means reading that minute again.
    private static let saveInterval: TimeInterval = 60
    private static let usageMarker = Data("\"usage\"".utf8)
    private static let assistantMarker = Data("\"assistant\"".utf8)

    private let cacheFile: URL?
    private var entries: [String: Entry] = [:]
    private var seen: Set<String> = []
    private var loaded = false
    private var unsaved = false
    private var lastSaved: Date?
    private let timestamps: ISO8601DateFormatter
    private let dayKeys: DateFormatter

    /// - Parameter cacheFile: nil keeps everything in memory.
    public init(cacheFile: URL?, timeZone: TimeZone = .current) {
        self.cacheFile = cacheFile
        let timestamps = ISO8601DateFormatter()
        timestamps.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.timestamps = timestamps
        let dayKeys = DateFormatter()
        dayKeys.locale = Locale(identifier: "en_US_POSIX")
        dayKeys.timeZone = timeZone
        dayKeys.dateFormat = "yyyy-MM-dd"
        self.dayKeys = dayKeys
    }

    /// Done on first use rather than when created, which can be on the main thread.
    private func loadCache() {
        guard !loaded else { return }
        loaded = true
        guard let cacheFile,
              let data = try? Data(contentsOf: cacheFile),
              let cache = try? JSONDecoder().decode(Cache.self, from: data),
              cache.version == Self.version
        else { return }
        entries = cache.entries
        seen = Set(cache.entries.values.flatMap(\.ids))
    }

    /// Brings the index up to date. A transcript that Claude has deleted leaves the totals with it.
    /// - Parameter progress: how many transcripts are done and how many there are.
    /// - Returns: true if anything changed.
    @discardableResult
    public func update(roots: [ClaudePaths], progress: (@Sendable (Int, Int) -> Void)? = nil) async -> Bool {
        loadCache()
        let files = Self.transcripts(in: roots)
        var changed = false

        let existing = Set(files.map(\.path))
        for path in entries.keys where !existing.contains(path) {
            forget(path)
            changed = true
        }
        for (index, file) in files.enumerated() {
            // Without its own pool a long pass keeps every buffer it has read until it ends.
            if autoreleasepool(invoking: { read(file) }) { changed = true }
            progress?(index + 1, files.count)
            // Other work gets its turn, however many logs there are.
            await Task.yield()
        }
        saveWhenDue(changed: changed)
        return changed
    }

    /// Reads only the folders the file system says have changed, so the cost follows what is being written and not how much history there is.
    /// Something deleted, or a change that was never reported, waits for the next `update(roots:)`.
    /// - Returns: true if anything changed.
    @discardableResult
    public func update(folders: Set<String>, roots: [ClaudePaths]) async -> Bool {
        loadCache()
        var changed = false
        for folder in folders.sorted() {
            for file in Self.transcripts(inFolder: folder, roots: roots) where autoreleasepool(invoking: { read(file) }) {
                changed = true
            }
            await Task.yield()
        }
        saveWhenDue(changed: changed)
        return changed
    }

    /// What has not reached the cache yet. For whoever is done with the index.
    public func flush() {
        if unsaved { save() }
    }

    public func records() -> [TokenRecord] {
        loadCache()
        var result: [TokenRecord] = []
        for (path, entry) in entries {
            let owner = Self.owner(ofTranscript: path)
            for bucket in entry.buckets {
                result.append(TokenRecord(
                    sessionId: owner.session,
                    agentId: owner.agent,
                    runId: owner.run,
                    cwd: entry.cwd,
                    entrypoint: entry.entrypoint,
                    day: bucket.day,
                    model: bucket.model,
                    usage: bucket.usage
                ))
            }
        }
        return result
    }

    /// The oldest day there is data for.
    public func earliestDay() -> String? {
        loadCache()
        return entries.values.flatMap(\.buckets).map(\.day).min()
    }

    private func forget(_ path: String) {
        guard let entry = entries.removeValue(forKey: path) else { return }
        seen.subtract(entry.ids)
    }

    private func read(_ url: URL) -> Bool {
        guard let size = FileInfo.size(url) else { return false }
        if let known = entries[url.path], size == known.size { return false }
        // A file that shrank was rewritten, so it starts over.
        if let known = entries[url.path], size < known.offset { forget(url.path) }

        var entry = entries[url.path] ?? Entry(size: size, offset: 0, buckets: [], ids: [], recent: [:], order: [])
        let fallbackDay = dayKeys.string(from: FileInfo.modified(url) ?? Date())
        guard let handle = try? FileHandle(forReadingFrom: url), (try? handle.seek(toOffset: entry.offset)) != nil else { return false }
        defer { try? handle.close() }

        var pending = Data()
        while let data = try? handle.read(upToCount: Self.chunk), !data.isEmpty {
            pending.append(data)
            guard let newline = pending.lastIndex(of: 0x0A) else { continue }
            let complete = pending[pending.startIndex..<newline]
            for line in complete.split(separator: 0x0A) where line.range(of: Self.usageMarker) != nil && line.range(of: Self.assistantMarker) != nil {
                add(line: line, to: &entry, fallbackDay: fallbackDay)
            }
            entry.offset += UInt64(newline - pending.startIndex + 1)
            pending = Data(pending[pending.index(after: newline)...])
        }
        entry.size = size
        entries[url.path] = entry
        return true
    }

    private func add(line: Data, to entry: inout Entry, fallbackDay: String) {
        guard let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              let (usage, model) = TranscriptReader.realUsage(record)
        else { return }
        entry.cwd = entry.cwd ?? record["cwd"] as? String
        entry.entrypoint = entry.entrypoint ?? record["entrypoint"] as? String

        var growth = usage
        if let id = (record["message"] as? [String: Any])?["id"] as? String {
            if let previous = entry.recent[id] {
                growth = usage.growth(since: previous)
            } else if seen.contains(id) {
                // A fork starts with its parent's messages. They were already paid for once.
                return
            } else {
                seen.insert(id)
                entry.ids.append(id)
                entry.order.append(id)
                if entry.order.count > Self.recentLimit {
                    entry.recent[entry.order.removeFirst()] = nil
                }
            }
            entry.recent[id] = usage
        }

        let day = (record["timestamp"] as? String).flatMap { timestamps.date(from: $0) }.map { dayKeys.string(from: $0) } ?? fallbackDay
        if let index = entry.buckets.firstIndex(where: { $0.day == day && $0.model == model }) {
            entry.buckets[index].usage = entry.buckets[index].usage + growth
        } else {
            entry.buckets.append(Bucket(day: day, model: model, usage: growth))
        }
    }

    private func saveWhenDue(changed: Bool, now: Date = Date()) {
        if changed { unsaved = true }
        guard unsaved else { return }
        if let lastSaved, now.timeIntervalSince(lastSaved) < Self.saveInterval { return }
        lastSaved = now
        save()
    }

    private func save() {
        unsaved = false
        guard let cacheFile else { return }
        try? FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(Cache(version: Self.version, entries: entries)) {
            do {
                try data.write(to: cacheFile, options: .atomic)
            } catch {
                AppLog.note(.fileWriteFailed, .word(.tokenCache), .failure(error))
            }
        }
    }

    /// The main transcript comes before its subagents, so a fork's repeats are the ones left out.
    static func transcripts(in roots: [ClaudePaths]) -> [URL] {
        var files: [URL] = []
        let hidden = BorisPaths.usageProbeProject
        for root in roots {
            for project in FileInfo.names(in: root.projects) where !project.hasPrefix(".") && project != hidden {
                let folder = root.projects.appendingPathComponent(project)
                for name in FileInfo.names(in: folder) where !name.hasPrefix(".") {
                    let item = folder.appendingPathComponent(name)
                    if name.hasSuffix(".jsonl") {
                        files.append(item)
                    } else {
                        files += agentFiles(in: item.appendingPathComponent("subagents"))
                        let workflows = item.appendingPathComponent("subagents/workflows")
                        for run in FileInfo.names(in: workflows) where run.hasPrefix("wf_") {
                            files += agentFiles(in: workflows.appendingPathComponent(run))
                        }
                    }
                }
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    /// The transcripts lying directly in one folder, by the same rules as `transcripts(in:)`. Anything else in Claude's folders holds none.
    /// The file system reports real paths while the folder may be reached through a link, so they are compared resolved, and what comes back is spelled as a whole pass spells it.
    static func transcripts(inFolder path: String, roots: [ClaudePaths]) -> [URL] {
        let inner = URL(fileURLWithPath: path).resolvingSymlinksInPath().pathComponents
        for root in roots {
            let outer = root.projects.resolvingSymlinksInPath().pathComponents
            guard inner.count > outer.count, Array(inner.prefix(outer.count)) == outer else { continue }
            let parts = Array(inner.dropFirst(outer.count))
            guard !parts[0].hasPrefix("."), parts[0] != BorisPaths.usageProbeProject else { return [] }
            let folder = parts.reduce(root.projects) { $0.appendingPathComponent($1) }
            switch parts.count {
            case 1:
                return FileInfo.names(in: folder)
                    .filter { $0.hasSuffix(".jsonl") && !$0.hasPrefix(".") }
                    .map { folder.appendingPathComponent($0) }
            case 3 where parts[2] == "subagents":
                return agentFiles(in: folder)
            case 5 where parts[2] == "subagents" && parts[3] == "workflows" && parts[4].hasPrefix("wf_"):
                return agentFiles(in: folder)
            default:
                return []
            }
        }
        return []
    }

    private static func agentFiles(in folder: URL) -> [URL] {
        FileInfo.names(in: folder)
            .filter { $0.hasPrefix("agent-") && $0.hasSuffix(".jsonl") }
            .map { folder.appendingPathComponent($0) }
    }

    /// Whose transcript this is, from where it lies: `<session>.jsonl`, `<session>/subagents/agent-<id>.jsonl` or `<session>/subagents/workflows/<run>/agent-<id>.jsonl`.
    static func owner(ofTranscript path: String) -> (session: String, agent: String?, run: String?) {
        let parts = path.split(separator: "/").map(String.init)
        let name = parts.last ?? ""
        guard name.hasPrefix("agent-") else {
            return (String(name.dropLast(".jsonl".count)), nil, nil)
        }
        let agent = String(name.dropFirst("agent-".count).dropLast(".jsonl".count))
        guard let subagents = parts.lastIndex(of: "subagents"), subagents > 0 else {
            return ("", agent, nil)
        }
        let run = parts.count > subagents + 2 && parts[subagents + 1] == "workflows" ? parts[subagents + 2] : nil
        return (parts[subagents - 1], agent, run)
    }
}
