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

/// A surface that wants fresh data while it is open.
enum LookingSurface {
    case mainWindow, miniWindow
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
    let load = MacLoadWatch()
    let losses = LossStore()
    let notifications: NotificationHub
    private let store: StateStore?
    private var state: AppState
    private var board = MoodBoard()
    private var engine: WorkEngine?
    private var tokensVersion = -1
    private var surfacesOpen: Set<LookingSurface> = []
    private var focusedRuns: Set<String> = []
    private var pastRead = Date.distantPast
    private var pastReading = false
    /// Grows when the engine changes, so that a read from the old folder is not taken for a read from the new one.
    private var pastGeneration = 0

    let usage = UsageModel()
    let usageRefresher: UsageRefresher
    private(set) var work = WorkModel()
    private(set) var world = WorldSnapshot(takenAt: Date())
    private(set) var runs: [RunState] = []
    private(set) var hookState = HookState()
    private(set) var today = TokenUsage()
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
    var mainWindowIsOpen: Bool { surfacesOpen.contains(.mainWindow) }
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
    let walrus = WalrusStage()
    let walrusPage = WalrusPageState()
    let packShelf: WalrusPackShelf
    /// The session a click on a notification asked to show.
    var requestedSession: String?

    var onPresenceChange: (() -> Void)?
    /// Brings the main window forward, from wherever a session is being opened.
    var onShowMainWindow: (() -> Void)?
    var onEvent: ((BorisEvent, Reaction) -> Void)?

    /// - Parameter store: nil keeps everything in memory.
    init(settings: AppSettings = AppSettings(), store: StateStore? = StateStore(), live: Bool = true) {
        self.settings = settings
        self.store = store
        hooks = HookController(settings: settings, live: live)
        // Without a store nothing may touch Boris's real folder.
        packShelf = WalrusPackShelf(folder: (store?.folder ?? FileManager.default.temporaryDirectory.appendingPathComponent("boris-memory")).appendingPathComponent("Packs", isDirectory: true))
        WalrusArt.shared.pack = packShelf.pack(id: settings.wardrobe.pack)
        notifications = NotificationHub(settings: settings, live: live)
        usageRefresher = UsageRefresher(settings: settings)
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
        load.sessions = { [weak self] in self?.sessionProcesses ?? [:] }
        usage.onBuilt = { [weak self] in self?.tokensAddedUp() }
        usageRefresher.onFinished = { [weak self] in
            Task { await self?.engine?.usageChanged() }
        }
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
        let sampler = MacLoadSampler(logRoots: { ([paths] + ClaudeFolders.others(besides: paths)).map(\.projects) })
        load.reader = { await sampler.read($0) }
        Task { await engine.start() }
        if !surfacesOpen.isEmpty { sendFocus() }
        hooks.refresh()
    }

    /// Reads from another folder after the setting changes.
    func restartEngine() {
        let old = engine
        Task { await old?.stop() }
        pastGeneration += 1
        pastSessions = []
        pastLoaded = false
        pastReading = false
        pastRead = .distantPast
        // What the old folder spent is not what the new one spent, and the new engine counts its versions from the start.
        tokensVersion = -1
        usage.reset()
        today = TokenUsage()
        start()
    }

    func noteWake() {
        Task { await engine?.noteWake(at: Date()) }
    }

    /// Open windows get fresher data, and closed ones cost nothing. Closing one says nothing about the other.
    func setLookingClosely(_ closely: Bool, from surface: LookingSurface = .mainWindow) {
        if closely { surfacesOpen.insert(surface) } else { surfacesOpen.remove(surface) }
        sendFocus()
    }

    /// The runs and agents of an open session are read more often. Closing the page gives that up.
    func focus(on runs: Set<String>) {
        guard runs != focusedRuns else { return }
        focusedRuns = runs
        sendFocus()
    }

    /// A session is open only in the main window, and a closed window keeps its page, so its runs count only while it is open.
    private func sendFocus() {
        let runs = surfacesOpen.contains(.mainWindow) ? focusedRuns : []
        let closely = !surfacesOpen.isEmpty
        Task { await engine?.setFocus(runs: runs, lookingClosely: closely) }
    }

    private func receive(_ signal: HookSignal) {
        Task { await engine?.receive(signal) }
    }

    private func apply(_ output: WorkEngine.Output) {
        work = usage.book?.applied(to: output.model) ?? output.model
        world = output.world
        runs = output.runs
        hookState = output.hooks
        tokenProgress = output.tokenProgress
        now = output.at
        loaded = true
        usage.progress = output.tokenProgress
        if output.tokensVersion != tokensVersion {
            tokensVersion = output.tokensVersion
            // Version zero means the first pass over the logs is not done, which is different from finding nothing.
            if tokensVersion > 0 { usage.read(output.tokens) }
        }
        if page == .projects, surfacesOpen.contains(.mainWindow) { refreshPastSessions() }
        usage.noteTime(output.at)
        today = usage.spentToday(output.at)
        usageRefresher.refreshIfDue(now: output.at, liveSessions: output.world.sessions.count, account: output.world.account, fetchedAt: output.world.usage?.fetchedAt)

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
            // Do not disturb silences his reactions too. His pose keeps telling the truth.
            if !quietDuringScan { walrus.hear(event) }
            if let run = output.runs.first(where: { $0.runId == event.runId }), run.status.isTerminal {
                state.awards.record(run.status, today: UsageModel.dayKey(output.at))
            }
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

    /// The sums were added up off the main thread, and now the numbers on the screens can use them.
    private func tokensAddedUp() {
        today = usage.spentToday(now)
        if let book = usage.book { work = book.applied(to: work) }
    }

    func refreshPresence() {
        let date = Date()
        now = date
        hasAlarm = board.hasAlarm
        mood = board.mood(work: work, usage: world.usage, limitPercent: Double(settings.usageHigh), broken: loaded && connectionStatus.isBroken, matrix: settings.matrix, now: date)
        outfit = Wardrobe.outfit(at: date, settings: settings.wardrobe, rewardParty: state.awards.hasParty(today: UsageModel.dayKey(date)))
        walrus.upsideDown = settings.wardrobe.mode == .byDate && Wardrobe.isAprilFools(date)
        onPresenceChange?()
    }

    /// Opening the mini window confirms the alarm.
    func miniWindowDidOpen() {
        acknowledgeAlarm()
        setLookingClosely(true, from: .miniWindow)
    }

    /// The person has opened Boris, so he has done his job.
    func acknowledgeAlarm() {
        board.acknowledge()
        refreshPresence()
    }

    var hasFish: Bool { state.awards.hasFish }

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
        let began = Date()
        guard let engine, !pastReading, began.timeIntervalSince(pastRead) >= 30 else { return }
        pastReading = true
        let owner = WeakModel(self)
        let generation = pastGeneration
        Task.detached(priority: .utility) {
            let sessions = await engine.pastSessions()
            await MainActor.run { owner.model?.pastSessionsRead(sessions, at: began, generation: generation) }
        }
    }

    private func pastSessionsRead(_ sessions: [WorkSession], at began: Date, generation: Int) {
        guard generation == pastGeneration else { return }
        pastSessions = sessions
        pastLoaded = true
        pastReading = false
        pastRead = began
    }

    /// Every session there is: what works from the live scan, the rest from the logs.
    var allSessions: [WorkSession] {
        ProjectBook.sessions(work: work, past: pastSessions, logsReadAt: pastLoaded ? pastRead : nil)
    }

    func session(_ id: String) -> WorkSession? {
        allSessions.first { $0.id == id }
    }

    // MARK: - What the screens ask

    /// Sessions waiting for the person, together with requests that are held here.
    var requestCount: Int {
        Set(work.waitingSessions.map(\.id)).union(hooks.pending.map(\.session)).count
    }

    var activeSessions: [WorkSession] {
        work.sessions.filter { $0.state.isActive && $0.state != .waiting }
    }

    /// Sessions known only by a transcript have no process on this Mac to measure.
    private var sessionProcesses: [String: Int32] {
        Dictionary(world.sessions.filter { $0.pid > 0 }.map { ($0.sessionId, $0.pid) }) { first, _ in first }
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
    func showWalrusForSnapshot(mood: Mood?, outfit: Outfit?) {
        if let mood { self.mood = mood }
        if let outfit { self.outfit = outfit }
    }

    func showForSnapshot(work: WorkModel, world: WorldSnapshot, today: TokenUsage, mood: Mood, outfit: Outfit = .none, offer: Bool = false) {
        self.work = work
        self.world = world
        self.today = today
        self.mood = mood
        self.outfit = outfit
        loaded = true
        state.connectOfferDismissed = !offer
    }

    func showProjectsForSnapshot(past: [WorkSession]) {
        pastSessions = past
        pastLoaded = true
    }
    #endif
}

private struct WeakModel: @unchecked Sendable {
    weak var model: AppModel?

    init(_ model: AppModel) {
        self.model = model
    }
}
