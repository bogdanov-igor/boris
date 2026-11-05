#if DEBUG
import BorisCore
import BorisData
import SwiftUI

/// Banners cannot be shown during a check, so this draws their real texts the way the board shows them.
struct NotificationPreview: View {
    var long: Bool

    private var project: String { long ? "a-very-long-project-name-that-nobody-would-ever-want-to-type-by-hand-more-than-once" : "shop-api" }

    private var events: [BorisEvent] {
        let now = Date()
        return [
            BorisEvent(id: "1", kind: .waiting, at: now, sessionId: "s", project: project, toolName: "Bash", environment: .vsCode),
            BorisEvent(id: "2", kind: .waiting, at: now, sessionId: "s", project: project, toolName: "AskUserQuestion", environment: .terminal),
            BorisEvent(id: "3", kind: .waiting, at: now, sessionId: "s", project: project, toolName: "ExitPlanMode", environment: .cursor),
            BorisEvent(id: "4", kind: .completed, at: now, sessionId: "s", project: "landing", agentsTotal: 4, durationMs: 720_000),
            BorisEvent(id: "5", kind: .limitReached, at: now, project: project, agentsFailed: 12, resets: "18:40"),
            BorisEvent(id: "6", kind: .allAgentsFailed, at: now, sessionId: "s", project: project, agentsTotal: 3, agentsFailed: 3, topFailure: .api),
            BorisEvent(id: "7", kind: .interrupted, at: now, sessionId: "s", project: project),
            BorisEvent(id: "8", kind: .silent, at: now, sessionId: "s", project: project),
            BorisEvent(id: "9", kind: .limitNear, at: now, windowId: "five_hour", percent: 90),
        ]
    }

    private var summaries: [MacBanner] {
        var router = NotificationRouter()
        let on = Reaction(banner: true, sound: false, mood: .none)
        let now = Date()
        let finished = (1...5).map { BorisEvent(id: "w\($0)", kind: .completed, at: now, project: "project-\($0)") }
        let away = ["boris", "deploy-tools"].map { BorisEvent(id: $0, kind: .interrupted, at: now, sessionId: $0, project: $0, whileAway: true) }
        let delivered = router.route((finished + away).map { .init(event: $0, reaction: on, telegram: false) }, now: now)
        var banners: [MacBanner] = delivered.compactMap {
            if case .banner(let banner) = $0 { return banner }
            return nil
        }
        banners.append(NotificationWords.quietSummary(missed: [.waiting: 3, .failed: 1, .completed: 2], requestsWaiting: 1))
        return banners
    }

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .trailing, spacing: 10) {
                ForEach(Array((events.map(NotificationWords.banner) + summaries).enumerated()), id: \.offset) { _, banner in
                    bannerView(banner)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array((events.map(NotificationWords.telegram) + [NotificationWords.telegramTest]).enumerated()), id: \.offset) { _, line in
                    (Text(line.subject).bold() + Text(" · \(line.text)"))
                        .font(.system(size: 13))
                        .frame(maxWidth: 290, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.fill2))
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.window)
        .foregroundStyle(Palette.text1)
    }

    private func bannerView(_ banner: MacBanner) -> some View {
        HStack(alignment: .top, spacing: 10) {
            WalrusView(mood: .waiting, outfit: .none, size: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(banner.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(banner.body).font(.system(size: 12.5)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 360, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Palette.pop))
    }
}

/// The states of the notification settings for a snapshot.
@MainActor
enum NotificationSnapshots {
    static func prepare(_ screen: String, model: AppModel) {
        switch screen {
        case "notificationsQuiet":
            model.startQuiet(for: 3600)
        case "notificationsBot":
            model.settings.notifications.telegramChat = "1234567"
            model.notifications.showForSnapshot(telegram: .init(at: Date(), problem: nil, wasTest: true))
        case "notificationsOffline":
            model.settings.notifications.telegramChat = "1234567"
            model.notifications.showForSnapshot(macDenied: true, telegram: .init(at: Date(), problem: .noConnection, wasTest: false))
        case "notificationsConnect":
            model.notifications.showForSnapshot(formOpen: true)
        case "quietRequests":
            model.startQuiet(for: 3600)
        default:
            break
        }
    }
}
#endif
