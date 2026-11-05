import BorisCore
import Foundation
import Testing

@Suite("Подписи оценки")
struct EstimateWordingTests {
    private let ru = Locale(identifier: "ru")
    private let en = Locale(identifier: "en")

    private func estimate(tokens: TokenUsage, model: String?) -> SpendEstimate {
        let record = TokenRecord(sessionId: "s", day: "2026-11-05", model: model, usage: tokens)
        return TokenBook(records: [record], now: Date(timeIntervalSince1970: 1_793_880_000), timeZone: TimeZone(identifier: "UTC") ?? .current).report(.all).estimate
    }

    @Test("Сумма всегда со знаком приблизительности")
    func alwaysMarked() {
        let known = estimate(tokens: TokenUsage(input: 1_000_000), model: "claude-opus-5-5")
        #expect(UsageFormat.estimate(known, locale: en) == "≈ $4")
        #expect(UsageFormat.estimate(known, locale: ru).hasPrefix("≈ 4"))
        #expect(UsageFormat.estimate(SpendEstimate(), locale: en) == "≈ $0")
    }

    @Test("Подписчику оценка не подаётся как расход", arguments: [ClaudeAccount.signedIn, .unknown])
    func subscriberIsNotCharged(account: ClaudeAccount) {
        let note = UsageFormat.estimateNote(account: account)
        #expect(note.contains("would cost"))
        #expect(note.contains("not a charge"))
    }

    @Test("По API-ключу и через шлюз оценка остаётся приблизительной, но списанием не отрицается", arguments: [ClaudeAccount.apiKey, .gateway])
    func paidByTokens(account: ClaudeAccount) {
        let note = UsageFormat.estimateNote(account: account)
        #expect(note.contains("approximate"))
        #expect(!note.contains("not a charge"))
    }

    @Test("Токены без цены не считаются бесплатными")
    func unknownIsNotZero() {
        let unknown = estimate(tokens: TokenUsage(input: 500), model: "some-gateway-model")
        #expect(!unknown.isKnown)
        #expect(unknown.unpricedTokens == 500)
        #expect(UsageFormat.estimate(unknown, locale: en) == "no data")
    }

    @Test("Совсем маленькая сумма не показывается нулём")
    func tiny() {
        let tiny = estimate(tokens: TokenUsage(input: 1), model: "claude-haiku-5-5")
        #expect(UsageFormat.estimate(tiny, locale: en) == "≈ $0.01")
    }

    @Test("Пока логи не прочитаны, токены сегодня неизвестны, а настоящий ноль остаётся нулём")
    func todayIsNotZeroUntilRead() {
        #expect(UsageFormat.total(nil) == "no data")
        #expect(UsageFormat.total(TokenUsage()) == "0")
        #expect(UsageFormat.total(TokenUsage(input: 1500)) == WorkFormat.tokens(1500))
    }

    @Test("Деньги в валюте аккаунта, а ноль остаётся нулём")
    func money() {
        #expect(UsageFormat.money(12.4, locale: en) == "$12.40")
        #expect(UsageFormat.money(50, locale: en) == "$50")
        #expect(UsageFormat.money(0, locale: en) == "$0")
        #expect(UsageFormat.money(12.4, currency: "EUR", locale: en) == "€12.40")
        #expect(UsageFormat.money(12.4, locale: ru).hasPrefix("12,40"))
        #expect(UsageFormat.money(12.4, locale: ru).hasSuffix("$"))
    }
}

@Suite("Что показывать для какого аккаунта")
struct UsageCardsTests {
    private let week = UsageWindow(id: "seven_day", kind: .week, percent: 34)
    private let extra = UsageWindow(id: "extra_usage", kind: .extraSpend, percent: 25, usedDollars: 12.4, limitDollars: 50)

    @Test("Личный план: окна и доплаты")
    func personal() {
        let usage = UsageSnapshot(windows: [week, extra], extra: .on(used: 12.4, limit: 50, currency: "USD"))
        #expect(UsageCards.limits(usage: usage, account: .signedIn) == .windows([week]))
        #expect(UsageCards.extra(usage: usage, account: .signedIn) == .spent(used: 12.4, limit: 50, currency: "USD"))
    }

    @Test("Team или Enterprise без лимитов: «нет данных», а не пустой блок")
    func team() {
        let usage = UsageSnapshot(windows: [])
        #expect(UsageCards.limits(usage: usage, account: .signedIn) == .noData)
        #expect(UsageCards.extra(usage: usage, account: .signedIn) == .noData)
        #expect(UsageCards.limits(usage: nil, account: .signedIn) == .noData)
    }

    @Test("Шлюз: лимиты «нет данных», доплат плана нет")
    func gateway() {
        #expect(UsageCards.limits(usage: nil, account: .gateway) == .noData)
        #expect(UsageCards.extra(usage: nil, account: .gateway) == .hidden)
    }

    @Test("Шлюз показывает окна, если Claude их сообщил")
    func gatewayWithWindows() {
        #expect(UsageCards.limits(usage: UsageSnapshot(windows: [week]), account: .gateway) == .windows([week]))
    }

    @Test("Шлюз показывает сумму и лимит, если Claude их сообщил")
    func gatewayWithMoney() {
        let usage = UsageSnapshot(extra: .on(used: 314, limit: 500, currency: "USD"))
        #expect(UsageCards.extra(usage: usage, account: .gateway) == .spent(used: 314, limit: 500, currency: "USD"))
    }

    @Test("API-ключ: без блоков лимитов и доплат")
    func apiKey() {
        #expect(UsageCards.limits(usage: nil, account: .apiKey) == .hidden)
        #expect(UsageCards.extra(usage: nil, account: .apiKey) == .hidden)
    }

    @Test("Если ничего не известно, это «нет данных», а не отсутствие блока")
    func unknown() {
        #expect(UsageCards.limits(usage: nil, account: .unknown) == .noData)
        #expect(UsageCards.extra(usage: nil, account: .unknown) == .noData)
    }

    @Test("Ноль остаётся нулём: окно с нулём и доплаты с нулём показываются как значения")
    func zero() {
        let empty = UsageWindow(id: "seven_day", kind: .week, percent: 0)
        let usage = UsageSnapshot(windows: [empty], extra: .on(used: 0, limit: 50, currency: "USD"))
        #expect(UsageCards.limits(usage: usage, account: .signedIn) == .windows([empty]))
        #expect(UsageCards.extra(usage: usage, account: .signedIn) == .spent(used: 0, limit: 50, currency: "USD"))
    }

    @Test("Выключенные доплаты видны, даже если аккаунт определить не удалось")
    func offIsReported() {
        #expect(UsageCards.extra(usage: UsageSnapshot(extra: .off), account: .unknown) == .off)
    }
}
