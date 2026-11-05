import AppKit
import BorisCore
import BorisData
import Observation

enum AppPage: String, CaseIterable, Identifiable {
    case now, projects, spend, requests, activity, losses, walrus

    var id: String { rawValue }

    var title: String {
        switch self {
        case .now: return L("Now")
        case .projects: return L("Projects")
        case .spend: return L("Usage")
        case .requests: return L("Requests")
        case .activity: return L("Activity")
        case .losses: return L("Losses")
        case .walrus: return L("Walrus")
        }
    }

    /// Activity and losses are for those who want the details.
    func isShown(in mode: DisplayMode) -> Bool {
        mode == .technical || (self != .activity && self != .losses)
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, sources, surfaces, notifications, connections, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return L("General")
        case .sources: return L("Sources")
        case .surfaces: return L("Surfaces")
        case .notifications: return L("Notifications")
        case .connections: return L("Connections")
        case .about: return L("About Boris")
        }
    }
}

/// Everything the screens and the menu bar icon show. Lives on the main thread.
@MainActor
@Observable
final class AppModel {
    let settings: AppSettings
    let hooks: HookController
    let notifications: NotificationHub
    private let store: StateStore?
    private var state: AppState
    private var board = MoodBoard()
    private var engine: WorkEngine?
    private var tokensVersion = -1
    private var tokens: [TokenRecord] = []

    private(set) var work = WorkModel()
    private(set) var world = WorldSnapshot(takenAt: Date())
    private(set) var runs: [RunState] = []
    private(set) var hookState = HookState()
    private(set) var today = TokenUsage()
    private(set) var tokenProgress: WorkEngine.TokenProgress?
    private(set) var loaded = false
    private(set) var mood = Mood.sleeping
    private(set) var outfit = Outfit.none
    private(set) var hasAlarm = false
    private(set) var quiet: QuietMode
    private(set) var now = Date()
    var page = AppPage.now
    var settingsSection = SettingsSection.general
    var showIconNotice = false
    var hotKeyTaken = false
    /// The session a click on a notification asked to show.
    var requestedSession: String?

    var onPresenceChange: (() -> Void)?
    var onEvent: ((BorisEvent, Reaction) -> Void)?

    /// - Parameter store: nil keeps everything in memory.
    init(settings: AppSettings = AppSettings(), store: StateStore? = StateStore(), live: Bool = true) {
        self.settings = settings
        self.store = store
        hooks = HookController(settings: settings, live: live)
        notifications = NotificationHub(settings: settings, live: live)
        var loaded = store?.loadState() ?? AppState()
        if loaded.firstLaunch == nil {
            loaded.firstLaunch = Date()
            store?.save(loaded)
        }
        state = loaded
        quiet = loaded.quiet
        if settings.wardrobe.firstLaunch == nil {
            settings.wardrobe.firstLaunch = loaded.firstLaunch
        }
        hooks.onSignal = { [weak self] signal in self?.receive(signal) }
    }

    func start() {
        let paths = ClaudePaths.resolve(custom: settings.claudeFolder)
        let owner = WeakModel(self)
        let engine = WorkEngine(
            paths: paths,
            runs: state.runs,
            detector: state.detector,
            status: settings.statusConfig,
            events: settings.detectorConfig,
            tokenCache: BorisPaths.tokenIndex,
            others: { ClaudeFolders.others(besides: paths) }
        ) { output in
            Task { @MainActor in owner.model?.apply(output) }
        }
        self.engine = engine
        Task { await engine.start() }
        hooks.refresh()
    }

    /// Reads from another folder after the setting changes.
    func restartEngine() {
        let old = engine
        Task { await old?.stop() }
        start()
    }

    func noteWake() {
        Task { await engine?.noteWake(at: Date()) }
    }

    /// Open windows get fresher data, and closed ones cost nothing.
    func setLookingClosely(_ closely: Bool) {
        Task { await engine?.setFocus(runs: [], lookingClosely: closely) }
    }

    private func receive(_ signal: HookSignal) {
        Task { await engine?.receive(signal) }
    }

    private func apply(_ output: WorkEngine.Output) {
        work = output.model
        world = output.world
        runs = output.runs
        hookState = output.hooks
        tokenProgress = output.tokenProgress
        now = output.at
        loaded = true
        if output.tokensVersion != tokensVersion {
            tokensVersion = output.tokensVersion
            tokens = output.tokens
        }
        today = Self.spent(on: output.at, in: tokens)

        var changed = state.runs != output.runMemory || state.detector != output.detectorMemory
        state.runs = output.runMemory
        state.detector = output.detectorMemory
        let quietDuringScan = quiet.isOn(now: output.at)
        var news: [(event: BorisEvent, reaction: Reaction)] = []
        for event in output.events {
            let wanted = settings.notifications.reaction(for: event, mood: settings.matrix.reaction(for: event.kind).mood)
            let reaction = quiet.filter(wanted, kind: event.kind, now: output.at)
            board.apply(event, reaction: reaction.mood, now: output.at)
            onEvent?(event, reaction)
            news.append((event, reaction))
            changed = true
        }
        notifications.scanned(news, quiet: quietDuringScan, now: output.at)
        if let missed = quiet.finish(now: output.at) {
            notifications.quietEnded(missed: missed, requestsWaiting: requestCount)
            changed = true
        }
        if changed {
            state.quiet = quiet
            store?.save(state)
        }
        refreshPresence()
    }

    static func spent(on date: Date, in records: [TokenRecord]) -> TokenUsage {
        let key = dayKey(date)
        return records.lazy.filter { $0.day == key }.reduce(TokenUsage()) { $0 + $1.usage }
    }

    private static func dayKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    func refreshPresence() {
        let date = Date()
        now = date
        hasAlarm = board.hasAlarm
        mood = board.mood(runs: runs, sessions: world.sessions, formatBroken: !world.formatIssues.isEmpty, matrix: settings.matrix, now: date)
        outfit = Wardrobe.outfit(at: date, settings: settings.wardrobe)
        onPresenceChange?()
    }

    /// Opening the mini window confirms the alarm.
    func miniWindowDidOpen() {
        board.acknowledge()
        refreshPresence()
        setLookingClosely(true)
    }

    func startQuiet(for duration: TimeInterval) {
        quiet.start(for: duration, now: Date())
        state.quiet = quiet
        store?.save(state)
    }

    func stopQuiet() {
        let missed = quiet.cancel()
        state.quiet = quiet
        store?.save(state)
        if let missed { notifications.quietEnded(missed: missed, requestsWaiting: requestCount) }
    }

    /// The thresholds in the settings changed, so the running engine should use them.
    func thresholdsChanged() {
        let status = settings.statusConfig
        let events = settings.detectorConfig
        Task { await engine?.configure(status: status, events: events) }
    }

    /// Where a click on a notification leads.
    func open(_ route: NotificationRoute) {
        switch route {
        case .now:
            page = .now
        case .usage:
            page = .spend
        case .session(let id):
            requestedSession = id
            page = .projects
        case .requests(let id):
            requestedSession = id
            page = .requests
        }
    }

    // MARK: - What the screens ask

    /// Sessions waiting for the person, together with requests that are held here.
    var requestCount: Int {
        Set(work.waitingSessions.map(\.id)).union(hooks.pending.map(\.session)).count
    }

    var activeSessions: [WorkSession] {
        work.sessions.filter { $0.state.isActive && $0.state != .waiting }
    }

    var connectionStatus: ConnectionStatus {
        ConnectionStatus(world: world, hooks: hooks.connection, hookState: hookState, hooksSince: hooks.since, now: now)
    }

    var offerConnecting: Bool {
        get { loaded && world.claudeFolderFound && !state.connectOfferDismissed && hooks.connection == .notConnected }
        set {
            guard !newValue else { return }
            state.connectOfferDismissed = true
            store?.save(state)
        }
    }

    func dismissIconNotice() {
        showIconNotice = false
        state.iconNoticeSeen = true
        store?.save(state)
    }

    /// Asked once per life of the settings: the notice should not come back every day.
    func noteIconHidden() {
        guard !state.iconNoticeSeen else { return }
        showIconNotice = true
    }

    var isFirstLaunch: Bool {
        guard let first = state.firstLaunch else { return true }
        return Date().timeIntervalSince(first) < 5
    }

    func chooseClaudeFolder(_ url: URL) {
        settings.claudeFolder = url.path
        restartEngine()
    }

    func copyDiagnostics() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? BorisCore.version
        let connection = connectionStatus
        Task {
            let report = await engine?.diagnostics(appVersion: version, connection: connection) ?? ""
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(report, forType: .string)
        }
    }

    func persistNow() {
        store?.save(state)
        store?.flush()
    }

    #if DEBUG
    func showForSnapshot(work: WorkModel, world: WorldSnapshot, today: TokenUsage, mood: Mood, outfit: Outfit = .none, offer: Bool = false) {
        self.work = work
        self.world = world
        self.today = today
        self.mood = mood
        self.outfit = outfit
        loaded = true
        state.connectOfferDismissed = !offer
    }
    #endif
}

private struct WeakModel: @unchecked Sendable {
    weak var model: AppModel?

    init(_ model: AppModel) {
        self.model = model
    }
}
