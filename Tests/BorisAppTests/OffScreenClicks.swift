import AppKit
import SwiftUI

/// A window that can never take the keyboard, far off screen, whose real buttons can be pressed with made-up mouse events.
/// Accessibility cannot find them here: SwiftUI builds that tree only when someone asks for it. So a click goes over a stretch of the window until what was asked for has happened.
@MainActor
final class OffScreenClicks {
    private final class Window: NSWindow {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
        override func keyDown(with event: NSEvent) {}
        override func noResponder(for eventSelector: Selector) {}
    }

    let window: NSWindow
    let size: CGSize

    init<Content: View>(_ view: Content, size: CGSize) {
        _ = NSApplication.shared
        self.size = size
        window = Window(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.orderBack(nil)
    }

    func settle() async {
        for _ in 0..<8 {
            window.contentView?.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(15))
        }
    }

    func click(at point: NSPoint) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                window.sendEvent(event)
            }
        }
    }

    /// Clicks along the points given until the condition holds.
    /// - Returns: whether it did.
    func press(along points: [NSPoint], until condition: () -> Bool) async -> Bool {
        await settle()
        for point in points {
            if condition() { return true }
            click(at: point)
            try? await Task.sleep(for: .milliseconds(25))
            window.contentView?.layoutSubtreeIfNeeded()
        }
        return condition()
    }

    /// From the bottom right corner to the left, row by row upward: the main button of a dialog is there.
    func fromBottomRight(rows: ClosedRange<Int>, step: CGFloat = 14) -> [NSPoint] {
        rows.flatMap { row in
            stride(from: size.width - 8, through: 8, by: -step).map { NSPoint(x: $0, y: CGFloat(row) * step) }
        }
    }

    /// Down a column from the top. In AppKit's coordinates the top is at the highest y.
    func downColumn(x: CGFloat, step: CGFloat = 12) -> [NSPoint] {
        stride(from: size.height - 4, through: 4, by: -step).map { NSPoint(x: x, y: $0) }
    }

    func close() {
        window.orderOut(nil)
    }
}
