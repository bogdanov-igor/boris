import Foundation
import BorisCore

/// Reads past results for the statistics. Only final files: run counts, not tokens.
public enum HistoryReader {
    public struct Item: Sendable {
        public var run: RunState
        public var date: Date
    }

    public static func finishedRuns(paths: ClaudePaths, since: Date) -> [Item] {
        var items: [Item] = []
        for project in FileInfo.names(in: paths.projects) where !project.hasPrefix(".") {
            let projectDir = paths.projects.appendingPathComponent(project)
            for session in FileInfo.names(in: projectDir) where !session.hasSuffix(".jsonl") && !session.hasPrefix(".") {
                let folder = projectDir.appendingPathComponent(session).appendingPathComponent("workflows")
                for name in FileInfo.names(in: folder) where name.hasPrefix("wf_") && name.hasSuffix(".json") {
                    let url = folder.appendingPathComponent(name)
                    guard let date = FileInfo.modified(url), date >= since, let final = FinalReader.read(url) else { continue }
                    let agents = final.entries.map(\.record)
                    let run = RunState(
                        runId: String(name.dropLast(5)),
                        sessionId: session,
                        name: "",
                        status: StatusRules.status(of: final, journalAgents: []),
                        lastWrite: date,
                        agents: agents,
                        total: final.agentCount ?? agents.count
                    )
                    items.append(Item(run: run, date: date))
                }
            }
        }
        return items
    }
}
