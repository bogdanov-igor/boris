import BorisCore
import BorisData
import Foundation

/// The words of the cards and the history. Simple mode names no tools, and it hides nothing a person is agreeing to.
enum RequestWords {
    static func title(_ request: PendingPermission, denying: Bool, mode: DisplayMode) -> String {
        let brief = RequestBrief(request)
        if mode == .technical {
            switch brief.kind {
            case .questions: return L("Question · %@", request.tool)
            case .plan: return L("Plan · %@", request.tool)
            default: return denying ? L("Deny · %@", request.tool) : L("Permission · %@", request.tool)
            }
        }
        switch brief.kind {
        case .questions: return L("Claude asks")
        case .plan: return L("Proposes a plan")
        case .command: return denying ? L("Deny command") : PhraseBook.asks(.command)
        case .file:
            if denying { return L("Deny file edit") }
            if case .file(_, _, true, _) = request.content { return L("Wants to write a file") }
            return PhraseBook.asks(.write)
        case .other:
            if denying { return L("Deny request") }
            return PhraseBook.asks(WorkAction(tool: request.tool))
        }
    }

    /// The project a request comes from. Simple mode shows no ids, so without anything else to go by it is just a session.
    static func project(_ project: String?, session: WorkSession?, id: String, mode: DisplayMode) -> String {
        if let project { return project }
        if let session { return session.name(in: mode) }
        return mode == .simple ? L("Session") : String(id.prefix(8))
    }

    /// The tool and the permission mode, which only the technical view shows.
    static func technicalMeta(_ request: PendingPermission) -> String {
        switch request.content {
        case .questions, .plan: return request.tool
        default: return request.mode.map { L("%@ · %@ mode", request.tool, $0) } ?? request.tool
        }
    }

    static func agent(isMain: Bool, title: String?, type: String?, mode: DisplayMode) -> String {
        if isMain { return L("Main agent") }
        if let title, !title.isEmpty { return title }
        return mode == .technical ? (type ?? L("Helper agent")) : L("Helper agent")
    }

    /// What a request is about, without its text.
    static func what(_ brief: RequestBrief) -> String {
        switch brief.kind {
        case .command: return L("command")
        case .file: return brief.fileName ?? L("file")
        case .questions: return brief.questions == 1 ? L("%lld question", brief.questions) : L("%lld questions", brief.questions)
        case .plan: return L("plan")
        case .other: return L("request")
        }
    }

    static func outcome(_ outcome: RequestOutcome) -> String {
        switch outcome {
        case .allowed: return L("Allowed")
        case .denied: return L("Denied")
        case .answered: return L("Answered")
        case .planApproved: return L("Plan approved")
        case .planDenied: return L("Plan denied")
        case .expired: return L("Time ran out")
        case .closedInClaude: return L("Closed in Claude")
        }
    }

    static func place(_ place: RequestPlace) -> String {
        switch place {
        case .window: return L("Boris · window")
        case .mini: return L("Boris · mini window")
        case .notch: return L("Boris · notch")
        case .hotKey: return L("Boris · hotkey")
        case .session: return L("In the session")
        }
    }

    /// `1:42`.
    static func clock(_ seconds: TimeInterval) -> String {
        // Bounded before it becomes a whole number: a damaged history file must not bring the app down.
        let whole = Int(min(max(seconds, 0), 86_400).rounded(.up))
        return "\(whole / 60):" + String(format: "%02d", whole % 60)
    }

    /// Short only inside the project. A file anywhere else keeps its whole path, so it cannot pass for a file of the project.
    static func path(_ path: String, cwd: String?) -> String {
        guard let cwd, path.hasPrefix(cwd + "/") else { return path }
        return String(path.dropFirst(cwd.count + 1))
    }

    static func waitChoice(_ seconds: Int) -> String {
        seconds < 60 ? L("%lld s", seconds) : L("%lld min", seconds / 60)
    }
}
