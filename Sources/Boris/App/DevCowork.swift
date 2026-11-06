#if DEBUG
import BorisCore
import BorisData
import Foundation

/// Made-up Cowork work for looking at screens. Nothing here comes from real sessions.
@MainActor
enum DevCowork {
    static let session = "c1"

    /// The Cowork session of the made-up work, asking the person a question that only Claude Desktop can take.
    static func showWaiting(_ model: AppModel, long: Bool) {
        let now = Date()
        let root = WorkNode(id: session, kind: .main, state: .waiting, step: StepBrief(kind: .other, tool: "AskUserQuestion"), model: "model-name")
        let waiting = WorkSession(
            id: session,
            environment: .cowork,
            cwd: "/sessions/made-up-name",
            title: long ? "Отчёт за квартал со всеми приложениями, сверками и очень подробными пояснениями для всех отделов" : "Отчёт за квартал",
            state: .waiting,
            waitingFor: .input,
            startedAt: now.addingTimeInterval(-1440),
            lastActivity: now.addingTimeInterval(-40),
            root: root
        )
        let others = model.work.projects.map { project in
            WorkProject(path: project.path, sessions: project.sessions.filter { $0.id != session })
        }
        model.showForSnapshot(work: WorkModel(projects: [WorkProject(path: nil, sessions: [waiting])] + others.filter { !$0.sessions.isEmpty }), world: model.world, today: model.today, mood: .waiting)
        model.hooks.selectedRow = model.hooks.queue.rows(now: now).first { $0.session == session }?.id
    }
}
#endif
