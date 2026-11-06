import BorisCore
import Foundation

/// Why a message did not go. The words of the error itself are dropped on purpose: they can hold the address with the token.
public enum TelegramProblem: String, Sendable, Equatable {
    case noConnection, badToken, badRecipient, botCannotWrite, tooOften, other
}

/// Sends a request and gives back the answer. Tests put a fake here, so they never reach the network.
public protocol TelegramTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (status: Int, body: Data)
}

public struct URLSessionTelegramTransport: TelegramTransport {
    private let session: URLSession

    /// Ephemeral: the address holds the token, and it must not end up in a cache on disk.
    public init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    public func send(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        let (data, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}

/// What a request to the Telegram Bot API looks like and what its answers mean.
public enum TelegramAPI {
    public static func cleanToken(_ token: String) -> String? {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.range(of: #"^[0-9]+:[A-Za-z0-9_-]+$"#, options: .regularExpression) == nil ? nil : token
    }

    /// A number, or the `@name` of a channel.
    public static func cleanChat(_ chat: String) -> String? {
        let chat = chat.trimmingCharacters(in: .whitespacesAndNewlines)
        return chat.range(of: #"^(-?[0-9]+|@[A-Za-z0-9_]+)$"#, options: .regularExpression) == nil ? nil : chat
    }

    /// The name of the project goes in bold by position, so nothing in the text can be read as markup.
    public static func request(_ line: TelegramLine, token: String, chat: String) throws -> URLRequest {
        guard let url = URL(string: "https://api.telegram.org/bot\(token)/sendMessage") else { throw URLError(.badURL) }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "chat_id": chat,
            "text": line.full,
            "entities": [["type": "bold", "offset": 0, "length": line.subject.utf16.count]],
            "link_preview_options": ["is_disabled": true],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Nil when Telegram took the message.
    public static func problem(status: Int) -> TelegramProblem? {
        switch status {
        case 200...299: return nil
        case 401, 404: return .badToken
        case 400: return .badRecipient
        case 403: return .botCannotWrite
        case 429: return .tooOften
        default: return .other
        }
    }

    public static func problem(error: Error) -> TelegramProblem {
        switch (error as? URLError)?.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .timedOut, .internationalRoamingOff, .dataNotAllowed, .secureConnectionFailed:
            return .noConnection
        default:
            return .other
        }
    }
}

/// Sends messages one after another, away from the main thread. Whatever happens to them, nobody waits for it:
/// the result only goes to `onResult`, for the settings to show.
public actor TelegramChannel {
    /// With no connection for a long time, only the latest news is worth sending.
    static let maxQueued = 20

    private let transport: any TelegramTransport
    private let secret: any SecretStore
    private let onResult: @Sendable (TelegramProblem?) -> Void
    private var token: String?
    private var queue: [(line: TelegramLine, chat: String)] = []
    private var sending = false

    var queuedCount: Int { queue.count }

    public init(transport: any TelegramTransport, secret: any SecretStore, onResult: @escaping @Sendable (TelegramProblem?) -> Void) {
        self.transport = transport
        self.secret = secret
        self.onResult = onResult
    }

    public func send(_ line: TelegramLine, chat: String) {
        queue.append((line, chat))
        if queue.count > Self.maxQueued { queue.removeFirst() }
        guard !sending else { return }
        sending = true
        Task { await drain() }
    }

    private func drain() async {
        while !queue.isEmpty {
            let next = queue.removeFirst()
            let problem = await deliver(next.line, token: savedToken(), chat: next.chat)
            note(problem, about: next.line)
            onResult(problem)
        }
        sending = false
    }

    /// Asked for only when there is something to send: reading the Keychain can ask the person for permission.
    private func savedToken() -> String? {
        if token == nil { token = secret.read() }
        return token
    }

    private func deliver(_ line: TelegramLine, token: String?, chat: String) async -> TelegramProblem? {
        guard let token else { return .badToken }
        do {
            let request = try TelegramAPI.request(line, token: token, chat: chat)
            let (status, _) = try await transport.send(request)
            return TelegramAPI.problem(status: status)
        } catch {
            return TelegramAPI.problem(error: error)
        }
    }

    /// A new bot is kept only after Telegram has taken a test message from it.
    public func connect(token rawToken: String, chat: String, test: TelegramLine) async -> TelegramProblem? {
        guard let clean = TelegramAPI.cleanToken(rawToken) else {
            AppLog.note(.telegramConnectFailed, .word(.badToken))
            return .badToken
        }
        guard let cleanChat = TelegramAPI.cleanChat(chat) else {
            AppLog.note(.telegramConnectFailed, .word(.badRecipient))
            return .badRecipient
        }
        if let problem = await deliver(test, token: clean, chat: cleanChat) {
            AppLog.note(.telegramConnectFailed, .word(problem.logWord))
            return problem
        }
        guard secret.write(clean) else {
            AppLog.note(.keychainFailed)
            return .other
        }
        token = clean
        AppLog.note(.telegramConnected)
        return nil
    }

    public func test(_ line: TelegramLine, chat: String) async -> TelegramProblem? {
        let problem = await deliver(line, token: savedToken(), chat: chat)
        note(problem, about: line)
        return problem
    }

    private func note(_ problem: TelegramProblem?, about line: TelegramLine) {
        if let problem {
            AppLog.note(.telegramFailed, line.about, .word(problem.logWord))
        } else {
            AppLog.note(.telegramSent, line.about)
        }
    }

    public func disconnect() {
        queue = []
        token = nil
        secret.delete()
        AppLog.note(.telegramDisconnected)
    }
}
