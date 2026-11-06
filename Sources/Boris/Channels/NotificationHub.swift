import BorisCore
import BorisData
import Foundation
import Observation

/// Takes the events of each scan and hands them to the Mac, the voice and Telegram.
@MainActor
@Observable
final class NotificationHub {
    struct TelegramResult: Equatable {
        var at: Date
        var problem: TelegramProblem?
        var wasTest: Bool
    }

    private(set) var macDenied = false
    private(set) var telegramResult: TelegramResult?
    private(set) var telegramBusy = false
    /// Open while the person is typing the token and the recipient.
    var telegramFormOpen = false
    var onOpen: ((NotificationRoute) -> Void)?

    private let settings: AppSettings
    private let live: Bool
    @ObservationIgnored private let banners: any BannerPosting
    @ObservationIgnored private let voice = Voice()
    @ObservationIgnored private var telegram: TelegramChannel?
    @ObservationIgnored private var router = NotificationRouter()
    @ObservationIgnored private var permissionKnown = false

    /// - Parameter live: false reaches nothing outside, as in a snapshot.
    init(settings: AppSettings, live: Bool) {
        let live = live && BannerChannel.canRun
        self.settings = settings
        self.live = live
        banners = live ? BannerChannel() : NoBanners()
        voice.volume = { [settings] in settings.notifications.volume }
        banners.onClick = { [weak self] route in self?.onOpen?(route) }
        banners.onPermissionChange = { [weak self] denied in
            if self?.permissionKnown != true || self?.macDenied != denied { AppLog.note(denied ? .bannersDenied : .bannersAllowed) }
            self?.permissionKnown = true
            self?.macDenied = denied
        }
        guard live else { return }
        let owner = WeakHub(self)
        telegram = TelegramChannel(
            transport: URLSessionTelegramTransport(),
            secret: KeychainSecret(service: "app.boris.Boris.telegram", account: "bot-token")
        ) { problem in
            Task { @MainActor in owner.hub?.telegramResult = TelegramResult(at: Date(), problem: problem, wasTest: false) }
        }
    }

    func refreshPermission() {
        banners.refreshPermission()
    }

    #if DEBUG
    var bannersPostedForCheck: [MacBanner] { (banners as? NoBanners)?.posted ?? [] }
    #endif

    /// What one scan found. `quiet` is whether do not disturb was on during it.
    func scanned(_ events: [(event: BorisEvent, reaction: Reaction)], quiet: Bool, now: Date) {
        let preferences = settings.notifications
        let items = events.map { NotificationRouter.Item(event: $0.event, reaction: $0.reaction, telegram: preferences.wantsTelegram($0.event, quiet: quiet)) }
        perform(router.route(items, now: now))
    }

    func quietEnded(missed: [EventKind: Int], requestsWaiting: Int) {
        banners.post(NotificationWords.quietSummary(missed: missed, requestsWaiting: requestsWaiting))
    }

    private func perform(_ deliveries: [NotificationDelivery]) {
        for delivery in deliveries {
            switch delivery {
            case .banner(let banner): banners.post(banner)
            case .removeBanners(let ids): banners.remove(ids: ids)
            case .sound(let sound): if live { voice.play(sound) }
            case .telegram(let line): sendToTelegram(line)
            }
        }
    }

    private func sendToTelegram(_ line: TelegramLine) {
        let chat = settings.notifications.telegramChat
        guard !chat.isEmpty, let telegram else { return }
        Task { await telegram.send(line, chat: chat) }
    }

    /// For the volume slider: the person asked to hear it.
    func playSample() {
        if live { voice.play(.done) }
    }

    /// Checks the bot with a test message, and keeps it only if that worked. Nil means it is connected.
    func connectTelegram(token: String, chat: String) async -> TelegramProblem? {
        guard let telegram else { return .other }
        telegramBusy = true
        defer { telegramBusy = false }
        let problem = await telegram.connect(token: token, chat: chat, test: NotificationWords.telegramTest)
        if problem == nil, let clean = TelegramAPI.cleanChat(chat) {
            settings.notifications.telegramChat = clean
            telegramFormOpen = false
            telegramResult = TelegramResult(at: Date(), problem: nil, wasTest: true)
        }
        return problem
    }

    func sendTelegramTest() async {
        guard let telegram, !settings.notifications.telegramChat.isEmpty else { return }
        telegramBusy = true
        let problem = await telegram.test(NotificationWords.telegramTest, chat: settings.notifications.telegramChat)
        telegramBusy = false
        telegramResult = TelegramResult(at: Date(), problem: problem, wasTest: true)
    }

    func disconnectTelegram() {
        settings.notifications.telegramChat = ""
        telegramResult = nil
        guard let telegram else { return }
        Task { await telegram.disconnect() }
    }

    #if DEBUG
    func showForSnapshot(macDenied: Bool = false, telegram: TelegramResult? = nil, formOpen: Bool = false) {
        self.macDenied = macDenied
        telegramResult = telegram
        telegramFormOpen = formOpen
    }
    #endif
}

private struct WeakHub: @unchecked Sendable {
    weak var hub: NotificationHub?

    init(_ hub: NotificationHub) {
        self.hub = hub
    }
}
