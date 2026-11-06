import AppKit
import BorisCore
import Observation
import SwiftUI

extension AppModel {
    /// Whether the hotkey can open the mini window at this moment.
    var hotKeyWorks: Bool { settings.hotKeyEnabled && !hotKeyTaken }

    var surfaceNumbers: SurfaceNumbers {
        SurfaceNumbers(work: work, requests: requestCount, today: usage.book == nil ? nil : today, usage: world.usage)
    }
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
    /// What the walrus is saying now. It takes the place of the numbers for as long as it lasts.
    var spoken: String?
    /// Nothing else opens Boris, so a surface with no room still has to be reachable.
    var lastWayIn: Bool

    init(model: AppModel) {
        switches = model.settings.surfaces
        choice = model.settings.surfaceScreen
        mode = model.settings.displayMode
        numbers = model.surfaceNumbers
        requests = model.hooks.pending.count
        quiet = model.quiet.isOn(now: model.now)
        language = model.settings.language
        spoken = model.walrus.line?.text
        lastWayIn = switches.notch && !switches.canTurnOff(.notch, hotKeyWorks: model.hotKeyWorks)
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
    /// The panel's strip in the menu bar, if it has one now, and where its parts stand inside the window.
    var strip: CGRect?
    var stripInset: CGFloat = 0
    var sheetInset: CGFloat = 0

    /// Fills in the stage and returns where the window belongs. Nil means nothing is on screen.
    /// - Parameter around: where the pointer reached the top edge of a hidden menu bar, if that is what opened the panel.
    func arrange(_ inputs: SurfaceInputs, on screen: SurfaceScreen, isOpen: Bool, contentHeight: CGFloat, around: CGFloat? = nil) -> SurfacePlacement? {
        let notch = screen.notch
        self.isOpen = isOpen
        isQuiet = inputs.numbers.waiting == 0 && inputs.numbers.agents == 0
        hasNotch = notch != nil
        headerLine = inputs.spoken.map { SurfaceLine(main: $0) } ?? SurfaceWords.closedLine(inputs.numbers, mode: .simple, onNotch: notch != nil)
        openWidth = SurfaceGeometry.openWidth(on: screen)
        maximumHeight = SurfaceGeometry.maximumOpenHeight(on: screen)
        guard let notch else { return arrangePanel(inputs, on: screen, isOpen: isOpen, contentHeight: contentHeight, around: around) }

        strip = nil
        line = inputs.spoken.map { SurfaceLine(main: $0) } ?? SurfaceWords.closedLine(inputs.numbers, mode: inputs.mode, onNotch: true)
        closedNotch = SurfaceGeometry.closedNotch(
            on: screen,
            notch: notch,
            textWidth: SurfaceMetrics.textWidth(line, size: SurfaceMetrics.notchText),
            minimumWidth: SurfaceWords.closedNotchWidth(inputs.numbers, mode: inputs.mode)
        )
        return SurfacePlacement(frame: isOpen ? SurfaceGeometry.open(on: screen, contentHeight: contentHeight) : closedNotch.frame)
    }

    private func arrangePanel(_ inputs: SurfaceInputs, on screen: SurfaceScreen, isOpen: Bool, contentHeight: CGFloat, around: CGFloat?) -> SurfacePlacement? {
        let lines = SurfaceWords.stripLines(inputs.numbers, mode: inputs.mode, spoken: inputs.spoken)
        let height = screen.menuBar > 0 ? screen.menuBar : SurfaceGeometry.hiddenStripHeight
        let placement = SurfaceGeometry.panel(
            on: screen,
            widths: lines.map { SurfaceMetrics.stripWidth($0, height: height) },
            isOpen: isOpen,
            contentHeight: contentHeight,
            // In quiet hours a request waits in the counter and the queue: it does not come to the screen, not even small.
            requestWaiting: inputs.requests > 0 && !inputs.quiet,
            lastWayIn: inputs.lastWayIn,
            around: around
        )
        line = placement.map { lines[$0.choice] } ?? SurfaceLine()
        strip = placement?.strip
        stripInset = placement.flatMap { place in place.strip.map { $0.minX - place.frame.minX } } ?? 0
        sheetInset = placement.flatMap { place in place.sheet.map { $0.minX - place.frame.minX } } ?? 0
        return placement
    }
}

/// Keeps the notch or the panel on the right screen, in the right state and out of the way of the active app.
@MainActor
final class SurfaceController {
    private let model: AppModel
    private let screens: @MainActor ([ScreenWindow]) -> [SurfaceScreen]
    private let readWindows: @MainActor () -> [ScreenWindow]
    private let stage = SurfaceStage()
    private let panel = SurfacePanel()
    private var host: SurfaceHostingView<AnyView>?
    private var behavior = SurfaceBehavior()
    private var inputs: SurfaceInputs?
    private var screen: SurfaceScreen?
    /// What the last reading of the menu bars found. Reading costs too much to do on every redraw.
    private var windows: [ScreenWindow] = []
    private var menuBarWatch: Timer?
    /// Where the surface is now. Nil while nothing is on screen.
    private var placement: SurfacePlacement?
    private var shownOpen = false
    private var iconShown: Bool?
    private var pointerInside = false
    /// Where the pointer reached the top edge of a hidden menu bar, while the panel it opened there is open.
    private var edgeEntry: CGFloat?
    private var pointerTask: Task<Void, Never>?
    private var contentHeight: CGFloat = 240
    private var mouseMonitor: Any?
    private var pointerWatch: Timer?
    private var observers: [NSObjectProtocol] = []
    private var panelLog = PanelLogTrack()

    var onOpenMain: (() -> Void)?
    var onOpenSettings: ((SettingsSection) -> Void)?
    var onIconSwitch: (() -> Void)?

    /// - Parameter screens: a test can pass a made-up screen that nobody sees.
    init(
        model: AppModel,
        screens: @escaping @MainActor ([ScreenWindow]) -> [SurfaceScreen] = { SurfaceScreens.current(windows: $0) },
        readWindows: @escaping @MainActor () -> [ScreenWindow] = MenuBarWindows.read
    ) {
        self.model = model
        self.screens = screens
        self.readWindows = readWindows
    }

    func start() {
        let host = SurfaceHostingView(rootView: AnyView(SurfaceView(
            model: model,
            stage: stage,
            speak: { [weak self] in _ = self?.model.pokeWalrus() },
            openMain: { [weak self] in self?.onOpenMain?() },
            openSettings: { [weak self] in self?.onOpenSettings?(.surfaces) },
            contentHeight: { [weak self] in self?.contentHeightChanged($0) }
        )))
        // The clear part of the window also reports the pointer, so the event only says it is time to look.
        host.onHover = { [weak self] _ in self?.pointerMoved() }
        self.host = host
        panel.contentView = host
        panel.onKeyChange = { [weak self] typing in
            self?.behavior.typingChanged(typing)
            self?.arrange(animated: true)
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.windows = []
                self?.menuBarsChanged()
            }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.menuBarsChanged() }
        })
        // Mouse events need no permission. This one also catches the pointer leaving when the window moved from under it.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
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
            MainActor.assumeIsolated { self?.pointerMoved() }
        }
    }

    var isWatchingMenuBars: Bool { menuBarWatch != nil }

    /// Only the panel depends on the menu bars, and only a surface that is on. With the surface off, or on a Mac with nothing but its own notched screen, nothing wakes up for them.
    /// - Returns: whether they are worth reading.
    @discardableResult
    func watchMenuBars(surfaceOn: Bool) -> Bool {
        let needed = surfaceOn && screens([]).contains { $0.notch == nil }
        if !needed {
            menuBarWatch?.invalidate()
            menuBarWatch = nil
        } else if menuBarWatch == nil {
            // An icon that comes or grows announces nothing.
            let watch = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.readMenuBars()
                    self?.arrange(animated: true)
                }
            }
            watch.tolerance = 3
            menuBarWatch = watch
        }
        return needed
    }

    private func readMenuBars() {
        guard watchMenuBars(surfaceOn: inputs?.switches.notch == true) else { return }
        // The panel itself sits on the icons' layer and must not push itself away.
        windows = readWindows().filter { $0.number != panel.windowNumber }
    }

    /// A monitor that just came and a window going full screen take their final place only after a moment, so one look now is not enough.
    private func menuBarsChanged() {
        readMenuBars()
        arrange(animated: false)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.readMenuBars()
            self?.arrange(animated: false)
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
        let needsReading = inputs.switches.notch != self.inputs?.switches.notch || inputs.choice != self.inputs?.choice
        self.inputs = inputs
        if needsReading { readMenuBars() }
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
        guard inputs.switches.notch, let screen = SurfaceGeometry.screen(for: inputs.choice, among: screens(windows), cursor: cursor) else {
            placement = nil
            panel.orderOut(nil)
            return
        }
        let moved = screen.id != self.screen?.id
        self.screen = screen
        let isOpen = behavior.isOpen
        if !isOpen { edgeEntry = nil }
        panelLog.note(isOpen: isOpen, hovering: pointerInside)
        guard let placement = stage.arrange(inputs, on: screen, isOpen: isOpen, contentHeight: contentHeight, around: edgeEntry) else {
            self.placement = nil
            panel.orderOut(nil)
            return
        }
        self.placement = placement
        let frame = placement.frame
        host?.appearance = stage.hasNotch ? NSAppearance(named: .darkAqua) : nil
        // A closed panel is part of the menu bar, and a shadow would fall on the window below it. With no menu bar it lies on that window itself.
        panel.hasShadow = !stage.hasNotch && (isOpen || screen.menuBar <= 0)
        if !isOpen { returnKeyboard() }
        // The strip stands still while the window around it changes, and an animated window would carry it along.
        let keepsShape = stage.hasNotch || shownOpen == isOpen
        shownOpen = isOpen
        if panel.frame != frame { place(frame, animated: animated && !moved && panel.isVisible && keepsShape) }
        if !panel.isVisible { panel.orderFrontRegardless() }
        // The shadow follows what is drawn, and the corners change with the state.
        if panel.hasShadow { panel.invalidateShadow() }
    }

    private func place(_ frame: CGRect, animated: Bool) {
        // Through the animator even without animation: a frame set directly is overwritten by a resize still under way.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.16 : 0
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            // Without animation the window waits for the views, so the strip is not seen in the wrong place for a moment.
            panel.animator().setFrame(frame, display: animated)
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
    /// The strip lies right on the way from the menus to the icons, so it waits longer than the notch.
    private func pointer(inside: Bool) {
        pointerInside = inside
        pointerTask?.cancel()
        let opening = stage.hasNotch ? 120 : 220
        pointerTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(inside ? opening : 250))
            guard !Task.isCancelled, let self else { return }
            let really = self.isOnSurface(NSEvent.mouseLocation)
            guard really == inside else { return }
            if inside {
                // With nothing on screen, this can only be the top edge of a hidden menu bar.
                if self.placement == nil { self.edgeEntry = NSEvent.mouseLocation.x }
                self.behavior.pointerEntered()
            } else {
                self.returnKeyboardIfNoField()
                self.behavior.pointerLeft()
            }
            self.arrange(animated: true)
        }
    }

    private func isOnSurface(_ cursor: CGPoint) -> Bool {
        if let placement { return placement.holds(cursor) }
        // With the menu bar hidden and nothing else to open Boris with, the top edge of the screen stands in for the strip.
        guard inputs?.lastWayIn == true, let screen else { return false }
        return SurfaceGeometry.isAtHiddenBarEdge(of: screen, cursor)
    }

    /// These events are the active app's, so they also come while the pointer is on the surface: only its real position tells.
    private func pointerMoved() {
        let cursor = NSEvent.mouseLocation
        let inside = isOnSurface(cursor)
        if inside != pointerInside { pointer(inside: inside) }
        if inputs?.choice == .followCursor, let screen, !SurfaceGeometry.contains(screen.frame, cursor) {
            arrange(animated: false)
        }
    }
}
