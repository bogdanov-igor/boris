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
    case general, sources, surfaces, notifications, connections, log, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return L("General")
        case .sources: return L("Sources")
        case .surfaces: return L("Surfaces")
        case .notifications: return L("Notifications")
        case .connections: return L("Connections")
        case .log: return L("Log")
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
    let chat: ChatWatch
    let losses = LossStore()
    let logFeed = LogFeed()
    let notifications: NotificationHub
    let capture = CaptureKeeper()
    /// The filter the running engine reads through. A change of it means a new engine.
    private(set) var sourceFilter = SourceFilter()
    private let editors: EditorBook
    /// What counts as written since this launch, kept when the engine starts again because of a setting.
    private let launchedAt = Date()
    @ObservationIgnored var sourcesRestart: Task<Void, Never>?
    let updates = Updates.forThisBuild()
    let remote: RemoteHub
    private let store: StateStore?
    /// Nothing has been saved yet, so this is the very first launch.
    let isFirstLaunch: Bool
    /// False reaches nothing of the person's: no other Claude folders, no files of Boris's own.
    private let live: Bool
    private var state: AppState
    private var board = MoodBoard()
    private var engine: WorkEngine?
    private var tokensVersion = -1
    private var surfacesOpen: Set<LookingSurface> = []
    private var focusedRuns: Set<String> = []
    private var pastRead = Date.distantPast
    private var pastReading = false
    /// Grows when the engine changes, so that a read from the old folder is not taken for a read from the new one.
    private(set) var pastGeneration = 0
    @ObservationIgnored private var logWatch = AppLogWatch()

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
    /// The failure the session's feed should go to as soon as it has been read.
    var feedTarget: FeedTarget?
    var settingsSection = SettingsSection.general
    var showIconNotice = false
    var hotKeyTaken = false
    let walrus = WalrusStage()
    let walrusPage = WalrusPageState()
    let packShelf: WalrusPackShelf

    var onPresenceChange: (() -> Void)?
    /// Brings the main window forward, from wherever a session is being opened.
    var onShowMainWindow: (() -> Void)?
    var onEvent: ((BorisEvent, Reaction) -> Void)?

    /// - Parameter store: nil keeps everything in memory.
    init(settings: AppSettings = AppSettings(), store: StateStore? = StateStore(), live: Bool = true) {
        self.settings = settings
        self.store = store
        self.live = live
        hooks = HookController(settings: settings, live: live)
        editors = live ? EditorBook(file: BorisPaths.support.appendingPathComponent(EditorBook.fileName), onlyCursorInstalled: EditorBook.isOnlyCursorInstalled()) : EditorBook()
        chat = ChatWatch(probe: live ? AccessibilityChatProbe() : NoChatProbe())
        remote = RemoteHub(hooks: hooks, store: live ? store.map { RemoteStore(folder: $0.folder) } : nil, tool: live ? .system() : nil)
        // Without a store nothing may touch Boris's real folder.
        packShelf = WalrusPackShelf(folder: (store?.folder ?? FileManager.default.temporaryDirectory.appendingPathComponent("boris-memory")).appendingPathComponent("Packs", isDirectory: true))
        // The walrus is one for the whole process, and a model made for a check must not change him under whoever is looking.
        if live { WalrusArt.shared.pack = packShelf.pack(id: settings.wardrobe.pack) }
        notifications = NotificationHub(settings: settings, live: live)
        usageRefresher = UsageRefresher(settings: settings)
        var loaded = store?.loadState() ?? AppState()
        isFirstLaunch = loaded.firstLaunch == nil
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
        connectRemote()
        load.sessions = { [weak self] in self?.sessionProcesses ?? [:] }
        usage.onBuilt = { [weak self] in self?.tokensAddedUp() }
        usageRefresher.onFinished = { [weak self] in
            Task { await self?.engine?.usageChanged() }
        }
        hooks.onChange = { [weak self] in self?.refreshPresence() }
        capture.hides = { [weak self] in self?.hidesFromCapture($0) ?? false }
        chat.onChange = { [weak self] in self?.chatChanged() }
    }

    func start() {
        let paths = ClaudePaths.resolve(custom: settings.claudeFolder)
        let owner = WeakModel(self)
        let filter = SourceFilter(off: settings.sources.readingOff, editors: editors)
        sourceFilter = filter
        hooks.applySources()
        let others: @Sendable () -> [ClaudePaths] = { [live] in live ? ClaudeFolders.others(besides: paths).filter(filter.reads(root:)) : [] }
        // Grows with every new engine, so the last words of an old one cannot bring back what it was told to leave alone.
        let generation = pastGeneration
        let engine = WorkEngine(
            paths: paths,
            runs: state.runs,
            detector: state.detector,
            status: settings.statusConfig,
            events: settings.detectorConfig,
            tokenCache: live ? BorisPaths.tokenIndex : nil,
            others: others,
            filter: filter,
            startedAt: launchedAt
        ) { output in
            Task { @MainActor in owner.model?.received(output, generation: generation) }
        }
        self.engine = engine
        logWatch.started()
        remote.setReading(settings.sources.reads(.remote))
        let remoteNow = remote.world
        Task { await engine.setRemote(remoteNow) }
        // Only the sizes the file system knows, for the disk row. No file is opened by this.
        let sampler = MacLoadSampler(logRoots: { ([paths] + others()).map(\.projects) })
        load.reader = { await sampler.read($0) }
        Task { await engine.start() }
        if !surfacesOpen.isEmpty { sendFocus() }
        hooks.refresh()
        updateChatWatch()
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

    /// Nothing reads the logs after this. For whoever started a model and is done with it.
    func stop() async {
        chat.update(consent: false)
        await engine?.stop()
        engine = nil
    }

    func noteWake() {
        Task { await engine?.noteWake(at: Date()) }
        remote.retryAll()
    }

    /// Remote machines reach the rest of Boris the same way a Mac's own files do: through the engine and the sums.
    private func connectRemote() {
        remote.onWorld = { [weak self] world in
            guard let engine = self?.engine else { return }
            Task { await engine.setRemote(world) }
        }
        remote.onSignal = { [weak self] signal in
            guard let engine = self?.engine else { return }
            Task { await engine.receive(signal, fromThisMac: false) }
        }
        remote.onRecords = { [weak self] records in self?.usage.readRemote(records) }
        remote.loadNumbers()
    }

    /// Where a session's transcript is, for a feed that is on screen.
    func sessionTranscript(_ id: String) async -> URL? {
        #if DEBUG
        if let file = transcriptsForCheck[id] { return file }
        #endif
        return await engine?.sessionTranscript(id)
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
    var focusWanted: (runs: Set<String>, closely: Bool) {
        (surfacesOpen.contains(.mainWindow) ? focusedRuns : [], !surfacesOpen.isEmpty)
    }

    private func sendFocus() {
        let (runs, closely) = focusWanted
        Task { await engine?.setFocus(runs: runs, lookingClosely: closely) }
    }

    private func receive(_ signal: HookSignal) {
        Task { await engine?.receive(signal) }
    }

    /// What the engine of another folder had on its way when the folder changed is dropped: its numbers would come back, and its version would hide the new ones.
    func received(_ output: WorkEngine.Output, generation: Int) {
        guard generation == pastGeneration else { return }
        apply(output)
    }

    func apply(_ output: WorkEngine.Output) {
        logWatch.saw(output)
        work = (usage.book?.applied(to: output.model) ?? output.model).withChat(chat.tracker.session)
        hooks.note(work: output.model, now: output.at)
        hooks.noteHidden(Set(output.world.hiddenSessions.keys))
        let loadOff = settings.sources.loadOff(hiddenSessions: Set(output.world.hiddenSessions.values))
        if load.off != loadOff { load.off = loadOff }
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
        // Its sessions going unseen does not stop it being asked for limits, unless it is off altogether: then the limits are not read either.
        if settings.sources.isOn(.claudeCode) { usageRefresher.refreshIfDue(now: output.at, liveSessions: output.world.sessions.filter { $0.host == nil }.count, account: output.world.account, fetchedAt: output.world.usage?.fetchedAt) }

        var changed = state.runs != output.runMemory || state.detector != output.detectorMemory
        state.runs = output.runMemory
        state.detector = output.detectorMemory
        let quietDuringScan = quiet.isOn(now: output.at)
        var news: [(event: BorisEvent, reaction: Reaction)] = []
        var muted = Set<String>()
        for event in output.events + chat.takeEvents() {
            let wanted = settings.notifications.reaction(for: event, mood: settings.matrix.reaction(for: event.kind).mood)
            // A muted source was never going to call anyone, so do not disturb has nothing to save up for later.
            let reaction = notifies(about: event) ? quiet.filter(wanted, kind: event.kind, now: output.at) : Reaction(banner: false, sound: false, mood: wanted.mood)
            board.apply(event, reaction: reaction.mood, now: output.at)
            onEvent?(event, reaction)
            news.append((event, reaction))
            if !notifies(about: event) { muted.insert(event.id) }
            // Do not disturb silences his reactions too. His pose keeps telling the truth.
            if !quietDuringScan { walrus.hear(event) }
            if let run = output.runs.first(where: { $0.runId == event.runId }), run.status.isTerminal {
                state.awards.record(run.status, today: UsageModel.dayKey(output.at))
            }
            changed = true
        }
        notifications.scanned(news, muted: muted, quiet: quietDuringScan, now: output.at)
        if let missed = quiet.finish(now: output.at) {
            AppLog.note(.quietEnded)
            notifications.quietEnded(missed: missed, requestsWaiting: requestCount)
            changed = true
        }
        if changed {
            state.quiet = quiet
            store?.save(state)
        }
        refreshPresence()
        lookForSurprise(at: output.at)
    }

    /// The sums were added up off the main thread, and now the numbers on the screens can use them.
    private func tokensAddedUp() {
        today = usage.spentToday(now)
        if let book = usage.book { work = book.applied(to: work) }
    }

    /// A look at Claude Desktop comes on its own time, between the scans.
    private func chatChanged() {
        work = work.withChat(chat.tracker.session)
        refreshPresence()
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

    /// What the walrus's surprises remember, kept with the rest, so a restart does not bring one back the same day.
    var eggs: EggDiary { state.eggs ?? EggDiary() }

    func noteEggs(_ diary: EggDiary) {
        state.eggs = diary
        store?.save(state)
    }

    func startQuiet(for duration: TimeInterval) {
        quiet.start(for: duration, now: Date())
        if duration >= QuietMode.indefinitely / 2 {
            AppLog.note(.quietUntilOff)
        } else {
            AppLog.note(.quietStarted, .seconds(duration))
        }
        state.quiet = quiet
        store?.save(state)
    }

    func stopQuiet() {
        let missed = quiet.cancel()
        AppLog.note(.quietEnded)
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
            openSession(id)
            return
        case .requests(let id):
            if let id, let row = hooks.queue.rows(now: Date()).first(where: { $0.session == id }) { hooks.selectedRow = row.id }
            page = .requests
        }
        onShowMainWindow?()
    }

    // MARK: - Going around

    /// Opens a session from any surface.
    /// - Parameter agent: the agent its feed starts on. Nil shows them all.
    /// - Parameter target: the failure its feed goes to. Nil stays at the newest record.
    func openSession(_ id: String, agent: String? = nil, target: FeedTarget? = nil) {
        projectsRoute = .session(id)
        feedAgent = agent
        feedTarget = target
        page = .projects
        refreshPastSessions()
        onShowMainWindow?()
    }

    func openProject(_ path: String?) {
        projectsRoute = .project(path)
        page = .projects
    }

    /// Changes the mode for the whole app. A page the new one does not have gives way to «Now», which tells the same failures in plain words.
    func setDisplayMode(_ mode: DisplayMode) {
        settings.displayMode = mode
        if !page.isShown(in: mode) { page = .now }
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
        ProjectBook.sessions(work: work, past: pastSessions + remote.pastSessions, logsReadAt: pastLoaded ? pastRead : nil)
    }

    func session(_ id: String) -> WorkSession? {
        allSessions.first { $0.id == id }
    }

    // MARK: - What the screens ask

    /// Requests held here, together with sessions waiting for the person with nothing held.
    var requestCount: Int {
        hooks.queue.rows(now: Date()).count
    }

    var activeSessions: [WorkSession] {
        work.sessions.filter { $0.state.isActive && $0.state != .waiting }
    }

    /// Sessions known only by a transcript have no process on this Mac to measure.
    private var sessionProcesses: [String: Int32] {
        Dictionary(world.sessions.filter { $0.pid > 0 }.map { ($0.sessionId, $0.pid) }) { first, _ in first }
    }

    var connectionStatus: ConnectionStatus {
        var status = ConnectionStatus(world: world, hooks: hooks.connection, hookState: hookState, hooksSince: hooks.since, now: now)
        status.remote = remote.summary
        return status
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
    /// - Returns: true only when the notice has just appeared, which is when the window comes forward to show it.
    @discardableResult
    func noteIconHidden() -> Bool {
        guard !state.iconNoticeSeen, !showIconNotice else { return false }
        showIconNotice = true
        return true
    }

    /// Only while Claude is at work, and only if the person asked for it.
    var shouldKeepAwake: Bool {
        // Work on another machine goes on whether this Mac sleeps or not.
        settings.keepAwake && work.sessions.contains { $0.state.isActive && $0.environment?.isRemote != true }
    }

    func chooseClaudeFolder(_ url: URL) {
        settings.claudeFolder = url.path
        restartEngine()
    }

    /// Versions, field names and counters: no content and no project paths.
    func diagnosticsReport() async -> String? {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? BorisCore.version
        let connection = connectionStatus
        guard let report = await engine?.diagnostics(appVersion: version, connection: connection) else { return nil }
        let log = await Task.detached(priority: .userInitiated) { AppLogStore.current?.newest(Diagnostics.logLines) ?? [] }.value
        return Diagnostics.adding(log: log, to: report)
    }

    func copyDiagnostics() async {
        guard let report = await diagnosticsReport() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
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

    /// Invented feed records for snapshots and test files for the off-screen check, so no real transcript is read.
    var feedForSnapshot: DevFeed?
    var transcriptsForCheck: [String: URL] = [:]

    func showForSnapshot(work: WorkModel, world: WorldSnapshot, today: TokenUsage, mood: Mood, outfit: Outfit = .none, offer: Bool = false) {
        self.work = work
        hooks.note(work: work)
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
