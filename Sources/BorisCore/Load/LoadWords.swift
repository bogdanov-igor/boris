import Foundation

extension WorkFormat {
    /// `950 КБ`, `480 МБ`, `2,8 ГБ`. Counted in 1024s, as Activity Monitor counts memory.
    public static func byteCount(_ value: UInt64) -> String {
        let kilobytes = Double(value) / 1024
        let megabytes = kilobytes / 1024
        let gigabytes = megabytes / 1024
        let locale = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...1)).locale(Localizer.locale)
        let whole = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0)).locale(Localizer.locale)
        if kilobytes < 1000 { return L("%@ KB", kilobytes.formatted(whole)) }
        if megabytes < 1000 { return L("%@ MB", megabytes.formatted(whole)) }
        if gigabytes < 1000 { return L("%@ GB", gigabytes.formatted(locale)) }
        return L("%@ TB", (gigabytes / 1024).formatted(locale))
    }
}

/// Colours of the groups, from `B-Mini`. They only tell the groups apart and carry no meaning of their own.
extension DesignTokens {
    public static let loadClaude = TokenPair(0x3F6FC2, 0x6F9BEA)
    public static let loadCowork = TokenPair(0x8558C9, 0xB08BEA)
    public static let loadVSCode = TokenPair(0x3B8C8C, 0x5DB3B3)
    public static let loadCursor = TokenPair(0xB07A2A, 0xD7A24E)
    public static let loadDesktop = TokenPair(0x5E7FB8, 0x8AA6DA)
    public static let loadBoris = TokenPair(0x5F6F84, 0x9AA9BD)
    public static let loadRest = TokenPair(0xB9BEC7, 0x55585F)
    public static let loadGap = TokenPair(TokenColor(hex: 0xFFFFFF, alpha: 0.7), TokenColor(hex: 0x000000, alpha: 0.35))
}
