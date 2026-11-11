import BorisCore
import Foundation
import Testing

/// Made-up work only: sessions with helpers, a workflow with agents in every state, a session that is over and one whose process died.
@Suite("Одно число работающих агентов на всех экранах")
struct AgentCountTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func info(_ id: String, status: String = "busy", waitingFor: String? = nil) -> SessionInfo {
        SessionInfo(sessionId: id, pid: 100, cwd: "/x/\(id)", entrypoint: "cli", status: status, waitingFor: waitingFor, statusUpdatedAt: now)
    }

    private func helper(_ id: String, in session: String, under parent: String? = nil, fork: Bool = false, state: AgentState = .running) -> AgentSnapshot {
        AgentSnapshot(id: id, sessionId: session, parentAgentId: parent, description: id, isFork: fork, state: state, lastWrite: now)
    }

    /// 4 + 1 + 5 + 1 agents at work, in the sessions that go on. The two that are over add nothing.
    private func work() -> WorkModel {
        var world = WorldSnapshot(takenAt: now, sessions: [
            info("busy"),
            info("asking", status: "waiting", waitingFor: "approve Bash"),
            info("flow"),
            info("background", status: "idle"),
            info("done", status: "idle"),
        ])
        // Its process vanished, and the files of two of its helpers still say they are running.
        world.endedSessions = [info("killed")]
        world.agents = [
            helper("b1", in: "busy"), helper("b2", in: "busy"), helper("b2-fork", in: "busy", under: "b2", fork: true), helper("b3", in: "busy", state: .done),
            helper("a1", in: "asking"),
            helper("bg1", in: "background"),
            helper("d1", in: "done", state: .done),
            helper("k1", in: "killed"), helper("k2", in: "killed"),
            // Started by an agent of the workflow.
            helper("w1-helper", in: "flow", under: "w1"),
        ]
        let audit = RunState(runId: "wf_audit", sessionId: "flow", name: "Аудит", cwd: "/x/flow", status: .running, lastWrite: now, agents: [
            AgentRecord(key: "1", agentId: "w1", state: .running),
            AgentRecord(key: "2", agentId: "w2", state: .running),
            AgentRecord(key: "3", agentId: "w3", state: .running),
            AgentRecord(key: "4", agentId: "w4", state: .done),
            AgentRecord(key: "5", agentId: "w5", state: .done),
            AgentRecord(key: "6", agentId: "w6", state: .failed),
            AgentRecord(key: "7", agentId: "w7", state: .cancelled),
        ])
        let earlier = RunState(runId: "wf_earlier", sessionId: "flow", name: "Сбор", cwd: "/x/flow", status: .completed, lastWrite: now, agents: [
            AgentRecord(key: "1", agentId: "e1", state: .done),
            AgentRecord(key: "2", agentId: "e2", state: .done),
        ])
        return WorkBuilder.build(world: world, runs: [audit, earlier])
    }

    private func sessions(_ work: WorkModel) -> [String: WorkSession] {
        Dictionary(uniqueKeysWithValues: work.sessions.map { ($0.id, $0) })
    }

    @Test("Главные агенты, помощники и агенты workflow считаются по разу, а сессии складываются в итог")
    func sessionsAddUp() {
        let work = work()
        let found = sessions(work)
        #expect(found.mapValues(\.state) == ["busy": .running, "asking": .waiting, "flow": .running, "background": .running, "done": .finished, "killed": .interrupted])
        // The main agent waiting for the person is not at work, its helper is. One that ended its turn is not, its helper in the background is.
        #expect(found.mapValues(\.workingAgents) == ["busy": 4, "asking": 1, "flow": 5, "background": 1, "done": 0, "killed": 0])
        #expect(work.workingAgents == 11)
        #expect(work.sessions.reduce(0) { $0 + $1.workingAgents } == work.workingAgents)
        // What a dead session's files say is out of date, and a workflow is a script, not an agent.
        #expect(found["killed"]?.root.flattened.contains { $0.state == .running } == true)
        #expect(found["flow"]?.root.flattened.contains { $0.kind == .workflow && $0.state == .running } == true)
    }

    @Test("Морж под боковой панелью, чёлка и полоса в строке меню показывают одно и то же число")
    func surfacesShowTheTotal() {
        let work = work()
        let total = work.workingAgents
        // A request would put the walrus on watch, and here he has to say how many are at work.
        let matrix = ReactionMatrix(overrides: [.waiting: Reaction(banner: true, sound: true, mood: .none)])
        let mood = MoodBoard().mood(work: work, broken: false, matrix: matrix, now: now)
        #expect(mood == .working(agents: total))
        #expect(WalrusLines.standing(mood: mood, waiting: 0) == "11 agents at work")

        let numbers = SurfaceNumbers(work: work, requests: 1, today: nil, usage: nil)
        #expect(numbers.agents == total)
        #expect(SurfaceWords.closedLine(numbers, mode: .simple, onNotch: false) == SurfaceLine(main: "11 agents at work", waiting: "1 needs you"))
        #expect(SurfaceWords.closedLine(numbers, mode: .technical, onNotch: true).main == "11 agents")
        #expect(SurfaceWords.stripLines(numbers, mode: .simple, spoken: nil).contains(SurfaceLine(main: "11 agents", waiting: "1 needs you")))
    }

    @Test("Строка сессии и её страница называют её долю итога тем же счётом")
    func sessionRowsAndPage() throws {
        let found = sessions(work())
        for mode in [DisplayMode.simple, .technical] {
            var shown = 0
            for session in found.values {
                let line = WorkPhrases.lineParts(session, mode: mode)
                #expect(WorkPhrases.line(session, mode: mode) == line.agents.map { "\(line.doing) · \($0)" } ?? line.doing)
                guard let agents = line.agents else {
                    // A row without a number has one agent at most, or says it waits for you or how it ended.
                    #expect(session.workingAgents <= 1 || session.state != .running)
                    continue
                }
                #expect(agents == (mode == .simple ? WorkPhrases.agentsWorking(session.workingAgents) : WorkPhrases.agents(session.workingAgents)))
                shown += session.workingAgents
            }
            #expect(shown == 9)
        }
        let flow = try #require(found["flow"])
        #expect(WorkPhrases.lineParts(flow, mode: .simple).agents == "5 agents working")
        #expect(WorkPhrases.agentsWorking(flow.workingAgents) == "5 agents working")
        #expect(WorkPhrases.lineParts(try #require(found["busy"]), mode: .technical).agents == "4 agents")
    }

    @Test("Закончившаяся, прерванная или потерявшая связь сессия никого не держит за работающих, а один агент дважды считается раз")
    func overIsOver() {
        let stale = WorkNode(id: "h", kind: .subagent, state: .running)
        for state in [WorkState.interrupted, .unreachable, .finished, .failed, .stopped] {
            let session = WorkSession(id: "s", state: state, root: WorkNode(id: "s", kind: .main, state: .running, children: [stale]))
            #expect(session.workingAgents == 0)
        }
        for state in [WorkState.running, .silent, .waiting] {
            let session = WorkSession(id: "s", state: state, root: WorkNode(id: "s", kind: .main, state: .running, children: [stale, stale]))
            #expect(session.workingAgents == 2)
        }
    }
}
