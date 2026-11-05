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

/// Where the page «Projects» is: the list, one project (nil is «No project»), or one session.
enum ProjectsRoute: Hashable {
    case list
    case project(String?)
    case session(String)
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
    private let store: StateStore?
    private var state: AppState
    private var board = MoodBoard()
    private var engine: WorkEngine?
    private var tokensVersion = -1
    private var focusedRuns: Set<String> = []
    private var pastRead = Date.distantPast
    private var pastReading = false

    private(set) var work = WorkModel()
    private(set) var world = WorldSnapshot(takenAt: Date())
    private(set) var runs: [RunState] = []
    private(set) var hookState = HookState()
    private(set) var today = TokenUsage()
    private(set) var tokens: [TokenRecord] = []
    private(set) var spendIndex = SpendIndex()
    /// Every session in Claude's logs. Empty until the page «Projects» first asks.
    private(set) var pastSessions: [WorkSession] = []
    private(set) var pastLoaded = false
    private(set) var tokenProgress: WorkEngine.TokenProgress?
    private(set) var loaded = false
    private(set) var mood = Mood.sleeping
    private(set) var outfit = Outfit.none
    private(set) var hasAlarm = false
    private(set) var quiet: QuietMode
    private(set) var now = Date()
    var page = AppPage.now
    var projectsRoute = ProjectsRoute.list
    var projectFilter = ProjectFilter()
    /// The open phases of workflows, kept while going from page to page.
    var expandedPhases: Set<String> = []
    /// The agent the session's feed is limited to. Nil shows all of them.
    var feedAgent: String?
    var settingsSection = SettingsSection.general
    var showIconNotice = false
    var hotKeyTaken = false

    var onPresenceChange: (() -> Void)?
    /// Brings the main window forward, from wherever a session is being opened.
    var onShowMainWindow: (() -> Void)?
    var onEvent: ((BorisEvent, Reaction) -> Void)?

    /// - Parameter store: nil keeps everything in memory.
    init(settings: AppSettings = AppSettings(), store: StateStore? = StateStore(), live: Bool = true) {
        self.settings = settings
        self.store = store
        hooks = HookController(settings: settings, live: live)
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
        Task { [focusedRuns] in await engine?.setFocus(runs: focusedRuns, lookingClosely: closely) }
    }

    /// The runs and agents of an open session are read more often. Closing the page gives that up.
    func focus(on runs: Set<String>) {
        guard runs != focusedRuns else { return }
        focusedRuns = runs
        setLookingClosely(true)
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
            spendIndex = SpendIndex(output.tokens)
        }
        if page == .projects { refreshPastSessions() }
        today = Self.spent(on: output.at, in: tokens)

        var changed = state.runs != output.runMemory || state.detector != output.detectorMemory
        state.runs = output.runMemory
        state.detector = output.detectorMemory
        for event in output.events {
            let reaction = settings.matrix.reaction(for: event.kind)
            board.apply(event, reaction: reaction.mood, now: output.at)
            onEvent?(event, quiet.filter(reaction, kind: event.kind, now: output.at))
            changed = true
        }
        if quiet.finish(now: output.at) != nil {
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
        quiet.cancel()
        state.quiet = quiet
        store?.save(state)
    }

    // MARK: - Going around

    /// Opens a session from any surface.
    func openSession(_ id: String) {
        projectsRoute = .session(id)
        feedAgent = nil
        page = .projects
        refreshPastSessions()
        onShowMainWindow?()
    }

    func openProject(_ path: String?) {
        projectsRoute = .project(path)
        page = .projects
    }

    /// Choosing the page one is already on goes back to the top of it.
    func choose(_ chosen: AppPage) {
        if chosen == .projects, page == .projects { projectsRoute = .list }
        page = chosen
    }

    /// Reads the logs for past sessions, at most twice a minute: a log that Claude has deleted leaves the list soon after.
    func refreshPastSessions() {
        guard let engine, !pastReading, Date().timeIntervalSince(pastRead) >= 30 else { return }
        pastReading = true
        let owner = WeakModel(self)
        Task.detached(priority: .utility) {
            let sessions = await engine.pastSessions()
            await MainActor.run { owner.model?.pastSessionsRead(sessions) }
        }
    }

    private func pastSessionsRead(_ sessions: [WorkSession]) {
        pastSessions = sessions
        pastLoaded = true
        pastReading = false
        pastRead = Date()
    }

    /// Every session there is: what works from the live scan, the rest from the logs.
    var allSessions: [WorkSession] {
        ProjectBook.sessions(work: work, past: pastSessions)
    }

    func session(_ id: String) -> WorkSession? {
        work.sessions.first { $0.id == id && $0.state.isActive } ?? pastSessions.first { $0.id == id } ?? work.sessions.first { $0.id == id }
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

    func showProjectsForSnapshot(past: [WorkSession], tokens: [TokenRecord]) {
        pastSessions = past
        pastLoaded = true
        self.tokens = tokens
        spendIndex = SpendIndex(tokens)
    }
    #endif
}

private struct WeakModel: @unchecked Sendable {
    weak var model: AppModel?

    init(_ model: AppModel) {
        self.model = model
    }
}
