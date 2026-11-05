import AppKit
import BorisCore
import SwiftUI

/// The window of the notch and of the panel. Showing it or clicking its buttons leaves the active app as it is.
/// Only a text field of a card takes the keyboard, and the keyboard goes back when the field or the surface goes.
final class SurfacePanel: NSPanel {
    var onKeyChange: ((Bool) -> Void)?

    /// The window stays key when the field in it goes away, so being key does not mean the person can type here.
    var isTyping: Bool { isKeyWindow && firstResponder is NSText }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 300, height: 34), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        // Above the menu bar, because the notch sits in it.
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    /// `becomesKeyOnlyIfNeeded` keeps this to text fields. A borderless window would refuse even them.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// A card can focus its field by itself after a click on "Deny". The field then looks ready, and without this the letters would go to the active app, which may be a terminal.
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let made = super.makeFirstResponder(responder)
        if made, firstResponder is NSText, !isKeyWindow { makeKey() }
        return made
    }

    override func becomeKey() {
        super.becomeKey()
        onKeyChange?(true)
    }

    override func resignKey() {
        super.resignKey()
        onKeyChange?(false)
    }
}

/// Hosts the surface and tells when the pointer comes and goes, whichever app is active.
final class SurfaceHostingView<Content: View>: NSHostingView<Content> {
    var onHover: ((Bool) -> Void)?

    required init(rootView: Content) {
        super.init(rootView: rootView)
        // The window follows the state of the surface, not the other way round.
        sizingOptions = []
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    /// A card is answered with one click, without first bringing anything forward.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// This view says yes by default, and it is what a SwiftUI button hits: any click would take the keyboard from the active app.
    /// Text fields are views of their own and still ask for it.
    override var needsPanelToBecomeKey: Bool { false }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHover?(false)
    }
}

/// The real screens, in the form placement understands. The main screen comes first.
@MainActor
enum SurfaceScreens {
    static func current() -> [SurfaceScreen] {
        NSScreen.screens.map { screen in
            SurfaceScreen(
                id: id(of: screen),
                name: screen.localizedName,
                frame: screen.frame,
                visibleFrame: screen.visibleFrame,
                notch: SurfaceScreen.notch(
                    frame: screen.frame,
                    topInset: screen.safeAreaInsets.top,
                    leftWidth: screen.auxiliaryTopLeftArea?.width,
                    rightWidth: screen.auxiliaryTopRightArea?.width
                )
            )
        }
    }

    /// Stays the same when a monitor is unplugged and plugged back in, unlike its number.
    private static func id(of screen: NSScreen) -> String {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return screen.localizedName }
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue() else { return String(number) }
        return CFUUIDCreateString(nil, uuid) as String
    }
}

/// With the icon off, the mini window has nothing to hang from. This invisible point stands in for the icon.
@MainActor
final class MiniAnchor {
    private let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)

    init() {
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.isReleasedWhenClosed = false
    }

    func view(at point: CGPoint) -> NSView? {
        window.setFrameOrigin(NSPoint(x: point.x, y: point.y - 1))
        window.orderFrontRegardless()
        return window.contentView
    }

    func hide() {
        window.orderOut(nil)
    }
}
