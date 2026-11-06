import Foundation

/// Writes down which settings changed. A slider moves through dozens of values on its way, so a line is written only when it comes to rest.
@MainActor
public enum SettingsLog {
    /// A field of a setting: what it is called and what can be said about its value. Nil means the value stays out of the log.
    struct Field {
        var path: String
        /// Only for telling whether it changed. It never leaves this file.
        var fingerprint: String
        var value: LogValue?
    }

    private struct Waiting {
        var firstFingerprint: String
        var latest: Field
    }

    /// In the order of the first change.
    private static var waiting: [(path: String, change: Waiting)] = []
    private static var planned = false
    private static let rest: TimeInterval = 0.8
    /// Numbers that are about the person, whatever type they have.
    private static let secretFields: Set<String> = ["telegramChat", "userBirthday"]

    /// - Parameter name: the setting's name in the code. A literal, so that it cannot be anything else.
    public static func changed<T>(_ name: StaticString, from old: T, to new: T) {
        guard AppLog.isOn else { return }
        let before = Dictionary(fields(of: old, at: "\(name)").map { ($0.path, $0) }) { first, _ in first }
        for field in fields(of: new, at: "\(name)") {
            guard before[field.path]?.fingerprint != field.fingerprint else { continue }
            remember(field, was: before[field.path]?.fingerprint)
        }
    }

    /// A key combination, which is safe to name and whose stored form says nothing to a reader.
    public static func changedKeys(_ name: StaticString, from old: String, to new: String) {
        guard AppLog.isOn, old != new else { return }
        remember(Field(path: "\(name)", fingerprint: new, value: .keys(new)), was: old)
    }

    /// Writes what is waiting. For quitting.
    public static func flush() {
        for (_, change) in waiting where change.firstFingerprint != change.latest.fingerprint {
            let name = LogValue.settingName(change.latest.path)
            if let value = change.latest.value {
                AppLog.note(.settingChanged, name, value)
            } else {
                AppLog.note(.settingChangedHidden, name)
            }
        }
        waiting = []
    }

    private static func remember(_ field: Field, was old: String?) {
        if let index = waiting.firstIndex(where: { $0.path == field.path }) {
            waiting[index].change.latest = field
        } else {
            waiting.append((field.path, Waiting(firstFingerprint: old ?? "", latest: field)))
        }
        guard !planned else { return }
        planned = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(rest))
            planned = false
            flush()
        }
    }

    /// Goes down through structs and dictionaries with enum keys to the fields that can be named.
    /// Field and case names come from the code. Of values, only numbers, switches and bare enum cases are ever said; strings and the payloads of enums never are.
    static func fields(of value: Any, at path: String) -> [Field] {
        switch value {
        case let value as Bool:
            return [Field(path: path, fingerprint: String(value), value: .flag(value))]
        case let value as Int:
            return [Field(path: path, fingerprint: String(value), value: .number(value))]
        case let value as Double:
            return [Field(path: path, fingerprint: String(value), value: .decimal(value))]
        case is String, is Date, is URL, is Data:
            return [hidden(value, at: path)]
        default:
            break
        }
        let mirror = Mirror(reflecting: value)
        switch mirror.displayStyle {
        case .optional:
            guard let inner = mirror.children.first?.value else { return [Field(path: path, fingerprint: "nil", value: .settingName("none"))] }
            return fields(of: inner, at: path)
        case .struct:
            return mirror.children.flatMap { child -> [Field] in
                guard let label = child.label else { return [] }
                let inner = "\(path).\(label)"
                return secretFields.contains(label) ? [hidden(child.value, at: inner)] : fields(of: child.value, at: inner)
            }
        case .enum:
            // With a payload only the case is named. The payload can be a display's name, or anything else someone typed.
            let name = mirror.children.first?.label ?? String(describing: value)
            return [Field(path: path, fingerprint: String(reflecting: value), value: .settingName(name))]
        case .dictionary:
            return mirror.children.flatMap { child -> [Field] in
                let pair = Mirror(reflecting: child.value).children.map(\.value)
                guard pair.count == 2, Mirror(reflecting: pair[0]).displayStyle == .enum, Mirror(reflecting: pair[0]).children.isEmpty else { return [hidden(value, at: path)] }
                return fields(of: pair[1], at: "\(path).\(String(describing: pair[0]))")
            }
        default:
            return [hidden(value, at: path)]
        }
    }

    private static func hidden(_ value: Any, at path: String) -> Field {
        Field(path: path, fingerprint: String(reflecting: value), value: nil)
    }
}
