#if DEBUG
import AppKit
import BorisCore
import BorisData
import SwiftUI

/// `BORIS_SNAPSHOT=/folder BORIS_LOAD_MEASURE=seconds` proves that the load is read only while a block can be seen, and what that costs.
/// It goes through the real blocks in a real window and a real popover, and prints one JSON line per stage. Both are see-through
/// and made so before they reach the screen, so nothing shows, and there is no menu bar item.
@MainActor
enum LoadMeasure {
    /// Counts readings and the time spent in them. Reading happens off the main thread, hence the lock.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var readings = 0
        private var nanoseconds: UInt64 = 0

        func add(_ spent: UInt64) {
            lock.withLock {
                readings += 1
                nanoseconds += spent
            }
        }

        var count: Int { lock.withLock { readings } }
        var spent: UInt64 { lock.withLock { nanoseconds } }
    }

    private static func processCPUSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    private final class SeeThroughHost: NSHostingController<AnyView> {
        override func viewWillAppear() {
            super.viewWillAppear()
            view.window?.alphaValue = 0
            view.window?.ignoresMouseEvents = true
            // Like the real one, which hangs from the menu bar. A popover behind another program's window counts as not seen.
            view.window?.level = .statusBar
        }
    }

    private struct Switchable: View {
        @Bindable var model: AppModel
        @Bindable var switcher: Switcher

        var body: some View {
            if switcher.showsBlock {
                MacLoadBlock(model: model, kind: .pageTechnical)
            } else {
                Color.clear
            }
        }
    }

    @Observable
    final class Switcher {
        var showsBlock = true
    }

    private static func seeThroughWindow(_ view: AnyView) -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.styleMask = [.borderless]
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.level = .statusBar
        window.setContentSize(NSSize(width: 420, height: 200))
        if let screen = NSScreen.main?.frame { window.setFrameOrigin(NSPoint(x: screen.minX + 1, y: screen.minY + 1)) }
        return window
    }

    static func runIfRequested() -> Bool {
        guard let text = ProcessInfo.processInfo.environment["BORIS_LOAD_MEASURE"], let seconds = Double(text) else { return false }
        let settings = AppSettings(defaults: nil)
        let model = AppModel(settings: settings, store: nil, live: false)
        let counter = Counter()
        let sampler = MacLoadSampler(logRoots: { [] })
        model.load.reader = { request in
            let began = DispatchTime.now().uptimeNanoseconds
            let load = await sampler.read(request)
            counter.add(DispatchTime.now().uptimeNanoseconds - began)
            return load
        }

        /// - Parameter surface: what must be seen for readings to go on. A sleeping display or another Space hides it, and then no readings
        ///   is the right result, so such a stage proves nothing either way and says so.
        func stage(_ name: String, surface: NSWindow? = nil, for span: Double, action: () -> Void) async -> Bool {
            action()
            // A closed window reports it a moment later, and a reading may be finishing.
            try? await Task.sleep(for: .seconds(0.5))
            let readings = counter.count
            let spent = counter.spent
            let cpu = processCPUSeconds()
            try? await Task.sleep(for: .seconds(span))
            let count = counter.count - readings
            let took = counter.count > readings ? Double(counter.spent - spent) / Double(count) / 1_000_000 : 0
            let percent = (processCPUSeconds() - cpu) / span * 100
            let expected = surface != nil
            let seen = surface?.occlusionState.contains(.visible) ?? false
            let good = expected ? count > 0 || !seen : count == 0
            print(#"{"stage":"\#(name)","seconds":\#(span),"expected":\#(expected),"seen":\#(seen),"readings":\#(count),"msPerReading":\#(String(format: "%.2f", took)),"processCPUPercent":\#(String(format: "%.3f", percent)),"good":\#(good)}"#)
            fflush(stdout)
            return good
        }

        Task { @MainActor in
            var results: [Bool] = []
            let switcher = Switcher()
            // A width of its own, as every real place has: without one the note is sized at its narrowest and the window grows off the screen.
            let window = seeThroughWindow(AnyView(Switchable(model: model, switcher: switcher).frame(width: 420)))

            results.append(await stage("nothing open", for: seconds) {})
            results.append(await stage("window open", surface: window, for: seconds) { window.orderBack(nil) })
            results.append(await stage("window closed", for: seconds) { window.close() })
            results.append(await stage("window open again", surface: window, for: seconds) { window.orderBack(nil) })
            results.append(await stage("another page in the window", for: seconds) { switcher.showsBlock = false })
            results.append(await stage("back on the page", surface: window, for: seconds) { switcher.showsBlock = true })
            results.append(await stage("window hidden", for: seconds) { window.orderOut(nil) })

            let popover = NSPopover()
            popover.animates = false
            popover.behavior = .applicationDefined
            let mini = SeeThroughHost(rootView: AnyView(MiniWindowView(model: model, openMain: {})))
            popover.contentViewController = mini
            let anchor = window.contentView ?? NSView()
            window.orderBack(nil)
            switcher.showsBlock = false
            for round in 1...2 {
                popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
                results.append(await stage("popover open \(round)", surface: mini.view.window, for: seconds) {})
                results.append(await stage("popover closed \(round)", for: seconds) { popover.performClose(nil) })
            }
            window.close()
            exit(results.allSatisfy { $0 } ? 0 : 1)
        }
        return true
    }
}
#endif
