import Foundation

public enum TokenFormat {
    /// `950`, `12k`, `1.2M`.
    public static func short(_ value: Int) -> String {
        switch value {
        case ..<1000: return "\(value)"
        case ..<1_000_000: return "\(value / 1000)k"
        default:
            let m = Double(value) / 1_000_000
            return m >= 100 ? "\(Int(m))M" : String(format: "%.1fM", m)
        }
    }
}
