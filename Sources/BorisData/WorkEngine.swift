import BorisCore
import Foundation

/// The cycle: file changes and a timer lead to a scan, statuses and the model of the work. Whoever listens only gets finished results.
public actor WorkEngine {
    public struct Output: Sendable {
        public var at: Date
        public var model: WorkModel
        public var world: WorldSnapshot
        public var runs: [RunState]
        public var hooks: HookState
        public var runMemory: [String: RunMemory]
        /// What happened since the last scan. Empty when only hooks spoke.
        public var events: [BorisEvent]
        public var detectorMemory: DetectorMemory
        /// Changes whenever `tokens` does, so nobody has to compare them to find out.
        public var tokensVersion: Int
        /// Real spend from every log. Empty until the first pass over the logs is done.
        public var tokens: [TokenRecord]
        /// How far the pass over the logs has come, while it is going.
        public var tokenProgress: TokenProgress?
    }

    public struct TokenProgress: Sendable, Equatable {
        public var done: Int
        public var total: Int
    }

    private let paths: ClaudePaths
    private let scanner: RunScanner
    private var tracker: RunTracker
    private var detector: EventDetector
    private var tokensVersion = 0
    private var gate = ScanGate()
    private var hooks = HookState()
    private let handler: @Sendable (Output) -> Void
    private let watcher: FileWatcher
    private let box: WatcherBox
    private var timer: Task<Void, Never>?
    private var lookingClosely = false
    private var watchedFolders: [URL] = []
    private var scanning = false
    private var rescanNeeded = false
    private let index: TokenIndex
    private let others: @Sendable () -> [ClaudePaths]
    private var tokens: [TokenRecord] = []
    private var tokenProgress: TokenProgress?
    private var tokensChanged = true
    private var indexing = false
    private var tokenReadPlanned = false
    private var emitPlanned = false
    private var scanned: (world: WorldSnapshot, runs: [RunState])?
    private var lastIndexed = Date.distantPast

    /// How often the logs are looked at again while they are being written.
    private static let indexInterval: TimeInterval = 2
    /// Files can change without an event reaching us, so the logs are looked at now and then anyway.
    private static let indexFallback: TimeInterval = 60

    /// - Parameter tokenCache: nil keeps the token index in memory.
    public init(paths: ClaudePaths, runs: [String: RunMemory] = [:], detector: DetectorMemory = DetectorMemory(), status: StatusConfig = StatusConfig(), events: DetectorConfig = DetectorConfig(), tokenCache: URL? = nil, others: @escaping @Sendable () -> [ClaudePaths], handler: @escaping @Sendable (Output) -> Void) {
        self.paths = paths
        self.index = TokenIndex(cacheFile: tokenCache)
        self.others = others
        self.scanner = RunScanner(paths: paths, others: others)
        self.tracker = RunTracker(memory: runs, config: status)
        self.detector = EventDetector(memory: detector, config: events)
        self.handler = handler
        let box = WatcherBox()
        self.box = box
        self.watcher = FileWatcher { changed in box.forward(changed) }
    }

    public func start() {
        box.target = { [weak self] changed in
            guard let self else { return }
            Task { await self.filesChanged(changed) }
        }
        startTimer()
    }

    public func stop() {
        timer?.cancel()
        watcher.stop()
    }

    /// A stream on a folder that does not exist yet stays silent, so it restarts once Claude creates the folder or starts using a new place.
    private func watchNewFolders() async {
        let folders = await scanner.watchedFolders().filter { FileManager.default.fileExists(atPath: $0.path) }
        guard folders != watchedFolders else { return }
        watchedFolders = folders
        watcher.stop()
        watcher.start(paths: folders)
        await scanner.markDiscovery()
    }

    /// While someone is looking at the live feed, scans come more often. Files are read only then.
    private func startTimer() {
        timer?.cancel()
        let interval: TimeInterval = lookingClosely ? 2 : 5
        timer = Task { [weak self] in
            while !Task.isCancelled {
                await self?.requestScan()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    public func configure(status: StatusConfig, events: DetectorConfig) {
        tracker.config = status
        detector.config = events
    }

    public func noteWake(at date: Date) {
        tracker.lastWake = date
        requestScan()
    }

    public func runFolder(_ runId: String) async -> URL? {
        await scanner.runFolder(runId)
    }

    public func usageChanged() async {
        await scanner.markUsageChanged()
        requestScan()
    }

    public func sessionTranscript(_ sessionId: String) async -> URL? {
        await scanner.sessionTranscript(sessionId)
    }

    public func setFocus(runs: Set<String>, lookingClosely: Bool) async {
        await scanner.setFocus(runs: runs, menuOpen: lookingClosely)
        if lookingClosely != self.lookingClosely {
            self.lookingClosely = lookingClosely
            startTimer()
        } else {
            requestScan()
        }
    }

    public func diagnostics(appVersion: String, connection: ConnectionStatus? = nil) async -> String {
        let world = await scanner.scan(now: Date())
        return Diagnostics.report(world: world, paths: paths, appVersion: appVersion, connection: connection)
    }

    /// Marks what changed and asks for a scan.
    public func filesChanged(_ changed: [String]) async {
        tokensChanged = true
        var runs: Set<String> = []
        var discovery = false
        for change in FileChangeParser.changes(in: changed) {
            switch change {
            case .run(let id): runs.insert(id)
            case .session(let id): await scanner.markDirty(session: id)
            case .discovery: discovery = true
            case .project(let folder): await scanner.markProject(folder)
            case .sessions: break
            }
        }
        if !runs.isEmpty { await scanner.markDirty(runs: runs) }
        if discovery { await scanner.markDiscovery() }
        requestScan()
    }

    /// Hooks only say where to look and add details. The scan that follows still decides every status.
    public func receive(_ signal: HookSignal) async {
        hooks.apply(signal, now: Date())
        if case .workflowLaunched = signal {
            // A new run is rare and worth showing at once, so it does not wait for the gate.
            await scanner.markDiscovery()
            await runScan()
            return
        }
        if case .agentStarted = signal { await scanner.markDiscovery() }
        emitSoon()
        requestScan()
    }

    /// Shows what a signal added without reading anything, and only once for a burst of signals.
    private func emitSoon() {
        guard !emitPlanned else { return }
        emitPlanned = true
        Task {
            try? await Task.sleep(for: .milliseconds(50))
            emitPlanned = false
            if let output = assemble(now: Date(), events: []) { handler(output) }
        }
    }

    public func requestScan() {
        switch gate.request(now: Date()) {
        case .runNow:
            Task { await runScan() }
        case .runAfter(let delay):
            Task {
                try? await Task.sleep(for: .seconds(delay))
                gate.didRun(now: Date())
                await runScan()
            }
        case .alreadyPending:
            break
        }
    }

    /// One pass, for tools that only want a look.
    public func scanOnce() async -> Output {
        await watchNewFolders()
        return await makeOutput()
    }

    private func runScan() async {
        guard !scanning else {
            rescanNeeded = true
            return
        }
        scanning = true
        await watchNewFolders()
        handler(await makeOutput())
        scanning = false
        if rescanNeeded {
            rescanNeeded = false
            requestScan()
        }
    }

    /// Reads the logs off to the side at low priority, so a first pass over gigabytes holds nothing up.
    private func refreshTokens(now: Date) {
        guard !indexing else { return }
        let since = now.timeIntervalSince(lastIndexed)
        if tokensChanged, since < Self.indexInterval {
            planTokenRead(after: Self.indexInterval - since)
            return
        }
        guard tokensChanged || since >= Self.indexFallback else { return }
        indexing = true
        tokensChanged = false
        lastIndexed = now
        let roots = [paths] + others()
        let index = index
        let engine = self
        Task.detached(priority: .utility) {
            await index.update(roots: roots) { done, total in
                guard done == total || done % 50 == 0 else { return }
                Task { await engine.noteProgress(done: done, total: total) }
            }
            let records = await index.records()
            await engine.tokensRead(records)
        }
    }

    /// A change right after a read must not wait for the next tick of the timer.
    private func planTokenRead(after delay: TimeInterval) {
        guard !tokenReadPlanned else { return }
        tokenReadPlanned = true
        Task {
            try? await Task.sleep(for: .seconds(delay))
            tokenReadPlanned = false
            refreshTokens(now: Date())
        }
    }

    private func noteProgress(done: Int, total: Int) {
        guard indexing else { return }
        tokenProgress = TokenProgress(done: done, total: total)
    }

    private func tokensRead(_ records: [TokenRecord]) {
        tokens = records
        tokensVersion += 1
        tokenProgress = nil
        indexing = false
        if tokensChanged { planTokenRead(after: Self.indexInterval) }
        // New numbers go out at once: the gate is there for reading files, and these are already read.
        Task { await runScan() }
    }

    private func makeOutput() async -> Output {
        let now = Date()
        refreshTokens(now: now)
        let world = await scanner.scan(now: now)
        let runs = tracker.resolve(world) { ProcessInspector.startTime(pid: $0) }
        scanned = (world, runs)
        hooks.expire(now: now)
        let events = detector.detect(runs: hooks.overlay(runs: runs), sessions: hooks.overlay(sessions: world.sessions), usage: world.usage, now: now, failures: hooks.drainFailures())
        // Just assigned, so it is always there.
        return assemble(now: now, events: events) ?? emptyOutput(now: now, world: world, runs: runs, events: events)
    }

    private func emptyOutput(now: Date, world: WorldSnapshot, runs: [RunState], events: [BorisEvent]) -> Output {
        Output(at: now, model: WorkModel(), world: world, runs: runs, hooks: hooks, runMemory: tracker.memory, events: events, detectorMemory: detector.memory, tokensVersion: tokensVersion, tokens: tokens, tokenProgress: tokenProgress)
    }

    /// The last scan with the hooks laid over it. Statuses come from the scan, so hooks cannot change them.
    private func assemble(now: Date, events: [BorisEvent]) -> Output? {
        guard var (world, runs) = scanned else { return nil }
        hooks.expire(now: now)
        runs = hooks.overlay(runs: runs)
        world.sessions = hooks.overlay(sessions: world.sessions)
        world.agents = hooks.overlay(agents: world.agents)
        var output = emptyOutput(now: now, world: world, runs: runs, events: events)
        output.model = WorkBuilder.build(world: world, runs: runs)
        return output
    }
}

/// Lets the file watcher be created before the actor can hand out a reference to itself.
private final class WatcherBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: (@Sendable ([String]) -> Void)?

    var target: (@Sendable ([String]) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }

    func forward(_ paths: [String]) {
        target?(paths)
    }
}
