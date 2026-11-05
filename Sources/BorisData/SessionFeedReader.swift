import BorisCore
import Foundation

/// Follows everything one session writes: its own transcript and the transcripts of the agents under it.
/// It lives only while a feed is on screen, and nothing it holds is written anywhere.
public struct SessionFeedReader: Sendable {
    private let window: UInt64
    private var main: ActivityReader
    private var agents: [String: ActivityReader] = [:]
    private var files: [String: URL] = [:]
    private var transcript: URL?
    /// What an agent's own file calls it, for an agent the tree no longer shows.
    public private(set) var names: [String: String] = [:]

    /// - Parameter window: how much of the end of each big file to start from.
    public init(window: UInt64 = ActivityReader.startWindow) {
        self.window = window
        main = ActivityReader(window: window)
    }

    /// True when a file was too big to read from its start or a log dropped its oldest records, so the feed begins part way.
    public var startedPartWay: Bool {
        ([main] + agents.values).contains { $0.startedPartWay || $0.log.dropped }
    }

    /// Returns true when something new arrived. Costs a look at each file's size when nothing did.
    /// - Parameter withAgents: false reads only the session's own transcript, for a quick first look.
    @discardableResult
    public mutating func read(transcript: URL, withAgents: Bool = true) -> Bool {
        self.transcript = transcript
        var changed = main.read(transcript)
        guard withAgents else { return changed }
        for (id, file) in Self.agentFiles(of: transcript) {
            if files[id] == nil {
                files[id] = file
                agents[id] = ActivityReader(window: window)
                names[id] = Self.name(of: file)
            }
            if agents[id]?.read(file) == true { changed = true }
        }
        return changed
    }

    /// The logs as they should be shown. An agent that has stopped will not get its results any more, so its open calls are over.
    public func logs(live: (String?) -> Bool) -> [AgentLog] {
        var result = [AgentLog(agentId: nil, log: main.log)]
        for id in agents.keys.sorted() {
            guard let log = agents[id]?.log else { continue }
            result.append(AgentLog(agentId: id, log: log))
        }
        for index in result.indices where !live(result[index].agentId) {
            result[index].log.closeRunning()
        }
        return result
    }

    /// The transcript that holds an agent's records.
    public func file(agentId: String?) -> URL? {
        agentId.flatMap { files[$0] } ?? transcript
    }

    /// `<session>/subagents/agent-*.jsonl` and `<session>/subagents/workflows/wf_*/agent-*.jsonl`.
    static func agentFiles(of transcript: URL) -> [(id: String, file: URL)] {
        let folder = transcript.deletingPathExtension().appendingPathComponent("subagents")
        let workflows = folder.appendingPathComponent("workflows")
        let folders = [folder] + FileInfo.names(in: workflows).filter { $0.hasPrefix("wf_") }.map { workflows.appendingPathComponent($0) }
        return folders.flatMap { place in
            FileInfo.names(in: place).compactMap { name -> (id: String, file: URL)? in
                guard name.hasPrefix("agent-"), name.hasSuffix(".jsonl") else { return nil }
                return (String(name.dropFirst("agent-".count).dropLast(".jsonl".count)), place.appendingPathComponent(name))
            }
        }
    }

    private static func name(of agentFile: URL) -> String? {
        let meta = agentFile.deletingPathExtension().appendingPathExtension("meta.json")
        guard let data = try? Data(contentsOf: meta), let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return record["description"] as? String ?? AgentKind.shown(record["agentType"] as? String)
    }
}
