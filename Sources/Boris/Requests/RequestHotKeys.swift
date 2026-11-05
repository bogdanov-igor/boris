import AppKit
import BorisCore
import Carbon.HIToolbox
import SwiftUI

extension HotKeyCombo {
    /// ⌥⌘Y.
    static let allowStandard = HotKeyCombo(keyCode: UInt32(kVK_ANSI_Y), carbonModifiers: UInt32(cmdKey | optionKey))
    /// ⌥⌘N.
    static let denyStandard = HotKeyCombo(keyCode: UInt32(kVK_ANSI_N), carbonModifiers: UInt32(cmdKey | optionKey))

    /// Enter never answers a request, with any modifier.
    var isEnter: Bool {
        keyCode == UInt32(kVK_Return) || keyCode == UInt32(kVK_ANSI_KeypadEnter)
    }

    /// Stored settings can hold anything, so this is asked when they are read as well as when a key is chosen.
    var canAnswer: Bool {
        !isEnter && carbonModifiers & UInt32(cmdKey | optionKey | controlKey) != 0
    }
}

/// The two keys for answering. They are held only while there is a card they can act on, and at any other moment the combination belongs to the active app.
@MainActor
final class RequestHotKeys {
    var onAllow: () -> Void = {}
    var onDeny: () -> Void = {}
    private(set) var taken = false

    private let allowing = HotKeyController(id: 2)
    private let denying = HotKeyController(id: 3)
    private var heldAllow: HotKeyCombo?
    private var heldDeny: HotKeyCombo?

    /// - Parameter allow: the combination to hold, or nil to let it go.
    func apply(allow: HotKeyCombo?, deny: HotKeyCombo?) {
        let allowTaken = hold(allow, with: allowing, held: &heldAllow) { [weak self] in self?.onAllow() }
        let denyTaken = hold(deny, with: denying, held: &heldDeny) { [weak self] in self?.onDeny() }
        taken = allowTaken || denyTaken
    }

    /// Returns whether another app has the combination. One that failed is tried again next time, because it may have been freed.
    private func hold(_ combo: HotKeyCombo?, with key: HotKeyController, held: inout HotKeyCombo?, action: @escaping @MainActor () -> Void) -> Bool {
        guard combo != held else { return false }
        key.unregister()
        held = nil
        guard let combo else { return false }
        do {
            try key.register(combo, action: action)
            held = combo
            return false
        } catch {
            return true
        }
    }
}

/// Tells whether the window holding a card is really on screen. A covered, minimised or closed window frees the keys.
struct RequestWindowProbe: NSViewRepresentable {
    var onChange: (Bool) -> Void
    /// The card has left the screen for good.
    var onGone: () -> Void

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onChange = onChange
        view.onGone = onGone
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.onChange = onChange
        view.onGone = onGone
    }

    static func dismantleNSView(_ view: ProbeView, coordinator: ()) {
        view.stop()
    }

    final class ProbeView: NSView {
        var onChange: (Bool) -> Void = { _ in }
        var onGone: () -> Void = {}
        private var observers: [NSObjectProtocol] = []
        private var last: Bool?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeObservers()
            if let window {
                let center = NotificationCenter.default
                for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification] {
                    observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                        let closing = note.name == NSWindow.willCloseNotification
                        MainActor.assumeIsolated { self?.report(closing: closing) }
                    })
                }
            }
            report(closing: false)
        }

        private func report(closing: Bool) {
            let shows = !closing && window?.isVisible == true && window?.occlusionState.contains(.visible) == true
            guard shows != last else { return }
            last = shows
            // Layout is in progress here, and the keys change what is drawn.
            let onChange = onChange
            DispatchQueue.main.async { onChange(shows) }
        }

        func stop() {
            removeObservers()
            let onGone = onGone
            DispatchQueue.main.async { onGone() }
        }

        private func removeObservers() {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers = []
        }
    }
}
