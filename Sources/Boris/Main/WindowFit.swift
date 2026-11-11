import AppKit
import SwiftUI

/// Keeps a window on its screen, whatever size was saved for it last time.
@MainActor
enum WindowFit {
    /// The frame, moved and shrunk only as much as it takes to be entirely inside the visible area.
    /// A frame saved before the window had its smallest size grows back to `minimum`, as far as the screen allows.
    static func fitted(_ frame: NSRect, in visible: NSRect, minimum: NSSize = .zero) -> NSRect {
        var fitted = frame
        fitted.size.width = min(max(frame.width, minimum.width), visible.width)
        fitted.size.height = min(max(frame.height, minimum.height), visible.height)
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

    /// A window with a transparent title bar, its pages drawn under it. It moves only by the title bar and the strips marked with `WindowDragArea`:
    /// moved by its whole background, it went off with the mouse when the person meant to select text, scroll, grab a list or the edge to resize.
    static func window(_ host: NSViewController, title: String, size: NSSize, minimum: NSSize) -> NSWindow {
        let window = SizedWindow(contentViewController: host)
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.setContentSize(size)
        window.smallest = minimum
        window.minSize = minimum
        return window
    }

    /// Puts the window back on a screen it fits on, at no less than its smallest size.
    static func keepOnScreen(_ window: NSWindow, minimum: NSSize) {
        guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        let fitted = fitted(window.frame, in: visible, minimum: minimum)
        if fitted != window.frame { window.setFrame(fitted, display: false) }
    }

    /// What a double click on a title bar does, as set in System Settings › Desktop & Dock.
    enum DoubleClick: Equatable {
        case zoom, minimize, nothing

        static func chosen(_ setting: String?) -> DoubleClick {
            switch setting {
            case "Minimize": return .minimize
            case "None": return .nothing
            default: return .zoom
            }
        }
    }
}

/// The hosting controller sets the window's smallest size back to nothing the first time it lays out a page,
/// and the window could then be dragged down to a sliver with its pages cut off. This window keeps the smallest size it was given.
final class SizedWindow: NSWindow {
    var smallest: NSSize = .zero {
        didSet { minSize = minSize }
    }

    override var minSize: NSSize {
        get { super.minSize }
        set { super.minSize = NSSize(width: max(newValue.width, smallest.width), height: max(newValue.height, smallest.height)) }
    }

    override var contentMinSize: NSSize {
        get { super.contentMinSize }
        set { super.contentMinSize = NSSize(width: max(newValue.width, smallest.width), height: max(newValue.height, smallest.height)) }
    }
}

/// A strip that moves the window as its title bar does: dragged, it takes the window along, and a double click zooms it.
/// What stands on top of it, such as buttons and menus, keeps its clicks.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowDragView { WindowDragView() }
    func updateNSView(_ view: WindowDragView, context: Context) {}
}

final class WindowDragView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    /// A title bar moves a window that is not in front at once, without a first click to bring it forward.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        guard event.clickCount == 2 else {
            window.performDrag(with: event)
            return
        }
        switch WindowFit.DoubleClick.chosen(UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick")) {
        case .zoom: window.zoom(nil)
        case .minimize: window.miniaturize(nil)
        case .nothing: break
        }
    }
}
