import AppKit
import Foundation
import Testing
@testable import BorisCore

private let on = Reaction(banner: true, sound: true, mood: .none)
private let bannerOnly = Reaction(banner: true, sound: false, mood: .none)

private func item(_ event: BorisEvent, _ reaction: Reaction = on, telegram: Bool = true) -> NotificationRouter.Item {
    NotificationRouter.Item(event: event, reaction: reaction, telegram: telegram)
}

private func finished(_ number: Int, project: String = "landing") -> BorisEvent {
    BorisEvent(id: "done\(number)", kind: .completed, at: t0, sessionId: "s\(number)", project: project)
}

private func request(_ tool: String? = "Bash", id: String = "r", session: String = "s1") -> BorisEvent {
    BorisEvent(id: id, kind: .waiting, at: t0, sessionId: session, project: "shop-api", toolName: tool, environment: .vsCode)
}

private func banners(_ deliveries: [NotificationDelivery]) -> [MacBanner] {
    deliveries.compactMap {
        if case .banner(let banner) = $0 { return banner }
        return nil
    }
}

private func telegrams(_ deliveries: [NotificationDelivery]) -> [TelegramLine] {
    deliveries.compactMap {
        if case .telegram(let line) = $0 { return line }
        return nil
    }
}

private func sounds(_ deliveries: [NotificationDelivery]) -> [WalrusSound] {
    deliveries.compactMap {
        if case .sound(let sound) = $0 { return sound }
        return nil
    }
}

/// Everything that can leave Boris, as one piece of text.
private func allText(_ deliveries: [NotificationDelivery]) -> String {
    deliveries.map { delivery -> String in
        switch delivery {
        case .banner(let banner): return "\(banner.title) \(banner.body) \(banner.route.userInfo)"
        case .telegram(let line): return line.full
        case .sound, .removeBanners: return ""
        }
    }.joined(separator: "\n")
}

@Suite("Настройки уведомлений")
struct NotificationPreferencesTests {
    @Test("Запрос разрешения, вопрос и план различаются", arguments: [
        ("Bash", false, NotificationTopic.permission),
        (nil, false, .permission),
        ("AskUserQuestion", false, .question),
        (nil, true, .question),
        ("ExitPlanMode", false, .plan),
    ] as [(String?, Bool, NotificationTopic)])
    func requestKinds(tool: String?, asks: Bool, topic: NotificationTopic) {
        #expect(NotificationTopic(BorisEvent(id: "e", kind: .waiting, at: t0, toolName: tool, asksForAnswer: asks)) == topic)
    }

    @Test("Каждое событие попадает в свою строку таблицы", arguments: [
        (EventKind.completed, NotificationTopic.finished),
        (.sessionFinished, .finished),
        (.completedWithErrors, .failure),
        (.allAgentsFailed, .failure),
        (.failed, .failure),
        (.sessionError, .failure),
        (.limitReached, .failure),
        (.stopped, .interrupted),
        (.interrupted, .interrupted),
        (.silent, .silence),
        (.limitNear, .limitNear),
    ] as [(EventKind, NotificationTopic)])
    func topics(kind: EventKind, topic: NotificationTopic) {
        #expect(NotificationTopic(BorisEvent(id: "e", kind: kind, at: t0)) == topic)
    }

    @Test("Сессия ждёт ввода: это вопрос, а не разрешение") func waitingReasonReachesEvent() {
        var detector = EventDetector(config: DetectorConfig(waitingDelay: 0))
        _ = detector.detect(runs: [], sessions: [], usage: nil, now: t0)
        let input = detector.detect(runs: [], sessions: [session(status: "waiting", waitingFor: "input needed")], usage: nil, now: at(1))
        #expect(input.map(NotificationTopic.init) == [.question])
        var second = EventDetector(config: DetectorConfig(waitingDelay: 0))
        _ = second.detect(runs: [], sessions: [], usage: nil, now: t0)
        let prompt = second.detect(runs: [], sessions: [session(status: "waiting", waitingFor: "permission prompt")], usage: nil, now: at(1))
        #expect(prompt.map(NotificationTopic.init) == [.permission])
    }

    @Test("По умолчанию как на макете") func defaults() {
        let preferences = NotificationPreferences()
        #expect(preferences.choice(.permission) == ChannelChoice(mac: true, sound: true, telegram: true))
        #expect(preferences.choice(.question) == ChannelChoice(mac: true, sound: true, telegram: true))
        #expect(preferences.choice(.plan) == ChannelChoice(mac: true, sound: false, telegram: false))
        #expect(preferences.choice(.finished) == ChannelChoice(mac: true, sound: false, telegram: false))
        #expect(preferences.choice(.failure) == ChannelChoice(mac: true, sound: true, telegram: true))
        #expect(preferences.choice(.interrupted) == ChannelChoice(mac: true, sound: false, telegram: true))
        #expect(preferences.choice(.silence) == ChannelChoice(mac: true, sound: false, telegram: false))
        #expect(preferences.choice(.limitNear) == ChannelChoice(mac: true, sound: true, telegram: true))
    }

    @Test("Mac выключен для завершения: остальные каналы работают по своим настройкам") func oneChannelOff() {
        var preferences = NotificationPreferences()
        preferences.telegramChat = "1"
        preferences.channels[.finished] = ChannelChoice(mac: false, sound: true, telegram: true)
        let event = finished(1)
        let reaction = preferences.reaction(for: event, mood: .happy)
        #expect(reaction == Reaction(banner: false, sound: true, mood: .happy))

        var router = NotificationRouter()
        let delivered = router.route([item(event, reaction, telegram: preferences.wantsTelegram(event, quiet: false))], now: t0)
        #expect(banners(delivered).isEmpty)
        #expect(sounds(delivered) == [.done])
        #expect(telegrams(delivered).count == 1)
    }

    @Test("Голос выключен: звуков нет ни у какого события") func voiceOff() {
        var preferences = NotificationPreferences()
        preferences.voiceOn = false
        #expect(!preferences.reaction(for: request(), mood: .none).sound)
        #expect(preferences.reaction(for: request(), mood: .none).banner)
    }

    @Test("Без бота в Telegram не уходит ничего") func noBot() {
        #expect(!NotificationPreferences().wantsTelegram(request(), quiet: false))
    }

    @Test("Выбор переживает кодирование, а токену в нём места нет") func roundTrip() throws {
        var preferences = NotificationPreferences()
        preferences.channels[.plan] = ChannelChoice(mac: false, sound: true, telegram: false)
        preferences.telegramChat = "777"
        preferences.limitNearPercent = 75
        let data = try JSONEncoder().encode(preferences)
        #expect(try JSONDecoder().decode(NotificationPreferences.self, from: data) == preferences)
        #expect(!String(decoding: data, as: UTF8.self).lowercased().contains("token"))
    }

    @Test("Порог лимита из настроек срабатывает один раз за окно") func limitOnce() {
        var detector = EventDetector(config: DetectorConfig(usageThresholds: [85]))
        func usage(_ percent: Double, resets: Date = at(1000)) -> UsageSnapshot {
            UsageSnapshot(fetchedAt: t0, windows: [UsageWindow(id: "five_hour", kind: .fiveHour, percent: percent, resetsAt: resets)])
        }
        #expect(detector.detect(runs: [], sessions: [], usage: usage(80), now: t0).isEmpty)
        #expect(detector.detect(runs: [], sessions: [], usage: usage(86), now: at(1)).map(\.kind) == [.limitNear])
        #expect(detector.detect(runs: [], sessions: [], usage: usage(99), now: at(2)).isEmpty)
        #expect(detector.detect(runs: [], sessions: [], usage: usage(84), now: at(3)).isEmpty)
        #expect(detector.detect(runs: [], sessions: [], usage: usage(86), now: at(4)).isEmpty)
    }
}

@Suite("Содержимое уведомлений")
struct NotificationContentTests {
    @Test("Запрос: проект и событие, как на макете") func request() {
        let event = BorisEvent(id: "r", kind: .waiting, at: t0, sessionId: "s1", project: "shop-api", toolName: "Bash", environment: .vsCode)
        let banner = NotificationWords.banner(event)
        #expect(banner.title == "shop-api · waiting for permission")
        #expect(banner.body == "Claude wants to run a command · VS Code")
        #expect(NotificationWords.telegram(event) == TelegramLine(subject: "shop-api", text: "waiting for permission (VS Code)"))
    }

    @Test("Нажатие на запрос ведёт к запросу, на сессию к сессии, на лимит к расходу") func routes() {
        #expect(NotificationWords.banner(BorisEvent(id: "r", kind: .waiting, at: t0, sessionId: "s1")).route == .requests(session: "s1"))
        #expect(NotificationWords.banner(finished(1)).route == .session("s1"))
        #expect(NotificationWords.banner(BorisEvent(id: "l", kind: .limitReached, at: t0)).route == .usage)
        #expect(NotificationWords.banner(BorisEvent(id: "l", kind: .limitNear, at: t0)).route == .usage)
        #expect(NotificationWords.banner(BorisEvent(id: "x", kind: .sessionError, at: t0)).route == .now)
    }

    @Test("Адрес нажатия переживает уведомление", arguments: [
        NotificationRoute.now, .usage, .session("s1"), .requests(session: "s1"), .requests(session: nil),
    ])
    func routeRoundTrip(route: NotificationRoute) {
        #expect(NotificationRoute(userInfo: route.userInfo) == route)
    }

    @Test("Незнакомый адрес никуда не ведёт") func strangeRoute() {
        #expect(NotificationRoute(userInfo: [:]) == nil)
        #expect(NotificationRoute(userInfo: ["route": "session"]) == nil)
    }

    @Test("Вместо проекта только среда, если его нет") func noProject() {
        #expect(NotificationWords.telegram(BorisEvent(id: "x", kind: .silent, at: t0, environment: .cowork)).subject == "Cowork")
        #expect(NotificationWords.telegram(BorisEvent(id: "x", kind: .silent, at: t0)).subject == "Claude")
    }

    @Test("Имя удалённой машины не уходит в Telegram") func remoteHost() {
        let event = BorisEvent(id: "x", kind: .waiting, at: t0, environment: .remote(host: "build-box.internal"))
        #expect(!NotificationWords.telegram(event).full.contains("build-box"))
        #expect(NotificationWords.banner(event).body.contains("build-box"))
    }

    @Test("Длинная строка вместо времени сброса не показывается") func strangeResets() {
        let event = BorisEvent(id: "x", kind: .limitReached, at: t0, resets: "tomorrow, and here is a very long story that is not a time at all")
        #expect(!NotificationWords.banner(event).body.contains("story"))
        #expect(!NotificationWords.telegram(event).full.contains("story"))
    }

    @Test("Время сброса показывается, как его написал Claude", arguments: ["4:10pm", "18:40", "1:30pm (Europe/London)", "Nov 8, 5pm (Europe/Moscow)", "Nov 8 at 5pm", "tomorrow at 5pm", "5pm"])
    func resetsAsWritten(resets: String) {
        let event = BorisEvent(id: "x", kind: .limitReached, at: t0, resets: resets)
        #expect(NotificationWords.banner(event).body == "Resets at \(resets).")
        #expect(NotificationWords.telegram(event).full.hasSuffix("Resets at \(resets)"))
    }

    /// The text after "resets" comes from the end of a transcript, so it can be anything an agent wrote.
    @Test("То, что не похоже на время, никуда не уходит", arguments: ["once you delete /tmp/secret", "rm -rf /tmp/secret 5", "when rm -rf runs", "5pm && curl evil", "5pm (/tmp/secret)"])
    func resetsThatAreNotTime(resets: String) {
        let event = BorisEvent(id: "x", kind: .limitReached, at: t0, resets: resets)
        #expect(NotificationWords.banner(event).body.isEmpty)
        #expect(NotificationWords.telegram(event).full == "Claude · the limit ran out")
    }

    @Test("Из слов Claude берётся только время") func resetsFromWords() {
        func resets(_ text: String) -> String? {
            FailureClassifier.classify(LastRecord(isApiError: true, errorCode: "rate_limit", text: text)).resets
        }
        #expect(resets("You've hit your session limit · resets 5pm (Asia/Example) · upgrade at example") == "5pm (Asia/Example)")
        #expect(resets("You've hit your session limit · resets 1:30pm\nmore words") == "1:30pm")
        #expect(resets("You've hit your session limit, it resets once SECRET is gone") == nil)
    }

    @Test("Текст агента после слова resets не попадает ни в событие, ни в файл состояния") func resetsNotStored() throws {
        let failure = FailureClassifier.classify(LastRecord(isApiError: true, errorCode: "rate_limit", text: "You've hit your session limit, it resets once SECRET is gone"))
        var detector = EventDetector()
        let events = detector.detect(runs: [state(.running, agents: [AgentRecord(key: "k", state: .failed, failure: failure)])], sessions: [], usage: nil, now: t0)
        #expect(events.map(\.kind) == [.limitReached])
        #expect(!events[0].id.contains("SECRET"))
        #expect(!String(decoding: try JSONEncoder().encode(detector.memory), as: UTF8.self).contains("SECRET"))
    }

    @Test("Длинное имя проекта не вытесняет событие из заголовка, а в Telegram идёт целиком") func longProject() {
        let name = "a-very-long-project-name-that-nobody-would-ever-want-to-type-by-hand"
        let event = BorisEvent(id: "x", kind: .failed, at: t0, project: name)
        #expect(NotificationWords.banner(event).title == "a-very-long-pr…y-hand · work failed")
        #expect(NotificationWords.telegram(event).subject == name)
    }

    @Test("Сводка пропущенного как на макете") func quietSummary() {
        let banner = NotificationWords.quietSummary(missed: [.waiting: 3, .failed: 1, .completed: 2], requestsWaiting: 1)
        #expect(banner.title == "While Do not disturb was on")
        #expect(banner.body == "3 requests, 1 failure, 2 finished. 1 request is still waiting.")
        #expect(banner.route == .requests(session: nil))
        #expect(NotificationWords.quietSummary(missed: [.silent: 1], requestsWaiting: 0).route == .now)
    }

    @Test("Несколько имён укорачиваются") func names() {
        #expect(NotificationWords.names([]) == "")
        #expect(NotificationWords.names(["a"]) == "a")
        #expect(NotificationWords.names(["a", "b", "c"]) == "a, b and c")
        #expect(NotificationWords.names(["a", "b", "c", "d", "e"]) == "a, b, c and 2 more")
    }

    /// Everything secret a session can hold, from the files through the detector to what leaves Boris.
    @Test("Текст команд, запросов и пути не доходит до уведомлений и Telegram") func nothingLeaks() {
        let secret = "SECRET"
        var preferences = NotificationPreferences()
        preferences.telegramChat = "1"
        preferences.channels = Dictionary(uniqueKeysWithValues: NotificationTopic.allCases.map { ($0, ChannelChoice(mac: true, sound: true, telegram: true)) })

        func info(_ id: String, status: String, waitingFor: String? = nil) -> SessionInfo {
            var info = SessionInfo(sessionId: id, pid: 100, cwd: "/Users/\(secret)/private/\(secret)-folder/proj", entrypoint: "claude-vscode", name: "\(secret) name", status: status, waitingFor: waitingFor)
            info.title = "\(secret) prompt turned into a title"
            info.nameSource = "derived"
            info.currentStep = StepBrief(kind: .shell, tool: "Bash", fileName: "\(secret).swift")
            return info
        }
        let failedAgent = AgentRecord(
            key: "k",
            label: "\(secret) label",
            state: .failed,
            failure: FailureClassifier.classify(LastRecord(isApiError: true, errorCode: "rate_limit", text: "\(secret) You've hit your session limit · resets 1:30pm"))
        )
        func secretRun(_ status: RunStatus, id: String, agents: [AgentRecord] = []) -> RunState {
            var run = RunState(runId: id, sessionId: "s9", name: "\(secret) run", description: "\(secret) description", cwd: "/Users/\(secret)/proj", status: status, lastWrite: t0, agents: agents)
            run.errorFirstLine = "\(secret) rm -rf /"
            return run
        }

        var detector = EventDetector(config: DetectorConfig(longTurn: 1, waitingDelay: 0, sessionAfterRunQuiet: 0))
        _ = detector.detect(runs: [], sessions: [info("busy", status: "busy")], usage: nil, now: t0)
        let events = detector.detect(
            runs: [secretRun(.failed, id: "a"), secretRun(.interrupted, id: "b"), secretRun(.completed, id: "c"), secretRun(.running, id: "d", agents: [failedAgent])],
            sessions: [
                info("permission", status: "waiting", waitingFor: "approve Bash: \(secret) rm -rf /"),
                info("no-colon", status: "waiting", waitingFor: "approve \(secret) rm -rf /"),
                info("other", status: "waiting", waitingFor: "\(secret) reason"),
                info("busy", status: "idle"),
            ],
            usage: nil,
            now: at(2),
            failures: [HookState.Failure(session: "permission", error: "\(secret) error")],
            endedSessions: [info("dead", status: "busy")]
        )
        #expect(Set(events.map(\.kind)).isSuperset(of: [.waiting, .failed, .interrupted, .completed, .limitReached, .sessionFinished, .sessionError]))

        var router = NotificationRouter()
        let delivered = router.route(events.map { item($0, preferences.reaction(for: $0, mood: .none), telegram: preferences.wantsTelegram($0, quiet: false)) }, now: at(2)) + router.drain(now: at(100))
        #expect(!banners(delivered).isEmpty)
        #expect(!telegrams(delivered).isEmpty)
        // The session's id is a random id on disk, not its text, and the project's name is allowed.
        #expect(!allText(delivered).contains(secret))
        for event in events {
            let single = allText([.banner(NotificationWords.banner(event)), .telegram(NotificationWords.telegram(event))])
            #expect(!single.contains(secret), "\(event.kind)")
        }
    }

    @Test("Даже если в проект попал путь, уходит только имя папки") func pathInProject() {
        let event = BorisEvent(id: "x", kind: .failed, at: t0, project: "/Users/someone/private/proj")
        #expect(NotificationWords.telegram(event).subject == "proj")
        #expect(NotificationWords.banner(event).title.hasPrefix("proj "))
    }

    @Test("Русский перевод есть у каждой строки уведомлений и не теряет чисел") func russianForms() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Strings/notifications.json")
        let table = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        for (key, value) in table where key.contains("%lld") {
            let forms = (value as? [String: String])?.values.map { $0 } ?? [value as? String ?? ""]
            for form in forms { #expect(form.contains("%lld"), "\(key)") }
        }
    }
}

@Suite("Волны и сводки")
struct NotificationWaveTests {
    @Test("Пять завершений в одном проходе: одно уведомление, один звук") func oneScan() {
        var router = NotificationRouter()
        let delivered = router.route((1...5).map { item(finished($0, project: "p\($0)")) }, now: t0)
        #expect(banners(delivered).map(\.title) == ["Work finished: 5"])
        #expect(banners(delivered)[0].body == "p1, p2, p3 and 2 more")
        #expect(sounds(delivered) == [.done])
        #expect(!delivered.contains { if case .removeBanners = $0 { return true } else { return false } })
    }

    @Test("Волна в нескольких проходах: два сразу, потом одна сводка вместо них") func severalScans() {
        var router = NotificationRouter()
        let first = router.route([item(finished(1)), item(finished(2))], now: t0)
        #expect(banners(first).map(\.id) == ["done1", "done2"])
        let second = router.route([item(finished(3))], now: at(5))
        #expect(second.contains(.removeBanners(["done1", "done2"])))
        #expect(banners(second).map(\.title) == ["Work finished: 3"])
        let third = router.route([item(finished(4))], now: at(8))
        #expect(banners(third).map(\.title) == ["Work finished: 4"])
        #expect(banners(third)[0].id == banners(second)[0].id)
    }

    @Test("Разные события не смешиваются") func differentTopics() {
        var router = NotificationRouter()
        let events = (1...3).map { item(finished($0)) } + [item(request())]
        let delivered = router.route(events, now: t0)
        #expect(banners(delivered).count == 2)
        #expect(banners(delivered).contains { $0.route == .requests(session: "s1") })
    }

    @Test("Волна запросов ведёт к запросам") func requestWave() {
        var router = NotificationRouter()
        let delivered = router.route((1...3).map { item(request(id: "r\($0)", session: "s\($0)")) }, now: t0)
        #expect(banners(delivered).map(\.route) == [.requests(session: nil)])
    }

    @Test("Кончилась волна: следующие события снова приходят по одному") func afterWave() {
        var router = NotificationRouter()
        _ = router.route((1...3).map { item(finished($0)) }, now: t0)
        #expect(banners(router.route([item(finished(4))], now: at(30))).map(\.id) == ["done4"])
    }

    @Test("Telegram не забирает сообщений назад: одна сводка, когда волна закончилась") func telegramWave() {
        var router = NotificationRouter()
        let first = router.route([item(finished(1)), item(finished(2))], now: t0)
        #expect(telegrams(first).count == 2)
        #expect(telegrams(router.route([item(finished(3))], now: at(5))).isEmpty)
        #expect(telegrams(router.route([item(finished(4))], now: at(8))).isEmpty)
        #expect(router.drain(now: at(12)).isEmpty)
        let summary = telegrams(router.drain(now: at(19)))
        #expect(summary.map(\.full) == ["Boris · Work finished: 4. landing"])
        #expect(router.drain(now: at(40)).isEmpty)
    }

    @Test("Новая волна сразу за старой не теряет её сводку в Telegram") func telegramSummaryBeforeNext() {
        var router = NotificationRouter()
        _ = router.route((1...3).map { item(finished($0)) }, now: t0)
        let later = router.route([item(finished(4))], now: at(30))
        #expect(telegrams(later).count == 2)
        #expect(telegrams(later)[0].text.hasPrefix("Work finished: 3"))
    }

    @Test("Длинная волна: счёт только растёт, а по одному больше не приходит") func longWave() {
        var router = NotificationRouter()
        var titles: [String] = []
        var lines: [TelegramLine] = []
        for (index, second) in stride(from: 0.0, through: 28, by: 4).enumerated() {
            var event = finished(index + 1)
            event.at = at(second)
            let delivered = router.route([item(event)], now: at(second))
            titles += banners(delivered).map(\.title)
            lines += telegrams(delivered)
        }
        #expect(titles == ["landing · work done", "landing · work done"] + (3...8).map { "Work finished: \($0)" })
        #expect(lines.count == 2)
        #expect(telegrams(router.drain(now: at(40))).map(\.full) == ["Boris · Work finished: 8. landing"])
    }

    @Test("Волна стала реже, но не кончилась: всё равно одна сводка") func waveSlowsDown() {
        var router = NotificationRouter()
        func event(_ number: Int, _ second: Double) -> NotificationRouter.Item {
            var event = finished(number)
            event.at = at(second)
            return item(event)
        }
        _ = router.route((1...5).map { event($0, 0) }, now: t0)
        _ = router.route([event(6, 9)], now: at(9))
        // Only two of the burst are inside the window now, and that does not make it a new start.
        let later = router.route([event(7, 12)], now: at(12))
        #expect(banners(later).map(\.title) == ["Work finished: 7"])
        #expect(telegrams(later).isEmpty)
    }

    @Test("Сводка забирает все уведомления этой волны, даже если первое уже вышло за окно") func waveTakesAllBack() {
        var router = NotificationRouter()
        var first = finished(1)
        first.at = t0
        var second = finished(2)
        second.at = at(6)
        var third = finished(3)
        third.at = at(12)
        var fourth = finished(4)
        fourth.at = at(13)
        _ = router.route([item(first)], now: t0)
        _ = router.route([item(second)], now: at(6))
        _ = router.route([item(third)], now: at(12))
        #expect(router.route([item(fourth)], now: at(13)).contains(.removeBanners(["done1", "done2", "done3"])))
    }

    @Test("Сводке нечем заменить уведомления: они остаются на экране") func nothingReplaces() {
        var router = NotificationRouter()
        _ = router.route([item(finished(1)), item(finished(2))], now: t0)
        let muted = router.route([item(finished(3), Reaction(banner: false, sound: false, mood: .none))], now: at(1))
        #expect(!muted.contains { if case .removeBanners = $0 { return true } else { return false } })
        #expect(banners(muted).isEmpty)
    }

    @Test("Даже если в проект попал путь, сводки несут только имя папки") func pathInSummaries() {
        let path = "/Users/someone/private/proj"
        var router = NotificationRouter()
        let wave = (1...3).map { item(finished($0, project: path)) }
        let away = BorisEvent(id: "a", kind: .interrupted, at: t0, sessionId: "s", project: path, whileAway: true)
        let delivered = router.route(wave + [item(away)], now: t0) + router.drain(now: at(30))
        #expect(!banners(delivered).isEmpty)
        #expect(telegrams(delivered).count == 2)
        #expect(!allText(delivered).contains("someone"))
    }

    private func limitFailure(_ id: String) -> BorisEvent {
        BorisEvent(id: id, kind: .allAgentsFailed, at: t0, project: "p", agentsFailed: 2, topFailure: .limit)
    }

    private func limitEvent(_ id: String, limit: LimitKind = .session, resets: String? = "18:40") -> BorisEvent {
        BorisEvent(id: id, kind: .limitReached, at: t0, project: "p", agentsFailed: 2, limitKind: limit, resets: resets)
    }

    private var limitAgent: AgentRecord {
        AgentRecord(key: "k", state: .failed, failure: FailureClassifier.classify(LastRecord(isApiError: true, errorCode: "rate_limit", text: "You've hit your session limit · resets 18:40")))
    }

    /// A run that fell from the limit between two looks, never seen at work with a failed agent.
    private func fallen(_ id: String) -> RunState {
        var run = state(.allAgentsFailed, id: id, agents: [limitAgent, limitAgent, limitAgent])
        run.topFailure = .limit
        return run
    }

    /// One look of the detector, the way the person gets it.
    private func look(_ detector: inout EventDetector, _ router: inout NotificationRouter, runs: [RunState] = [], failures: [HookState.Failure] = [], now: Date) -> [NotificationDelivery] {
        router.route(detector.detect(runs: runs, sessions: [], usage: nil, now: now, failures: failures).map { item($0) }, now: now)
    }

    @Test("О лимите сказал упавший запуск, потом другой запуск упёрся в него же: второго уведомления нет") func limitToldByFailureFirst() {
        var detector = EventDetector()
        var router = NotificationRouter()
        _ = look(&detector, &router, now: t0)
        #expect(banners(look(&detector, &router, runs: [fallen("a")], now: at(1))).count == 1)
        #expect(look(&detector, &router, runs: [fallen("a"), state(.running, id: "b", agents: [limitAgent])], now: at(30)).isEmpty)
    }

    @Test("Сначала лимит без времени сброса, потом с ним: время доходит, а на Mac это то же уведомление") func limitGetsItsTime() {
        var detector = EventDetector()
        var router = NotificationRouter()
        _ = look(&detector, &router, now: t0)
        let first = look(&detector, &router, failures: [HookState.Failure(session: "s", error: "rate_limit")], now: at(1))
        let second = look(&detector, &router, runs: [fallen("a")], now: at(30))
        #expect(banners(first).count == 1)
        #expect(banners(second).map(\.id) == banners(first).map(\.id))
        #expect(banners(second)[0].body.contains("18:40"))
        #expect(telegrams(second).count == 1)
        #expect(look(&detector, &router, runs: [fallen("a"), fallen("b")], now: at(60)).isEmpty)
    }

    @Test("Другой лимит в те же часы это новость, а старый не повторяется") func anotherLimit() {
        var router = NotificationRouter()
        _ = router.route([item(limitEvent("session"))], now: t0)
        #expect(banners(router.route([item(limitEvent("month", limit: .monthly, resets: nil))], now: at(60))).count == 1)
        #expect(router.route([item(limitFailure("later"))], now: at(120)).isEmpty)
    }

    @Test("Остановка, прерывание и молчание не прячутся за лимитом", arguments: [EventKind.stopped, .interrupted, .silent])
    func notAFailure(kind: EventKind) {
        var router = NotificationRouter()
        _ = router.route([item(limitEvent("limit"))], now: t0)
        let event = BorisEvent(id: "e", kind: kind, at: t0, project: "p", topFailure: .limit)
        #expect(banners(router.route([item(event)], now: at(30))).map(\.id) == ["e"])
    }

    @Test("Запуск упал от лимита сразу, без стадии работы: время сброса всё равно в уведомлении") func limitTimeWithoutItsEvent() {
        var detector = EventDetector()
        var router = NotificationRouter()
        _ = look(&detector, &router, now: t0)
        let delivered = look(&detector, &router, runs: [fallen("a")], now: at(1))
        #expect(banners(delivered).map(\.title) == ["The limit ran out · 3 agents failed"])
        #expect(banners(delivered)[0].body == "proj. Resets at 18:40.")
        #expect(telegrams(delivered).map(\.full) == ["proj · the limit ran out, 3 agents failed. Resets at 18:40"])
    }

    @Test("Лимит кончился и упало много агентов: одно общее уведомление со временем сброса") func limitWave() {
        let failedLimit = AgentRecord(key: "k", state: .failed, failure: FailureClassifier.classify(LastRecord(isApiError: true, errorCode: "rate_limit", text: "You've hit your session limit · resets 18:40")))
        var detector = EventDetector()
        _ = detector.detect(runs: [], sessions: [], usage: nil, now: t0)
        let running = (0..<6).map { state(.running, id: "wf_\($0)", agents: [failedLimit, failedLimit]) }
        var router = NotificationRouter()

        let first = router.route(detector.detect(runs: running, sessions: [], usage: nil, now: at(1)).map { item($0) }, now: at(1))
        #expect(banners(first).count == 1)
        #expect(banners(first)[0].title == "The limit ran out · 12 agents failed")
        #expect(banners(first)[0].body == "proj. Resets at 18:40.")
        #expect(banners(first)[0].route == .usage)
        #expect(sounds(first) == [.tired])
        #expect(telegrams(first).map(\.full) == ["proj · the limit ran out, 12 agents failed. Resets at 18:40"])

        // Then the runs fall one by one, and that adds nothing.
        var failed = (0..<6).map { index -> RunState in
            var run = state(.allAgentsFailed, id: "wf_\(index)", agents: [failedLimit, failedLimit])
            run.topFailure = .limit
            return run
        }
        failed[0].status = .completedWithErrors
        let later = router.route(detector.detect(runs: failed, sessions: [], usage: nil, now: at(40)).map { item($0) }, now: at(40))
        #expect(later.isEmpty)
    }

    @Test("Сбои от лимита в одном проходе с ним не дают отдельных уведомлений, в каком бы порядке ни шли") func limitInOneScan() {
        var router = NotificationRouter()
        let failure = BorisEvent(id: "run", kind: .allAgentsFailed, at: t0, project: "p", agentsFailed: 2, topFailure: .limit)
        let limit = BorisEvent(id: "limit", kind: .limitReached, at: t0, project: "p", agentsFailed: 2, resets: "18:40")
        let delivered = router.route([item(failure), item(limit)], now: t0)
        #expect(banners(delivered).map(\.title) == ["The limit ran out · 2 agents failed"])
        #expect(telegrams(delivered).count == 1)
    }

    @Test("Два запуска упали от лимита разом: одно уведомление, а следующий упавший ничего не добавляет") func limitFromFallenRuns() {
        var detector = EventDetector()
        var router = NotificationRouter()
        _ = look(&detector, &router, now: t0)
        let first = look(&detector, &router, runs: [fallen("a"), fallen("b")], now: at(1))
        #expect(banners(first).map(\.title) == ["The limit ran out · 6 agents failed"])
        #expect(look(&detector, &router, runs: [fallen("a"), fallen("b"), fallen("c")], now: at(60)).isEmpty)
    }

    @Test("Через пять часов это уже новый лимит") func limitLater() {
        var detector = EventDetector()
        var router = NotificationRouter()
        _ = look(&detector, &router, now: t0)
        _ = look(&detector, &router, runs: [fallen("a")], now: at(1))
        #expect(banners(look(&detector, &router, runs: [fallen("a"), fallen("b")], now: at(1 + 5 * 3600))).count == 1)
    }

    @Test("Перезапуск Boris не повторяет лимит, о котором уже сказано") func limitAcrossRestart() throws {
        var before = EventDetector()
        var router = NotificationRouter()
        _ = look(&before, &router, now: t0)
        #expect(banners(look(&before, &router, runs: [fallen("a")], now: at(1))).count == 1)

        var after = EventDetector(memory: try JSONDecoder().decode(DetectorMemory.self, from: JSONEncoder().encode(before.memory)))
        var newRouter = NotificationRouter()
        _ = look(&after, &newRouter, runs: [fallen("a")], now: at(100))
        #expect(look(&after, &newRouter, runs: [fallen("a"), fallen("b")], now: at(130)).isEmpty)
    }

    @Test("Сбой по другой причине лимит не глотает") func otherFailureAfterLimit() {
        var router = NotificationRouter()
        _ = router.route([item(BorisEvent(id: "l", kind: .limitReached, at: t0))], now: t0)
        let other = BorisEvent(id: "o", kind: .failed, at: t0, project: "p", topFailure: .api)
        #expect(banners(router.route([item(other)], now: at(1))).map(\.id) == ["o"])
    }

    @Test("Работа прервалась, пока Boris был закрыт: одна сводка") func awaySummary() {
        var router = NotificationRouter()
        let away = ["boris", "deploy-tools", "boris"].enumerated().map { index, name in
            BorisEvent(id: "a\(index)", kind: .interrupted, at: t0, sessionId: index == 2 ? "boris" : name, project: name, whileAway: true)
        }
        let delivered = router.route(away.map { item($0) }, now: t0)
        #expect(banners(delivered).count == 1)
        #expect(banners(delivered)[0].title == "While Boris was closed")
        #expect(banners(delivered)[0].body == "2 sessions were interrupted: boris and deploy-tools. Open to see where the work stopped.")
        #expect(banners(delivered)[0].route == .now)
        #expect(telegrams(delivered).map(\.full) == ["Boris · while Boris was closed, 2 sessions were interrupted: boris and deploy-tools"])
        #expect(sounds(delivered) == [.alarm])
    }

    @Test("Одна прерванная сессия: нажатие ведёт прямо к ней") func awayOne() {
        var router = NotificationRouter()
        let event = BorisEvent(id: "a", kind: .interrupted, at: t0, sessionId: "s1", project: "boris", whileAway: true)
        let delivered = router.route([item(event)], now: t0)
        #expect(banners(delivered)[0].body == "1 session was interrupted: boris. Open to see where the work stopped.")
        #expect(banners(delivered)[0].route == .session("s1"))
    }

    @Test("Обычное прерывание при открытом Boris идёт обычным путём") func interruptedWhileOpen() {
        var router = NotificationRouter()
        let event = BorisEvent(id: "a", kind: .interrupted, at: t0, sessionId: "s1", project: "boris")
        #expect(banners(router.route([item(event)], now: t0)).map(\.title) == ["boris · work interrupted"])
    }
}

@Suite("Прерванные сессии")
struct InterruptedSessionTests {
    private func info(_ id: String, status: String = "busy") -> SessionInfo {
        session(id: id, status: status)
    }

    @Test("Процесс исчез посреди работы: одно событие") func diedWhileOpen() {
        var detector = EventDetector()
        _ = detector.detect(runs: [], sessions: [info("s1")], usage: nil, now: t0)
        let events = detector.detect(runs: [], sessions: [], usage: nil, now: at(5), endedSessions: [info("s1")])
        #expect(events.map(\.kind) == [.interrupted])
        #expect(events[0].sessionId == "s1")
        #expect(!events[0].whileAway)
        #expect(detector.detect(runs: [], sessions: [], usage: nil, now: at(10), endedSessions: [info("s1")]).isEmpty)
    }

    @Test("Сессия прервалась, пока Boris был закрыт") func diedWhileClosed() throws {
        var before = EventDetector()
        _ = before.detect(runs: [], sessions: [info("s1")], usage: nil, now: t0)
        let saved = try JSONDecoder().decode(DetectorMemory.self, from: JSONEncoder().encode(before.memory))
        var after = EventDetector(memory: saved)
        let events = after.detect(runs: [], sessions: [], usage: nil, now: at(100), endedSessions: [info("s1")])
        #expect(events.map(\.whileAway) == [true])
        #expect(after.detect(runs: [], sessions: [], usage: nil, now: at(105), endedSessions: [info("s1")]).isEmpty)
    }

    @Test("Запуск прервался, пока Boris был закрыт: событие помечено") func runWhileClosed() {
        var before = EventDetector()
        _ = before.detect(runs: [state(.running)], sessions: [], usage: nil, now: t0)
        var after = EventDetector(memory: before.memory)
        let events = after.detect(runs: [state(.interrupted)], sessions: [], usage: nil, now: at(100))
        #expect(events.map(\.whileAway) == [true])
    }

    @Test("Незнакомая мёртвая сессия при первом запуске: это старая новость") func unknownSession() {
        var detector = EventDetector()
        #expect(detector.detect(runs: [], sessions: [], usage: nil, now: t0, endedSessions: [info("old")]).isEmpty)
    }

    @Test("Сессия ничего не делала: ничего не прервалось") func idleSession() {
        var detector = EventDetector()
        _ = detector.detect(runs: [], sessions: [info("s1", status: "idle")], usage: nil, now: t0)
        #expect(detector.detect(runs: [], sessions: [], usage: nil, now: at(5), endedSessions: [info("s1", status: "idle")]).isEmpty)
    }

    @Test("Запуск внутри сам сообщает о себе, одно и то же не говорится дважды") func notTwice() {
        var detector = EventDetector()
        _ = detector.detect(runs: [state(.running, session: "s1")], sessions: [info("s1")], usage: nil, now: t0)
        let events = detector.detect(runs: [state(.interrupted, session: "s1")], sessions: [], usage: nil, now: at(5), endedSessions: [info("s1")])
        #expect(events.map(\.runId) == ["wf_1"])
    }

    @Test("Убитую сессию продолжили: старый файл не даёт ложной тревоги") func resumed() {
        var detector = EventDetector()
        _ = detector.detect(runs: [], sessions: [info("s1")], usage: nil, now: t0)
        let stale = session(id: "s1", pid: 100, status: "busy")
        #expect(detector.detect(runs: [], sessions: [], usage: nil, now: at(5), endedSessions: [stale]).count == 1)
        // The same id under a new process, next to the file the old one left.
        let resumed = session(id: "s1", pid: 200, status: "busy")
        #expect(detector.detect(runs: [], sessions: [resumed], usage: nil, now: at(10), endedSessions: [stale]).isEmpty)
        // It ends properly, and only the old file is left.
        #expect(detector.detect(runs: [], sessions: [], usage: nil, now: at(15), endedSessions: [stale]).isEmpty)
    }

    @Test("Перезапуск Boris не возвращает тревогу о старом файле убитой и продолженной сессии") func resumedAcrossRestart() throws {
        var before = EventDetector()
        _ = before.detect(runs: [], sessions: [info("s1")], usage: nil, now: t0)
        let stale = session(id: "s1", pid: 100, status: "busy")
        #expect(before.detect(runs: [], sessions: [], usage: nil, now: at(5), endedSessions: [stale]).count == 1)
        let resumed = session(id: "s1", pid: 200, status: "busy")
        _ = before.detect(runs: [], sessions: [resumed], usage: nil, now: at(10), endedSessions: [stale])

        let saved = try JSONDecoder().decode(DetectorMemory.self, from: JSONEncoder().encode(before.memory))
        var after = EventDetector(memory: saved)
        #expect(after.detect(runs: [], sessions: [resumed], usage: nil, now: at(100), endedSessions: [stale]).isEmpty)
        // It ends properly, and only the old file is left.
        #expect(after.detect(runs: [], sessions: [], usage: nil, now: at(105), endedSessions: [stale]).isEmpty)
    }

    @Test("Всё упало, сессию продолжили и нормально закрыли: тревога была одна, при запуске") func rebootThenResumed() {
        var before = EventDetector()
        _ = before.detect(runs: [], sessions: [info("s1")], usage: nil, now: t0)
        var after = EventDetector(memory: before.memory)
        let stale = session(id: "s1", pid: 100, status: "busy")
        #expect(after.detect(runs: [], sessions: [], usage: nil, now: at(100), endedSessions: [stale]).map(\.whileAway) == [true])
        let resumed = session(id: "s1", pid: 200, status: "busy")
        #expect(after.detect(runs: [], sessions: [resumed], usage: nil, now: at(110), endedSessions: [stale]).isEmpty)
        #expect(after.detect(runs: [], sessions: [], usage: nil, now: at(120), endedSessions: [stale]).isEmpty)
    }

    @Test("Сессию убили и продолжили, пока Boris был закрыт: когда она нормально закончится, тревоги нет") func resumedWhileClosed() {
        var before = EventDetector()
        _ = before.detect(runs: [], sessions: [info("s1")], usage: nil, now: t0)
        var after = EventDetector(memory: before.memory)
        let stale = session(id: "s1", pid: 100, status: "busy")
        let resumed = session(id: "s1", pid: 200, status: "busy")
        #expect(after.detect(runs: [], sessions: [resumed], usage: nil, now: at(100), endedSessions: [stale]).isEmpty)
        #expect(after.detect(runs: [], sessions: [], usage: nil, now: at(110), endedSessions: [stale]).isEmpty)
    }

    @Test("Продолженную сессию убили снова: это новая потеря") func killedAgain() {
        var detector = EventDetector()
        _ = detector.detect(runs: [], sessions: [info("s1")], usage: nil, now: t0)
        let stale = session(id: "s1", pid: 100, status: "busy")
        let resumed = session(id: "s1", pid: 200, status: "busy")
        _ = detector.detect(runs: [], sessions: [], usage: nil, now: at(5), endedSessions: [stale])
        _ = detector.detect(runs: [], sessions: [resumed], usage: nil, now: at(10), endedSessions: [stale])
        #expect(detector.detect(runs: [], sessions: [], usage: nil, now: at(15), endedSessions: [stale, resumed]).map(\.id) == ["ended|s1|200"])
    }

    @Test("Старый файл состояния, где этой памяти ещё нет, читается") func oldState() throws {
        let old = #"{"notified":[],"activeRuns":{},"usageFired":[],"usageSeen":{},"limitFired":{}}"#
        let memory = try JSONDecoder().decode(DetectorMemory.self, from: Data(old.utf8))
        #expect(memory.liveSessions == nil)
    }
}

@Suite("Звуки")
struct NotificationSoundTests {
    @Test("Один и тот же звук не чаще раза в 10 секунд") func gap() {
        var limiter = SoundLimiter()
        let answers = [t0, at(9.9), at(10), at(15)].map { limiter.allow(.done, now: $0) }
        #expect(answers == [true, false, true, false])
    }

    @Test("Разные звуки друг другу не мешают") func different() {
        var limiter = SoundLimiter()
        let answers = [WalrusSound.done, .alarm].map { limiter.allow($0, now: t0) }
        #expect(answers == [true, true])
    }

    @Test("Пять агентов завершились за несколько секунд: звук один") func series() {
        var router = NotificationRouter()
        var played: [WalrusSound] = []
        for second in 0..<5 {
            played += sounds(router.route([item(finished(second))], now: at(Double(second))))
        }
        #expect(played == [.done])
    }

    @Test("Серия дольше десяти секунд звучит снова, но редко") func longSeries() {
        var router = NotificationRouter()
        var count = 0
        for second in stride(from: 0, to: 31, by: 2) {
            count += sounds(router.route([item(finished(second))], now: at(Double(second)))).count
        }
        #expect(count == 4)
    }

    @Test("Звук зависит от события", arguments: [
        (EventKind.waiting, WalrusSound.wait), (.completed, .done), (.sessionFinished, .done), (.failed, .alarm),
        (.interrupted, .alarm), (.stopped, .hmm), (.silent, .hmm), (.limitReached, .tired), (.limitNear, .tired),
    ] as [(EventKind, WalrusSound)])
    func soundOfEvent(kind: EventKind, sound: WalrusSound) {
        #expect(WalrusSound(for: kind) == sound)
    }

    @Test("Каждому звуку есть файл, и он читается") func files() {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Sounds")
        for sound in WalrusSound.allCases {
            let file = folder.appendingPathComponent("\(sound.rawValue).caf")
            let player = NSSound(contentsOf: file, byReference: false)
            #expect((player?.duration ?? 0) > 0, "\(sound)")
        }
    }
}

/// How the app combines these pieces during do not disturb.
@Suite("Режим «не беспокоить»")
struct QuietNotificationTests {
    private func pass(_ events: [BorisEvent], quiet: inout QuietMode, preferences: NotificationPreferences, router: inout NotificationRouter, now: Date) -> [NotificationDelivery] {
        let on = quiet.isOn(now: now)
        let items = events.map { event -> NotificationRouter.Item in
            let wanted = preferences.reaction(for: event, mood: .alarm)
            return item(event, quiet.filter(wanted, kind: event.kind, now: now), telegram: preferences.wantsTelegram(event, quiet: on))
        }
        return router.route(items, now: now)
    }

    private var withBot: NotificationPreferences {
        var preferences = NotificationPreferences()
        preferences.telegramChat = "1"
        return preferences
    }

    @Test("Запрос в режиме: ни уведомления, ни звука, а Telegram приходит") func requestDuringQuiet() {
        var quiet = QuietMode()
        var router = NotificationRouter()
        quiet.start(for: 3600, now: t0)
        let delivered = pass([request()], quiet: &quiet, preferences: withBot, router: &router, now: at(10))
        #expect(banners(delivered).isEmpty)
        #expect(sounds(delivered).isEmpty)
        #expect(telegrams(delivered).count == 1)
    }

    @Test("Telegram можно отключить на время режима отдельно") func telegramOffDuringQuiet() {
        var preferences = withBot
        preferences.telegramDuringQuiet = false
        var quiet = QuietMode()
        var router = NotificationRouter()
        quiet.start(for: 3600, now: t0)
        #expect(pass([request()], quiet: &quiet, preferences: preferences, router: &router, now: at(10)).isEmpty)
        // Once the mode is over, it comes again.
        #expect(telegrams(pass([request(id: "r2")], quiet: &quiet, preferences: preferences, router: &router, now: at(4000))).count == 1)
    }

    @Test("В режиме морж не реагирует") func walrusStill() {
        var quiet = QuietMode()
        quiet.start(for: 3600, now: t0)
        #expect(quiet.filter(Reaction(banner: true, sound: true, mood: .alarm), kind: .failed, now: at(1)).mood == .none)
        var board = MoodBoard()
        board.apply(BorisEvent(id: "e", kind: .failed, at: at(1)), reaction: quiet.filter(Reaction(banner: true, sound: true, mood: .alarm), kind: .failed, now: at(1)).mood, now: at(1))
        #expect(!board.hasAlarm)
    }

    @Test("Запрос в режиме остаётся в очереди и счётчике: они считаются по работе, а не по событиям") func requestStaysInQueue() {
        let waiting = WorkSession(id: "s1", state: .waiting, waitingFor: .permission(tool: "Bash"), root: WorkNode(id: "s1", kind: .main, state: .waiting))
        let work = WorkModel(projects: [WorkProject(path: "/x/p", sessions: [waiting])])
        var quiet = QuietMode()
        quiet.start(for: 3600, now: t0)
        _ = quiet.filter(Reaction(banner: true, sound: true, mood: .watching), kind: .waiting, now: at(1))
        #expect(quiet.missed == [.waiting: 1])
        #expect(work.waitingSessions.map(\.id) == ["s1"])
        // Nothing about the waiting state depends on the mode: the walrus still shows the request.
        #expect(MoodBoard().mood(work: work, broken: false, matrix: ReactionMatrix(), now: at(1)) == .waiting)
    }

    @Test("Режим закончился сам: одна сводка") func endsByItself() {
        var quiet = QuietMode()
        quiet.start(for: 3600, now: t0)
        var router = NotificationRouter()
        _ = pass([request(), finished(1), finished(2)], quiet: &quiet, preferences: withBot, router: &router, now: at(10))
        #expect(quiet.finish(now: at(100)) == nil)
        #expect(quiet.finish(now: at(3600)) == [.waiting: 1, .completed: 2])
        #expect(quiet.finish(now: at(3700)) == nil)
    }

    @Test("Режим выключили руками: сводка тоже приходит, иначе «до выключения» её бы не дождался") func endsByHand() {
        var quiet = QuietMode()
        quiet.start(for: QuietMode.indefinitely, now: t0)
        _ = quiet.filter(on, kind: .failed, now: at(10))
        #expect(quiet.cancel() == [.failed: 1])
        #expect(!quiet.isOn(now: at(11)))
        #expect(quiet.cancel() == nil)
        #expect(quiet.finish(now: at(12)) == nil)
    }

    @Test("Ничего не случилось: сводки нет") func nothingMissed() {
        var quiet = QuietMode()
        quiet.start(for: 60, now: t0)
        #expect(quiet.cancel() == nil)
    }

    @Test("Выключенное событие не считается пропущенным") func offIsNotMissed() {
        var preferences = NotificationPreferences()
        preferences.channels[.silence] = ChannelChoice(mac: false, sound: false, telegram: false)
        var quiet = QuietMode()
        quiet.start(for: 60, now: t0)
        let event = BorisEvent(id: "e", kind: .silent, at: t0)
        _ = quiet.filter(preferences.reaction(for: event, mood: .none), kind: .silent, now: at(1))
        #expect(quiet.missed.isEmpty)
    }

    @Test("Режим закончился, пока Boris был закрыт: сводка приходит при запуске") func endedWhileClosed() throws {
        var quiet = QuietMode()
        quiet.start(for: 60, now: t0)
        _ = quiet.filter(on, kind: .failed, now: at(10))
        var loaded = try JSONDecoder().decode(QuietMode.self, from: JSONEncoder().encode(quiet))
        #expect(loaded.finish(now: at(5000)) == [.failed: 1])
    }

    @Test("«До выключения» остаётся включённым очень надолго") func untilOff() {
        var quiet = QuietMode()
        quiet.start(for: QuietMode.indefinitely, now: t0)
        #expect(quiet.isOn(now: at(365 * 24 * 3600)))
    }
}
