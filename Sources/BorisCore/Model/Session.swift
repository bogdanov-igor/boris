import Foundation

/// A process pinned by its start time, so a reused PID is not mistaken for the original.
public struct ProcessIdentity: Codable, Sendable, Equatable {
    public var pid: Int32
    public var start: Date

    public init(pid: Int32, start: Date) {
        self.pid = pid
        self.start = start
    }
}

/// One `sessions/<pid>.json` file, or a session known only by its transcript. Every field except the ids may be absent.
public struct SessionInfo: Sendable, Equatable, Identifiable {
    public var id: String { sessionId }
    public var sessionId: String
    public var pid: Int32
    public var cwd: String?
    public var entrypoint: String?
    public var name: String?
    public var status: String?
    public var waitingFor: String?
    public var version: String?
    public var procStart: Date?
    public var startedAt: Date?
    public var statusUpdatedAt: Date?
    /// What the session is doing now, read while the menu is open.
    public var currentStep: StepBrief?
    /// `derived` means Claude Code made the name up from the folder.
    public var nameSource: String?
    /// The title Claude gave the conversation. It comes from the request, so it is for lists on screen only.
    public var title: String?
    /// How full the main agent's context is and on which model, from the last record. Read while someone looks closely.
    public var contextTokens: Int?
    public var model: String?

    public init(
        sessionId: String,
        pid: Int32,
        cwd: String? = nil,
        entrypoint: String? = nil,
        name: String? = nil,
        status: String? = nil,
        waitingFor: String? = nil,
        version: String? = nil,
        procStart: Date? = nil,
        startedAt: Date? = nil,
        statusUpdatedAt: Date? = nil
    ) {
        self.sessionId = sessionId
        self.pid = pid
        self.cwd = cwd
        self.entrypoint = entrypoint
        self.name = name
        self.status = status
        self.waitingFor = waitingFor
        self.version = version
        self.procStart = procStart
        self.startedAt = startedAt
        self.statusUpdatedAt = statusUpdatedAt
    }

    public var projectName: String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }

    /// True when the session belongs to an editor extension rather than a terminal.
    public var isEditorSession: Bool {
        entrypoint?.contains("vscode") == true
    }

    /// Known only by its transcript: there is no process to look at, as with Cowork, whose processes live in a virtual machine.
    public var isUnlisted: Bool { pid <= 0 }

    /// The name a person would recognise: their own, then Claude's title, then the made-up one.
    public var displayName: String? {
        nameSource == "derived" ? title ?? name : name ?? title
    }

    public var environment: WorkEnvironment? { WorkEnvironment(entrypoint: entrypoint, unlisted: isUnlisted) }
}

/// `procStart` is the text of `ps -o lstart=` taken in UTC, for example `Wed Nov  4 06:51:16 2026`.
public enum ProcStart {
    private static let parser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return f
    }()

    public static func parse(_ text: String?) -> Date? {
        guard let text else { return nil }
        let squeezed = text.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return parser.date(from: squeezed)
    }
}

/// What a session is waiting for, read from `waitingFor`.
public enum WaitingReason: Sendable, Equatable {
    /// The file does not always name the tool: terminal sessions write only `permission prompt`.
    case permission(tool: String?)
    case input
    case dialog
    case other(String)

    public init?(_ raw: String?) {
        guard let raw, !raw.isEmpty else { return nil }
        if raw == "input needed" {
            self = .input
        } else if raw == "dialog open" {
            self = .dialog
        } else if raw == "permission prompt" {
            self = .permission(tool: nil)
        } else if raw.hasPrefix("approve ") {
            let rest = raw.dropFirst("approve ".count)
            let tool = rest.split(separator: ":", maxSplits: 1).first.map(String.init) ?? String(rest)
            self = .permission(tool: tool.trimmingCharacters(in: .whitespaces))
        } else {
            self = .other(raw)
        }
    }
}
