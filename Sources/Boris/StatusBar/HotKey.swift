import AppKit
import BorisCore
import Carbon.HIToolbox

struct HotKeyCombo: Codable, Equatable, Sendable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    /// ⌥⌘O.
    static let standard = HotKeyCombo(keyCode: UInt32(kVK_ANSI_O), carbonModifiers: UInt32(cmdKey | optionKey))

    var label: String {
        var text = ""
        if carbonModifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + Self.keyName(keyCode)
    }

    init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        // A global key needs a modifier, otherwise it would swallow typing everywhere.
        guard modifiers & UInt32(cmdKey | optionKey | controlKey) != 0 else { return nil }
        self.init(keyCode: UInt32(event.keyCode), carbonModifiers: modifiers)
    }

    /// Named by a Latin layout, so ⌥⌘O does not turn into ⌥⌘Щ while the keyboard is on Russian.
    private static func keyName(_ code: UInt32) -> String {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return "\(code)" }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        var dead: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = data.withUnsafeBytes { buffer -> OSStatus in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &length, &chars)
        }
        guard status == noErr, length > 0 else { return "\(code)" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}

private let hotKeySignature: OSType = 0x424F_5253

/// A global key through Carbon, which needs no Accessibility permission.
@MainActor
final class HotKeyController {
    enum Failure: Error { case taken }

    // Reached from deinit too, when nothing else can be using them.
    private nonisolated(unsafe) var reference: EventHotKeyRef?
    private nonisolated(unsafe) var handler: EventHandlerRef?
    private var action: (@MainActor () -> Void)?
    private let id: UInt32

    /// - Parameter id: tells this key from the others the app holds. Each controller needs its own.
    init(id: UInt32 = 1) {
        self.id = id
    }

    /// A handler left behind would point at freed memory, and a key left behind would stay taken.
    deinit {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
    }

    func register(_ combo: HotKeyCombo, action: @escaping @MainActor () -> Void) throws {
        unregister()
        guard !Self.isTaken(combo) else { throw Failure.taken }
        self.action = action
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, EventHotKeyID(signature: hotKeySignature, id: id), GetApplicationEventTarget(), 0, &reference)
        guard status == noErr, let reference else { throw Failure.taken }
        self.reference = reference

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, info in
            guard let info, let event else { return OSStatus(eventNotHandledErr) }
            var pressed = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            let controller = Unmanaged<HotKeyController>.fromOpaque(info).takeUnretainedValue()
            // Every handler in the app hears every key. Passing on what is not ours keeps ⌥⌘O from answering a request.
            guard status == noErr, pressed.signature == hotKeySignature, pressed.id == controller.id else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated { controller.action?() }
            return noErr
        }, 1, &spec, me, &handler)
    }

    /// Whether this key would never reach Boris. A plain registration succeeds anyway, so the question has to be asked apart from it.
    /// Another app's plain registration cannot be seen, and it does no harm: both apps hear the key.
    static func isTaken(_ combo: HotKeyCombo) -> Bool {
        if isSystemShortcut(combo) { return true }
        // This fails for a key held exclusively by another app or by this one. It is let go at once: holding on would silence other apps.
        var probe: EventHotKeyRef?
        let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, EventHotKeyID(signature: hotKeySignature, id: 0), GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &probe)
        if let probe { UnregisterEventHotKey(probe) }
        return status != noErr
    }

    /// The shortcuts in System Settings, such as ⌘Space, come before any app's. Reading them needs no permission.
    private static func isSystemShortcut(_ combo: HotKeyCombo) -> Bool {
        var list: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&list) == noErr, let shortcuts = list?.takeRetainedValue() as? [[String: Any]] else { return false }
        return matches(combo, shortcuts: shortcuts)
    }

    static func matches(_ combo: HotKeyCombo, shortcuts: [[String: Any]]) -> Bool {
        let modifiers = UInt32(cmdKey | optionKey | controlKey | shiftKey)
        return shortcuts.contains { shortcut in
            shortcut[kHISymbolicHotKeyEnabled as String] as? Bool == true
                && shortcut[kHISymbolicHotKeyCode as String] as? Int == Int(combo.keyCode)
                && (shortcut[kHISymbolicHotKeyModifiers as String] as? Int).map { UInt32(truncatingIfNeeded: $0) & modifiers } == combo.carbonModifiers & modifiers
        }
    }

    func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
        reference = nil
        handler = nil
    }
}
