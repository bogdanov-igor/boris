import Foundation

/// Puts what was read from disk together into projects, sessions and trees of agents.
public enum WorkBuilder {
    public static func build(world: WorldSnapshot, runs: [RunState]) -> WorkModel {
        var infos: [String: SessionInfo] = [:]
        for session in world.sessions { infos[session.sessionId] = session }
        var ended: [String: SessionInfo] = [:]
        for session in world.endedSessions where infos[session.sessionId] == nil { ended[session.sessionId] = session }

        var ids = Set(infos.keys).union(ended.keys)
        ids.formUnion(runs.map(\.sessionId))
        ids.formUnion(world.agents.map(\.sessionId))

        let runsBySession = Dictionary(grouping: runs, by: \.sessionId)
        let agentsBySession = Dictionary(grouping: world.agents, by: \.sessionId)

        var sessions: [WorkSession] = []
        for id in ids {
            sessions.append(session(
                id: id,
                info: infos[id] ?? ended[id],
                isLive: infos[id] != nil,
                died: ended[id] != nil,
                runs: runsBySession[id] ?? [],
                agents: agentsBySession[id] ?? [],
                world: world
            ))
        }

        let byProject = Dictionary(grouping: sessions, by: \.projectPath)
        let projects = byProject.map { path, sessions in
            WorkProject(path: path, sessions: sessions.sorted(by: comesFirst))
        }
        return WorkModel(projects: projects.sorted { a, b in
            switch (a.sessions.first, b.sessions.first) {
            case let (x?, y?):
                if x.id == y.id { return (a.path ?? "") < (b.path ?? "") }
                return comesFirst(x, y)
            default:
                return (a.path ?? "") < (b.path ?? "")
            }
        })
    }

    /// Who needs the person comes first, then who works, then the most recent.
    private static func comesFirst(_ a: WorkSession, _ b: WorkSession) -> Bool {
        func rank(_ state: WorkState) -> Int {
            switch state {
            case .waiting: return 0
            case .running, .silent: return 1
            default: return 2
            }
        }
        if rank(a.state) != rank(b.state) { return rank(a.state) < rank(b.state) }
        let first = a.lastActivity ?? a.startedAt ?? .distantPast
        let second = b.lastActivity ?? b.startedAt ?? .distantPast
        return first == second ? a.id < b.id : first > second
    }

    private static func session(id: String, info: SessionInfo?, isLive: Bool, died: Bool, runs: [RunState], agents: [AgentSnapshot], world: WorldSnapshot) -> WorkSession {
        let ownState = sessionState(info: info, isLive: isLive, died: died)
        // Files and dictionaries come in no fixed order, and a list that jumps around at every scan cannot be read.
        var nodes: [WorkNode] = agents.sorted { comesEarlier($0.startedAt, $0.id, $1.startedAt, $1.id) }.map { node($0, sessionId: id, tokens: world.agentTokens[$0.id]) }
        for run in runs.sorted(by: { comesEarlier($0.startedAt, $0.runId, $1.startedAt, $1.runId) }) {
            nodes += workflowNodes(run, sessionId: id, tokens: world.runTokens[run.runId])
        }
        nodes = joiningContinued(nodes)
        let place = world.places[id]
        for index in nodes.indices {
            if let own = world.places[nodes[index].id], own.isSeparateCopy, place?.isSameCopy(as: own) != true { nodes[index].place = own }
        }

        let root = WorkNode(
            id: id,
            kind: .main,
            title: info?.displayName,
            state: ownState,
            step: info?.currentStep,
            contextTokens: info?.contextTokens,
            model: info?.model,
            children: tree(nodes, rootId: id)
        )
        let waitingFor = WaitingReason(info?.waitingFor)
        return WorkSession(
            id: id,
            environment: info?.environment ?? runs.first?.environment ?? agents.compactMap(\.environment).first,
            cwd: info?.cwd ?? runs.first?.cwd ?? agents.compactMap(\.cwd).first,
            title: info?.displayName,
            state: combined(ownState, under: root),
            waitingFor: ownState == .waiting ? waitingFor : nil,
            startedAt: info?.startedAt ?? runs.compactMap(\.startedAt).min() ?? agents.compactMap(\.startedAt).min(),
            lastActivity: ([info?.statusUpdatedAt] + runs.map(\.lastWrite) + agents.map(\.lastWrite)).compactMap { $0 }.max(),
            place: place,
            root: root
        )
    }

    /// An agent that goes on after its workflow has ended writes a second file under the same id, and the scan finds it as an ordinary agent.
    /// It is still one agent: it keeps its place and its name in the workflow, so the run's counts stay right, and the newer file says how it is doing.
    private static func joiningContinued(_ nodes: [WorkNode]) -> [WorkNode] {
        let inWorkflow = Set(nodes.filter { $0.kind == .workflowAgent }.map(\.id))
        let continued = Dictionary(nodes.filter { ($0.kind == .subagent || $0.kind == .fork) && inWorkflow.contains($0.id) }.map { ($0.id, $0) }) { first, _ in first }
        guard !continued.isEmpty else { return nodes }
        return nodes.compactMap { node in
            guard let newer = continued[node.id] else { return node }
            guard node.kind == .workflowAgent else { return nil }
            var joined = node
            joined.state = newer.state
            joined.step = newer.step
            joined.contextTokens = newer.contextTokens ?? node.contextTokens
            joined.tokens = newer.tokens ?? node.tokens
            joined.model = newer.model ?? node.model
            joined.failure = newer.failure
            joined.lastActivity = newer.lastActivity ?? node.lastActivity
            return joined
        }
    }

    private static func comesEarlier(_ a: Date?, _ first: String, _ b: Date?, _ second: String) -> Bool {
        let x = a ?? .distantPast
        let y = b ?? .distantPast
        return x == y ? first < second : x < y
    }

    private static func sessionState(info: SessionInfo?, isLive: Bool, died: Bool) -> WorkState {
        // Its process vanished and left the file behind, so it never got to say goodbye.
        if died { return .interrupted }
        guard let info, isLive else { return .finished }
        switch info.status {
        case "waiting":
            return WaitingReason(info.waitingFor) == .dialog ? .running : .waiting
        case "idle":
            return .finished
        default:
            return .running
        }
    }

    /// A session whose main agent has ended a turn is still at work while something under it is.
    private static func combined(_ own: WorkState, under root: WorkNode) -> WorkState {
        if own == .waiting || own == .interrupted { return own }
        let below = root.children.flatMap(\.flattened).map(\.state)
        if below.contains(.waiting) { return .waiting }
        if own == .running || below.contains(.running) { return .running }
        if below.contains(.silent) { return .silent }
        return own
    }

    private static func node(_ agent: AgentSnapshot, sessionId: String, tokens: TokenUsage?) -> WorkNode {
        WorkNode(
            id: agent.id,
            kind: agent.isFork ? .fork : .subagent,
            parentId: agent.parentAgentId ?? sessionId,
            title: agent.description,
            agentType: agent.agentType,
            state: state(agent.state),
            step: agent.currentStep,
            contextTokens: agent.contextTokens,
            tokens: tokens,
            model: agent.model,
            failure: agent.failure,
            lastActivity: agent.lastWrite
        )
    }

    private static func workflowNodes(_ run: RunState, sessionId: String, tokens: TokenUsage?) -> [WorkNode] {
        var nodes = [WorkNode(
            id: run.runId,
            kind: .workflow,
            parentId: sessionId,
            title: run.name,
            state: state(run.status),
            tokens: tokens,
            attempts: run.attempt,
            workflow: WorkflowDetails(run),
            lastActivity: run.lastWrite
        )]
        for agent in run.agents {
            nodes.append(WorkNode(
                id: agent.agentId ?? "\(run.runId)/\(agent.key)",
                kind: .workflowAgent,
                parentId: agent.parentAgentId ?? run.runId,
                title: agent.label,
                agentType: agent.agentType,
                state: state(agent.state),
                step: agent.currentStep,
                contextTokens: agent.contextTokens,
                model: agent.model,
                failure: agent.failure,
                attempts: agent.attempts,
                phase: agent.phase,
                lastActivity: run.lastWrite
            ))
        }
        return nodes
    }

    static func state(_ agent: AgentState) -> WorkState {
        switch agent {
        case .running: return .running
        case .done: return .finished
        case .failed: return .failed
        case .cancelled: return .stopped
        }
    }

    static func state(_ status: RunStatus) -> WorkState {
        switch status {
        case .running: return .running
        case .silent: return .silent
        case .completed, .unknown: return .finished
        case .completedWithErrors, .allAgentsFailed, .failed: return .failed
        case .stopped: return .stopped
        case .interrupted: return .interrupted
        }
    }

    /// Hangs nodes on their parents. A node whose parent is unknown, or caught in a loop, goes under the root, so nothing is lost.
    public static func tree(_ nodes: [WorkNode], rootId: String) -> [WorkNode] {
        var known: [String: WorkNode] = [:]
        var order: [String] = []
        for node in nodes where known[node.id] == nil {
            known[node.id] = node
            order.append(node.id)
        }

        var resolvedParent: [String: String] = [:]
        for id in order {
            var seen: Set<String> = [id]
            var parent = known[id]?.parentId
            while let current = parent, current != rootId {
                guard known[current] != nil, !seen.contains(current) else {
                    parent = rootId
                    break
                }
                seen.insert(current)
                parent = known[current]?.parentId
            }
            let declared = known[id]?.parentId ?? rootId
            resolvedParent[id] = parent == rootId && (known[declared] == nil || !reachesRoot(declared, known: known, rootId: rootId)) ? rootId : declared
        }

        var children: [String: [String]] = [:]
        for id in order { children[resolvedParent[id] ?? rootId, default: []].append(id) }

        func build(_ id: String) -> WorkNode {
            var node = known[id] ?? WorkNode(id: id, kind: .subagent)
            node.parentId = resolvedParent[id]
            node.children = (children[id] ?? []).map(build)
            return node
        }
        return (children[rootId] ?? []).map(build)
    }

    private static func reachesRoot(_ id: String, known: [String: WorkNode], rootId: String) -> Bool {
        var seen: Set<String> = []
        var current: String? = id
        while let value = current {
            if value == rootId { return true }
            guard let node = known[value], !seen.contains(value) else { return false }
            seen.insert(value)
            current = node.parentId
        }
        return false
    }
}
