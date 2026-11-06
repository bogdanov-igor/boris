import BorisCore
import Foundation

/// How the hooks stand on a remote machine, as its helper sees them.
public enum RemoteHookState: String, Sendable, Equatable {
    case notInstalled, installed, outdated, disabledInSettings, disabledByPolicy, unreadable
}

/// What the helper says about itself every few seconds.
public struct RemoteVitals: Sendable, Equatable {
    /// The forwarded socket is there, so live events and requests can reach this Mac.
    public var socket: Bool
    public var claudeFound: Bool
    public var hooks: RemoteHookState?

    public init(socket: Bool, claudeFound: Bool, hooks: RemoteHookState?) {
        self.socket = socket
        self.claudeFound = claudeFound
        self.hooks = hooks
    }
}

/// One line of a session list from a remote machine. Words the helper could not vouch for never get this far.
public struct RemoteSessionReport: Sendable, Equatable {
    public var id: String
    public var status: String?
    public var waitingFor: String?
    public var cwd: String?
    public var version: String?
    public var startedAt: Date?
    public var updatedAt: Date?
    /// Its process vanished and left its file behind.
    public var gone: Bool

    public init(id: String, status: String? = nil, waitingFor: String? = nil, cwd: String? = nil, version: String? = nil, startedAt: Date? = nil, updatedAt: Date? = nil, gone: Bool = false) {
        self.id = id
        self.status = status
        self.waitingFor = waitingFor
        self.cwd = cwd
        self.version = version
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.gone = gone
    }
}

/// What one transcript spent in a quarter of an hour with one model. Numbers and ids, and the folder it is about.
public struct RemoteSpendRow: Codable, Sendable, Equatable {
    public var session: String
    public var agent: String?
    public var run: String?
    public var cwd: String?
    /// The start of the quarter of an hour, in seconds. A time zone is a matter for this Mac.
    public var time: Int
    public var model: String?
    public var usage: TokenUsage

    public init(session: String, agent: String? = nil, run: String? = nil, cwd: String? = nil, time: Int, model: String? = nil, usage: TokenUsage) {
        self.session = session
        self.agent = agent
        self.run = run
        self.cwd = cwd
        self.time = time
        self.model = model
        self.usage = usage
    }
}

/// One line from the helper. This is the second gate after the helper's own: a machine can run anything under that name,
/// so every field is checked here too, whatever else comes along is dropped, and no text is kept.
public enum RemoteMessage: Sendable, Equatable {
    case hello
    case info(home: String, vitals: RemoteVitals)
    case alive(RemoteVitals)
    case sessions([RemoteSessionReport])
    case numbers(full: Bool, rows: [RemoteSpendRow])

    /// Nil for anything it does not recognise, which a newer helper is allowed to send.
    public init?(line: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], let kind = object["k"] as? String else { return nil }
        switch kind {
        case "hello":
            self = .hello
        case "alive":
            self = .alive(Self.vitals(object))
        case "info":
            guard let home = RemoteField.path(object["home"]) else { return nil }
            self = .info(home: home, vitals: Self.vitals(object))
        case "sessions":
            guard let list = object["list"] as? [[String: Any]] else { return nil }
            self = .sessions(list.compactMap(Self.report))
        case "numbers":
            guard let rows = object["rows"] as? [[Any]] else { return nil }
            self = .numbers(full: object["full"] as? Bool == true, rows: rows.compactMap(Self.row))
        default:
            return nil
        }
    }

    private static func vitals(_ object: [String: Any]) -> RemoteVitals {
        RemoteVitals(
            socket: object["socket"] as? Bool == true,
            claudeFound: object["claude"] as? Bool == true,
            hooks: (object["hooks"] as? String).flatMap(RemoteHookState.init(rawValue:))
        )
    }

    private static func report(_ object: [String: Any]) -> RemoteSessionReport? {
        guard let id = RemoteField.id(object["id"]) else { return nil }
        return RemoteSessionReport(
            id: id,
            status: RemoteField.status(object["status"]),
            waitingFor: RemoteField.waiting(object["waiting"]),
            cwd: RemoteField.path(object["cwd"]),
            version: RemoteField.word(object["version"]),
            startedAt: RemoteField.milliseconds(object["started"]),
            updatedAt: RemoteField.milliseconds(object["updated"]),
            gone: object["gone"] as? Bool == true
        )
    }

    private static func row(_ fields: [Any]) -> RemoteSpendRow? {
        guard fields.count == 10, let session = RemoteField.id(fields[0]), let time = RemoteField.count(fields[4]) else { return nil }
        guard let input = RemoteField.count(fields[6]), let output = RemoteField.count(fields[7]), let cacheRead = RemoteField.count(fields[8]), let cacheWrite = RemoteField.count(fields[9]) else { return nil }
        return RemoteSpendRow(
            session: session,
            agent: RemoteField.id(fields[1]),
            run: RemoteField.id(fields[2]),
            cwd: RemoteField.path(fields[3]),
            time: time,
            model: RemoteField.model(fields[5]),
            usage: TokenUsage(input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite)
        )
    }
}

/// The result of one action on a machine's hooks.
public struct RemoteHookResult: Sendable, Equatable {
    public var ok: Bool
    public var lines: [String]
    public var reformats: Bool

    public init(ok: Bool, lines: [String] = [], reformats: Bool = false) {
        self.ok = ok
        self.lines = lines
        self.reformats = reformats
    }

    public init?(line: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], object["k"] as? String == "result", let ok = object["ok"] as? Bool else { return nil }
        self.init(ok: ok, lines: (object["lines"] as? [String] ?? []).prefix(400).map { String($0.prefix(2000)) }, reformats: object["reformats"] as? Bool == true)
    }
}

/// Which words from a remote machine are allowed to mean anything here.
enum RemoteField {
    private static let idCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_.:-"))
    private static let modelCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_.:/@[]-"))
    private static let wordCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_.+-"))
    private static let waitingWords: Set<String> = ["input needed", "dialog open", "permission prompt"]
    private static let statuses: Set<String> = ["busy", "idle", "waiting"]
    /// More than anyone can spend, and small enough for any sum of these to stay far from overflowing.
    private static let largest = 1 << 50

    private static func allowed(_ text: String, _ set: CharacterSet) -> Bool {
        text.unicodeScalars.allSatisfy { $0.isASCII && set.contains($0) }
    }

    static func id(_ value: Any?) -> String? {
        guard let text = value as? String, (1...128).contains(text.utf8.count), allowed(text, idCharacters) else { return nil }
        return text
    }

    static func model(_ value: Any?) -> String? {
        guard let text = value as? String, (1...128).contains(text.utf8.count), allowed(text, modelCharacters) else { return nil }
        return text
    }

    static func word(_ value: Any?) -> String? {
        guard let text = value as? String, (1...64).contains(text.utf8.count), allowed(text, wordCharacters) else { return nil }
        return text
    }

    static func path(_ value: Any?) -> String? {
        guard let text = value as? String, text.hasPrefix("/"), text.utf8.count <= 4096, !text.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { return nil }
        return text
    }

    static func status(_ value: Any?) -> String? {
        (value as? String).flatMap { statuses.contains($0) ? $0 : nil }
    }

    static func waiting(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        if waitingWords.contains(text) { return text }
        guard text.hasPrefix("approve "), let tool = id(String(text.dropFirst("approve ".count))), !tool.contains(":") else { return nil }
        return "approve \(tool)"
    }

    /// A whole number and nothing that only looks like one: a Bool also comes as an NSNumber.
    static func count(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue >= 0, number.doubleValue < Double(largest),
              number.doubleValue == number.doubleValue.rounded() else { return nil }
        return number.intValue
    }

    static func milliseconds(_ value: Any?) -> Date? {
        count(value).map { Date(timeIntervalSince1970: Double($0) / 1000) }
    }
}
