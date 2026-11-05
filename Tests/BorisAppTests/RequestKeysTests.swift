import AppKit
import BorisCore
import BorisData
import Carbon.HIToolbox
import SwiftUI
import Testing
@testable import Boris

/// Rare combinations, so that nothing a person might press is held even for a moment.
private let rareAllow = HotKeyCombo(keyCode: UInt32(kVK_F19), carbonModifiers: UInt32(cmdKey | optionKey | controlKey | shiftKey))
private let rareDeny = HotKeyCombo(keyCode: UInt32(kVK_F18), carbonModifiers: UInt32(cmdKey | optionKey | controlKey | shiftKey))

/// Is this combination free in this process? Carbon refuses a second registration of a combination the process already holds.
@MainActor
private func isFree(_ combo: HotKeyCombo) -> Bool {
    var reference: EventHotKeyRef?
    let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, EventHotKeyID(signature: 0x5445_5354, id: 99), GetApplicationEventTarget(), 0, &reference)
    if let reference { UnregisterEventHotKey(reference) }
    return status == noErr
}

/// What Carbon delivers on a real press, without pressing anything.
@MainActor
private func press(id: UInt32) {
    var event: EventRef?
    CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0, 0, &event)
    guard let event else { return }
    defer { ReleaseEvent(event) }
    var pressed = EventHotKeyID(signature: 0x424F_5253, id: id)
    SetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &pressed)
    SendEventToEventTarget(event, GetApplicationEventTarget())
}

private func command(_ session: String = "s1", at ago: TimeInterval = 30) -> PendingPermission {
    PendingPermission(session: session, tool: "Bash", content: .command("make deploy", unsandboxed: false), project: "proj", askedAt: Date().addingTimeInterval(-ago))
}

private let oneQuestion = RequestQuestion(text: "Какую базу?", options: [.init(label: "SQLite")])

@MainActor
private func controller(keys: RequestHotKeys? = nil) -> (HookController, AppSettings) {
    let settings = AppSettings(defaults: nil)
    settings.allowKey = rareAllow
    settings.denyKey = rareDeny
    return (HookController(settings: settings, live: false, keys: keys), settings)
}

@Suite("Горячие клавиши запросов", .serialized)
@MainActor
struct RequestKeysTests {
    @Test("Клавиши заняты только пока карточка видна, а потом сочетание снова свободно")
    func heldOnlyWhileCardIsSeen() {
        let (hooks, _) = controller(keys: RequestHotKeys())
        let asked = command()
        let card = UUID()
        #expect(isFree(rareAllow), "до запроса ничего не занято")

        hooks.showRequestsForSnapshot(open: [asked], expired: [], decisions: [])
        hooks.applyKeys()
        #expect(isFree(rareAllow), "запрос есть, но карточки на экране нет")
        #expect(isFree(rareDeny))

        hooks.noteCard(card, request: asked.id, windowShows: true)
        #expect(!isFree(rareAllow), "карточка видна")
        #expect(!isFree(rareDeny))

        hooks.noteCard(card, request: asked.id, windowShows: false)
        #expect(isFree(rareAllow), "окно закрыли или перекрыли")
        #expect(isFree(rareDeny))

        hooks.noteCard(card, request: asked.id, windowShows: true)
        #expect(!isFree(rareAllow))
        hooks.noteCard(card, request: asked.id, inView: false)
        #expect(isFree(rareAllow), "карточку прокрутили за край списка")
        hooks.noteCard(card, request: asked.id, inView: true)
        #expect(!isFree(rareAllow))

        hooks.forgetCard(card)
        #expect(isFree(rareAllow), "карточка ушла с экрана")
        #expect(isFree(rareDeny))
    }

    @Test("Ответили на единственный запрос: клавиши сразу свободны")
    func freedAfterAnswer() {
        let (hooks, _) = controller(keys: RequestHotKeys())
        let asked = command()
        hooks.showRequestsForSnapshot(open: [asked], expired: [], decisions: [])
        hooks.noteCard(UUID(), request: asked.id, windowShows: true)
        #expect(!isFree(rareDeny))
        hooks.answer(asked.id, .deny(reason: ""), via: .window)
        #expect(hooks.pending.isEmpty)
        #expect(isFree(rareAllow))
        #expect(isFree(rareDeny))
    }

    @Test("Нажатие разрешает запрос именно в этой карточке, а другая клавиша приложения его не трогает")
    func pressReachesItsOwnAction() async throws {
        let keys = RequestHotKeys()
        let (hooks, _) = controller(keys: keys)
        let first = command("s1", at: 30)
        let second = command("s2", at: 10)
        hooks.showRequestsForSnapshot(open: [first, second], expired: [], decisions: [])
        hooks.noteCard(UUID(), request: first.id, windowShows: true)
        hooks.noteCard(UUID(), request: second.id, windowShows: true)
        try await Task.sleep(for: .seconds(HookController.settleTime + 0.1))

        // The mini window's key is alive next to these, and its press must not answer anything.
        let mini = HotKeyController()
        var miniPressed = 0
        try mini.register(HotKeyCombo(keyCode: UInt32(kVK_F17), carbonModifiers: rareAllow.carbonModifiers)) { miniPressed += 1 }
        defer { mini.unregister() }
        press(id: 1)
        #expect(miniPressed == 1)
        #expect(hooks.pending.count == 2, "клавиша мини-окна ничего не решает")

        press(id: 2)
        #expect(miniPressed == 1, "клавиша ответа не открывает мини-окно")
        #expect(hooks.pending == [second], "разрешён запрос в карточке, на которую указывают клавиши")
        #expect(hooks.queue.decisions.first?.outcome == .allowed)
        #expect(hooks.queue.decisions.first?.place == .hotKey)
    }

    @Test("Клавиша отказа отклоняет сразу, с тем, что уже написано")
    func denyKeySendsReason() {
        let keys = RequestHotKeys()
        let (hooks, _) = controller(keys: keys)
        let asked = command()
        hooks.showRequestsForSnapshot(open: [asked], expired: [], decisions: [])
        hooks.noteCard(UUID(), request: asked.id, windowShows: true)
        hooks.updateDraft(asked.id) { $0.denying = true; $0.reason = "причина" }
        press(id: 3)
        #expect(hooks.pending.isEmpty)
        #expect(hooks.queue.decisions.first?.outcome == .denied)
        #expect(hooks.drafts.isEmpty, "написанное уходит из памяти вместе с запросом")
    }

    @Test("Пока карточки на экране нет, нажатие ничего не решает")
    func pressWithoutCard() async throws {
        let keys = RequestHotKeys()
        let (hooks, _) = controller(keys: keys)
        let asked = command()
        hooks.showRequestsForSnapshot(open: [asked], expired: [], decisions: [])
        try await Task.sleep(for: .seconds(HookController.settleTime + 0.1))
        hooks.pressAllow()
        hooks.pressDeny()
        #expect(hooks.pending == [asked])
        #expect(hooks.queue.decisions.isEmpty)
    }

    @Test("Клавиша не действует на запрос, чью карточку не видно, даже если он старше")
    func onlySeenCards() {
        let (hooks, _) = controller()
        let older = command("s1", at: 60)
        let newer = command("s2", at: 5)
        hooks.showRequestsForSnapshot(open: [older, newer], expired: [], decisions: [])
        hooks.noteCard(UUID(), request: newer.id, windowShows: true)
        #expect(hooks.hotKeyTarget == newer)
    }

    @Test("Выбранная видимая карточка важнее самой старой, а невидимая выбранная нет")
    func chosenCard() {
        let (hooks, _) = controller()
        let older = command("s1", at: 60)
        let newer = command("s2", at: 5)
        hooks.showRequestsForSnapshot(open: [older, newer], expired: [], decisions: [])
        hooks.noteCard(UUID(), request: older.id, windowShows: true)
        #expect(hooks.hotKeyTarget == older)
        hooks.selectedRow = newer.id.uuidString
        #expect(hooks.hotKeyTarget == older, "выбранной карточки не видно")
        hooks.noteCard(UUID(), request: newer.id, windowShows: true)
        #expect(hooks.hotKeyTarget == newer)
    }

    @Test("Какие клавиши что-то значат, зависит от карточки")
    func wantedKeys() {
        let (hooks, _) = controller()
        func wanted(_ content: RequestContent, draft: ((inout RequestDraft) -> Void)? = nil) -> (Bool, Bool) {
            let asked = PendingPermission(session: "s", tool: "x", content: content)
            hooks.showRequestsForSnapshot(open: [asked], expired: [], decisions: [])
            hooks.noteCard(UUID(), request: asked.id, windowShows: true)
            if let draft { hooks.updateDraft(asked.id, draft) }
            return hooks.keysWanted
        }
        #expect(wanted(.command("x", unsandboxed: false)) == (true, true))
        #expect(wanted(.command("x", unsandboxed: false)) { $0.denying = true } == (false, true), "пока открыта форма отказа, разрешить клавишей нельзя")
        #expect(wanted(.plan("p")) == (true, true))
        #expect(wanted(.unreadable("x")) == (false, true), "непрочитанное нельзя разрешить")
        #expect(wanted(.questions([oneQuestion])) == (false, false), "вопрос без ответа")
        #expect(wanted(.questions([oneQuestion])) { $0.toggle("SQLite", in: oneQuestion) } == (true, false))
    }

    @Test("На форму отказа и незаполненный вопрос клавиша разрешения не занимается")
    func keyStaysFreeWhenMeaningless() {
        let (hooks, _) = controller(keys: RequestHotKeys())
        let several = RequestQuestion(text: "Что настроить?", multiple: true, options: [.init(label: "Копии")])
        let asked = PendingPermission(session: "s", tool: "AskUserQuestion", content: .questions([several]))
        hooks.showRequestsForSnapshot(open: [asked], expired: [], decisions: [])
        hooks.noteCard(UUID(), request: asked.id, windowShows: true)
        #expect(isFree(rareAllow))
        #expect(isFree(rareDeny), "у вопроса нет кнопки отказа")
        hooks.updateDraft(asked.id) { $0.toggle("Копии", in: several) }
        #expect(!isFree(rareAllow))
        hooks.updateDraft(asked.id) { $0.toggle("Копии", in: several) }
        #expect(isFree(rareAllow), "галочку сняли, и отвечать снова нечем")
    }

    @Test("Занятая клавиша показана, а без карточки предупреждение уходит")
    func takenKeyIsReportedAndForgotten() {
        let (hooks, _) = controller(keys: RequestHotKeys())
        let asked = command()
        hooks.showRequestsForSnapshot(open: [asked], expired: [], decisions: [])
        var other: EventHotKeyRef?
        RegisterEventHotKey(rareAllow.keyCode, rareAllow.carbonModifiers, EventHotKeyID(signature: 0x5445_5354, id: 98), GetApplicationEventTarget(), 0, &other)
        defer { if let other { UnregisterEventHotKey(other) } }
        let card = UUID()
        hooks.noteCard(card, request: asked.id, windowShows: true)
        #expect(hooks.keysTaken)
        #expect(!isFree(rareDeny), "вторая клавиша при этом работает")
        hooks.forgetCard(card)
        #expect(!hooks.keysTaken, "карточки нет, значит, и занимать нечего")
    }

    @Test("Ответ сразу после предыдущего не разрешает следующий запрос")
    func settleAfterAnswer() {
        let (hooks, _) = controller()
        let first = command("s1", at: 30)
        let second = command("s2", at: 10)
        hooks.showRequestsForSnapshot(open: [first, second], expired: [], decisions: [])
        let start = Date().addingTimeInterval(10)
        hooks.answer(first.id, .allow, via: .window, now: start)
        #expect(hooks.pending == [second])

        // A double press: the next card has slid into the same place.
        hooks.answer(second.id, .allow, via: .window, now: start.addingTimeInterval(0.2))
        #expect(hooks.pending == [second], "второе нажатие не считается")

        hooks.answer(second.id, .allow, via: .window, now: start.addingTimeInterval(HookController.settleTime + 0.1))
        #expect(hooks.pending.isEmpty, "спустя мгновение уже можно")
    }

    @Test("Отказ не ждёт: он ничего не запускает")
    func denyNeedsNoSettling() {
        let (hooks, _) = controller()
        let first = command("s1", at: 30)
        let second = command("s2", at: 10)
        hooks.showRequestsForSnapshot(open: [first, second], expired: [], decisions: [])
        let start = Date().addingTimeInterval(10)
        hooks.answer(first.id, .allow, via: .window, now: start)
        hooks.answer(second.id, .deny(reason: ""), via: .window, now: start.addingTimeInterval(0.1))
        #expect(hooks.pending.isEmpty)
    }

    @Test("Новая карточка под нажатием тоже защищена")
    func settleWhenTargetChanges() {
        let (hooks, _) = controller()
        let asked = command()
        hooks.showRequestsForSnapshot(open: [asked], expired: [], decisions: [])
        hooks.noteCard(UUID(), request: asked.id, windowShows: true)
        hooks.pressAllow()
        #expect(hooks.pending == [asked], "карточка появилась только что")
    }

    @Test("Enter нельзя назначить ни с каким модификатором")
    func enterIsRefused() {
        #expect(HotKeyCombo(keyCode: UInt32(kVK_Return), carbonModifiers: UInt32(cmdKey)).isEnter)
        #expect(HotKeyCombo(keyCode: UInt32(kVK_ANSI_KeypadEnter), carbonModifiers: UInt32(optionKey)).isEnter)
        #expect(!HotKeyCombo.allowStandard.isEnter)
        #expect(!HotKeyCombo.denyStandard.isEnter)
    }

    @Test("Клавиши по умолчанию: ⌥⌘Y и ⌥⌘N, отдельно от клавиши мини-окна")
    func defaults() {
        let settings = AppSettings(defaults: nil)
        #expect(settings.allowKey == .allowStandard)
        #expect(settings.denyKey == .denyStandard)
        #expect(Set([settings.allowKey.keyCode, settings.denyKey.keyCode, settings.hotKey.keyCode]).count == 3)
        #expect(settings.permissionWaitSeconds == 120)
    }

    @Test("Выбранные клавиши сохраняются между запусками")
    func keysPersist() throws {
        let defaults = try #require(UserDefaults(suiteName: "boris-tests-\(UUID().uuidString)"))
        let first = AppSettings(defaults: defaults)
        first.allowKey = rareAllow
        first.denyKey = rareDeny
        let second = AppSettings(defaults: defaults)
        #expect(second.allowKey == rareAllow)
        #expect(second.denyKey == rareDeny)
    }

    @Test("Любой выбор времени короче предела хука и срока ожидания в хуках")
    func waitsFitLimits() throws {
        let longest = try #require(RequestSettingsRows.waits.max())
        #expect(longest < HookController.hookLimit)
        #expect(TimeInterval(longest) < HookState.waitingExpiry)
        #expect(RequestSettingsRows.waits.contains(120), "значение по умолчанию есть среди вариантов")
    }
}
