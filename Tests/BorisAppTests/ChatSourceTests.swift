import BorisCore
import BorisData
import Foundation
import Testing
@testable import Boris

private final class RememberingDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Bool] = [:]

    override func set(_ value: Bool, forKey key: String) {
        values[key] = value
    }

    override func bool(forKey key: String) -> Bool {
        values[key] ?? false
    }

    override func object(forKey key: String) -> Any? { nil }
    override func string(forKey key: String) -> String? { nil }
    override func data(forKey key: String) -> Data? { nil }
    override func set(_ value: Any?, forKey key: String) {}
}

@MainActor
private func makeModel() -> AppModel {
    // In memory, and with the stand-in: nothing here reaches Claude Desktop or macOS.
    AppModel(settings: AppSettings(defaults: nil), store: nil, live: false)
}

@Suite("Обычный чат в приложении")
@MainActor
struct ChatSourceTests {
    @Test("По умолчанию выключен, и после запуска никто никуда не смотрит")
    func offByDefault() async {
        let model = makeModel()
        #expect(!model.settings.chatConsent)
        #expect(!model.chat.isLooking)
        #expect(model.chat.tracker.connection == .notConnected)
        model.chat.update(consent: model.settings.chatConsent)
        #expect(!model.chat.isLooking)
    }

    @Test("Согласие и отказ меняют настройку и слежение вместе")
    func consent() async {
        let model = makeModel()
        model.setChatConsent(true)
        #expect(model.settings.chatConsent)
        #expect(model.chat.isLooking)
        model.setChatConsent(false)
        #expect(!model.settings.chatConsent)
        #expect(!model.chat.isLooking)
        #expect(model.chat.tracker.connection == .notConnected)
    }

    @Test("Согласие включает источник, а выключенный источник перестаёт смотреть в окно")
    func sourceSwitch() async {
        let model = makeModel()
        #expect(!model.settings.sources.reads(.chat))
        model.setChatConsent(true)
        #expect(model.settings.sources.reads(.chat))
        #expect(model.settings.sources.notifies(.chat))
        model.settings.sources.set(.chat, on: false)
        model.sourcesChanged(reading: true)
        #expect(!model.chat.isLooking)
        model.settings.sources.set(.chat, on: true)
        model.sourcesChanged(reading: true)
        #expect(model.chat.isLooking)
        model.setChatConsent(false)
        #expect(!model.settings.sources.reads(.chat))
        #expect(!model.chat.isLooking)
    }

    @Test("Согласие хранится между запусками")
    func remembered() {
        // Held in memory: a real suite leaves a file in the person's preferences folder.
        let defaults = RememberingDefaults()
        #expect(!AppSettings(defaults: defaults).chatConsent)
        AppSettings(defaults: defaults).chatConsent = true
        #expect(AppSettings(defaults: defaults).chatConsent)
    }

    @Test("Со страницы чата можно перейти в Claude Desktop")
    func canOpen() {
        let chat = WorkSession(id: ChatTracker.sessionId, environment: .chat, state: .running, root: WorkNode(id: ChatTracker.sessionId, kind: .main))
        #expect(SessionNavigator.canOpen(chat, pid: nil))
        #expect(SessionJump.title(.chat) == "Open Claude Desktop")
    }
}
