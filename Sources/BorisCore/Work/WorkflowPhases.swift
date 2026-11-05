/// The agents of one phase of a workflow, counted by how they are doing.
public struct WorkflowPhase: Sendable, Equatable, Identifiable {
    public var id: String { title ?? "" }
    /// Nil for agents without a phase.
    public var title: String?
    public var isCurrent: Bool
    public var agents: [WorkNode]
    public var done = 0
    public var running = 0
    public var failed = 0
    public var cancelled = 0

    public init(title: String?, isCurrent: Bool = false, agents: [WorkNode] = []) {
        self.title = title
        self.isCurrent = isCurrent
        self.agents = agents
        for node in agents.flatMap(\.flattened) where node.kind != .workflow {
            switch node.state {
            case .finished: done += 1
            case .running, .silent, .waiting: running += 1
            case .failed: failed += 1
            case .stopped, .interrupted: cancelled += 1
            }
        }
    }

    public var total: Int { done + running + failed + cancelled }
    /// The script plans it, but no agent has started it yet.
    public var isAhead: Bool { agents.isEmpty }
}

extension WorkNode {
    /// The workflow's agents by phase, in the order of the plan. A phase still ahead is shown only while the run can reach it.
    public var phases: [WorkflowPhase] {
        guard let details = workflow else { return [] }
        let known = details.phases.isEmpty ? details.planned.map { PhaseGroup(title: $0, agents: []) } : details.phases
        var byTitle = Dictionary(grouping: children, by: \.phase)
        var result: [WorkflowPhase] = []
        for group in known {
            result.append(WorkflowPhase(title: group.title, isCurrent: group.isCurrent, agents: byTitle.removeValue(forKey: group.title) ?? []))
        }
        // Agents the final file knows and the plan does not. A list stays complete even when the two disagree.
        for title in children.map(\.phase).reduce(into: [String?](), { if !$0.contains($1) { $0.append($1) } }) {
            if let agents = byTitle.removeValue(forKey: title) { result.append(WorkflowPhase(title: title, agents: agents)) }
        }
        return details.status.isActive ? result : result.filter { !$0.isAhead }
    }
}
