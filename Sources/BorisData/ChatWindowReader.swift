import AppKit
import ApplicationServices
import BorisCore

/// The only place Boris touches another application's window, and only after the person has agreed in «Sources».
///
/// Of everything in the window, it reads the kind of each element and the labels of buttons. The text of chats is never asked for.
public struct AccessibilityChatProbe: ChatWindowProbe {
    /// A long chat has thousands of elements, and this runs every few seconds.
    private static let elementLimit = 3000
    private static let timeLimit: TimeInterval = 0.4
    /// A call to an application that hangs must not hold the look for the system's usual 6 seconds.
    private static let callLimit: Float = 0.25
    /// Parts of the chat itself, where no such button lives.
    private static let notDescended: Set<String> = [kAXStaticTextRole, kAXImageRole, kAXListRole, kAXTableRole, kAXTextAreaRole, kAXTextFieldRole, kAXScrollBarRole, "AXLink", "AXHeading"]

    public init() {}

    public func hasPermission() -> Bool {
        AXIsProcessTrusted()
    }

    public func askForPermission() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    public func look() -> ChatLook {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: SessionJump.claudeDesktop).first else { return .appClosed }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier { return .inFront }
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), Self.callLimit)
        let element = AXUIElementCreateApplication(app.processIdentifier)
        // Claude Desktop is built on Electron, which describes its window to others only when asked to in this way.
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        guard let windows = children(of: element, attribute: kAXWindowsAttribute), !windows.isEmpty else { return .cannotSee }
        return search(windows)
    }

    public func stopLooking() {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: SessionJump.claudeDesktop).first else { return }
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(app.processIdentifier), "AXManualAccessibility" as CFString, kCFBooleanFalse)
    }

    /// The input box is at the bottom of the window and the last among its neighbours, so what comes last is looked at first.
    private func search(_ windows: [AXUIElement]) -> ChatLook {
        var stack = windows
        var seen = 0
        var buttons = 0
        let deadline = Date().addingTimeInterval(Self.timeLimit)
        while let element = stack.popLast() {
            seen += 1
            // Not having looked everywhere is not the same as the button being gone.
            if seen > Self.elementLimit || Date() > deadline { return .cannotSee }
            guard let role = text(of: element, attribute: kAXRoleAttribute) else { continue }
            if role == kAXButtonRole {
                buttons += 1
                if ChatStopButton.matches(text(of: element, attribute: kAXDescriptionAttribute)) || ChatStopButton.matches(text(of: element, attribute: kAXTitleAttribute)) {
                    return .answering
                }
            } else if !Self.notDescended.contains(role) {
                stack += children(of: element, attribute: kAXChildrenAttribute) ?? []
            }
        }
        // A window with no buttons at all has not described itself yet, and that happens right after it is asked to.
        return buttons == 0 ? .cannotSee : .notAnswering
    }

    private func text(of element: AXUIElement, attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func children(of element: AXUIElement, attribute: String) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? [AXUIElement]
    }
}
