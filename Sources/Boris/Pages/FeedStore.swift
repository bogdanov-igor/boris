import AppKit
import BorisCore
import BorisData
import Observation

/// Reads the feed from the transcripts while someone is looking at it. Nothing here is written anywhere, and it all goes away with the view.
@MainActor
@Observable
final class FeedStore {
    /// Someone waiting for the next step, as `sessionId` and the agent, nil for the main one.
    struct Thinker: Sendable, Equatable, Identifiable {
        var sessionId: String
        var agentId: String?
        var id: String { "\(sessionId)/\(agentId ?? "")" }
    }

    private(set) var entries: [FeedEntry] = []
    private(set) var thinking: [Thinker] = []
    /// True once every agent has been read, so an empty feed really is empty.
    private(set) var loaded = false
    private(set) var startedPartWay = false
    private(set) var fileNames: [String: String] = [:]
    /// Only the log says it, so it is known once the session's feed has been read.
    private(set) var permissionMode: String?
    /// Someone is reading older records, so the oldest stay until they come back to the end.
    @ObservationIgnored var keepsOldest = false {
        didSet {
            if !keepsOldest, oldValue { lastLive = nil }
        }
    }
    /// A change someone asked to see in full. It is opened from the top of the page, as a sheet on a lazy row would close when the row leaves the screen.
    var shownDiff: DiffRequest?

    @ObservationIgnored private let model: AppModel
    @ObservationIgnored private let sessionId: String?
    /// How much of the end of each big file to start from.
    @ObservationIgnored private let window: UInt64
    @ObservationIgnored private var fallback: WorkSession?
    @ObservationIgnored private var readers: [String: SessionFeedReader] = [:]
    @ObservationIgnored private var lastLive: Set<String>?
    @ObservationIgnored private var lookedOnce = false
    @ObservationIgnored private var viewers = 0
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored weak var hostWindow: NSWindow?

    private static let interval: Duration = .seconds(1)

    /// A session page shows one session, and whatever is on it reads through one store.
    private static var stores: [String: WeakStore] = [:]

    static func forSession(_ session: WorkSession, model: AppModel) -> FeedStore {
        stores = stores.filter { $0.value.store != nil }
        if let known = stores[session.id]?.store, known.model === model {
            known.fallback = session
            return known
        }
        let store = FeedStore(model: model, sessionId: session.id, window: ActivityReader.startWindow)
        store.fallback = session
        stores[session.id] = WeakStore(store: store)
        return store
    }

    /// - Parameter sessionId: nil for all the sessions there are.
    init(model: AppModel, sessionId: String?, window: UInt64) {
        self.model = model
        self.sessionId = sessionId
        self.window = window
        #if DEBUG
        if let feed = model.feedForSnapshot { show(feed) }
        #endif
    }

    private var sessions: [WorkSession] {
        guard let sessionId else { return model.work.sessions }
        return [model.work.sessions.first { $0.id == sessionId } ?? fallback].compactMap { $0 }
    }

    /// Reading goes on while any view of it is around and its window is on screen.
    func viewerAppeared() {
        viewers += 1
        startReading()
    }

    func viewerLeft() {
        viewers -= 1
        guard viewers <= 0 else { return }
        loop?.cancel()
        loop = nil
    }

    /// The window may have come back. One that has left is noticed by the reading itself, which then stops, so a closed window has no timer running.
    func windowChanged() {
        startReading()
    }

    /// A closed window keeps its views, so being on the page is not enough.
    private var isOnScreen: Bool { hostWindow?.isVisible ?? false }

    private func startReading() {
        guard loop == nil, viewers > 0, isOnScreen else { return }
        #if DEBUG
        if model.feedForSnapshot != nil { return }
        #endif
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                guard self.isOnScreen else {
                    self.release()
                    self.loop = nil
                    return
                }
                await self.tick()
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    private func tick() async {
        let started = SpeedLog.start()
        let sessions = sessions
        var files: [(session: WorkSession, file: URL)] = []
        for session in sessions {
            if let file = await model.sessionTranscript(session.id) { files.append((session, file)) }
        }
        let live = Self.liveKeys(sessions)
        let force = live != lastLive
        let window = window
        let current = readers
        let sources = files
        // A big workflow can have hundreds of files, so the first look is only at the main agents, and the rest follow on the next tick.
        let firstLook = !lookedOnce
        let merging: SpeedLoad = sessionId == nil ? .activityMerge : .sessionMerge
        let reading = Task.detached(priority: .userInitiated) {
            Self.read(current, files: sources, live: live, force: force, window: window, withAgents: !firstLook, merging: merging)
        }
        // This can take seconds, and nobody should keep paying for it after leaving the page.
        let result = await withTaskCancellationHandler { await reading.value } onCancel: { reading.cancel() }
        guard !Task.isCancelled, isOnScreen else { return }
        lastLive = firstLook ? nil : live
        readers = result.readers
        if let merged = result.entries {
            SpeedLog.did(.feedArrived)
            let next = keepsOldest ? SessionFeed.keepingOlder(entries, next: merged) : merged
            if next != entries { entries = next }
            // Only a look that brought something: one every second that found nothing new says nothing about a page.
            SpeedLog.loaded(sessionId == nil ? .activity : .sessionFeed, since: started, items: entries.count, onMain: false)
        }
        if result.thinking != thinking { thinking = result.thinking }
        if result.names != fileNames { fileNames = result.names }
        if sessionId != nil, result.permissionMode != permissionMode { permissionMode = result.permissionMode }
        // A feed at its limit has dropped what came before, also on a tick that brought nothing new.
        let partWay = result.partWay || entries.count >= SessionFeed.limit
        if partWay != startedPartWay { startedPartWay = partWay }
        lookedOnce = true
        if !firstLook, !loaded { loaded = true }
    }

    /// Text must not stay in memory behind a closed window. It is read again if the window comes back.
    private func release() {
        guard lookedOnce else { return }
        readers = [:]
        lastLive = nil
        entries = []
        thinking = []
        fileNames = [:]
        permissionMode = nil
        shownDiff = nil
        startedPartWay = false
        lookedOnce = false
        loaded = false
    }

    /// Who may still be working: a session or agent that has stopped gets no more results.
    private static func liveKeys(_ sessions: [WorkSession]) -> Set<String> {
        var live: Set<String> = []
        for session in sessions {
            if session.state.isActive && session.root.state.isActive { live.insert(key(session.id, nil)) }
            for node in session.root.children.flatMap(\.flattened) where node.state.isActive {
                live.insert(key(session.id, node.id))
            }
        }
        return live
    }

    private nonisolated static func key(_ session: String, _ agent: String?) -> String {
        "\(session)/\(agent ?? "")"
    }

    private struct ReadResult: Sendable {
        var readers: [String: SessionFeedReader]
        /// Nil when nothing changed.
        var entries: [FeedEntry]?
        var thinking: [Thinker]
        var names: [String: String]
        var partWay: Bool
        var permissionMode: String?
    }

    private nonisolated static func read(_ current: [String: SessionFeedReader], files: [(session: WorkSession, file: URL)], live: Set<String>, force: Bool, window: UInt64, withAgents: Bool, merging: SpeedLoad) -> ReadResult {
        var readers = current
        var changed = force
        for (session, file) in files {
            if Task.isCancelled { break }
            var reader = readers[session.id] ?? SessionFeedReader(window: window)
            if reader.read(transcript: file, withAgents: withAgents) { changed = true }
            readers[session.id] = reader
        }
        // Nobody is waiting for the rest, and this result goes unused.
        if Task.isCancelled { return ReadResult(readers: current, entries: nil, thinking: [], names: [:], partWay: false) }
        let mergeStarted = SpeedLog.start()
        var feeds: [[FeedEntry]] = []
        var thinking: [Thinker] = []
        var names: [String: String] = [:]
        var partWay = false
        for (session, _) in files {
            guard let reader = readers[session.id] else { continue }
            let logs = reader.logs { live.contains(key(session.id, $0)) }
            if changed { feeds.append(SessionFeed.merged(sessionId: session.id, logs: logs)) }
            thinking += SessionFeed.thinking(session: session, logs: logs).map { Thinker(sessionId: session.id, agentId: $0) }
            names.merge(reader.names.compactMapValues { $0 }) { _, new in new }
            partWay = partWay || reader.startedPartWay
        }
        let merged = changed ? SessionFeed.merged(feeds) : nil
        if let merged { SpeedLog.loaded(merging, since: mergeStarted, items: merged.count, onMain: pthread_main_np() != 0) }
        return ReadResult(readers: readers, entries: merged, thinking: thinking, names: names, partWay: partWay, permissionMode: files.first.flatMap { readers[$0.session.id]?.permissionMode })
    }

    /// The whole of a call, which the feed keeps only the start of. Read from the transcript, only when asked.
    func full(_ entry: FeedEntry) async -> ActivityReader.FullStep? {
        guard let step = entry.step, let files = readers[entry.sessionId]?.files(agentId: entry.agentId) else { return nil }
        return await Task.detached(priority: .userInitiated) {
            files.lazy.compactMap { ActivityReader.fullStep(step.id, in: $0) }.first
        }.value
    }

    /// What to call an agent, from the session's tree or else from the agent's own file.
    func agentName(_ agentId: String?, session: WorkSession?, short: Bool = true) -> String {
        guard let agentId else { return short ? L("Main") : L("Main agent") }
        let node = session?.root.flattened.first { $0.id == agentId }
        return (node?.title ?? node?.agentType) ?? fileNames[agentId] ?? L("Agent")
    }

    /// The agents that have records in this feed, in the order they first appear.
    var agentIds: [String] {
        var seen: Set<String> = []
        return entries.compactMap(\.agentId).filter { seen.insert($0).inserted }
    }

    #if DEBUG
    /// For the off-screen check.
    var isReading: Bool { loop != nil }

    private func show(_ feed: DevFeed) {
        entries = feed.entries.filter { sessionId == nil || $0.sessionId == sessionId }
        thinking = feed.thinking.filter { sessionId == nil || $0.sessionId == sessionId }
        fileNames = feed.names
        permissionMode = feed.permissionMode
        loaded = true
    }
    #endif
}

private struct WeakStore {
    weak var store: FeedStore?
}

/// Which changes to show in full, and under what title.
struct DiffRequest: Identifiable {
    let id = UUID()
    var title: String
    var entries: [FeedEntry]
}
