import AppKit
import BorisCore
import SwiftUI

extension AppPage {
    var speedPlace: SpeedPlace {
        switch self {
        case .now: return .now
        case .projects: return .projects
        case .spend: return .spend
        case .requests: return .requests
        case .activity: return .activity
        case .losses: return .losses
        case .walrus: return .walrus
        }
    }
}

extension ProjectsRoute {
    var speedPlace: SpeedPlace {
        switch self {
        case .list: return .projects
        case .project: return .project
        case .session: return .session
        }
    }
}

extension SettingsSection {
    var speedPlace: SpeedPlace {
        switch self {
        case .general: return .settingsGeneral
        case .sources: return .settingsSources
        case .surfaces: return .settingsSurfaces
        case .notifications: return .settingsNotifications
        case .connections: return .settingsConnections
        case .log: return .settingsLog
        case .about: return .settingsAbout
        }
    }
}

extension View {
    /// Tells the speed log that this page is on screen, so that the click that led here is timed until it is drawn.
    func speedPlace(_ place: SpeedPlace) -> some View {
        onAppear { SpeedLog.appeared(place) }
    }
}

/// Starts timing what the person does. Only the app itself does this, together with its log.
@MainActor
enum SpeedWatch {
    private static var monitor: Any?

    static func start() {
        MainThreadWatch.start()
        guard monitor == nil else { return }
        // Before any button hears the click, so the time starts where the person's does.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp, .keyDown]) { event in
            SpeedLog.began(event.type == .keyDown ? .key : .click)
            return event
        }
    }
}
