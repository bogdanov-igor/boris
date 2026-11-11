import BorisCore
import BorisData
import Foundation
import Testing
@testable import Boris

/// Made-up work goes through the model the way a scan does, and every window that counts agents is asked what it would say.
@MainActor
@Suite("Одно число агентов во всех окнах Boris", .serialized)
struct AgentCountSurfacesTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func info(_ id: String, folder: String) -> SessionInfo {
        SessionInfo(sessionId: id, pid: 100, cwd: folder, entrypoint: "cli", status: "busy", statusUpdatedAt: now)
    }

    private func helper(_ id: String, in session: String, state: AgentState = .running) -> AgentSnapshot {
        AgentSnapshot(id: id, sessionId: session, description: id, state: state, lastWrite: now)
    }

    /// In one project 3 + 1 at work, in the other 4, and a session whose process died adds nothing.
    private func work() -> WorkModel {
        var world = WorldSnapshot(takenAt: now, sessions: [info("a", folder: "/x/shop"), info("b", folder: "/x/shop"), info("c", folder: "/x/blog")])
        world.endedSessions = [info("d", folder: "/x/blog")]
        world.agents = [helper("a1", in: "a"), helper("a2", in: "a"), helper("a3", in: "a", state: .done), helper("d1", in: "d")]
        let run = RunState(runId: "wf_1", sessionId: "c", name: "Аудит", cwd: "/x/blog", status: .running, lastWrite: now, agents: [
            AgentRecord(key: "1", agentId: "c1", state: .running),
            AgentRecord(key: "2", agentId: "c2", state: .running),
            AgentRecord(key: "3", agentId: "c3", state: .running),
            AgentRecord(key: "4", agentId: "c4", state: .done),
        ])
        return WorkBuilder.build(world: world, runs: [run])
    }

    @Test("Морж, чёлка, страницы проектов и строки сессий берут число из одного места")
    func oneNumber() throws {
        let model = AppModel(settings: AppSettings(defaults: nil), store: nil, live: false)
        model.apply(WorkEngine.Output(at: now, model: work(), world: WorldSnapshot(takenAt: now)))
        let total = model.work.workingAgents
        #expect(total == 8)

        // Under the walrus in the sidebar, and the menu bar icon's pose.
        #expect(model.mood == .working(agents: total))
        #expect(WalrusLines.standing(mood: model.mood, waiting: model.requestCount) == "8 agents at work")
        // The notch and the panel.
        let inputs = SurfaceInputs(model: model)
        #expect(inputs.numbers.agents == total)
        #expect(SurfaceWords.closedLine(inputs.numbers, mode: .simple, onNotch: true).main == "8 agents at work")

        // The projects add up to the total, and so do the sessions in them.
        let projects = ProjectBook.summaries(sessions: model.allSessions, tokens: [], filter: ProjectFilter(), now: now)
        #expect(projects.reduce(0) { $0 + $1.workingAgents } == total)
        let shop = try #require(projects.first { $0.path == "/x/shop" })
        let blog = try #require(projects.first { $0.path == "/x/blog" })
        #expect(shop.active.map(\.workingAgents).sorted() == [1, 3])
        #expect(ProjectStateLabel(project: shop, mode: .simple, now: now).text == "Working · 4 agents")
        #expect(ProjectStateLabel(project: blog, mode: .technical, now: now).text == "Running · 4 agents")
        #expect(model.activeSessions.reduce(0) { $0 + $1.workingAgents } == total)
    }
}
