import AppKit
import BorisCore
import SwiftUI

/// For checking screens without clicking. It exists only in debug builds.
@MainActor
enum DevSnapshot {
    /// `BORIS_SNAPSHOT=/path/out.png` renders the page and quits.
    static func runIfRequested() -> Bool {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["BORIS_SNAPSHOT"] else { return false }
        let settings = AppSettings(defaults: nil)
        if let theme = environment["BORIS_THEME"].flatMap(ThemeMode.init(rawValue:)) { settings.theme = theme }
        if let language = environment["BORIS_LANGUAGE"].flatMap(AppLanguage.init(rawValue:)) { settings.language = language }

        let host = NSHostingView(rootView: TokenPage(settings: settings).frame(width: 520))
        host.appearance = settings.theme.appearance
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.orderBack(nil)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.5))
            // Switches while the page is on screen, to see that it follows without a restart.
            if let language = environment["BORIS_SWITCH_LANGUAGE"].flatMap(AppLanguage.init(rawValue:)) {
                settings.language = language
                try? await Task.sleep(for: .seconds(0.5))
            }
            host.layoutSubtreeIfNeeded()
            if let picture = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: picture)
                try? picture.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            exit(0)
        }
        return true
        #else
        return false
        #endif
    }

    /// `BORIS_SMOKE=1` reports whether the status item came up and quits.
    static func smokeIfRequested(item: NSStatusItem) {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["BORIS_SMOKE"] != nil else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.5))
            let shown = item.button?.window != nil && item.button?.image != nil
            print("status item: \(shown ? "shown" : "missing"), bundle: \(Bundle.main.bundleIdentifier ?? "none")")
            exit(shown ? 0 : 1)
        }
        #endif
    }
}
