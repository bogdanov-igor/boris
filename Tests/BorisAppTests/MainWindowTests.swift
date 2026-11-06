import AppKit
import BorisCore
import BorisData
import Foundation
import SwiftUI
import Testing
@testable import Boris

/// Lays a view out off screen. It is never shown, never key, and nothing is pressed.
@MainActor
private func lay<Content: View>(_ view: Content, size: CGSize = CGSize(width: 1200, height: 800)) async -> NSHostingView<some View> {
    _ = NSApplication.shared
    let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
    host.frame = NSRect(origin: .zero, size: size)
    host.layoutSubtreeIfNeeded()
    try? await Task.sleep(for: .milliseconds(30))
    host.layoutSubtreeIfNeeded()
    return host
}

@MainActor
@Suite("Главное окно", .serialized)
struct MainWindowTests {
    private func model(_ data: DevData, _ mode: DisplayMode) -> AppModel {
        let settings = AppSettings(defaults: nil)
        settings.displayMode = mode
        let model = AppModel(settings: settings, store: nil, live: false)
        data.fill(model)
        return model
    }

    @Test("В техническом режиме все страницы, в простом нет «Активности» и «Потерь»")
    func sidebar() {
        #expect(AppPage.allCases.filter { $0.isShown(in: .technical) } == [.now, .projects, .spend, .requests, .activity, .losses, .walrus])
        #expect(AppPage.allCases.filter { $0.isShown(in: .simple) } == [.now, .projects, .spend, .requests, .walrus])
    }

    @Test("Каждая страница открывается и в заполненном, и в пустом виде", arguments: [DevData.busy, .empty, .long], [DisplayMode.simple, .technical])
    func everyPage(data: DevData, mode: DisplayMode) async {
        let model = model(data, mode)
        for page in AppPage.allCases where page.isShown(in: mode) {
            model.choose(page)
            #expect(model.page == page)
            let host = await lay(MainWindowView(model: model, connect: ConnectFlow(), openSettings: { _ in }))
            #expect(host.fittingSize.height > 0, "\(page)")
        }
    }

    @Test("Бейдж у «Запросов» считает ожидающих")
    func badge() {
        let model = AppModel(settings: AppSettings(defaults: nil), store: nil, live: false)
        #expect(model.requestCount == 0)
        let first = PendingPermission(session: "s1", tool: "Bash", content: .command("a", unsandboxed: false), project: "p", askedAt: Date().addingTimeInterval(-20))
        let second = PendingPermission(session: "s2", tool: "Bash", content: .command("b", unsandboxed: false), project: "p", askedAt: Date().addingTimeInterval(-10))
        model.hooks.showRequestsForSnapshot(open: [first, second], expired: [], decisions: [])
        #expect(model.requestCount == 2)
    }

    @Test("Первый запуск узнаётся по сохранённому, а не по часам")
    func firstLaunchIsRemembered() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("boris-state-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = AppModel(settings: AppSettings(defaults: nil), store: StateStore(folder: folder), live: false)
        #expect(first.isFirstLaunch)
        first.persistNow()
        // Sooner than any time limit: a quick restart after a crash is not a first launch.
        let second = AppModel(settings: AppSettings(defaults: nil), store: StateStore(folder: folder), live: false)
        #expect(!second.isFirstLaunch)
    }
}

@MainActor
@Suite("Темы")
struct ThemeTests {
    @Test("«Как в системе» значит не задавать вид самому, а тёмная и светлая задают свой")
    func modes() {
        #expect(ThemeMode.system.appearance == nil)
        #expect(ThemeMode.light.appearance?.name == .aqua)
        #expect(ThemeMode.dark.appearance?.name == .darkAqua)
    }

    @Test("Цвета следуют за видом, в котором нарисованы")
    func colours() throws {
        func resolved(_ color: Color, _ name: NSAppearance.Name) throws -> NSColor {
            let appearance = try #require(NSAppearance(named: name))
            var result = NSColor.clear
            appearance.performAsCurrentDrawingAppearance {
                result = NSColor(color).usingColorSpace(.sRGB) ?? .clear
            }
            return result
        }
        for color in [Palette.window, Palette.text1, Palette.side, Palette.pop] {
            let light = try resolved(color, .aqua)
            let dark = try resolved(color, .darkAqua)
            #expect(light != dark)
        }
    }
}

