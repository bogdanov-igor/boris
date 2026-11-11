import Foundation

/// The words for what is going on, in both display modes. Text of commands and prompts never gets here.
public enum WorkPhrases {
    public static func state(_ state: WorkState, mode: DisplayMode) -> String {
        guard mode == .technical else { return PhraseBook.state(state) }
        switch state {
        case .running: return L("Running")
        case .silent: return L("Silent")
        case .waiting: return L("Waiting")
        case .finished: return L("Finished")
        case .failed: return L("Failed")
        case .stopped: return L("Stopped")
        case .interrupted: return L("Interrupted")
        case .unreachable: return L("No connection")
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
        guard mode == .technical else { return PhraseBook.waiting(reason) }
        switch reason {
        case .permission(let tool?): return L("%@ is waiting for permission", tool)
        case .permission(nil): return L("Waiting for permission")
        case .input: return L("Waiting for input")
        case .dialog: return L("A dialog is open in Claude")
        case .other, nil: return state(.waiting, mode: mode)
        }
    }

    /// What the agent is doing, or nil when nothing is known.
    public static func step(_ step: StepBrief?, mode: DisplayMode) -> String? {
        guard let step else { return nil }
        guard mode == .simple else { return [step.tool, step.fileName].compactMap { $0 }.joined(separator: " ") }
        return PhraseBook.doing(step)
    }

    public static func agents(_ count: Int) -> String {
        count == 1 ? L("%lld agent", count) : L("%lld agents", count)
    }

    /// The line under a session's name.
    public static func line(_ session: WorkSession, mode: DisplayMode) -> String {
        let parts = lineParts(session, mode: mode)
        return parts.agents.map { "\(parts.doing) · \($0)" } ?? parts.doing
    }

    /// The same line in two parts, so that a narrow row can cut what is being done and keep the number of agents whole.
    public static func lineParts(_ session: WorkSession, mode: DisplayMode) -> (doing: String, agents: String?) {
        // All that is known about a chat is said in its own words, and it has no steps or agents.
        if session.environment == .chat { return (session.state == .running ? L("Writing an answer") : L("The answer is ready"), nil) }
        switch session.state {
        case .waiting:
            return (waiting(session.waitingFor, mode: mode), nil)
        case .running:
            let doing = step(session.root.step, mode: mode) ?? state(.running, mode: mode)
            // The count is of everyone at work, the same number the session's own page gives and the total adds up from.
            let working = session.workingAgents
            guard working > 1 else { return (doing, nil) }
            return (doing, mode == .simple ? lowercasedStart(agentsWorking(working)) : agents(working))
        case .silent, .finished, .failed, .stopped, .interrupted:
            return (state(session.state, mode: mode), nil)
        case .unreachable:
            return (L("No connection to the remote machine"), nil)
        }
    }

    /// `id · model · bypassPermissions mode · branch main · ~/dev/app`: what only a person with a reason looks for. What is not known is left out.
    public static func sessionFacts(_ session: WorkSession, permissionMode: String?) -> String {
        var parts = [session.id]
        if let model = session.root.model { parts.append(model) }
        if let permissionMode { parts.append(L("%@ mode", permissionMode)) }
        if let branch = session.place?.branch { parts.append(L("branch %@", branch)) }
        if let cwd = session.cwd { parts.append((cwd as NSString).abbreviatingWithTildeInPath) }
        return parts.joined(separator: " · ")
    }

    /// What a session's context holds, for its line in the technical mode.
    public static func contextLine(_ session: WorkSession) -> String? {
        session.root.contextTokens.map { L("context %@", WorkFormat.tokens($0)) }
    }

    private static func lowercasedStart(_ text: String) -> String {
        text.prefix(1).lowercased() + text.dropFirst()
    }
}

extension WorkSession {
    /// The name Claude or the person gave it, otherwise its project.
    public var displayName: String {
        if let title, !title.isEmpty { return title }
        if let workingFolder, !workingFolder.isEmpty { return URL(fileURLWithPath: workingFolder).lastPathComponent }
        switch environment {
        case .cowork: return L("Cowork task")
        case .chat: return L("Answer in chat")
        default: return String(id.prefix(8))
        }
    }

    /// The simple mode shows no ids, so a session with nothing else to go by is just a session.
    public func name(in mode: DisplayMode) -> String {
        if mode == .simple, !hasName { return L("Session") }
        return displayName
    }

    var hasName: Bool {
        title?.isEmpty == false || cwd?.isEmpty == false
    }

    /// A folder is set in a monospaced font, a person's words are not.
    public var nameIsFolder: Bool {
        title?.isEmpty != false && workingFolder?.isEmpty == false
    }

    /// The folder it works in, if that means anything to a person. Cowork's is a made-up name inside a virtual machine.
    public var workingFolder: String? {
        environment == .cowork ? nil : cwd
    }
}
