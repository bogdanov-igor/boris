import AppKit
import BorisCore
import Carbon.HIToolbox
import Foundation
import Testing
@testable import Boris

/// Counts instead of holding anything: no real power setting is touched here.
@MainActor
private final class FakeBlocker: SleepBlocker {
    var held: Set<UInt32> = []
    var calls = 0
    var refuses = false

    func hold(reason: String) -> UInt32? {
        calls += 1
        guard !refuses else { return nil }
        held.insert(UInt32(calls))
        return UInt32(calls)
    }

    func release(_ id: UInt32) {
        held.remove(id)
    }
}

@MainActor
@Suite("Запрет сна")
struct PowerGuardTests {
    @Test("Запрет держится, пока он нужен, берётся один раз и снимается")
    func holdsOnlyWhileNeeded() {
        let blocker = FakeBlocker()
        let guardian = PowerGuard(blocker: blocker)
        guardian.update(shouldHold: false)
        #expect(blocker.calls == 0)
        guardian.update(shouldHold: true)
        guardian.update(shouldHold: true)
        #expect(blocker.calls == 1)
        #expect(guardian.isHolding)
        guardian.update(shouldHold: false)
        #expect(blocker.held.isEmpty)
        #expect(!guardian.isHolding)
        guardian.update(shouldHold: true)
        #expect(blocker.held.count == 1)
    }

    @Test("Отказ системы не считается запретом, и попытка повторяется")
    func refusalIsRetried() {
        let blocker = FakeBlocker()
        blocker.refuses = true
        let guardian = PowerGuard(blocker: blocker)
        guardian.update(shouldHold: true)
        #expect(!guardian.isHolding)
        blocker.refuses = false
        guardian.update(shouldHold: true)
        #expect(guardian.isHolding)
    }

    private func session(_ state: WorkState) -> WorkModel {
        let id = "s"
        return WorkModel(projects: [WorkProject(path: "/x", sessions: [WorkSession(id: id, environment: .terminal, cwd: "/x", state: state, root: WorkNode(id: id, kind: .main, state: state))])])
    }

    @Test("По умолчанию выключено, а включённое действует только пока идёт работа")
    func rule() {
        let settings = AppSettings(defaults: nil)
        #expect(!settings.keepAwake)
        let model = AppModel(settings: settings, store: nil, live: false)
        model.showForSnapshot(work: session(.running), world: WorldSnapshot(takenAt: Date()), today: TokenUsage(), mood: .sleeping)
        #expect(!model.shouldKeepAwake, "настройка выключена")
        settings.keepAwake = true
        #expect(model.shouldKeepAwake)
        model.showForSnapshot(work: session(.finished), world: WorldSnapshot(takenAt: Date()), today: TokenUsage(), mood: .sleeping)
        #expect(!model.shouldKeepAwake, "работа закончилась")
    }
}

@MainActor
@Suite("Глобальная клавиша")
struct HotKeyTests {
    private let rare = HotKeyCombo(keyCode: UInt32(kVK_F15), carbonModifiers: UInt32(cmdKey | optionKey | controlKey | shiftKey))

    @Test("По умолчанию ⌥⌘O")
    func standard() {
        #expect(HotKeyCombo.standard.label == "⌥⌘O")
    }

    @Test("Клавиша регистрируется без разрешений и не занята, пока её никто не держит")
    func registers() throws {
        #expect(!HotKeyController.isTaken(rare))
        let key = HotKeyController(id: 90)
        try key.register(rare) {}
        key.unregister()
        #expect(!HotKeyController.isTaken(rare), "снятая клавиша свободна")
    }

    @Test("Занятое сочетание не молчит, а настройки могут об этом сказать")
    func taken() throws {
        let first = HotKeyController(id: 91)
        try first.register(rare) {}
        defer { first.unregister() }
        #expect(HotKeyController.isTaken(rare))
        let second = HotKeyController(id: 92)
        #expect(throws: HotKeyController.Failure.self) { try second.register(rare) {} }
    }

    private func shortcut(code: Int, modifiers: Int, enabled: Bool = true) -> [String: Any] {
        [kHISymbolicHotKeyCode as String: code, kHISymbolicHotKeyModifiers as String: modifiers, kHISymbolicHotKeyEnabled as String: enabled]
    }

    @Test("Системное сочетание считается занятым, выключенное нет")
    func systemShortcuts() {
        let combo = HotKeyCombo(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(cmdKey))
        #expect(HotKeyController.matches(combo, shortcuts: [shortcut(code: kVK_Space, modifiers: cmdKey)]))
        #expect(HotKeyController.matches(combo, shortcuts: [shortcut(code: kVK_Space, modifiers: cmdKey | 0x20000)]), "лишние биты системы не мешают узнать сочетание")
        #expect(!HotKeyController.matches(combo, shortcuts: [shortcut(code: kVK_Space, modifiers: cmdKey, enabled: false)]))
        #expect(!HotKeyController.matches(combo, shortcuts: [shortcut(code: kVK_Space, modifiers: controlKey)]))
        #expect(!HotKeyController.matches(combo, shortcuts: [shortcut(code: kVK_Return, modifiers: cmdKey)]))
    }

    private func event(_ flags: NSEvent.ModifierFlags, code: UInt16 = UInt16(kVK_ANSI_O)) -> NSEvent? {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, characters: "o", charactersIgnoringModifiers: "o", isARepeat: false, keyCode: code)
    }

    @Test("Выбрать можно только сочетание с модификатором: иначе оно съест набор текста")
    func choosing() throws {
        #expect(try HotKeyCombo(event: #require(event([.option, .command]))) == .standard)
        #expect(try HotKeyCombo(event: #require(event([]))) == nil)
        #expect(try HotKeyCombo(event: #require(event([.shift]))) == nil)
    }
}
