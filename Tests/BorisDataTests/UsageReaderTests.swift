import BorisCore
import Foundation
import Testing
@testable import BorisData

@Suite("Лимиты из кэша Claude Code")
struct UsageReaderTests {
    private func usage(_ body: String) throws -> UsageSnapshot {
        try #require(UsageReader.parse(Data(#"{"cachedUsageUtilization":{"fetchedAtMs":1000,"utilization":{\#(body)}}}"#.utf8)))
    }

    private let fiveHour = #""five_hour":{"utilization":62,"resets_at":"2026-11-05T18:40:00.123456+00:00"}"#
    private let week = #""seven_day":{"utilization":34,"resets_at":"2026-11-09T10:00:00+00:00"}"#
    private let opus = #""seven_day_opus":{"utilization":18,"resets_at":"2026-11-09T10:00:00+00:00"}"#
    private let sonnet = #""seven_day_sonnet":{"utilization":7}"#

    @Test("Все окна на месте, в постоянном порядке")
    func allWindows() throws {
        let found = try usage([sonnet, opus, week, fiveHour].joined(separator: ","))
        #expect(found.windows.map(\.kind) == [.fiveHour, .week, .weekModel("Opus"), .weekModel("Sonnet")])
        #expect(found.windows.map(\.percent) == [62, 34, 18, 7])
        #expect(found.fetchedAt == Date(timeIntervalSince1970: 1))
    }

    @Test("Окно, которого нет, не появляется", arguments: ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet"])
    func eachWindowCanBeAbsent(id: String) throws {
        let parts = [("five_hour", fiveHour), ("seven_day", week), ("seven_day_opus", opus), ("seven_day_sonnet", sonnet)]
        let found = try usage(parts.filter { $0.0 != id }.map(\.1).joined(separator: ","))
        #expect(!found.windows.map(\.id).contains(id))
        #expect(found.windows.count == 3)
    }

    @Test("Каждое окно бывает единственным", arguments: ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet"])
    func eachWindowAlone(id: String) throws {
        let parts = [("five_hour", fiveHour), ("seven_day", week), ("seven_day_opus", opus), ("seven_day_sonnet", sonnet)]
        let found = try usage(parts.filter { $0.0 == id }.map(\.1).joined(separator: ","))
        #expect(found.windows.map(\.id) == [id])
    }

    @Test("План Ultra: пустое окно 5 часов не даёт строки")
    func ultraHasNoFiveHours() throws {
        let found = try usage(#""five_hour":null,"# + week)
        #expect(found.windows.map(\.kind) == [.week])
        let card = UsageCards.limits(usage: found, account: .signedIn)
        #expect(card == .windows(found.windows))
    }

    @Test("Время сброса читается с дробными секундами, а без него окно остаётся")
    func resets() throws {
        let found = try usage([fiveHour, sonnet].joined(separator: ","))
        #expect(found.windows[0].resetsAt == UsageReader.date("2026-11-05T18:40:00+00:00"))
        #expect(found.windows[1].resetsAt == nil)
    }

    @Test("Записи с кодовыми именами не показываются как лимиты, даже с суммой в долларах")
    func codeNames() throws {
        let found = try usage([
            week,
            #""iguana_necktie":{"utilization":0.05,"limit_dollars":250,"used_dollars":0.13,"resets_at":"2026-11-05T07:59:00+00:00"}"#,
            #""amber_ladder":{"utilization":99}"#,
            #""wattle":{"utilization":3}"#,
            #""tangelo":null"#,
            #""spend":{"utilization":63}"#,
        ].joined(separator: ","))
        #expect(found.windows.map(\.id) == ["seven_day"])
    }

    @Test("Окна по моделям из limits: активное есть, неактивное с нулём пропущено, дубли не задваиваются")
    func modelWindows() throws {
        let found = try usage(#""seven_day":{"utilization":25},"seven_day_opus":{"utilization":9},"limits":[{"kind":"weekly_all","percent":25,"is_active":true,"scope":null},{"kind":"weekly_scoped","percent":40,"is_active":true,"resets_at":"2026-11-10T13:00:00+00:00","scope":{"model":{"display_name":"Fable"}}},{"kind":"weekly_scoped","percent":0,"is_active":false,"scope":{"model":{"display_name":"Haiku"}}},{"kind":"weekly_scoped","percent":30,"is_active":true,"scope":{"model":{"display_name":"Opus"}}}]"#)
        #expect(found.windows.map(\.kind) == [.week, .weekModel("Opus"), .weekModel("Fable")])
        #expect(found.windows.first { $0.kind == .weekModel("Opus") }?.percent == 9)
        #expect(found.windows.last?.percent == 40)
        #expect(found.windows.last?.resetsAt != nil)
    }

    @Test("Неактивное окно по модели с ненулевым процентом всё равно показывается: его уже тратят")
    func inactiveButUsed() throws {
        let found = try usage(#""limits":[{"kind":"weekly_scoped","percent":5,"is_active":false,"scope":{"model":{"display_name":"Fable"}}}]"#)
        #expect(found.windows.map(\.kind) == [.weekModel("Fable")])
    }

    @Test("Ноль в окне это настоящий ноль")
    func zeroWindow() throws {
        let found = try usage(#""seven_day":{"utilization":0}"#)
        #expect(found.windows.first?.percent == 0)
    }

    @Test("Странная форма окна не ломает чтение", arguments: [
        #""seven_day":"много""#,
        #""seven_day":{"utilization":"34"}"#,
        #""seven_day":[]"#,
        #""limits":"strange""#,
        #""limits":[1,2]"#,
    ])
    func strangeShape(body: String) throws {
        #expect(try usage(body).windows.isEmpty)
    }

    @Test("Учётная запись и идентификаторы отброшены")
    func nothingPersonal() throws {
        let json = #"{"oauthAccount":{"emailAddress":"secret@x"},"primaryApiKey":"secret","cachedUsageUtilization":{"fetchedAtMs":1000,"accountUuid":"secret","utilization":{"seven_day":{"utilization":16}}}}"#
        let found = try #require(UsageReader.parse(Data(json.utf8)))
        #expect(!String(describing: found).contains("secret"))
    }

    // MARK: - Real extra spend

    @Test("Доплаты включены: сумма, лимит и валюта аккаунта")
    func extraOn() throws {
        let found = try usage(#""extra_usage":{"is_enabled":true,"monthly_limit":5000,"used_credits":1240,"decimal_places":2,"currency":"EUR"}"#)
        #expect(found.extra == .on(used: 12.4, limit: 50, currency: "EUR"))
    }

    @Test("Доплаты включены и потрачено ноль: это ноль, а не «нет данных»")
    func extraZero() throws {
        let found = try usage(#""extra_usage":{"is_enabled":true,"monthly_limit":5000,"used_credits":0,"decimal_places":2,"currency":"USD"}"#)
        #expect(found.extra == .on(used: 0, limit: 50, currency: "USD"))
    }

    @Test("Без лимита сумма всё равно видна", arguments: [#""monthly_limit":null,"#, #""monthly_limit":0,"#, ""])
    func extraWithoutLimit(limit: String) throws {
        let found = try usage(#""extra_usage":{"is_enabled":true,\#(limit)"used_credits":1240,"decimal_places":2,"currency":"USD"}"#)
        #expect(found.extra == .on(used: 12.4, limit: nil, currency: "USD"))
    }

    @Test("Без валюты считаем доллары: так Claude платит по умолчанию")
    func extraDefaultCurrency() throws {
        let found = try usage(#""extra_usage":{"is_enabled":true,"monthly_limit":100,"used_credits":25,"decimal_places":0}"#)
        #expect(found.extra == .on(used: 25, limit: 100, currency: "USD"))
    }

    @Test("Доплаты выключены")
    func extraOff() throws {
        let found = try usage(#""extra_usage":{"is_enabled":false,"monthly_limit":5000,"used_credits":0,"decimal_places":2}"#)
        #expect(found.extra == .off)
        #expect(found.windows.isEmpty)
    }

    @Test("Сведений о доплатах нет или они непонятны", arguments: [
        "",
        #""extra_usage":null"#,
        #""extra_usage":"something new""#,
        #""extra_usage":{}"#,
        #""extra_usage":{"used_credits":100}"#,
        // A sum whose scale is unknown could be a hundred times off.
        #""extra_usage":{"is_enabled":true,"monthly_limit":5000,"used_credits":1240}"#,
        #""extra_usage":{"is_enabled":true,"decimal_places":2}"#,
    ])
    func extraNoData(body: String) throws {
        #expect(try usage(body).extra == .noData)
    }

    @Test("Включённые доплаты с лимитом по-прежнему дают окно для предупреждения о лимите")
    func extraWindow() throws {
        let found = try usage(#""extra_usage":{"is_enabled":true,"monthly_limit":10000,"used_credits":2500,"decimal_places":2}"#)
        let window = try #require(found.windows.first)
        #expect(window.kind == .extraSpend)
        #expect(window.percent == 25)
        #expect(UsageCards.limits(usage: found, account: .signedIn) == .noData)
    }
}

@Suite("Тип аккаунта по файлам Claude")
struct AccountReaderTests {
    private let nothingManaged = ManagedSettings(folder: URL(fileURLWithPath: "/nonexistent"), profiles: [])

    private func profile(_ text: String?, settings: String? = nil, environment: [String: String] = [:], managed: ManagedSettings? = nil) -> UsageReader.Profile? {
        let folder = TempFolder()
        let file = text.map { folder.write("claude.json", $0) } ?? folder.url.appendingPathComponent("missing.json")
        let settingsFile = settings.map { folder.write("settings.json", $0) } ?? folder.url.appendingPathComponent("no-settings.json")
        return UsageReader.profile(file, settings: settingsFile, managed: managed ?? nothingManaged, environment: environment)
    }

    private let limits = #""cachedUsageUtilization":{"fetchedAtMs":1000,"utilization":{"seven_day":{"utilization":16}}}"#

    @Test("Вход по подписке")
    func signedIn() {
        #expect(profile(#"{"oauthAccount":{"emailAddress":"a@x"}}"#)?.account == .signedIn)
        #expect(profile("{\(limits)}")?.account == .signedIn)
    }

    @Test("Без входа и без лимитов это API-ключ")
    func apiKey() {
        #expect(profile(#"{"primaryApiKey":"k"}"#)?.account == .apiKey)
        #expect(profile("{}")?.account == .apiKey)
        #expect(profile(#"{"oauthAccount":{}}"#)?.account == .apiKey)
    }

    @Test("Шлюз виден по настройкам, окружению и настройкам компании")
    func gateway() throws {
        #expect(profile("{}", settings: #"{"env":{"ANTHROPIC_BASE_URL":"https://gateway.example"}}"#)?.account == .gateway)
        #expect(profile("{}", environment: ["ANTHROPIC_BASE_URL": "https://gateway.example"])?.account == .gateway)
        #expect(profile(#"{"oauthAccount":{"emailAddress":"a@x"}}"#, settings: #"{"env":{"ANTHROPIC_BASE_URL":"https://gateway.example"}}"#)?.account == .gateway)

        let company = TempFolder()
        company.write("managed-settings.json", #"{"env":{"ANTHROPIC_BASE_URL":"https://gateway.example"}}"#)
        #expect(profile("{}", managed: ManagedSettings(folder: company.url, profiles: []))?.account == .gateway)
    }

    @Test("Пустая переменная окружения и чужие настройки не делают шлюза")
    func notGateway() {
        #expect(profile("{}", settings: #"{"env":{"OTHER":"1"}}"#, environment: ["ANTHROPIC_BASE_URL": ""])?.account == .apiKey)
    }

    @Test("Файл нельзя прочитать: значит, ничего не известно, а не API-ключ")
    func unreadable() {
        #expect(profile(nil) == nil)
        #expect(profile("{half a fi") == nil)
    }
}
