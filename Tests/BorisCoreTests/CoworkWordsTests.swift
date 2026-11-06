import Foundation
import Testing
@testable import BorisCore

@Suite("Cowork: слова на экранах")
struct CoworkWordsTests {
    private func session(title: String? = nil) -> WorkSession {
        WorkSession(id: "abcdefgh-1234", environment: .cowork, cwd: "/sessions/made-up-name", title: title, state: .running, root: WorkNode(id: "s", kind: .main))
    }

    @Test("Придуманная папка виртуальной машины не становится именем")
    func noMadeUpName() {
        #expect(session().displayName == "Cowork task")
        #expect(!session().nameIsFolder)
        #expect(session().workingFolder == nil)
        #expect(session(title: "Отчёт").displayName == "Отчёт")
    }

    @Test("Обычная сессия по-прежнему называется по папке")
    func others() {
        let plain = WorkSession(id: "abcdefgh-1234", environment: .terminal, cwd: "/x/shop", state: .running, root: WorkNode(id: "s", kind: .main))
        #expect(plain.displayName == "shop")
        #expect(plain.nameIsFolder)
        #expect(plain.workingFolder == "/x/shop")
    }

    @Test("Имя проекта для событий у Cowork пустое, у запуска тоже")
    func noProjectInEvents() {
        #expect(SessionInfo(sessionId: "s", pid: 0, cwd: "/sessions/made-up-name", entrypoint: "local-agent").projectName == nil)
        #expect(SessionInfo(sessionId: "s", pid: 1, cwd: "/x/shop", entrypoint: "cli").projectName == "shop")
        var run = RunState(runId: "r", sessionId: "s", name: "n", cwd: "/sessions/made-up-name", status: .running, lastWrite: t0)
        run.entrypoint = "local-agent"
        #expect(run.projectName == nil)
    }

    @Test("В потерях придуманная папка Cowork не считается проектом")
    func noProjectInLosses() {
        #expect(LossEntry(id: "l", at: t0, kind: .crash, sessionId: "s", cwd: "/sessions/made-up-name", entrypoint: "local-agent").project == nil)
        #expect(LossEntry(id: "l", at: t0, kind: .crash, sessionId: "s", cwd: "/x/shop", entrypoint: "cli").project == "shop")
    }

    @Test("Фильтр «Активность» по проекту не путает Cowork с папкой")
    func activityFilter() {
        let step = ActivityStep(id: "t", tool: "Read", kind: .read, input: ToolInput(), state: .running)
        let entry = FeedEntry(sessionId: "s", agentId: nil, item: .step(step))
        #expect(ActivityQuery(project: "").matches(entry, session: session()))
        #expect(!ActivityQuery(project: "/sessions/made-up-name").matches(entry, session: session()))
    }
}
