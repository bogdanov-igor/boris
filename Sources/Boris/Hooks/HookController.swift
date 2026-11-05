import BorisCore
import BorisData
import Foundation
import Observation

/// Everything about the connection to Claude's settings: what is installed, the local server, and requests waiting for an answer.
@MainActor
@Observable
final class HookController {
    private(set) var status: HookInstaller.Status = .notInstalled
    private(set) var serverRunning = false
    private(set) var pending: [PendingPermission] = []
    /// When the hooks could first have spoken.
    private(set) var since = Date()

    private let settings: AppSettings
    private let live: Bool
    private var server: HookServer?
    var onSignal: ((HookSignal) -> Void)?

    /// - Parameter live: false never reads Claude's settings or opens the socket, as in a snapshot.
    init(settings: AppSettings, live: Bool = true) {
        self.settings = settings
        self.live = live
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
        return HookInstaller.Plan(helperPath: folder.appendingPathComponent("boris-hook").path, permissions: true, permissionWait: settings.permissionWaitSeconds)
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
        try HookInstaller.install(at: settingsFile, plan: plan)
        settings.hooksWanted = true
        since = Date()
        refresh()
    }

    func disconnect() throws {
        try HookInstaller.uninstall(at: settingsFile)
        settings.hooksWanted = false
        refresh()
    }

    private func startServer() {
        guard server == nil else { return }
        let server = HookServer(path: HookServer.defaultPath)
        let owner = WeakHooks(self)
        server.onSignal = { signal in
            Task { @MainActor in owner.value?.onSignal?(signal) }
        }
        server.onPermission = { request in
            Task { @MainActor in owner.value?.pending.append(request) }
        }
        server.onPermissionGone = { id in
            Task { @MainActor in owner.value?.pending.removeAll { $0.id == id } }
        }
        serverRunning = server.start()
        self.server = server
    }

    func stopServer() {
        server?.stop()
        server = nil
        serverRunning = false
        pending = []
    }

    /// The answer goes only to this request. The command text leaves memory with it.
    func answer(_ id: UUID, allow: Bool) {
        guard pending.contains(where: { $0.id == id }) else { return }
        pending.removeAll { $0.id == id }
        server?.answer(id, allow: allow)
    }

    #if DEBUG
    func showForSnapshot(status: HookInstaller.Status) {
        self.status = status
    }
    #endif
}

private struct WeakHooks: @unchecked Sendable {
    weak var value: HookController?

    init(_ value: HookController) {
        self.value = value
    }
}
