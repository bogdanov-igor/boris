#if DEBUG
import BorisCore
import BorisData
import Foundation

/// Made-up work for looking at screens. Nothing here comes from real sessions.
@MainActor
enum DevData: String {
    case busy, empty, long, big

    func fill(_ model: AppModel, offer: Bool = false, issues: Set<FormatIssue> = [], folderFound: Bool = true, sessions: [SessionInfo] = []) {
        let now = Date()
        var world = WorldSnapshot(
            takenAt: now,
            sessions: sessions,
            usage: self == .empty ? nil : UsageSnapshot(fetchedAt: now.addingTimeInterval(-720), windows: [
                UsageWindow(id: "five_hour", kind: .fiveHour, percent: 62, resetsAt: now.addingTimeInterval(8000)),
                UsageWindow(id: "seven_day", kind: .week, percent: 34, resetsAt: now.addingTimeInterval(4 * 86400)),
            ]),
            claudeFolderFound: folderFound,
            formatIssues: issues
        )
        world.account = self == .empty ? .unknown : .signedIn
        world.usage?.extra = .on(used: 12.4, limit: 50, currency: "USD")
        let projectTokens = self == .empty ? [] : DevProjects.tokens(now: now)
        model.usage.showForSnapshot(book: DevUsageData.book(for: self, now: now, adding: projectTokens), records: projectTokens)
        let tokens = self == .empty ? TokenUsage() : TokenUsage(input: 520_000, output: 60_000, cacheRead: 1_170_000, cacheWrite: 90_000)
        let mood: Mood = self == .empty ? .sleeping : .waiting
        model.feedForSnapshot = feed(now: now)
        model.showForSnapshot(work: work(now: now), world: world, today: tokens, mood: mood, offer: offer)
        model.load.showForSnapshot(macLoad)
        fillLosses(model, now: now)
        let hasPast = self == .busy || self == .long
        model.showProjectsForSnapshot(past: hasPast ? DevProjects.past(now: now, long: self == .long) : [])
    }

    private func work(now: Date) -> WorkModel {
        guard self != .empty else { return WorkModel() }
        if self == .big {
            let session = DevProjects.bigSession(now: now)
            return WorkModel(projects: [WorkProject(path: session.cwd, sessions: [session])])
        }
        let long = self == .long
        let waiting = DevProjects.troubledSession(now: now, long: long)
        let running = DevProjects.workingSession(now: now, long: long)
        let cowork = WorkSession(
            id: "c1",
            environment: .cowork,
            title: long ? "Отчёт за квартал со всеми приложениями, сверками и очень подробными пояснениями для всех отделов" : "Отчёт за квартал",
            state: .running,
            startedAt: now.addingTimeInterval(-1440),
            root: WorkNode(id: "c1", kind: .main, state: .running, step: StepBrief(kind: .read, tool: "Read"))
        )
        let silent = WorkSession(
            id: "d1",
            environment: .cursor,
            cwd: "/x/landing",
            state: .silent,
            startedAt: now.addingTimeInterval(-900),
            root: WorkNode(id: "d1", kind: .main, state: .silent)
        )
        return WorkModel(projects: [
            WorkProject(path: waiting.cwd, sessions: [waiting]),
            WorkProject(path: running.cwd, sessions: [running]),
            WorkProject(path: nil, sessions: [cowork]),
            WorkProject(path: silent.cwd, sessions: [silent, DevProjects.finishedSession(now: now)]),
        ])
    }
}
#endif
