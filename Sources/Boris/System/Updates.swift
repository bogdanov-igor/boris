import AppKit
import Foundation
import Network
import Observation
import Sparkle

/// A newer version the appcast offers.
struct UpdateOffer: Equatable {
    var version: String
    var notes: URL?
}

enum UpdateStatus: Equatable {
    /// Nothing to say yet. An automatic check that could not reach the network leaves it like this, on purpose.
    case unknown
    case checking
    case upToDate
    case available(UpdateOffer)
    /// The person pressed the button and the check did not get through. It is a remark, not a failure of anything.
    case unreachable
}

/// What Boris needs from whatever fetches updates. Sparkle in a released copy, a fake in tests.
@MainActor
protocol UpdateEngine: AnyObject {
    var checksAutomatically: Bool { get set }
    var onStatus: ((UpdateStatus) -> Void)? { get set }
    /// - Returns: false if it could not start, and then nothing will ever be checked.
    func start() -> Bool
    /// A quiet look at the appcast, with no window.
    /// - Returns: false if it cannot look right now.
    func checkNow() -> Bool
    /// Sparkle's own window, with the release notes and the buttons. The download starts only from there.
    func showUpdate()
}

/// Whether a build was made to update itself. `scripts/release.sh` writes both values into the app, and nothing else does.
struct UpdateConfiguration: Equatable {
    var feed: String
    var publicKey: String

    init?(info: [String: Any]) {
        guard let feed = info["SUFeedURL"] as? String, !feed.isEmpty,
              let publicKey = info["SUPublicEDKey"] as? String, !publicKey.isEmpty
        else { return nil }
        self.feed = feed
        self.publicKey = publicKey
    }
}

/// When to look again after an automatic check failed. The system says at once what the connection is now,
/// so a check that failed with the network up, on a server error, must not turn into a loop.
struct RetryWhenOnline {
    private var wasOffline = false

    /// - Returns: true when the connection has just come back.
    mutating func pathChanged(online: Bool) -> Bool {
        guard online else {
            wasOffline = true
            return false
        }
        defer { wasOffline = false }
        return wasOffline
    }
}

/// What the screens show about updates. Debug builds and copies built by hand have no engine, so they never reach for the network.
@MainActor
@Observable
final class Updates {
    private(set) var status = UpdateStatus.unknown
    private(set) var checksAutomatically = false
    private(set) var canCheck: Bool
    @ObservationIgnored private let engine: (any UpdateEngine)?

    init(engine: (any UpdateEngine)?) {
        self.engine = engine
        canCheck = engine != nil
        checksAutomatically = engine?.checksAutomatically ?? false
        engine?.onStatus = { [weak self] status in self?.status = status }
    }

    /// Debug builds have no check of any kind, whatever the bundle says.
    static func forThisBuild(info: [String: Any] = Bundle.main.infoDictionary ?? [:]) -> Updates {
        #if DEBUG
        Updates(engine: nil)
        #else
        Updates(engine: UpdateConfiguration(info: info) == nil ? nil : SparkleEngine())
        #endif
    }

    func start() {
        guard let engine else { return }
        canCheck = engine.start()
    }

    func setChecksAutomatically(_ on: Bool) {
        guard let engine else { return }
        engine.checksAutomatically = on
        checksAutomatically = engine.checksAutomatically
    }

    func checkNow() {
        guard let engine, canCheck else { return }
        if engine.checkNow() { status = .checking }
    }

    func install() {
        engine?.showUpdate()
    }

    /// The version on the banner. Nil when there is nothing to offer.
    var offer: UpdateOffer? {
        if case .available(let offer) = status { return offer }
        return nil
    }

    #if DEBUG
    /// Every state of the group and the banner, with invented versions. Without a matching screen it stays what a debug build really is.
    func prepareForSnapshot(_ screen: String, long: Bool) {
        let offer = UpdateOffer(version: long ? "12.345.6789-beta.42+20261106" : "1.1", notes: URL(string: "https://example.com/notes"))
        let shown: UpdateStatus?
        switch screen {
        case "updatesCurrent": shown = .upToDate
        case "updatesChecking": shown = .checking
        case "updatesAvailable", "updateNotice": shown = .available(offer)
        case "updatesOffline": shown = .unreachable
        default: shown = nil
        }
        guard let shown else { return }
        status = shown
        canCheck = true
        checksAutomatically = true
    }
    #endif
}

/// Sparkle, set up so that the check carries nothing about the person: no system profile and no parameters, only the appcast's own address.
@MainActor
final class SparkleEngine: NSObject, UpdateEngine {
    var onStatus: ((UpdateStatus) -> Void)?
    private var updater: SPUUpdater?
    private var driver: SPUUserDriver?
    private var connection: NWPathMonitor?
    private var retry = RetryWhenOnline()
    #if DEBUG
    /// For the check off screen: an automatic check says nothing in the interface, so only this shows it has ended.
    var onCycleFinished: ((SPUUpdateCheck, (any Error)?) -> Void)?
    var sendsProfile: Bool { updater?.sendsSystemProfile ?? false }
    #endif

    /// - Parameters:
    ///   - host: the app whose Info.plist holds the feed and the key.
    ///   - driver: nil is Sparkle's own window. A check off screen passes one that shows nothing.
    init(host: Bundle = .main, driver: SPUUserDriver? = nil) {
        super.init()
        let driver = driver ?? SPUStandardUserDriver(hostBundle: host, delegate: self)
        self.driver = driver
        updater = SPUUpdater(hostBundle: host, applicationBundle: host, userDriver: driver, delegate: self)
    }

    var checksAutomatically: Bool {
        get { updater?.automaticallyChecksForUpdates ?? false }
        set { updater?.automaticallyChecksForUpdates = newValue }
    }

    func start() -> Bool {
        guard let updater else { return false }
        updater.sendsSystemProfile = false
        // A bad setup must not greet the person with Sparkle's alert: the settings then say this copy does not check.
        return (try? updater.start()) != nil
    }

    func checkNow() -> Bool {
        guard let updater, updater.canCheckForUpdates, !updater.sessionInProgress else { return false }
        updater.checkForUpdateInformation()
        return true
    }

    func showUpdate() {
        updater?.checkForUpdates()
    }

    private func offer(_ item: SUAppcastItem) -> UpdateOffer {
        UpdateOffer(version: item.displayVersionString, notes: item.releaseNotesURL ?? item.fullReleaseNotesURL ?? item.infoURL)
    }

    /// With no connection, Sparkle would wait for the next day's check. The spec says to look as soon as the connection is back.
    private func retryWhenOnline() {
        guard connection == nil else { return }
        retry = RetryWhenOnline()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.pathChanged(online: online) }
        }
        monitor.start(queue: .global(qos: .utility))
        connection = monitor
    }

    private func pathChanged(online: Bool) {
        guard retry.pathChanged(online: online) else { return }
        connection?.cancel()
        connection = nil
        guard let updater, updater.automaticallyChecksForUpdates else { return }
        updater.checkForUpdatesInBackground()
    }
}

extension SparkleEngine: @preconcurrency SPUUpdaterDelegate {
    func feedParameters(for updater: SPUUpdater, sendingSystemProfile sendingProfile: Bool) -> [[String: String]] {
        []
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        onStatus?(.available(offer(item)))
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        onStatus?(.upToDate)
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        #if DEBUG
        defer { onCycleFinished?(updateCheck, error) }
        #endif
        guard let error = error as NSError? else { return }
        func isSparkle(_ code: SUError) -> Bool {
            error.domain == SUSparkleErrorDomain && error.code == Int(code.rawValue)
        }
        // Finding nothing new also ends with an error, and so does the person cancelling.
        if isSparkle(.noUpdateError) || isSparkle(.installationCanceledError) { return }
        if updateCheck == .updatesInBackground {
            // No error to show, and no window: just another try later.
            retryWhenOnline()
        } else {
            onStatus?(.unreachable)
        }
    }
}

extension SparkleEngine: @preconcurrency SPUStandardUserDriverDelegate {
    /// A calm banner instead of a window that jumps up in the middle of someone's work.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        onStatus?(.available(offer(update)))
    }

    /// «Later» or «Skip» in Sparkle's window: the banner goes, and a later check may bring it back.
    func standardUserDriverWillFinishUpdateSession() {
        onStatus?(.unknown)
    }
}
