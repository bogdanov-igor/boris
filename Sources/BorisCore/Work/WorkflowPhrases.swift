import Foundation

/// The words for workflows, failures and the outcome of a session. Technical names go only to the technical mode.
extension WorkPhrases {
    public static func workflow(_ status: RunStatus, mode: DisplayMode) -> String {
        guard mode == .technical else { return PhraseBook.status(status) }
        switch status {
        case .running: return L("Running")
        case .silent: return L("Silent")
        case .completed: return L("Finished")
        case .completedWithErrors: return L("Finished with errors")
        case .allAgentsFailed: return L("All agents failed")
        case .failed: return L("Failed")
        case .stopped: return L("Halted")
        case .interrupted: return L("Interrupted")
        case .unknown(let raw): return raw
        }
    }

    /// The simple mode has a plain name for it, the technical one shows it as it is.
    public static func workflowName(_ raw: String?, mode: DisplayMode) -> String {
        guard mode == .technical else { return PhraseBook.taskName(raw) }
        guard let raw, !raw.isEmpty else { return L("Workflow") }
        return raw
    }

    /// Why it fell, in lowercase for the middle of a line.
    public static func cause(_ cause: FailureClass?, resets: String? = nil, mode: DisplayMode) -> String {
        guard mode == .technical else { return PhraseBook.reason(cause, resets: resets) }
        switch cause {
        case .limit: return resets.map { L("limit, resets at %@", $0) } ?? L("limit")
        case .network: return L("network")
        case .sleep: return L("Mac asleep")
        case .stall: return L("stalled")
        case .api: return L("API error")
        case .unknown, nil: return L("unknown")
        }
    }

    /// A failure in one line: `Did not work: ran out of limit, resets at 18:40`, or `All agents failed · 12 of 12 · limit` in the technical mode.
    public static func failure(_ failure: WorkFailure, mode: DisplayMode) -> String {
        guard mode == .technical else { return PhraseBook.failure(failure) }
        switch failure.source {
        case .session:
            return "\(L("Interrupted")) · \(L("Claude Code closed"))"
        case .sessionError, .agent:
            let why = capitalized(cause(failure.cause, resets: failure.resets, mode: mode))
            // The kind of an API error is what a person with a reason came for.
            return failure.problem.flatMap(LossPhrases.problemWord).map { "\(why) · \($0)" } ?? why
        case .workflow(let status, let failed, let total):
            let word = workflow(status, mode: mode)
            if status == .interrupted { return "\(word) · \(L("Claude Code closed"))" }
            if status == .failed, failed == 0 { return "\(word) · \(L("script error"))" }
            let why = cause(failure.cause, resets: failure.resets, mode: mode)
            if status == .allAgentsFailed { return "\(word) · \(L("%lld of %lld", failed, total)) · \(why)" }
            return "\(word) · \(L("failed %lld of %lld", failed, total)) · \(why)"
        }
    }

    /// What it means for the person, for the simple mode.
    public static func hint(_ cause: FailureClass?, problem: ApiProblem? = nil, resets: String?) -> String {
        PhraseBook.advice(cause: cause, problem: problem, resets: resets)
    }

    /// Who it is, for a list of failures.
    public static func failureName(_ failure: WorkFailure, mode: DisplayMode) -> String {
        switch failure.source {
        case .session, .sessionError:
            return failure.name ?? L("Session")
        case .workflow:
            return workflowName(failure.name, mode: mode)
        case .agent(let kind):
            guard mode == .technical else { return PhraseBook.helperName(failure.name) }
            guard let name = failure.name ?? failure.agentType, !name.isEmpty else { return agentKind(kind) }
            return "\(agentKind(kind)) «\(name)»"
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
        let rest = title.dropFirst(phase.count + 1)
        return rest.isEmpty ? title : String(rest)
    }

    /// The second line of a row in the tree.
    public static func agentActivity(_ node: WorkNode, mode: DisplayMode) -> String {
        switch node.state {
        case .running: return step(node.step, mode: mode) ?? L("Thinking…")
        case .failed: return capitalized(cause(node.failure?.failureClass, resets: node.failure?.resets, mode: mode))
        case .waiting, .silent, .finished, .stopped, .interrupted, .unreachable: return state(node.state, mode: mode)
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
        case .running, .silent, .waiting, .unreachable: return self.state(state, mode: mode)
        }
    }

    /// What a failed step was stopped by, in the tool's own terms. The output itself stays where it is.
    public static func stepError(_ step: ActivityStep) -> String? {
        guard step.state == .failed else { return nil }
        let failure = ToolFailure.classify(String((step.output ?? "").prefix(300)))
        return LossPhrases.toolFailureWords(failure.kind, code: failure.code)
    }

    /// `3 agents working`. Counts everything that works, the main agent too.
    public static func agentsWorking(_ count: Int) -> String {
        count == 1 ? L("%lld agent working", count) : L("%lld agents working", count)
    }

    /// The headline of a session in the simple mode: the current occupation, never «nothing» while it works.
    public static func occupation(_ session: WorkSession, mode: DisplayMode) -> String {
        if session.environment == .chat { return line(session, mode: mode) }
        switch session.state {
        case .waiting: return waiting(session.waitingFor, mode: mode)
        case .running: return step(session.root.step, mode: mode) ?? state(.running, mode: mode)
        case .silent, .finished, .failed, .stopped, .interrupted, .unreachable: return outcome(session.state, mode: mode)
        }
    }

    private static func capitalized(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }
}
