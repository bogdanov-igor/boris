import Foundation

public enum Surface: Sendable, CaseIterable {
    case icon, notch, mini
}

/// Which compact surfaces are on. At least one way to open Boris has to stay.
public struct SurfaceSwitches: Codable, Sendable, Equatable {
    public var icon: Bool
    public var notch: Bool
    public var mini: Bool

    public init(icon: Bool = true, notch: Bool = true, mini: Bool = true) {
        self.icon = icon
        self.notch = notch
        self.mini = mini
    }

    public subscript(surface: Surface) -> Bool {
        get {
            switch surface {
            case .icon: return icon
            case .notch: return notch
            case .mini: return mini
            }
        }
        set {
            switch surface {
            case .icon: icon = newValue
            case .notch: notch = newValue
            case .mini: mini = newValue
            }
        }
    }

    /// The mini window has no place of its own: without the icon only the hotkey opens it.
    public func leavesWayIn(hotKeyWorks: Bool) -> Bool {
        icon || notch || (mini && hotKeyWorks)
    }

    public func canTurnOff(_ surface: Surface, hotKeyWorks: Bool) -> Bool {
        var after = self
        after[surface] = false
        return after.leavesWayIn(hotKeyWorks: hotKeyWorks)
    }

    /// The hotkey can stop working after the surfaces were chosen: another program takes it, say. The icon then comes back.
    public func withWayIn(hotKeyWorks: Bool) -> SurfaceSwitches {
        guard !leavesWayIn(hotKeyWorks: hotKeyWorks) else { return self }
        var repaired = self
        repaired.icon = true
        return repaired
    }
}

/// When the notch or the panel is open.
public struct SurfaceBehavior: Sendable, Equatable {
    public private(set) var isOpen = false
    private var hovering = false
    private var typing = false
    private var requests = 0

    public init() {}

    public mutating func pointerEntered() {
        hovering = true
        isOpen = true
    }

    /// Passing the pointer over an open surface also dismisses it: the closed one still says who is waiting.
    public mutating func pointerLeft() {
        hovering = false
        if !typing { isOpen = false }
    }

    /// A new request opens the surface, unless the person asked for quiet: it then waits in the counter and the queue.
    public mutating func requestsChanged(to count: Int, quiet: Bool) {
        if count > requests, !quiet { isOpen = true }
        if count == 0, requests > 0, !hovering, !typing { isOpen = false }
        requests = count
    }

    /// The person clicked into a text field of a card, so moving the pointer away must not close what is being written.
    public mutating func typingChanged(_ typing: Bool) {
        self.typing = typing
        if !typing, !hovering { isOpen = false }
    }
}
