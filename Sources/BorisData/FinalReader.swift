import Foundation
import BorisCore

public enum FinalReader {
    /// Returns nil for JSON that cannot be parsed yet, which usually means the file is still being written.
    public static func read(_ url: URL) -> FinalReport? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parse(data)
    }

    static func parse(_ data: Data) -> FinalReport? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = object["status"] as? String
        else { return nil }

        var titles: [(Int, String)] = []
        var entries: [FinalReport.Entry] = []
        for item in object["workflowProgress"] as? [[String: Any]] ?? [] {
            switch item["type"] as? String {
            case "workflow_phase":
                if let title = item["title"] as? String {
                    titles.append((item["index"] as? Int ?? titles.count, title))
                }
            case "workflow_agent":
                entries.append(FinalReport.Entry(
                    agentId: item["agentId"] as? String,
                    label: item["label"] as? String,
                    phaseTitle: item["phaseTitle"] as? String,
                    phaseIndex: item["phaseIndex"] as? Int,
                    state: item["state"] as? String,
                    tokens: item["tokens"] as? Int,
                    toolCalls: item["toolCalls"] as? Int,
                    durationMs: item["durationMs"] as? Int,
                    model: item["model"] as? String,
                    attempt: item["attempt"] as? Int,
                    error: item["error"] as? String,
                    lastAttemptReason: item["lastAttemptReason"] as? String,
                    lastToolName: item["lastToolName"] as? String
                ))
            default:
                break
            }
        }
        let start = (object["startTime"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        return FinalReport(
            status: status,
            workflowName: object["workflowName"] as? String,
            agentCount: object["agentCount"] as? Int,
            durationMs: object["durationMs"] as? Int,
            totalTokens: object["totalTokens"] as? Int,
            errorFirstLine: (object["error"] as? String)?.split(separator: "\n", maxSplits: 1).first.map(String.init),
            startTime: start,
            taskId: object["taskId"] as? String,
            phaseTitles: titles.sorted { $0.0 < $1.0 }.map(\.1),
            entries: entries
        )
    }
}
