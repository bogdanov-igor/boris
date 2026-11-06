import BorisData
import Foundation
import Testing
@testable import Boris

/// Stands in for Sparkle: no network, no windows.
@MainActor
private final class FakeEngine: UpdateEngine {
    var checksAutomatically = true
    var onStatus: ((UpdateStatus) -> Void)?
    var startWorks = true
    var checkAccepted = true
    var started = 0
    var checks = 0
    var windows = 0

    func start() -> Bool {
        started += 1
        return startWorks
    }

    func checkNow() -> Bool {
        checks += 1
        return checkAccepted
    }

    func showUpdate() {
        windows += 1
    }
}

@MainActor
@Suite("Обновления")
struct UpdatesTests {
    private let offer = UpdateOffer(version: "1.1", notes: nil)

    @Test("В отладочной сборке проверки нет вообще, что бы ни было написано в её настройках")
    func debugBuildHasNoCheck() {
        let updates = Updates.forThisBuild(info: ["SUFeedURL": "https://example.com/appcast.xml", "SUPublicEDKey": "key"])
        #expect(!updates.canCheck)
        #expect(!updates.checksAutomatically)
        updates.start()
        updates.checkNow()
        updates.install()
        #expect(updates.status == .unknown)
    }

    @Test("Копия без адреса или без ключа не считается выпущенной")
    func needsBothFeedAndKey() {
        #expect(UpdateConfiguration(info: [:]) == nil)
        #expect(UpdateConfiguration(info: ["SUFeedURL": "https://example.com/appcast.xml"]) == nil)
        #expect(UpdateConfiguration(info: ["SUPublicEDKey": "key"]) == nil)
        #expect(UpdateConfiguration(info: ["SUFeedURL": "", "SUPublicEDKey": ""]) == nil)
        #expect(UpdateConfiguration(info: ["SUFeedURL": "https://example.com/appcast.xml", "SUPublicEDKey": "key"]) != nil)
    }

    @Test("Если Sparkle не запустился, настройки говорят, что проверять некому")
    func engineThatFailsToStart() {
        let engine = FakeEngine()
        engine.startWorks = false
        let updates = Updates(engine: engine)
        updates.start()
        #expect(!updates.canCheck)
        updates.checkNow()
        #expect(engine.checks == 0)
    }

    @Test("Кнопка проверяет и показывает, что нашлось")
    func checkingByHand() {
        let engine = FakeEngine()
        let updates = Updates(engine: engine)
        updates.start()
        updates.checkNow()
        #expect(engine.checks == 1)
        #expect(updates.status == .checking)
        engine.onStatus?(.upToDate)
        #expect(updates.status == .upToDate)
        #expect(updates.offer == nil)
    }

    @Test("Занятый Sparkle не оставляет строку в состоянии «Проверяю…» навсегда")
    func busyEngineChangesNothing() {
        let engine = FakeEngine()
        engine.checkAccepted = false
        let updates = Updates(engine: engine)
        updates.start()
        engine.onStatus?(.available(offer))
        updates.checkNow()
        #expect(updates.status == .available(offer))
    }

    @Test("Новая версия показывает плашку, а окно Sparkle открывается только по кнопке")
    func offerAndConsent() {
        let engine = FakeEngine()
        let updates = Updates(engine: engine)
        updates.start()
        engine.onStatus?(.available(offer))
        #expect(updates.offer == offer)
        #expect(engine.windows == 0)
        updates.install()
        #expect(engine.windows == 1)
        // «Позже» в окне Sparkle.
        engine.onStatus?(.unknown)
        #expect(updates.offer == nil)
    }

    @Test("Переключатель доходит до Sparkle")
    func automaticSwitch() {
        let engine = FakeEngine()
        let updates = Updates(engine: engine)
        #expect(updates.checksAutomatically)
        updates.setChecksAutomatically(false)
        #expect(!engine.checksAutomatically)
        #expect(!updates.checksAutomatically)
    }

    @Test("После неудачной проверки смотрим снова, только когда связь вернулась")
    func retryOnlyWhenTheConnectionComesBack() {
        var retry = RetryWhenOnline()
        // The system answers at once with what is true now: the network was up, and the failure was something else.
        let answers = [true, true, false, false, true, true].map { retry.pathChanged(online: $0) }
        #expect(answers == [false, false, false, false, true, false])
    }

    @Test("На экране абзац лицензии течёт, а короткие строки, списки и линейки остаются")
    func licenseFlows() {
        let file = """
        ================================================================================
        Sparkle 2.10.1
        ================================================================================

        Copyright (c) 2006-2013 Andy Matuschak.
        Copyright (c) 2014 C.W. Betts.

        Redistribution and use in source and binary forms, with or without
        modification, are permitted providing that the following conditions
        are met:
        1. Redistributions of source code must retain the above copyright
           notice, this list of conditions and the following disclaimer.
        2. Redistributions in binary form must reproduce the above copyright
           notice.

          Sources/BorisCharacter/
          design/walrus/
        """
        let lines = AboutSection.LicenseText.flowing(file).components(separatedBy: "\n")
        #expect(lines == [
            "================================================================================",
            "Sparkle 2.10.1",
            "================================================================================",
            "",
            "Copyright (c) 2006-2013 Andy Matuschak.",
            "Copyright (c) 2014 C.W. Betts.",
            "",
            "Redistribution and use in source and binary forms, with or without modification, are permitted providing that the following conditions are met:",
            "1. Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.",
            "2. Redistributions in binary form must reproduce the above copyright notice.",
            "",
            "  Sources/BorisCharacter/",
            "  design/walrus/",
        ])
    }

    @Test("Текст лицензий берётся из самого приложения")
    func licensesComeFromTheBundle() throws {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("boris-license-\(UUID().uuidString).app")
        defer { try? FileManager.default.removeItem(at: app) }
        let resources = app.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "app.boris.license-test"], format: .xml, options: 0)
        try info.write(to: app.appendingPathComponent("Contents/Info.plist"))
        try "own".write(to: resources.appendingPathComponent("LICENSE.txt"), atomically: true, encoding: .utf8)
        try "theirs".write(to: resources.appendingPathComponent("THIRD_PARTY_LICENSES.txt"), atomically: true, encoding: .utf8)
        let bundle = try #require(Bundle(url: app))
        #expect(AboutSection.LicenseText.own.text(in: bundle) == "own")
        #expect(AboutSection.LicenseText.thirdParty.text(in: bundle) == "theirs")
    }
}
