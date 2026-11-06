import AppKit
import BorisCore
import CoreGraphics
import Foundation
import Testing
@testable import Boris

/// No window here: the stage only decides, and nothing reaches the person's screen.
@MainActor
@Suite("Сцена панели")
struct SurfaceStageTests {
    private let wide = SurfaceScreen(
        id: "wide",
        name: "Wide",
        frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1050),
        statusIconsMinX: 1200
    )
    private let laptop = SurfaceScreen(
        id: "laptop",
        name: "Built-in",
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 70, width: 1512, height: 875),
        notch: CGRect(x: 664, y: 945, width: 184, height: 37)
    )

    private func inputs(_ switches: SurfaceSwitches = SurfaceSwitches(), numbers: SurfaceNumbers = SurfaceNumbers(waiting: 1, agents: 3), requests: Int = 0, quiet: Bool = false, spoken: String? = nil) -> SurfaceInputs {
        let settings = AppSettings(defaults: nil)
        settings.surfaces = switches
        var inputs = SurfaceInputs(model: AppModel(settings: settings, store: nil, live: false))
        inputs.numbers = numbers
        inputs.requests = requests
        inputs.quiet = quiet
        inputs.spoken = spoken
        return inputs
    }

    private func hidden(_ screen: SurfaceScreen) -> SurfaceScreen {
        var screen = screen
        screen.visibleFrame.size.height = screen.frame.maxY - screen.visibleFrame.minY
        screen.menuBar = 0
        screen.statusIconsMinX = nil
        return screen
    }

    private func arrange(_ inputs: SurfaceInputs, on screen: SurfaceScreen, isOpen: Bool = false) -> (SurfaceStage, SurfacePlacement?) {
        let stage = SurfaceStage()
        let placement = stage.arrange(inputs, on: screen, isOpen: isOpen, contentHeight: 300)
        return (stage, placement)
    }

    @Test("С местом в строке панель говорит полностью")
    func roomy() throws {
        let (stage, placement) = arrange(inputs(), on: wide)
        #expect(try #require(placement).strip != nil)
        #expect(stage.line == SurfaceLine(main: "3 agents at work", waiting: "1 needs you"))
        #expect(stage.strip == placement?.frame)
        #expect(stage.stripInset == 0)
    }

    @Test("Места мало: панель говорит коротко, а её рамка совпадает с тем, что она говорит")
    func tight() throws {
        var screen = wide
        screen.statusIconsMinX = 930
        let (stage, placement) = arrange(inputs(), on: screen)
        let frame = try #require(placement).frame
        #expect(stage.line == SurfaceLine(main: "3 agents", waiting: "1 needs you"))
        #expect(frame.maxX <= 930)
        #expect(frame.width == SurfaceMetrics.stripWidth(stage.line, height: 30).rounded(.up))
    }

    @Test("Ещё меньше: остаётся только тот, кто ждёт")
    func tighter() throws {
        var screen = wide
        screen.statusIconsMinX = 870
        let (stage, placement) = arrange(inputs(), on: screen)
        #expect(try #require(placement).frame.maxX <= 870)
        #expect(stage.line == SurfaceLine(waiting: "1 needs you"))
    }

    @Test("Совсем мало: морж один")
    func onlyWalrus() {
        var screen = wide
        screen.statusIconsMinX = 770
        let (stage, placement) = arrange(inputs(), on: screen)
        #expect(placement != nil)
        #expect(stage.line == SurfaceLine())
    }

    @Test("Места нет: на экране ничего")
    func noRoom() {
        var screen = wide
        screen.statusIconsMinX = 700
        let (stage, placement) = arrange(inputs(), on: screen)
        #expect(placement == nil)
        #expect(stage.strip == nil)
    }

    @Test("Последний способ открыть Boris остаётся и без места")
    func lastWayIn() {
        var screen = wide
        screen.statusIconsMinX = 700
        let only = SurfaceSwitches(icon: false, notch: true, mini: false)
        #expect(inputs(only).lastWayIn)
        #expect(!inputs().lastWayIn)
        #expect(!inputs(SurfaceSwitches(icon: false, notch: false, mini: true)).lastWayIn)
        let (stage, placement) = arrange(inputs(only), on: screen)
        #expect(placement != nil)
        #expect(stage.line == SurfaceLine())
    }

    @Test("Строка скрыта: без запроса ничего нет")
    func hiddenQuiet() {
        #expect(arrange(inputs(), on: hidden(wide)).1 == nil)
    }

    @Test("Строка скрыта: при ждущем запросе свёрнутая панель остаётся")
    func hiddenWithRequest() throws {
        let (stage, placement) = arrange(inputs(requests: 1), on: hidden(wide))
        let found = try #require(placement)
        #expect(found.frame.height == SurfaceGeometry.hiddenStripHeight)
        #expect(stage.strip != nil)
    }

    @Test("Строка скрыта и включена тишина: запрос ждёт в очереди и на экран не выходит")
    func hiddenInQuietHours() {
        #expect(arrange(inputs(requests: 1, quiet: true), on: hidden(wide)).1 == nil)
    }

    @Test("Открытая панель: рядом с листом полоска, а его место в окне посчитано")
    func open() throws {
        let (stage, placement) = arrange(inputs(requests: 1), on: wide, isOpen: true)
        let found = try #require(placement)
        let sheet = try #require(found.sheet)
        let strip = try #require(found.strip)
        #expect(stage.isOpen)
        #expect(found.frame.minX + stage.sheetInset == sheet.minX)
        #expect(found.frame.minX + stage.stripInset == strip.minX)
        #expect(sheet.height == 300)
        #expect(found.frame.height == 330)
    }

    @Test("Открытая панель при скрытой строке: полоски нет")
    func openHidden() throws {
        let (stage, placement) = arrange(inputs(requests: 1), on: hidden(wide), isOpen: true)
        #expect(try #require(placement).strip == nil)
        #expect(stage.strip == nil)
        #expect(stage.sheetInset == 0)
    }

    @Test("Длинная реплика не помещается и уступает числам")
    func longLine() {
        var screen = wide
        screen.statusIconsMinX = 1000
        let long = String(repeating: "Морж говорит что-то долгое. ", count: 6)
        #expect(arrange(inputs(spoken: long), on: screen).0.line != SurfaceLine(main: long))
        #expect(arrange(inputs(spoken: "Привет"), on: screen).0.line == SurfaceLine(main: "Привет"))
    }

    @Test("Ширина моржа не даёт его шляпе выйти за строку меню", arguments: [24.0, 30.0, 37.0, 60.0] as [CGFloat])
    func walrusFits(height: CGFloat) {
        let walrus = SurfaceMetrics.stripWalrus(height: height)
        #expect(walrus * SurfaceMetrics.walrusOverdraw <= height)
        #expect(walrus >= 18)
    }

    @Test("Чёлка своё место не меняет и полоски не заводит, что бы ни было со строкой меню")
    func notch() {
        var bare = laptop
        bare.menuBar = 0
        let visible = arrange(inputs(), on: laptop)
        let gone = arrange(inputs(), on: bare)
        #expect(visible.1 != nil)
        #expect(visible.1 == gone.1)
        #expect(visible.0.strip == nil)
        #expect(visible.1?.frame.maxY == laptop.frame.maxY)
        #expect(visible.0.hasNotch)
    }

    /// The real list and the real screens, read only: this proves the keys and types of what the Window Server gives. Nothing is shown and nothing asks for permission.
    @Test("Настоящий список окон читается, и экраны получаются правдоподобные")
    func realWindowList() throws {
        // `visibleFrame` of a monitor other than the main one is right only inside an application.
        _ = NSApplication.shared
        let windows = MenuBarWindows.read()
        for window in windows {
            #expect([MenuBarReading.normalLayer, MenuBarReading.barLayer, MenuBarReading.iconLayer].contains(window.layer))
        }
        for screen in SurfaceScreens.current(windows: windows) {
            #expect(screen.menuBar >= 0)
            #expect(screen.menuBar < 100)
            if let icons = screen.statusIconsMinX {
                #expect(icons >= screen.frame.minX)
                #expect(icons <= screen.frame.maxX)
                #expect(screen.menuBar > 0)
            }
            // Wherever it lands on the real bar, it is off the windows and off the icons.
            guard screen.notch == nil, let placement = arrange(inputs(), on: screen).1 else { continue }
            #expect(!placement.frame.intersects(screen.visibleFrame))
            if let icons = screen.statusIconsMinX { #expect(placement.frame.maxX <= icons) }
        }
    }

    @Test("Панель, сменившая экран на чёлку, не оставляет после себя полоску")
    func leavesNoStripOnNotch() {
        let stage = SurfaceStage()
        _ = stage.arrange(inputs(), on: wide, isOpen: false, contentHeight: 300)
        #expect(stage.strip != nil)
        _ = stage.arrange(inputs(), on: laptop, isOpen: false, contentHeight: 300)
        #expect(stage.strip == nil)
    }
}
