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
    @ObservationIgnored var onFinished: (() -> Void)?

    init(settings: AppSettings) {
        self.settings = settings
    }

    func refreshIfDue(now: Date, liveSessions: Int, account: ClaudeAccount, fetchedAt: Date?) {
        // A debug build never starts Claude Code by itself, and nobody asked, so there is no failure to report either.
        #if !DEBUG
        guard !refreshing, UsageRefreshPolicy.isDue(
            now: now,
            enabled: settings.usageRefreshEnabled,
            intervalMinutes: settings.usageRefreshMinutes,
            liveSessions: liveSessions,
            account: account,
            fetchedAt: fetchedAt,
            lastAttempt: lastAttempt
        ) else { return }
        refreshNow()
        #endif
    }

    func refreshNow() {
        guard !refreshing else { return }
        lastAttempt = Date()
        #if DEBUG
        // Debug builds, tests and snapshots must never start the real Claude Code. The button then shows what a failure looks like.
        failed = true
        #else
        refreshing = true
        failed = false
        let paths = ClaudePaths.resolve(custom: settings.claudeFolder)
        let configFolder = settings.claudeFolder.isEmpty ? ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] : settings.claudeFolder
        let owner = Owner(self)
        DispatchQueue.global(qos: .utility).async {
            let outcome = ClaudeCodeBinary.find().map {
                UsageProbe(binary: $0, folder: BorisPaths.usageProbeFolder, profile: paths.profile, configFolder: configFolder).run()
            } ?? .failed
            Task { @MainActor in owner.refresher?.finish(outcome) }
        }
        #endif
    }

    private func finish(_ outcome: UsageProbe.Outcome) {
        refreshing = false
        failed = outcome == .failed
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
