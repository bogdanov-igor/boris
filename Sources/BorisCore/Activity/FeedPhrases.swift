import Foundation

extension WorkPhrases {
    /// The name of an action on the Activity page. A tool without a kind of its own goes by its own name.
    public static func action(_ action: WorkAction, tool: String) -> String {
        switch action {
        case .read: return L("Read")
        case .write: return L("Write")
        case .command: return L("Command")
        case .webSearch, .webFetch: return L("Web search")
        case .skill: return L("Skill")
        case .mcp: return "MCP"
        case .startAgent: return L("Start agent")
        case .other: return tool
        }
    }

    /// How a step is named in the technical feed. Nil for a step with nothing to add to its tool.
    public static func target(_ step: ActivityStep, cwd: String?) -> String? {
        let firstLine = step.input.command?.split(separator: "\n", maxSplits: 1).first.map(String.init)
        switch step.kind {
        case .shell:
            return firstLine ?? step.input.note
        case .search:
            return [step.input.target, step.input.note.map { path($0, cwd: cwd) }].compactMap { $0 }.joined(separator: " ")
        case .web:
            return step.input.target ?? firstLine
        case .helper:
            return step.input.target ?? step.input.note ?? firstLine
        case .read, .edit, .write:
            return step.input.target.map { path($0, cwd: cwd) }
        case .answer, .other:
            return step.input.target ?? step.input.note
        }
    }

    /// Inside the project a path is told from its folder.
    public static func path(_ path: String, cwd: String?) -> String {
        guard let cwd, path.hasPrefix(cwd + "/") else { return path }
        return String(path.dropFirst(cwd.count + 1))
    }

    /// A step's own time: `0,4 с`, `1:23`, `1:02:03`.
    public static func stepDuration(_ seconds: TimeInterval) -> String {
        guard seconds >= 60 else {
            return L("%@ s", max(0, seconds).formatted(.number.precision(.fractionLength(1)).locale(Localizer.locale)))
        }
        return clock(seconds)
    }

    /// `0:14`, `1:02:03`.
    public static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let minutes = String(format: "%02d", total / 60 % 60)
        let rest = String(format: "%02d", total % 60)
        return total >= 3600 ? "\(total / 3600):\(minutes):\(rest)" : "\(total / 60):\(rest)"
    }

    /// The time of a record. One from another day also says which day.
    public static func time(_ date: Date, now: Date, seconds: Bool, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.locale = Localizer.locale
        formatter.timeZone = timeZone
        if calendar.isDate(date, inSameDayAs: now) {
            formatter.dateFormat = seconds ? "HH:mm:ss" : "HH:mm"
        } else {
            formatter.dateFormat = Localizer.locale.identifier == "ru" ? "d MMM HH:mm" : "MMM d HH:mm"
        }
        return formatter.string(from: date)
    }

    /// The whole feed as plain text, for pasting elsewhere. It goes to the clipboard only when the person asks.
    public static func plainText(_ entries: [FeedEntry], names: [String: String], cwd: String?) -> String {
        entries.map { entry in
            let agent = entry.agentId.map { names[$0] ?? L("Agent") } ?? L("Main agent")
            switch entry.item {
            case .note(_, let text, _):
                return text
            case .prompt(_, let text, _):
                return entry.agentId == nil ? "\(L("You")):\n\(text)" : "\(agent):\n\(text)"
            case .step(let step):
                var lines = ["\(agent) · \(step.tool)" + (target(step, cwd: cwd).map { " \($0)" } ?? "")]
                if let command = step.input.command, command != target(step, cwd: cwd) { lines.append(command) }
                lines += step.diff().map { ($0.kind == .added ? "+ " : "- ") + $0.text }
                if let output = step.output, !output.isEmpty, step.kind != .read { lines.append(output) }
                return lines.joined(separator: "\n")
            }
        }.joined(separator: "\n\n")
    }
}

/// The types the Activity page filters by.
public enum ActivityFilter: String, Sendable, CaseIterable, Identifiable {
    case all, read, write, command, web, skill, mcp, startAgent

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: return L("All")
        case .read: return L("Read")
        case .write: return L("Write")
        case .command: return L("Command")
        case .web: return L("Web search")
        case .skill: return L("Skill")
        case .mcp: return "MCP"
        case .startAgent: return L("Start agent")
        }
    }

    public func matches(_ action: WorkAction) -> Bool {
        switch self {
        case .all: return true
        case .read: return action == .read
        case .write: return action == .write
        case .command: return action == .command
        case .web: return action == .webSearch || action == .webFetch
        case .skill: return action == .skill
        case .mcp: return action == .mcp
        case .startAgent: return action == .startAgent
        }
    }
}
