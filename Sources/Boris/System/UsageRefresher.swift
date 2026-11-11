import BorisCore
import BorisData
import Foundation
import Observation

/// Decides when Claude Code is asked for fresh limits, and remembers how the last attempt went.
@MainActor
@Observable
final class UsageRefresher {
    private let settings: AppSettings
    private(set) var refreshing = false
    /// The last attempt did not work out. The old values stay, so this is a remark, not a failure of the work.
    private(set) var failed = false
    @ObservationIgnored private var lastAttempt: Date?
    /// Time awake, so that the log tells how long it worked and not how long the Mac slept in between.
    @ObservationIgnored private var startedAt = ProcessInfo.processInfo.systemUptime
    @ObservationIgnored var onFinished: (() -> Void)?
    /// False from «going to sleep» to «woke up». The short wakes with the lid closed come in between and do not count.
    @ObservationIgnored var macAwake = true

    init(settings: AppSettings) {
        self.settings = settings
    }

    func refreshIfDue(now: Date, liveSessions: Int, account: ClaudeAccount, fetchedAt: Date?) {
        // A debug build never starts Claude Code by itself, and nobody asked, so there is no failure to report either.
        #if !DEBUG
        guard !refreshing, UsageRefreshPolicy.isDue(
            now: now,
            enabled: settings.usageRefreshEnabled,
            macAwake: macAwake,
            intervalMinutes: settings.usageRefreshMinutes,
            liveSessions: liveSessions,
            account: account,
            fetchedAt: fetchedAt,
            lastAttempt: lastAttempt
        ) else { return }
        refreshNow(why: .onSchedule)
        #endif
    }

    func refreshNow(why: LogWord = .byButton) {
        guard !refreshing else { return }
        lastAttempt = Date()
        #if DEBUG
        // Debug builds, tests and snapshots must never start the real Claude Code. The button then shows what a failure looks like.
        failed = true
        AppLog.note(.limitsRefreshSkipped)
        #else
        refreshing = true
        startedAt = ProcessInfo.processInfo.systemUptime
        AppLog.note(.limitsRefreshStarted, .word(why))
        failed = false
        let paths = ClaudePaths.resolve(custom: settings.claudeFolder)
        let configFolder = settings.claudeFolder.isEmpty ? ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] : settings.claudeFolder
        let owner = Owner(self)
        DispatchQueue.global(qos: .utility).async {
            let binary = ClaudeCodeBinary.find()
            if binary == nil { AppLog.note(.limitsRefreshProblem, .word(.noClaudeBinary)) }
            let outcome = binary.map {
                UsageProbe(binary: $0, folder: BorisPaths.usageProbeFolder, profile: paths.profile, configFolder: configFolder).run()
            } ?? .failed
            Task { @MainActor in owner.refresher?.finish(outcome) }
        }
        #endif
    }

    private func finish(_ outcome: UsageProbe.Outcome) {
        refreshing = false
        failed = outcome == .failed
        AppLog.note(failed ? .limitsRefreshFailed : .limitsRefreshDone, .seconds(ProcessInfo.processInfo.systemUptime - startedAt))
        onFinished?()
    }

    #if DEBUG
    func showForSnapshot(failed: Bool) {
        self.failed = failed
    }
    #endif
}

private struct Owner: @unchecked Sendable {
    weak var refresher: UsageRefresher?

    init(_ refresher: UsageRefresher) {
        self.refresher = refresher
    }
}
