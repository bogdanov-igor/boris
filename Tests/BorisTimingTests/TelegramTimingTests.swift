import BorisCore
import Foundation
import Testing
@testable import BorisData

/// Never answers, as a network that takes forever.
private struct StuckTransport: TelegramTransport {
    func send(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        try await Task.sleep(for: .seconds(3600))
        return (200, Data())
    }
}

/// Holds a made-up token in memory. The Keychain is never touched.
private final class FakeSecret: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    init(_ value: String?) {
        self.value = value
    }

    func read() -> String? { lock.withLock { value } }

    func write(_ value: String) -> Bool {
        lock.withLock { self.value = value }
        return true
    }

    func delete() {
        lock.withLock { value = nil }
    }
}

extension TimingTests {
    @Suite("Telegram: сроки")
    struct TelegramTimingTests {
        @Test("Сеть зависла: Boris не ждёт, а очередь не растёт без конца") func stuckNetwork() async {
            let sender = TelegramChannel(transport: StuckTransport(), secret: FakeSecret("123456:ABC-def_789")) { _ in }
            let line = TelegramLine(subject: "shop-api", text: "waiting for permission")
            let started = ContinuousClock.now
            for _ in 0..<(TelegramChannel.maxQueued * 3) {
                await sender.send(line, chat: "777")
            }
            #expect(ContinuousClock.now - started < .seconds(5))
            #expect(await sender.queuedCount <= TelegramChannel.maxQueued)
        }
    }
}
