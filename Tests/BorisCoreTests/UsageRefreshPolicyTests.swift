import BorisCore
import Foundation
import Testing

@Suite("Когда обновлять лимиты")
struct UsageRefreshPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func due(enabled: Bool = true, awake: Bool = true, sessions: Int = 1, account: ClaudeAccount = .signedIn, fetched: Double? = 20, attempt: Double? = nil) -> Bool {
        UsageRefreshPolicy.isDue(
            now: now,
            enabled: enabled,
            macAwake: awake,
            intervalMinutes: 15,
            liveSessions: sessions,
            account: account,
            fetchedAt: fetched.map { now.addingTimeInterval(-$0 * 60) },
            lastAttempt: attempt.map { now.addingTimeInterval(-$0 * 60) }
        )
    }

    @Test("Устаревшие данные и открытая сессия: пора")
    func isDue() {
        #expect(due())
        #expect(due(fetched: nil))
    }

    @Test("Выключено настройкой: никогда")
    func disabled() {
        #expect(!due(enabled: false))
    }

    @Test("Mac спит с закрытой крышкой и проснулся сам на пару секунд: не запускается, даже когда пора")
    func darkWake() {
        #expect(!due(awake: false))
        #expect(!due(awake: false, fetched: nil))
    }

    @Test("Без открытых сессий ничего не запускается")
    func noSessions() {
        #expect(!due(sessions: 0))
    }

    @Test("Без плана обновлять нечего: Claude Code не запускается зря")
    func noPlan() {
        #expect(!due(account: .apiKey))
        #expect(!due(account: .gateway))
        #expect(due(account: .unknown))
    }

    @Test("Данные ещё свежие")
    func fresh() {
        #expect(!due(fetched: 10))
    }

    @Test("Неудачная попытка не повторяется на каждом проходе")
    func failedAttempt() {
        #expect(!due(attempt: 3))
        #expect(due(attempt: 16))
    }

    @Test("Интервал по умолчанию есть среди вариантов")
    func intervals() {
        #expect(UsageRefreshPolicy.intervals.contains(15))
    }
}
