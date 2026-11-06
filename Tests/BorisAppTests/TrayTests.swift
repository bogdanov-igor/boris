import AppKit
import BorisCore
import Foundation
import Testing
@testable import Boris

@MainActor
@Suite("Значок в трее")
struct TrayTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func titles(_ entries: [TrayMenu.Entry]) -> [String] {
        entries.map { entry in
            switch entry {
            case .action(let title, _, _), .state(let title), .choices(let title, _): return title
            case .separator: return "-"
            }
        }
    }

    @Test("Правый клик: главное окно, «не беспокоить», настройки, «О Boris», выход")
    func menu() {
        let entries = TrayMenu.entries(quiet: QuietMode(), now: now)
        #expect(titles(entries) == [L("Open Boris"), L("Do not disturb"), "-", L("Settings…"), L("About Boris"), "-", L("Quit")])
        #expect(entries.contains(.action(L("About Boris"), .about)))
        #expect(entries.contains(.action(L("Settings…"), key: ",", .settings)))
        #expect(entries.contains(.action(L("Quit"), key: "q", .quit)))
    }

    @Test("«Не беспокоить» раскрывается тремя вариантами")
    func quietChoices() throws {
        let entries = TrayMenu.entries(quiet: QuietMode(), now: now)
        guard case .choices(_, let choices)? = entries.first(where: { if case .choices = $0 { return true } else { return false } }) else {
            Issue.record("нет подменю")
            return
        }
        #expect(titles(choices) == [L("For an hour"), L("For 4 hours"), L("Until turned off")])
    }

    @Test("Включённое «не беспокоить» говорит до скольких и предлагает выключить")
    func quietOn() {
        var quiet = QuietMode()
        quiet.start(for: 3600, now: now)
        let shown = titles(TrayMenu.entries(quiet: quiet, now: now))
        #expect(shown.contains(L("Do not disturb until %@", WorkFormat.time(now.addingTimeInterval(3600)))))
        #expect(shown.contains(L("Turn off Do not disturb")))
        #expect(!shown.contains(L("Do not disturb")))
    }

    @Test("«До выключения» не называет времени")
    func quietIndefinitely() {
        var quiet = QuietMode()
        quiet.start(for: QuietMode.indefinitely, now: now)
        #expect(titles(TrayMenu.entries(quiet: quiet, now: now)).contains(L("Do not disturb is on")))
    }

    @Test("Счётчик у значка: две ждущие сессии дают «2», ни одной ничего")
    func counter() {
        #expect(StatusBarController.counter(0) == "")
        #expect(StatusBarController.counter(2) == " 2")
    }

    @Test("VoiceOver слышит, что значит значок и сколько ждут")
    func voiceOver() {
        let text = StatusBarController.description(mood: .alarm, waiting: 2)
        #expect(text.contains(L("Something broke")))
        #expect(text.contains(L("Waiting for you: %lld", 2)))
    }

    @Test("Клик открывает мини-окно, повторный закрывает", arguments: [
        // mini, icon, visible, shown
        (true, true, true, false, MiniWindowChoice.open),
        (true, true, true, true, .close),
        (true, false, false, false, .open),
        (true, true, false, false, .main),
        (true, true, false, true, .close),
        (false, true, true, false, .main),
        (false, false, false, false, .main),
    ])
    func click(mini: Bool, icon: Bool, visible: Bool, shown: Bool, expected: MiniWindowChoice) {
        #expect(MiniWindowChoice(miniOn: mini, iconOn: icon, iconVisible: visible, isShown: shown) == expected)
    }

    private let screen = NSRect(x: 0, y: 0, width: 1512, height: 982)
    private let left = NSRect(x: 0, y: 950, width: 650, height: 32)
    private let right = NSRect(x: 860, y: 950, width: 652, height: 32)

    @Test("Значок виден только там, где его не закрывает чёлка и край экрана", arguments: [
        (NSRect(x: 1000, y: 950, width: 30, height: 32), true),
        (NSRect(x: 600, y: 950, width: 30, height: 32), true),
        (NSRect(x: 700, y: 950, width: 30, height: 32), false),
        (NSRect(x: 640, y: 950, width: 30, height: 32), false),
        (NSRect(x: 0, y: 2000, width: 30, height: 32), false),
    ])
    func notch(icon: NSRect, visible: Bool) {
        #expect(StatusBarController.fits(icon, on: screen, left: left, right: right) == visible)
    }

    @Test("На экране без чёлки мешает только край")
    func noNotch() {
        #expect(StatusBarController.fits(NSRect(x: 700, y: 950, width: 30, height: 32), on: screen, left: nil, right: nil))
    }

    @Test("Пропажу значка замечают не сразу, и только если значок нужен")
    func watch() {
        var watch = IconWatch()
        let afterHalfAMinute = watch.note(visible: false, wanted: true, seconds: 30)
        let afterAMinute = watch.note(visible: false, wanted: true, seconds: 30)
        let back = watch.note(visible: true, wanted: true, seconds: 30)
        let goneAgain = watch.note(visible: false, wanted: true, seconds: 30)
        #expect(!afterHalfAMinute)
        #expect(afterAMinute)
        #expect(!back, "вернулся: счёт сначала")
        #expect(!goneAgain)
        var off = IconWatch()
        let turnedOff = off.note(visible: false, wanted: false, seconds: 600)
        #expect(!turnedOff, "выключенный значок не пропал")
    }

    @Test("Сообщение о значке приходит один раз: окно не лезет вперёд при каждой проверке")
    func noticeOnce() {
        let model = AppModel(settings: AppSettings(defaults: nil), store: nil, live: false)
        #expect(model.noteIconHidden())
        #expect(model.showIconNotice)
        #expect(!model.noteIconHidden())
        model.dismissIconNotice()
        #expect(!model.showIconNotice)
        #expect(!model.noteIconHidden(), "прочитанное больше не возвращается")
        #expect(!model.showIconNotice)
    }
}
