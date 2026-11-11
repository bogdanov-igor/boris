import Foundation

/// What a person can turn off in one move.
public enum SourceProduct: String, Codable, CaseIterable, Sendable, Identifiable {
    case claudeCode, cowork, chat

    public var id: String { rawValue }

    public var sources: [SourceID] { SourceID.allCases.filter { $0.product == self } }

    public var title: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .cowork: return "Cowork"
        case .chat: return L("Claude chat")
        }
    }
}

/// A product together with the place it runs in, as one row of the settings.
public enum SourceID: String, Codable, CaseIterable, Sendable, Identifiable {
    case terminal, vsCode, cursor, claudeDesktop, remote, program, cowork, chat

    public var id: String { rawValue }

    public var product: SourceProduct {
        switch self {
        case .cowork: return .cowork
        case .chat: return .chat
        default: return .claudeCode
        }
    }

    /// Nil when nothing says where the work runs. Such work is shown until the person's choice can be applied to it.
    public init?(_ environment: WorkEnvironment?) {
        switch environment {
        // Claude Code started from inside another one is still Claude Code on the command line.
        case .terminal, .insideClaude: self = .terminal
        case .vsCode: self = .vsCode
        case .cursor: self = .cursor
        case .claudeDesktop: self = .claudeDesktop
        case .remote: self = .remote
        case .program: self = .program
        case .cowork: self = .cowork
        case .chat: self = .chat
        case nil: return nil
        }
    }

    public init?(entrypoint: String?) {
        self.init(WorkEnvironment(entrypoint: entrypoint, unlisted: false))
    }

    /// There is nothing to answer in the chat, and Cowork takes its answers in Claude Desktop.
    public var canAnswer: Bool { self != .cowork && self != .chat }

    public var title: String {
        switch self {
        case .terminal: return L("Terminal")
        case .vsCode: return "VS Code"
        case .cursor: return "Cursor"
        case .claudeDesktop: return L("Code tab in Claude Desktop")
        case .remote: return L("Remote machines")
        case .program: return L("Agent SDK programs")
        case .cowork: return "Cowork"
        case .chat: return L("Claude chat")
        }
    }
}

/// The four switches of one source.
public struct SourceSwitches: Codable, Sendable, Equatable {
    public var read = true
    public var notify = true
    public var answer = true
    public var capture = true

    public init(read: Bool = true, notify: Bool = true, answer: Bool = true, capture: Bool = true) {
        self.read = read
        self.notify = notify
        self.answer = answer
        self.capture = capture
    }

    /// A field missing or not understood takes its standard value, so one of them cannot cost the person the others.
    public init(from decoder: Decoder) throws {
        let saved = try decoder.container(keyedBy: CodingKeys.self)
        read = (try? saved.decodeIfPresent(Bool.self, forKey: .read)) ?? true
        notify = (try? saved.decodeIfPresent(Bool.self, forKey: .notify)) ?? true
        answer = (try? saved.decodeIfPresent(Bool.self, forKey: .answer)) ?? true
        capture = (try? saved.decodeIfPresent(Bool.self, forKey: .capture)) ?? true
    }
}

/// What the person chose about each source. Turning a product off leaves the choices of its sources in place, so turning it on brings them back.
public struct SourceSettings: Codable, Sendable, Equatable {
    /// Plain strings, so that what another version saved cannot make the whole choice unreadable.
    private var productsOff: Set<String> = [SourceProduct.chat.rawValue]
    private var switches: [String: SourceSwitches] = [:]

    public init() {}

    public init(from decoder: Decoder) throws {
        let saved = try decoder.container(keyedBy: CodingKeys.self)
        productsOff = (try? saved.decodeIfPresent(Set<String>.self, forKey: .productsOff)) ?? productsOff
        switches = (try? saved.decodeIfPresent([String: SourceSwitches].self, forKey: .switches)) ?? switches
    }

    public subscript(source: SourceID) -> SourceSwitches {
        get { switches[source.rawValue] ?? SourceSwitches() }
        set { switches[source.rawValue] = newValue }
    }

    public func isOn(_ product: SourceProduct) -> Bool {
        !productsOff.contains(product.rawValue)
    }

    public mutating func set(_ product: SourceProduct, on: Bool) {
        if on {
            productsOff.remove(product.rawValue)
        } else {
            productsOff.insert(product.rawValue)
        }
    }

    /// The chat has one switch, the person's consent, and no row of its own. Whatever an older version kept about that row goes with it,
    /// so that a switch shown as on always means the chat is read and notified about.
    public mutating func setChat(on: Bool) {
        set(.chat, on: on)
        switches[SourceID.chat.rawValue] = nil
    }

    public func reads(_ source: SourceID) -> Bool {
        isOn(source.product) && self[source].read
    }

    /// Nil is work that says nothing about where it runs.
    public func notifies(_ source: SourceID?) -> Bool {
        guard let source else { return true }
        return reads(source) && self[source].notify
    }

    public func answers(_ source: SourceID?) -> Bool {
        guard let source else { return true }
        return source.canAnswer && reads(source) && self[source].answer
    }

    /// Whether the window of a source that has data may be captured. A source that is not read has no data on any window.
    public func forbidsCapture(_ source: SourceID) -> Bool {
        reads(source) && !self[source].capture
    }

    public var readingOff: Set<SourceID> {
        Set(SourceID.allCases.filter { !reads($0) })
    }

    public var captureForbidden: Set<SourceID> {
        Set(SourceID.allCases.filter(forbidsCapture))
    }

    /// Sources whose absence makes the totals smaller. The chat never has numbers to count, so it stays out of this, on or off.
    public var missingFromTotals: [SourceID] {
        SourceID.allCases.filter { $0 != .chat && !reads($0) }
    }

    /// Nothing at all is being read.
    public var allOff: Bool {
        SourceID.allCases.allSatisfy { !reads($0) }
    }

    public var hookPolicy: HookPolicy {
        HookPolicy(
            silent: readingOff,
            noAnswers: Set(SourceID.allCases.filter { reads($0) && !answers($0) })
        )
    }
}

/// How a window relates to the capture switches. A window with data of several sources goes by the strictest of them.
public enum CaptureRule {
    /// - Parameters:
    ///   - shown: the sources whose data the window holds now.
    ///   - unknown: it also holds work nothing says the source of, which may be a forbidden one.
    public static func hides(shown: Set<SourceID>, unknown: Bool = false, settings: SourceSettings) -> Bool {
        let forbidden = settings.captureForbidden
        guard !forbidden.isEmpty else { return false }
        return unknown || !forbidden.isDisjoint(with: shown)
    }
}

/// How the settings word a list of sources that are off.
public enum SourceWords {
    public static func names(_ sources: [SourceID]) -> String {
        sources.map(\.title).joined(separator: ", ")
    }

    /// Nil when everything counts.
    public static func incompleteNote(_ settings: SourceSettings) -> String? {
        let missing = settings.missingFromTotals
        guard !missing.isEmpty else { return nil }
        return L("Not all sources are counted. Off in Sources: %@.", names(missing))
    }
}
