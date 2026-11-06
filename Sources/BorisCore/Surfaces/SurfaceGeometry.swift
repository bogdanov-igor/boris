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
    /// How high the menu bar is right now. Zero while there is none to see: auto-hide, a full-screen app, a monitor that does not get one.
    public var menuBar: CGFloat
    /// Where the status icons begin on this screen, or nil when that is not known.
    public var statusIconsMinX: CGFloat?

    /// - Parameter menuBar: left out, it comes from what `visibleFrame` keeps free at the top.
    public init(id: String, name: String, frame: CGRect, visibleFrame: CGRect, notch: CGRect? = nil, menuBar: CGFloat? = nil, statusIconsMinX: CGFloat? = nil) {
        self.id = id
        self.name = name
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.notch = notch
        self.menuBar = menuBar ?? max(frame.maxY - visibleFrame.maxY, 0)
        self.statusIconsMinX = statusIconsMinX
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

/// Where the panel goes on a screen without a notch. Nil in its place means nothing is on screen.
public struct SurfacePlacement: Sendable, Equatable {
    /// The window: all of what follows, with clear space between the parts.
    public var frame: CGRect
    /// The closed part, inside the menu bar.
    public var strip: CGRect?
    /// The open part, below the menu bar.
    public var sheet: CGRect?
    /// Which of the widths offered for the strip was taken.
    public var choice: Int

    public init(frame: CGRect, strip: CGRect? = nil, sheet: CGRect? = nil, choice: Int = 0) {
        self.frame = frame
        self.strip = strip
        self.sheet = sheet
        self.choice = choice
    }

    /// The clear space beside the strip is not the surface: the pointer there is on its way to a menu.
    public func holds(_ point: CGPoint) -> Bool {
        guard strip != nil || sheet != nil else { return SurfaceGeometry.contains(frame, point) }
        return [strip, sheet].contains { $0.map { SurfaceGeometry.contains($0, point) } ?? false }
    }
}

public enum SurfaceGeometry {
    /// The open notch is wider, because it has nothing around it and starts at the very top.
    public static let openNotchWidth: CGFloat = 540
    public static let openPanelWidth: CGFloat = 460
    /// A surface never touches the sides or the bottom of the screen.
    static let screenMargin: CGFloat = 8
    /// The walrus with its padding.
    static let walrusWing: CGFloat = 44
    /// Keeps text off the cutout and off the rounded end of the notch.
    static let textInsets: CGFloat = 22
    /// A strip with no menu bar to live in, there only for a request, is as high as a usual menu bar and stays narrow.
    public static let hiddenStripHeight: CGFloat = 28
    static let hiddenStripWidth: CGFloat = 260
    /// How far the active app's menus may reach. Only Accessibility permission could tell exactly, and Boris does not ask for it,
    /// so room is kept for long menus: all of `menusReach` on a wide screen, a share of a narrow one so that something is left there.
    static let menusReach: CGFloat = 720
    static let menusShare: CGFloat = 0.42
    /// Air between the strip and the icons.
    static let iconGap: CGFloat = 6

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

    /// What the menu bar has free for a strip: from where the menus may end to where the icons begin. The two ends can cross.
    static func menuBarRoom(on screen: SurfaceScreen) -> (from: CGFloat, to: CGFloat) {
        let menus = min(menusReach, screen.frame.width * menusShare)
        let icons = min(screen.statusIconsMinX ?? screen.frame.maxX, screen.frame.maxX - screenMargin + iconGap)
        return (screen.frame.minX + menus, icons - iconGap)
    }

    /// Without a cutout the closed surface lives inside the menu bar, so it can never cover a window.
    /// - Parameter widths: from the fullest to the narrowest. The first that fits is taken, near the middle of the screen as far as the room allows.
    /// - Parameter requestWaiting: with the menu bar hidden, only this puts a strip on screen. A full bar still goes without one.
    /// - Parameter lastWayIn: nothing else opens Boris, so a full bar gets the narrowest strip all the same. It goes next to the icons,
    ///   because their place is known and the end of the menus is only a guess.
    public static func closedStrip(on screen: SurfaceScreen, widths: [CGFloat], requestWaiting: Bool, lastWayIn: Bool) -> (frame: CGRect, choice: Int)? {
        guard let narrowest = widths.last else { return nil }
        let top = screen.frame.maxY
        guard screen.menuBar > 0 else {
            guard requestWaiting else { return nil }
            let limit = min(hiddenStripWidth, screen.frame.width - 2 * screenMargin)
            let choice = widths.firstIndex { $0.rounded(.up) <= limit } ?? widths.count - 1
            let width = min(widths[choice].rounded(.up), limit)
            return (CGRect(x: (screen.frame.midX - width / 2).rounded(), y: top - hiddenStripHeight, width: width, height: hiddenStripHeight), choice)
        }
        let height = screen.menuBar
        let room = menuBarRoom(on: screen)
        for (choice, wanted) in widths.enumerated() {
            let width = wanted.rounded(.up)
            guard width <= room.to - room.from else { continue }
            // A window on half a point would blur its text on a monitor without Retina.
            let x = min(max((screen.frame.midX - width / 2).rounded(), room.from.rounded(.up)), (room.to - width).rounded(.down))
            return (CGRect(x: x, y: top - height, width: width, height: height), choice)
        }
        guard lastWayIn else { return nil }
        let width = min(narrowest.rounded(.up), screen.frame.width - 2 * screenMargin)
        let x = max(room.to - width, screen.frame.minX + screenMargin)
        return (CGRect(x: x, y: top - height, width: width, height: height), widths.count - 1)
    }

    /// The panel as a whole. Opening adds a sheet below the menu bar and leaves the strip where it is, so the menus and icons stay uncovered.
    /// With the menu bar hidden the sheet starts at the very top and has no strip above it.
    public static func panel(on screen: SurfaceScreen, widths: [CGFloat], isOpen: Bool, contentHeight: CGFloat, requestWaiting: Bool, lastWayIn: Bool) -> SurfacePlacement? {
        let strip = closedStrip(on: screen, widths: widths, requestWaiting: requestWaiting, lastWayIn: lastWayIn)
        guard isOpen else {
            return strip.map { SurfacePlacement(frame: $0.frame, strip: $0.frame, choice: $0.choice) }
        }
        let inBar = screen.menuBar > 0 ? strip : nil
        let sheet = open(on: screen, contentHeight: contentHeight, around: inBar?.frame.midX)
        guard let inBar else {
            return SurfacePlacement(frame: sheet, sheet: sheet, choice: max(widths.count - 1, 0))
        }
        return SurfacePlacement(frame: sheet.union(inBar.frame), strip: inBar.frame, sheet: sheet, choice: inBar.choice)
    }

    /// The very top of a screen whose menu bar is hidden: that is where the system would bring the menu bar back.
    public static func isAtHiddenBarEdge(of screen: SurfaceScreen, _ point: CGPoint) -> Bool {
        screen.notch == nil && screen.menuBar <= 0 && contains(screen.frame, point) && point.y >= screen.frame.maxY - 1
    }

    /// Where an open surface starts: the notch at the very top, the panel below the menu bar, whether that is there or not.
    private static func openTop(on screen: SurfaceScreen) -> CGFloat {
        screen.notch == nil ? screen.frame.maxY - screen.menuBar : screen.frame.maxY
    }

    public static func openWidth(on screen: SurfaceScreen) -> CGFloat {
        min(screen.notch == nil ? openPanelWidth : openNotchWidth, screen.frame.width - 2 * screenMargin)
    }

    /// The tallest an open surface may be: what does not fit scrolls inside it.
    public static func maximumOpenHeight(on screen: SurfaceScreen) -> CGFloat {
        max(openTop(on: screen) - screen.visibleFrame.minY - screenMargin, 0)
    }

    /// - Parameter around: the middle of the strip the panel hangs from. It has to stay under the pointer that opened it.
    public static func open(on screen: SurfaceScreen, contentHeight: CGFloat, around: CGFloat? = nil) -> CGRect {
        let width = openWidth(on: screen)
        let height = min(contentHeight.rounded(.up), maximumOpenHeight(on: screen))
        let top = openTop(on: screen)
        let center = screen.notch?.midX ?? around?.rounded() ?? screen.frame.midX
        let x = min(max(center - width / 2, screen.frame.minX + screenMargin), screen.frame.maxX - screenMargin - width)
        return CGRect(x: x, y: top - height, width: width, height: height)
    }

    /// Where the mini window hangs while the icon is off: about where the icon would be.
    public static func miniAnchor(on screen: SurfaceScreen) -> CGPoint {
        CGPoint(x: screen.frame.maxX - 200, y: screen.visibleFrame.maxY)
    }
}
