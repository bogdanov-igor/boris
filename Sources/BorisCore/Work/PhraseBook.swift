import Foundation

/// The plain words of the simple mode: actions, statuses, reasons and failures, in one place.
/// They are made here from the kind of a thing, without any network. Whatever has no phrase of its own gets the most general one, never a name from inside Claude Code.
public enum PhraseBook {
    // MARK: - Actions

    /// What an agent is doing right now, for any step at all.
    public static func doing(_ step: StepBrief) -> String {
        switch step.kind {
        case .read: return L("Reading project files")
        case .edit: return step.fileName.map { L("Editing %@", $0) } ?? L("Editing files")
        case .write: return step.fileName.map { L("Writing %@", $0) } ?? L("Writing files")
        case .shell: return L("Running a command")
        case .search: return L("Searching the files")
        case .web: return L("Searching the internet")
        case .helper: return step.skill != nil || step.tool == "Skill" ? L("Using a skill") : L("Called in a helper")
        case .answer: return L("Preparing an answer")
        case .other: return L("Working")
        }
    }

    public static func doing(tool: String) -> String {
        doing(StepBrief(kind: StepKind(tool: tool), tool: tool))
    }

    /// A running step that can say more than its kind.
    public static func readingFile(_ name: String) -> String {
        L("Reading %@", name)
    }

    public static func helperWorking(on task: String) -> String {
        L("A helper is working on: %@", task)
    }

    /// What steps of one kind in a row have done, told as one thing.
    /// - Parameters:
    ///   - steps: how many there were.
    ///   - files: how many different files they named.
    ///   - note: the agent's own words for a single command or helper.
    public static func done(_ kind: StepKind, steps: Int, files: Int, isSkill: Bool = false, note: String? = nil) -> String {
        switch kind {
        case .read:
            return files == 1 ? L("Read %lld file", files) : L("Read %lld files", files)
        case .edit, .write:
            return files == 1 ? L("Changed %lld file", files) : L("Changed %lld files", files)
        case .shell:
            if steps == 1 { return note ?? L("Ran %lld command", steps) }
            return L("Ran %lld commands", steps)
        case .search:
            return steps == 1 ? L("Searched the files") : L("Searched the files %lld times", steps)
        case .web:
            return steps == 1 ? L("Looked on the internet") : L("Looked on the internet %lld times", steps)
        case .helper:
            if isSkill { return L("Used a skill") }
            return note.map { L("Asked a helper: %@", $0) } ?? L("Called in a helper")
        case .answer, .other:
            return L("Working")
        }
    }

    /// A step that failed always stands alone, so this is about one.
    public static func failed(_ kind: StepKind) -> String {
        switch kind {
        case .read: return L("Could not read a file")
        case .edit, .write: return L("Could not change a file")
        case .shell: return L("A command failed")
        case .search: return L("The search in the files failed")
        case .web: return L("Could not get it from the internet")
        case .helper: return L("A helper failed")
        case .answer, .other: return L("A step failed")
        }
    }

    /// The agent ended before these got a result, so whether they worked is not known.
    public static func unfinished(steps: Int) -> String {
        steps == 1 ? L("This step did not finish") : L("%lld steps did not finish", steps)
    }

    /// The title of a request for something other than a command, an edit, a question or a plan.
    public static func asks(_ action: WorkAction) -> String {
        switch action {
        case .webFetch, .webSearch: return L("Wants to go online")
        case .read: return L("Wants to read files")
        case .mcp: return L("Wants to use an outside tool")
        case .startAgent: return L("Wants to start an agent")
        case .skill: return L("Wants to use a skill")
        case .write: return L("Wants to edit a file")
        case .command: return L("Wants to run a command")
        case .other: return L("Asks for permission")
        }
    }

    // MARK: - Statuses

    public static func state(_ state: WorkState) -> String {
        switch state {
        case .running: return L("Working")
        case .silent: return L("No news for a while")
        case .waiting: return L("Waiting for you")
        case .finished: return L("Done")
        case .failed: return L("Broke")
        case .stopped: return L("Stopped")
        case .interrupted: return L("Cut off")
        case .unreachable: return L("No connection")
        }
    }

    /// A workflow's status. One Boris does not know has still ended.
    public static func status(_ status: RunStatus) -> String {
        switch status {
        case .running: return L("Working")
        case .silent: return L("No news for a while")
        case .completed: return L("Done")
        case .completedWithErrors: return L("Partly done")
        case .allAgentsFailed: return L("Did not work")
        case .failed: return L("Broke")
        case .stopped: return L("Stopped")
        case .interrupted: return L("Cut off")
        case .unknown: return L("Ended")
        }
    }

    /// What a session waits for. The file does not always name the tool.
    public static func waiting(_ reason: WaitingReason?) -> String {
        switch reason {
        case .permission(let tool):
            switch tool.map(StepKind.init(tool:)) {
            case .shell: return L("Waiting for you: wants to run a command")
            case .edit, .write: return L("Waiting for you: wants to change a file")
            default: return L("Waiting for you: asks for permission")
            }
        case .input: return L("Waiting for your answer")
        case .dialog: return L("A dialog is open in Claude")
        case .other, nil: return state(.waiting)
        }
    }

    // MARK: - Reasons

    /// Why it fell, in lowercase for the middle of a line.
    public static func reason(_ cause: FailureClass?, resets: String? = nil) -> String {
        switch cause {
        case .limit: return resets.map { L("ran out of limit, resets at %@", $0) } ?? L("ran out of limit")
        case .network: return L("no connection to Claude")
        case .sleep: return L("the Mac went to sleep")
        case .stall: return L("the task got stuck")
        case .api: return L("a Claude error")
        case .unknown, nil: return L("reason unknown")
        }
    }

    /// The same as a heading of its own.
    public static func reasonTitle(_ reason: LossReason) -> String {
        switch reason {
        case .limit: return L("Out of limit")
        case .network: return L("No connection to Claude")
        case .stall: return L("The task hung")
        case .api: return L("Claude error")
        case .sleep: return L("The Mac went to sleep")
        case .script: return L("Error in the task")
        case .closed: return L("Claude Code closed")
        case .unknown: return L("Reason unknown")
        }
    }

    // MARK: - Failures

    /// The cause and what to do about it, for a failure known by its class.
    /// - Parameter resets: the time as Claude Code wrote it.
    public static func advice(cause: FailureClass?, problem: ApiProblem? = nil, resets: String? = nil) -> String {
        switch cause {
        case .limit: return resets.map { L("The limit ran out, it resets at %@", $0) } ?? L("The limit ran out")
        case .network: return advice(reason: .network)
        case .sleep: return advice(reason: .sleep)
        case .stall: return advice(reason: .stall)
        case .api: return advice(reason: .api, problem: problem)
        case .unknown, nil: return advice(reason: .unknown)
        }
    }

    /// The cause and what to do about it, for a failure known by its reason.
    /// - Parameter resets: already in words, like `resets at 18:40`.
    public static func advice(reason: LossReason, problem: ApiProblem? = nil, resets: String? = nil) -> String {
        switch reason {
        case .limit: return resets.map { L("Out of limit, %@", $0) } ?? L("Out of limit, wait until it resets")
        case .network: return L("No connection to Claude, check the internet and try again")
        case .stall: return L("The task hung, try starting it again")
        case .sleep: return L("The Mac went to sleep and the work stopped, try again")
        case .script: return L("Error in the task, start it again or change it")
        case .closed: return L("Claude Code closed, open the session to continue")
        case .unknown: return L("Something went wrong")
        case .api:
            // An error is called an overload only when it says so: telling someone to wait would be no help with a bad request.
            switch problem ?? .other {
            case .overloaded: return L("Claude is overloaded right now, try again later")
            case .billing: return L("Claude asks to sort out payment, check your account")
            case .access: return L("Claude asks to sign in again")
            case .request, .other: return L("Claude returned an error, try again")
            }
        }
    }

    /// A failure in one line, like `Did not work: ran out of limit, resets at 18:40`.
    public static func failure(_ failure: WorkFailure) -> String {
        switch failure.source {
        case .session:
            return "\(state(.interrupted)): \(L("Claude Code closed"))"
        case .sessionError, .agent:
            return advice(cause: failure.cause, problem: failure.problem, resets: failure.resets)
        case .workflow(let status, let failed, let total):
            let word = self.status(status)
            if status == .interrupted { return "\(word): \(L("Claude Code closed"))" }
            if status == .failed, failed == 0 || failure.cause == nil { return "\(word): \(L("an error in the task"))" }
            let why = reason(failure.cause, resets: failure.resets)
            if status == .allAgentsFailed { return "\(word): \(why)" }
            return "\(word): \(L("failed %lld of %lld", failed, total)), \(why)"
        }
    }

    // MARK: - Names

    /// `Silktrace final verify` for `silktrace-final-verify`. Words with spaces are a phrase already, and an id is not a name.
    public static func taskName(_ raw: String?) -> String {
        guard let raw, !raw.hasPrefix("wf_") else { return L("A big task") }
        guard !raw.contains(" ") else { return raw }
        let words = raw.split(whereSeparator: { $0 == "-" || $0 == "_" }).joined(separator: " ")
        guard !words.isEmpty else { return L("A big task") }
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// What a type like `general-purpose` says to a person is nothing, so only a name given by someone is shown.
    public static func helperName(_ title: String?) -> String {
        guard let title, !title.isEmpty else { return L("A helper") }
        return L("Helper «%@»", title)
    }
}
