import AppKit
import BorisCharacter
import BorisCore
import BorisData
import Foundation
import Testing
@testable import Boris

/// The walrus's hidden things as the app plays them, on a made-up clock and made-up keys. No window is shown and no key is sent anywhere.
@MainActor
@Suite("Пасхалки моржа", .serialized)
struct WalrusEggTests {
    private let t = Date(timeIntervalSince1970: 1_800_000_000)

    private func model() -> AppModel {
        AppModel(settings: AppSettings(defaults: nil), store: nil, live: false)
    }

    private func type(_ keys: [PlayKey], on stage: WalrusStage, pose: PoseName = .watch) {
        for key in keys { stage.key(key, pose: pose, now: t) }
    }

    private func letters(_ word: String) -> [PlayKey] {
        word.map { .character(String($0)) }
    }

    @Test("Имя в главном окне: подмигивает и отзывается, а имя с пробелом внутри уже не имя")
    func name() {
        let stage = WalrusStage()
        type(letters("bo ris"), on: stage)
        #expect(stage.line == nil)
        type(letters("борис"), on: stage)
        #expect(stage.line?.text == WalrusLines.trick(.name))
        #expect(stage.play.current(now: t.addingTimeInterval(0.5), restricted: false)?.act == .wink)
    }

    @Test("Код Konami: минута в пиксельном наряде и отказ сдаваться")
    func konami() {
        let stage = WalrusStage()
        type([.up, .up, .down, .down, .left, .right, .left, .right, .character("B"), .character("A")], on: stage)
        #expect(stage.costume == .pixel)
        #expect(stage.line?.text == WalrusLines.trick(.konami))
    }

    @Test("Когда он зовёт человека, фокусы молчат")
    func restricted() {
        let stage = WalrusStage()
        type(letters("boris"), on: stage, pose: .wait)
        type([.up, .up, .down, .down, .left, .right, .left, .right, .character("b"), .character("a")], on: stage, pose: .alarm)
        #expect(stage.line == nil)
        #expect(stage.costume == nil)
    }

    @Test("Клавиши: стрелки и буквы, но не сочетания и не набор в поле")
    func keys() {
        #expect(WalrusKeyWatch.playKey(keyCode: 126, characters: "\u{F700}", modifiers: [.numericPad, .function]) == .up)
        #expect(WalrusKeyWatch.playKey(keyCode: 125, characters: "\u{F701}", modifiers: [.numericPad, .function]) == .down)
        #expect(WalrusKeyWatch.playKey(keyCode: 123, characters: "\u{F702}", modifiers: []) == .left)
        #expect(WalrusKeyWatch.playKey(keyCode: 124, characters: "\u{F703}", modifiers: []) == .right)
        #expect(WalrusKeyWatch.playKey(keyCode: 11, characters: "B", modifiers: [.shift]) == .character("B"))
        #expect(WalrusKeyWatch.playKey(keyCode: 11, characters: "и", modifiers: []) == .character("и"))
        #expect(WalrusKeyWatch.playKey(keyCode: 11, characters: "b", modifiers: [.command]) == nil)
        #expect(WalrusKeyWatch.playKey(keyCode: 126, characters: "\u{F700}", modifiers: [.option]) == nil)
        #expect(WalrusKeyWatch.playKey(keyCode: 18, characters: "1", modifiers: []) == .character("1"))
        #expect(WalrusKeyWatch.playKey(keyCode: 36, characters: "\r", modifiers: []) == nil)
        #expect(WalrusKeyWatch.playKey(keyCode: 53, characters: "\u{1B}", modifiers: []) == nil)
        #expect(WalrusKeyWatch.playKey(keyCode: 122, characters: "\u{F704}", modifiers: [.function]) == nil)
        #expect(!WalrusKeyWatch.listens(to: NSTextView()))
        #expect(WalrusKeyWatch.listens(to: NSView()))
        #expect(WalrusKeyWatch.listens(to: nil))
    }

    @Test("30 ноября первый клик дня приносит реплику ко дню рождения, следующий уже нет")
    func birthday() throws {
        let model = model()
        let day = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 30, hour: 12)))
        _ = model.pokeWalrus(now: day)
        #expect(model.walrus.line?.text == WalrusLines.surprise(.birthday))
        #expect(!model.eggs.birthdayDue(now: day))
        _ = model.pokeWalrus(now: day.addingTimeInterval(5))
        #expect(model.walrus.line?.text != WalrusLines.surprise(.birthday))
    }

    private func nightScan(at hour: Int, minute: Int = 0) throws -> WorkEngine.Output {
        let at = try #require(Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()))
        let session = WorkSession(id: "s1", state: .running, root: WorkNode(id: "s1", kind: .main, state: .running))
        return WorkEngine.Output(at: at, model: WorkModel(projects: [WorkProject(path: "/x", sessions: [session])]), world: WorldSnapshot(takenAt: at))
    }

    @Test("Ночью при идущей работе одна реплика о ночной смене, и та не повторяется")
    func nightShift() throws {
        let model = model()
        model.apply(try nightScan(at: 2))
        #expect(model.walrus.line?.text == WalrusLines.surprise(.nightShift))
        let night = try nightScan(at: 3)
        #expect(model.eggs.due(now: night.at, working: true, tokensToday: 0, weekSpent: false) == nil)
    }

    @Test("В тишине сюрпризы не приходят")
    func quiet() throws {
        let model = model()
        let scan = try nightScan(at: 2)
        model.startQuiet(for: 2 * 86_400)
        model.apply(scan)
        #expect(model.walrus.line == nil)
        #expect(model.eggs.due(now: scan.at, working: true, tokensToday: 0, weekSpent: false) == .nightShift)
        model.stopQuiet()
    }

    @Test("«Очевидно»: первая реплика сразу, остальные следом; «колдун» надевает ведьминскую шляпу")
    func scenes() {
        let stage = WalrusStage()
        type(letters("очевидно"), on: stage)
        #expect(stage.line?.text == WalrusLines.scene(.obviously).first?.text)
        let wizard = WalrusStage()
        type(letters("wizard"), on: wizard)
        #expect(wizard.costume == .witch)
        #expect(wizard.line?.text == WalrusLines.scene(.wizard).first?.text)
    }

    @Test("Своё слово: картинка человека на месте моржа и его первая реплика")
    func secretWord() {
        let stage = WalrusStage()
        let picture = URL(fileURLWithPath: "/x/face.png")
        let secret = SecretWord(word: "гоблин", lines: ["Первая.", "Вторая."], picture: picture)
        var last: KeyTrick?
        for key in letters("гоблин") { last = stage.key(key, pose: .watch, secrets: [secret], now: t) }
        #expect(last == .secret("гоблин"))
        #expect(stage.picture == picture)
        #expect(stage.line?.text == "Первая.")
    }

    @Test("В проверке папка секретных слов не читается")
    func checkReadsNoSecrets() {
        #expect(model().secretWords.current().isEmpty)
    }

    @Test("Реплики идут стопкой: новая под старой, одинаковые слова подряд остаются двумя репликами, больше трёх не бывает")
    func linesStack() {
        let stage = WalrusStage()
        var second = 0.0
        func say(_ keys: [PlayKey]) {
            second += 1
            for key in keys { stage.key(key, pose: .watch, now: t.addingTimeInterval(second)) }
        }
        say(letters("boris"))
        say(letters("угу"))
        #expect(stage.lines.map(\.line.text) == [WalrusLines.trick(.name), WalrusLines.trick(.hoot)])
        say(letters("угу"))
        #expect(stage.lines.count == 3, "то же «Кхм.» ещё раз это новая реплика")
        say([.up, .up, .down, .down, .left, .right, .left, .right, .character("b"), .character("a")])
        #expect(stage.lines.count == WalrusStage.linesAtOnce)
        #expect(stage.lines.last?.line.text == WalrusLines.trick(.konami))
        #expect(stage.lines.first?.line.text == WalrusLines.trick(.hoot), "самая старая ушла раньше времени")
    }
}
