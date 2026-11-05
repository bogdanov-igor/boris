import Foundation
import os

/// The languages of the interface. Adding one takes a translation in the catalog and a case here, no logic.
public enum AppLanguage: String, CaseIterable, Sendable {
    case ru, en

    /// Each language names itself, so it can be found from any other.
    public var nativeName: String {
        switch self {
        case .ru: return "Русский"
        case .en: return "English"
        }
    }

    /// The first preferred language Boris has, otherwise English.
    public static func preferred(from languages: [String]) -> AppLanguage {
        for language in languages {
            let code = language.split(separator: "-").first.map(String.init) ?? language
            if let match = AppLanguage(rawValue: code) { return match }
        }
        return .en
    }
}

/// Finds a string in the chosen language's table, so switching needs no restart.
public enum Localizer {
    private static let table = OSAllocatedUnfairLock<Bundle?>(initialState: nil)
    private static let chosen = OSAllocatedUnfairLock(initialState: AppLanguage.en)

    /// Numbers, dates and plurals follow the chosen language, not the system one.
    public static var locale: Locale {
        Locale(identifier: chosen.withLock { $0 }.rawValue)
    }

    /// English is the source language and has no table: its text is the key itself.
    /// Falling back to the main bundle here would pick the system language instead of the chosen one.
    public static func use(_ language: AppLanguage, in main: Bundle = .main) {
        let bundle = main.path(forResource: language.rawValue, ofType: "lproj").flatMap(Bundle.init(path:))
        table.withLock { $0 = bundle }
        chosen.withLock { $0 = language }
    }

    public static func string(_ key: String) -> String {
        guard let bundle = table.withLock({ $0 }) else { return key }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }
}

/// Looks up an interface string. The key is the English text, formats follow `String(format:)`.
public func L(_ key: String, _ args: CVarArg...) -> String {
    let format = Localizer.string(key)
    guard !args.isEmpty else { return format }
    return withVaList(args) { NSString(format: format, locale: Localizer.locale, arguments: $0) as String }
}
