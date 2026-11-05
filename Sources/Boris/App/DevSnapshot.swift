import AppKit
import BorisCore
import BorisData
import SwiftUI

/// For checking screens without clicking. It exists only in debug builds.
@MainActor
enum DevSnapshot {
    static var isRequested: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["BORIS_SNAPSHOT"] != nil || ProcessInfo.processInfo.environment["BORIS_WALRUS_CPU"] != nil
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
        let environment = ProcessInfo.processInfo.environment
        if WalrusDev.measureIfRequested() { return true }
        guard let folder = environment["BORIS_SNAPSHOT"] else { return false }
        if LoadMeasure.runIfRequested() { return true }
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
        case license, offer, preview, waiting, connected, iconNotice, repair, policy, formatChanged, folderMissing
        case walrusThemes, walrusPacks, walrusError, walrusLine, walrusSurfaces
        case notchClosed, notchOpen, panelClosed, panelOpen, surfacesLast, surfacesHotKey, surfacesGone

        var page: AppPage? {
            AppPage(rawValue: rawValue)
        }

        var section: SettingsSection? {
            if self == .license { return .about }
            if self == .surfacesLast || self == .surfacesHotKey || self == .surfacesGone { return .surfaces }
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
        if let page = screen.page { model.page = page }
        if let section = screen.section { model.settingsSection = section }

        let view: AnyView
        var canvas = size ?? CGSize(width: 1200, height: 800)
        switch screen {
        case .mini:
            view = AnyView(MiniWindowView(model: model, openMain: {}))
            canvas = CGSize(width: 360, height: 0)
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
        case .general, .sources, .surfaces, .notifications, .connections, .about, .license, .surfacesLast, .surfacesHotKey, .surfacesGone:
            if screen == .surfacesLast { settings.surfaces = SurfaceSwitches(icon: false, notch: true, mini: false) }
            if screen == .surfacesHotKey {
                settings.surfaces = SurfaceSwitches(icon: true, notch: false, mini: true)
                model.hotKeyTaken = true
            }
            if screen == .surfacesGone { settings.surfaceScreen = .screen(id: "gone", name: "Studio Monitor") }
            view = AnyView(SettingsView(model: model, connect: connect, actions: SettingsActions()))
            canvas = size ?? CGSize(width: 760, height: 720)
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
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.orderBack(nil)
        try? await Task.sleep(for: .seconds(0.25))
        host.layoutSubtreeIfNeeded()
        if let picture = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: picture)
            try? picture.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        window.orderOut(nil)
    }
    #endif
}
