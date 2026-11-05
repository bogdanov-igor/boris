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
    static let desk = Color(DesignTokens.desk)
    static let button = Color(DesignTokens.button)
    static let buttonBorder = Color(DesignTokens.buttonBorder)
    static let monoBackground = Color(DesignTokens.monoBackground)
    static let meter = Color(DesignTokens.meter)
    static let meterTrack = Color(DesignTokens.meterTrack)
    static let chartInput = Color(DesignTokens.chartInput)
    static let chartOutput = Color(DesignTokens.chartOutput)
    static let chartCacheRead = Color(DesignTokens.chartCacheRead)
    static let chartCacheWrite = Color(DesignTokens.chartCacheWrite)
    static let smoke = Color(DesignTokens.statusSmoke)
    static let doneSoft = Color(DesignTokens.statusDoneSoft)
    static let red = Color(DesignTokens.statusRed)
    static let redSoft = Color(DesignTokens.statusRedSoft)
    static let grey = Color(DesignTokens.statusGrey)
    static let waitingSoft = Color(DesignTokens.statusWaitingSoft)
    static let limitSoft = Color(DesignTokens.statusLimitSoft)
    static let notch = Color(DesignTokens.notch)
    static let panel = Color(DesignTokens.panel)
    static let ribbonDone = Color(DesignTokens.ribbonDone)
    static let ribbonRunning = Color(DesignTokens.ribbonRunning)
    static let ribbonFailed = Color(DesignTokens.ribbonFailed)
    static let ribbonCancelled = Color(DesignTokens.ribbonCancelled)
    static let brandRed = Color(DesignTokens.brandRed)
    static let brandGold = Color(DesignTokens.brandGold)
}
