import AppKit
import BorisCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private lazy var settings = AppSettings()
    private var statusItem: NSStatusItem?
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if DevSnapshot.runIfRequested() { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "circle.dashed", accessibilityDescription: "Boris")
        item.button?.target = self
        item.button?.action = #selector(openWindow)
        statusItem = item

        DevSnapshot.smokeIfRequested(item: item)
    }

    @objc private func openWindow() {
        if window == nil {
            let host = NSHostingController(rootView: TokenPage(settings: settings))
            let created = NSWindow(contentViewController: host)
            created.title = "Boris"
            created.setContentSize(NSSize(width: 520, height: 560))
            created.isReleasedWhenClosed = false
            window = created
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
