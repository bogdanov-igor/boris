import AppKit
import BorisCore

/// Reads the list of windows on screen. It needs no permission, because it asks only for places and levels, and it takes about a millisecond,
/// so it runs now and then and not on every redraw.
enum MenuBarWindows {
    static func read() -> [ScreenWindow] {
        let layers = [MenuBarReading.normalLayer, MenuBarReading.barLayer, MenuBarReading.iconLayer]
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard let layer = info[kCGWindowLayer as String] as? Int, layers.contains(layer),
                  let number = info[kCGWindowNumber as String] as? Int,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let raw = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: raw)
            else { return nil }
            return ScreenWindow(number: number, layer: layer, bounds: bounds)
        }
    }
}
