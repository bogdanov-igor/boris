import Foundation

public enum StepKind: String, Sendable, Equatable, CaseIterable {
    case read, edit, write, shell, search, web, helper, answer, other

    public init(tool: String) {
        switch tool {
        case "Read", "NotebookRead": self = .read
        case "Edit", "MultiEdit", "NotebookEdit": self = .edit
        case "Write": self = .write
        case "Bash", "Monitor", "BashOutput": self = .shell
        case "Grep", "Glob", "LS": self = .search
        case "WebFetch", "WebSearch": self = .web
        case "Agent", "Task", "Skill", "Workflow": self = .helper
        case "StructuredOutput": self = .answer
        default: self = .other
        }
    }
}

public enum StepState: Sendable, Equatable {
    case running, done, failed
    /// The agent ended before this call got a result. Whether it worked is unknown.
    case unfinished
}

/// What a tool call is about, taken from its input.
public struct ToolInput: Sendable, Equatable {
    /// A file, an address or a search pattern.
    public var target: String?
    /// The command's human description, when it has one.
    public var note: String?
    /// The full command or query. Content: shown only in details.
    public var command: String?
    public var oldText: String?
    public var newText: String?

    public init(target: String? = nil, note: String? = nil, command: String? = nil, oldText: String? = nil, newText: String? = nil) {
        self.target = target
        self.note = note
        self.command = command
        self.oldText = oldText
        self.newText = newText
    }
}

public enum ActivityEvent: Sendable, Equatable {
    case toolUse(id: String, tool: String, input: ToolInput, at: Date?)
    case toolResult(id: String, isError: Bool, text: String?, at: Date?)
    case text(String, at: Date?)
    /// What the person asked, or the task an agent was given.
    case prompt(String, at: Date?)
}

public struct ActivityStep: Sendable, Equatable, Identifiable {
    public let id: String
    public var tool: String
    public var kind: StepKind
    public var input: ToolInput
    public var added: Int?
    public var removed: Int?
    public var output: String?
    public var state: StepState
    public var startedAt: Date?
    public var finishedAt: Date?

    /// The last path part, for places that must not show whole paths.
    public var fileName: String? {
        guard kind == .read || kind == .edit || kind == .write, let target = input.target else { return nil }
        return URL(fileURLWithPath: target).lastPathComponent
    }

    public var brief: StepBrief {
        StepBrief(kind: kind, tool: tool, fileName: fileName, skill: tool == "Skill" ? input.target : nil)
    }
}

/// A step reduced to what a list may show: never a command's text.
public struct StepBrief: Sendable, Equatable {
    public var kind: StepKind
    public var tool: String
    public var fileName: String?
    public var skill: String?

    public init(kind: StepKind, tool: String, fileName: String? = nil, skill: String? = nil) {
        self.kind = kind
        self.tool = tool
        self.fileName = fileName
        self.skill = skill
    }
}

public enum ActivityItem: Sendable, Equatable, Identifiable {
    case step(ActivityStep)
    case note(id: String, text: String, at: Date?)
    case prompt(id: String, text: String, at: Date?)

    public var id: String {
        switch self {
        case .step(let step): return step.id
        case .note(let id, _, _), .prompt(let id, _, _): return id
        }
    }

    public var at: Date? {
        switch self {
        case .step(let step): return step.startedAt
        case .note(_, _, let at), .prompt(_, _, let at): return at
        }
    }
}

/// The feed of one agent or session. Transcripts may repeat a record, so steps are matched by id.
public struct ActivityLog: Sendable, Equatable {
    public static let limit = 400
    static let textLimit = 8 * 1024
    static let outputLimit = 4 * 1024

    public private(set) var items: [ActivityItem] = []
    private var nextNote = 0

    public init() {}

    public var current: ActivityStep? {
        for item in items.reversed() {
            if case .step(let step) = item, step.state == .running { return step }
        }
        return nil
    }

    public mutating func apply(_ event: ActivityEvent) {
        switch event {
        case .toolUse(let id, let tool, let input, let at):
            guard !items.contains(where: { $0.id == id }) else { return }
            var trimmed = input
            trimmed.oldText = input.oldText.map { Self.head($0, Self.textLimit) }
            trimmed.newText = input.newText.map { Self.head($0, Self.textLimit) }
            var step = ActivityStep(id: id, tool: tool, kind: StepKind(tool: tool), input: trimmed, state: .running, startedAt: at)
            let stat = DiffLines.stat(old: input.oldText, new: input.newText)
            step.added = stat?.added
            step.removed = stat?.removed
            items.append(.step(step))
        case .toolResult(let id, let isError, let text, let at):
            guard let index = items.lastIndex(where: { $0.id == id }), case .step(var step) = items[index] else { return }
            step.state = isError ? .failed : .done
            step.finishedAt = at
            step.output = text.map { Self.tail($0, Self.outputLimit) }
            items[index] = .step(step)
        case .text(let text, let at):
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { return }
            nextNote += 1
            items.append(.note(id: "note-\(nextNote)", text: Self.head(clean, Self.textLimit), at: at))
        case .prompt(let text, let at):
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { return }
            nextNote += 1
            items.append(.prompt(id: "prompt-\(nextNote)", text: Self.head(clean, Self.textLimit), at: at))
        }
        if items.count > Self.limit { items.removeFirst(items.count - Self.limit) }
    }

    /// For an agent or session that has stopped: nothing is running any more.
    public mutating func closeRunning() {
        items = items.map { item in
            guard case .step(var step) = item, step.state == .running else { return item }
            step.state = .unfinished
            return .step(step)
        }
    }

    private static func head(_ text: String, _ limit: Int) -> String {
        text.utf8.count <= limit ? text : String(decoding: text.utf8.prefix(limit), as: UTF8.self) + "\n…"
    }

    private static func tail(_ text: String, _ limit: Int) -> String {
        text.utf8.count <= limit ? text : "…\n" + String(decoding: text.utf8.suffix(limit), as: UTF8.self)
    }
}

/// Lines before and after an edit, without the common start and end.
public enum DiffLines {
    public struct Line: Sendable, Equatable, Identifiable {
        public enum Kind: Sendable, Equatable { case removed, added }
        public let id: Int
        public let kind: Kind
        public let text: String
    }

    public static func changed(old: String?, new: String?) -> [Line] {
        let a = (old ?? "").components(separatedBy: "\n")
        let b = (new ?? "").components(separatedBy: "\n")
        var start = 0
        while start < a.count, start < b.count, a[start] == b[start] { start += 1 }
        var endA = a.count
        var endB = b.count
        while endA > start, endB > start, a[endA - 1] == b[endB - 1] {
            endA -= 1
            endB -= 1
        }
        var lines: [Line] = []
        if old != nil, !(old ?? "").isEmpty {
            for text in a[start..<endA] { lines.append(Line(id: lines.count, kind: .removed, text: text)) }
        }
        for text in b[start..<endB] { lines.append(Line(id: lines.count, kind: .added, text: text)) }
        return lines
    }

    static func stat(old: String?, new: String?) -> (added: Int, removed: Int)? {
        guard old != nil || new != nil else { return nil }
        let lines = changed(old: old, new: new)
        return (lines.filter { $0.kind == .added }.count, lines.filter { $0.kind == .removed }.count)
    }
}

/// Puts machine output into a readable shape.
public enum ResultFormat {
    /// JSON becomes an indented outline, with real line breaks inside its strings. Anything else stays as it is.
    public static func pretty(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("["),
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data)
        else { return text }
        return outline(object).joined(separator: "\n")
    }

    private static func outline(_ value: Any) -> [String] {
        switch value {
        case let object as [String: Any]:
            return object.keys.sorted().flatMap { key -> [String] in
                let lines = outline(object[key] as Any)
                if lines.count == 1, !(object[key] is [Any]), !(object[key] is [String: Any]) { return ["\(key): \(lines[0])"] }
                return ["\(key):"] + lines.map { "  " + $0 }
            }
        case let array as [Any]:
            return array.flatMap { item -> [String] in
                let lines = outline(item)
                return lines.enumerated().map { $0.offset == 0 ? "- " + $0.element : "  " + $0.element }
            }
        case let string as String:
            return string.components(separatedBy: "\n")
        case let number as NSNumber:
            return [CFGetTypeID(number) == CFBooleanGetTypeID() ? (number.boolValue ? "true" : "false") : number.stringValue]
        default:
            return ["—"]
        }
    }
}
