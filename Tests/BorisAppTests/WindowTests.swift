import AppKit
import BorisCore
import Foundation
import SwiftUI
import Testing
@testable import Boris

/// No window here is ever shown or made key: they only get laid out.
@MainActor
@Suite("Окна", .serialized)
struct WindowTests {
    private let screen = NSRect(x: 0, y: 0, width: 1512, height: 949)

    private func model(_ data: DevData, page: AppPage) -> AppModel {
        let model = AppModel(settings: AppSettings(defaults: nil), store: nil, live: false)
        data.fill(model)
        model.page = page
        return model
    }

    @Test("Рамка, которая не помещается, становится меньше и остаётся на экране")
    func tooTall() {
        let fitted = WindowFit.fitted(NSRect(x: 203, y: -900, width: 1200, height: 1849), in: screen)
        #expect(fitted == NSRect(x: 203, y: 0, width: 1200, height: 949))
    }

    @Test("Рамка за краем экрана возвращается, не меняя размера")
    func offScreen() {
        #expect(WindowFit.fitted(NSRect(x: 1400, y: -300, width: 900, height: 600), in: screen) == NSRect(x: 612, y: 0, width: 900, height: 600))
        #expect(WindowFit.fitted(NSRect(x: 100, y: 900, width: 900, height: 600), in: screen) == NSRect(x: 100, y: 349, width: 900, height: 600))
    }

    @Test("Рамка, которая помещается, не трогается")
    func fits() {
        let frame = NSRect(x: 100, y: 100, width: 1200, height: 800)
        #expect(WindowFit.fitted(frame, in: screen) == frame)
    }

    @Test("Экран с отступом сверху и снизу: окно не заходит под строку меню")
    func visibleAreaWithOrigin() {
        let visible = NSRect(x: 0, y: 70, width: 1512, height: 879)
        let fitted = WindowFit.fitted(NSRect(x: 0, y: 0, width: 1200, height: 1000), in: visible)
        #expect(fitted.minY == 70)
        #expect(fitted.maxY == 949)
    }

    /// An unshown window does not resize itself either way, so this is what can be checked without a screen:
    /// the hosting controller is told not to drive the window. Pages ask for up to 1451 points of height.
    @Test("Окна не подстраивают высоту под содержимое")
    func hostDoesNotDriveTheWindow() {
        #expect(WindowFit.host(Text(verbatim: "x")).sizingOptions == [])
    }

    @Test("Отладочная сборка не запускается как настоящая без разрешения")
    func debugBuildNeedsPermission() {
        #expect(ProcessInfo.processInfo.environment["BORIS_ALLOW_UI"] == nil)
        #expect(!DevSnapshot.mayStartForReal)
    }

    @Test("Отладочная сборка не пишет в настоящие настройки Claude")
    func realSettingsAreOffLimits() {
        let real = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
        #expect(!HookController.mayChange(real, environment: [:]))
        #expect(!HookController.mayChange(URL(fileURLWithPath: "/tmp/../Users/x/.claude/settings.json"), environment: [:]))
        let temporary = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("a/settings.json")
        #expect(HookController.mayChange(temporary, environment: [:]))
        #expect(HookController.mayChange(real, environment: ["BORIS_ALLOW_REAL_SETTINGS": "1"]))
    }
}
