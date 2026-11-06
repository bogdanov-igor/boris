import AppKit
import BorisCore
import Foundation
import SwiftUI
import Testing
@testable import Boris

private let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

@MainActor
private func lay<Content: View>(_ view: Content, size: CGSize) async -> NSHostingView<some View> {
    _ = NSApplication.shared
    let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
    host.frame = NSRect(origin: .zero, size: size)
    host.layoutSubtreeIfNeeded()
    try? await Task.sleep(for: .milliseconds(30))
    host.layoutSubtreeIfNeeded()
    return host
}

@MainActor
@Suite("Раздел «О Boris»")
struct AboutTests {
    @Test("Кнопка кофе только для настоящей веб-ссылки", arguments: [
        ("https://example.com/boris", true),
        ("http://example.com", true),
        ("", false),
        ("not a link", false),
        ("file:///etc/hosts", false),
        ("javascript:alert(1)", false),
    ])
    func coffee(text: String, shown: Bool) {
        #expect((AboutContent.coffeeLink(info: text) != nil) == shown)
    }

    @Test("Ссылки нет: кнопки нет")
    func noCoffee() {
        #expect(AboutContent.coffeeLink(info: nil) == nil)
    }

    /// The button is near the bottom of the section, so it is reached going up the middle of it, before the rows that open a license.
    private func pressCoffee(link: URL?) async -> [URL] {
        var opened: [URL] = []
        let model = AppModel(settings: AppSettings(defaults: nil), store: nil, live: false)
        let clicks = OffScreenClicks(AboutSection(model: model, coffeeLink: link, openLink: { opened.append($0) }), size: CGSize(width: 570, height: 720))
        defer { clicks.close() }
        _ = await clicks.press(along: clicks.downColumn(x: 285, step: 6).reversed()) { !opened.isEmpty }
        return opened
    }

    @Test("Кнопка кофе отдаёт ссылку браузеру и больше ничего не делает, а без ссылки нажимать нечего")
    func coffeeButton() async throws {
        let link = try #require(URL(string: "https://example.com/boris"))
        #expect(await pressCoffee(link: link) == [link])
        #expect(await pressCoffee(link: nil).isEmpty)
    }

    @Test("Отладочная ссылка важнее записанной, только чтобы проверить оба случая")
    func coffeeOverride() {
        #expect(AboutContent.coffeeLink(info: nil, override: "https://example.com")?.host == "example.com")
    }

    @Test("Тексты лицензий лежат в самом приложении и читаются оттуда")
    func licensesFromTheBundle() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("boris-bundle-\(UUID().uuidString).bundle")
        defer { try? FileManager.default.removeItem(at: folder) }
        let resources = folder.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try "own".write(to: resources.appendingPathComponent("LICENSE.txt"), atomically: true, encoding: .utf8)
        try "others".write(to: resources.appendingPathComponent("THIRD_PARTY_LICENSES.txt"), atomically: true, encoding: .utf8)
        let bundle = try #require(Bundle(url: folder))
        #expect(AboutContent.text(.own, in: bundle) == "own")
        #expect(AboutContent.text(.thirdParty, in: bundle) == "others")
        #expect(AboutContent.text(.own, in: Bundle(for: BundleMark.self)) == nil, "текста нет: сказано об этом, а не упало")
    }

    @Test("Абзацы лицензии текут по ширине окна, а заголовки и списки остаются на своих строках")
    func flowing() {
        let text = "THE WALRUS\n\nFirst line\nsecond line.\n\n  Sources/\n  design/\n\nLast."
        #expect(AboutContent.flowing(text) == "THE WALRUS\n\nFirst line second line.\n\n  Sources/\n  design/\n\nLast.")
    }

    @Test("Файлы лицензий есть в репозитории и попадают в сборку")
    func licensesInTheBuild() throws {
        let own = try String(contentsOf: packageRoot.appendingPathComponent("LICENSE"), encoding: .utf8)
        #expect(own.contains("MIT License"))
        #expect(own.contains("Igor Bogdanov"))
        #expect(own.contains("THE WALRUS"), "морж, реплики и звуки защищены")
        #expect(FileManager.default.fileExists(atPath: packageRoot.appendingPathComponent("THIRD_PARTY_LICENSES.txt").path))
        let script = try String(contentsOf: packageRoot.appendingPathComponent("scripts/build-app.sh"), encoding: .utf8)
        #expect(script.contains("LICENSE.txt"))
        #expect(script.contains("cp THIRD_PARTY_LICENSES.txt"))
    }

    private func sources() throws -> [(name: String, text: String)] {
        let root = packageRoot.appendingPathComponent("Sources/Boris")
        let walker = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        return try walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }.map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
    }

    @Test("Раздел сам в сеть не ходит и о поддержке не напоминает нигде больше")
    func noNetworkAndNoNagging() throws {
        let all = try sources()
        let about = try #require(all.first { $0.name == "AboutSection.swift" })
        for network in ["URLSession", "URLRequest", "NSURLConnection", "Data(contentsOf: link", "dataTask"] {
            #expect(!about.text.contains(network))
        }
        let mentions = all.filter { $0.text.contains("Buy Boris a coffee") }.map(\.name)
        #expect(mentions == ["AboutSection.swift"], "кнопка только здесь: \(mentions)")
    }

    @Test("Раздел открывается в обоих режимах и с длинным текстом лицензии", arguments: [DisplayMode.simple, .technical])
    func bothModes(mode: DisplayMode) async {
        let settings = AppSettings(defaults: nil)
        settings.displayMode = mode
        let model = AppModel(settings: settings, store: nil, live: false)
        #expect(SettingsSection.allCases.contains(.about))
        model.settingsSection = .about
        let about = await lay(SettingsView(model: model, connect: ConnectFlow(), actions: SettingsActions()), size: CGSize(width: 760, height: 720))
        #expect(about.fittingSize.width > 0)
        let license = await lay(SettingsView(model: model, connect: ConnectFlow(), actions: SettingsActions(), openLicense: .own), size: CGSize(width: 760, height: 720))
        #expect(license.fittingSize.width > 0)
    }
}

private final class BundleMark {}

