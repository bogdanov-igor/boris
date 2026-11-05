import Foundation

public enum RunStatus: Codable, Sendable, Equatable, Hashable {
    case running
    case silent
    case completed
    case completedWithErrors
    case allAgentsFailed
    case failed
    case stopped
    case interrupted
    case unknown(String)

    public var isActive: Bool { self == .running || self == .silent }
    public var isTerminal: Bool { !isActive }

    /// Stable name for memory keys and statistics.
    public var key: String {
        switch self {
        case .running: return "running"
        case .silent: return "silent"
        case .completed: return "completed"
        case .completedWithErrors: return "completedWithErrors"
        case .allAgentsFailed: return "allAgentsFailed"
        case .failed: return "failed"
        case .stopped: return "stopped"
        case .interrupted: return "interrupted"
        case .unknown(let raw): return "unknown:\(raw)"
        }
    }
}

public struct StatusConfig: Sendable, Equatable {
    public var silenceThreshold: TimeInterval
    public var deathGrace: TimeInterval
    public var clockTolerance: TimeInterval

    public init(silenceThreshold: TimeInterval = 12 * 60, deathGrace: TimeInterval = 8, clockTolerance: TimeInterval = 2) {
        self.silenceThreshold = silenceThreshold
        self.deathGrace = deathGrace
        self.clockTolerance = clockTolerance
    }
}

public enum StatusRules {
    /// A final file older than the journal belongs to an earlier attempt and does not count.
    public static func validFinal(_ run: RunSnapshot) -> FinalReport? {
        guard let final = run.final else { return nil }
        if let finalModified = run.finalModified, let journalModified = run.journalModified, finalModified < journalModified {
            return nil
        }
        return final
    }

    /// Status of a run that has a valid final file.
    public static func status(of final: FinalReport, journalAgents: [AgentRecord]) -> RunStatus {
        switch final.status {
        case "completed":
            let failed: Int
            let total: Int
            if final.entries.isEmpty {
                failed = journalAgents.filter { $0.state == .failed }.count
                total = journalAgents.count
            } else {
                failed = final.entries.filter { $0.state == "error" }.count
                total = final.entries.count
            }
            if failed == 0 { return .completed }
            return failed == total ? .allAgentsFailed : .completedWithErrors
        case "failed":
            return .failed
        case "killed":
            return .stopped
        default:
            return .unknown(final.status)
        }
    }

    /// Whether the session file proves its process is the real, current owner of the run.
    public static func sessionOwnsRun(_ session: SessionInfo, lastWrite: Date, processStart: Date?, config: StatusConfig) -> Bool {
        guard let processStart else { return false }
        if let declared = session.procStart, abs(processStart.timeIntervalSince(declared)) > config.clockTolerance {
            return false
        }
        return processStart <= lastWrite.addingTimeInterval(config.clockTolerance)
    }
}
