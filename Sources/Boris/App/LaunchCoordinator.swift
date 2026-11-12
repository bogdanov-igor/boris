import AppKit
import BorisCore
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
    /// Tells the running copy to open its mini window.
    case askOtherAndLeave
    /// A developer's copy tells nobody anything.
    case leaveQuietly
}

/// Keeps one running instance and hands work to the launchd agent, which is the copy that restarts after a crash.
/// The agent stays registered whether autostart is on or off, so that a crash always brings Boris back. Off only means that the copy launchd starts at login leaves at once.
@MainActor
final class LaunchCoordinator {
    static let openMenuNotification = Notification.Name("app.boris.Boris.openMenu")
    static let handOverNotification = Notification.Name("app.boris.Boris.handOver")
    static let agentPlist = "app.boris.Boris.agent.plist"
    static let agentLabel = "app.boris.Boris.agent"
    private static let reopenSettingsKey = "reopenSettingsAfterHandOver"
    static let autostartOffKey = "autostartOff"
    static let configuredKey = "autostartConfigured"
    /// The process id of the copy that is running. It is removed when that copy quits normally, so it stays behind only after a crash.
    static let runningKey = "runningCopy"

    private var observers: [NSObjectProtocol] = []
    private let isAgentInstance: Bool
    let agent: any LoginAgent
    private let isDebug: Bool
    /// Nil outside the real app: a check must leave no trace in the defaults of the process that runs it.
    private let defaults: UserDefaults?
    private let pid: Int

    init(
        agent: any LoginAgent = SMAppService.agent(plistName: LaunchCoordinator.agentPlist),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isDebug: Bool = LaunchCoordinator.isDebugBuild,
        defaults: UserDefaults? = LaunchCoordinator.isRealLaunch ? .standard : nil,
        pid: Int = Int(ProcessInfo.processInfo.processIdentifier)
    ) {
        self.agent = agent
        self.isDebug = isDebug
        self.defaults = defaults
        self.pid = pid
        isAgentInstance = environment["BORIS_LAUNCHD"] == "1"
    }

    /// Whether a copy that launchd started leaves at once. launchd starts it at login and after a crash alike, and only how the last run ended tells them apart.
    /// It leaves with exit code 0, so launchd does not start it again.
    nonisolated static func leavesAtStart(isAgent: Bool, autostartOff: Bool, lastRunEndedNormally: Bool) -> Bool {
        isAgent && autostartOff && lastRunEndedNormally
    }

    private var autostartOff: Bool { defaults?.bool(forKey: Self.autostartOffKey) ?? false }
    private var lastRunEndedNormally: Bool { defaults?.object(forKey: Self.runningKey) == nil }

    /// This copy is the one that runs. Also before handing over to the agent: the copy launchd starts for that must not take it for a login.
    func noteRunStarted() {
        defaults?.set(pid, forKey: Self.runningKey)
    }

    /// Only the copy that is running clears its mark: a copy that steps aside for another must not make that one's crash look like a normal quit.
    func noteQuitNormally() {
        guard let defaults, defaults.integer(forKey: Self.runningKey) == pid else { return }
        defaults.removeObject(forKey: Self.runningKey)
    }

    /// The agent is what brings Boris back after a crash, so it is put back whenever it is missing.
    /// Earlier versions turned autostart off by removing it, so a missing agent after the first launch means the person had turned it off.
    func keepAgentRegistered() {
        guard let defaults else { return }
        let configured = defaults.bool(forKey: Self.configuredKey)
        defaults.set(true, forKey: Self.configuredKey)
        guard agent.status != .enabled, agent.status != .requiresApproval else { return }
        if configured, agent.status == .notRegistered { defaults.set(true, forKey: Self.autostartOffKey) }
        do {
            try agent.register()
            AppLog.note(.autostartChanged, .flag(!autostartOff))
        } catch {
            AppLog.note(.autostartFailed, .failure(error))
        }
    }

    static func otherCopies() -> [NSRunningApplication] {
        let selfPid = ProcessInfo.processInfo.processIdentifier
        let bundleId = Bundle.main.bundleIdentifier ?? "app.boris.Boris"
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            .filter { $0.processIdentifier != selfPid }
    }

    nonisolated static func claim(othersRun: Bool, isAgent: Bool, isDebug: Bool) -> LaunchClaim {
        if isDebug { return othersRun ? .leaveQuietly : .run }
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
        if !isDebug, Self.leavesAtStart(isAgent: isAgentInstance, autostartOff: autostartOff, lastRunEndedNormally: lastRunEndedNormally) { return false }
        switch Self.claim(othersRun: !others.isEmpty, isAgent: isAgentInstance, isDebug: isDebug) {
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
        }
    }

    /// Asks the system by process id too: this runs before the app has started, when what a running application says about itself may not change.
    private func waitUntilGone(_ others: [NSRunningApplication]) -> Bool {
        func isGone(_ other: NSRunningApplication) -> Bool { other.isTerminated || kill(other.processIdentifier, 0) != 0 }
        for _ in 0..<50 where !others.allSatisfy(isGone) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return others.allSatisfy(isGone)
    }

    /// Hands over from a manually opened copy to the launchd agent, whether autostart is on or off: only the agent's copy comes back after a crash.
    /// This copy quits only once the agent's copy is really running. launchd accepting the start is not enough: an agent registered
    /// by a copy signed otherwise, one built from source before a release say, is killed by the system the moment it starts.
    /// Registering it again from this copy makes the system's record match. Should that not help either, this copy simply goes on.
    /// - Returns: true when this copy should quit.
    func handOverToAgentIfNeeded(
        isBundled: Bool = Bundle.main.bundleURL.pathExtension == "app",
        start: @MainActor () -> Bool = { LaunchCoordinator.kickstartAgent() },
        cameUp: @MainActor () -> Bool = { LaunchCoordinator.waitForAgentCopy() }
    ) -> Bool {
        guard !isAgentInstance, isBundled, agent.status == .enabled else { return false }
        if start(), cameUp() { return true }
        do {
            try agent.unregister()
            try agent.register()
            AppLog.note(.agentReregistered)
        } catch {
            AppLog.note(.autostartFailed, .failure(error))
            return false
        }
        guard agent.status == .enabled else { return false }
        return start() && cameUp()
    }

    /// Asks launchd to start the agent now. True means only that launchd took the request.
    static func kickstartAgent() -> Bool {
        let kick = Process()
        kick.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        kick.arguments = ["kickstart", "gui/\(getuid())/\(agentLabel)"]
        do {
            try kick.run()
            kick.waitUntilExit()
            return kick.terminationStatus == 0
        } catch {
            AppLog.note(.autostartFailed, .failure(error))
            return false
        }
    }

    /// Whether another copy of Boris, the agent's, shows up within a few seconds.
    static func waitForAgentCopy(seconds: TimeInterval = 5) -> Bool {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until {
            if !otherCopies().isEmpty { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return !otherCopies().isEmpty
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
        case .enabled: return autostartOff ? .off : .on
        case .requiresApproval: return .needsApproval
        default: return .off
        }
    }

    /// Only the wish changes: the agent stays, so a crash still brings Boris back. Should the agent be missing, it is registered, and the copy on screen ends up replaced by the agent's.
    /// Whoever is looking at the settings has to find them there again, so that the switch does not look like a crash.
    /// - Parameter prepare: saves what must not be lost when this copy goes away.
    /// - Returns: false when macOS refused.
    func setAutostart(_ on: Bool, prepare: () -> Void) -> Bool {
        prepare()
        let wasOff = autostartOff
        defaults?.set(!on, forKey: Self.autostartOffKey)
        guard agent.status != .enabled else {
            AppLog.note(.autostartChanged, .flag(on))
            return true
        }
        do {
            // launchd starts the agent's copy at once, and it asks this one to step aside.
            noteSettingsToReopen(true)
            try agent.register()
            AppLog.note(.autostartChanged, .flag(on))
            return true
        } catch {
            noteSettingsToReopen(false)
            defaults?.set(wasOff, forKey: Self.autostartOffKey)
            AppLog.note(.autostartFailed, .failure(error))
            return false
        }
    }

    private func noteSettingsToReopen(_ reopen: Bool) {
        if reopen {
            defaults?.set(true, forKey: Self.reopenSettingsKey)
        } else {
            defaults?.removeObject(forKey: Self.reopenSettingsKey)
        }
    }

    /// A check must leave no trace in the defaults of the process that runs it.
    nonisolated static var isRealLaunch: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    /// True once, for the copy that replaced the one whose settings were open.
    func shouldReopenSettings() -> Bool {
        guard let defaults, defaults.bool(forKey: Self.reopenSettingsKey) else { return false }
        defaults.removeObject(forKey: Self.reopenSettingsKey)
        return true
    }
}
