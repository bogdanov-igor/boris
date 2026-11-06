#if DEBUG
import AppKit
import BorisCore
import SwiftUI

/// `BORIS_FEED_CHECK=/folder` checks that the feed follows its last record, off screen, on a made-up transcript that it keeps writing to.
/// It says how each step went, leaves pictures in the folder and quits with a failure if any step failed.
@MainActor
enum DevFeedCheck {
    static func runIfRequested() -> Bool {
        guard let folder = ProcessInfo.processInfo.environment["BORIS_FEED_CHECK"] else { return false }
        Task { @MainActor in
            let url = URL(fileURLWithPath: folder)
            let followed = await run(folder: url)
            let found = await runTarget(folder: url)
            exit(followed && found ? 0 : 1)
        }
        return true
    }

    private static var passed = true

    private static func report(_ what: String, _ ok: Bool, _ details: String = "") {
        print("\(ok ? "ok  " : "FAIL") \(what) \(details)")
        if !ok { passed = false }
    }

    private static func step(_ id: Int) -> String {
        let time = String(format: "10:%02d:%02d", id / 60, id % 60)
        let use = #"{"type":"assistant","timestamp":"2026-11-05T\#(time).000Z","message":{"id":"m\#(id)","content":[{"type":"tool_use","id":"t\#(id)","name":"Read","input":{"file_path":"/x/boris/src/file\#(id).swift"}}]}}"#
        let result = #"{"type":"user","timestamp":"2026-11-05T\#(time).500Z","message":{"content":[{"type":"tool_result","tool_use_id":"t\#(id)","content":"text"}]}}"#
        return use + "\n" + result + "\n"
    }

    private static func append(_ text: String, to file: URL) {
        guard let handle = try? FileHandle(forWritingTo: file) else { return }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(text.utf8))
        try? handle.close()
    }

    private static func findScrollView(in view: NSView) -> NSScrollView? {
        if let found = view as? NSScrollView { return found }
        for child in view.subviews {
            if let found = findScrollView(in: child) { return found }
        }
        return nil
    }

    /// One step of a mouse wheel. The event goes through this app's own queue, so the feed notices it as it does a real one. Nothing leaves this app.
    /// An event made by hand belongs to no window and the view will not scroll for it, so the view is moved here, with no word about live scrolling, which is all a stepped wheel does.
    private static func wheel(by distance: CGFloat, over view: NSScrollView) async {
        guard let source = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: distance > 0 ? 3 : -3, wheel2: 0, wheel3: 0), let event = NSEvent(cgEvent: source) else { return }
        NSApp.postEvent(event, atStart: false)
        try? await Task.sleep(for: .milliseconds(30))
        let bounds = view.contentView.bounds
        let lowest = max(0, (view.documentView?.frame.height ?? 0) - bounds.height)
        view.contentView.scroll(to: NSPoint(x: bounds.minX, y: min(lowest, max(0, bounds.minY - distance))))
        view.reflectScrolledClipView(view.contentView)
    }

    private static func picture(_ host: NSView, _ path: URL) {
        guard let image = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: image)
        try? image.representation(using: .png, properties: [:])?.write(to: path)
    }

    /// A failure in the middle of a long session: its row on the Losses page should open the feed there, and not at the end.
    private static func runTarget(folder: URL) async -> Bool {
        let file = folder.appendingPathComponent("target-session.jsonl")
        var text = ""
        for id in 0..<120 {
            if id == 40 {
                text += #"{"type":"assistant","timestamp":"2026-11-05T10:00:40.000Z","message":{"id":"m-bad","content":[{"type":"tool_use","id":"t-bad","name":"Bash","input":{"command":"make"}}]}}"# + "\n"
                text += #"{"type":"user","timestamp":"2026-11-05T10:00:40.500Z","message":{"content":[{"type":"tool_result","tool_use_id":"t-bad","is_error":true,"content":"Exit code 2"}]}}"# + "\n"
            }
            text += step(id)
        }
        try? text.write(to: file, atomically: false, encoding: .utf8)

        let settings = AppSettings(defaults: nil)
        settings.displayMode = .technical
        let model = AppModel(settings: settings, store: nil, live: false)
        let session = WorkSession(id: "target-session", environment: .terminal, cwd: "/x/boris", state: .finished, root: WorkNode(id: "target-session", kind: .main, state: .finished))
        model.showForSnapshot(work: WorkModel(projects: [WorkProject(path: "/x/boris", sessions: [session])]), world: WorldSnapshot(takenAt: Date()), today: TokenUsage(), mood: .working(agents: 1))
        model.transcriptsForCheck[session.id] = file
        model.openSession(session.id, target: FeedTarget(stepId: "t-bad", at: Date()))

        let bounds = NSRect(x: 0, y: 0, width: 620, height: 500)
        let host = NSHostingView(rootView: SessionFeedView(model: model, session: session).background(Palette.window).foregroundStyle(Palette.text1).frame(width: bounds.width, height: bounds.height))
        host.appearance = settings.theme.appearance
        let window = NSWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.contentView = host
        host.frame = bounds
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.orderBack(nil)
        try? await Task.sleep(for: .seconds(4))
        host.layoutSubtreeIfNeeded()
        picture(host, folder.appendingPathComponent("7-target.png"))

        let store = FeedStore.forSession(session, model: model)
        guard let view = findScrollView(in: host), let document = view.documentView, let index = store.entries.firstIndex(where: { $0.step?.id == "t-bad" }) else {
            report("the failed step is in the feed", false)
            return false
        }
        let distance = document.frame.height - view.contentView.bounds.maxY
        report("the feed opens away from its end", distance > 400, "distance \(distance)")
        report("the failed step is one of the first records", index < store.entries.count / 2, "record \(index) of \(store.entries.count)")
        report("the feed is scrolled to about that place", view.contentView.bounds.minY < document.frame.height / 2, "offset \(view.contentView.bounds.minY) of \(document.frame.height)")
        report("going there happens once", model.feedTarget == nil)

        // New records must not pull the reader away from the failure they came to see.
        let kept = view.contentView.bounds.minY
        append(step(130), to: file)
        try? await Task.sleep(for: .seconds(2.2))
        host.layoutSubtreeIfNeeded()
        report("new records leave the reader where they are", abs(view.contentView.bounds.minY - kept) < 1, "offset \(kept) -> \(view.contentView.bounds.minY)")
        window.orderOut(nil)
        return passed
    }

    private static func run(folder: URL) async -> Bool {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("check-session.jsonl")
        var start = #"{"type":"user","timestamp":"2026-11-05T09:59:00.000Z","message":{"content":"Посмотри файлы."}}"# + "\n"
        for id in 0..<60 { start += step(id) }
        try? start.write(to: file, atomically: false, encoding: .utf8)

        let settings = AppSettings(defaults: nil)
        settings.displayMode = .technical
        settings.language = .ru
        settings.theme = .dark
        let model = AppModel(settings: settings, store: nil, live: false)
        let session = WorkSession(id: "check-session", environment: .terminal, cwd: "/x/boris", state: .running, root: WorkNode(id: "check-session", kind: .main, state: .running))
        model.showForSnapshot(work: WorkModel(projects: [WorkProject(path: "/x/boris", sessions: [session])]), world: WorldSnapshot(takenAt: Date()), today: TokenUsage(), mood: .working(agents: 1))
        model.transcriptsForCheck[session.id] = file

        let bounds = NSRect(x: 0, y: 0, width: 620, height: 500)
        let host = NSHostingView(rootView: SessionFeedView(model: model, session: session).background(Palette.window).foregroundStyle(Palette.text1).frame(width: bounds.width, height: bounds.height))
        host.appearance = settings.theme.appearance
        let window = NSWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.contentView = host
        host.frame = bounds
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.orderBack(nil)
        host.layoutSubtreeIfNeeded()
        picture(host, folder.appendingPathComponent("0-reading.png"))

        // The feed reads once a second and lazy rows settle after that, so each step waits for its result to show.
        func settle(_ seconds: Double = 2.2) async {
            try? await Task.sleep(for: .seconds(seconds))
            host.layoutSubtreeIfNeeded()
        }
        func scroll() -> NSScrollView? { findScrollView(in: host) }
        func distance() -> CGFloat {
            guard let view = scroll(), let document = view.documentView else { return .infinity }
            return document.frame.height - view.contentView.bounds.maxY
        }
        func offset() -> CGFloat { scroll()?.contentView.bounds.minY ?? -1 }
        func height() -> CGFloat { scroll()?.documentView?.frame.height ?? 0 }
        func click(at point: NSPoint) {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    window.sendEvent(event)
                }
            }
        }

        await settle(3)
        report("the feed opens at its end", distance() <= 8, "distance \(distance()), height \(height())")
        picture(host, folder.appendingPathComponent("1-opened.png"))

        var added = ""
        for id in 60..<65 { added += step(id) }
        append(added, to: file)
        let before = height()
        await settle()
        report("new records came in", height() > before, "height \(before) -> \(height())")
        report("it goes along with new records", distance() <= 8, "distance \(distance())")
        picture(host, folder.appendingPathComponent("2-followed.png"))

        guard let view = scroll() else {
            report("found the scroll view", false)
            return false
        }
        // What a trackpad does: the view moves and says it moved.
        view.contentView.scroll(to: NSPoint(x: 0, y: max(0, offset() - 400)))
        view.reflectScrolledClipView(view.contentView)
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: view)
        await settle(0.5)
        let kept = offset()
        added = ""
        for id in 65..<68 { added += step(id) }
        append(added, to: file)
        let beforeUp = height()
        await settle()
        report("new records came in while scrolled up", height() > beforeUp, "height \(beforeUp) -> \(height())")
        report("it stays where the person left it", abs(offset() - kept) < 1, "offset \(kept) -> \(offset())")
        report("it is away from the end", distance() > 8, "distance \(distance())")
        picture(host, folder.appendingPathComponent("3-scrolled-up.png"))

        // The button is at the bottom of the feed, in the middle.
        click(at: NSPoint(x: bounds.midX, y: 30))
        await settle(1)
        report("the button goes back to the last record", distance() <= 8, "distance \(distance())")
        added = ""
        for id in 68..<70 { added += step(id) }
        append(added, to: file)
        let beforeBack = height()
        await settle()
        report("and it follows again", height() > beforeBack && distance() <= 8, "distance \(distance())")
        picture(host, folder.appendingPathComponent("4-back.png"))

        // The same with a mouse wheel, which has no live scrolling to go by.
        FeedScrollCheck.wheelHasNoWindow = true
        await wheel(by: 300, over: view)
        await settle(0.8)
        report("a wheel step takes it away from the end", distance() > 8, "distance \(distance())")
        let keptWheel = offset()
        added = ""
        for id in 70..<73 { added += step(id) }
        append(added, to: file)
        let beforeWheel = height()
        await settle()
        report("new records came in after the wheel", height() > beforeWheel, "height \(beforeWheel) -> \(height())")
        report("it stays where the wheel left it", abs(offset() - keptWheel) < 1, "offset \(keptWheel) -> \(offset())")
        picture(host, folder.appendingPathComponent("4b-wheel-up.png"))
        await wheel(by: -distance(), over: view)
        await settle(1)
        report("the wheel back to the end follows again", distance() <= 8, "distance \(distance())")
        added = ""
        for id in 73..<75 { added += step(id) }
        append(added, to: file)
        let beforeWheelBack = height()
        await settle()
        report("and new records are followed after the wheel", height() > beforeWheelBack && distance() <= 8, "distance \(distance())")

        // A change as an agent's transcript writes it, opened with a click on its row, above the "Thinking" row.
        append(#"{"type":"assistant","timestamp":"2026-11-05T10:02:00.000Z","message":{"id":"m-edit","content":[{"type":"tool_use","id":"t-edit","name":"Edit","input":{"file_path":"/x/boris/src/auth.swift","old_string":"third\nkeep one\nkeep two\nsixth","new_string":"changed third\nkeep one\nkeep two\nchanged sixth\nadded"}}]}}"# + "\n" + #"{"type":"user","timestamp":"2026-11-05T10:02:01.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"t-edit","content":"The file has been updated successfully."}]}}"# + "\n", to: file)
        await settle()
        let closed = height()
        click(at: NSPoint(x: 300, y: 64))
        await settle(1)
        report("a click opens the change", height() > closed + 40, "height \(closed) -> \(height())")
        picture(host, folder.appendingPathComponent("5-change.png"))

        // A window nobody can see reads nothing and holds no text.
        window.orderOut(nil)
        await settle(1.5)
        let hidden = "\(height())"
        append(step(75), to: file)
        await settle(1.5)
        report("a closed window stops reading", "\(height())" == hidden)
        let store = FeedStore.forSession(session, model: model)
        report("and it has no timer left", !store.isReading)
        window.orderBack(nil)
        // An off-screen window is not seen either way, so nothing tells it that it came back. A real one becomes key.
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        await settle(3)
        report("and it reads again when it comes back", distance() <= 8, "distance \(distance())")

        // At the limit each new record drops the oldest. While the person reads, those stay, or what they read would move.
        added = ""
        for id in 76..<440 { added += step(id) }
        append(added, to: file)
        await settle(4)
        report("the feed is at its limit", store.entries.count == ActivityLog.limit, "records \(store.entries.count)")
        report("and it is at its end", distance() <= 8, "distance \(distance())")
        // The feed went empty behind the closed window, so this is a new scroll view.
        if let current = scroll() {
            current.contentView.scroll(to: NSPoint(x: 0, y: max(0, offset() - 600)))
            current.reflectScrolledClipView(current.contentView)
            NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: current)
        }
        await settle(0.5)
        let oldest = store.entries.first?.id
        let atLimit = offset()
        added = ""
        for id in 440..<445 { added += step(id) }
        append(added, to: file)
        await settle()
        report("the oldest stay while the person reads", store.entries.first?.id == oldest && store.entries.count == ActivityLog.limit + 5, "records \(store.entries.count)")
        report("and nothing moves", abs(offset() - atLimit) < 1, "offset \(atLimit) -> \(offset())")
        picture(host, folder.appendingPathComponent("6-at-limit.png"))
        click(at: NSPoint(x: bounds.midX, y: 30))
        await settle()
        report("back at the end the limit holds again", store.entries.count == ActivityLog.limit && distance() <= 8, "records \(store.entries.count), distance \(distance())")
        window.orderOut(nil)
        return passed
    }
}
#endif
