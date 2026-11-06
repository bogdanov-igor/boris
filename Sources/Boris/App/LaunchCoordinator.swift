import AppKit
import ServiceManagement

/// The launchd job, apart from the system, so that what is decided about it can be checked without launchd.
@MainActor
protocol LoginAgent {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: LoginAgent {}

enum AutostartState: Equatable {
    case on, off
    /// The person turned Boris off in System Settings, and only they can turn it on again there.
    case needsApproval
}

/// What a starting copy does about the other copies running.
enum LaunchClaim: Equatable {
    case run
    /// launchd started this copy while a hand-opened one runs: that one steps aside.
    case takeOverFromHandOpened
    /// The agent's copy asked for this one, because turning the agent off kills it.
    case takeOverFromAgent
    /// Tells the running copy to open its mini window.
    case askOtherAndLeave
    /// A developer's copy tells nobody anything.
    case leaveQuietly
}

/// Keeps one running instance and hands work to the launchd agent, which is the copy that restarts after a crash.
@MainActor
final class LaunchCoordinator {
    static let openMenuNotification = Notification.Name("app.boris.Boris.openMenu")
    static let handOverNotification = Notification.Name("app.boris.Boris.handOver")
    static let agentPlist = "app.boris.Boris.agent.plist"
    static let agentLabel = "app.boris.Boris.agent"
    private static let reopenSettingsKey = "reopenSettingsAfterHandOver"
    private static let takeOverVariable = "BORIS_TAKE_OVER_FROM_AGENT"

    private var observers: [NSObjectProtocol] = []
    private let isAgentInstance: Bool
    /// This copy was started to stay after the agent's copy goes away.
    let takesOverFromAgent: Bool
    let agent: any LoginAgent
    private let isDebug: Bool
    private let startPlainCopy: @MainActor () -> Void

    /// - Parameter startPlainCopy: starts a copy of the app that launchd has nothing to do with.
    init(
        agent: any LoginAgent = SMAppService.agent(plistName: LaunchCoordinator.agentPlist),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isDebug: Bool = LaunchCoordinator.isDebugBuild,
        startPlainCopy: @escaping @MainActor () -> Void = LaunchCoordinator.startPlainCopy
    ) {
        self.agent = agent
        self.isDebug = isDebug
        isAgentInstance = environment["BORIS_LAUNCHD"] == "1"
        takesOverFromAgent = environment[Self.takeOverVariable] == "1"
        self.startPlainCopy = startPlainCopy
    }

    static func otherCopies() -> [NSRunningApplication] {
        let selfPid = ProcessInfo.processInfo.processIdentifier
        let bundleId = Bundle.main.bundleIdentifier ?? "app.boris.Boris"
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            .filter { $0.processIdentifier != selfPid }
    }

    nonisolated static func claim(othersRun: Bool, isAgent: Bool, takesOverFromAgent: Bool, isDebug: Bool) -> LaunchClaim {
        if isDebug { return othersRun ? .leaveQuietly : .run }
        // Whether or not that copy is still around, its job has to go.
        if takesOverFromAgent { return .takeOverFromAgent }
        guard othersRun else { return .run }
        return isAgent ? .takeOverFromHandOpened : .askOtherAndLeave
    }

    static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    /// Returns false when this process should exit because another instance owns the work.
    func claimInstance(others: [NSRunningApplication] = LaunchCoordinator.otherCopies()) -> Bool {
        switch Self.claim(othersRun: !others.isEmpty, isAgent: isAgentInstance, takesOverFromAgent: takesOverFromAgent, isDebug: isDebug) {
        case .run:
            return true
        case .leaveQuietly:
            print("Another Boris is running, so this debug copy leaves it alone and quits.")
            return false
        case .askOtherAndLeave:
            post(Self.openMenuNotification)
            return false
        case .takeOverFromHandOpened:
            post(Self.handOverNotification)
            waitUntilGone(others)
            return true
        case .takeOverFromAgent:
            // launchd kills the agent's copy for this. Should it refuse, that copy goes on, and this one must not run beside it.
            try? agent.unregister()
            return waitUntilGone(others)
        }
    }

    /// Asks the system by process id too: this runs before the app has started, when what a running application says about itself may not change.
    @discardableResult
    private func waitUntilGone(_ others: [NSRunningApplication]) -> Bool {
        func isGone(_ other: NSRunningApplication) -> Bool { other.isTerminated || kill(other.processIdentifier, 0) != 0 }
        for _ in 0..<50 where !others.allSatisfy(isGone) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return others.allSatisfy(isGone)
    }

    /// Hands over from a manually opened copy to the launchd agent when autostart is on.
    /// Returns true when this copy should quit.
    func handOverToAgentIfNeeded() -> Bool {
        guard !isAgentInstance, !takesOverFromAgent, Bundle.main.bundleURL.pathExtension == "app", agent.status == .enabled else { return false }
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

    // MARK: - Open at login

    var autostartState: AutostartState {
        switch agent.status {
        case .enabled: return .on
        case .requiresApproval: return .needsApproval
        default: return .off
        }
    }

    /// Both ways, the copy on screen ends up replaced by another. Whoever is looking at the settings has to find them there again, so that the switch does not look like a crash.
    /// - Parameter prepare: saves what must not be lost when this copy goes away.
    /// - Returns: false when macOS refused.
    func setAutostart(_ on: Bool, prepare: () -> Void) -> Bool {
        prepare()
        if !on, isAgentInstance {
            // This copy is the job being turned off, and launchd kills a job that it removes. So a plain copy does the removing, and stays.
            startPlainCopy()
            return true
        }
        do {
            if on {
                // launchd starts the agent's copy at once, and it asks this one to step aside.
                noteSettingsToReopen(true)
                try agent.register()
            } else {
                try agent.unregister()
            }
            return true
        } catch {
            noteSettingsToReopen(false)
            return false
        }
    }

    private func noteSettingsToReopen(_ reopen: Bool) {
        guard Self.isRealLaunch else { return }
        if reopen {
            UserDefaults.standard.set(true, forKey: Self.reopenSettingsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.reopenSettingsKey)
        }
    }

    /// A check must leave no trace in the defaults of the process that runs it.
    private static var isRealLaunch: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    /// True once, for the copy that replaced the one whose settings were open.
    func shouldReopenSettings() -> Bool {
        if takesOverFromAgent { return true }
        guard Self.isRealLaunch, UserDefaults.standard.bool(forKey: Self.reopenSettingsKey) else { return false }
        UserDefaults.standard.removeObject(forKey: Self.reopenSettingsKey)
        return true
    }

    private static func startPlainCopy() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = false
        configuration.environment = [takeOverVariable: "1"]
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration)
    }
}
