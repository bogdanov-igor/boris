#if DEBUG
import AppKit
import BorisCore
import BorisData
import SwiftUI

/// `BORIS_SNAPSHOT=/folder BORIS_SPEED_TOUR=1` goes through the pages of the real model off screen, the way a person clicks through them,
/// with the speed log taking every timing, and prints those lines: names from the closed lists and numbers, nothing from the logs.
/// Like `BORIS_APP_MEASURE` it reads the real logs, keeps Boris's own files in `BORIS_STATE_DIR`, and opens no window on screen.
@MainActor
enum SpeedTour {
    /// Keeps what the tour hears, from any thread.
    private final class Heard: LogSink, @unchecked Sendable {
        private let lock = NSLock()
        private var records: [LogRecord] = []

        func write(_ record: LogRecord) {
            guard record.area == .speed else { return }
            lock.withLock { records.append(record) }
        }

        func flush() {}

        var all: [LogRecord] { lock.withLock { records } }
    }

    /// Hears no key and takes no focus.
    private final class SilentWindow: NSWindow {
        override func keyDown(with event: NSEvent) {}
        override func noResponder(for eventSelector: Selector) {}
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private static func window(_ view: some View, size: CGSize) -> NSWindow {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.appearance = NSAppearance(named: .darkAqua)
        let window = SilentWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        return window
    }

    nonisolated private static func say(_ fields: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]), let text = String(data: data, encoding: .utf8) {
            print(text)
            fflush(stdout)
        }
    }

    private static func until(seconds: TimeInterval, _ done: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if done() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return done()
    }

    static func runIfRequested() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard environment["BORIS_SPEED_TOUR"] != nil else { return false }
        guard environment["BORIS_STATE_DIR"] != nil, !BannerChannel.canRun else {
            FileHandle.standardError.write(Data("BORIS_SPEED_TOUR needs BORIS_STATE_DIR, and BORIS_SMOKE=1 inside an app bundle.\n".utf8))
            exit(2)
        }
        let settle = environment["BORIS_SPEED_SETTLE"].flatMap(Double.init) ?? 4
        Task { @MainActor in
            let heard = Heard()
            AppLog.add(heard)
            SpeedLog.thresholds = .everything
            MainThreadWatch.start()

            let settings = AppSettings(defaults: nil)
            settings.displayMode = .technical
            let model = AppModel(settings: settings, store: StateStore(), live: true)
            model.start()
            let began = Date()
            _ = await until(seconds: 1500) { model.loaded && model.usage.book != nil && model.usage.progress == nil }
            say(["stage": "ready", "seconds": Int(Date().timeIntervalSince(began)), "sessionsAtWork": model.work.sessions.count, "tokenRecords": model.usage.records.count])

            let main = window(MainWindowView(model: model, connect: ConnectFlow(), openSettings: { _ in }), size: CGSize(width: 1200, height: 800))
            SpeedLog.began(.openMainWindow)
            main.orderBack(nil)
            model.setLookingClosely(true, from: .mainWindow)
            try? await Task.sleep(for: .seconds(settle))

            var step = 0
            func mark(_ name: String) {
                step += 1
                say(["stage": "step", "step": step, "what": name, "linesSoFar": heard.all.count])
            }

            // Every page, twice: the first visit reads, the second shows what is already there.
            for round in 1...2 {
                for page in AppPage.allCases where page != .now {
                    mark("page \(page.rawValue) round \(round)")
                    model.choose(page)
                    try? await Task.sleep(for: .seconds(settle))
                    model.choose(.now)
                    try? await Task.sleep(for: .seconds(1))
                }
            }

            // Projects with the most sessions, then the sessions with the biggest trees and the newest ones.
            model.choose(.projects)
            _ = await until(seconds: 120) { model.pastLoaded }
            let all = model.allSessions
            say(["stage": "sessions", "known": all.count])
            let byProject = Dictionary(grouping: all, by: { $0.projectPath ?? "" })
            let projects = byProject.sorted { $0.value.count > $1.value.count }.prefix(3).map(\.key)
            for (index, path) in projects.enumerated() {
                mark("project \(index + 1) of the biggest, sessions \(byProject[path]?.count ?? 0)")
                model.openProject(path.isEmpty ? nil : path)
                try? await Task.sleep(for: .seconds(settle))
                model.backToProjects()
                try? await Task.sleep(for: .seconds(1))
            }
            let biggest = all.sorted { $0.root.flattened.count > $1.root.flattened.count }.prefix(3)
            let newest = all.sorted { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }.prefix(3)
            var seen = Set<String>()
            for (kind, session) in biggest.map({ ("biggest", $0) }) + newest.map({ ("newest", $0) }) where seen.insert(session.id).inserted {
                mark("session \(kind), agents \(session.root.flattened.count)")
                model.openSession(session.id)
                try? await Task.sleep(for: .seconds(settle))
                SpeedLog.began(.click)
                model.setDisplayMode(.simple)
                try? await Task.sleep(for: .seconds(2))
                model.setDisplayMode(.technical)
                try? await Task.sleep(for: .seconds(2))
                model.backToProjects()
                try? await Task.sleep(for: .seconds(1))
            }
            model.choose(.now)
            try? await Task.sleep(for: .seconds(1))

            // The mini window and every section of the settings, each in a window of its own.
            mark("mini window")
            let mini = window(MiniWindowView(model: model, openMain: {}), size: CGSize(width: 360, height: 560))
            SpeedLog.began(.openMiniWindow)
            mini.orderBack(nil)
            model.setLookingClosely(true, from: .miniWindow)
            try? await Task.sleep(for: .seconds(settle))
            mini.orderOut(nil)
            model.setLookingClosely(false, from: .miniWindow)

            mark("settings")
            model.settingsSection = .general
            let settingsWindow = window(SettingsView(model: model, connect: ConnectFlow(), actions: SettingsActions()), size: CGSize(width: 760, height: 720))
            SpeedLog.began(.openSettings)
            settingsWindow.orderBack(nil)
            try? await Task.sleep(for: .seconds(settle))
            for section in SettingsSection.allCases where section != .general {
                mark("settings \(section.rawValue)")
                SpeedLog.began(.chooseSettingsSection, to: section.speedPlace)
                model.settingsSection = section
                try? await Task.sleep(for: .seconds(settle))
            }
            settingsWindow.orderOut(nil)
            main.orderOut(nil)
            model.setLookingClosely(false, from: .mainWindow)

            for record in heard.all {
                // The line as the file keeps it, without its time: level, area, message and the typed values.
                let fields = LogFile.line(record).trimmingCharacters(in: .newlines).split(separator: "\t").dropFirst(3).map(String.init)
                say(["stage": "line", "fields": fields])
            }
            MainThreadWatch.stop()
            await model.stop()
            exit(0)
        }
        return true
    }
}
#endif
