import BorisCore
import BorisData
import Foundation
import Observation

/// Everything about the connection to Claude's settings: what is installed, the local server, and requests waiting for an answer.
@MainActor
@Observable
final class HookController {
    /// The most any request can wait. The app lets a hook go at the chosen time, so changing that time does not touch Claude's settings.
    static let hookLimit = 600
    /// A new request may slide under the cursor or the finger just as the previous one is answered. It cannot be allowed by that same press.
    static let settleTime: TimeInterval = 0.6

    private(set) var status: HookInstaller.Status = .notInstalled
    private(set) var serverRunning = false
    private(set) var queue = RequestQueue()
    private(set) var drafts: [UUID: RequestDraft] = [:]
    /// The row chosen on the Requests page.
    var selectedRow: String? { didSet { syncKeys() } }
    /// A key could not be registered, so its hint is not shown either.
    private(set) var keysTaken = false
    /// When the hooks could first have spoken.
    private(set) var since = Date()

    private let settings: AppSettings
    private let live: Bool
    private var server: HookServer?
    private var keys: RequestHotKeys?
    private var sightings: [UUID: Sighting] = [:]
    private var lastTarget: UUID?
    private var settledAt = Date.distantPast

    private struct Sighting {
        var request: UUID
        var windowShows = false
        var inView = true

        var isSeen: Bool { windowShows && inView }
    }

    var onSignal: ((HookSignal) -> Void)?
    /// Anything that changes what the menu bar shows.
    var onChange: (() -> Void)?
    /// Offers to connect the answers, where the flow can be shown.
    var onConnect: (() -> Void)?

    var pending: [PendingPermission] { queue.open }

    /// - Parameter live: false never reads Claude's settings, opens the socket, holds a key or keeps a file, as in a snapshot.
    /// - Parameter keys: the real keys without the rest of a live app, for checking them.
    init(settings: AppSettings, live: Bool = true, keys: RequestHotKeys? = nil) {
        self.settings = settings
        self.live = live
        if live { queue = RequestQueue(decisions: RequestLog.load()) }
        guard let keys = keys ?? (live ? RequestHotKeys() : nil) else { return }
        keys.onAllow = { [weak self] in self?.pressAllow() }
        keys.onDeny = { [weak self] in self?.pressDeny() }
        self.keys = keys
    }

    var connection: HookConnection {
        HookConnection(wanted: settings.hooksWanted, status: status)
    }

    var settingsFile: URL {
        ClaudePaths.resolve(custom: settings.claudeFolder).settings
    }

    private var plan: HookInstaller.Plan {
        // Next to this program, both inside the app and in a developer's build folder.
        let folder = Bundle.main.executableURL?.deletingLastPathComponent() ?? Bundle.main.bundleURL
        return HookInstaller.Plan(helperPath: folder.appendingPathComponent("boris-hook").path, permissions: true, permissionWait: Self.hookLimit)
    }

    /// Looks at the settings again and listens only when something can talk to us.
    func refresh() {
        guard live else { return }
        status = HookInstaller.status(at: settingsFile, plan: plan)
        let shouldListen = status == .installed || status == .outdated || ProcessInfo.processInfo.environment["BORIS_HOOK_SOCKET"] != nil
        if shouldListen { startServer() } else { stopServer() }
    }

    func preview() throws -> HookInstaller.Preview {
        try HookInstaller.preview(at: settingsFile, plan: plan)
    }

    func previewRemoval() throws -> HookInstaller.Preview {
        try HookInstaller.previewRemoval(at: settingsFile)
    }

    /// Also puts damaged hooks back: the same entries are written again.
    func connect() throws {
        try guardRealSettings()
        try HookInstaller.install(at: settingsFile, plan: plan)
        settings.hooksWanted = true
        since = Date()
        refresh()
    }

    func disconnect() throws {
        try guardRealSettings()
        try HookInstaller.uninstall(at: settingsFile)
        settings.hooksWanted = false
        refresh()
    }

    /// A developer's build lives in a folder that goes away, so its path must never land in the person's real Claude settings.
    static func mayChange(_ file: URL, environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        #if DEBUG
        if environment["BORIS_ALLOW_REAL_SETTINGS"] == "1" { return true }
        let temporary = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path + "/"
        return file.resolvingSymlinksInPath().path.hasPrefix(temporary)
        #else
        true
        #endif
    }

    private func guardRealSettings() throws {
        guard Self.mayChange(settingsFile) else { throw CocoaError(.fileWriteNoPermission) }
    }

    private func startServer() {
        guard server == nil else { return }
        let server = HookServer(path: HookServer.defaultPath)
        server.setAnswerWindow(TimeInterval(settings.permissionWaitSeconds))
        let owner = WeakHooks(self)
        server.onSignal = { signal in
            Task { @MainActor in owner.value?.receive(signal) }
        }
        server.onPermission = { request in
            Task { @MainActor in owner.value?.add(request) }
        }
        server.onPermissionGone = { id in
            Task { @MainActor in owner.value?.gone(id) }
        }
        server.onPermissionExpired = { id in
            Task { @MainActor in owner.value?.expire(id) }
        }
        server.onToolDone = { session, digest in
            Task { @MainActor in owner.value?.toolDone(session: session, digest: digest) }
        }
        serverRunning = server.start()
        self.server = server
    }

    /// Every held hook exits without a decision, so whatever is open stays in Claude.
    func stopServer() {
        server?.stop()
        server = nil
        serverRunning = false
        for request in queue.open { queue.expire(request.id) }
        drafts = [:]
        syncKeys()
    }

    func quit() {
        stopServer()
        keys?.apply(allow: nil, deny: nil)
        RequestLog.flush()
    }

    /// The chosen time applies to the requests that come next.
    func applyWait() {
        server?.setAnswerWindow(TimeInterval(settings.permissionWaitSeconds))
    }

    // MARK: - Requests

    /// Called with every new picture of the work, so it stays quiet unless a request has ended.
    func note(work: WorkModel, now: Date = Date()) {
        let before = queue.decisions.last?.id
        queue.note(work: work, now: now)
        if queue.decisions.last?.id != before { settle(savingFrom: before) }
    }

    private func add(_ request: PendingPermission) {
        queue.add(request)
        settle(savingFrom: queue.decisions.last?.id)
    }

    private func gone(_ id: UUID) {
        let before = queue.decisions.last?.id
        queue.gone(id, now: Date())
        drafts[id] = nil
        settle(savingFrom: before)
    }

    private func expire(_ id: UUID) {
        queue.expire(id)
        drafts[id] = nil
        settle(savingFrom: queue.decisions.last?.id)
    }

    private func toolDone(session: String, digest: String) {
        let before = queue.decisions.last?.id
        release(queue.toolDone(session: session, digest: digest, now: Date()))
        settle(savingFrom: before)
    }

    private func receive(_ signal: HookSignal) {
        let before = queue.decisions.last?.id
        release(queue.note(signal, now: Date()))
        settle(savingFrom: before)
        onSignal?(signal)
    }

    private func release(_ ids: [UUID]) {
        for id in ids {
            server?.release(id)
            drafts[id] = nil
        }
    }

    private func settle(savingFrom before: UUID?) {
        if queue.decisions.last?.id != before, live { RequestLog.save(queue.decisions) }
        syncKeys()
        onChange?()
    }

    /// The answer goes only to this request. Its text and everything typed into the card leave memory with it.
    func answer(_ id: UUID, _ answer: HookAnswer, via place: RequestPlace, now: Date = Date()) {
        if case .deny = answer {} else if now.timeIntervalSince(settledAt) < Self.settleTime { return }
        let before = queue.decisions.last?.id
        guard let session = queue.open.first(where: { $0.id == id })?.session,
              queue.answered(id, with: answer, place: place, now: now)
        else { return }
        drafts[id] = nil
        server?.answer(id, answer)
        settledAt = now
        // The session goes on waiting for as long as another of its requests does.
        let stillAsks = queue.open.contains { $0.session == session } || queue.expired.contains { $0.session == session }
        if !stillAsks { onSignal?(.permissionAnswered(session: session)) }
        settle(savingFrom: before)
    }

    func draft(_ id: UUID) -> RequestDraft {
        drafts[id] ?? RequestDraft()
    }

    func updateDraft(_ id: UUID, _ change: (inout RequestDraft) -> Void) {
        var draft = drafts[id] ?? RequestDraft()
        change(&draft)
        drafts[id] = draft
        syncKeys()
    }

    /// What the deny button sends: the reason typed so far, or none.
    func deny(_ id: UUID, via place: RequestPlace) {
        answer(id, .deny(reason: draft(id).reason), via: place)
    }

    // MARK: - Hot keys

    /// Each card reports where it stands. A key can act only on a request whose card someone can see.
    func noteCard(_ token: UUID, request: UUID, windowShows: Bool? = nil, inView: Bool? = nil) {
        let before = sightings[token]
        var sighting = before ?? Sighting(request: request)
        sighting.request = request
        // A snapshot draws off screen, where no window ever counts as shown.
        if let windowShows { sighting.windowShows = windowShows || (!live && keys == nil) }
        if let inView { sighting.inView = inView }
        sightings[token] = sighting
        // A card that has just come into sight may be under the cursor, even while the keys still point at another one.
        if sighting.isSeen, before?.isSeen != true { settledAt = Date() }
        syncKeys()
    }

    func forgetCard(_ token: UUID) {
        sightings[token] = nil
        syncKeys()
    }

    /// The card the keys act on: the chosen one if it can be seen, otherwise the oldest that can.
    var hotKeyTarget: PendingPermission? {
        let seen = Set(sightings.values.filter(\.isSeen).map(\.request))
        let open = queue.open.sorted { $0.askedAt < $1.askedAt }.filter { seen.contains($0.id) }
        return open.first { $0.id.uuidString == selectedRow } ?? open.first
    }

    /// Which keys mean something right now. Whatever is false stays free for the active app.
    var keysWanted: (allow: Bool, deny: Bool) {
        guard let target = hotKeyTarget else { return (false, false) }
        let draft = draft(target.id)
        switch target.content {
        case .questions(let questions):
            return (draft.answers(to: questions) != nil, false)
        case .plan:
            return (true, true)
        case .command, .file, .other, .unreadable:
            return (target.content.canAllow && !draft.denying, true)
        }
    }

    private func syncKeys() {
        // A card can report once more on its way off screen, after its request has already gone.
        let open = Set(queue.open.map(\.id))
        let current = sightings.filter { open.contains($0.value.request) }
        if current.count != sightings.count { sightings = current }
        let target = hotKeyTarget?.id
        if target != lastTarget {
            lastTarget = target
            settledAt = Date()
        }
        guard let keys else { return }
        let wanted = keysWanted
        keys.apply(allow: wanted.allow ? settings.allowKey : nil, deny: wanted.deny ? settings.denyKey : nil)
        if keysTaken != keys.taken { keysTaken = keys.taken }
    }

    /// After the person chooses other keys.
    func applyKeys() {
        syncKeys()
    }

    func pressAllow(now: Date = Date()) {
        guard keysWanted.allow, let target = hotKeyTarget else { return }
        switch target.content {
        case .questions(let questions):
            guard let answers = draft(target.id).answers(to: questions) else { return }
            answer(target.id, .answers(answers), via: .hotKey, now: now)
        default:
            answer(target.id, .allow, via: .hotKey, now: now)
        }
    }

    func pressDeny() {
        guard keysWanted.deny, let target = hotKeyTarget else { return }
        deny(target.id, via: .hotKey)
    }

    #if DEBUG
    func showForSnapshot(status: HookInstaller.Status) {
        self.status = status
    }

    func showRequestsForSnapshot(open: [PendingPermission], expired: [PendingPermission], decisions: [RequestDecision]) {
        queue.showForSnapshot(open: open, expired: expired, decisions: decisions)
    }
    #endif
}

private struct WeakHooks: @unchecked Sendable {
    weak var value: HookController?

    init(_ value: HookController) {
        self.value = value
    }
}
