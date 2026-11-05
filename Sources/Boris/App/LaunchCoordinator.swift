import AppKit
import ServiceManagement

/// Keeps one running instance and hands work to the launchd agent, which is the copy that restarts after a crash.
@MainActor
final class LaunchCoordinator {
    static let openMenuNotification = Notification.Name("app.boris.Boris.openMenu")
    static let handOverNotification = Notification.Name("app.boris.Boris.handOver")
    static let agentPlist = "app.boris.Boris.agent.plist"
    static let agentLabel = "app.boris.Boris.agent"

    private var observers: [NSObjectProtocol] = []
    private let isAgentInstance = ProcessInfo.processInfo.environment["BORIS_LAUNCHD"] == "1"

    var agent: SMAppService { SMAppService.agent(plistName: Self.agentPlist) }

    /// Returns false when this process should exit because another instance owns the work.
    func claimInstance() -> Bool {
        let selfPid = ProcessInfo.processInfo.processIdentifier
        let bundleId = Bundle.main.bundleIdentifier ?? "app.boris.Boris"
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            .filter { $0.processIdentifier != selfPid }

        guard !others.isEmpty else { return true }

        #if DEBUG
        // A developer's copy must not open the real copy's menu or make it quit. It shares its files too, so it simply does not start.
        print("Another Boris is running, so this debug copy leaves it alone and quits.")
        return false
        #else
        if isAgentInstance {
            // launchd started us while a manually opened copy runs: that copy steps aside.
            post(Self.handOverNotification)
            for _ in 0..<20 where others.contains(where: { !$0.isTerminated }) {
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            }
            return true
        }
        post(Self.openMenuNotification)
        return false
        #endif
    }

    /// Hands over from a manually opened copy to the launchd agent when autostart is on.
    /// Returns true when this copy should quit.
    func handOverToAgentIfNeeded() -> Bool {
        guard !isAgentInstance, Bundle.main.bundleURL.pathExtension == "app", agent.status == .enabled else { return false }
        let kick = Process()
        kick.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        kick.arguments = ["kickstart", "gui/\(getuid())/\(Self.agentLabel)"]
        do {
            try kick.run()
            kick.waitUntilExit()
            return kick.terminationStatus == 0
        } catch {
            return false
        }
    }

    func listen(openMenu: @escaping @MainActor () -> Void) {
        // What the real copy says to its own kind is not for a developer's copy, which would come forward or quit because of it.
        #if !DEBUG
        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(forName: Self.openMenuNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { openMenu() }
        })
        observers.append(center.addObserver(forName: Self.handOverNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { NSApp.terminate(nil) }
        })
        #endif
    }

    private func post(_ name: Notification.Name) {
        DistributedNotificationCenter.default().postNotificationName(name, object: nil, userInfo: nil, deliverImmediately: true)
    }
}
