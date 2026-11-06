import BorisCore
import CoreGraphics
import Foundation
import Testing

/// A monitor as the main screen, with a menu bar as high as on the current macOS and the icons taking a good part of it.
private let wide = SurfaceScreen(
    id: "wide",
    name: "Wide",
    frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
    visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1050),
    statusIconsMinX: 1200
)

/// A monitor stood on end to the left of it: narrow, and everything in it has coordinates below zero.
private let upright = SurfaceScreen(
    id: "upright",
    name: "Upright",
    frame: CGRect(x: -1080, y: -840, width: 1080, height: 1920),
    visibleFrame: CGRect(x: -1080, y: -840, width: 1080, height: 1890),
    statusIconsMinX: -480
)

private let laptop = SurfaceScreen(
    id: "laptop",
    name: "Built-in",
    frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
    visibleFrame: CGRect(x: 0, y: 70, width: 1512, height: 875),
    notch: CGRect(x: 664, y: 945, width: 184, height: 37)
)

private func hidden(_ screen: SurfaceScreen) -> SurfaceScreen {
    var screen = screen
    screen.visibleFrame.size.height = screen.frame.maxY - screen.visibleFrame.minY
    screen.menuBar = 0
    screen.statusIconsMinX = nil
    return screen
}

private func with(_ screen: SurfaceScreen, icons: CGFloat?) -> SurfaceScreen {
    var screen = screen
    screen.statusIconsMinX = icons
    return screen
}

private func strip(_ screen: SurfaceScreen, _ widths: [CGFloat] = [200, 34], request: Bool = false, lastWayIn: Bool = false) -> (frame: CGRect, choice: Int)? {
    SurfaceGeometry.closedStrip(on: screen, widths: widths, requestWaiting: request, lastWayIn: lastWayIn)
}

private func panel(_ screen: SurfaceScreen, open: Bool, height: CGFloat = 320, widths: [CGFloat] = [200, 34], request: Bool = false, lastWayIn: Bool = false, around: CGFloat? = nil) -> SurfacePlacement? {
    SurfaceGeometry.panel(on: screen, widths: widths, isOpen: open, contentHeight: height, requestWaiting: request, lastWayIn: lastWayIn, around: around)
}

@Suite("Закрытая панель живёт в строке меню")
struct SurfaceStripTests {
    @Test("Она внутри строки и не выше её, так что окна ей не закрыть", arguments: [24.0, 30.0, 37.0] as [CGFloat])
    func insideTheBar(height: CGFloat) throws {
        var screen = wide
        screen.visibleFrame.size.height = screen.frame.height - height
        screen.menuBar = height
        let frame = try #require(strip(screen)).frame
        #expect(frame.maxY == screen.frame.maxY)
        #expect(frame.height == height)
        #expect(frame.minY == screen.visibleFrame.maxY)
        #expect(!frame.intersects(screen.visibleFrame))
    }

    @Test("Когда есть место, она посередине экрана")
    func centered() throws {
        let frame = try #require(strip(wide, [200.4, 34])).frame
        #expect(abs(frame.midX - wide.frame.midX) <= 0.5)
        #expect(frame.width == 201)
        // On a whole point: half of one blurs the text on a monitor without Retina.
        #expect(frame.minX == frame.minX.rounded())
    }

    @Test("Значки не задеты, а панель отступает от них влево", arguments: [1200, 1100, 1050, 1000] as [CGFloat])
    func offTheIcons(icons: CGFloat) throws {
        let screen = with(wide, icons: icons)
        let frame = try #require(strip(screen, [200])).frame
        #expect(frame.maxX <= icons)
        #expect(frame.width == 200)
    }

    @Test("Берётся самое полное, что помещается")
    func takesTheFullestThatFits() throws {
        // Between where the menus may end, 720, and the icons at 1000 there are 274 points.
        let screen = with(wide, icons: 1000)
        #expect(try #require(strip(screen, [100, 34])).choice == 0)
        #expect(try #require(strip(screen, [600, 200, 34])).choice == 1)
        #expect(try #require(strip(screen, [600, 300, 34])).choice == 2)
    }

    @Test("На заполненной строке её просто нет, а не поверх значков")
    func leftOutOnFullBar() {
        #expect(strip(with(wide, icons: 700)) == nil)
        #expect(strip(with(wide, icons: 0)) == nil)
    }

    @Test("Меню приложения оставлено место, пока это возможно")
    func offTheMenus() throws {
        let frame = try #require(strip(with(wide, icons: 1000), [270])).frame
        #expect(frame.minX >= 720)
    }

    @Test("Если это последний способ открыть Boris, узкая панель остаётся и на заполненной строке")
    func lastWayInStays() throws {
        let full = with(wide, icons: 700)
        let found = try #require(strip(full, [200, 34], lastWayIn: true))
        #expect(found.choice == 1)
        #expect(found.frame.width == 34)
        // Next to the icons: their place is known, and the end of the menus is only a guess.
        #expect(found.frame.maxX <= 700)
        #expect(found.frame.maxX >= 690)
    }

    @Test("Даже когда значки заняли всю строку, последняя панель остаётся на экране")
    func lastWayInOnScreen() throws {
        let frame = try #require(strip(with(wide, icons: 0), [34], lastWayIn: true)).frame
        #expect(wide.frame.contains(frame))
    }

    @Test("Последняя панель у значков стоит на целой точке")
    func lastWayInOnWholePoint() throws {
        let frame = try #require(strip(with(wide, icons: 700.5), [34.2], lastWayIn: true)).frame
        #expect(frame.minX == frame.minX.rounded())
        #expect(frame.maxX <= 700.5)
    }

    @Test("Запрос сам по себе панель на заполненную строку не ставит")
    func requestDoesNotCrowd() {
        #expect(strip(with(wide, icons: 700), request: true) == nil)
    }

    @Test("На узком стоячем мониторе панель помещается в короткой форме и не заходит на значки")
    func uprightMonitor() throws {
        let found = try #require(strip(upright, [400, 90, 34]))
        #expect(found.choice == 1)
        #expect(found.frame.maxX <= -480)
        #expect(upright.frame.contains(found.frame))
        #expect(found.frame.maxY == upright.frame.maxY)
        #expect(!found.frame.intersects(upright.visibleFrame))
    }

    @Test("Положение значков неизвестно: панель всё равно на экране")
    func iconsUnknown() throws {
        let frame = try #require(strip(with(wide, icons: nil))).frame
        #expect(frame.midX == wide.frame.midX)
    }

    @Test("Пустой список ширин ничего не ломает")
    func nothingOffered() {
        #expect(strip(wide, [], request: true, lastWayIn: true) == nil)
        #expect(panel(wide, open: false, widths: [], lastWayIn: true) == nil)
        #expect(panel(wide, open: true, widths: []) != nil)
    }
}

@Suite("Панель при скрытой строке меню")
struct SurfaceHiddenBarTests {
    @Test("Без запроса на экране ничего нет", arguments: [wide, upright])
    func nothingOnScreen(screen: SurfaceScreen) {
        #expect(panel(hidden(screen), open: false) == nil)
        // The last way in does not change that: the top edge of the screen stands in for it.
        #expect(panel(hidden(screen), open: false, lastWayIn: true) == nil)
    }

    @Test("Запрос раскрывает её от самого верха экрана, без полоски")
    func requestOpens() throws {
        let screen = hidden(wide)
        let found = try #require(panel(screen, open: true, request: true))
        #expect(found.strip == nil)
        #expect(found.frame.maxY == screen.frame.maxY)
        #expect(found.frame.midX == screen.frame.midX)
    }

    @Test("Свёрнутая при ждущем запросе, она остаётся узкой полоской, чтобы запрос не потерялся")
    func dismissedWithRequest() throws {
        let screen = hidden(wide)
        let found = try #require(panel(screen, open: false, widths: [900, 120, 34], request: true))
        #expect(found.strip == found.frame)
        #expect(found.choice == 1)
        #expect(found.frame.height == SurfaceGeometry.hiddenStripHeight)
        #expect(found.frame.maxY == screen.frame.maxY)
        #expect(abs(found.frame.midX - screen.frame.midX) <= 0.5)
    }

    @Test("Панель, открытая с верхнего края, стоит под курсором, где бы он ни подошёл", arguments: [wide, upright])
    func opensUnderPointer(screen: SurfaceScreen) throws {
        let bare = hidden(screen)
        var counted = 0
        // Along the whole edge, half a point at a time: wherever the edge counts as the surface, the sheet that opens has the pointer on it.
        for x in stride(from: bare.frame.minX, through: bare.frame.maxX, by: 0.5) {
            let pointer = CGPoint(x: x, y: bare.frame.maxY)
            guard SurfaceGeometry.isAtHiddenBarEdge(of: bare, pointer) else { continue }
            counted += 1
            let found = try #require(panel(bare, open: true, lastWayIn: true, around: x))
            #expect(found.holds(pointer))
            // It stays on screen, and a small move does not take the pointer off it.
            #expect(bare.frame.contains(found.frame))
            #expect(found.holds(CGPoint(x: x, y: pointer.y - 40)))
        }
        // Nearly all of the edge counts, so the loop above is not empty.
        #expect(CGFloat(counted) >= (bare.frame.width - 20) * 2)
    }

    @Test("Углы экрана верхним краем не считаются: там панели не открыться под курсором", arguments: [wide, upright])
    func cornersAreNotTheEdge(screen: SurfaceScreen) {
        let bare = hidden(screen)
        for x in [bare.frame.minX, bare.frame.minX + 1, bare.frame.minX + 7, bare.frame.maxX - 8, bare.frame.maxX - 1] {
            #expect(!SurfaceGeometry.isAtHiddenBarEdge(of: bare, CGPoint(x: x, y: bare.frame.maxY)))
        }
        #expect(SurfaceGeometry.isAtHiddenBarEdge(of: bare, CGPoint(x: bare.frame.minX + 8, y: bare.frame.maxY)))
        #expect(SurfaceGeometry.isAtHiddenBarEdge(of: bare, CGPoint(x: bare.frame.maxX - 9, y: bare.frame.maxY)))
    }

    @Test("Запрос открывает панель посередине, где бы ни был курсор")
    func requestOpensInTheMiddle() throws {
        let found = try #require(panel(hidden(wide), open: true, request: true))
        #expect(found.frame.midX == wide.frame.midX)
    }

    @Test("Высокое содержимое помещается и здесь")
    func tallContent() throws {
        let screen = hidden(wide)
        let found = try #require(panel(screen, open: true, height: 5000))
        #expect(screen.frame.contains(found.frame))
        #expect(found.frame.height == SurfaceGeometry.maximumOpenHeight(on: screen))
    }

    @Test("Верхний край считается только у скрытой строки на этом экране")
    func edge() {
        let screen = hidden(wide)
        #expect(SurfaceGeometry.isAtHiddenBarEdge(of: screen, CGPoint(x: 500, y: 1080)))
        #expect(SurfaceGeometry.isAtHiddenBarEdge(of: screen, CGPoint(x: 500, y: 1079)))
        #expect(!SurfaceGeometry.isAtHiddenBarEdge(of: screen, CGPoint(x: 500, y: 1077)))
        #expect(!SurfaceGeometry.isAtHiddenBarEdge(of: screen, CGPoint(x: -500, y: 1080)))
        #expect(!SurfaceGeometry.isAtHiddenBarEdge(of: wide, CGPoint(x: 500, y: 1080)))
        #expect(!SurfaceGeometry.isAtHiddenBarEdge(of: laptop, CGPoint(x: 500, y: 982)))
    }
}

@Suite("Открытая панель свисает из строки меню")
struct SurfaceSheetTests {
    @Test("Лист под строкой, а полоска там же, где и была", arguments: [wide, upright, with(wide, icons: 1000)])
    func sheetBelowStrip(screen: SurfaceScreen) throws {
        let closed = try #require(panel(screen, open: false, widths: [80, 34]))
        let open = try #require(panel(screen, open: true, widths: [80, 34]))
        let sheet = try #require(open.sheet)
        #expect(open.strip == closed.strip)
        #expect(sheet.maxY == screen.visibleFrame.maxY)
        #expect(open.frame.contains(sheet))
        #expect(try open.frame.contains(#require(open.strip)))
        #expect(screen.frame.contains(open.frame))
    }

    @Test("Курсор может уйти с полоски прямо вниз на лист: разрыва нет", arguments: [wide, upright, with(wide, icons: 1000)])
    func noGap(screen: SurfaceScreen) throws {
        let open = try #require(panel(screen, open: true, widths: [80, 34]))
        let stripFrame = try #require(open.strip)
        let x = stripFrame.midX
        for y in stride(from: stripFrame.maxY, through: stripFrame.minY - 40, by: -1) {
            #expect(open.holds(CGPoint(x: x, y: y)))
        }
    }

    @Test("Место рядом с полоской поверхностью не считается: курсор идёт к меню")
    func clearSpaceIsNotSurface() throws {
        let open = try #require(panel(wide, open: true, widths: [80, 34]))
        let stripFrame = try #require(open.strip)
        #expect(open.frame.width > stripFrame.width)
        #expect(open.holds(CGPoint(x: stripFrame.midX, y: stripFrame.midY)))
        #expect(!open.holds(CGPoint(x: open.frame.minX + 2, y: stripFrame.midY)))
        #expect(!open.holds(CGPoint(x: open.frame.maxX - 2, y: stripFrame.midY)))
    }

    @Test("Лист строку меню не закрывает, какой бы высоты ни был", arguments: [100, 5000] as [CGFloat])
    func barStaysUncovered(height: CGFloat) throws {
        let open = try #require(panel(wide, open: true, height: height))
        let sheet = try #require(open.sheet)
        #expect(sheet.maxY <= wide.visibleFrame.maxY)
        #expect(sheet.minY >= wide.visibleFrame.minY)
    }

    @Test("Без места в строке запрос всё равно раскрывает панель под строкой")
    func requestOnFullBar() throws {
        let full = with(wide, icons: 700)
        #expect(panel(full, open: false, request: true) == nil)
        let open = try #require(panel(full, open: true, request: true))
        #expect(open.strip == nil)
        #expect(open.frame == open.sheet)
        #expect(open.frame.maxY == full.visibleFrame.maxY)
    }

    @Test("Лист держится на экране, даже если полоска у края")
    func sheetStaysOnScreen() throws {
        let narrow = SurfaceScreen(
            id: "narrow",
            name: "Narrow",
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            visibleFrame: CGRect(x: 0, y: 0, width: 800, height: 570),
            statusIconsMinX: 500
        )
        let open = try #require(panel(narrow, open: true, widths: [100, 34]))
        #expect(narrow.frame.contains(open.frame))
        #expect(try open.holds(CGPoint(x: #require(open.strip).midX, y: narrow.visibleFrame.maxY - 1)))
    }
}

@Suite("Чёлка от строки меню не зависит")
struct SurfaceNotchStaysTests {
    @Test("С видимой и со скрытой строкой меню чёлка на месте")
    func notchIgnoresBar() throws {
        var bare = laptop
        bare.menuBar = 0
        let cutout = try #require(laptop.notch)
        let closed = SurfaceGeometry.closedNotch(on: laptop, notch: cutout, textWidth: 60, minimumWidth: 380)
        #expect(SurfaceGeometry.closedNotch(on: bare, notch: cutout, textWidth: 60, minimumWidth: 380) == closed)
        #expect(SurfaceGeometry.open(on: bare, contentHeight: 320) == SurfaceGeometry.open(on: laptop, contentHeight: 320))
        #expect(SurfaceGeometry.open(on: bare, contentHeight: 320).maxY == laptop.frame.maxY)
        #expect(SurfaceGeometry.maximumOpenHeight(on: bare) == SurfaceGeometry.maximumOpenHeight(on: laptop))
    }

    @Test("У чёлки поверхностью считается вся её рамка")
    func holdsWholeFrame() {
        let whole = SurfacePlacement(frame: CGRect(x: 0, y: 0, width: 100, height: 40))
        #expect(whole.holds(CGPoint(x: 50, y: 40)))
        #expect(!whole.holds(CGPoint(x: 50, y: 41)))
    }
}

@Suite("Панель и несколько экранов")
struct SurfaceScreensTests {
    private let cursorOnWide = CGPoint(x: 500, y: 500)
    private let cursorOnUpright = CGPoint(x: -500, y: 500)

    @Test("За курсором: панель в строке меню того экрана, где курсор")
    func followsCursor() throws {
        let screens = [wide, upright]
        let here = try #require(SurfaceGeometry.screen(for: .followCursor, among: screens, cursor: cursorOnUpright))
        let frame = try #require(strip(here, [90, 34])).frame
        #expect(upright.frame.contains(frame))
        #expect(!frame.intersects(upright.visibleFrame))
        let there = try #require(SurfaceGeometry.screen(for: .followCursor, among: screens, cursor: cursorOnWide))
        #expect(try wide.frame.contains(#require(strip(there)).frame))
    }

    @Test("На один экран строка скрыта, на другой нет: каждый решает за себя")
    func eachScreenForItself() throws {
        let screens = [wide, hidden(upright)]
        let onUpright = try #require(SurfaceGeometry.screen(for: .followCursor, among: screens, cursor: cursorOnUpright))
        #expect(panel(onUpright, open: false) == nil)
        let onWide = try #require(SurfaceGeometry.screen(for: .followCursor, among: screens, cursor: cursorOnWide))
        #expect(panel(onWide, open: false) != nil)
    }

    @Test("Отключённый экран уступает основному, и панель там в его строке меню")
    func disconnected() throws {
        let choice = SurfaceScreenChoice.screen(id: "upright", name: "Upright")
        let here = try #require(SurfaceGeometry.screen(for: choice, among: [wide], cursor: .zero))
        #expect(here.id == "wide")
        let frame = try #require(strip(here)).frame
        #expect(frame.maxY == wide.frame.maxY)
        #expect(!frame.intersects(wide.visibleFrame))
    }

    @Test("С выбранным экраном панель там, а курсор ни при чём")
    func chosenScreen() throws {
        let choice = SurfaceScreenChoice.screen(id: "upright", name: "Upright")
        let here = try #require(SurfaceGeometry.screen(for: choice, among: [wide, upright], cursor: cursorOnWide))
        #expect(try upright.frame.contains(#require(strip(here, [90, 34])).frame))
    }
}

@Suite("Что известно о строке меню")
struct MenuBarReadingTests {
    /// The list counts from the top left of the primary screen. Both screens here have their top at its zero.
    private let bar = ScreenWindow(number: 1, layer: MenuBarReading.barLayer, bounds: CGRect(x: 0, y: 0, width: 1920, height: 30))
    private let uprightBar = ScreenWindow(number: 2, layer: MenuBarReading.barLayer, bounds: CGRect(x: -1080, y: 0, width: 1080, height: 30))

    private func icon(_ number: Int, x: CGFloat, width: CGFloat = 38) -> ScreenWindow {
        ScreenWindow(number: number, layer: MenuBarReading.iconLayer, bounds: CGRect(x: x, y: 0, width: width, height: 30))
    }

    private func read(_ screen: SurfaceScreen, _ windows: [ScreenWindow]) -> MenuBarReading {
        MenuBarReading(frame: screen.frame, visibleFrame: screen.visibleFrame, primaryHeight: wide.frame.height, windows: windows)
    }

    @Test("Видимая строка: её высота и начало значков")
    func visible() {
        let reading = read(wide, [bar, icon(3, x: 1500), icon(4, x: 1300), icon(5, x: 1700)])
        #expect(reading.height == 30)
        #expect(reading.iconsMinX == 1300)
    }

    @Test("У каждого экрана своя строка и свои значки")
    func twoScreens() {
        let windows = [bar, uprightBar, icon(3, x: 1300), icon(4, x: -400), icon(5, x: -300)]
        #expect(read(wide, windows).iconsMinX == 1300)
        #expect(read(upright, windows).iconsMinX == -400)
        #expect(read(upright, windows).height == 30)
    }

    @Test("Экран ниже основного считается от верха основного")
    func screenBelow() {
        let below = SurfaceScreen(
            id: "below",
            name: "Below",
            frame: CGRect(x: 0, y: -1080, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 0, y: -1080, width: 1920, height: 1050)
        )
        let itsBar = ScreenWindow(number: 2, layer: MenuBarReading.barLayer, bounds: CGRect(x: 0, y: 1080, width: 1920, height: 30))
        let itsIcon = ScreenWindow(number: 3, layer: MenuBarReading.iconLayer, bounds: CGRect(x: 1400, y: 1080, width: 40, height: 30))
        #expect(read(below, [bar, itsBar, icon(4, x: 1000), itsIcon]).iconsMinX == 1400)
        #expect(read(wide, [bar, itsBar, icon(4, x: 1000), itsIcon]).iconsMinX == 1000)
    }

    @Test("Автоскрытие: окнам отдан весь экран, значит строки нет")
    func autoHide() {
        let reading = read(hidden(wide), [bar, icon(3, x: 1300)])
        #expect(reading.height == 0)
        #expect(reading.iconsMinX == nil)
    }

    @Test("Приложение на весь экран: строки нет, хотя место за ней числится")
    func fullScreenApp() {
        let app = ScreenWindow(number: 9, layer: MenuBarReading.normalLayer, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let reading = read(wide, [bar, icon(3, x: 1300), app])
        #expect(reading.height == 0)
        #expect(reading.iconsMinX == nil)
    }

    @Test("Два приложения рядом на весь экран: строки тоже нет")
    func splitView() {
        let left = ScreenWindow(number: 9, layer: MenuBarReading.normalLayer, bounds: CGRect(x: 0, y: 0, width: 955, height: 1080))
        let right = ScreenWindow(number: 10, layer: MenuBarReading.normalLayer, bounds: CGRect(x: 965, y: 0, width: 955, height: 1080))
        let reading = read(wide, [bar, icon(3, x: 1300), left, right])
        #expect(reading.height == 0)
        #expect(reading.iconsMinX == nil)
    }

    @Test("Окно от самого верха, но не на весь экран, строку не прячет")
    func partOfTheScreen() {
        let helper = ScreenWindow(number: 9, layer: MenuBarReading.normalLayer, bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        let sidebar = ScreenWindow(number: 10, layer: MenuBarReading.normalLayer, bounds: CGRect(x: 0, y: 0, width: 300, height: 1080))
        let wideButShort = ScreenWindow(number: 11, layer: MenuBarReading.normalLayer, bounds: CGRect(x: 0, y: 0, width: 1920, height: 400))
        #expect(read(wide, [bar, helper, sidebar, wideButShort]).height == 30)
    }

    @Test("Несколько окон поверх друг друга не считаются за один экран, если соседнему экрану они не мешают")
    func windowsElsewhereDoNotCount() {
        let there = ScreenWindow(number: 9, layer: MenuBarReading.normalLayer, bounds: CGRect(x: -1080, y: 0, width: 1080, height: 1080))
        #expect(read(wide, [bar, there]).height == 30)
    }

    @Test("Щель в пару точек наверху это ещё не строка меню")
    func sliverIsNoBar() {
        var screen = wide
        screen.visibleFrame.size.height = screen.frame.height - 1
        #expect(read(screen, [bar, icon(3, x: 1300)]).height == 0)
        #expect(read(screen, []).height == 0)
    }

    @Test("Обычное окно до самой строки меню полным экраном не считается")
    func ordinaryWindow() {
        let app = ScreenWindow(number: 9, layer: MenuBarReading.normalLayer, bounds: CGRect(x: 0, y: 30, width: 1920, height: 1050))
        #expect(read(wide, [bar, app]).height == 30)
    }

    @Test("Приложение на весь соседний экран строку этого не прячет")
    func fullScreenElsewhere() {
        let app = ScreenWindow(number: 9, layer: MenuBarReading.normalLayer, bounds: CGRect(x: -1080, y: 0, width: 1080, height: 1920))
        let windows = [bar, uprightBar, app]
        #expect(read(wide, windows).height == 30)
        #expect(read(upright, windows).height == 0)
    }

    @Test("Окно строки меню за верхним краем: она спрятана")
    func barAboveTheEdge() {
        let away = ScreenWindow(number: 1, layer: MenuBarReading.barLayer, bounds: CGRect(x: 0, y: -30, width: 1920, height: 30))
        #expect(read(wide, [away]).height == 0)
    }

    @Test("Строка есть только на другом экране: на этом её нет")
    func barOnlyElsewhere() {
        #expect(read(upright, [bar, icon(3, x: 1300)]).height == 0)
    }

    @Test("Список не прочитался: остаётся то, что говорит экран")
    func listUnread() {
        let reading = read(wide, [])
        #expect(reading.height == 30)
        #expect(reading.iconsMinX == nil)
        #expect(read(hidden(wide), []).height == 0)
    }

    @Test("Высота не больше места, которое строка занимает у окон")
    func notTallerThanReserved() {
        let tall = ScreenWindow(number: 1, layer: MenuBarReading.barLayer, bounds: CGRect(x: 0, y: 0, width: 1920, height: 44))
        #expect(read(wide, [tall]).height == 30)
    }

    @Test("Значками не считается то, что значком не является")
    func notIcons() {
        let anchor = ScreenWindow(number: 3, layer: MenuBarReading.iconLayer, bounds: CGRect(x: 100, y: 0, width: 1, height: 1))
        let tall = ScreenWindow(number: 4, layer: MenuBarReading.iconLayer, bounds: CGRect(x: 200, y: 0, width: 300, height: 400))
        let lower = ScreenWindow(number: 5, layer: MenuBarReading.iconLayer, bounds: CGRect(x: 300, y: 200, width: 40, height: 30))
        let offScreen = ScreenWindow(number: 6, layer: MenuBarReading.iconLayer, bounds: CGRect(x: 1900, y: 0, width: 40, height: 30))
        let ordinary = ScreenWindow(number: 7, layer: MenuBarReading.normalLayer, bounds: CGRect(x: 400, y: 0, width: 40, height: 30))
        #expect(read(wide, [bar, anchor, tall, lower, offScreen, ordinary]).iconsMinX == nil)
        #expect(read(wide, [bar, anchor, icon(8, x: 1500)]).iconsMinX == 1500)
    }

    @Test("Прочитанное кладётся на экран и доходит до панели")
    func readingReachesThePanel() throws {
        let reading = read(wide, [bar, icon(3, x: 1000), icon(4, x: 1200)])
        let screen = SurfaceScreen(id: "a", name: "A", frame: wide.frame, visibleFrame: wide.visibleFrame, menuBar: reading.height, statusIconsMinX: reading.iconsMinX)
        #expect(try #require(strip(screen, [200])).frame.maxX <= 1000)
    }
}

@Suite("Что говорит полоска в строке меню")
struct SurfaceStripWordsTests {
    @Test("От полного к короткому, а в конце морж один, без повторов")
    func fromFullToNarrow() {
        let simple = SurfaceWords.stripLines(SurfaceNumbers(waiting: 1, agents: 3), mode: .simple, spoken: nil)
        #expect(simple == [
            SurfaceLine(main: "3 agents at work", waiting: "1 needs you"),
            SurfaceLine(main: "3 agents", waiting: "1 needs you"),
            SurfaceLine(waiting: "1 needs you"),
            SurfaceLine(),
        ])
    }

    @Test("Работают без ожидающих: короткая форма не теряет число")
    func working() {
        let lines = SurfaceWords.stripLines(SurfaceNumbers(agents: 3), mode: .simple, spoken: nil)
        #expect(lines == [SurfaceLine(main: "3 agents at work"), SurfaceLine(main: "3 agents"), SurfaceLine()])
    }

    @Test("Тихо")
    func quiet() {
        #expect(SurfaceWords.stripLines(SurfaceNumbers(), mode: .simple, spoken: nil) == [SurfaceLine(main: "Quiet"), SurfaceLine()])
    }

    @Test("Технический режим уступает числа, но не того, кто ждёт")
    func technical() {
        let lines = SurfaceWords.stripLines(SurfaceNumbers(waiting: 1, agents: 3, tokensToday: 1_840_000), mode: .technical, spoken: nil)
        #expect(lines == [
            SurfaceLine(main: "3 agents · 1.84M", waiting: "1 needs you"),
            SurfaceLine(main: "3 agents", waiting: "1 needs you"),
            SurfaceLine(waiting: "1 needs you"),
            SurfaceLine(),
        ])
    }

    @Test("Реплика первая, а числа остаются ей на замену")
    func spoken() {
        let lines = SurfaceWords.stripLines(SurfaceNumbers(agents: 1), mode: .simple, spoken: "Hello")
        #expect(lines.first == SurfaceLine(main: "Hello"))
        #expect(lines.contains(SurfaceLine(main: "1 agent at work")))
        #expect(lines.last == SurfaceLine())
    }
}
