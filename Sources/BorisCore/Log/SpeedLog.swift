import CoreFoundation
import Darwin
import Foundation
import os

/// Where a slow moment happened. A closed list: a line says what kind of page it was, never which project or session it showed.
public enum SpeedPlace: String, Sendable, CaseIterable {
    case none
    case now, projects, project, session, spend, requests, activity, losses, walrus
    case mainWindow, miniWindow, settingsWindow
    case settingsGeneral, settingsSources, settingsSurfaces, settingsNotifications, settingsConnections, settingsLog, settingsAbout
}

/// What happened just before: something the person did, or something the app did on its own on the main thread.
public enum SpeedAction: String, Sendable, CaseIterable {
    case none
    // Any click or key, when nothing more exact is known
    case click, key
    // Going around
    case choosePage, openSession, openProject, backToProjects, openFromNotification, openMainWindow, openMiniWindow, openSettings, chooseSettingsSection
    // Buttons
    case changeDisplayMode, changeFilter, chooseAgent, togglePhase, copyDiagnostics
    // On its own
    case scanApplied, tokensAddedUp, feedArrived, lossesArrived, pastSessionsArrived
}

/// Data read for a page.
public enum SpeedLoad: String, Sendable, CaseIterable {
    case sessionFeed, sessionMerge, activity, activityMerge, pastSessions, sessionList, projectSums, losses, sessionLosses, spendSums
}

/// From how long a moment counts as slow. Below these nothing is written, so a quick click leaves no line.
public struct SpeedThresholds: Sendable, Equatable {
    public var page: TimeInterval
    public var load: TimeInterval
    public var action: TimeInterval
    public var stall: TimeInterval
    /// Rounded values fold into one line when they come back. A measuring run wants them exact.
    public var rounds: Bool

    public init(page: TimeInterval = 0.1, load: TimeInterval = 0.1, action: TimeInterval = 0.1, stall: TimeInterval = 0.15, rounds: Bool = true) {
        self.page = page
        self.load = load
        self.action = action
        self.stall = stall
        self.rounds = rounds
    }

    public static let standard = SpeedThresholds()
    /// Every page, load and click, exact, for a measuring run. A stall still has to be long enough to be one.
    public static let everything = SpeedThresholds(page: 0, load: 0, action: 0, stall: 0.05, rounds: false)
}

/// Notices when the main thread was away, from the marks its run loop leaves: no timer of its own, and nothing at all while the app sleeps.
///
/// A gap between two marks is work the main thread did without looking at anything else, the drawing of a frame included.
/// The time between going to sleep and waking up is rest, and does not count.
public struct StallWatch: Sendable {
    public enum Mark: Sendable {
        /// The run loop goes on to its next piece of work: timers, sources, a run loop inside a run loop, or the end of one.
        case working
        /// It has drawn what changed and is about to sleep.
        case sleeping
        /// It woke up.
        case waking
    }

    private var since: UInt64?

    public init() {}

    /// How long the main thread was away when this mark came, in nanoseconds, if that is at least the threshold.
    public mutating func mark(_ mark: Mark, at now: UInt64, threshold: UInt64) -> UInt64? {
        defer { since = mark == .sleeping ? nil : now }
        guard mark != .waking, let since, now >= since else { return nil }
        let gap = now - since
        return gap >= threshold ? gap : nil
    }
}

/// How long pages, data and buttons take, written to the app log only when it is long enough to feel.
///
/// Everything goes into the area «speed», as names from closed lists, rounded durations and rounded counts. Rounding lets the log fold a slow spot
/// that comes back every second into one line with a count. Any thread may call it.
public enum SpeedLog {
    /// Something the person started, waiting for the frame that shows its result.
    struct Pending: Sendable {
        var action: SpeedAction
        /// The page it leads to. Nil when it is done at the next frame.
        var place: SpeedPlace?
        var startedAt: UInt64
        var appeared: Bool
    }

    struct State: Sendable {
        var thresholds = SpeedThresholds.standard
        var watching = false
        var place = SpeedPlace.none
        var action = SpeedAction.none
        var actionAt: UInt64 = 0
        var pending: Pending?
        var stalls = StallWatch()
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    /// A page that never appears is given up on after this long, rather than counted.
    static let giveUp: UInt64 = 10_000_000_000
    /// A stall is said to come after an action only when the action came this soon before it began.
    static let actionMemory: UInt64 = 1_000_000_000

    /// Nanoseconds that do not move while the Mac sleeps.
    public static func now() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    }

    public static var thresholds: SpeedThresholds {
        get { state.withLock { $0.thresholds } }
        set { state.withLock { $0.thresholds = newValue } }
    }

    /// True while something tells it when frames are drawn, which only the app does. Without that, nothing a person starts is followed.
    public static var isWatching: Bool {
        get { state.withLock { $0.watching } }
        set {
            state.withLock {
                $0.watching = newValue
                $0.pending = nil
                $0.stalls = StallWatch()
            }
        }
    }

    /// The page on screen now, as far as the log knows.
    public static var place: SpeedPlace { state.withLock { $0.place } }

    /// Forgets what was on screen and done, for a test.
    public static func reset() {
        state.withLock { $0 = State() }
    }

    // MARK: - Rounding

    /// To 50 ms below a second, to a quarter of a second below five, and to whole seconds above.
    public static func rounded(milliseconds value: Int) -> Int {
        let step = value < 1000 ? 50 : value < 5000 ? 250 : 1000
        return (value + step / 2) / step * step
    }

    /// Two significant digits from a hundred on: 1234 is 1200.
    public static func roughly(_ count: Int) -> Int {
        guard count >= 100 else { return max(0, count) }
        var scale = 1
        while count / scale >= 100 { scale *= 10 }
        return (count + scale / 2) / scale * scale
    }

    static func milliseconds(_ nanoseconds: UInt64) -> Int {
        Int(min(nanoseconds / 1_000_000, UInt64(Int.max)))
    }

    private static func shown(_ nanoseconds: UInt64, _ thresholds: SpeedThresholds) -> Int {
        thresholds.rounds ? rounded(milliseconds: milliseconds(nanoseconds)) : milliseconds(nanoseconds)
    }

    private static func passes(_ nanoseconds: UInt64, _ threshold: TimeInterval) -> Bool {
        Double(nanoseconds) / 1e9 >= threshold
    }

    // MARK: - Loads

    /// The moment a load starts, to give back to `loaded`.
    public static func start() -> UInt64 { now() }

    /// A load has finished. It goes in only when it took at least the threshold.
    /// - Parameter onMain: whether the reading itself ran on the main thread.
    public static func loaded(_ load: SpeedLoad, since start: UInt64, items: Int, onMain: Bool, now end: UInt64 = SpeedLog.now()) {
        let took = end >= start ? end - start : 0
        let thresholds = thresholds
        guard passes(took, thresholds.load) else { return }
        AppLog.note(.loadSlow, .choice(load), .milliseconds(shown(took, thresholds)), .number(thresholds.rounds ? roughly(items) : items), .flag(onMain))
    }

    /// Times a load done right here, on whatever thread this is.
    public static func measure<T>(_ load: SpeedLoad, items: (T) -> Int, _ work: () throws -> T) rethrows -> T {
        let began = now()
        let result = try work()
        loaded(load, since: began, items: items(result), onMain: pthread_main_np() != 0)
        return result
    }

    // MARK: - What the person does

    /// The person started something. It is timed until the next frame drawn after `place`, if given, has appeared.
    /// A click is noticed before the button hears it, so a more exact name given while handling it keeps the time of the click.
    public static func began(_ action: SpeedAction, to place: SpeedPlace? = nil, now moment: UInt64 = SpeedLog.now()) {
        state.withLock { state in
            guard state.watching else { return }
            var startedAt = moment
            if let pending = state.pending, pending.action == .click || pending.action == .key, action != .click, action != .key {
                startedAt = pending.startedAt
            }
            state.pending = Pending(action: action, place: place, startedAt: startedAt, appeared: place == nil || place == state.place)
            state.action = action
            state.actionAt = moment
        }
    }

    /// Something the app does on its own on the main thread, so that a stall right after it can name it.
    public static func did(_ job: SpeedAction, now moment: UInt64 = SpeedLog.now()) {
        state.withLock { state in
            guard state.watching else { return }
            state.action = job
            state.actionAt = moment
        }
    }

    /// A page or window is on screen.
    public static func appeared(_ place: SpeedPlace) {
        state.withLock { state in
            state.place = place
            if state.pending?.place == place { state.pending?.appeared = true }
        }
    }

    // MARK: - The main thread's run loop

    /// A mark from the main run loop. `sleeping` comes after the frame has been handed over for drawing.
    public static func mainThread(_ mark: StallWatch.Mark, now moment: UInt64 = SpeedLog.now()) {
        enum Line {
            case stall(UInt64, SpeedPlace, SpeedAction)
            case page(SpeedPlace, UInt64, SpeedAction)
            case action(SpeedAction, UInt64, SpeedPlace)
        }
        let (lines, thresholds): ([Line], SpeedThresholds) = state.withLock { state in
            guard state.watching else { return ([], state.thresholds) }
            var lines: [Line] = []
            let threshold = UInt64(max(0, state.thresholds.stall) * 1e9)
            if let gap = state.stalls.mark(mark, at: moment, threshold: threshold) {
                let began = moment - gap
                let recent = state.actionAt > 0 && state.actionAt + actionMemory >= began
                lines.append(.stall(gap, state.place, recent ? state.action : .none))
            }
            if mark == .sleeping, let pending = state.pending {
                let took = moment >= pending.startedAt ? moment - pending.startedAt : 0
                if pending.appeared {
                    state.pending = nil
                    if let place = pending.place {
                        if passes(took, state.thresholds.page) { lines.append(.page(place, took, pending.action)) }
                    } else if passes(took, state.thresholds.action) {
                        lines.append(.action(pending.action, took, state.place))
                    }
                } else if took > giveUp {
                    state.pending = nil
                }
            }
            return (lines, state.thresholds)
        }
        for line in lines {
            switch line {
            case let .stall(gap, place, action):
                AppLog.note(.mainThreadStalled, .milliseconds(shown(gap, thresholds)), .choice(place), .choice(action))
            case let .page(place, took, action):
                AppLog.note(.pageShown, .choice(place), .milliseconds(shown(took, thresholds)), .choice(action))
            case let .action(action, took, place):
                AppLog.note(.actionSlow, .choice(action), .milliseconds(shown(took, thresholds)), .choice(place))
            }
        }
    }
}

/// Puts the marks of the main run loop into `SpeedLog`. Two observers and no timer: while nothing happens, nothing here runs.
public enum MainThreadWatch {
    @MainActor private static var observers: [CFRunLoopObserver] = []

    @MainActor public static var isRunning: Bool { !observers.isEmpty }

    @MainActor public static func start() {
        guard observers.isEmpty else { return }
        // First of all at every step, so that the work of other observers counts in the step it belongs to.
        let working = CFRunLoopActivity([.entry, .beforeTimers, .beforeSources, .afterWaiting, .exit])
        let early = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, working.rawValue, true, CFIndex.min) { _, activity in
            SpeedLog.mainThread(activity == .afterWaiting ? .waking : .working)
        }
        // Last before sleeping: after the frame has been laid out and handed over, which happens in an observer of its own.
        let late = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { _, _ in
            SpeedLog.mainThread(.sleeping)
        }
        for observer in [early, late].compactMap({ $0 }) {
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            observers.append(observer)
        }
        SpeedLog.isWatching = true
    }

    @MainActor public static func stop() {
        for observer in observers {
            CFRunLoopObserverInvalidate(observer)
        }
        observers = []
        SpeedLog.isWatching = false
    }
}
