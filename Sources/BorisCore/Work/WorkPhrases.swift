import Foundation

/// The words for what is going on, in both display modes. Text of commands and prompts never gets here.
public enum WorkPhrases {
    public static func state(_ state: WorkState, mode: DisplayMode) -> String {
        let simple = mode == .simple
        switch state {
        case .running: return simple ? L("Working") : L("Running")
        case .silent: return simple ? L("No news for a while") : L("Silent")
        case .waiting: return simple ? L("Waiting for you") : L("Waiting")
        case .finished: return simple ? L("Done") : L("Finished")
        case .failed: return simple ? L("Broke") : L("Failed")
        case .stopped: return L("Stopped")
        case .interrupted: return simple ? L("Cut off") : L("Interrupted")
        }
    }

    public static func environment(_ environment: WorkEnvironment?) -> String {
        switch environment {
        case .terminal: return L("Terminal")
        case .vsCode: return "VS Code"
        case .cursor: return "Cursor"
        case .claudeDesktop: return "Claude Desktop"
        case .cowork: return "Cowork"
        case .program: return L("Agent SDK program")
        case .chat: return L("Claude chat")
        case .insideClaude: return L("Inside Claude")
        case .remote(let host): return host
        case nil: return L("Unknown place")
        }
    }

    public static func waiting(_ reason: WaitingReason?, mode: DisplayMode) -> String {
        let simple = mode == .simple
        switch reason {
        case .permission(let tool?):
            guard simple else { return L("%@ is waiting for permission", tool) }
            switch StepKind(tool: tool) {
            case .shell: return L("Waiting for you: wants to run a command")
            case .edit, .write: return L("Waiting for you: wants to change a file")
            default: return L("Waiting for you: asks for permission")
            }
        case .permission(nil):
            return simple ? L("Waiting for you: asks for permission") : L("Waiting for permission")
        case .input:
            return simple ? L("Waiting for your answer") : L("Waiting for input")
        case .dialog:
            return L("A dialog is open in Claude")
        case .other, nil:
            return state(.waiting, mode: mode)
        }
    }

    /// What the agent is doing, or nil when nothing is known.
    public static func step(_ step: StepBrief?, mode: DisplayMode) -> String? {
        guard let step else { return nil }
        guard mode == .simple else { return [step.tool, step.fileName].compactMap { $0 }.joined(separator: " ") }
        switch step.kind {
        case .read: return L("Reading project files")
        case .edit: return step.fileName.map { L("Editing %@", $0) } ?? L("Editing files")
        case .write: return step.fileName.map { L("Writing %@", $0) } ?? L("Writing files")
        case .shell: return L("Running a command")
        case .search: return L("Searching the files")
        case .web: return L("Searching the internet")
        case .helper: return step.skill == nil ? L("Called in a helper") : L("Using a skill")
        case .answer: return L("Preparing an answer")
        case .other: return L("Working")
        }
    }

    public static func agents(_ count: Int) -> String {
        count == 1 ? L("%lld agent", count) : L("%lld agents", count)
    }

    /// The line under a session's name.
    public static func line(_ session: WorkSession, mode: DisplayMode) -> String {
        switch session.state {
        case .waiting:
            return waiting(session.waitingFor, mode: mode)
        case .running:
            let doing = step(session.root.step, mode: mode) ?? state(.running, mode: mode)
            let helpers = session.workingAgents - (session.root.state.isActive ? 1 : 0)
            return helpers > 0 ? "\(doing) · \(agents(helpers))" : doing
        case .silent, .finished, .failed, .stopped, .interrupted:
            return state(session.state, mode: mode)
        }
    }
}

extension WorkSession {
    /// The name Claude or the person gave it, otherwise its project.
    public var displayName: String {
        if let title, !title.isEmpty { return title }
        if let cwd, !cwd.isEmpty { return URL(fileURLWithPath: cwd).lastPathComponent }
        return String(id.prefix(8))
    }

    /// A folder is set in a monospaced font, a person's words are not.
    public var nameIsFolder: Bool {
        title?.isEmpty != false && cwd?.isEmpty == false
    }
}
