import CoreGraphics
import Foundation

/// A screen as the notch and the panel need to know it. AppKit stays out, so that placement can be tested with any screens.
/// All rectangles are in global coordinates with the origin at the bottom left, as AppKit has them.
public struct SurfaceScreen: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var frame: CGRect
    /// Without the menu bar and the Dock.
    public var visibleFrame: CGRect
    /// The cutout, or nil on a screen without one.
    public var notch: CGRect?

    public init(id: String, name: String, frame: CGRect, visibleFrame: CGRect, notch: CGRect? = nil) {
        self.id = id
        self.name = name
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.notch = notch
    }

    /// The cutout from what `NSScreen` reports: only the widths of the areas beside it can be relied on, on any screen.
    public static func notch(frame: CGRect, topInset: CGFloat, leftWidth: CGFloat?, rightWidth: CGFloat?) -> CGRect? {
        guard topInset > 0, let leftWidth, let rightWidth else { return nil }
        let width = frame.width - leftWidth - rightWidth
        guard width > 0 else { return nil }
        return CGRect(x: frame.minX + leftWidth, y: frame.maxY - topInset, width: width, height: topInset)
    }
}

/// Where the person wants the notch or the panel.
public enum SurfaceScreenChoice: Codable, Sendable, Equatable {
    case followCursor, main
    /// The name stays so that the settings can name a monitor that is not connected right now.
    case screen(id: String, name: String)

    /// Identifies the choice whatever the monitor is called today.
    public var key: String {
        switch self {
        case .followCursor: return "cursor"
        case .main: return "main"
        case .screen(let id, _): return id
        }
    }
}

public enum SurfaceGeometry {
    public static let closedPillHeight: CGFloat = 34
    public static let panelGap: CGFloat = 6
    /// The open notch is wider, because it has nothing around it and starts at the very top.
    public static let openNotchWidth: CGFloat = 540
    public static let openPanelWidth: CGFloat = 460
    /// A surface never touches the sides or the bottom of the screen.
    static let screenMargin: CGFloat = 8
    /// The walrus with its padding.
    static let walrusWing: CGFloat = 44
    /// Keeps text off the cutout and off the rounded end of the notch.
    static let textInsets: CGFloat = 22

    /// `screens` comes in the order of `NSScreen.screens`: the main screen is first. A monitor that is gone gives way to the main screen,
    /// and the choice itself stays, so the surface goes back when the monitor returns.
    public static func screen(for choice: SurfaceScreenChoice, among screens: [SurfaceScreen], cursor: CGPoint) -> SurfaceScreen? {
        switch choice {
        case .main:
            return screens.first
        case .followCursor:
            return screens.first { contains($0.frame, cursor) } ?? screens.first
        case .screen(let id, _):
            return screens.first { $0.id == id } ?? screens.first
        }
    }

    /// `CGRect.contains` leaves out the top edge, where the cursor rests when it goes up to the notch.
    public static func contains(_ rect: CGRect, _ point: CGPoint) -> Bool {
        point.x >= rect.minX && point.x < rect.maxX && point.y > rect.minY && point.y <= rect.maxY
    }

    public struct ClosedNotch: Sendable, Equatable {
        public var frame: CGRect
        public var left: CGFloat
        public var cutout: CGFloat
        public var right: CGFloat

        public init(frame: CGRect = .zero, left: CGFloat = 0, cutout: CGFloat = 0, right: CGFloat = 0) {
            self.frame = frame
            self.left = left
            self.cutout = cutout
            self.right = right
        }
    }

    /// The walrus goes left of the cutout and the text right of it. Both sides take half of `minimumWidth` as in the design,
    /// and the right one grows when the text would otherwise run behind the cutout. It stops at the edge of the screen.
    public static func closedNotch(on screen: SurfaceScreen, notch: CGRect, textWidth: CGFloat, minimumWidth: CGFloat) -> ClosedNotch {
        let half = (minimumWidth - notch.width) / 2
        let left = min(max(half, walrusWing), notch.minX - screen.frame.minX)
        let right = min(max(half, textWidth.rounded(.up) + textInsets), screen.frame.maxX - notch.maxX)
        return ClosedNotch(
            frame: CGRect(x: notch.minX - left, y: screen.frame.maxY - notch.height, width: left + notch.width + right, height: notch.height),
            left: left,
            cutout: notch.width,
            right: right
        )
    }

    /// Without a cutout the surface is a pill just below the menu bar.
    public static func closedPill(on screen: SurfaceScreen, contentWidth: CGFloat) -> CGRect {
        let width = min(contentWidth.rounded(.up), screen.frame.width - 2 * screenMargin)
        return CGRect(x: screen.frame.midX - width / 2, y: screen.visibleFrame.maxY - panelGap - closedPillHeight, width: width, height: closedPillHeight)
    }

    public static func openWidth(on screen: SurfaceScreen) -> CGFloat {
        min(screen.notch == nil ? openPanelWidth : openNotchWidth, screen.frame.width - 2 * screenMargin)
    }

    /// The tallest an open surface may be: what does not fit scrolls inside it.
    public static func maximumOpenHeight(on screen: SurfaceScreen) -> CGFloat {
        let top = screen.notch == nil ? screen.visibleFrame.maxY - panelGap : screen.frame.maxY
        return max(top - screen.visibleFrame.minY - screenMargin, 0)
    }

    public static func open(on screen: SurfaceScreen, contentHeight: CGFloat) -> CGRect {
        let width = openWidth(on: screen)
        let height = min(contentHeight.rounded(.up), maximumOpenHeight(on: screen))
        let top = screen.notch == nil ? screen.visibleFrame.maxY - panelGap : screen.frame.maxY
        let center = screen.notch?.midX ?? screen.frame.midX
        let x = min(max(center - width / 2, screen.frame.minX + screenMargin), screen.frame.maxX - screenMargin - width)
        return CGRect(x: x, y: top - height, width: width, height: height)
    }

    /// Where the mini window hangs while the icon is off: about where the icon would be.
    public static func miniAnchor(on screen: SurfaceScreen) -> CGPoint {
        CGPoint(x: screen.frame.maxX - 200, y: screen.visibleFrame.maxY)
    }
}
