import Foundation

/// Decides what leaves `boris-hook`. Prompts and assistant messages never pass this point.
public enum HookPayload {
    static let allowedFields = ["hook_event_name", "session_id", "cwd", "agent_id", "agent_type", "tool_name", "notification_type", "source", "reason", "error_type"]
    /// Longest command text shown in a permission request.
    static let commandLimit = 64 * 1024

    public static func reduce(_ input: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for field in allowedFields {
            if let value = input[field] as? String { out[field] = value }
        }
        if out["error_type"] == nil, let error = input["error"] as? String { out["error_type"] = error }

        let event = input["hook_event_name"] as? String
        if event == "PostToolUse", input["tool_name"] as? String == "Workflow", let response = input["tool_response"] as? [String: Any] {
            if let run = response["runId"] as? String { out["run_id"] = run }
        }
        if event == "PermissionRequest", let toolInput = input["tool_input"] as? [String: Any] {
            out["command_text"] = commandText(toolInput)
        }
        return out
    }

    /// The whole request as a person needs to read it, because a permission is given on this text.
    static func commandText(_ toolInput: [String: Any]) -> String {
        let text: String
        if let command = toolInput["command"] as? String {
            text = command
        } else if JSONSerialization.isValidJSONObject(toolInput),
                  let data = try? JSONSerialization.data(withJSONObject: toolInput, options: [.prettyPrinted, .sortedKeys]) {
            text = String(decoding: data, as: UTF8.self)
        } else {
            text = ""
        }
        return text.utf8.count <= commandLimit ? text : String(decoding: text.utf8.prefix(commandLimit), as: UTF8.self) + "\n…"
    }
}

public enum HookSignal: Sendable, Equatable {
    case toolStarted(session: String, agent: String?, tool: String)
    case toolFinished(session: String, agent: String?, tool: String)
    case agentStarted(session: String, agent: String)
    case agentStopped(session: String, agent: String)
    case workflowLaunched(session: String, runId: String)
    case turnStopped(session: String)
    case stopFailure(session: String, error: String)
    case sessionStarted(session: String, source: String, cwd: String?)
    case sessionEnded(session: String, reason: String, cwd: String?)
    case needsUser(session: String)
    case permissionAsked(session: String, tool: String)

    /// Unknown events return nil: a new hook type must not disturb anything.
    public init?(payload p: [String: Any]) {
        guard let event = p["hook_event_name"] as? String, let session = p["session_id"] as? String else { return nil }
        // The files know an agent by its bare id.
        let agent = (p["agent_id"] as? String).map { $0.hasPrefix("agent-") ? String($0.dropFirst(6)) : $0 }
        let tool = p["tool_name"] as? String
        let cwd = p["cwd"] as? String
        switch event {
        case "PreToolUse":
            guard let tool else { return nil }
            self = .toolStarted(session: session, agent: agent, tool: tool)
        case "PostToolUse", "PostToolUseFailure":
            guard let tool else { return nil }
            if tool == "Workflow", let run = p["run_id"] as? String {
                self = .workflowLaunched(session: session, runId: run)
            } else {
                self = .toolFinished(session: session, agent: agent, tool: tool)
            }
        case "SubagentStart":
            guard let agent else { return nil }
            self = .agentStarted(session: session, agent: agent)
        case "SubagentStop":
            guard let agent else { return nil }
            self = .agentStopped(session: session, agent: agent)
        case "Stop":
            self = .turnStopped(session: session)
        case "StopFailure":
            self = .stopFailure(session: session, error: p["error_type"] as? String ?? "unknown")
        case "SessionStart":
            self = .sessionStarted(session: session, source: p["source"] as? String ?? "", cwd: cwd)
        case "SessionEnd":
            self = .sessionEnded(session: session, reason: p["reason"] as? String ?? "other", cwd: cwd)
        case "Notification":
            guard let kind = p["notification_type"] as? String, ["permission_prompt", "agent_needs_input", "elicitation_dialog"].contains(kind) else { return nil }
            self = .needsUser(session: session)
        case "PermissionRequest":
            self = .permissionAsked(session: session, tool: tool ?? "?")
        default:
            return nil
        }
    }
}

/// What hooks add on top of the files. Files stay the source of truth: nothing here sets a run status.
public struct HookState: Sendable, Equatable {
    public struct Failure: Sendable, Equatable {
        public var session: String
        public var error: String
    }

    private struct Ending: Sendable, Equatable {
        var session: String
        var cwd: String?
        var at: Date
    }

    /// When any hook last spoke, for noticing that they have gone quiet.
    public private(set) var lastEventAt: Date?
    public private(set) var currentTool: [String: String] = [:]
    /// What the main agent of each session is running now.
    public private(set) var sessionTool: [String: String] = [:]
    public private(set) var waiting: [String: Date] = [:]
    public private(set) var waitingTool: [String: String] = [:]
    public private(set) var sessionEnd: [String: String] = [:]
    public private(set) var successor: [String: String] = [:]
    private var failures: [Failure] = []
    private var ending: Ending?

    public static let waitingExpiry: TimeInterval = 10 * 60

    public init() {}

    public mutating func apply(_ signal: HookSignal, now: Date) {
        lastEventAt = now
        switch signal {
        case .agentStarted:
            break
        case .toolStarted(let session, let agent, let tool):
            if let agent { currentTool[agent] = tool } else { sessionTool[session] = tool }
        case .toolFinished(let session, let agent, _):
            if let agent { currentTool[agent] = nil } else { sessionTool[session] = nil }
            clearWaiting(session)
        case .agentStopped(_, let agent):
            currentTool[agent] = nil
        case .workflowLaunched(let session, _):
            clearWaiting(session)
        case .turnStopped(let session):
            sessionTool[session] = nil
            clearWaiting(session)
        case .stopFailure(let session, let error):
            failures.append(Failure(session: session, error: error))
        case .sessionEnded(let session, let reason, let cwd):
            sessionEnd[session] = reason
            sessionTool[session] = nil
            clearWaiting(session)
            if reason == "clear" || reason == "resume" {
                ending = Ending(session: session, cwd: cwd, at: now)
            }
        case .sessionStarted(let session, let source, let cwd):
            if source == "clear" || source == "resume", let ending, ending.cwd == cwd, now.timeIntervalSince(ending.at) <= 10, ending.session != session {
                successor[ending.session] = session
                self.ending = nil
            }
        case .needsUser(let session):
            if waiting[session] == nil { waiting[session] = now }
        case .permissionAsked(let session, let tool):
            if waiting[session] == nil { waiting[session] = now }
            waitingTool[session] = tool
        }
    }

    private mutating func clearWaiting(_ session: String) {
        waiting[session] = nil
        waitingTool[session] = nil
    }

    public mutating func expire(now: Date) {
        for (session, since) in waiting where now.timeIntervalSince(since) > Self.waitingExpiry {
            clearWaiting(session)
        }
    }

    public mutating func drainFailures() -> [Failure] {
        defer { failures = [] }
        return failures
    }

    /// A session hooks know to be waiting counts as waiting, even when its file does not say so.
    public func overlay(sessions: [SessionInfo]) -> [SessionInfo] {
        sessions.map { session in
            var session = session
            if let tool = sessionTool[session.sessionId], session.currentStep?.tool != tool {
                session.currentStep = StepBrief(kind: StepKind(tool: tool), tool: tool)
            }
            guard waiting[session.sessionId] != nil else { return session }
            if session.status == "waiting" {
                // The hook may know the tool that the file leaves out.
                if WaitingReason(session.waitingFor) == .permission(tool: nil), let tool = waitingTool[session.sessionId] {
                    session.waitingFor = "approve \(tool)"
                }
                return session
            }
            session.status = "waiting"
            session.waitingFor = waitingTool[session.sessionId].map { "approve \($0)" } ?? "input needed"
            return session
        }
    }

    /// An ordinary agent's tool, known at once. Nothing else about it changes.
    public func overlay(agents: [AgentSnapshot]) -> [AgentSnapshot] {
        guard !currentTool.isEmpty else { return agents }
        return agents.map { agent in
            guard agent.state == .running, let tool = currentTool[agent.id], agent.currentStep?.tool != tool else { return agent }
            var agent = agent
            agent.currentStep = StepBrief(kind: StepKind(tool: tool), tool: tool)
            return agent
        }
    }

    public func overlay(runs: [RunState]) -> [RunState] {
        guard !currentTool.isEmpty else { return runs }
        return runs.map { run in
            guard run.status.isActive else { return run }
            var run = run
            run.agents = run.agents.map(withTool)
            run.phases = run.phases.map { phase in
                var phase = phase
                phase.agents = phase.agents.map(withTool)
                return phase
            }
            return run
        }
    }

    private func withTool(_ agent: AgentRecord) -> AgentRecord {
        guard agent.state == .running, let id = agent.agentId, let tool = currentTool[id] else { return agent }
        var agent = agent
        agent.currentTool = tool
        if agent.currentStep?.tool != tool { agent.currentStep = StepBrief(kind: StepKind(tool: tool), tool: tool) }
        return agent
    }
}
