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

/// One parameter of a tool call, as the technical details show it.
public struct ToolParameter: Sendable, Equatable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
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
    /// What else the call was given. The long texts above are not repeated here, and a value is cut short: the event itself has all of it.
    public var parameters: [ToolParameter]

    public init(target: String? = nil, note: String? = nil, command: String? = nil, oldText: String? = nil, newText: String? = nil, parameters: [ToolParameter] = []) {
        self.target = target
        self.note = note
        self.command = command
        self.oldText = oldText
        self.newText = newText
        self.parameters = parameters
    }
}

public enum ActivityEvent: Sendable, Equatable {
    case toolUse(id: String, tool: String, input: ToolInput, at: Date?)
    case toolResult(id: String, isError: Bool, text: String?, at: Date?)
    case text(String, at: Date?)
    /// What the person asked, or the task an agent was given.
    case prompt(String, at: Date?)
    /// What the message that made this call cost. Tokens are counted per message, not per tool.
    case tokens(id: String, TokenUsage)
    /// What really changed, as Claude Code worked it out once the call was done. Only a session's own transcript has this, an agent's has not.
    case patch(id: String, [DiffHunk])
    /// A file was written over and the log does not say what it held before.
    case overwrote(id: String)
}

/// One piece of a change, as in a unified diff.
public struct DiffHunk: Sendable, Equatable {
    public var oldStart: Int
    public var newStart: Int
    /// Each line starts with a space, `-` or `+`.
    public var lines: [String]

    public init(oldStart: Int, newStart: Int, lines: [String]) {
        self.oldStart = oldStart
        self.newStart = newStart
        self.lines = lines
    }
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
    public var tokens: TokenUsage?
    public var hunks: [DiffHunk] = []
    /// Long texts are cut to keep the feed small, so the whole change has to be read again from the transcript.
    public var isCut = false
    /// The file was written over and its old text is unknown, so nothing can be said about how many lines changed.
    public var oldTextUnknown = false

    public var duration: TimeInterval? {
        guard let startedAt, let finishedAt else { return nil }
        return max(0, finishedAt.timeIntervalSince(startedAt))
    }

    /// True for a call that was meant to change a file.
    public var isChange: Bool { kind == .edit || kind == .write }

    /// The lines of this change. Line numbers come from Claude Code's own patch. Without one the two texts are compared, and that gives no numbers.
    /// - Parameter context: also the unchanged lines around the change.
    public func diff(context: Bool = false) -> [DiffLines.Line] {
        let lines = hunks.isEmpty ? DiffLines.changed(old: input.oldText, new: input.newText) : DiffLines.lines(of: hunks)
        return context ? lines : lines.filter { $0.kind != .context }
    }

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

    /// Notes and prompts are numbered within their file, so a later file of the same agent starts the numbers again.
    fileprivate func inPart(_ part: Int) -> ActivityItem {
        guard part > 0 else { return self }
        switch self {
        case .step: return self
        case .note(let id, let text, let at): return .note(id: "\(part)-\(id)", text: text, at: at)
        case .prompt(let id, let text, let at): return .prompt(id: "\(part)-\(id)", text: text, at: at)
        }
    }
}

/// The feed of one agent or session. Transcripts may repeat a record, so steps are matched by id.
public struct ActivityLog: Sendable, Equatable {
    public static let limit = 400
    static let textLimit = 8 * 1024
    static let outputLimit = 4 * 1024

    public private(set) var items: [ActivityItem] = []
    /// True once the oldest records have been dropped to stay within the limit.
    public private(set) var dropped = false
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
            trimmed.command = input.command.map { Self.head($0, Self.textLimit) }
            var step = ActivityStep(id: id, tool: tool, kind: StepKind(tool: tool), input: trimmed, state: .running, startedAt: at)
            step.isCut = trimmed != input
            let stat = DiffLines.stat(old: input.oldText, new: input.newText)
            step.added = stat?.added
            step.removed = stat?.removed
            items.append(.step(step))
        case .toolResult(let id, let isError, let text, let at):
            guard let index = items.lastIndex(where: { $0.id == id }), case .step(var step) = items[index] else { return }
            step.state = isError ? .failed : .done
            step.finishedAt = at
            step.output = text.map { Self.tail($0, Self.outputLimit) }
            // A change that failed changed nothing, so it has no lines to count.
            if isError, step.isChange {
                step.added = nil
                step.removed = nil
            }
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
        case .tokens(let id, let usage):
            guard let index = items.lastIndex(where: { $0.id == id }), case .step(var step) = items[index] else { return }
            step.tokens = usage
            items[index] = .step(step)
        case .patch(let id, let hunks):
            guard let index = items.lastIndex(where: { $0.id == id }), case .step(var step) = items[index] else { return }
            let lines = DiffLines.lines(of: hunks)
            step.added = lines.filter { $0.kind == .added }.count
            step.removed = lines.filter { $0.kind == .removed }.count
            let kept = Self.head(hunks, Self.textLimit)
            step.hunks = kept
            step.isCut = step.isCut || kept != hunks
            items[index] = .step(step)
        case .overwrote(let id):
            guard let index = items.lastIndex(where: { $0.id == id }), case .step(var step) = items[index], step.kind == .write else { return }
            step.oldTextUnknown = true
            step.added = nil
            step.removed = nil
            items[index] = .step(step)
        }
        if items.count > Self.limit {
            items.removeFirst(items.count - Self.limit)
            dropped = true
        }
    }

    /// For an agent or session that has stopped: nothing is running any more.
    public mutating func closeRunning() {
        items = items.map { item in
            guard case .step(var step) = item, step.state == .running else { return item }
            step.state = .unfinished
            return .step(step)
        }
    }

    /// One agent's log from the files its work was written to, oldest first. An agent that goes on after its workflow has ended writes a new file under the same id.
    /// An older file gets no more results, a call found in two files is told by the newer one, and notes of different files keep different ids.
    public static func joined(_ parts: [ActivityLog]) -> ActivityLog {
        guard parts.count > 1 else { return parts.first ?? ActivityLog() }
        var result = ActivityLog()
        var later: Set<String> = []
        var kept: [[ActivityItem]] = []
        for (index, part) in parts.enumerated().reversed() {
            var old = part
            if index < parts.count - 1 { old.closeRunning() }
            let items = old.items.filter { item in
                if case .step = item { return !later.contains(item.id) }
                return true
            }
            kept.append(items.map { $0.inPart(index) })
            later.formUnion(old.items.map(\.id))
            result.dropped = result.dropped || part.dropped
        }
        let all = Array(kept.reversed().joined())
        result.items = Array(all.suffix(limit))
        result.dropped = result.dropped || all.count > limit
        return result
    }

    /// The counts are taken before this, so they stay right for a change that is cut.
    private static func head(_ hunks: [DiffHunk], _ limit: Int) -> [DiffHunk] {
        var room = limit
        var kept: [DiffHunk] = []
        for hunk in hunks {
            var lines: [String] = []
            for line in hunk.lines {
                guard room > 0 else { break }
                lines.append(line)
                room -= line.utf8.count + 1
            }
            if !lines.isEmpty { kept.append(DiffHunk(oldStart: hunk.oldStart, newStart: hunk.newStart, lines: lines)) }
            guard room > 0 else { break }
        }
        return kept
    }

    /// A limit counted in bytes can fall inside a letter, which would show as a broken character, so the cut moves to the letter's edge.
    private static func head(_ text: String, _ limit: Int) -> String {
        guard text.utf8.count > limit else { return text }
        var end = text.utf8.index(text.startIndex, offsetBy: limit)
        while end > text.startIndex, end.samePosition(in: text.unicodeScalars) == nil { end = text.utf8.index(before: end) }
        return String(text[..<end]) + "\n…"
    }

    private static func tail(_ text: String, _ limit: Int) -> String {
        guard text.utf8.count > limit else { return text }
        var start = text.utf8.index(text.endIndex, offsetBy: -limit)
        while start < text.endIndex, start.samePosition(in: text.unicodeScalars) == nil { start = text.utf8.index(after: start) }
        return "…\n" + String(text[start...])
    }
}

/// Lines before and after an edit, without the common start and end.
public enum DiffLines {
    public struct Line: Sendable, Equatable, Identifiable {
        public enum Kind: Sendable, Equatable { case context, removed, added }
        public let id: Int
        public let kind: Kind
        public let text: String
        /// In the old file for a removed line, in the new one otherwise. Nil when unknown.
        public var number: Int?
    }

    /// Lines of Claude Code's patch, numbered.
    public static func lines(of hunks: [DiffHunk]) -> [Line] {
        var lines: [Line] = []
        for hunk in hunks {
            var old = hunk.oldStart
            var new = hunk.newStart
            for raw in hunk.lines {
                let text = String(raw.dropFirst())
                switch raw.first {
                case "-":
                    lines.append(Line(id: lines.count, kind: .removed, text: text, number: old))
                    old += 1
                case "+":
                    lines.append(Line(id: lines.count, kind: .added, text: text, number: new))
                    new += 1
                case " ":
                    lines.append(Line(id: lines.count, kind: .context, text: text, number: new))
                    old += 1
                    new += 1
                default:
                    // "\ No newline at end of file" says something about the line before it and is no line itself.
                    break
                }
            }
        }
        return lines
    }

    public static func changed(old: String?, new: String?) -> [Line] {
        let a = (old ?? "").components(separatedBy: "\n")
        var b = (new ?? "").components(separatedBy: "\n")
        // A whole new file: its last line break ends a line and does not start one.
        if old == nil, b.count > 1, b.last == "" { b.removeLast() }
        var start = 0
        while start < a.count, start < b.count, a[start] == b[start] { start += 1 }
        var endA = a.count
        var endB = b.count
        while endA > start, endB > start, a[endA - 1] == b[endB - 1] {
            endA -= 1
            endB -= 1
        }
        let before = (old ?? "").isEmpty ? [] : Array(a[start..<endA])
        var lines: [Line] = []
        var written = 0
        for (kind, text) in script(before, Array(b[start..<endB])) {
            if kind == .added { written += 1 }
            lines.append(Line(id: lines.count, kind: kind, text: text, number: old == nil ? written : nil))
        }
        return lines
    }

    /// More than this many pairs of lines to compare, and two pieces of text simply count as replaced.
    private static let comparisonLimit = 1_000_000

    /// How to get from one list of lines to the other with the fewest changes, removals first.
    private static func script(_ a: [String], _ b: [String]) -> [(Line.Kind, String)] {
        guard !a.isEmpty, !b.isEmpty, a.count * b.count <= comparisonLimit else {
            return a.map { (.removed, $0) } + b.map { (.added, $0) }
        }
        // How many lines the rest of both lists have in common, from each pair of positions.
        let width = b.count + 1
        var common = [Int32](repeating: 0, count: (a.count + 1) * width)
        for i in a.indices.reversed() {
            for j in b.indices.reversed() {
                common[i * width + j] = a[i] == b[j] ? common[(i + 1) * width + j + 1] + 1 : max(common[(i + 1) * width + j], common[i * width + j + 1])
            }
        }
        var result: [(Line.Kind, String)] = []
        var i = 0
        var j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                result.append((.context, a[i]))
                i += 1
                j += 1
            } else if common[(i + 1) * width + j] >= common[i * width + j + 1] {
                result.append((.removed, a[i]))
                i += 1
            } else {
                result.append((.added, b[j]))
                j += 1
            }
        }
        result += a[i...].map { (.removed, $0) }
        result += b[j...].map { (.added, $0) }
        return result
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
