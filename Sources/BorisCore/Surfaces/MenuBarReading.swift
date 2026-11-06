import CoreGraphics
import Foundation

/// One window as the Window Server lists it: only its place and level, never its name or what it shows.
public struct ScreenWindow: Sendable, Equatable {
    public var number: Int
    public var layer: Int
    /// Global, with the origin at the top left of the primary screen, which is not how AppKit counts.
    public var bounds: CGRect

    public init(number: Int, layer: Int, bounds: CGRect) {
        self.number = number
        self.layer = layer
        self.bounds = bounds
    }
}

/// What the menu bar of one screen looks like right now.
///
/// `NSStatusBar.thickness` says 22 where the bar is 30, and `visibleFrame` alone does not tell a full-screen app from a bar that is there,
/// so the list of windows has the last word. Every screen with a bar has its own bar window and its own copies of the icons.
public struct MenuBarReading: Sendable, Equatable {
    public static let normalLayer = 0
    public static let barLayer = 24
    public static let iconLayer = 25
    /// Our own invisible anchor for the mini window sits on the icon layer too, and it is no icon.
    private static let narrowestIcon: CGFloat = 8

    public var height: CGFloat
    public var iconsMinX: CGFloat?

    /// - Parameter frame: the screen, as AppKit counts.
    /// - Parameter visibleFrame: what AppKit leaves for windows on it.
    /// - Parameter primaryHeight: the height of the primary screen, which links the two ways of counting.
    /// - Parameter windows: empty when the list could not be read. What `visibleFrame` says is then all there is.
    public init(frame: CGRect, visibleFrame: CGRect, primaryHeight: CGFloat, windows: [ScreenWindow]) {
        height = 0
        iconsMinX = nil
        let reserved = frame.maxY - visibleFrame.maxY
        guard reserved > 0 else { return }
        guard !windows.isEmpty else {
            height = reserved
            return
        }
        let area = CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
        let atTop = { (bounds: CGRect) in abs(bounds.minY - area.minY) <= 1 }
        let bar = windows.first { $0.layer == Self.barLayer && atTop($0.bounds) && $0.bounds.intersection(area).width >= area.width / 2 }
        guard let bar else { return }
        // Only a full-screen app covers a whole screen with an ordinary window: everything else stops below the menu bar.
        let fullScreen = windows.contains { $0.layer == Self.normalLayer && $0.bounds.insetBy(dx: -1, dy: -1).contains(area) }
        guard !fullScreen else { return }
        height = min(bar.bounds.height, reserved)
        iconsMinX = windows
            .filter { window in
                window.layer == Self.iconLayer && atTop(window.bounds) && window.bounds.width >= Self.narrowestIcon
                    && window.bounds.height <= bar.bounds.height + 1 && area.insetBy(dx: -1, dy: -1).contains(window.bounds)
            }
            .map(\.bounds.minX)
            .min()
    }
}
