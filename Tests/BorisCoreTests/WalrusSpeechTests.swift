import Foundation
import Testing
@testable import BorisCore

private func book(_ cue: WalrusCue) -> (String?) -> [String] {
    { project in
        project.map { ["\(cue.rawValue) in \($0)"] } ?? ["\(cue.rawValue)", "\(cue.rawValue) again"]
    }
}

private func first(_ count: Int) -> Int { 0 }

@Suite("walrus-lines")
struct WalrusSpeechTests {
    private func hear(_ speech: inout WalrusSpeech, _ cue: WalrusCue, project: String? = nil, at seconds: TimeInterval) {
        speech.hear(cue, project: project, now: at(seconds), lines: book(cue), pick: first)
    }

    @Test("Сбой: реплика с названием проекта") func failureNamesProject() {
        var speech = WalrusSpeech()
        hear(&speech, .failure, project: "shop-api", at: 0)
        #expect(speech.line(now: at(0))?.text == "failure in shop-api")
        #expect(speech.line(now: at(0))?.count == 1)
    }

    @Test("Серия событий одного типа: одна реплика со счётчиком") func series() {
        var speech = WalrusSpeech()
        for index in 0..<12 { hear(&speech, .failure, project: "shop-api", at: TimeInterval(index)) }
        let line = speech.line(now: at(11))
        #expect(line?.text == "failure in shop-api")
        #expect(line?.count == 12)
    }

    @Test("Пока серия идёт, реплика не исчезает и не меняется") func seriesKeepsShowing() {
        var speech = WalrusSpeech()
        hear(&speech, .finish, at: 0)
        hear(&speech, .finish, at: WalrusSpeech.shownFor + 1)
        #expect(speech.line(now: at(WalrusSpeech.shownFor + 2))?.count == 2)
        #expect(speech.line(now: at(WalrusSpeech.shownFor + 2))?.text == "finish")
    }

    @Test("Серия по разным проектам не называет один из них") func seriesOverProjects() {
        var speech = WalrusSpeech()
        hear(&speech, .failure, project: "shop-api", at: 0)
        hear(&speech, .failure, project: "landing", at: 1)
        let line = speech.line(now: at(1))
        #expect(line?.text == "failure")
        #expect(line?.count == 2)
    }

    @Test("Реплика исчезает сама") func lineEnds() {
        var speech = WalrusSpeech()
        hear(&speech, .finish, at: 0)
        #expect(speech.line(now: at(WalrusSpeech.shownFor - 0.1)) != nil)
        #expect(speech.line(now: at(WalrusSpeech.shownFor)) == nil)
    }

    @Test("Другое событие сразу после реплики ждёт своей очереди") func quietGap() {
        var speech = WalrusSpeech()
        hear(&speech, .finish, at: 0)
        hear(&speech, .request, at: 5)
        #expect(speech.line(now: at(5))?.cue == .finish)
        hear(&speech, .limit, at: WalrusSpeech.quietGap + 1)
        #expect(speech.line(now: at(WalrusSpeech.quietGap + 1))?.cue == .limit)
    }

    @Test("Сбой не ждёт очереди") func failureBreaksThrough() {
        var speech = WalrusSpeech()
        hear(&speech, .finish, at: 0)
        hear(&speech, .failure, at: 1)
        #expect(speech.line(now: at(1))?.cue == .failure)
    }

    @Test("Сто событий за минуту: не больше двух реплик") func notAnnoying() {
        var speech = WalrusSpeech()
        var said: [String] = []
        for index in 0..<100 {
            let seconds = TimeInterval(index) * 0.6
            let cue = [WalrusCue.finish, .request, .limit][index % 3]
            speech.hear(cue, project: nil, now: at(seconds), lines: { _ in ["\(cue.rawValue)"] }, pick: first)
            if let line = speech.line(now: at(seconds)), said.last != line.text { said.append(line.text) }
        }
        #expect(said.count <= 3)
    }

    @Test("После паузы то же событие говорит снова") func afterSeries() {
        var speech = WalrusSpeech()
        hear(&speech, .finish, at: 0)
        hear(&speech, .finish, at: WalrusSpeech.quietGap + 1)
        let line = speech.line(now: at(WalrusSpeech.quietGap + 1))
        #expect(line?.count == 1)
    }

    @Test("Одна и та же реплика не повторяется подряд") func noRepeat() {
        var speech = WalrusSpeech()
        hear(&speech, .finish, at: 0)
        #expect(speech.line(now: at(0))?.text == "finish")
        hear(&speech, .finish, at: WalrusSpeech.quietGap + 1)
        #expect(speech.line(now: at(WalrusSpeech.quietGap + 1))?.text == "finish again")
    }

    @Test("Нажатие отвечает всегда, но не мелькает при частых нажатиях") func poke() {
        var speech = WalrusSpeech()
        hear(&speech, .finish, at: 0)
        speech.poked(now: at(1), lines: ["раз", "два"], pick: first)
        #expect(speech.line(now: at(1))?.text == "раз")
        speech.poked(now: at(1.5), lines: ["раз", "два"], pick: first)
        #expect(speech.line(now: at(1.5))?.text == "раз")
        speech.poked(now: at(3), lines: ["раз", "два"], pick: first)
        #expect(speech.line(now: at(3))?.text == "два")
    }

    @Test("Реплика реакции не ждёт") func fixedLine() {
        var speech = WalrusSpeech()
        speech.poked(now: at(0), lines: ["раз"], pick: first)
        speech.poked(now: at(0.5), fixed: "Кхм.", lines: ["раз"], pick: first)
        #expect(speech.line(now: at(0.5))?.text == "Кхм.")
    }

    @Test("Сказать нечего: молчит") func nothingToSay() {
        var speech = WalrusSpeech()
        speech.hear(.finish, project: nil, now: at(0), lines: { _ in [] })
        #expect(speech.line(now: at(0)) == nil)
    }

    @Test("Какие события получают реплику", arguments: [
        (EventKind.waiting, WalrusCue?.some(.request)),
        (.completed, .finish),
        (.sessionFinished, .finish),
        (.failed, .failure),
        (.allAgentsFailed, .failure),
        (.interrupted, .failure),
        (.sessionError, .failure),
        (.completedWithErrors, .failure),
        (.limitNear, .limit),
        (.limitReached, .limit),
        (.stopped, nil),
        (.silent, nil),
    ] as [(EventKind, WalrusCue?)])
    func cues(kind: EventKind, cue: WalrusCue?) {
        #expect(WalrusCue(event: kind) == cue)
    }
}

@Suite("walrus-lines")
struct WalrusBookTests {
    @Test("На каждое событие есть реплики, и они разные", arguments: WalrusCue.allCases)
    func everyCue(cue: WalrusCue) {
        for project in [nil, "shop-api"] as [String?] {
            let lines = WalrusLines.builtIn(cue, project: project)
            #expect(lines.count >= 3)
            #expect(Set(lines).count == lines.count)
            #expect(lines.allSatisfy { !$0.isEmpty && !$0.contains("%") })
        }
    }

    @Test("Сбой всегда называет проект, если он известен") func failureAlwaysNames() {
        #expect(WalrusLines.builtIn(.failure, project: "shop-api").allSatisfy { $0.contains("shop-api") })
    }

    @Test("Строка под моржом для каждого настроения", arguments: [Mood.alarm, .broken, .waiting, .tired, .alert, .happy, .hmm, .working(agents: 3), .working(agents: 1), .working(agents: 0), .sleeping])
    func standing(mood: Mood) {
        #expect(!WalrusLines.standing(mood: mood, waiting: 2).isEmpty)
    }

    @Test("Строка под моржом говорит точные числа") func standingNumbers() {
        #expect(WalrusLines.standing(mood: .waiting, waiting: 2).contains("2"))
        #expect(WalrusLines.standing(mood: .working(agents: 7), waiting: 0).contains("7"))
    }

    @Test("Выбранный язык: реплики набора, а без набора свои") func packOrBuiltIn() {
        let pack = WalrusPack(
            id: "x", folder: URL(fileURLWithPath: "/x"), name: "x", author: nil, baseLanguage: "en", framesPerSecond: 8,
            baseFrames: [], poses: [:], baseIcon: URL(fileURLWithPath: "/x/i.png"), icons: [:],
            lines: ["en": [.poke: ["Base line."]], "ru": [.poke: ["Русская реплика."]]], sounds: []
        )
        #expect(WalrusLines.lines(.poke, project: nil, pack: pack, language: .ru) == ["Русская реплика."])
        #expect(WalrusLines.lines(.poke, project: nil, pack: pack, language: .en) == ["Base line."])
        #expect(WalrusLines.lines(.poke, project: nil, pack: nil, language: .ru) == WalrusLines.builtIn(.poke, project: nil))
    }

    /// The text the person approves: it must keep the voice and the rules, so a slip is caught before they read it.
    @Test("Тексты реплик в рамках правил") func lineRules() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Resources/Strings/walrus-lines.json"))
        let lines = try JSONDecoder().decode([String: String].self, from: data)
        #expect(lines.count >= 40)
        for (english, russian) in lines {
            #expect(!english.contains("—") && !russian.contains("—"), "тире: \(english)")
            #expect(!english.contains("–") && !russian.contains("–"), "тире: \(english)")
            #expect(english.count <= 100 && russian.count <= 100, "слишком длинно: \(english)")
            // The reader is «вы», and the walrus speaks for himself.
            let words = russian.lowercased().split { !$0.isLetter }.map(String.init)
            #expect(Set(words).isDisjoint(with: ["ты", "тебя", "тебе", "тобой", "твой", "твоя", "твоё", "твои", "иди", "нажимай"]), "на ты: \(russian)")
            #expect(english.components(separatedBy: "%@").count == russian.components(separatedBy: "%@").count, "проект потерян: \(english)")
        }
    }
}
