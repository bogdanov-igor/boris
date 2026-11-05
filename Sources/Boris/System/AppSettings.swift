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

    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        theme = defaults?.string(forKey: "theme").flatMap(ThemeMode.init(rawValue:)) ?? .system
        language = defaults?.string(forKey: "language").flatMap(AppLanguage.init(rawValue:)) ?? .preferred(from: Locale.preferredLanguages)
        Localizer.use(language)
        NSApp?.appearance = theme.appearance
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
