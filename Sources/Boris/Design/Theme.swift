import AppKit
import BorisCore
import SwiftUI

extension NSColor {
    convenience init(_ color: TokenColor) {
        self.init(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    }
}

extension Color {
    /// A colour that follows the theme of the view it is drawn in.
    init(_ pair: TokenPair) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(dark ? pair.dark : pair.light)
        })
    }
}

/// The tokens as SwiftUI colours, so a screen never spells a hex value.
enum Palette {
    static let window = Color(DesignTokens.window)
    static let side = Color(DesignTokens.side)
    static let pop = Color(DesignTokens.pop)
    static let fill1 = Color(DesignTokens.fill1)
    static let fill2 = Color(DesignTokens.fill2)
    static let separator = Color(DesignTokens.separator)
    static let text1 = Color(DesignTokens.text1)
    static let text2 = Color(DesignTokens.text2)
    static let text3 = Color(DesignTokens.text3)
    static let focus = Color(DesignTokens.focus)
    static let running = Color(DesignTokens.statusRunning)
    static let done = Color(DesignTokens.statusDone)
    static let redText = Color(DesignTokens.statusRedText)
    static let waiting = Color(DesignTokens.statusWaiting)
    static let limit = Color(DesignTokens.statusLimit)
    static let brandRed = Color(DesignTokens.brandRed)
    static let brandGold = Color(DesignTokens.brandGold)
}
