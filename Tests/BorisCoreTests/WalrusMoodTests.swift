import Foundation
import Testing
@testable import BorisCore

/// Work in the new model, made up: which pose each situation gets.
private func session(_ id: String = "s", state: WorkState = .running, nodes: [WorkNode] = []) -> WorkSession {
    WorkSession(id: id, state: state, root: WorkNode(id: id, kind: .main, state: state, children: nodes))
}

private func work(_ sessions: WorkSession...) -> WorkModel {
    WorkModel(projects: [WorkProject(path: "/x/shop-api", sessions: sessions)])
}

private func window(_ percent: Double, resets: Date? = nil, kind: UsageWindow.Kind = .fiveHour) -> UsageSnapshot {
    UsageSnapshot(windows: [UsageWindow(id: "w", kind: kind, percent: percent, resetsAt: resets)])
}

private func event(_ kind: EventKind) -> BorisEvent { BorisEvent(id: "\(kind)", kind: kind, at: t0) }

@Suite("walrus-mood")
struct WalrusMoodTests {
    private func mood(_ board: MoodBoard = MoodBoard(), _ model: WorkModel = WorkModel(), usage: UsageSnapshot? = nil, broken: Bool = false, matrix: ReactionMatrix = ReactionMatrix(), now: Date = t0) -> Mood {
        board.mood(work: model, usage: usage, limitPercent: 95, broken: broken, matrix: matrix, now: now)
    }

    /// What the default reactions do with an event, as the app applies them.
    private func board(after kinds: EventKind...) -> MoodBoard {
        var board = MoodBoard()
        for kind in kinds { board.apply(event(kind), reaction: ReactionMatrix().reaction(for: kind).mood, now: t0) }
        return board
    }

    @Test("Работы нет: спит") func nothing() {
        #expect(mood() == .sleeping)
        #expect(mood(MoodBoard(), work(session(state: .finished))) == .sleeping)
    }

    @Test("Один агент работает") func oneAgent() {
        #expect(mood(MoodBoard(), work(session())) == .working(agents: 1))
    }

    @Test("Агенты считаются по всему дереву, а workflow не агент") func agentsInTree() {
        let helpers = [WorkNode(id: "h1", kind: .subagent, state: .running), WorkNode(id: "h2", kind: .fork, state: .running)]
        let flow = WorkNode(id: "w", kind: .workflow, state: .running, children: [WorkNode(id: "a", kind: .workflowAgent, state: .running), WorkNode(id: "d", kind: .workflowAgent, state: .finished)])
        #expect(mood(MoodBoard(), work(session(nodes: helpers + [flow]), session("s2"))) == .working(agents: 5))
    }

    @Test("Работа закончена: ненадолго радуется", arguments: [EventKind.completed, .sessionFinished])
    func finished(kind: EventKind) {
        #expect(mood(board(after: kind), now: at(5)) == .happy)
        #expect(mood(board(after: kind), now: at(MoodBoard.transientDuration + 1)) == .sleeping)
    }

    @Test("Завершено не всё: ненадолго хм", arguments: [EventKind.completedWithErrors, .stopped])
    func partly(kind: EventKind) {
        #expect(mood(board(after: kind), now: at(5)) == .hmm)
        #expect(mood(board(after: kind), now: at(MoodBoard.transientDuration + 1)) == .sleeping)
    }

    @Test("Давно нет новостей: настороже, даже когда другие работают") func silent() {
        #expect(mood(MoodBoard(), work(session(state: .silent, nodes: [WorkNode(id: "w", kind: .workflow, state: .silent)]))) == .alert)
        #expect(mood(MoodBoard(), work(session(nodes: [WorkNode(id: "w", kind: .workflow, state: .silent)]))) == .alert)
    }

    @Test("Реакция на молчание выключена: просто работает") func silentOff() {
        var matrix = ReactionMatrix()
        matrix.overrides[.silent] = Reaction(banner: true, sound: false, mood: .none)
        #expect(mood(MoodBoard(), work(session(state: .silent)), matrix: matrix) == .working(agents: 1))
    }

    @Test("Кончился лимит: устал") func limitReached() {
        #expect(mood(board(after: .limitReached)) == .tired)
    }

    @Test("Лимит близко: устал", arguments: [95.0, 99, 100])
    func limitNear(percent: Double) {
        #expect(mood(usage: window(percent)) == .tired)
    }

    @Test("До порога лимит не утомляет") func limitFar() {
        #expect(mood(usage: window(94.9)) == .sleeping)
    }

    @Test("Окно уже сбросилось: не устал") func limitReset() {
        #expect(mood(usage: window(100, resets: at(-1))) == .sleeping)
        #expect(mood(usage: window(100, resets: at(60))) == .tired)
    }

    @Test("Доплаты не считаются лимитом") func extraSpend() {
        #expect(mood(usage: window(100, kind: .extraSpend)) == .sleeping)
    }

    @Test("Реакция на лимит выключена: не устал") func limitOff() {
        var matrix = ReactionMatrix()
        matrix.overrides[.limitReached] = Reaction(banner: true, sound: false, mood: .none)
        #expect(mood(usage: window(100), matrix: matrix) == .sleeping)
    }

    @Test("Сбой: тревога, пока не откроют Boris", arguments: [EventKind.failed, .interrupted, .allAgentsFailed, .sessionError])
    func alarm(kind: EventKind) {
        var board = board(after: kind)
        #expect(mood(board, now: at(100_000)) == .alarm)
        board.acknowledge()
        #expect(mood(board, now: at(100_001)) == .sleeping)
    }

    @Test("Boris не может читать данные: сломалось") func broken() {
        #expect(mood(broken: true) == .broken)
    }

    @Test("Одна сессия ждёт, другая работает: ждёт") func waitingWins() {
        #expect(mood(MoodBoard(), work(session("a", state: .waiting), session("b"))) == .waiting)
    }

    @Test("Ожидание выключено в реакциях: работает") func waitingOff() {
        var matrix = ReactionMatrix()
        matrix.overrides[.waiting] = Reaction(banner: true, sound: false, mood: .none)
        #expect(mood(MoodBoard(), work(session("a", state: .waiting), session("b")), matrix: matrix) == .working(agents: 1))
    }

    /// The whole order from the spec, removing the winner step by step.
    @Test("Полный порядок приоритетов") func priorities() {
        let everything = work(session("a", state: .waiting), session("b", nodes: [WorkNode(id: "w", kind: .workflow, state: .silent)]))
        let alarmed = board(after: .completed, .limitReached, .failed)
        #expect(mood(alarmed, everything, usage: window(100), broken: true, now: at(1)) == .alarm)

        let noAlarm = board(after: .completed, .limitReached)
        #expect(mood(noAlarm, everything, usage: window(100), broken: true, now: at(1)) == .broken)
        #expect(mood(noAlarm, everything, usage: window(100), now: at(1)) == .waiting)

        let noWaiting = work(session("b", nodes: [WorkNode(id: "w", kind: .workflow, state: .silent)]))
        #expect(mood(noAlarm, noWaiting, usage: window(100), now: at(1)) == .tired)

        let happy = board(after: .completed)
        #expect(mood(happy, noWaiting, now: at(1)) == .alert)
        #expect(mood(happy, work(session()), now: at(1)) == .happy)
        #expect(mood(MoodBoard(), work(session()), now: at(1)) == .working(agents: 1))
        #expect(mood(MoodBoard(), WorkModel(), now: at(1)) == .sleeping)
    }

    @Test("Упал один и идёт другой: тревога") func alarmOverWork() {
        #expect(mood(board(after: .failed), work(session())) == .alarm)
    }

    @Test("Завершился один и идёт другой: радуется 10 секунд") func happyThenWork() {
        #expect(mood(board(after: .completed), work(session()), now: at(5)) == .happy)
        #expect(mood(board(after: .completed), work(session()), now: at(11)) == .working(agents: 1))
    }

    @Test("Реакция отключена: нет тревоги") func reactionOff() {
        var board = MoodBoard()
        board.apply(event(.failed), reaction: .none, now: t0)
        #expect(mood(board) == .sleeping)
    }

    @Test("Открытие Boris снимает тревогу и усталость от события") func acknowledge() {
        var board = board(after: .failed, .limitReached)
        #expect(mood(board) == .alarm)
        board.acknowledge()
        #expect(mood(board, work(session())) == .working(agents: 1))
    }

    @Test("Лимит на исходе остаётся фактом и после открытия Boris") func limitIsAFact() {
        var board = MoodBoard()
        board.acknowledge()
        #expect(mood(board, usage: window(99)) == .tired)
    }

    /// The states come from `WorkBuilder`, so what reaches the walrus is what the screens show.
    @Test("Занятая сессия без workflow не выглядит как «ничего не идёт»") func busySession() {
        let model = WorkBuilder.build(world: WorldSnapshot(takenAt: t0, sessions: [session(status: "busy")]), runs: [])
        #expect(mood(MoodBoard(), model) == .working(agents: 1))
    }

    @Test("Открытый диалог не считается ожиданием") func dialogIsNotWaiting() {
        let model = WorkBuilder.build(world: WorldSnapshot(takenAt: t0, sessions: [session(status: "waiting", waitingFor: "dialog open")]), runs: [])
        #expect(mood(MoodBoard(), model) == .working(agents: 1))
    }

    @Test("Сессия ждёт разрешения") func waitingSession() {
        let model = WorkBuilder.build(world: WorldSnapshot(takenAt: t0, sessions: [session(status: "waiting", waitingFor: "approve Bash")]), runs: [])
        #expect(mood(MoodBoard(), model) == .waiting)
    }

    @Test("Workflow замолчал: настороже, с настоящими статусами запусков") func silentRun() {
        let model = WorkBuilder.build(world: WorldSnapshot(takenAt: t0, sessions: [session(status: "busy")]), runs: [state(.silent)])
        #expect(mood(MoodBoard(), model) == .alert)
    }

    @Test("Ожидание снимается ответом, а не временем") func waitingLasts() {
        #expect(mood(MoodBoard(), work(session(state: .waiting)), now: at(100_000)) == .waiting)
    }
}

@Suite("walrus-motion")
struct WalrusMotionTests {
    @Test("В покое и невидимым таймера нет", arguments: [
        (false, true, false),  // still and seen
        (true, false, false),  // moving but hidden
        (false, false, false), // still and hidden
        (true, true, true),    // reduced motion
        (false, true, true),
    ])
    func noTimer(moves: Bool, visible: Bool, reduceMotion: Bool) {
        #expect(WalrusMotion.nextFrame(moves: moves, visible: visible, reduceMotion: reduceMotion) == nil)
    }

    @Test("Движется, только если можно и его видно") func timer() {
        #expect(WalrusMotion.nextFrame(moves: true, visible: true, reduceMotion: false) == WalrusMotion.frameInterval)
    }

    @Test("Реакция будит спящего, но не невидимого") func act() {
        #expect(WalrusMotion.nextFrame(moves: false, visible: true, reduceMotion: false, actLeft: 1) == WalrusMotion.frameInterval)
        #expect(WalrusMotion.nextFrame(moves: false, visible: false, reduceMotion: false, actLeft: 1) == nil)
        #expect(WalrusMotion.nextFrame(moves: false, visible: true, reduceMotion: false, actLeft: 0) == nil)
    }

    @Test("С уменьшением движения реакция один раз меняет картинку и один раз заканчивается") func actReduced() {
        #expect(WalrusMotion.nextFrame(moves: true, visible: true, reduceMotion: true, actLeft: 3) == 3)
    }
}
