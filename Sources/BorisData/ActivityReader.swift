import Foundation
import BorisCore

/// Follows a transcript as it grows. Starts near the end of a big file, then reads only what was added.
public struct ActivityReader: Sendable {
    public static let startWindow: UInt64 = 4 * 1024 * 1024
    /// One record can reach 8 MB. If it fills the window, the window grows to reach the steps before it.
    public static let widestWindow: UInt64 = 16 * 1024 * 1024

    public private(set) var log = ActivityLog()
    /// True when the file was too big to read from its start, so the feed begins part way.
    public private(set) var startedPartWay = false
    private var offset: UInt64?
    private let window: UInt64

    /// - Parameter window: how much of the end of a big file to start from.
    public init(window: UInt64 = ActivityReader.startWindow) {
        self.window = window
    }

    /// Returns true when something new arrived.
    @discardableResult
    public mutating func read(_ url: URL) -> Bool {
        guard let size = FileInfo.size(url) else { return false }
        if let known = offset {
            if size < known {
                self = ActivityReader(window: window)
                return read(url)
            }
            return consume(url, size: size, from: known, skipFirstLine: false)
        }
        var window = window
        while true {
            startedPartWay = size > window
            log = ActivityLog()
            let changed = consume(url, size: size, from: startedPartWay ? size - window : 0, skipFirstLine: startedPartWay)
            // A huge pasted request alone must not hide the steps before it.
            let hasWork = log.items.contains { if case .prompt = $0 { false } else { true } }
            if hasWork || !startedPartWay || window >= Self.widestWindow { return changed }
            window *= 2
        }
    }

    /// The window may begin inside a record, so its first line is dropped. An unfinished last line waits for the next read.
    /// Foundation keeps buffers and parsed records alive until the pool around them ends, and a screen reads hundreds of files in one go.
    private mutating func consume(_ url: URL, size: UInt64, from start: UInt64, skipFirstLine: Bool) -> Bool {
        autoreleasepool {
            guard size > start, let handle = try? FileHandle(forReadingFrom: url) else { return false }
            defer { try? handle.close() }
            guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd(), let lastNewline = data.lastIndex(of: 0x0A) else { return false }
            var lines = data[data.startIndex..<lastNewline].split(separator: 0x0A)
            if skipFirstLine, !lines.isEmpty { lines.removeFirst() }
            let marker = Data("\"message\"".utf8)
            var changed = false
            for line in lines {
                autoreleasepool {
                    guard line.range(of: marker) != nil, let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { return }
                    for event in Self.events(from: record) {
                        log.apply(event)
                        changed = true
                    }
                }
            }
            offset = start + UInt64(lastNewline - data.startIndex + 1)
            return changed
        }
    }

    /// The writer has stopped, so a call without a result will not get one.
    public mutating func finish() {
        log.closeRunning()
    }

    /// Turns one transcript record into feed events. Other record types carry nothing for the feed.
    static func events(from record: [String: Any]) -> [ActivityEvent] {
        guard let type = record["type"] as? String, type == "assistant" || type == "user",
              let message = record["message"] as? [String: Any]
        else { return [] }
        let at = date(record["timestamp"] as? String)
        if type == "user", let text = promptText(record, content: message["content"]) { return [.prompt(text, at: at)] }
        guard let blocks = message["content"] as? [[String: Any]] else { return [] }
        return blocks.flatMap { block -> [ActivityEvent] in
            switch block["type"] as? String {
            case "tool_use":
                guard let id = block["id"] as? String, let name = block["name"] as? String else { return [] }
                var events: [ActivityEvent] = [.toolUse(id: id, tool: name, input: input(name, block["input"] as? [String: Any] ?? [:]), at: at)]
                if let (usage, _) = TranscriptReader.realUsage(record) { events.append(.tokens(id: id, usage)) }
                return events
            case "tool_result":
                guard let id = block["tool_use_id"] as? String else { return [] }
                var events: [ActivityEvent] = [.toolResult(id: id, isError: block["is_error"] as? Bool ?? false, text: resultText(block["content"]), at: at)]
                let hunks = patch(record)
                if !hunks.isEmpty {
                    events.append(.patch(id: id, hunks))
                } else if overwroteUnseen(record, block: block) {
                    events.append(.overwrote(id: id))
                }
                return events
            case "text":
                guard type == "assistant", let text = block["text"] as? String else { return [] }
                return [.text(text, at: at)]
            default:
                return []
            }
        }
    }

    /// An agent's transcript has no patch, and a call that wrote over a file says only that it did.
    private static func overwroteUnseen(_ record: [String: Any], block: [String: Any]) -> Bool {
        record["toolUseResult"] == nil && resultText(block["content"])?.contains("has been updated") == true
    }

    /// What Claude Code itself says a call changed. Only a session's own transcript has this.
    static func patch(_ record: [String: Any]) -> [DiffHunk] {
        guard let result = record["toolUseResult"] as? [String: Any], let hunks = result["structuredPatch"] as? [[String: Any]] else { return [] }
        return hunks.compactMap { hunk in
            guard let lines = hunk["lines"] as? [String] else { return nil }
            return DiffHunk(oldStart: hunk["oldStart"] as? Int ?? 1, newStart: hunk["newStart"] as? Int ?? 1, lines: lines)
        }
    }

    /// What a person wrote. Claude Code also records its own insertions as user messages: they are marked, or wrapped in a tag.
    private static func promptText(_ record: [String: Any], content: Any?) -> String? {
        for mark in ["isMeta", "isCompactSummary", "isVisibleInTranscriptOnly"] where record[mark] as? Bool == true { return nil }
        let text: String
        if let plain = content as? String {
            text = plain
        } else if let blocks = content as? [[String: Any]], !blocks.contains(where: { $0["type"] as? String == "tool_result" }) {
            text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.filter { !$0.hasPrefix("<") }.joined(separator: "\n")
        } else {
            return nil
        }
        return text.isEmpty || text.hasPrefix("<") ? nil : text
    }

    static func input(_ tool: String, _ input: [String: Any]) -> ToolInput {
        var result = ToolInput()
        switch tool {
        case "Bash", "Monitor":
            result.command = input["command"] as? String
            result.note = input["description"] as? String
        case "Edit":
            result.target = input["file_path"] as? String
            result.oldText = input["old_string"] as? String
            result.newText = input["new_string"] as? String
        case "MultiEdit":
            result.target = input["file_path"] as? String
            let edits = input["edits"] as? [[String: Any]] ?? []
            result.oldText = edits.compactMap { $0["old_string"] as? String }.joined(separator: "\n")
            result.newText = edits.compactMap { $0["new_string"] as? String }.joined(separator: "\n")
        case "Write":
            result.target = input["file_path"] as? String
            result.newText = input["content"] as? String
        case "NotebookEdit":
            result.target = input["notebook_path"] as? String
            result.newText = input["new_source"] as? String
        case "Read":
            result.target = input["file_path"] as? String ?? input["notebook_path"] as? String
        case "Grep", "Glob":
            result.target = input["pattern"] as? String
            result.note = input["path"] as? String
        case "LS":
            result.target = input["path"] as? String
        case "WebFetch":
            result.target = input["url"] as? String
        case "WebSearch":
            result.command = input["query"] as? String
        case "Agent", "Task":
            result.note = input["description"] as? String
            result.command = input["prompt"] as? String
        case "Skill":
            result.target = input["skill"] as? String
        case "Workflow":
            result.target = (input["scriptPath"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent }
        default:
            result.target = mcpName(tool)
            result.command = parameters(input)
        }
        return result
    }

    /// `mcp__postgres__query` becomes `postgres · query`.
    private static func mcpName(_ tool: String) -> String? {
        guard tool.hasPrefix("mcp__") else { return nil }
        let parts = tool.dropFirst("mcp__".count).components(separatedBy: "__")
        return parts.joined(separator: " · ")
    }

    /// A tool Boris knows nothing about still shows what it was asked to do.
    private static func parameters(_ input: [String: Any]) -> String? {
        guard !input.isEmpty, let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]) else { return nil }
        return ResultFormat.pretty(String(decoding: data, as: UTF8.self))
    }

    /// A whole call, read again from the transcript because the feed keeps only the start of long texts.
    public struct FullStep: Sendable, Equatable {
        public var input: ToolInput
        public var hunks: [DiffHunk]
        public var output: String?
        /// The records of the call and of its result, exactly as Claude Code wrote them.
        public var raw: String
    }

    /// Goes through the file, so it runs only when someone asks, and off the main thread. Nothing it returns is kept on disk.
    public static func fullStep(_ id: String, in url: URL) -> FullStep? {
        let needle = Data(id.utf8)
        var full = FullStep(input: ToolInput(), hunks: [], output: nil, raw: "")
        var foundCall = false
        var raw: [String] = []
        TranscriptReader.forEachLine(url) { line in
            guard line.range(of: needle) != nil, let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let blocks = (record["message"] as? [String: Any])?["content"] as? [[String: Any]]
            else { return }
            for block in blocks {
                if block["type"] as? String == "tool_use", block["id"] as? String == id, let name = block["name"] as? String {
                    full.input = input(name, block["input"] as? [String: Any] ?? [:])
                    foundCall = true
                    raw.append(String(decoding: line, as: UTF8.self))
                } else if block["type"] as? String == "tool_result", block["tool_use_id"] as? String == id {
                    full.output = resultText(block["content"])
                    full.hunks = patch(record)
                    raw.append(String(decoding: line, as: UTF8.self))
                }
            }
        }
        guard foundCall else { return nil }
        full.raw = raw.joined(separator: "\n")
        return full
    }

    private static func resultText(_ content: Any?) -> String? {
        if let text = content as? String { return text }
        guard let blocks = content as? [[String: Any]] else { return nil }
        let texts = blocks.compactMap { $0["text"] as? String }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    private static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
}
