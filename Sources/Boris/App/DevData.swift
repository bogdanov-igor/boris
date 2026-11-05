#if DEBUG
import BorisCore
import Foundation

/// Made-up work for looking at screens. Nothing here comes from real sessions.
@MainActor
enum DevData: String {
    case busy, empty, long

    func fill(_ model: AppModel, offer: Bool = false, issues: Set<FormatIssue> = [], folderFound: Bool = true) {
        let now = Date()
        let world = WorldSnapshot(
            takenAt: now,
            usage: self == .empty ? nil : UsageSnapshot(fetchedAt: now.addingTimeInterval(-720), windows: [
                UsageWindow(id: "five_hour", kind: .fiveHour, percent: 62, resetsAt: now.addingTimeInterval(8000)),
                UsageWindow(id: "seven_day", kind: .week, percent: 34, resetsAt: now.addingTimeInterval(4 * 86400)),
            ]),
            claudeFolderFound: folderFound,
            formatIssues: issues
        )
        let tokens = self == .empty ? TokenUsage() : TokenUsage(input: 520_000, output: 60_000, cacheRead: 1_170_000, cacheWrite: 90_000)
        let mood: Mood = self == .empty ? .sleeping : .waiting
        model.showForSnapshot(work: work(now: now), world: world, today: tokens, mood: mood, offer: offer)
        fillLosses(model, now: now)
    }

    private func work(now: Date) -> WorkModel {
        guard self != .empty else { return WorkModel() }
        let long = self == .long
        let waiting = WorkSession(
            id: "a1",
            environment: .vsCode,
            cwd: long ? "/x/a-very-long-project-name-that-nobody-would-ever-want-to-type-by-hand-more-than-once" : "/x/shop-api",
            state: .waiting,
            waitingFor: .permission(tool: "Bash"),
            startedAt: now.addingTimeInterval(-2520),
            root: WorkNode(id: "a1", kind: .main, state: .waiting, tokens: TokenUsage(input: 900_000))
        )
        let helpers = (1...3).map { WorkNode(id: "h\($0)", kind: .subagent, state: .running) }
        let running = WorkSession(
            id: "b1",
            environment: .terminal,
            cwd: "/x/boris",
            state: .running,
            startedAt: now.addingTimeInterval(-3960),
            root: WorkNode(id: "b1", kind: .main, state: .running, step: StepBrief(kind: .edit, tool: "Edit", fileName: long ? "a-file-with-a-name-so-long-that-it-cannot-possibly-fit-anywhere-on-one-line.swift" : "auth.swift"), tokens: TokenUsage(input: 1_750_000), children: helpers)
        )
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
            WorkProject(path: silent.cwd, sessions: [silent]),
        ])
    }
}
#endif
