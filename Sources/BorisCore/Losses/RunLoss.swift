import Foundation

/// What a workflow lost, by one rule for the Losses page, the failures of a session and project, and notifications.
public enum RunLoss {
    /// Only these words mean the run was stopped. Something else that was aborted, such as a request on a timeout, is a real failure.
    public static func isRunStop(_ text: String?) -> Bool {
        text?.lowercased().contains("workflow aborted") == true
    }

    /// An agent that fell. Agents at work when a run was stopped were stopped with it: an abort is that same stop as told by the agent,
    /// and an agent with no error of its own has nothing else to tell.
    public static func fell(_ agent: AgentRecord, runKilled: Bool) -> Bool {
        agent.state == .failed && !isRunStop(agent.failure?.text) && !(runKilled && agent.failure?.text == nil)
    }

    /// The same rule for an agent's line in the tree, under its workflow's line. A stopped workflow is one whose run was killed.
    public static func fell(_ node: WorkNode, in workflow: WorkflowDetails) -> Bool {
        node.state == .failed && !isRunStop(node.failure?.text) && !(workflow.status == .stopped && node.failure?.text == nil)
    }

    /// A failed run's own error, as a reason. When its agents failed, that error is usually just theirs, and only something else counts on its own.
    public static func scriptFailure(status: String?, error: String?, anyFallen: Bool) -> LossReason? {
        guard status == "failed", !isRunStop(error) else { return nil }
        let failure = FailureClassifier.classify(nil, reason: error).failureClass
        guard failure == .unknown || !anyFallen else { return nil }
        return failure == .unknown ? .script : LossReason(failure)
    }

    /// When a run ended, as both the Losses page and a session's failures date it.
    public static func endedAt(final: FinalReport?, finalModified: Date?, journalModified: Date?) -> Date? {
        if let start = final?.startTime, let duration = final?.durationMs { return start.addingTimeInterval(Double(duration) / 1000) }
        return finalModified ?? journalModified
    }

    /// A run's agents once it has a result: as the result names them, each with the attempts the journal knows before it,
    /// and then every agent of the journal the result no longer names, such as one that fell in an earlier attempt. Each wrote a file, and each is the run's.
    /// One that never got to start has an empty id in the journal and is listed in the result without one.
    public static func agents(final: FinalReport, journal: [AgentRecord]) -> [AgentRecord] {
        let listed = Set(final.entries.compactMap(\.agentId))
        var alone = journal.filter { agent in agent.agentId.map { !$0.isEmpty && !listed.contains($0) } == true }
        let own = listed.union(alone.compactMap(\.agentId))
        var claimed: Set<String> = []
        let named = final.entries.map { entry -> AgentRecord in
            var record = entry.record
            if let id = entry.agentId, let known = journal.first(where: { $0.agentId == id || $0.earlierAgentIds.contains(id) }) {
                record.earlierAgentIds = ([known.agentId].compactMap { $0 } + known.earlierAgentIds).filter { $0 != id && !$0.isEmpty && !own.contains($0) }
                claimed.formUnion(record.earlierAgentIds)
            }
            return record
        }
        for index in alone.indices {
            alone[index].earlierAgentIds = alone[index].earlierAgentIds.filter { !own.contains($0) && !claimed.contains($0) }
            claimed.formUnion(alone[index].earlierAgentIds)
        }
        return named + alone
    }

    /// The node id of a workflow's agent, which is also how its losses name it.
    public static func nodeId(_ agent: AgentRecord, runId: String) -> String {
        agent.agentId ?? "\(runId)/\(agent.key)"
    }
}
