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

/// A global key through Carbon, which needs no Accessibility permission.
@MainActor
final class HotKeyController {
    enum Failure: Error { case taken }

    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var action: (@MainActor () -> Void)?

    func register(_ combo: HotKeyCombo, action: @escaping @MainActor () -> Void) throws {
        unregister()
        self.action = action
        var reference: EventHotKeyRef?
        let id = EventHotKeyID(signature: 0x424F_5253, id: 1)
        let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, id, GetApplicationEventTarget(), 0, &reference)
        guard status == noErr, let reference else { throw Failure.taken }
        self.reference = reference

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, info in
            guard let info else { return noErr }
            let controller = Unmanaged<HotKeyController>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { controller.action?() }
            return noErr
        }, 1, &spec, me, &handler)
    }

    func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
        reference = nil
        handler = nil
    }
}
