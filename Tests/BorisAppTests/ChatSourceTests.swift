import BorisCore
import BorisData
import Foundation
import Testing
@testable import Boris

/// Held in memory: a real suite leaves a file in the person's preferences folder.
private final class RememberingDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]

    override func set(_ value: Bool, forKey key: String) {
        values[key] = value
    }

    override func bool(forKey key: String) -> Bool {
        values[key] as? Bool ?? false
    }

    override func object(forKey key: String) -> Any? { values[key] }
    override func string(forKey key: String) -> String? { values[key] as? String }
    override func data(forKey key: String) -> Data? { values[key] as? Data }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
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
        let defaults = RememberingDefaults()
        #expect(!AppSettings(defaults: defaults).chatConsent)
        let model = AppModel(settings: AppSettings(defaults: defaults), store: nil, live: false)
        model.setChatConsent(true)
        let again = AppSettings(defaults: defaults)
        #expect(again.chatConsent)
        #expect(again.sources.reads(.chat))
        model.setChatConsent(false)
    }

    /// What a version that showed the chat as a row of its own could leave behind.
    private func saved(consent: Bool, _ change: (inout SourceSettings) -> Void) -> RememberingDefaults {
        let defaults = RememberingDefaults()
        var sources = SourceSettings()
        sources.set(.chat, on: true)
        change(&sources)
        defaults.set(try? JSONEncoder().encode(sources), forKey: "sources")
        defaults.set(consent, forKey: "chatConsent")
        return defaults
    }

    @Test("Согласие есть, а чат выключен прежним рядом: переключатель не говорит «вкл», пока никто не смотрит", arguments: ["product", "reading"])
    func oldRowOff(what: String) {
        let defaults = saved(consent: true) { sources in
            if what == "product" { sources.set(.chat, on: false) } else { sources[.chat].read = false }
        }
        let settings = AppSettings(defaults: defaults)
        #expect(!settings.chatConsent, "переключатель чата показан выключенным")
        #expect(!settings.sources.reads(.chat))
        let model = AppModel(settings: settings, store: nil, live: false)
        model.updateChatWatch()
        #expect(!model.chat.isLooking)
        // Turned on again, it works in full: no hidden part of the old row keeps it off.
        model.setChatConsent(true)
        #expect(model.settings.sources.reads(.chat))
        #expect(model.chat.isLooking)
        model.setChatConsent(false)
    }

    @Test("Источник чата включён без согласия: окна никто не трогает, и переключатель выключен")
    func sourceWithoutConsent() {
        let settings = AppSettings(defaults: saved(consent: false) { _ in })
        #expect(!settings.chatConsent)
        #expect(!settings.sources.reads(.chat))
    }

    @Test("У включённого чата нет скрытых запретов от прежнего ряда: о готовом ответе сообщается, окна не прячутся")
    func oldRowSwitches() {
        let defaults = saved(consent: true) { sources in
            sources[.chat].notify = false
            sources[.chat].capture = false
        }
        let settings = AppSettings(defaults: defaults)
        #expect(settings.chatConsent)
        #expect(settings.sources.notifies(.chat))
        #expect(!settings.sources.forbidsCapture(.chat))
    }

    @Test("Со страницы чата можно перейти в Claude Desktop")
    func canOpen() {
        let chat = WorkSession(id: ChatTracker.sessionId, environment: .chat, state: .running, root: WorkNode(id: ChatTracker.sessionId, kind: .main))
        #expect(SessionNavigator.canOpen(chat, pid: nil))
        #expect(SessionJump.title(.chat) == "Open Claude Desktop")
    }
}
