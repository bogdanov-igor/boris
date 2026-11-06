import BorisCore
import BorisData
import Foundation
import Observation

/// Every remote machine the person added, and what is known about each. Lives on the main thread, and the links do their work off it.
@MainActor
@Observable
final class RemoteHub {
    /// What the settings show about one machine.
    struct Row: Identifiable, Equatable {
        var machine: RemoteMachine
        var state = RemoteLink.State.stopped
        var vitals: RemoteVitals?
        /// The exact lines that will change in the machine's settings, while the person is deciding.
        var preview: RemoteHookResult?
        /// Waiting for the machine to do what was asked.
        var busy = false
        var problem: RemoteActionProblem?
        var confirmingRemoval = false

        var id: String { machine.id }

        var isUp: Bool {
            if case .up = state { return true }
            return false
        }

        var failure: RemoteFailure? {
            if case .down(let failure) = state { return failure }
            return nil
        }

        /// The hooks as they stand, with what the person asked for.
        var hooks: RemoteHookState? { vitals?.hooks }
        var hooksDamaged: Bool { machine.hooksWanted && (hooks == .notInstalled || hooks == .outdated) }
    }

    enum RemoteActionProblem: Equatable {
        case unreachable, settingsUnreadable
        /// The machine was taken off the list, and what is on it could not be removed.
        case leftBehind(String)
    }

    private final class Connection {
        var link: RemoteLink?
        var server: HookServer?
        var book: RemoteBook

        init(book: RemoteBook) {
            self.book = book
        }
    }

    /// The most any request can wait: the same limit as on this Mac.
    private var hookWait: Int { HookController.hookLimit }

    private(set) var rows: [Row] = []
    /// A machine was removed, and its hooks stayed on it.
    private(set) var leftBehind: String?
    /// What the machines left in numbers, for the pages that list past sessions.
    private(set) var pastSessions: [WorkSession] = []
    /// Grows with every event, so that a feed on screen knows to look again.
    private(set) var eventVersion = 0

    @ObservationIgnored var onWorld: ((RemoteWorld) -> Void)?
    @ObservationIgnored var onSignal: ((HookSignal) -> Void)?
    @ObservationIgnored var onRecords: (([TokenRecord]) -> Void)?

    @ObservationIgnored private let hooks: HookController
    @ObservationIgnored private var store: RemoteStore?
    @ObservationIgnored private var tool: SSHTool?
    @ObservationIgnored private var timing = RemoteLink.Timing()
    @ObservationIgnored private var connections: [String: Connection] = [:]
    @ObservationIgnored private var started = false
    /// The remote source is off in the settings.
    @ObservationIgnored private var readingOff = false
    @ObservationIgnored private var worldPlanned = false
    @ObservationIgnored private var numbersSavedAt: [String: Date] = [:]
    @ObservationIgnored private var booksBeforeStart: [String: RemoteBook] = [:]

    private static let numbersSaveInterval: TimeInterval = 60

    /// - Parameters:
    ///   - store: nil keeps everything in memory.
    ///   - tool: nil never connects to anything, as in a snapshot.
    init(hooks: HookController, store: RemoteStore?, tool: SSHTool?) {
        self.hooks = hooks
        self.store = store
        self.tool = tool
        hooks.onRemoteAnswered = { [weak self] session in self?.answered(session: session) }
        rows = (store?.machines() ?? []).map { Row(machine: $0) }
    }

    // MARK: - What the rest of Boris asks

    var world: RemoteWorld {
        let now = Date()
        var world = RemoteWorld()
        guard !readingOff else { return world }
        for connection in connections.values { world.add(connection.book.world(now: now)) }
        return world
    }

    var summary: RemoteSummary {
        RemoteSummary(machines: rows.count, connected: rows.filter(\.isUp).count, failures: rows.compactMap(\.failure))
    }

    func events(session: String) -> [RemoteEvent] {
        for connection in connections.values where connection.book.knows(session: session) {
            return connection.book.events(session: session)
        }
        return []
    }

    /// Live events come only through hooks, so without them a session page has nothing to follow.
    func hooksConnected(host: String) -> Bool {
        rows.first { $0.machine.name == host }?.hooks == .installed
    }

    // MARK: - Starting and stopping

    /// Brings back what the machines left last time, so that a machine out of reach does not take its spend with it.
    func loadNumbers() {
        for row in rows {
            connections[row.id] = Connection(book: RemoteBook(host: row.machine.name, rows: store?.rows(of: row.id) ?? []))
        }
        numbersChanged()
    }

    func start() {
        guard !started else { return }
        started = true
        for row in rows { connect(row.id) }
    }

    /// The remote source in the settings. Off, no connection stays up and nothing from the machines is shown.
    func setReading(_ on: Bool) {
        guard on == readingOff || (on && !started) else { return }
        readingOff = !on
        if on {
            start()
        } else {
            quit()
            started = false
        }
        publishWorld()
        numbersChanged()
    }

    private func connect(_ id: String) {
        guard !readingOff, let tool, let store, let row = rows.first(where: { $0.id == id }) else { return }
        let connection = connections[id] ?? Connection(book: RemoteBook(host: row.machine.name))
        connections[id] = connection
        guard connection.link == nil else { return }
        let name = row.machine.name
        let path = store.socket(of: id)
        let server = HookServer(path: path, host: name)
        let owner = WeakHub(self)
        hooks.adopt(server) { signal in
            Task { @MainActor in owner.value?.heard(signal, from: id) }
        }
        // The queue gets the request on its own. The folder it names is what this adds.
        let forward = server.onPermission
        server.onPermission = { request in
            forward?(request)
            Task { @MainActor in owner.value?.asked(request, from: id) }
        }
        _ = server.start()
        connection.server = server
        let link = RemoteLink(machine: name, localSocket: path, tool: tool, wait: hookWait, timing: timing) { state in
            Task { @MainActor in owner.value?.stateChanged(state, of: id) }
        } onMessage: { message in
            Task { @MainActor in owner.value?.heard(message, from: id) }
        }
        connection.link = link
        link.start()
    }

    private func disconnect(_ id: String) {
        guard let connection = connections[id] else { return }
        connection.link?.stop()
        connection.link = nil
        if let server = connection.server {
            server.stop()
            hooks.release(server)
        }
        connection.server = nil
    }

    func quit() {
        for id in connections.keys {
            saveNumbers(of: id)
            disconnect(id)
        }
    }

    func retry(_ id: String) {
        update(id) { $0.problem = nil }
        connections[id]?.link?.retryNow()
    }

    func retryAll() {
        for connection in connections.values { connection.link?.retryNow() }
    }

    // MARK: - The list of machines

    enum AddResult: Equatable {
        case added, invalidName, alreadyThere
    }

    @discardableResult
    func add(_ text: String) -> AddResult {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard RemoteMachine.isAcceptable(name) else { return .invalidName }
        guard !rows.contains(where: { $0.machine.name == name }) else { return .alreadyThere }
        let machine = RemoteMachine(name: name)
        rows.append(Row(machine: machine))
        saveMachines()
        connections[machine.id] = Connection(book: RemoteBook(host: name))
        leftBehind = nil
        connect(machine.id)
        return .added
    }

    func askRemoval(_ id: String, _ asking: Bool) {
        update(id) { $0.confirmingRemoval = asking }
    }

    /// Off the list and out of the numbers at once. What is on the machine is taken away if the machine can be reached, and is harmless if not.
    func remove(_ id: String) {
        guard let row = rows.first(where: { $0.id == id }) else { return }
        disconnect(id)
        connections[id] = nil
        numbersSavedAt[id] = nil
        rows.removeAll { $0.id == id }
        saveMachines()
        store?.forget(id)
        publishWorld()
        numbersChanged()
        guard let tool else { return }
        let helper = RemoteHelper(tool: tool, machine: row.machine.name, wait: hookWait)
        Task { [weak self] in
            let result = await helper.purge()
            if result?.ok != true { self?.leftBehind = row.machine.name }
        }
    }

    func dismissLeftBehind() {
        leftBehind = nil
    }

    private func saveMachines() {
        store?.save(rows.map(\.machine))
    }

    // MARK: - The hooks on a machine

    /// Asks the machine what would change. Nothing has been written yet.
    func askHooks(_ id: String) {
        act(id, "preview") { row, result in
            row.preview = result
        }
    }

    func cancelHooks(_ id: String) {
        update(id) { $0.preview = nil }
    }

    /// The person saw the lines and agreed. A repair goes straight here: they have agreed to these same entries.
    func confirmHooks(_ id: String) {
        act(id, "install") { row, _ in
            row.preview = nil
            row.machine.hooksWanted = true
            row.vitals?.hooks = .installed
        }
    }

    func disconnectHooks(_ id: String) {
        act(id, "uninstall") { row, _ in
            row.machine.hooksWanted = false
            row.vitals?.hooks = .notInstalled
        }
    }

    private func act(_ id: String, _ verb: String, then: @escaping (inout Row, RemoteHookResult) -> Void) {
        guard let tool, let row = rows.first(where: { $0.id == id }), !row.busy else { return }
        let helper = RemoteHelper(tool: tool, machine: row.machine.name, wait: hookWait)
        update(id) {
            $0.busy = true
            $0.problem = nil
        }
        Task { [weak self] in
            let result: RemoteHookResult?
            switch verb {
            case "preview": result = await helper.previewHooks()
            case "install": result = await helper.installHooks()
            default: result = await helper.uninstallHooks()
            }
            self?.acted(id, result: result, then: then)
        }
    }

    private func acted(_ id: String, result: RemoteHookResult?, then: (inout Row, RemoteHookResult) -> Void) {
        update(id) { row in
            row.busy = false
            guard let result else {
                row.problem = .unreachable
                return
            }
            guard result.ok else {
                row.problem = .settingsUnreadable
                row.preview = nil
                return
            }
            then(&row, result)
        }
        saveMachines()
    }

    private func update(_ id: String, _ change: (inout Row) -> Void) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        change(&rows[index])
    }

    // MARK: - What comes from the machines

    private func stateChanged(_ state: RemoteLink.State, of id: String) {
        guard let connection = connections[id] else { return }
        update(id) { $0.state = state }
        switch state {
        case .up:
            connection.book.linkUp()
        case .down:
            connection.book.linkDown(now: Date())
            update(id) { $0.vitals?.socket = false }
        case .connecting, .stopped:
            break
        }
        publishWorld()
    }

    private func heard(_ message: RemoteMessage, from id: String) {
        guard let connection = connections[id] else { return }
        switch message {
        case .hello:
            break
        case .info(_, let vitals), .alive(let vitals):
            update(id) { row in
                if row.vitals != vitals { row.vitals = vitals }
            }
        case .sessions(let reports):
            connection.book.take(sessions: reports, now: Date())
            publishWorld()
        case .numbers(let full, let rows):
            connection.book.take(rows: rows, full: full)
            numbersChanged()
            let now = Date()
            if now.timeIntervalSince(numbersSavedAt[id] ?? .distantPast) >= Self.numbersSaveInterval {
                numbersSavedAt[id] = now
                saveNumbers(of: id)
            }
        }
    }

    private func heard(_ signal: HookSignal, from id: String) {
        guard let connection = connections[id] else { return }
        connection.book.take(signal, now: Date())
        eventVersion += 1
        publishWorld()
        onSignal?(signal)
    }

    private func asked(_ request: PendingPermission, from id: String) {
        connections[id]?.book.note(cwd: request.cwd, session: request.session, now: Date())
        publishWorld()
    }

    /// The engine's view of what a session waits for has to end with the answer, wherever the answer was given.
    private func answered(session: String) {
        let signal = HookSignal.permissionAnswered(session: session)
        for connection in connections.values where connection.book.knows(session: session) {
            connection.book.take(signal, now: Date())
        }
        eventVersion += 1
        onSignal?(signal)
    }

    private func saveNumbers(of id: String) {
        guard let store, let book = connections[id]?.book else { return }
        let rows = book.spendRows
        // Off the main thread: a year of numbers is a large file.
        Task.detached(priority: .utility) { store.save(rows: rows, of: id) }
    }

    /// Bursts of events make one update.
    private func publishWorld() {
        guard !worldPlanned else { return }
        worldPlanned = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard let self else { return }
            self.worldPlanned = false
            self.onWorld?(self.world)
            self.pastSessions = self.readingOff ? [] : self.connections.values.flatMap { $0.book.pastSessions() }
        }
    }

    private func numbersChanged() {
        let books = readingOff ? [] : connections.values.map(\.book)
        onRecords?(books.flatMap { $0.records() })
        pastSessions = books.flatMap { $0.pastSessions() }
    }

    #if DEBUG
    /// For a check that talks to a fake ssh, with everything kept in a temporary folder.
    func useForCheck(tool: SSHTool, store: RemoteStore, timing: RemoteLink.Timing) {
        self.tool = tool
        self.store = store
        self.timing = timing
        started = true
    }

    func showForSnapshot(rows: [Row], leftBehind: String? = nil) {
        self.rows = rows
        self.leftBehind = leftBehind
    }

    func showForSnapshot(events: [RemoteEvent], session: String, host: String) {
        var book = RemoteBook(host: host)
        book.take(sessions: [RemoteSessionReport(id: session)], now: Date())
        for event in events { book.showForSnapshot(event, session: session) }
        connections[host] = Connection(book: book)
    }

    func showForSnapshot(pastSessions: [WorkSession]) {
        self.pastSessions = pastSessions
    }
    #endif
}

private struct WeakHub: @unchecked Sendable {
    weak var value: RemoteHub?

    init(_ value: RemoteHub) {
        self.value = value
    }
}
