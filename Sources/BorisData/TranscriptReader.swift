import Foundation
import BorisCore

public enum TranscriptReader {
    public struct Tail: Sendable, Equatable {
        public var last: LastRecord?
        public var usage: TokenUsage?
        public var model: String?
        /// The tool call still without a result, if any.
        public var running: StepBrief?
        /// The newest message closes a turn of Claude's, so nothing more is coming unless someone asks.
        public var turnEnded = false
        public var gitBranch: String?

        public init(last: LastRecord? = nil, usage: TokenUsage? = nil, model: String? = nil, running: StepBrief? = nil) {
            self.last = last
            self.usage = usage
            self.model = model
            self.running = running
        }
    }

    public struct Summary: Sendable, Equatable {
        public var tokens = TokenUsage()
        public var tools: [String: Int] = [:]
        public var model: String?
        public var messages = 0
    }

    private static let tailSteps = [64 * 1024, 256 * 1024, 1024 * 1024]

    /// Reads from the end of the file only. A 27 MB transcript costs the same as a small one.
    public static func tail(_ url: URL) -> Tail {
        guard let size = FileInfo.size(url), size > 0, let handle = try? FileHandle(forReadingFrom: url) else { return Tail() }
        defer { try? handle.close() }
        var result = Tail()
        for step in tailSteps {
            result = Tail()
            var finishedTools: Set<String> = []
            var toolKnown = false
            var messageSeen = false
            let length = min(UInt64(step), size)
            guard (try? handle.seek(toOffset: size - length)) != nil, let data = try? handle.read(upToCount: Int(length)) else { break }
            var lines = data.split(separator: 0x0A)
            if length < size, !lines.isEmpty { lines.removeFirst() }
            for line in lines.reversed() {
                guard let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
                if result.last == nil { result.last = lastRecord(record) }
                if result.gitBranch == nil { result.gitBranch = record["gitBranch"] as? String }
                if !messageSeen, let type = record["type"] as? String, type == "assistant" || type == "user" {
                    messageSeen = true
                    result.turnEnded = type == "assistant" && closesTurn(record)
                }
                if result.usage == nil, let (usage, model) = realUsage(record) {
                    result.usage = usage
                    result.model = model
                }
                if !toolKnown { toolKnown = readTool(record, finished: &finishedTools, running: &result.running) }
                // A newest call is always within the records read for these two, so the window never widens for it.
                if result.last != nil, result.usage != nil { return result }
            }
            if length == size { break }
        }
        return result
    }

    private static func closesTurn(_ record: [String: Any]) -> Bool {
        let reason = (record["message"] as? [String: Any])?["stop_reason"] as? String
        return reason == "end_turn" || reason == "stop_sequence"
    }

    /// Walking backwards: the newest call with no result is running. A newest call with one means nothing is.
    private static func readTool(_ record: [String: Any], finished: inout Set<String>, running: inout StepBrief?) -> Bool {
        guard let blocks = (record["message"] as? [String: Any])?["content"] as? [[String: Any]] else { return false }
        for block in blocks.reversed() {
            switch block["type"] as? String {
            case "tool_result":
                if let id = block["tool_use_id"] as? String { finished.insert(id) }
            case "tool_use":
                guard let id = block["id"] as? String, let name = block["name"] as? String else { continue }
                if finished.contains(id) { return true }
                let input = ActivityReader.input(name, block["input"] as? [String: Any] ?? [:])
                let kind = StepKind(tool: name)
                let file = (kind == .read || kind == .edit || kind == .write) ? input.target.map { URL(fileURLWithPath: $0).lastPathComponent } : nil
                running = StepBrief(kind: kind, tool: name, fileName: file, skill: name == "Skill" ? input.target : nil)
                return true
            default:
                break
            }
        }
        return false
    }

    private static func lastRecord(_ record: [String: Any]) -> LastRecord {
        LastRecord(isApiError: record["isApiErrorMessage"] as? Bool ?? false, errorCode: record["error"] as? String, text: text(of: record))
    }

    private static func text(of record: [String: Any]) -> String? {
        guard let message = record["message"] as? [String: Any] else { return nil }
        if let content = message["content"] as? String { return content }
        guard let blocks = message["content"] as? [[String: Any]] else { return nil }
        return blocks.first { $0["type"] as? String == "text" }?["text"] as? String
    }

    /// Error messages carry a synthetic zero usage, which must not hide the real last turn.
    static func realUsage(_ record: [String: Any]) -> (TokenUsage, String?)? {
        guard record["type"] as? String == "assistant", let message = record["message"] as? [String: Any], let usage = usage(message) else { return nil }
        let model = message["model"] as? String
        return model == "<synthetic>" ? nil : (usage, model)
    }

    private static func usage(_ message: [String: Any]) -> TokenUsage? {
        guard let u = message["usage"] as? [String: Any] else { return nil }
        return TokenUsage(
            input: u["input_tokens"] as? Int ?? 0,
            output: u["output_tokens"] as? Int ?? 0,
            cacheRead: u["cache_read_input_tokens"] as? Int ?? 0,
            cacheWrite: u["cache_creation_input_tokens"] as? Int ?? 0
        )
    }

    /// What an ordinary agent said last, which is its result.
    public static func lastText(_ url: URL) -> String? {
        guard let size = FileInfo.size(url), let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let length = min(UInt64(4 * 1024 * 1024), size)
        guard (try? handle.seek(toOffset: size - length)) != nil, let data = try? handle.read(upToCount: Int(length)) else { return nil }
        for line in data.split(separator: 0x0A).reversed() where line.range(of: Data("\"assistant\"".utf8)) != nil {
            guard let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any], record["type"] as? String == "assistant",
                  let blocks = (record["message"] as? [String: Any])?["content"] as? [[String: Any]] else { continue }
            let texts = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            if !texts.isEmpty { return texts.joined(separator: "\n") }
        }
        return nil
    }

    /// The agent's prompt: `message.content` of the first line.
    public static func firstPrompt(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var buffer = Data()
        while let chunk = try? handle.read(upToCount: 256 * 1024), !chunk.isEmpty {
            if let newline = chunk.firstIndex(of: 0x0A) {
                buffer.append(chunk[chunk.startIndex..<newline])
                break
            }
            buffer.append(chunk)
            if buffer.count > 16 * 1024 * 1024 { return nil }
        }
        guard let record = try? JSONSerialization.jsonObject(with: buffer) as? [String: Any] else { return nil }
        return text(of: record)
    }

    /// Walks the whole file once, for agent details and statistics.
    public static func summary(_ url: URL) -> Summary {
        var result = Summary()
        var ledger = TokenLedger()
        forEachLine(url) { line in
            // A cheap check first: most lines are not assistant messages and need no parsing.
            guard line.range(of: Data("\"assistant\"".utf8)) != nil,
                  let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  record["type"] as? String == "assistant",
                  let message = record["message"] as? [String: Any]
            else { return }
            result.messages += 1
            if let usage = usage(message), message["model"] as? String != "<synthetic>" {
                ledger.add(messageId: message["id"] as? String, usage: usage)
                result.model = (message["model"] as? String) ?? result.model
            }
            for block in message["content"] as? [[String: Any]] ?? [] where block["type"] as? String == "tool_use" {
                if let name = block["name"] as? String { result.tools[name, default: 0] += 1 }
            }
        }
        result.tokens = ledger.total
        return result
    }

    static func forEachLine(_ url: URL, _ body: (Data) -> Void) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        var pending = Data()
        while let chunk = try? handle.read(upToCount: 512 * 1024), !chunk.isEmpty {
            pending.append(chunk)
            var start = pending.startIndex
            while let newline = pending[start...].firstIndex(of: 0x0A) {
                if newline > start { body(Data(pending[start..<newline])) }
                start = pending.index(after: newline)
            }
            pending = Data(pending[start...])
        }
        if !pending.isEmpty { body(pending) }
    }

    /// Whether the end of the parent transcript has a `TaskStop` call naming this run.
    public static func hasStopCall(in parent: URL, ids: [String]) -> Bool {
        guard let size = FileInfo.size(parent), let handle = try? FileHandle(forReadingFrom: parent) else { return false }
        defer { try? handle.close() }
        let length = min(UInt64(2 * 1024 * 1024), size)
        guard (try? handle.seek(toOffset: size - length)) != nil, let data = try? handle.read(upToCount: Int(length)) else { return false }
        for line in data.split(separator: 0x0A) where line.range(of: Data("TaskStop".utf8)) != nil {
            if ids.contains(where: { line.range(of: Data($0.utf8)) != nil }) { return true }
        }
        return false
    }

    public struct LaunchInfo: Sendable, Equatable {
        public var workflowName: String?
        public var scriptPath: String?
    }

    /// A run started from a file has no copy in `workflows/scripts`. Its launch result in the parent transcript names it.
    public static func launchInfo(in parent: URL, runId: String) -> LaunchInfo? {
        guard let size = FileInfo.size(parent), let handle = try? FileHandle(forReadingFrom: parent) else { return nil }
        defer { try? handle.close() }
        let length = min(UInt64(8 * 1024 * 1024), size)
        guard (try? handle.seek(toOffset: size - length)) != nil, let data = try? handle.read(upToCount: Int(length)) else { return nil }
        let needle = Data(runId.utf8)
        for line in data.split(separator: 0x0A).reversed() where line.range(of: needle) != nil {
            guard let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let result = record["toolUseResult"] as? [String: Any],
                  result["runId"] as? String == runId
            else { continue }
            return LaunchInfo(workflowName: result["workflowName"] as? String, scriptPath: result["scriptPath"] as? String)
        }
        return nil
    }

    /// The project folder of a session, from its first transcript lines.
    public static func cwd(in parent: URL) -> String? {
        origin(in: parent).cwd
    }

    /// Where a session runs and what started it, from its first transcript lines.
    public static func origin(in parent: URL) -> (cwd: String?, entrypoint: String?, gitBranch: String?) {
        guard let handle = try? FileHandle(forReadingFrom: parent) else { return (nil, nil, nil) }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 256 * 1024) else { return (nil, nil, nil) }
        for line in data.split(separator: 0x0A) {
            if let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any], let cwd = record["cwd"] as? String {
                return (cwd, record["entrypoint"] as? String, record["gitBranch"] as? String)
            }
        }
        return (nil, nil, nil)
    }

    /// The title Claude gave the conversation. It is rewritten often, so its newest copy is close to the end.
    public static func title(in url: URL) -> String? {
        guard let size = FileInfo.size(url), let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let length = min(UInt64(4 * 1024 * 1024), size)
        guard (try? handle.seek(toOffset: size - length)) != nil, let data = try? handle.read(upToCount: Int(length)) else { return nil }
        for line in data.split(separator: 0x0A).reversed() where line.range(of: Data("\"ai-title\"".utf8)) != nil {
            if let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any], record["type"] as? String == "ai-title",
               let title = record["aiTitle"] as? String, !title.isEmpty {
                return title
            }
        }
        return nil
    }
}
