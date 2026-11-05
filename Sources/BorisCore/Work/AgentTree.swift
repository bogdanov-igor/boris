/// One line of a session's agent tree. The tree is shown as a flat list, so a run of hundreds of agents costs only the lines on screen.
public struct AgentTreeRow: Sendable, Equatable, Identifiable {
    public enum Content: Sendable, Equatable {
        case agent(WorkNode)
        case workflow(WorkNode)
        /// - Parameter isOnly: without any named phase, its agents are simply the agents.
        case phase(WorkflowPhase, workflowId: String, isOnly: Bool)
    }

    /// A workflow is drawn as a card made of its lines.
    public enum CardEdge: Sendable, Equatable {
        case none, top, middle, bottom, whole
    }

    public var id: String
    public var depth: Int
    public var content: Content
    public var edge = CardEdge.none
    /// How deep the card this line belongs to starts.
    public var cardDepth = 0
}

public enum AgentTree {
    public static func phaseKey(workflow: String, phase: String?) -> String {
        "\(workflow)#\(phase ?? "")"
    }

    /// - Parameter expanded: the keys of the phases that are open. All the others are folded into one line with a count.
    public static func rows(root: WorkNode, expanded: Set<String>) -> [AgentTreeRow] {
        var rows = [AgentTreeRow(id: root.id, depth: 0, content: .agent(root))]
        for child in root.children {
            // A workflow is not one of the agents, so it starts at the left edge, as a thing of its own.
            add(child, depth: child.kind == .workflow ? 0 : 1, card: nil, expanded: expanded, to: &rows)
        }
        return rows
    }

    private static func add(_ node: WorkNode, depth: Int, card: Int?, expanded: Set<String>, to rows: inout [AgentTreeRow]) {
        guard node.kind == .workflow else {
            var row = AgentTreeRow(id: node.id, depth: depth, content: .agent(node))
            if let card {
                row.edge = .middle
                row.cardDepth = card
            }
            rows.append(row)
            for child in node.children { add(child, depth: depth + 1, card: card, expanded: expanded, to: &rows) }
            return
        }
        let first = rows.count
        let edge = card ?? depth
        rows.append(AgentTreeRow(id: node.id, depth: depth, content: .workflow(node), edge: .middle, cardDepth: edge))
        let phases = node.phases
        for phase in phases {
            let key = phaseKey(workflow: node.id, phase: phase.title)
            rows.append(AgentTreeRow(id: key, depth: depth, content: .phase(phase, workflowId: node.id, isOnly: phases.count == 1), edge: .middle, cardDepth: edge))
            if expanded.contains(key) {
                for agent in phase.agents { add(agent, depth: depth + 1, card: edge, expanded: expanded, to: &rows) }
            }
        }
        // Only the outermost workflow draws a card. One inside it stays a part of that card.
        guard card == nil else { return }
        if rows.count == first + 1 {
            rows[first].edge = .whole
        } else {
            rows[first].edge = .top
            rows[rows.count - 1].edge = .bottom
        }
    }
}
