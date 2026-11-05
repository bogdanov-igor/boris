import Foundation

/// The words for workflows, failures and the outcome of a session. Technical names go only to the technical mode.
extension WorkPhrases {
    public static func workflow(_ status: RunStatus, mode: DisplayMode) -> String {
        let simple = mode == .simple
        switch status {
        case .running: return simple ? L("Working") : L("Running")
        case .silent: return simple ? L("No news for a while") : L("Silent")
        case .completed: return simple ? L("Done") : L("Finished")
        case .completedWithErrors: return simple ? L("Partly done") : L("Finished with errors")
        case .allAgentsFailed: return simple ? L("Did not work") : L("All agents failed")
        case .failed: return simple ? L("Broke") : L("Failed")
        case .stopped: return simple ? L("Stopped") : L("Halted")
        case .interrupted: return simple ? L("Cut off") : L("Interrupted")
        case .unknown(let raw): return simple ? L("Ended") : raw
        }
    }

    /// `Silktrace final verify` for `silktrace-final-verify`. An id is not a name.
    public static func workflowName(_ raw: String?, mode: DisplayMode) -> String {
        guard let raw, !raw.isEmpty, !raw.hasPrefix("wf_") else {
            return mode == .simple ? L("A big task") : (raw ?? L("Workflow"))
        }
        guard mode == .simple, !raw.contains(" ") else { return raw }
        let words = raw.split(whereSeparator: { $0 == "-" || $0 == "_" }).joined(separator: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// Why it fell, in lowercase for the middle of a line.
    public static func cause(_ cause: FailureClass?, resets: String? = nil, mode: DisplayMode) -> String {
        let simple = mode == .simple
        switch cause {
        case .limit:
            if let resets { return simple ? L("ran out of limit, resets at %@", resets) : L("limit, resets at %@", resets) }
            return simple ? L("ran out of limit") : L("limit")
        case .network: return simple ? L("no connection to Claude") : L("network")
        case .sleep: return simple ? L("the Mac went to sleep") : L("Mac asleep")
        case .stall: return simple ? L("the task got stuck") : L("stalled")
        case .api: return simple ? L("a Claude error") : L("API error")
        case .unknown, nil: return simple ? L("reason unknown") : L("unknown")
        }
    }

    /// A failure in one line: `Did not work: ran out of limit, resets at 18:40`, or `All agents failed · 12 of 12 · limit` in the technical mode.
    public static func failure(_ failure: WorkFailure, mode: DisplayMode) -> String {
        let simple = mode == .simple
        switch failure.source {
        case .session:
            return simple ? "\(L("Cut off")): \(L("Claude Code closed"))" : "\(L("Interrupted")) · \(L("Claude Code closed"))"
        case .agent:
            return simple ? hint(failure.cause, resets: failure.resets) : capitalized(cause(failure.cause, resets: failure.resets, mode: mode))
        case .workflow(let status, let failed, let total):
            let word = workflow(status, mode: mode)
            if status == .interrupted { return simple ? "\(word): \(L("Claude Code closed"))" : "\(word) · \(L("Claude Code closed"))" }
            if status == .failed, failed == 0 { return simple ? "\(word): \(L("an error in the task"))" : "\(word) · \(L("script error"))" }
            let why = cause(failure.cause, resets: failure.resets, mode: mode)
            if status == .allAgentsFailed {
                return simple ? "\(word): \(why)" : "\(word) · \(L("%lld of %lld", failed, total)) · \(why)"
            }
            let count = L("failed %lld of %lld", failed, total)
            return simple ? "\(word): \(count), \(why)" : "\(word) · \(count) · \(why)"
        }
    }

    /// What it means for the person, for the simple mode.
    public static func hint(_ cause: FailureClass?, resets: String?) -> String {
        switch cause {
        case .limit: return resets.map { L("The limit ran out, it resets at %@", $0) } ?? L("The limit ran out")
        case .network: return L("No connection to Claude, try again when it is back")
        case .sleep: return L("The Mac went to sleep while this was going on")
        case .stall: return L("The task got stuck")
        case .api: return L("Claude is overloaded right now, try again later")
        case .unknown, nil: return L("Something went wrong")
        }
    }

    /// Who it is, for a list of failures.
    public static func failureName(_ failure: WorkFailure, mode: DisplayMode) -> String {
        switch failure.source {
        case .session:
            return failure.name ?? L("Session")
        case .workflow:
            return workflowName(failure.name, mode: mode)
        case .agent(let kind):
            guard let name = failure.name, !name.isEmpty else { return mode == .simple ? L("A helper") : agentKind(kind) }
            return mode == .simple ? L("Helper «%@»", name) : "\(agentKind(kind)) «\(name)»"
        }
    }

    public static func agentKind(_ kind: WorkNodeKind) -> String {
        switch kind {
        case .main: return L("Main agent")
        case .subagent: return L("Subagent")
        case .fork: return L("Fork")
        case .workflow: return L("Workflow")
        case .workflowAgent: return L("Workflow agent")
        }
    }

    /// The name of a line in the tree. `search:form` under the phase «Search» says «form»: the heading above has said the rest.
    public static func agentName(_ node: WorkNode) -> String {
        if node.kind == .main { return L("Main agent") }
        guard let title = node.title, !title.isEmpty else { return node.agentType ?? agentKind(node.kind) }
        guard let phase = node.phase, title.lowercased().hasPrefix(phase.lowercased() + ":") else { return title }
        return String(title.dropFirst(phase.count + 1))
    }

    /// The second line of a row in the tree.
    public static func agentActivity(_ node: WorkNode, mode: DisplayMode) -> String {
        switch node.state {
        case .running: return step(node.step, mode: mode) ?? L("Thinking…")
        case .failed: return capitalized(cause(node.failure?.failureClass, resets: node.failure?.resets, mode: mode))
        case .waiting, .silent, .finished, .stopped, .interrupted: return state(node.state, mode: mode)
        }
    }

    /// How a session ended, or what it is doing. A session is feminine in Russian, a run is not, so the words differ.
    public static func outcome(_ state: WorkState, mode: DisplayMode) -> String {
        guard mode == .technical else { return self.state(state, mode: mode) }
        switch state {
        case .finished: return L("Session ended")
        case .failed: return L("Session broke")
        case .stopped: return L("Stopped by you")
        case .interrupted: return L("Session interrupted")
        case .running, .silent, .waiting: return self.state(state, mode: mode)
        }
    }

    /// `3 agents at work`. Counts everything that works, the main agent too.
    public static func agentsAtWork(_ count: Int) -> String {
        count == 1 ? L("%lld agent at work", count) : L("%lld agents at work", count)
    }

    /// The headline of a session in the simple mode: the current occupation, never «nothing» while it works.
    public static func occupation(_ session: WorkSession, mode: DisplayMode) -> String {
        switch session.state {
        case .waiting: return waiting(session.waitingFor, mode: mode)
        case .running: return step(session.root.step, mode: mode) ?? state(.running, mode: mode)
        case .silent, .finished, .failed, .stopped, .interrupted: return outcome(session.state, mode: mode)
        }
    }

    private static func capitalized(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }
}
