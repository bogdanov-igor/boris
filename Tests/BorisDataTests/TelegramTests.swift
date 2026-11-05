import BorisCore
import Foundation
import Testing
@testable import BorisData

private let token = "123456:ABC-def_789"
private let line = TelegramLine(subject: "shop-api", text: "waiting for permission")

/// Hands out prepared answers and writes down what was asked. Never reaches the network.
private final class FakeTransport: TelegramTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [Result<Int, Error>]
    private var sent: [URLRequest] = []

    init(_ answers: Result<Int, Error>...) {
        self.answers = answers
    }

    var requests: [URLRequest] { lock.withLock { sent } }

    func send(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        let answer: Result<Int, Error>? = lock.withLock {
            sent.append(request)
            return answers.isEmpty ? nil : answers.removeFirst()
        }
        return (try answer?.get() ?? 200, Data())
    }
}

/// Never answers, as a network that takes forever.
private struct StuckTransport: TelegramTransport {
    func send(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        try await Task.sleep(for: .seconds(3600))
        return (200, Data())
    }
}

private final class FakeSecret: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    private var reads = 0
    private let saves: Bool

    init(_ value: String? = nil, saves: Bool = true) {
        self.value = value
        self.saves = saves
    }

    var current: String? { lock.withLock { value } }
    var readCount: Int { lock.withLock { reads } }

    func read() -> String? {
        lock.withLock {
            reads += 1
            return value
        }
    }

    func write(_ value: String) -> Bool {
        guard saves else { return false }
        lock.withLock { self.value = value }
        return true
    }

    func delete() {
        lock.withLock { value = nil }
    }
}

/// Keeps every result in order, and lets a test wait for a number of them.
private actor Results {
    private(set) var all: [TelegramProblem?] = []

    func add(_ problem: TelegramProblem?) {
        all.append(problem)
    }

    func wait(for count: Int) async {
        for _ in 0..<2000 where all.count < count {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

private func channel(_ transport: any TelegramTransport, _ secret: any SecretStore, results: Results = Results()) -> TelegramChannel {
    TelegramChannel(transport: transport, secret: secret) { problem in
        Task { await results.add(problem) }
    }
}

private func body(_ request: URLRequest) throws -> [String: Any] {
    let data = try #require(request.httpBody)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Suite("Telegram")
struct TelegramTests {
    @Test("Запрос как у Bot API: токен только в адресе, имя проекта жирным по позиции") func requestShape() throws {
        let cyrillic = TelegramLine(subject: "проект 🦭", text: "готово")
        let request = try TelegramAPI.request(cyrillic, token: token, chat: "777")
        #expect(request.url?.absoluteString == "https://api.telegram.org/bot\(token)/sendMessage")
        #expect(request.httpMethod == "POST")
        let json = try body(request)
        #expect(json["chat_id"] as? String == "777")
        #expect(json["text"] as? String == "проект 🦭 · готово")
        #expect(json["parse_mode"] == nil)
        let entity = try #require((json["entities"] as? [[String: Any]])?.first)
        #expect(entity["type"] as? String == "bold")
        #expect(entity["offset"] as? Int == 0)
        // Telegram counts in UTF-16, and the seal takes two.
        #expect(entity["length"] as? Int == 9)
        #expect(!String(decoding: try #require(request.httpBody), as: UTF8.self).contains(token))
    }

    @Test("Ответы Telegram становятся понятными причинами", arguments: [
        (200, nil), (401, .badToken), (404, .badToken), (400, .badRecipient), (403, .botCannotWrite), (429, .tooOften), (500, .other),
    ] as [(Int, TelegramProblem?)])
    func statuses(status: Int, problem: TelegramProblem?) {
        #expect(TelegramAPI.problem(status: status) == problem)
    }

    @Test("Нет сети: это нет связи, что бы именно ни случилось", arguments: [
        URLError.Code.notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .timedOut,
    ])
    func offlineErrors(code: URLError.Code) {
        #expect(TelegramAPI.problem(error: URLError(code)) == .noConnection)
    }

    @Test("Токен и получатель проверяются до отправки и очищаются от пробелов") func validation() {
        #expect(TelegramAPI.cleanToken(" \(token)\n") == token)
        #expect(TelegramAPI.cleanToken("no-colon") == nil)
        #expect(TelegramAPI.cleanToken("1:a/../../evil") == nil)
        #expect(TelegramAPI.cleanChat(" 777 ") == "777")
        #expect(TelegramAPI.cleanChat("-100200") == "-100200")
        #expect(TelegramAPI.cleanChat("@channel_name") == "@channel_name")
        #expect(TelegramAPI.cleanChat("hello world") == nil)
    }

    @Test("Подключение: проверочное сообщение ушло, токен сохранён") func connectOK() async throws {
        let transport = FakeTransport()
        let secret = FakeSecret()
        let problem = await channel(transport, secret).connect(token: " \(token) ", chat: "777", test: NotificationWords.telegramTest)
        #expect(problem == nil)
        #expect(secret.current == token)
        #expect(transport.requests.count == 1)
        #expect(try body(transport.requests[0])["text"] as? String == "Boris · the bot is connected, this is a test")
    }

    @Test("Подключение не удалось: причина видна, а токен не сохранён", arguments: [
        (Result<Int, Error>.success(401), TelegramProblem.badToken),
        (.success(403), .botCannotWrite),
        (.failure(URLError(.notConnectedToInternet)), .noConnection),
    ] as [(Result<Int, Error>, TelegramProblem)])
    func connectFails(answer: Result<Int, Error>, expected: TelegramProblem) async {
        let secret = FakeSecret()
        let problem = await channel(FakeTransport(answer), secret).connect(token: token, chat: "777", test: line)
        #expect(problem == expected)
        #expect(secret.current == nil)
    }

    @Test("Неверный токен не доходит до сети") func badTokenStaysHere() async {
        let transport = FakeTransport()
        let problem = await channel(transport, FakeSecret()).connect(token: "not a token", chat: "777", test: line)
        #expect(problem == .badToken)
        #expect(transport.requests.isEmpty)
    }

    @Test("Связка ключей не дала сохранить: бот не считается подключённым") func keychainRefuses() async {
        let problem = await channel(FakeTransport(), FakeSecret(saves: false)).connect(token: token, chat: "777", test: line)
        #expect(problem == .other)
    }

    @Test("Сообщения уходят по очереди и токен читается один раз") func sendsInOrder() async throws {
        let transport = FakeTransport()
        let secret = FakeSecret(token)
        let results = Results()
        let sender = channel(transport, secret, results: results)
        for number in 1...3 {
            await sender.send(TelegramLine(subject: "p\(number)", text: "x"), chat: "777")
        }
        await results.wait(for: 3)
        #expect(await results.all.count == 3)
        #expect(try transport.requests.map { try body($0)["text"] as? String } == ["p1 · x", "p2 · x", "p3 · x"])
        #expect(secret.readCount == 1)
    }

    @Test("Нет интернета: статус ошибки появляется, а следующий успех его снимает") func offlineThenBack() async {
        let results = Results()
        let sender = channel(FakeTransport(.failure(URLError(.notConnectedToInternet)), .success(200)), FakeSecret(token), results: results)
        await sender.send(line, chat: "777")
        await results.wait(for: 1)
        await sender.send(line, chat: "777")
        await results.wait(for: 2)
        #expect(await results.all == [.noConnection, nil])
    }

    @Test("Сеть зависла: Boris не ждёт, а очередь не растёт без конца") func stuckNetwork() async {
        let sender = channel(StuckTransport(), FakeSecret(token))
        let started = ContinuousClock.now
        for _ in 0..<(TelegramChannel.maxQueued * 3) {
            await sender.send(line, chat: "777")
        }
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(await sender.queuedCount <= TelegramChannel.maxQueued)
    }

    @Test("Токена нет: сообщение не уходит, причина видна") func tokenMissing() async {
        let transport = FakeTransport()
        let results = Results()
        let sender = channel(transport, FakeSecret(), results: results)
        await sender.send(line, chat: "777")
        await results.wait(for: 1)
        #expect(await results.all == [.badToken])
        #expect(transport.requests.isEmpty)
    }

    @Test("Отключение забывает токен") func disconnect() async {
        let transport = FakeTransport()
        let secret = FakeSecret()
        let sender = channel(transport, secret)
        _ = await sender.connect(token: token, chat: "777", test: line)
        await sender.disconnect()
        #expect(secret.current == nil)
        #expect(await sender.test(line, chat: "777") == .badToken)
        #expect(transport.requests.count == 1)
    }

    /// The real transport with its traffic turned around, so no byte leaves this Mac.
    @Test("Настоящая отправка без сети: ошибка становится статусом, токена в нём нет") func realTransportOffline() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineProtocol.self]
        let results = Results()
        let sender = channel(URLSessionTelegramTransport(configuration: configuration), FakeSecret(token), results: results)
        await sender.send(line, chat: "777")
        await results.wait(for: 1)
        #expect(await results.all == [.noConnection])
    }

    @Test("Настоящая отправка: то, что ушло, и то, что вернулось") func realTransportAnswers() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AnsweringProtocol.self]
        let transport = URLSessionTelegramTransport(configuration: configuration)
        let answer = try await transport.send(TelegramAPI.request(line, token: token, chat: "777"))
        #expect(answer.status == 403)
        #expect(TelegramAPI.problem(status: answer.status) == .botCannotWrite)
    }
}

private final class OfflineProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
}

private final class AnsweringProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: nil) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// Real processes, real files and two engines one after the other, as a quit and a launch are.
@Suite("Перезапуск Boris")
struct NotificationRestartTests {
    private func procStart(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter.string(from: date)
    }

    private func startedProcess() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        return process
    }

    private func engine(_ folder: TempFolder, memory: DetectorMemory) -> WorkEngine {
        WorkEngine(paths: ClaudePaths(root: folder.url), detector: memory, others: { [] }, handler: { _ in })
    }

    @Test("Две сессии прервались, пока Boris был закрыт: при запуске приходит одна сводка") func twoSessionsDie() async throws {
        let folder = TempFolder()
        let processes = try [startedProcess(), startedProcess()]
        defer { processes.filter(\.isRunning).forEach { $0.terminate() } }
        for (process, name) in zip(processes, ["boris", "deploy-tools"]) {
            let pid = process.processIdentifier
            let start = try #require(ProcessInspector.startTime(pid: pid))
            let updated = Int(Date().timeIntervalSince1970 * 1000)
            folder.write("sessions/\(pid).json", #"{"sessionId":"\#(name)-id","pid":\#(pid),"procStart":"\#(procStart(start))","cwd":"/x/\#(name)","entrypoint":"cli","status":"busy","statusUpdatedAt":\#(updated)}"#)
        }

        // The first life of Boris sees them at work and writes down what it knows.
        let first = await engine(folder, memory: DetectorMemory()).scanOnce()
        #expect(first.events.isEmpty)
        #expect(first.detectorMemory.liveSessions == ["boris-id", "deploy-tools-id"])
        let saved = try JSONEncoder().encode(first.detectorMemory)

        // While it is closed, the sessions die.
        for process in processes {
            process.interrupt()
            process.waitUntilExit()
        }

        // The second life reads the state file and takes a first look.
        let memory = try JSONDecoder().decode(DetectorMemory.self, from: saved)
        let second = engine(folder, memory: memory)
        let output = await second.scanOnce()
        #expect(output.events.count == 2)
        #expect(output.events.allSatisfy { $0.kind == .interrupted && $0.whileAway })

        var router = NotificationRouter()
        let on = Reaction(banner: true, sound: true, mood: .none)
        let delivered = router.route(output.events.map { NotificationRouter.Item(event: $0, reaction: on, telegram: true) }, now: output.at)
        let banners = delivered.compactMap { delivery -> MacBanner? in
            if case .banner(let banner) = delivery { return banner }
            return nil
        }
        #expect(banners.count == 1)
        #expect(banners[0].title == "While Boris was closed")
        #expect(banners[0].body.hasPrefix("2 sessions were interrupted"))
        #expect(banners[0].body.contains("boris"))
        #expect(banners[0].body.contains("deploy-tools"))

        // And the third look has nothing more to say.
        #expect(await second.scanOnce().events.isEmpty)
    }
}
