import AppKit
import BorisCore
import UserNotifications

/// Puts banners on the screen. In a snapshot nothing must reach the person's notifications, so it is a separate piece.
@MainActor
protocol BannerPosting: AnyObject {
    var onClick: ((NotificationRoute) -> Void)? { get set }
    var onPermissionChange: ((_ denied: Bool) -> Void)? { get set }
    func refreshPermission()
    func post(_ banner: MacBanner)
    func remove(ids: [String])
}

@MainActor
final class NoBanners: BannerPosting {
    var onClick: ((NotificationRoute) -> Void)?
    var onPermissionChange: ((Bool) -> Void)?
    /// What would have reached the person, for a test to look at.
    private(set) var posted: [MacBanner] = []
    func refreshPermission() {}
    func post(_ banner: MacBanner) {
        posted.append(banner)
        AppLog.note(.bannerSent, banner.about)
    }

    func remove(ids: [String]) {}
}

/// Mac notifications. Sound is not asked for here: it can be on while banners are off, so it goes through `Voice`.
@MainActor
final class BannerChannel: NSObject, BannerPosting, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private var askedThisLaunch = false
    var onClick: ((NotificationRoute) -> Void)?
    var onPermissionChange: ((Bool) -> Void)?

    override init() {
        super.init()
        center.delegate = self
    }

    /// The notification center crashes outside an app bundle, which is how debug tools run.
    static var canRun: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    func refreshPermission() {
        Task {
            var status = await center.notificationSettings().authorizationStatus
            // A request that never got an answer is not a refusal: ask again once per launch.
            if status == .notDetermined, !askedThisLaunch {
                askedThisLaunch = true
                _ = try? await center.requestAuthorization(options: [.alert])
                status = await center.notificationSettings().authorizationStatus
            }
            onPermissionChange?(status == .denied)
        }
    }

    func post(_ banner: MacBanner) {
        let content = UNMutableNotificationContent()
        content.title = banner.title
        content.body = banner.body
        content.threadIdentifier = "boris"
        content.userInfo = banner.route.userInfo
        let about = banner.about
        center.add(UNNotificationRequest(identifier: banner.id, content: content, trigger: nil)) { error in
            if let error {
                AppLog.note(.bannerFailed, about, .failure(error))
            } else {
                AppLog.note(.bannerSent, about)
            }
        }
    }

    func remove(ids: [String]) {
        center.removeDeliveredNotifications(withIdentifiers: ids)
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        let route = NotificationRoute(userInfo: response.notification.request.content.userInfo)
        await MainActor.run {
            if let route { onClick?(route) }
        }
    }
}
