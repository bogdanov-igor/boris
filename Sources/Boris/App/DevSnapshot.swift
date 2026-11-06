import AppKit
import BorisCore
import BorisData
import SwiftUI

/// For checking screens without clicking. It exists only in debug builds.
@MainActor
enum DevSnapshot {
    static var isRequested: Bool {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        return environment["BORIS_SNAPSHOT"] != nil || environment["BORIS_WALRUS_CPU"] != nil || environment["BORIS_FEED_CHECK"] != nil
        #else
        false
        #endif
    }

    /// Without this, a check whose mode this build does not know would quietly start the real app: windows on the
    /// person's screen, their settings, their Claude folder. That has happened. A debug build has to be told.
    static var mayStartForReal: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["BORIS_ALLOW_UI"] == "1"
        #else
        true
        #endif
    }

    /// Snapshots of other debug builds come and go under the same bundle id, and they are not another Boris to give way to.
    static var ignoresOtherCopies: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["BORIS_ALLOW_UI"] == "1"
        #else
        false
        #endif
    }

    static var isSmoke: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["BORIS_SMOKE"] != nil
        #else
        false
        #endif
    }

    /// `BORIS_SMOKE=1` reports whether the app came up, and quits.
    static func smokeIfRequested(statusBar: StatusBarController, model: AppModel) {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["BORIS_SMOKE"] != nil else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            print("icon visible: \(statusBar.isIconVisible), loaded: \(model.loaded), sessions: \(model.work.sessions.count), mood: \(model.mood), hooks: \(model.hooks.connection), bundle: \(Bundle.main.bundleIdentifier ?? "none")")
            exit(model.loaded ? 0 : 1)
        }
        #endif
    }

    /// `BORIS_SNAPSHOT=/folder` renders the screens and quits. Each of `BORIS_SCREEN`, `BORIS_THEME`, `BORIS_MODE`, `BORIS_LANGUAGE`
    /// and `BORIS_DATA` takes a comma-separated list. Without one, every screen goes in both themes, modes and languages on the busy data.
    /// `BORIS_SIZE=WIDTHxHEIGHT` sets the size of the windows that have one.
    static func runIfRequested() -> Bool {
        #if DEBUG
        if DevFeedCheck.runIfRequested() { return true }
        let environment = ProcessInfo.processInfo.environment
        if WalrusDev.measureIfRequested() { return true }
        guard let folder = environment["BORIS_SNAPSHOT"] else { return false }
        if LoadMeasure.runIfRequested() { return true }
        if AppMeasure.runIfRequested() { return true }
        if DevUpdateCheck.runIfRequested() { return true }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        func list(_ key: String, _ all: [String]) -> [String] {
            environment[key].map { $0.split(separator: ",").map(String.init) } ?? all
        }
        let screens = list("BORIS_SCREEN", Screen.allCases.map(\.rawValue)).compactMap(Screen.init(rawValue:))
        let themes = list("BORIS_THEME", ["dark", "light"]).compactMap(ThemeMode.init(rawValue:))
        let modes = list("BORIS_MODE", ["simple", "technical"]).compactMap(DisplayMode.init(rawValue:))
        let languages = list("BORIS_LANGUAGE", ["ru", "en"]).compactMap(AppLanguage.init(rawValue:))
        let sets = list("BORIS_DATA", ["busy"]).compactMap(DevData.init(rawValue:))
        let size = environment["BORIS_SIZE"].flatMap { text -> CGSize? in
            let parts = text.split(separator: "x").compactMap { Double($0) }
            return parts.count == 2 ? CGSize(width: parts[0], height: parts[1]) : nil
        }

        Task { @MainActor in
            for screen in screens {
                for theme in themes {
                    for mode in modes {
                        for language in languages {
                            for data in sets {
                                let name = [screen.rawValue, theme.rawValue, mode.rawValue, language.rawValue, data.rawValue].joined(separator: "-")
                                await capture(screen, theme: theme, mode: mode, language: language, data: data, size: size, to: "\(folder)/\(name).png")
                            }
                        }
                    }
                }
            }
            exit(0)
        }
        return true
        #else
        return false
        #endif
    }

    #if DEBUG
    private enum Screen: String, CaseIterable {
        case now, projects, spend, requests, activity, losses, walrus, mini, load
        case general, sources, surfaces, notifications, connections, about
        case license, thirdPartyLicenses, offer, preview, waiting, connected, iconNotice, repair, policy, formatChanged, folderMissing
        case updatesCurrent, updatesChecking, updatesAvailable, updatesOffline, updatesNoCheck, updateNotice
        case walrusThemes, walrusPacks, walrusError, walrusLine, walrusSurfaces
        case notchClosed, notchOpen, panelClosed, panelOpen, surfacesLast, surfacesHotKey, surfacesGone
        case lossesReading, lossesFiltered, lossesNothingMatches
        case notificationsQuiet, notificationsBot, notificationsOffline, notificationsConnect, notificationsPreview, quietRequests
        case spendUltra, spendTeam, spendGateway, spendGatewayBudget, spendApiKey, spendExtraOff, spendExtraNoLimit, spendFilling, spendFailed, spendZero, spendAncient
        case spendProjects, spendModels, spendPlaces, spendAgents, spendToday, spendMonth, spendEverything
        case project, projectDates, datesPicker, session, sessionTrouble, sessionPast, sessionGone, bigRun
        case feed, feedWaiting, feedChanges, feedDiff, activityCommands
        case requestCards, requestsNoHooks, nowRequests, miniRequests

        var page: AppPage? {
            if self == .requestsNoHooks { return .requests }
            return DevUsageData.Scenario(rawValue: rawValue) != nil ? .spend : AppPage(rawValue: rawValue)
        }

        var section: SettingsSection? {
            if self == .license || self == .thirdPartyLicenses { return .about }
            if rawValue.hasPrefix("updates") { return .general }
            if self == .surfacesLast || self == .surfacesHotKey || self == .surfacesGone { return .surfaces }
            if rawValue.hasPrefix("notifications"), self != .notificationsPreview { return .notifications }
            return SettingsSection(rawValue: rawValue)
        }
    }

    private static func capture(_ screen: Screen, theme: ThemeMode, mode: DisplayMode, language: AppLanguage, data: DevData, size: CGSize?, to path: String) async {
        let settings = AppSettings(defaults: nil)
        settings.theme = theme
        settings.language = language
        settings.displayMode = mode
        let model = AppModel(settings: settings, store: nil, live: false)
        let connect = ConnectFlow()
        data.fill(model)
        WalrusDev.dress(model)
        NotificationSnapshots.prepare(screen.rawValue, model: model)
        DevUsageData.Scenario(rawValue: screen.rawValue)?.fill(model)
        if let page = screen.page { model.page = page }
        if let section = screen.section { model.settingsSection = section }
        if [.requests, .requestCards, .nowRequests, .miniRequests, .notchOpen, .panelOpen].contains(screen) { RequestDevData.fill(model, data: data) }

        let view: AnyView
        var canvas = size ?? CGSize(width: 1200, height: 800)
        switch screen {
        case .mini, .miniRequests:
            view = AnyView(MiniWindowView(model: model, openMain: {}))
            canvas = CGSize(width: 360, height: 0)
        case .requestCards:
            view = AnyView(RequestCardsSheet(model: model))
            canvas = size ?? CGSize(width: 1320, height: 0)
        case .load:
            view = AnyView(LoadGallery(model: model))
            canvas = CGSize(width: size?.width ?? 1060, height: 0)
        case .walrusSurfaces:
            view = AnyView(WalrusDev.surfaces(model))
            canvas = CGSize(width: 720, height: 280)
        case .notchClosed, .notchOpen, .panelClosed, .panelOpen:
            data.fillForSurface(model)
            canvas = size ?? CGSize(width: 1100, height: screen == .notchClosed || screen == .panelClosed ? 90 : 640)
            view = AnyView(SurfacePreview(model: model, hasNotch: screen == .notchClosed || screen == .notchOpen, isOpen: screen == .notchOpen || screen == .panelOpen, canvas: canvas))
        case .notificationsPreview:
            view = AnyView(NotificationPreview(long: data == .long))
            canvas = size ?? CGSize(width: 800, height: 1040)
        case .datesPicker:
            model.projectFilter.period = .dates(from: Date().addingTimeInterval(-10 * 86400), to: Date())
            view = AnyView(ProjectDatesPicker(model: model).background(Palette.pop))
            canvas = CGSize(width: 240, height: 0)
        case .license, .thirdPartyLicenses:
            view = AnyView(AboutSection(model: model, opening: screen == .license ? .own : .thirdParty).background(Palette.window).foregroundStyle(Palette.text1))
            canvas = size ?? CGSize(width: 570, height: 720)
        case .general, .sources, .surfaces, .notifications, .connections, .about, .updatesCurrent, .updatesChecking, .updatesAvailable, .updatesOffline, .updatesNoCheck, .surfacesLast, .surfacesHotKey, .surfacesGone, .notificationsQuiet, .notificationsBot, .notificationsOffline, .notificationsConnect:
            model.updates.prepareForSnapshot(screen.rawValue, long: data == .long)
            if screen == .surfacesLast { settings.surfaces = SurfaceSwitches(icon: false, notch: true, mini: false) }
            if screen == .surfacesHotKey {
                settings.surfaces = SurfaceSwitches(icon: true, notch: false, mini: true)
                model.hotKeyTaken = true
            }
            if screen == .surfacesGone { settings.surfaceScreen = .screen(id: "gone", name: "Studio Monitor") }
            view = AnyView(SettingsView(model: model, connect: connect, actions: SettingsActions()))
            canvas = size ?? CGSize(width: 760, height: 720)
        case .feed:
            view = DevFeedScreens.feed(model)
            canvas = size ?? CGSize(width: 609, height: 720)
        case .feedWaiting:
            view = DevFeedScreens.feed(model, id: "a1")
            canvas = size ?? CGSize(width: 609, height: 300)
        case .feedChanges:
            view = DevFeedScreens.changes(model)
            canvas = size ?? CGSize(width: 380, height: 240)
        case .feedDiff:
            view = DevFeedScreens.diff(model)
            canvas = size ?? CGSize(width: 760, height: 560)
        case .activityCommands:
            view = DevFeedScreens.commands(model)
            canvas = size ?? CGSize(width: 989, height: 400)
        default:
            switch screen {
            case .offer:
                data.fill(model, offer: true)
            case .preview:
                connect.stage = .preview(HookInstaller.Preview(lines: ["+   \"hooks\" : {", "+     \"PermissionRequest\" : [ … boris-hook … ],", "+     \"PreToolUse\" : [ … boris-hook … ],", "+   }"], reformats: true))
            case .waiting:
                connect.stage = .waiting(since: Date())
            case .connected:
                connect.stage = .connected
            case .iconNotice:
                model.showIconNotice = true
            case .updateNotice:
                model.updates.prepareForSnapshot(screen.rawValue, long: data == .long)
            case .repair:
                settings.hooksWanted = true
                model.hooks.showForSnapshot(status: .notInstalled)
            case .policy:
                model.hooks.showForSnapshot(status: .disabledByPolicy)
            case .formatChanged:
                data.fill(model, issues: [.unknownJournalEvent("x")])
            case .folderMissing:
                data.fill(model, folderFound: false)
            case .walrusThemes, .walrusPacks, .walrusError, .walrusLine:
                WalrusDev.prepare(screen.rawValue, model: model, long: data == .long, empty: data == .empty)
            case .walrus:
                WalrusDev.prepare("walrus", model: model, long: data == .long, empty: data == .empty)
            case .lossesReading:
                model.page = .losses
                model.losses.showProgressForSnapshot(done: 640, total: 2263)
            case .lossesFiltered:
                model.page = .losses
                model.losses.kind = .toolError
                model.losses.project = "boris"
            case .lossesNothingMatches:
                model.page = .losses
                model.losses.kind = .denied
                model.losses.project = "shop-api"
            case .project:
                model.openProject("/x/shop-api")
                if data == .long { model.openProject(model.work.projects.first?.path) }
            case .projectDates:
                model.openProject("/x/shop-api")
                model.projectFilter.period = .dates(from: Date().addingTimeInterval(-3.5 * 86400), to: Date().addingTimeInterval(-86400))
            case .session:
                model.openSession(DevProjects.working)
            case .sessionTrouble:
                model.openSession(DevProjects.troubled)
            case .sessionPast:
                model.openSession(DevProjects.pastBroken)
            case .sessionGone:
                model.openSession("no-such-session")
            case .bigRun:
                DevData.big.fill(model)
                model.openSession(DevProjects.big)
                let phases = model.session(DevProjects.big)?.root.children.first?.phases ?? []
                model.expandedPhases = Set(phases.map { AgentTree.phaseKey(workflow: "wf_big", phase: $0.title) })
            default:
                break
            }
            view = AnyView(MainWindowView(model: model, connect: connect, openSettings: { _ in }))
        }

        let host = NSHostingView(rootView: view.frame(width: canvas.width, height: canvas.height > 0 ? canvas.height : nil))
        host.appearance = theme.appearance
        let fitting = host.fittingSize
        let bounds = NSRect(x: 0, y: 0, width: canvas.width, height: canvas.height > 0 ? canvas.height : fitting.height)
        let window = NSWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.contentView = host
        host.frame = bounds
        let measuring = ProcessInfo.processInfo.environment["BORIS_MEASURE_SCROLL"] != nil
        if measuring { print(String(format: "first layout: %.1f ms", milliseconds { host.layoutSubtreeIfNeeded() })) }
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.orderBack(nil)
        try? await Task.sleep(for: .seconds(0.25))
        // `BORIS_SWITCH_LANGUAGE=1` changes the language with the window open, as the setting does.
        if ProcessInfo.processInfo.environment["BORIS_SWITCH_LANGUAGE"] != nil {
            settings.language = language == .ru ? .en : .ru
            try? await Task.sleep(for: .seconds(0.25))
        }
        host.layoutSubtreeIfNeeded()
        if let picture = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: picture)
            try? picture.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        if measuring { await measureScroll(in: host, model: model) }
        window.orderOut(nil)
    }

    private static func milliseconds(_ work: () -> Void) -> Double {
        let cost = ContinuousClock().measure(work)
        return Double(cost.components.attoseconds) / 1e15 + Double(cost.components.seconds) * 1000
    }

    /// `BORIS_MEASURE_SCROLL=1` goes down the first long list one step at a time and says what each step cost: a frame at 60 Hz has 16 ms.
    /// Then it changes what every row depends on, as a new scan does, and says what that cost.
    private static func measureScroll(in host: NSView, model: AppModel) async {
        func scrollViews(in view: NSView) -> [NSScrollView] {
            ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews)
        }
        guard let scroll = scrollViews(in: host).first(where: { ($0.documentView?.frame.height ?? 0) > $0.frame.height + 1 }) else {
            print("scroll: nothing long enough to scroll")
            return
        }
        var costs: [Double] = []
        var y: CGFloat = 0
        while y < scroll.documentView?.frame.height ?? 0 {
            costs.append(milliseconds {
                scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                scroll.reflectScrolledClipView(scroll.contentView)
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
            })
            y += 40
            // Lets the lazy list bring in what has just come into view, as a real run of the main loop would.
            try? await Task.sleep(for: .milliseconds(2))
        }
        costs.sort()
        let average = costs.reduce(0, +) / Double(max(costs.count, 1))
        let height = scroll.documentView?.frame.height ?? 0
        print(String(format: "scroll: list %.0f pt, %d steps, average %.2f ms, 95%% %.2f ms, worst %.2f ms", height, costs.count, average, costs[costs.count * 95 / 100], costs.last ?? 0))
        var updates: [Double] = []
        for index in 0..<10 {
            updates.append(milliseconds {
                model.feedAgent = "agent-\(index)"
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
            })
            try? await Task.sleep(for: .milliseconds(20))
        }
        print(String(format: "update of every row: worst %.1f ms", updates.max() ?? 0))
    }
    #endif
}
