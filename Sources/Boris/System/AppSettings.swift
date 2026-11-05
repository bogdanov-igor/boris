import AppKit
import BorisCore
import Observation

/// What the user chose. Each setting is written as soon as it changes.
@MainActor
@Observable
final class AppSettings {
    /// `nil` keeps everything in memory: a snapshot must not change what the user chose.
    private let defaults: UserDefaults?

    var theme: ThemeMode {
        didSet {
            defaults?.set(theme.rawValue, forKey: "theme")
            NSApp?.appearance = theme.appearance
        }
    }

    var language: AppLanguage {
        didSet {
            defaults?.set(language.rawValue, forKey: "language")
            Localizer.use(language)
        }
    }

    var displayMode: DisplayMode { didSet { defaults?.set(displayMode.rawValue, forKey: "displayMode") } }
    var keepAwake: Bool { didSet { defaults?.set(keepAwake, forKey: "keepAwake") } }
    var hotKeyEnabled: Bool { didSet { defaults?.set(hotKeyEnabled, forKey: "hotKeyEnabled") } }
    var hotKey: HotKeyCombo { didSet { save(hotKey, "hotKey") } }
    /// The person connected the hooks and has not disconnected them.
    var hooksWanted: Bool { didSet { defaults?.set(hooksWanted, forKey: "hooksWanted") } }
    /// How long Claude waits for an answer given in Boris.
    var permissionWaitSeconds: Int { didSet { defaults?.set(permissionWaitSeconds, forKey: "permissionWaitSeconds") } }
    /// Empty means the usual place.
    var claudeFolder: String { didSet { defaults?.set(claudeFolder, forKey: "claudeFolder") } }
    var wardrobe: WardrobeSettings { didSet { save(wardrobe, "wardrobe") } }
    var matrix: ReactionMatrix { didSet { save(matrix, "matrix") } }
    var silenceMinutes: Int { didSet { defaults?.set(silenceMinutes, forKey: "silenceMinutes") } }
    var longTurnMinutes: Int { didSet { defaults?.set(longTurnMinutes, forKey: "longTurnMinutes") } }
    var usageLow: Int { didSet { defaults?.set(usageLow, forKey: "usageLow") } }
    var usageHigh: Int { didSet { defaults?.set(usageHigh, forKey: "usageHigh") } }
    /// Fresh limits come from starting Claude Code for a moment, so this can be turned off.
    var usageRefreshEnabled: Bool { didSet { defaults?.set(usageRefreshEnabled, forKey: "usageRefreshEnabled") } }
    var usageRefreshMinutes: Int { didSet { defaults?.set(usageRefreshMinutes, forKey: "usageRefreshMinutes") } }

    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        theme = defaults?.string(forKey: "theme").flatMap(ThemeMode.init(rawValue:)) ?? .system
        language = defaults?.string(forKey: "language").flatMap(AppLanguage.init(rawValue:)) ?? .preferred(from: Locale.preferredLanguages)
        displayMode = defaults?.string(forKey: "displayMode").flatMap(DisplayMode.init(rawValue:)) ?? .simple
        keepAwake = defaults?.bool(forKey: "keepAwake") ?? false
        hotKeyEnabled = defaults?.object(forKey: "hotKeyEnabled") as? Bool ?? true
        hotKey = Self.load(defaults, "hotKey") ?? .standard
        hooksWanted = defaults?.bool(forKey: "hooksWanted") ?? false
        permissionWaitSeconds = defaults?.object(forKey: "permissionWaitSeconds") as? Int ?? 120
        claudeFolder = defaults?.string(forKey: "claudeFolder") ?? ""
        wardrobe = Self.load(defaults, "wardrobe") ?? WardrobeSettings()
        matrix = Self.load(defaults, "matrix") ?? ReactionMatrix()
        silenceMinutes = defaults?.object(forKey: "silenceMinutes") as? Int ?? 12
        longTurnMinutes = defaults?.object(forKey: "longTurnMinutes") as? Int ?? 5
        usageLow = defaults?.object(forKey: "usageLow") as? Int ?? 80
        usageHigh = defaults?.object(forKey: "usageHigh") as? Int ?? 95
        usageRefreshEnabled = defaults?.object(forKey: "usageRefreshEnabled") as? Bool ?? true
        usageRefreshMinutes = defaults?.object(forKey: "usageRefreshMinutes") as? Int ?? 15
        Localizer.use(language)
        NSApp?.appearance = theme.appearance
    }

    var statusConfig: StatusConfig {
        StatusConfig(silenceThreshold: TimeInterval(silenceMinutes) * 60)
    }

    var detectorConfig: DetectorConfig {
        DetectorConfig(longTurn: TimeInterval(longTurnMinutes) * 60, usageThresholds: [Double(usageLow), Double(usageHigh)])
    }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        defaults?.set(try? JSONEncoder().encode(value), forKey: key)
    }

    private static func load<T: Decodable>(_ defaults: UserDefaults?, _ key: String) -> T? {
        guard let data = defaults?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

extension ThemeMode {
    /// `nil` follows the system.
    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}
