import Foundation

/// One question of `AskUserQuestion`.
public struct RequestQuestion: Sendable, Equatable {
    public struct Option: Sendable, Equatable {
        public var label: String
        public var detail: String?

        public init(label: String, detail: String? = nil) {
            self.label = label
            self.detail = detail
        }
    }

    public var text: String
    public var multiple: Bool
    public var options: [Option]

    public init(text: String, multiple: Bool = false, options: [Option]) {
        self.text = text
        self.multiple = multiple
        self.options = options
    }
}

/// One changed line of a file.
public struct RequestDiffLine: Sendable, Equatable {
    public var added: Bool
    public var text: String

    public init(added: Bool, text: String) {
        self.added = added
        self.text = text
    }
}

/// What a request asks for, as a person needs to read it. It stays in memory only while the request is open.
public enum RequestContent: Sendable, Equatable {
    case command(String, unsandboxed: Bool)
    /// `whole` means the file gets this text entirely, rather than a change in place.
    case file(path: String, lines: [RequestDiffLine], whole: Bool, everyOccurrence: Bool)
    case questions([RequestQuestion])
    case plan(String)
    case other(String)
    /// Too long to read in full, or in a shape Boris does not understand. A person cannot agree to what they cannot read.
    case unreadable(String)

    public static func parse(tool: String, input: [String: Any]?, flat: String) -> RequestContent {
        guard let input else { return .unreadable(flat) }
        // Not `flat`: it may be cut, and for a tool with a `command` field it leaves the other fields out, while Allow stays available here.
        let whole = HookPayload.wholeText(input).map(RequestContent.other) ?? .unreadable(flat)
        switch tool {
        case "Bash":
            guard let command = input["command"] as? String else { return whole }
            return .command(command, unsandboxed: input["dangerouslyDisableSandbox"] as? Bool == true)
        case "Edit":
            guard let path = input["file_path"] as? String, let old = input["old_string"] as? String, let new = input["new_string"] as? String else { return whole }
            return .file(path: path, lines: diff(old: old, new: new), whole: false, everyOccurrence: input["replace_all"] as? Bool == true)
        case "MultiEdit":
            guard let path = input["file_path"] as? String, let edits = input["edits"] as? [[String: Any]] else { return whole }
            var lines: [RequestDiffLine] = []
            var every = false
            for edit in edits {
                guard let old = edit["old_string"] as? String, let new = edit["new_string"] as? String else { return whole }
                lines += diff(old: old, new: new)
                every = every || edit["replace_all"] as? Bool == true
            }
            return .file(path: path, lines: lines, whole: false, everyOccurrence: every)
        case "Write":
            guard let path = input["file_path"] as? String, let text = input["content"] as? String else { return whole }
            return .file(path: path, lines: added(text), whole: true, everyOccurrence: false)
        case "NotebookEdit":
            guard let path = input["notebook_path"] as? String, let source = input["new_source"] as? String, input["edit_mode"] as? String != "delete" else { return whole }
            return .file(path: path, lines: added(source), whole: false, everyOccurrence: false)
        case "AskUserQuestion":
            return questions(input).map(RequestContent.questions) ?? .unreadable(flat)
        case "ExitPlanMode":
            guard let plan = input["plan"] as? String, !plan.isEmpty else { return .unreadable(flat) }
            return .plan(plan)
        default:
            return whole
        }
    }

    /// Answers are keyed by the question's text, so two identical questions could not both be answered.
    private static func questions(_ input: [String: Any]) -> [RequestQuestion]? {
        guard let raw = input["questions"] as? [[String: Any]], !raw.isEmpty else { return nil }
        var result: [RequestQuestion] = []
        for item in raw {
            guard let text = item["question"] as? String, let options = item["options"] as? [[String: Any]], !options.isEmpty else { return nil }
            var parsed: [RequestQuestion.Option] = []
            for option in options {
                guard let label = option["label"] as? String else { return nil }
                parsed.append(RequestQuestion.Option(label: label, detail: (option["description"] as? String).flatMap { $0.isEmpty ? nil : $0 }))
            }
            result.append(RequestQuestion(text: text, multiple: item["multiSelect"] as? Bool == true, options: parsed))
        }
        return Set(result.map(\.text)).count == result.count ? result : nil
    }

    private static func lines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    private static func added(_ text: String) -> [RequestDiffLine] {
        lines(text).map { RequestDiffLine(added: true, text: $0) }
    }

    /// Only what changes. The same lines around the change say nothing about what is being agreed to.
    static func diff(old: String, new: String) -> [RequestDiffLine] {
        let before = lines(old)
        let after = lines(new)
        var start = 0
        while start < before.count, start < after.count, before[start] == after[start] { start += 1 }
        var tail = 0
        while tail < before.count - start, tail < after.count - start, before[before.count - 1 - tail] == after[after.count - 1 - tail] { tail += 1 }
        let removed = before[start..<(before.count - tail)].map { RequestDiffLine(added: false, text: $0) }
        let added = after[start..<(after.count - tail)].map { RequestDiffLine(added: true, text: $0) }
        return removed + added
    }

    /// False when the only honest answers are no, or going to Claude.
    public var canAllow: Bool {
        if case .unreadable = self { return false }
        return true
    }
}

/// What the person has put into an open card so far. It leaves memory with the request.
public struct RequestDraft: Sendable, Equatable {
    /// The form with a reason is open.
    public var denying = false
    public var reason = ""
    /// Chosen labels by question text.
    public var picks: [String: Set<String>] = [:]

    public init() {}

    public mutating func toggle(_ label: String, in question: RequestQuestion) {
        var chosen = picks[question.text] ?? []
        if question.multiple {
            if chosen.remove(label) == nil { chosen.insert(label) }
        } else {
            chosen = [label]
        }
        picks[question.text] = chosen
    }

    /// Nil until every question has an answer. Several labels go in the order Claude listed them, joined the way Claude expects.
    public func answers(to questions: [RequestQuestion]) -> [String: String]? {
        var result: [String: String] = [:]
        for question in questions {
            let chosen = picks[question.text] ?? []
            let labels = question.options.map(\.label).filter(chosen.contains)
            guard !labels.isEmpty else { return nil }
            result[question.text] = labels.joined(separator: ", ")
        }
        return result
    }
}

/// The person's answer as it travels from the app to `boris-hook`, down the connection of its own request.
public enum HookAnswer: Sendable, Equatable {
    case allow
    case deny(reason: String)
    case answers([String: String])

    /// One JSON line.
    public var line: Data {
        let object: [String: Any]
        switch self {
        case .allow: object = ["behavior": "allow"]
        case .deny(let reason): object = ["behavior": "deny", "reason": reason]
        case .answers(let answers): object = ["behavior": "allow", "answers": answers]
        }
        var data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        data.append(0x0A)
        return data
    }

    /// Anything else on the line means no answer: a decision is never guessed.
    public init?(line: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return nil }
        switch object["behavior"] as? String {
        case "allow":
            if object["answers"] != nil {
                guard let answers = object["answers"] as? [String: String], !answers.isEmpty else { return nil }
                self = .answers(answers)
            } else {
                self = .allow
            }
        case "deny":
            self = .deny(reason: object["reason"] as? String ?? "")
        default:
            return nil
        }
    }

    /// What Claude reads from the hook. Nil means no decision, and the request stays in Claude.
    /// Permissions are never remembered here: `updatedPermissions` is not sent.
    public func output(tool: String?, input: [String: Any]?) -> Data? {
        var decision: [String: Any]
        switch self {
        case .allow:
            decision = ["behavior": "allow"]
            switch tool {
            case "AskUserQuestion":
                return nil
            case "ExitPlanMode":
                // Claude's documentation asks for the input back with this tool.
                guard let input else { return nil }
                decision["updatedInput"] = input
            default:
                break
            }
        case .deny(let reason):
            let reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            decision = ["behavior": "deny", "message": reason.isEmpty ? "Denied in Boris" : reason]
        case .answers(let answers):
            guard tool == "AskUserQuestion", var updated = input, updated["questions"] != nil else { return nil }
            updated["answers"] = answers
            decision = ["behavior": "allow", "updatedInput": updated]
        }
        let wrapped: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
        guard JSONSerialization.isValidJSONObject(wrapped) else { return nil }
        return try? JSONSerialization.data(withJSONObject: wrapped)
    }
}
