import Foundation
import Testing
@testable import BorisCore

@Suite("Обычный чат: готовность ответа")
struct ChatReadinessTests {
    private func tracker(_ looks: [ChatLook]) -> (tracker: ChatTracker, fired: [Bool]) {
        var tracker = ChatTracker()
        let fired = looks.enumerated().map { tracker.note($1, now: at(Double($0) * 3)) }
        return (tracker, fired)
    }

    @Test("Ответ готов, когда кнопка остановки исчезла и не вернулась, и об этом сказано один раз")
    func ready() throws {
        let result = tracker([.notAnswering, .answering, .answering, .notAnswering, .notAnswering, .notAnswering])
        #expect(result.fired == [false, false, false, false, true, false])
        #expect(result.tracker.answeringSince == nil)
        #expect(result.tracker.readyAt == at(12))
        let session = try #require(result.tracker.session)
        #expect(session.environment == .chat)
        #expect(session.state == .finished)
    }

    @Test("Кнопка, мигнувшая на один взгляд, не даёт ложного «готово»")
    func flicker() {
        let result = tracker([.answering, .notAnswering, .answering, .notAnswering, .answering])
        #expect(!result.fired.contains(true))
        #expect(result.tracker.session?.state == .running)
    }

    @Test("Если ответа не было, готовить нечего")
    func nothingToTell() {
        let result = tracker([.notAnswering, .notAnswering, .notAnswering])
        #expect(!result.fired.contains(true))
        #expect(result.tracker.session == nil)
        #expect(result.tracker.connection == .connected)
    }

    @Test("Пока Claude на переднем плане, человек видит всё сам")
    func inFront() {
        let result = tracker([.answering, .inFront, .notAnswering, .notAnswering])
        #expect(!result.fired.contains(true))
        #expect(result.tracker.session == nil)
    }

    @Test("Открыл Claude после готового ответа: сообщать больше не о чем")
    func seen() {
        let result = tracker([.answering, .notAnswering, .notAnswering, .inFront])
        #expect(result.fired.contains(true))
        #expect(result.tracker.session == nil)
    }

    @Test("Claude закрыли посреди ответа: это не «готово»")
    func closed() {
        let result = tracker([.answering, .appClosed, .appClosed])
        #expect(!result.fired.contains(true))
        #expect(result.tracker.session == nil)
        #expect(result.tracker.connection == .appClosed)
    }

    @Test("Окно ничего не сказало: это не «готово», а ответ какое-то время считается идущим")
    func blind() {
        var tracker = ChatTracker()
        _ = tracker.note(.answering, now: at(0))
        let shortly = tracker.note(.cannotSee, now: at(3))
        #expect(!shortly)
        #expect(tracker.connection == .cannotSee)
        #expect(tracker.session?.state == .running)
        let later = tracker.note(.cannotSee, now: at(31))
        #expect(!later)
        #expect(tracker.session == nil)
    }

    @Test("Разрешение отозвали: чат снова требует разрешения, сообщить не о чем")
    func permissionGone() {
        let result = tracker([.answering, .noPermission])
        #expect(result.tracker.connection == .needsPermission)
        #expect(result.tracker.session == nil)
    }

    @Test("Выключение возвращает к «не подключён»")
    func turnedOff() {
        var result = tracker([.answering]).tracker
        result.turnOff()
        #expect(result.connection == .notConnected)
        #expect(result.session == nil)
    }

    @Test("Кнопка остановки узнаётся по точной подписи, а другие кнопки нет", arguments: [
        ("Stop response", true), ("  stop response\n", true), ("STOP GENERATING", true), ("Остановить ответ", true),
        ("Stop", false), ("Stop response early", false), ("Copy", false), ("", false), (nil, false),
    ] as [(String?, Bool)])
    func label(label: String?, expected: Bool) {
        #expect(ChatStopButton.matches(label) == expected)
    }

    @Test("Чат без единого слова из окна: только факт, без токенов и действий")
    func sessionKnowsNothingElse() throws {
        var tracker = ChatTracker()
        _ = tracker.note(.answering, now: at(0))
        let session = try #require(tracker.session)
        #expect(session.title == nil)
        #expect(session.cwd == nil)
        #expect(session.projectPath == nil)
        #expect(session.root.tokens == nil)
        #expect(session.root.step == nil)
        #expect(session.root.children.isEmpty)
        #expect(session.displayName == "Answer in chat")
        #expect(!session.nameIsFolder)
        #expect(WorkPhrases.line(session, mode: .simple) == "Writing an answer")
        #expect(WorkPhrases.line(session, mode: .technical) == "Writing an answer")
        #expect(WorkPhrases.occupation(session, mode: .simple) == "Writing an answer")
    }

    @Test("Уведомление говорит, что ответ готов, и больше ничего")
    func banner() {
        let banner = NotificationWords.banner(ChatTracker.readyEvent(at: t0))
        #expect(banner.title == "Claude chat · answer is ready")
        #expect(banner.body.isEmpty)
        #expect(banner.route == .session(ChatTracker.sessionId))
    }

    // MARK: in the work

    private let shop = WorkSession(id: "a", cwd: "/x/shop", state: .running, root: WorkNode(id: "a", kind: .main))
    private let cowork = WorkSession(id: "c", environment: .cowork, state: .running, root: WorkNode(id: "c", kind: .main))

    private var chat: WorkSession {
        var tracker = ChatTracker()
        _ = tracker.note(.answering, now: t0)
        return tracker.session ?? ChatTracker.seenSession
    }

    @Test("Чат идёт вместе с сессиями без проекта и заменяет прежний")
    func joins() {
        let work = WorkModel(projects: [WorkProject(path: "/x/shop", sessions: [shop]), WorkProject(path: nil, sessions: [cowork])])
        let once = work.withChat(chat)
        #expect(once.sessions.map(\.id) == ["a", "c", ChatTracker.sessionId])
        #expect(once.projects.count == 2)
        #expect(once.withChat(chat) == once)
        #expect(once.withChat(nil) == work)
    }

    @Test("Если сессий без проекта нет, появляется и исчезает своя группа")
    func ownGroup() {
        let work = WorkModel(projects: [WorkProject(path: "/x/shop", sessions: [shop])])
        let with = work.withChat(chat)
        #expect(with.projects.map(\.path) == ["/x/shop", nil])
        #expect(with.withChat(nil) == work)
        #expect(work.withChat(nil) == work)
    }

    @Test("Все три продукта видны каждый со своей средой")
    func threeProducts() {
        let code = WorkSession(id: "a", environment: .terminal, cwd: "/x/shop", state: .running, root: WorkNode(id: "a", kind: .main))
        let work = WorkModel(projects: [WorkProject(path: "/x/shop", sessions: [code]), WorkProject(path: nil, sessions: [cowork])]).withChat(chat)
        #expect(Set(work.sessions.compactMap { $0.environment?.product }) == [.claudeCode, .cowork, .chat])
        #expect(Set(work.sessions.map { WorkPhrases.environment($0.environment) }) == ["Terminal", "Cowork", "Claude chat"])
    }
}
