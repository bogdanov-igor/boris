import Foundation
@testable import BorisCore

let t0 = Date(timeIntervalSince1970: 1_800_000_000)

func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

func entry(_ state: String, id: String = UUID().uuidString, error: String? = nil) -> FinalReport.Entry {
    FinalReport.Entry(agentId: id, label: "a", state: state, tokens: 100, error: error)
}

func final(_ status: String, entries: [FinalReport.Entry] = []) -> FinalReport {
    FinalReport(status: status, workflowName: "wf", agentCount: entries.isEmpty ? nil : entries.count, entries: entries)
}

func run(
    id: String = "wf_1",
    session: String = "s1",
    lastWrite: Date = t0,
    final report: FinalReport? = nil,
    finalModified: Date? = nil,
    journalModified: Date? = nil,
    agents: [AgentRecord] = []
) -> RunSnapshot {
    RunSnapshot(
        runId: id,
        sessionId: session,
        cwd: "/tmp/proj",
        lastWrite: lastWrite,
        journalModified: journalModified ?? lastWrite,
        final: report,
        finalModified: report == nil ? nil : (finalModified ?? lastWrite),
        agents: agents
    )
}

func session(id: String = "s1", pid: Int32 = 100, start: Date? = t0.addingTimeInterval(-3600), status: String? = "busy", waitingFor: String? = nil) -> SessionInfo {
    SessionInfo(sessionId: id, pid: pid, cwd: "/tmp/proj", entrypoint: "claude-vscode", status: status, waitingFor: waitingFor, procStart: start)
}

func state(_ status: RunStatus, id: String = "wf_1", session: String = "s1", attempt: Int = 1, agents: [AgentRecord] = []) -> RunState {
    RunState(runId: id, sessionId: session, name: "wf", cwd: "/tmp/proj", status: status, attempt: attempt, lastWrite: t0, agents: agents)
}

/// One tracker pass with a fixed process table.
func resolve(_ tracker: inout RunTracker, _ runSnapshot: RunSnapshot, sessions: [SessionInfo] = [], now: Date, processes: [Int32: Date] = [:]) -> RunState {
    let world = WorldSnapshot(takenAt: now, sessions: sessions, runs: [runSnapshot])
    return tracker.resolve(world) { processes[$0] }[0]
}
