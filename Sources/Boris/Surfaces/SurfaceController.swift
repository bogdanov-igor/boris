import AppKit
import BorisCore
import Observation
import SwiftUI

extension AppModel {
    /// Whether the hotkey can open the mini window at this moment.
    var hotKeyWorks: Bool { settings.hotKeyEnabled && !hotKeyTaken }
}

/// Everything the surface needs from the model, read in one go, so that a change of any of it can be noticed.
@MainActor
struct SurfaceInputs: Equatable {
    var switches: SurfaceSwitches
    var choice: SurfaceScreenChoice
    var mode: DisplayMode
    var numbers: SurfaceNumbers
    var requests: Int
    var quiet: Bool
    var language: AppLanguage

    init(model: AppModel) {
        switches = model.settings.surfaces
        choice = model.settings.surfaceScreen
        mode = model.settings.displayMode
        numbers = SurfaceNumbers(work: model.work, requests: model.requestCount, today: model.today, usage: model.world.usage)
        requests = model.hooks.pending.count
        quiet = model.quiet.isOn(now: model.now)
        language = model.settings.language
    }
}

/// What the surface's views show right now.
@MainActor
@Observable
final class SurfaceStage {
    var isOpen = false
    var hasNotch = false
    var closedNotch = SurfaceGeometry.ClosedNotch()
    var line = SurfaceLine()
    var headerLine = SurfaceLine()
    var openWidth = SurfaceGeometry.openPanelWidth
    var maximumHeight: CGFloat = 600
    var isQuiet = false

    /// Fills in the stage and returns where the window belongs.
    func arrange(_ inputs: SurfaceInputs, on screen: SurfaceScreen, isOpen: Bool, contentHeight: CGFloat, spoken: String?) -> CGRect {
        let notch = screen.notch
        var line = SurfaceWords.closedLine(inputs.numbers, mode: inputs.mode, onNotch: notch != nil)
        var header = SurfaceWords.closedLine(inputs.numbers, mode: .simple, onNotch: notch != nil)
        if let spoken {
            line = SurfaceLine(main: spoken)
            header = line
        }
        self.isOpen = isOpen
        isQuiet = inputs.numbers.waiting == 0 && inputs.numbers.agents == 0
        hasNotch = notch != nil
        self.line = line
        headerLine = header
        openWidth = SurfaceGeometry.openWidth(on: screen)
        maximumHeight = SurfaceGeometry.maximumOpenHeight(on: screen)
        if let notch {
            closedNotch = SurfaceGeometry.closedNotch(
                on: screen,
                notch: notch,
                textWidth: SurfaceMetrics.textWidth(line, size: SurfaceMetrics.notchText),
                minimumWidth: SurfaceWords.closedNotchWidth(inputs.numbers, mode: inputs.mode)
            )
        }
        if isOpen { return SurfaceGeometry.open(on: screen, contentHeight: contentHeight) }
        if notch != nil { return closedNotch.frame }
        return SurfaceGeometry.closedPill(on: screen, contentWidth: SurfaceMetrics.pillWidth(line))
    }
}

/// Keeps the notch or the panel on the right screen, in the right state and out of the way of the active app.
@MainActor
final class SurfaceController {
    private let model: AppModel
    private let screens: @MainActor () -> [SurfaceScreen]
    private let stage = SurfaceStage()
    private let panel = SurfacePanel()
    private var host: SurfaceHostingView<AnyView>?
    private var behavior = SurfaceBehavior()
    private var inputs: SurfaceInputs?
    private var screen: SurfaceScreen?
    private var iconShown: Bool?
    private var pointerInside = false
    private var pointerTask: Task<Void, Never>?
    private var spoken: String?
    private var speechTask: Task<Void, Never>?
    private var contentHeight: CGFloat = 240
    private var mouseMonitor: Any?
    private var pointerWatch: Timer?
    private var observers: [NSObjectProtocol] = []

    var onOpenMain: (() -> Void)?
    var onOpenSettings: ((SettingsSection) -> Void)?
    var onIconSwitch: (() -> Void)?

    /// - Parameter screens: a test can pass a made-up screen that nobody sees.
    init(model: AppModel, screens: @escaping @MainActor () -> [SurfaceScreen] = SurfaceScreens.current) {
        self.model = model
        self.screens = screens
    }

    func start() {
        let host = SurfaceHostingView(rootView: AnyView(SurfaceView(
            model: model,
            stage: stage,
            speak: { [weak self] in self?.speak() },
            openMain: { [weak self] in self?.onOpenMain?() },
            openSettings: { [weak self] in self?.onOpenSettings?(.surfaces) },
            contentHeight: { [weak self] in self?.contentHeightChanged($0) }
        )))
        host.onHover = { [weak self] inside in self?.pointer(inside: inside) }
        self.host = host
        panel.contentView = host
        panel.onKeyChange = { [weak self] typing in
            self?.behavior.typingChanged(typing)
            self?.arrange(animated: true)
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.arrange(animated: false) }
        })
        // Mouse events need no permission. This one also catches the pointer leaving when the window moved from under it.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMovedElsewhere() }
        }
        // That monitor hears nothing while Boris itself is active, with Settings open for example.
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.watchPointer(true) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.watchPointer(false) }
        })
        follow()
    }

    private func watchPointer(_ on: Bool) {
        pointerWatch?.invalidate()
        pointerWatch = nil
        guard on else { return }
        pointerWatch = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMovedElsewhere() }
        }
    }

    private func follow() {
        let inputs = withObservationTracking {
            SurfaceInputs(model: model)
        } onChange: { [weak self] in
            Task { @MainActor in self?.follow() }
        }
        guard inputs != self.inputs else { return }
        if self.inputs?.switches.notch == true, !inputs.switches.notch { behavior = SurfaceBehavior() }
        let cardWent = inputs.requests < (self.inputs?.requests ?? 0)
        self.inputs = inputs
        behavior.requestsChanged(to: inputs.requests, quiet: inputs.quiet)
        arrange(animated: true)
        guard cardWent else { return }
        // SwiftUI takes the card and its field away only after this moment.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            self?.returnKeyboardIfNoField()
        }
    }

    private func arrange(animated: Bool) {
        guard let inputs else { return }
        if iconShown != inputs.switches.icon {
            iconShown = inputs.switches.icon
            onIconSwitch?()
        }
        let cursor = NSEvent.mouseLocation
        guard inputs.switches.notch, let screen = SurfaceGeometry.screen(for: inputs.choice, among: screens(), cursor: cursor) else {
            panel.orderOut(nil)
            return
        }
        let moved = screen.id != self.screen?.id
        self.screen = screen
        let frame = stage.arrange(inputs, on: screen, isOpen: behavior.isOpen, contentHeight: contentHeight, spoken: spoken)
        host?.appearance = stage.hasNotch ? NSAppearance(named: .darkAqua) : nil
        panel.hasShadow = !stage.hasNotch
        if !behavior.isOpen { returnKeyboard() }
        if panel.frame != frame { place(frame, animated: animated && !moved && panel.isVisible) }
        if !panel.isVisible { panel.orderFrontRegardless() }
        // The shadow follows what is drawn, and the corners change with the state.
        if panel.hasShadow { panel.invalidateShadow() }
    }

    private func place(_ frame: CGRect, animated: Bool) {
        // Through the animator even without animation: a frame set directly is overwritten by a resize still under way.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.16 : 0
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
        }
    }

    /// A closed surface has nothing to type in, so the keyboard goes back to where it was.
    private func returnKeyboard() {
        guard panel.isKeyWindow else { return }
        panel.orderOut(nil)
        panel.orderFrontRegardless()
    }

    /// The field can go away with its card, answered here or anywhere else, or when the person steps back from the form.
    private func returnKeyboardIfNoField() {
        if !panel.isTyping { returnKeyboard() }
    }

    private func contentHeightChanged(_ height: CGFloat) {
        guard height > 0, abs(height - contentHeight) > 0.5 else { return }
        contentHeight = height
        if behavior.isOpen { arrange(animated: true) }
    }

    /// A short pause before opening, so that going past on the way to the menu bar does not open anything,
    /// and before closing, so that slipping off the edge does not close it.
    private func pointer(inside: Bool) {
        pointerInside = inside
        pointerTask?.cancel()
        pointerTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(inside ? 120 : 250))
            guard !Task.isCancelled, let self else { return }
            let really = SurfaceGeometry.contains(self.panel.frame, NSEvent.mouseLocation)
            guard really == inside else { return }
            if inside {
                self.behavior.pointerEntered()
            } else {
                self.returnKeyboardIfNoField()
                self.behavior.pointerLeft()
            }
            self.arrange(animated: true)
        }
    }

    /// These events are the active app's, so they also come while the pointer is on the surface: only its real position tells.
    private func pointerMovedElsewhere() {
        let cursor = NSEvent.mouseLocation
        if pointerInside, !SurfaceGeometry.contains(panel.frame, cursor) { pointer(inside: false) }
        if inputs?.choice == .followCursor, let screen, !SurfaceGeometry.contains(screen.frame, cursor) {
            arrange(animated: false)
        }
    }

    /// A click on the walrus: he says how things are, for a moment.
    private func speak() {
        spoken = MainPhrases.walrusLine(waiting: model.requestCount, working: model.activeSessions.count)
        arrange(animated: true)
        speechTask?.cancel()
        speechTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let self else { return }
            self.spoken = nil
            self.arrange(animated: true)
        }
    }
}
