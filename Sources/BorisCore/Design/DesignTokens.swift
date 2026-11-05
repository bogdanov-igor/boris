import Foundation

/// A colour as data, so its contrast can be tested without a window.
public struct TokenColor: Sendable, Equatable {
    public var red, green, blue, alpha: Double

    public init(hex: UInt32, alpha: Double = 1) {
        red = Double((hex >> 16) & 0xFF) / 255
        green = Double((hex >> 8) & 0xFF) / 255
        blue = Double(hex & 0xFF) / 255
        self.alpha = alpha
    }

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// This colour laid over an opaque background.
    public func over(_ background: TokenColor) -> TokenColor {
        TokenColor(
            red: red * alpha + background.red * (1 - alpha),
            green: green * alpha + background.green * (1 - alpha),
            blue: blue * alpha + background.blue * (1 - alpha)
        )
    }

    private var luminance: Double {
        func channel(_ value: Double) -> Double {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    /// The WCAG contrast ratio against an opaque background.
    public func contrast(on background: TokenColor) -> Double {
        let a = over(background).luminance
        let b = background.luminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

public struct TokenPair: Sendable, Equatable {
    public var light, dark: TokenColor

    public init(_ light: TokenColor, _ dark: TokenColor) {
        self.light = light
        self.dark = dark
    }

    init(_ light: UInt32, _ dark: UInt32) {
        self.init(TokenColor(hex: light), TokenColor(hex: dark))
    }

    /// Black in the light theme and white in the dark one, each at its own strength.
    init(blackAlpha: Double, whiteAlpha: Double) {
        self.init(TokenColor(hex: 0x000000, alpha: blackAlpha), TokenColor(hex: 0xFFFFFF, alpha: whiteAlpha))
    }
}

/// The values of `design/claude-design/project/B-Kit.dc.html`. Brand colours come from the walrus's own code instead of the mockup's temporary ones.
public enum DesignTokens {
    public static let desk = TokenPair(0xE4E4E9, 0x141416)
    public static let pop = TokenPair(0xF6F6F7, 0x2A2A2D)
    public static let window = TokenPair(0xFFFFFF, 0x1E1E20)
    public static let side = TokenPair(0xEDEDF0, 0x262629)
    public static let fill1 = TokenPair(blackAlpha: 0.045, whiteAlpha: 0.06)
    public static let fill2 = TokenPair(blackAlpha: 0.085, whiteAlpha: 0.11)
    public static let separator = TokenPair(blackAlpha: 0.11, whiteAlpha: 0.11)
    public static let text1 = TokenPair(0x1D1D1F, 0xF2F2F4)
    public static let text2 = TokenPair(0x55555A, 0xB0B0B6)
    public static let text3 = TokenPair(0x6A6A6F, 0xA2A2A8)
    public static let focus = TokenPair(0x0A64D8, 0x3D8BFF)
    public static let button = TokenPair(0xFFFFFF, 0x3A3A3E)
    public static let buttonBorder = TokenPair(blackAlpha: 0.16, whiteAlpha: 0.13)
    public static let monoBackground = TokenPair(blackAlpha: 0.05, whiteAlpha: 0.07)
    public static let meter = TokenPair(0x55555A, 0xB0B0B6)
    public static let meterTrack = TokenPair(blackAlpha: 0.09, whiteAlpha: 0.12)
    /// As black as the cutout it continues, in either theme. What is on it is always set in the dark theme's colours.
    public static let notch = TokenPair(0x000000, 0x000000)
    /// The panel that stands in for the notch on a screen without one.
    public static let panel = TokenPair(0xF6F6F7, 0x1C1C1E)

    public static let statusRunning = TokenPair(0x1A6F75, 0x5CC0C6)
    public static let statusSmoke = TokenPair(0x8A8A92, 0x82828A)
    public static let statusDone = TokenPair(0x1A7340, 0x4CC27E)
    public static let statusDoneSoft = TokenPair(0xE6F3EA, 0x1C3226)
    public static let statusRed = TokenPair(0xE5383B, 0xE5383B)
    public static let statusRedText = TokenPair(0xB4262A, 0xFF7A7C)
    public static let statusRedSoft = TokenPair(0xFBEAEA, 0x3B2527)
    public static let statusGrey = TokenPair(0x6A6A6F, 0xA2A2A8)
    public static let statusWaiting = TokenPair(0x1D66C9, 0x62A6FF)
    public static let statusWaitingSoft = TokenPair(0xE7EEFA, 0x1E2B42)
    public static let statusLimit = TokenPair(0x4A4FBF, 0x9A9DFF)
    public static let statusLimitSoft = TokenPair(0xECECFA, 0x2A2B47)

    public static let ribbonDone = TokenPair(0x2B7D4E, 0x3E9D66)
    public static let ribbonRunning = TokenPair(0x8CC7CB, 0x2F7479)
    public static let ribbonFailed = TokenPair(0xE5383B, 0xE5383B)
    public static let ribbonCancelled = TokenPair(0xA2A2A8, 0x6A6A70)

    public static let bubble = TokenPair(0xFFFFFF, 0x3A3A3E)
    public static let bubbleBorder = TokenPair(blackAlpha: 0.12, whiteAlpha: 0.14)

    /// The band of his bowler and his gold crown. Only next to the walrus: red here must not read as an alarm.
    public static let brandRed = TokenPair(0xB3313F, 0xB3313F)
    public static let brandGold = TokenPair(0xF4C542, 0xF4C542)

    /// Every colour that text is set in, for the contrast check.
    public static let textColors: [(name: String, pair: TokenPair)] = [
        ("text1", text1), ("text2", text2), ("text3", text3),
        ("statusRunning", statusRunning), ("statusDone", statusDone), ("statusRedText", statusRedText),
        ("statusGrey", statusGrey), ("statusWaiting", statusWaiting), ("statusLimit", statusLimit),
    ]

    /// Every background that text sits on.
    public static let surfaces: [(name: String, pair: TokenPair)] = [
        ("window", window), ("side", side), ("pop", pop), ("panel", panel),
    ]
}

/// Sizes from the mockup, in points.
public enum DesignMetrics {
    public static let radiusSmall: Double = 4
    public static let radiusMedium: Double = 6
    public static let radiusLarge: Double = 8
    public static let textCaption: Double = 11
    public static let textSmall: Double = 12
    public static let textBody: Double = 13
    public static let textHeading: Double = 15
    public static let textTitle: Double = 20
}

public enum ThemeMode: String, CaseIterable, Sendable {
    case system, light, dark
}
