import AppKit
import SwiftUI

/// Keeps a window on its screen, whatever size was saved for it last time.
@MainActor
enum WindowFit {
    /// The frame, moved and shrunk only as much as it takes to be entirely inside the visible area.
    static func fitted(_ frame: NSRect, in visible: NSRect) -> NSRect {
        var fitted = frame
        fitted.size.width = min(frame.width, visible.width)
        fitted.size.height = min(frame.height, visible.height)
        fitted.origin.x = min(max(frame.minX, visible.minX), visible.maxX - fitted.width)
        fitted.origin.y = min(max(frame.minY, visible.minY), visible.maxY - fitted.height)
        return fitted
    }

    /// Left alone, a hosting controller makes the window as tall as its content wants, past the bottom of the screen.
    /// These windows get their size from the person instead, and their pages scroll.
    static func host<Content: View>(_ rootView: Content) -> NSHostingController<Content> {
        let host = NSHostingController(rootView: rootView)
        host.sizingOptions = []
        return host
    }
}
