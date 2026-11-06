import BorisCore
import Foundation

/// What Claude Desktop keeps next to a Cowork session's folder, `<session id>.json`.
///
/// The same file holds the person's email, name, first message and the system prompt, so only these fields are ever decoded.
public struct CoworkSessionFile: Sendable, Equatable {
    /// The name in Claude Desktop's own list. It comes from the request, so it is for lists on screen only.
    public var title: String?
    /// The folders the person gave the task, as paths on this Mac.
    public var folders: [String]
    public var model: String?

    public init(title: String? = nil, folders: [String] = [], model: String? = nil) {
        self.title = title
        self.folders = folders
        self.model = model
    }

    /// The task's name, otherwise the folder it works in. The session's own folder is made up by the virtual machine and says nothing.
    public var name: String? {
        if let title, !title.isEmpty { return title }
        return folders.first.map { URL(fileURLWithPath: $0).lastPathComponent }.flatMap { $0.isEmpty || $0 == "/" ? nil : $0 }
    }

    /// `.../<session id>/.claude/projects/<folder>/<transcript>.jsonl` has its file at `.../<session id>.json`. Nil for any other transcript.
    public static func url(forTranscript transcript: URL) -> URL? {
        let root = transcript.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard ClaudeFolders.isCowork(transcript), root.lastPathComponent == ".claude" else { return nil }
        let session = root.deletingLastPathComponent()
        return session.deletingLastPathComponent().appendingPathComponent(session.lastPathComponent + ".json")
    }

    /// A file that cannot be read is no reason to lose the session: what is missing is then simply not known.
    public static func read(_ url: URL) -> CoworkSessionFile? {
        guard let data = try? Data(contentsOf: url), let fields = try? JSONDecoder().decode(Fields.self, from: data) else { return nil }
        return CoworkSessionFile(title: fields.title, folders: fields.userSelectedFolders ?? [], model: fields.model)
    }

    /// One field of an unexpected type must not cost the others.
    private struct Fields: Decodable {
        var title: String?
        var userSelectedFolders: [String]?
        var model: String?

        private enum CodingKeys: String, CodingKey {
            case title, userSelectedFolders, model
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            title = try? values.decode(String.self, forKey: .title)
            userSelectedFolders = try? values.decode([String].self, forKey: .userSelectedFolders)
            model = try? values.decode(String.self, forKey: .model)
        }
    }
}

/// Whether a Cowork session is waiting for the person, going by its transcript alone.
///
/// Claude Desktop keeps open questions and permission requests in its memory, and no file says so (see section 16 of design.md).
/// What the file does show is a call with no result yet, and which tools Cowork runs without asking is known.
enum CoworkWaiting {
    /// How long a call to a tool that may ask stays quiet before it counts as asking. A guess: a connector can also simply be slow.
    static let settle: TimeInterval = 20
    /// A person can take their time, so silence ends a waiting session later than a working one.
    static let quietLimit: TimeInterval = 60 * 60

    /// The `allowedTools` of Cowork in Claude Desktop 4.29, and the shell and web tools it renames them to.
    private static let neverAsks: Set<String> = [
        "Task", "Agent", "Bash", "BashOutput", "KillShell", "Monitor", "Glob", "Grep", "LS", "Read", "Edit", "MultiEdit", "Write", "NotebookEdit", "NotebookRead",
        "WebFetch", "WebSearch", "Skill", "REPL", "JavaScript", "ToolSearch", "TodoWrite", "TaskOutput", "TaskStop", "SendUserMessage",
        "mcp__workspace__bash", "mcp__workspace__web_fetch",
    ]
    private static let neverAsksPrefixes = ["mcp__mcp-registry__", "mcp__plugins__", "mcp__skills__", "mcp__computer-use__"]

    /// The text of `waitingFor`, as Claude Code writes it in its session files. Nil when nothing says the session is waiting.
    static func reason(running: StepBrief?, quietFor: TimeInterval) -> String? {
        guard let tool = running?.tool else { return nil }
        // These two are nothing but a question to the person, so there is no need to wait and see.
        if tool == "AskUserQuestion" { return "input needed" }
        if tool == "ExitPlanMode" { return "approve ExitPlanMode" }
        guard !neverAsks.contains(tool), !neverAsksPrefixes.contains(where: tool.hasPrefix), quietFor >= settle else { return nil }
        return "approve \(tool)"
    }
}
