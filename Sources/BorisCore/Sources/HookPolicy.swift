import Foundation

/// What `boris-hook` reads before it does anything: sources it must not talk about and sources it must not wait for.
/// It lives in a file next to the socket, because the hook has to decide before it has reached the app.
public struct HookPolicy: Codable, Sendable, Equatable {
    public static let fileName = "source-policy.json"

    public enum Action: Sendable, Equatable {
        /// Reading is off: nothing is sent, and Claude goes on by itself.
        case leave
        /// The app hears about it, and Claude does not wait for anything.
        case tell
        /// The hook stays until there is an answer or the wait is over.
        case ask
    }

    /// Plain strings, so that a file from another version cannot make the rest unreadable.
    private var silent: Set<String>
    private var noAnswers: Set<String>

    public init(silent: Set<SourceID> = [], noAnswers: Set<SourceID> = []) {
        self.silent = Set(silent.map(\.rawValue))
        self.noAnswers = Set(noAnswers.map(\.rawValue))
    }

    /// - Parameter asking: this is a permission request, which would hold Claude until it is answered.
    public func action(for source: SourceID?, asking: Bool) -> Action {
        guard let source else { return asking ? .ask : .tell }
        if silent.contains(source.rawValue) { return .leave }
        return asking && !noAnswers.contains(source.rawValue) ? .ask : .tell
    }

    /// A missing or damaged file forbids nothing: the hook behaves as it does without any of this.
    public static func load(from url: URL) -> HookPolicy {
        guard let data = try? Data(contentsOf: url), let policy = try? JSONDecoder().decode(HookPolicy.self, from: data) else { return HookPolicy() }
        return policy
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}
