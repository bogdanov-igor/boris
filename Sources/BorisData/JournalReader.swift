import Foundation
import BorisCore

/// Reads `journal.jsonl` from a saved position. An unfinished last line waits for the next read.
public struct JournalReader: Sendable {
    public private(set) var tally = AgentTally()
    public private(set) var offset: UInt64 = 0

    public init() {}

    public mutating func read(_ url: URL) {
        guard let size = FileInfo.size(url) else { return }
        if size < offset {
            // The file was replaced or truncated: start over.
            self = JournalReader()
        }
        guard size > offset, let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil, let data = try? handle.readToEnd(), !data.isEmpty else { return }
        guard let lastNewline = data.lastIndex(of: 0x0A) else { return }

        for line in data[data.startIndex..<lastNewline].split(separator: 0x0A) {
            if let event = Self.parse(line: Data(line)) {
                tally.add(event)
            }
        }
        offset += UInt64(lastNewline - data.startIndex + 1)
    }

    static func parse(line: Data) -> JournalEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String
        else { return nil }
        let kind: JournalEvent.Kind
        switch type {
        case "launched": kind = .launched
        case "started": kind = .started
        case "result": kind = .result
        case "failed": kind = .failed
        default: kind = .unknown(type)
        }
        return JournalEvent(
            kind: kind,
            key: object["key"] as? String,
            agentId: object["agentId"] as? String,
            label: object["label"] as? String,
            phase: object["phase"] as? String,
            toolsUsed: object["toolsUsed"] as? [String]
        )
    }

    /// The agent's result text. Kept out of memory until someone opens the agent.
    public static func result(in url: URL, key: String) -> String? {
        result(in: url, field: "key", value: key)
    }

    public static func result(in url: URL, agentId: String) -> String? {
        result(in: url, field: "agentId", value: agentId)
    }

    private static func result(in url: URL, field: String, value: String) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        var found: String?
        for line in data.split(separator: 0x0A) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  object["type"] as? String == "result",
                  object[field] as? String == value
            else { continue }
            if let text = object["result"] as? String {
                found = text
            } else if let value = object["result"], JSONSerialization.isValidJSONObject(value),
                      let encoded = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) {
                found = String(data: encoded, encoding: .utf8)
            }
        }
        return found
    }
}
