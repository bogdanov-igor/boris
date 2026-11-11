import AppKit
import BorisCore
import BorisData
import Foundation
import SwiftUI
import Testing
@testable import Boris

/// The windows are laid out at one size after another, as a person dragging the corner would make them.
/// None of them is ever shown, made key or sent an event: hit tests and layout only look at geometry.
@MainActor
@Suite("Перетаскивание и размеры окон", .serialized)
struct WindowResizeTests {
    private let screen = NSRect(x: 0, y: 0, width: 1512, height: 949)

    private func model(_ mode: DisplayMode, _ language: AppLanguage, breakdown: TokenBreakdown = .days) -> AppModel {
        let settings = AppSettings(defaults: nil)
        settings.displayMode = mode
        settings.language = language
        let model = AppModel(settings: settings, store: nil, live: false)
        DevData.busy.fill(model)
        RequestDevData.fill(model, data: .busy)
        model.usage.breakdown = breakdown
        return model
    }

    private func mainWindow(_ model: AppModel, size: NSSize = NSSize(width: 1200, height: 800)) async -> (NSWindow, NSHostingController<MainWindowView>) {
        _ = NSApplication.shared
        let host = WindowFit.host(MainWindowView(model: model, connect: ConnectFlow(), openSettings: { _ in }))
        let window = WindowFit.window(host, title: "Boris", size: size, minimum: MainWindowController.minimum)
        await settle(host.view)
        return (window, host)
    }

    /// Lets the pages that size themselves by the room they get see their new width.
    private func settle(_ view: NSView) async {
        for _ in 0..<3 {
            view.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(5))
        }
        view.layoutSubtreeIfNeeded()
    }

    /// What catches a press at a point given from the window's top left corner, as on screen.
    private func hit(_ window: NSWindow, _ x: CGFloat, _ yFromTop: CGFloat) -> NSView? {
        let frame = window.contentView?.superview
        return frame?.hitTest(NSPoint(x: x, y: window.frame.height - yFromTop))
    }

    // MARK: - Moving

    @Test("Окно не уезжает, когда тянут за страницу, список или полосу прокрутки")
    func movesOnlyByItsTop() async {
        let model = model(.technical, .en)
        for page in [AppPage.now, .spend, .activity, .requests, .losses, .walrus] {
            model.choose(page)
            let (window, _) = await mainWindow(model)
            #expect(!window.isMovableByWindowBackground)
            #expect(window.styleMask.contains(.resizable))
            for (x, y) in [(600.0, 300.0), (900.0, 500.0), (1195.0, 300.0), (100.0, 400.0), (60.0, 95.0)] {
                #expect(!(hit(window, x, y) is WindowDragView), "\(page) \(x),\(y)")
            }
        }
    }

    @Test("За шапку страницы и верх боковой панели окно тянется, как за заголовок")
    func headerMovesTheWindow() async {
        let model = model(.technical, .en)
        for page in [AppPage.now, .spend, .requests, .activity, .losses, .walrus, .projects] {
            model.choose(page)
            let (window, _) = await mainWindow(model)
            #expect(hit(window, 100, 20) is WindowDragView, "\(page) sidebar")
            #expect(hit(window, 640, 44) is WindowDragView, "\(page) header")
            #expect(hit(window, 250, 30) is WindowDragView, "\(page) title")
        }
        model.choose(.projects)
        model.openSession(DevProjects.working)
        let (window, _) = await mainWindow(model)
        #expect(hit(window, 700, 8) is WindowDragView, "session header")
    }

    @Test("Кнопки в шапке нажимаются, а не тянут окно")
    func headerControlsKeepTheirClicks() async {
        let model = model(.technical, .en)
        model.choose(.spend)
        let (window, _) = await mainWindow(model)
        // The choice of a period and the sidebar's first item.
        #expect(!(hit(window, 1100 - 330, 26) is WindowDragView))
        #expect(!(hit(window, 40, 64) is WindowDragView))
    }

    @Test("Двойной щелчок по шапке делает то же, что по заголовку в настройках системы")
    func doubleClick() {
        #expect(WindowFit.DoubleClick.chosen(nil) == .zoom)
        #expect(WindowFit.DoubleClick.chosen("Maximize") == .zoom)
        #expect(WindowFit.DoubleClick.chosen("Fill") == .zoom)
        #expect(WindowFit.DoubleClick.chosen("Minimize") == .minimize)
        #expect(WindowFit.DoubleClick.chosen("None") == .nothing)
    }

    @Test("Окно настроек тоже не тянется за фон, а верх боковой панели его тянет")
    func settingsWindow() async {
        _ = NSApplication.shared
        let model = model(.technical, .en)
        let host = WindowFit.host(SettingsView(model: model, connect: ConnectFlow(), actions: SettingsActions()))
        let window = WindowFit.window(host, title: "Settings", size: NSSize(width: 760, height: 720), minimum: SettingsWindowController.minimum)
        await settle(host.view)
        #expect(!window.isMovableByWindowBackground)
        #expect(hit(window, 100, 20) is WindowDragView)
        #expect(!(hit(window, 400, 300) is WindowDragView))
    }

    /// The hosting controller used to set the smallest size back to nothing once the page was laid out, and the window could be dragged down to a sliver.
    @Test("Окно нельзя сделать меньше наименьшего размера и после того, как страница разложена")
    func minimumHoldsAfterLayout() async {
        let model = model(.technical, .en)
        let (main, mainHost) = await mainWindow(model)
        for page in AppPage.allCases {
            model.choose(page)
            await settle(mainHost.view)
            try? await Task.sleep(for: .milliseconds(30))
            #expect(main.minSize == MainWindowController.minimum, "\(page)")
            #expect(main.contentMinSize == MainWindowController.minimum, "\(page)")
        }

        let host = WindowFit.host(SettingsView(model: model, connect: ConnectFlow(), actions: SettingsActions()))
        let settings = WindowFit.window(host, title: "Settings", size: NSSize(width: 760, height: 720), minimum: SettingsWindowController.minimum)
        for section in SettingsSection.allCases {
            model.settingsSection = section
            await settle(host.view)
            try? await Task.sleep(for: .milliseconds(30))
            #expect(settings.minSize == SettingsWindowController.minimum, "\(section)")
        }
    }

    // MARK: - Saved frame

    @Test("Рамка, сохранённая меньше наименьшего размера, вырастает до него и остаётся на экране")
    func savedTooSmall() {
        let minimum = MainWindowController.minimum
        #expect(WindowFit.fitted(NSRect(x: 100, y: 100, width: 700, height: 400), in: screen, minimum: minimum) == NSRect(x: 100, y: 100, width: 900, height: 600))
        #expect(WindowFit.fitted(NSRect(x: 1300, y: 800, width: 500, height: 300), in: screen, minimum: minimum) == NSRect(x: 612, y: 349, width: 900, height: 600))
        // A screen smaller than the smallest window: the screen wins.
        let small = NSRect(x: 0, y: 0, width: 800, height: 560)
        #expect(WindowFit.fitted(NSRect(x: 0, y: 0, width: 700, height: 400), in: small, minimum: minimum) == small)
    }

    @Test("Рамка на втором экране остаётся на нём")
    func secondScreen() {
        let second = NSRect(x: -1920, y: 120, width: 1920, height: 1055)
        let frame = NSRect(x: -1500, y: 300, width: 1200, height: 800)
        #expect(WindowFit.fitted(frame, in: second, minimum: MainWindowController.minimum) == frame)
    }

    // MARK: - Resizing

    private static let widths: [CGFloat] = [900, 950, 1000, 1011, 1050, 1101, 1150, 1250, 1400, 1700]

    @Test("От наименьшего размера и выше каждая страница помещается в окно, и окно не меняет размер само", arguments: [AppLanguage.ru, .en], [DisplayMode.technical, .simple])
    func everyPageFitsAtEverySize(language: AppLanguage, mode: DisplayMode) async {
        let model = model(mode, language)
        var pages: [(String, () -> Void)] = AppPage.allCases.filter { $0.isShown(in: mode) }.map { page in (page.rawValue, { model.choose(page) }) }
        pages.append(("project", { model.choose(.projects); model.openProject("/x/shop-api") }))
        pages.append(("session", { model.choose(.projects); model.openSession(DevProjects.working) }))
        for (name, open) in pages {
            open()
            let (window, host) = await mainWindow(model, size: MainWindowController.minimum)
            for height in [MainWindowController.minimum.height, 900] {
                for width in Self.widths {
                    let size = NSSize(width: width, height: height)
                    window.setContentSize(size)
                    await settle(host.view)
                    #expect(window.frame.size == size, "\(name) \(size)")
                    let wanted = host.sizeThatFits(in: size)
                    #expect(wanted.width <= width + 0.5 && wanted.height <= height + 0.5, "\(name) \(language) \(mode) at \(size): needs \(wanted)")
                }
            }
        }
    }

    @Test("«Расход» помещается при любой разбивке, и колонки меняются по ширине, а не по данным", arguments: TokenBreakdown.allCases)
    func spendFitsInEveryBreakdown(breakdown: TokenBreakdown) async {
        let model = model(.technical, .ru, breakdown: breakdown)
        model.choose(.spend)
        let (window, host) = await mainWindow(model, size: MainWindowController.minimum)
        for width in Self.widths {
            let size = NSSize(width: width, height: 700)
            window.setContentSize(size)
            await settle(host.view)
            #expect(host.sizeThatFits(in: size).width <= width + 0.5, "\(breakdown) at \(width)")
        }
        #expect(SpendPage.twoColumnsFrom == 890)
        #expect(!SpendPage.hasTwoColumns(889) && SpendPage.hasTwoColumns(890))
    }

    @Test("Каждый раздел настроек помещается от наименьшего размера и выше", arguments: [AppLanguage.ru, .en])
    func everySettingsSectionFits(language: AppLanguage) async {
        _ = NSApplication.shared
        let model = model(.technical, language)
        let host = WindowFit.host(SettingsView(model: model, connect: ConnectFlow(), actions: SettingsActions()))
        let window = WindowFit.window(host, title: "Settings", size: SettingsWindowController.minimum, minimum: SettingsWindowController.minimum)
        for section in SettingsSection.allCases {
            model.settingsSection = section
            for size in [SettingsWindowController.minimum, NSSize(width: 760, height: 720), NSSize(width: 1100, height: 900)] {
                window.setContentSize(size)
                await settle(host.view)
                #expect(window.frame.size == size)
                let wanted = host.sizeThatFits(in: size)
                #expect(wanted.width <= size.width + 0.5 && wanted.height <= size.height + 0.5, "\(section) \(language) at \(size): needs \(wanted)")
            }
        }
    }

    @Test("Колонка агентов в сессии растёт с окном плавно, без скачка")
    func sessionAsideGrowsSmoothly() {
        var previous = SessionPage.asideWidth(for: 600)
        #expect(previous == 300)
        for width in stride(from: 601.0, through: 1500, by: 1) {
            let next = SessionPage.asideWidth(for: width)
            #expect(next >= previous && next - previous <= 0.5, "\(width)")
            previous = next
        }
        #expect(previous == 380)
    }
}
