#if DEBUG
import BorisCore
import BorisData
import Foundation

/// Made-up machines for looking at screens. Nothing here comes from a real one.
@MainActor
enum RemoteDevData {
    static let lostSession = "remote-lost"
    private static let workingSession = "remote-working"

    private static func names(_ data: DevData) -> (String, String, String) {
        guard data == .long else { return ("build-server", "gpu-box", "staging") }
        return ("a-build-machine-with-a-very-long-name.corp.example.internal", "gpu-box-in-the-other-data-centre-number-seventeen", "deploy@staging-environment-for-the-whole-team.example.org")
    }

    static func fillSettings(_ model: AppModel, data: DevData, preview: Bool) {
        guard data != .empty else { return }
        let (first, second, third) = names(data)
        var working = RemoteHub.Row(machine: RemoteMachine(name: first, id: "m1", hooksWanted: true))
        working.state = .up(since: Date().addingTimeInterval(-3600))
        working.vitals = RemoteVitals(socket: true, claudeFound: true, hooks: .installed)
        var lost = RemoteHub.Row(machine: RemoteMachine(name: second, id: "m2", hooksWanted: true))
        lost.state = .down(.dropped)
        var noKey = RemoteHub.Row(machine: RemoteMachine(name: third, id: "m3"))
        noKey.state = .down(.refused)
        var noHooks = RemoteHub.Row(machine: RemoteMachine(name: data == .long ? "another-machine-where-the-hooks-have-not-been-connected-yet" : "lab", id: "m4"))
        noHooks.state = .up(since: Date())
        noHooks.vitals = RemoteVitals(socket: true, claudeFound: true, hooks: .notInstalled)
        if preview {
            noHooks.preview = RemoteHookResult(ok: true, lines: [
                "+   \"hooks\": {",
                "+     \"PermissionRequest\": [",
                "+       { \"hooks\": [ { \"command\": \"[ -x '/home/me/.boris/boris-hook' ] && exec '/home/me/.boris/boris-hook' --permission 600 || exit 0\", \"timeout\": 605, \"type\": \"command\" } ] }",
                "+     ],",
                "+     \"PreToolUse\": [ … ],",
                "+   }",
            ], reformats: true)
        }
        var noSocket = RemoteHub.Row(machine: RemoteMachine(name: "old-sshd", id: "m5"))
        noSocket.state = .up(since: Date())
        noSocket.vitals = RemoteVitals(socket: false, claudeFound: false, hooks: .disabledByPolicy)
        model.remote.showForSnapshot(rows: [working, lost, noKey, noHooks, noSocket], leftBehind: data == .long ? "yet-another-machine-that-was-removed-while-it-was-out-of-reach.example.org" : nil)
    }

    static func fillWork(_ model: AppModel, data: DevData) {
        guard data != .empty else { return }
        let now = Date()
        let (first, second, _) = names(data)
        let long = data == .long
        let lost = WorkSession(
            id: lostSession,
            environment: .remote(host: first),
            cwd: long ? "/srv/projects/deploy-tools-for-the-whole-company-with-a-long-folder-name" : "/srv/deploy-tools",
            state: .unreachable,
            startedAt: now.addingTimeInterval(-2400),
            lastActivity: now.addingTimeInterval(-300),
            root: WorkNode(id: lostSession, kind: .main, state: .unreachable, model: "claude-sonnet-5-5")
        )
        var working = WorkSession(
            id: workingSession,
            environment: .remote(host: second),
            cwd: "/home/me/training",
            state: .running,
            startedAt: now.addingTimeInterval(-600),
            lastActivity: now,
            root: WorkNode(id: workingSession, kind: .main, state: .running, step: StepBrief(kind: .shell, tool: "Bash"), model: "claude-opus-5-5", children: [
                WorkNode(id: "agent-remote-1", kind: .subagent, parentId: workingSession, state: .running, step: StepBrief(kind: .read, tool: "Read")),
            ])
        )
        working.mainAgentTokens = TokenUsage(input: 40_000, output: 8_000)
        var projects = model.work.projects
        projects.insert(WorkProject(path: lost.cwd, sessions: [lost]), at: 0)
        projects.append(WorkProject(path: working.cwd, sessions: [working]))
        var work = model.work
        work.projects = projects
        model.showForSnapshot(work: work, world: model.world, today: model.today, mood: model.mood)
        let rows = [
            RemoteEvent(id: 1, at: now.addingTimeInterval(-2400), kind: .started),
            RemoteEvent(id: 2, at: now.addingTimeInterval(-2300), kind: .tool("Read")),
            RemoteEvent(id: 3, at: now.addingTimeInterval(-2200), kind: .agentStarted, agent: "agent-remote-1"),
            RemoteEvent(id: 4, at: now.addingTimeInterval(-1500), kind: .tool("Bash")),
            RemoteEvent(id: 5, at: now.addingTimeInterval(-1200), kind: .waiting(tool: "Bash")),
            RemoteEvent(id: 6, at: now.addingTimeInterval(-1190), kind: .answered),
            RemoteEvent(id: 7, at: now.addingTimeInterval(-1100), kind: .agentStopped, agent: "agent-remote-1"),
            RemoteEvent(id: 8, at: now.addingTimeInterval(-1000), kind: .tool("Edit")),
            RemoteEvent(id: 9, at: now.addingTimeInterval(-300), kind: .turnEnded),
        ]
        model.remote.showForSnapshot(events: rows, session: lostSession, host: first)
        let today = UsageModel.dayKey(now)
        let records = [
            TokenRecord(sessionId: lostSession, cwd: lost.cwd, day: today, model: "claude-sonnet-5-5", usage: TokenUsage(input: 210_000, output: 41_000, cacheRead: 900_000), host: first),
            TokenRecord(sessionId: workingSession, cwd: working.cwd, day: today, model: "claude-opus-5-5", usage: TokenUsage(input: 40_000, output: 8_000), host: second),
        ]
        let all = model.usage.records + records
        model.usage.showForSnapshot(book: TokenBook(records: all, now: now), records: all)
    }
}
#endif
