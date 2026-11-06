import BorisCore
import Foundation

/// Adds up the real spend of transcripts as they grow, reading only what was added.
/// A message is written several times while it streams, so a repeat counts only by what it grew.
public struct LiveTokenMeter: Sendable {
    private struct Follow: Sendable {
        var offset: UInt64
        var total = TokenUsage()
        var recent: [String: TokenUsage] = [:]
        var order: [String] = []
    }

    private static let recentLimit = 64
    private static let chunk = 1024 * 1024
    private static let usageMarker = Data("\"usage\"".utf8)
    private static let assistantMarker = Data("\"assistant\"".utf8)

    private var files: [String: Follow] = [:]

    public init() {}

    /// Returns what was added since the last read.
    /// - Parameter fromStart: for a file seen for the first time. If false, only what comes from now on counts.
    public mutating func read(_ url: URL, fromStart: Bool) -> TokenUsage {
        guard let size = FileInfo.size(url) else { return TokenUsage() }
        var follow = files[url.path] ?? Follow(offset: fromStart ? 0 : size)
        if size < follow.offset { follow = Follow(offset: 0) }
        var growth = TokenUsage()
        if size > follow.offset, let handle = try? FileHandle(forReadingFrom: url), (try? handle.seek(toOffset: follow.offset)) != nil {
            defer { try? handle.close() }
            var pending = Data()
            // Each chunk and what was parsed from it go before the next one comes.
            while autoreleasepool(invoking: {
                guard let data = try? handle.read(upToCount: Self.chunk), !data.isEmpty else { return false }
                pending.append(data)
                guard let newline = pending.lastIndex(of: 0x0A) else { return true }
                let complete = pending[pending.startIndex..<newline]
                for line in complete.split(separator: 0x0A) where line.range(of: Self.usageMarker) != nil && line.range(of: Self.assistantMarker) != nil {
                    growth = growth + Self.add(line: line, to: &follow)
                }
                follow.offset += UInt64(newline - pending.startIndex + 1)
                pending = Data(pending[pending.index(after: newline)...])
                return true
            }) {}
        }
        follow.total = follow.total + growth
        files[url.path] = follow
        return growth
    }

    public func total(of url: URL) -> TokenUsage {
        files[url.path]?.total ?? TokenUsage()
    }

    public mutating func forget(_ url: URL) {
        files[url.path] = nil
    }

    private static func add(line: Data, to follow: inout Follow) -> TokenUsage {
        guard let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              let (usage, _) = TranscriptReader.realUsage(record)
        else { return TokenUsage() }
        guard let id = (record["message"] as? [String: Any])?["id"] as? String else { return usage }
        let growth = usage.growth(since: follow.recent[id] ?? TokenUsage())
        if follow.recent[id] == nil {
            follow.order.append(id)
            if follow.order.count > recentLimit {
                follow.recent[follow.order.removeFirst()] = nil
            }
        }
        follow.recent[id] = usage
        return growth
    }
}
