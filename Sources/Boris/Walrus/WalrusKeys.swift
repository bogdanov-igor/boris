import AppKit
import BorisCore

/// Keys typed in the main window, for the walrus's tricks. It only listens: every key goes on to wherever it was going.
@MainActor
final class WalrusKeyWatch {
    private let window: () -> NSWindow?
    private let heard: (PlayKey) -> Void
    private var monitor: Any?

    init(window: @escaping () -> NSWindow?, heard: @escaping (PlayKey) -> Void) {
        self.window = window
        self.heard = heard
    }

    /// Called whenever the window opens. Nothing runs until a key is pressed.
    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.take(event)
            return event
        }
    }

    private func take(_ event: NSEvent) {
        guard let window = window(), event.window === window, !event.isARepeat, Self.listens(to: window.firstResponder),
              let key = Self.playKey(keyCode: event.keyCode, characters: event.characters, modifiers: event.modifierFlags) else { return }
        heard(key)
    }

    /// Typing into a field is the person's own text, and none of his business.
    static func listens(to responder: NSResponder?) -> Bool {
        !(responder is NSText)
    }

    /// Arrows and typed characters, so a space or a digit breaks a word. A shortcut is not a trick.
    static func playKey(keyCode: UInt16, characters: String?, modifiers: NSEvent.ModifierFlags) -> PlayKey? {
        guard modifiers.intersection([.command, .control, .option]).isEmpty else { return nil }
        switch keyCode {
        case 126: return .up
        case 125: return .down
        case 123: return .left
        case 124: return .right
        default:
            // Return, Escape, Tab and the function keys have no character of their own.
            guard let characters, characters.count == 1, !characters.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || (0xF700...0xF8FF).contains($0.value) }) else { return nil }
            return .character(characters)
        }
    }
}
