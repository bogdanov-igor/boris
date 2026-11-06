import Foundation
import os

public enum LogLevel: String, Sendable, CaseIterable {
    case info, warning, error

    public var label: String {
        switch self {
        case .info: return L("info")
        case .warning: return L("warning")
        case .error: return L("error")
        }
    }
}

public enum LogArea: String, Sendable, CaseIterable {
    case app, data, hooks, requests, notifications, sound, limits, settings, keys, windows, system

    public var label: String {
        switch self {
        case .app: return L("app")
        case .data: return L("data")
        case .hooks: return L("hooks")
        case .requests: return L("requests")
        case .notifications: return L("notifications")
        case .sound: return L("sound")
        case .limits: return L("limits")
        case .settings: return L("settings")
        case .keys: return L("keys")
        case .windows: return L("windows")
        case .system: return L("system")
        }
    }
}

/// One value in a log line. There is deliberately no way to make one from free text:
/// every door below takes a number, a closed list, or a string it cuts down to something that cannot hold a prompt, a path or a token.
public struct LogValue: Sendable, Equatable, Hashable {
    enum Kind: String, Sendable {
        case number = "n", decimal = "d", seconds = "s", flag = "f", word = "w", name = "c", tool = "t", session = "i", version = "v", failure = "e", keys = "k"
    }

    let kind: Kind
    let text: String

    public static func number(_ value: Int) -> LogValue {
        LogValue(kind: .number, text: String(value))
    }

    public static func decimal(_ value: Double) -> LogValue {
        LogValue(kind: .decimal, text: value.isFinite ? String(format: "%.2f", value) : "0.00")
    }

    public static func seconds(_ value: TimeInterval) -> LogValue {
        LogValue(kind: .seconds, text: value.isFinite ? String(format: "%.2f", max(0, value)) : "0.00")
    }

    public static func flag(_ on: Bool) -> LogValue {
        LogValue(kind: .flag, text: on ? "on" : "off")
    }

    public static func word(_ word: LogWord) -> LogValue {
        LogValue(kind: .word, text: word.rawValue)
    }

    /// A case of a closed list, by its name in the code: a sound, an event kind.
    public static func choice<T: RawRepresentable & CaseIterable>(_ value: T) -> LogValue where T.RawValue == String {
        LogValue(kind: .name, text: Self.isName(value.rawValue) ? value.rawValue : "?")
    }

    /// A built-in tool by name. The name of an MCP tool holds the name of a server the person set up, so it becomes `mcp`.
    public static func tool(_ raw: String) -> LogValue {
        if raw.hasPrefix("mcp__") { return LogValue(kind: .tool, text: "mcp") }
        return LogValue(kind: .tool, text: knownTools.contains(raw) ? raw : "other")
    }

    /// A session by the first 8 characters of its id, which is enough to find it and says nothing about it.
    public static func session(_ raw: String) -> LogValue {
        let start = raw.prefix(8)
        return LogValue(kind: .session, text: !start.isEmpty && start.allSatisfy(\.isHexOrDash) ? String(start) : "?")
    }

    public static func version(_ raw: String) -> LogValue {
        LogValue(kind: .version, text: Self.isVersion(raw) ? raw : "?")
    }

    /// Only where an error comes from and its number. Its description often holds the path of a file.
    public static func failure(_ error: Error) -> LogValue {
        let error = error as NSError
        let domain = Self.isDomain(error.domain) ? error.domain : "other"
        return LogValue(kind: .failure, text: "\(domain)/\(error.code)")
    }

    /// The label of a key combination, as ⌥⌘O.
    public static func keys(_ label: String) -> LogValue {
        let clean = label.prefix(Self.keysLimit).map { $0.isWhitespace || $0.isNewline || $0.unicodeScalars.contains { $0.value < 0x20 || (0xF700...0xF8FF).contains($0.value) } ? "?" : String($0) }.joined()
        return LogValue(kind: .keys, text: clean.isEmpty ? "?" : clean)
    }

    /// A field of the settings, by its path in the code.
    static func settingName(_ path: String) -> LogValue {
        LogValue(kind: .name, text: isName(path) ? path : "?")
    }

    /// Names from a file are checked as strictly as names from the code, so a file changed by hand cannot put words into what gets copied.
    init?(stored: String) {
        guard let colon = stored.firstIndex(of: ":"), let kind = Kind(rawValue: String(stored[..<colon])) else { return nil }
        let text = String(stored[stored.index(after: colon)...])
        let isValid: Bool
        switch kind {
        case .number: isValid = Int(text) != nil
        case .decimal, .seconds: isValid = Double(text)?.isFinite == true
        case .flag: isValid = text == "on" || text == "off"
        case .word: isValid = LogWord(rawValue: text) != nil
        case .name: isValid = Self.isName(text) || text == "?"
        case .tool: isValid = Self.knownTools.contains(text) || text == "mcp" || text == "other"
        case .session: isValid = text == "?" || (text.count <= 8 && !text.isEmpty && text.allSatisfy(\.isHexOrDash))
        case .version: isValid = Self.isVersion(text) || text == "?"
        case .failure: isValid = Self.isFailure(text)
        case .keys: isValid = !text.isEmpty && text.count <= Self.keysLimit && !text.contains { $0.isWhitespace || $0.isNewline }
        }
        guard isValid else { return nil }
        self.kind = kind
        self.text = text
    }

    private init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }

    var stored: String { "\(kind.rawValue):\(text)" }

    /// How the value reads in a line, in the language of the interface.
    var shown: String {
        switch kind {
        case .seconds: return Self.duration(Double(text) ?? 0)
        case .decimal: return Self.localized(Double(text) ?? 0, digits: 2)
        case .flag: return text == "on" ? L("on") : L("off")
        case .word: return LogWord(rawValue: text)?.label ?? text
        case .number, .name, .tool, .session, .version, .failure, .keys: return text
        }
    }

    private static func duration(_ seconds: Double) -> String {
        if seconds < 10 { return L("%@ s", localized(seconds, digits: 1)) }
        if seconds < 120 { return L("%@ s", String(Int(seconds.rounded()))) }
        if seconds < 2 * 3600 { return L("%@ min", String(Int((seconds / 60).rounded()))) }
        return L("%@ h", String(Int((seconds / 3600).rounded())))
    }

    private static func localized(_ value: Double, digits: Int) -> String {
        String(format: "%.\(digits)f", locale: Localizer.locale, value)
    }

    private static let keysLimit = 16

    private static func isName(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 64 && text.utf8.allSatisfy { $0.isASCIILetterOrDigit || $0 == 0x5F || $0 == 0x2E }
    }

    private static func isVersion(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 24 && text.utf8.allSatisfy { $0.isASCIILetterOrDigit || $0 == 0x2E || $0 == 0x2B || $0 == 0x2D }
    }

    private static func isDomain(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 60 && text.utf8.allSatisfy { $0.isASCIILetterOrDigit || $0 == 0x2E || $0 == 0x5F || $0 == 0x2D }
    }

    private static func isFailure(_ text: String) -> Bool {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && isDomain(String(parts[0])) && Int(parts[1]) != nil
    }

    /// Claude Code's own tools. A name from outside this list is reported only as `other`.
    private static let knownTools: Set<String> = [
        "Agent", "AskUserQuestion", "Bash", "BashOutput", "CronCreate", "CronDelete", "CronList", "Edit", "EnterPlanMode", "EnterWorktree",
        "ExitPlanMode", "ExitWorktree", "Glob", "Grep", "KillShell", "LS", "ListMcpResourcesTool", "Monitor", "MultiEdit", "NotebookEdit", "NotebookRead",
        "PushNotification", "Read", "ReadMcpResourceTool", "RemoteTrigger", "SendMessage", "Skill", "SlashCommand", "StructuredOutput", "Task", "TaskCreate",
        "TaskGet", "TaskList", "TaskOutput", "TaskStop", "TaskUpdate", "TodoRead", "TodoWrite", "ToolSearch", "WebFetch", "WebSearch", "Workflow", "Write",
    ]
}

private extension Character {
    var isHexOrDash: Bool { isHexDigit || self == "-" }
}

private extension UInt8 {
    var isASCIILetterOrDigit: Bool { (0x30...0x39).contains(self) || (0x41...0x5A).contains(self) || (0x61...0x7A).contains(self) }
}

/// One thing that happened. Repeats of it are folded into `count`.
public struct LogRecord: Sendable, Equatable {
    public let at: Date
    public let message: LogMessage
    public let values: [LogValue]
    public var count = 1
    public var lastAt: Date

    public init(at: Date = Date(), message: LogMessage, values: [LogValue] = []) {
        self.at = at
        self.message = message
        self.values = values
        lastAt = at
    }

    public var level: LogLevel { message.level }
    public var area: LogArea { message.area }

    public func says(sameAs other: LogRecord) -> Bool {
        message == other.message && values == other.values
    }

    /// What it says, in the language of the interface, without any repeats.
    public var text: String { Self.fill(message.template, values.map(\.shown)) }

    /// Not `String(format:)`: a wrong number of values, say from an older file, must not be able to bring the app down.
    static func fill(_ template: String, _ values: [String]) -> String {
        var result = ""
        var rest = template[...]
        var next = values.makeIterator()
        while let mark = rest.range(of: "%@") {
            result += rest[..<mark.lowerBound]
            result += next.next() ?? "?"
            rest = rest[mark.upperBound...]
        }
        return result + rest
    }
}

/// Where the lines go. The real one writes a file off the main thread, so `write` must return at once.
public protocol LogSink: AnyObject, Sendable {
    func write(_ record: LogRecord)
    func flush()
}

/// The log of what the app does. Any part of it can call `note`, from any thread.
///
/// With nothing installed it does nothing at all, which is the case in tests, snapshots and tools: only the app itself installs a file.
public enum AppLog {
    private static let sinks = OSAllocatedUnfairLock<[any LogSink]>(initialState: [])

    public static func add(_ sink: any LogSink) {
        sinks.withLock { $0.append(sink) }
    }

    public static func remove(_ sink: any LogSink) {
        sinks.withLock { $0.removeAll { $0 === sink } }
    }

    public static var installed: [any LogSink] { sinks.withLock { $0 } }

    public static var isOn: Bool { sinks.withLock { !$0.isEmpty } }

    public static func note(_ message: LogMessage, _ values: LogValue...) {
        let current = installed
        guard !current.isEmpty else { return }
        let record = LogRecord(at: Date(), message: message, values: values)
        for sink in current { sink.write(record) }
    }

    /// Waits until what was noted is written. For quitting.
    public static func flush() {
        for sink in installed { sink.flush() }
    }
}
