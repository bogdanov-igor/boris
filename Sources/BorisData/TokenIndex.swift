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
    private static let usageMarker = Data("\"usage\"".utf8)
    private static let assistantMarker = Data("\"assistant\"".utf8)

    private let cacheFile: URL?
    private var entries: [String: Entry] = [:]
    private var seen: Set<String> = []
    private var editors: EditorBook?
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
        if let cacheFile,
           let data = try? Data(contentsOf: cacheFile),
           let cache = try? JSONDecoder().decode(Cache.self, from: data),
           cache.version == Self.version {
            entries = cache.entries
            seen = Set(cache.entries.values.flatMap(\.ids))
        }
    }

    /// Brings the index up to date. A transcript that Claude has deleted leaves the totals with it, and so does one whose source is off:
    /// turning the source on reads it again from the logs.
    /// - Parameters:
    ///   - filter: which sources are left alone.
    ///   - progress: how many transcripts are done and how many there are.
    /// - Returns: true if anything changed.
    @discardableResult
    public func update(roots: [ClaudePaths], filter: SourceFilter = SourceFilter(), progress: (@Sendable (Int, Int) -> Void)? = nil) async -> Bool {
        editors = filter.editors
        let files = Self.transcripts(in: roots.filter(filter.reads(root:)), filter: filter)
        var changed = false

        let existing = Set(files.map(\.path))
        for path in entries.keys where !existing.contains(path) {
            forget(path)
            changed = true
        }
        for (index, file) in files.enumerated() {
            if read(file) { changed = true }
            progress?(index + 1, files.count)
            // Other work gets its turn, however many logs there are.
            await Task.yield()
        }
        if changed { save() }
        return changed
    }

    public func records() -> [TokenRecord] {
        var result: [TokenRecord] = []
        for (path, entry) in entries {
            let owner = Self.owner(ofTranscript: path)
            for bucket in entry.buckets {
                result.append(TokenRecord(
                    sessionId: owner.session,
                    agentId: owner.agent,
                    runId: owner.run,
                    cwd: entry.cwd,
                    entrypoint: editors?.entrypoint(entry.entrypoint, session: owner.session) ?? entry.entrypoint,
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
        entries.values.flatMap(\.buckets).map(\.day).min()
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

    private func save() {
        guard let cacheFile else { return }
        try? FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(Cache(version: Self.version, entries: entries)) {
            try? data.write(to: cacheFile, options: .atomic)
        }
    }

    /// The main transcript comes before its subagents, so a fork's repeats are the ones left out.
    static func transcripts(in roots: [ClaudePaths], filter: SourceFilter = SourceFilter()) -> [URL] {
        var files: [URL] = []
        let hidden = BorisPaths.usageProbeProject
        for root in roots {
            for project in FileInfo.names(in: root.projects) where !project.hasPrefix(".") && project != hidden {
                let folder = root.projects.appendingPathComponent(project)
                for name in FileInfo.names(in: folder) where !name.hasPrefix(".") {
                    let item = folder.appendingPathComponent(name)
                    if name.hasSuffix(".jsonl") {
                        if filter.allows(transcript: item) { files.append(item) }
                    } else if filter.allows(transcript: folder.appendingPathComponent("\(name).jsonl")) {
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
