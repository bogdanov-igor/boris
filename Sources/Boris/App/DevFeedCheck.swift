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
            exit(await run(folder: URL(fileURLWithPath: folder)) ? 0 : 1)
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

    private static func picture(_ host: NSView, _ path: URL) {
        guard let image = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: image)
        try? image.representation(using: .png, properties: [:])?.write(to: path)
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
        append(step(70), to: file)
        await settle(1.5)
        report("a closed window stops reading", "\(height())" == hidden)
        window.orderBack(nil)
        await settle(3)
        report("and it reads again when it comes back", distance() <= 8, "distance \(distance())")
        window.orderOut(nil)
        return passed
    }
}
#endif
