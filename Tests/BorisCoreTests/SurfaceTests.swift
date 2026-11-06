import BorisCore
import CoreGraphics
import Foundation
import Testing

/// A laptop with a notch, as the main screen.
private let laptop = SurfaceScreen(
    id: "laptop",
    name: "Built-in",
    frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
    visibleFrame: CGRect(x: 0, y: 70, width: 1512, height: 875),
    notch: CGRect(x: 664, y: 945, width: 184, height: 37)
)

/// An external monitor to the left of it and lower, so its coordinates go below zero.
private let monitor = SurfaceScreen(
    id: "monitor",
    name: "Monitor",
    frame: CGRect(x: -1920, y: -200, width: 1920, height: 1080),
    visibleFrame: CGRect(x: -1920, y: -200, width: 1920, height: 1056)
)

private let tiny = SurfaceScreen(
    id: "tiny",
    name: "Tiny",
    frame: CGRect(x: 0, y: 0, width: 400, height: 300),
    visibleFrame: CGRect(x: 0, y: 0, width: 400, height: 276)
)

@Suite("Положение чёлки и панели")
struct SurfaceGeometryTests {
    @Test("Вырез считается по ширинам областей рядом с ним, на любом экране")
    func notchFromScreen() {
        let frame = CGRect(x: 100, y: 50, width: 1512, height: 982)
        let notch = SurfaceScreen.notch(frame: frame, topInset: 37, leftWidth: 664, rightWidth: 664)
        #expect(notch == CGRect(x: 764, y: 995, width: 184, height: 37))
    }

    @Test("Экран без выреза не даёт выреза")
    func noNotch() {
        let frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        #expect(SurfaceScreen.notch(frame: frame, topInset: 0, leftWidth: nil, rightWidth: nil) == nil)
        #expect(SurfaceScreen.notch(frame: frame, topInset: 24, leftWidth: nil, rightWidth: nil) == nil)
        #expect(SurfaceScreen.notch(frame: frame, topInset: 37, leftWidth: 960, rightWidth: 960) == nil)
    }

    @Test("Выбор экрана: основной, конкретный, за курсором")
    func choice() {
        let screens = [laptop, monitor]
        let onMonitor = CGPoint(x: -500, y: 300)
        #expect(SurfaceGeometry.screen(for: .main, among: screens, cursor: onMonitor)?.id == "laptop")
        #expect(SurfaceGeometry.screen(for: .followCursor, among: screens, cursor: onMonitor)?.id == "monitor")
        #expect(SurfaceGeometry.screen(for: .followCursor, among: screens, cursor: CGPoint(x: 500, y: 300))?.id == "laptop")
        #expect(SurfaceGeometry.screen(for: .screen(id: "monitor", name: "Monitor"), among: screens, cursor: .zero)?.id == "monitor")
    }

    @Test("Курсор у самого верхнего края считается на своём экране")
    func cursorAtTopEdge() {
        let top = CGPoint(x: -500, y: monitor.frame.maxY)
        #expect(SurfaceGeometry.screen(for: .followCursor, among: [laptop, monitor], cursor: top)?.id == "monitor")
        let notchEdge = CGPoint(x: 700, y: laptop.frame.maxY)
        #expect(SurfaceGeometry.screen(for: .followCursor, among: [monitor, laptop], cursor: notchEdge)?.id == "laptop")
    }

    @Test("Курсор на границе двух экранов попадает ровно на один")
    func cursorBetweenScreens() {
        let border = CGPoint(x: 0, y: 300)
        #expect(SurfaceGeometry.contains(laptop.frame, border))
        #expect(!SurfaceGeometry.contains(monitor.frame, border))
    }

    @Test("Отключённый экран уступает основному, а вернувшийся снова выбран")
    func disconnected() {
        let choice = SurfaceScreenChoice.screen(id: "monitor", name: "Monitor")
        #expect(SurfaceGeometry.screen(for: choice, among: [laptop], cursor: .zero)?.id == "laptop")
        #expect(SurfaceGeometry.screen(for: choice, among: [laptop, monitor], cursor: .zero)?.id == "monitor")
    }

    @Test("Курсор вне всех экранов и отсутствие экранов ничего не ломают")
    func nothingToChoose() {
        #expect(SurfaceGeometry.screen(for: .followCursor, among: [laptop, monitor], cursor: CGPoint(x: 9000, y: 9000))?.id == "laptop")
        #expect(SurfaceGeometry.screen(for: .main, among: [], cursor: .zero) == nil)
        #expect(SurfaceGeometry.screen(for: .followCursor, among: [], cursor: .zero) == nil)
    }

    private func notch(_ screen: SurfaceScreen = laptop) -> CGRect {
        screen.notch ?? .zero
    }

    @Test("Закрытая чёлка: морж слева от выреза, текст справа, край к краю с вырезом")
    func closedNotchAroundCutout() {
        let closed = SurfaceGeometry.closedNotch(on: laptop, notch: notch(), textWidth: 60, minimumWidth: 380)
        #expect(closed.frame.minX + closed.left == notch().minX)
        #expect(closed.frame.minX + closed.left + closed.cutout == notch().maxX)
        #expect(closed.frame.maxY == laptop.frame.maxY)
        #expect(closed.frame.height == notch().height)
        #expect(closed.frame.width == closed.left + closed.cutout + closed.right)
    }

    @Test("Короткий текст: чёлка симметрична и шириной из макета")
    func closedNotchKeepsDesignWidth() {
        let closed = SurfaceGeometry.closedNotch(on: laptop, notch: notch(), textWidth: 60, minimumWidth: 380)
        #expect(closed.frame.width == 380)
        #expect(closed.left == closed.right)
        #expect(closed.frame.midX == notch().midX)
    }

    @Test("Длинный текст не уходит за вырез: растёт только правая сторона")
    func closedNotchGrowsForText() {
        let closed = SurfaceGeometry.closedNotch(on: laptop, notch: notch(), textWidth: 240, minimumWidth: 380)
        #expect(closed.right >= 240)
        #expect(closed.left == 98)
    }

    @Test("Очень длинный текст останавливается у края экрана")
    func closedNotchStaysOnScreen() {
        let closed = SurfaceGeometry.closedNotch(on: laptop, notch: notch(), textWidth: 5000, minimumWidth: 380)
        #expect(closed.frame.maxX == laptop.frame.maxX)
        #expect(laptop.frame.contains(closed.frame))
    }

    @Test("Морж помещается, даже если вырез шире заданной ширины")
    func closedNotchRoomForWalrus() {
        let closed = SurfaceGeometry.closedNotch(on: laptop, notch: notch(), textWidth: 10, minimumWidth: 100)
        #expect(closed.left >= 44)
    }

    @Test("Открытая чёлка начинается у самого верха и стоит по центру выреза")
    func openNotch() {
        let frame = SurfaceGeometry.open(on: laptop, contentHeight: 320)
        #expect(frame.width == SurfaceGeometry.openNotchWidth)
        #expect(frame.maxY == laptop.frame.maxY)
        #expect(frame.midX == notch().midX)
        #expect(frame.height == 320)
    }

    @Test("Открытая панель под строкой меню, а не на ней")
    func openPanel() {
        let frame = SurfaceGeometry.open(on: monitor, contentHeight: 320)
        #expect(frame.width == SurfaceGeometry.openPanelWidth)
        #expect(frame.maxY == monitor.visibleFrame.maxY)
        #expect(frame.midX == monitor.frame.midX)
    }

    @Test("Высокое содержимое не вылезает за экран и Dock", arguments: [laptop, monitor, tiny])
    func tallContentFits(screen: SurfaceScreen) {
        let frame = SurfaceGeometry.open(on: screen, contentHeight: 5000)
        #expect(screen.frame.contains(frame))
        #expect(frame.minY >= screen.visibleFrame.minY)
        #expect(frame.height == SurfaceGeometry.maximumOpenHeight(on: screen))
    }

    @Test("На маленьком экране открытая поверхность сужается")
    func openOnSmallScreen() {
        let frame = SurfaceGeometry.open(on: tiny, contentHeight: 100)
        #expect(frame.width < SurfaceGeometry.openPanelWidth)
        #expect(tiny.frame.contains(frame))
    }

    @Test("Вырез у края экрана не выталкивает открытую чёлку за экран")
    func openNotchNearEdge() {
        let screen = SurfaceScreen(
            id: "odd",
            name: "Odd",
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            visibleFrame: CGRect(x: 0, y: 0, width: 800, height: 560),
            notch: CGRect(x: 40, y: 560, width: 100, height: 40)
        )
        #expect(screen.frame.contains(SurfaceGeometry.open(on: screen, contentHeight: 200)))
    }

    @Test("Выбор экрана переживает сохранение")
    func choiceSurvivesSaving() throws {
        for choice in [SurfaceScreenChoice.followCursor, .main, .screen(id: "abc", name: "Monitor")] {
            let data = try JSONEncoder().encode(choice)
            #expect(try JSONDecoder().decode(SurfaceScreenChoice.self, from: data) == choice)
        }
    }
}

@Suite("Защита последней поверхности")
struct SurfaceSwitchesTests {
    @Test("Пока есть другие, можно выключить любую")
    func anyWhileOthersStay() {
        for surface in Surface.allCases {
            #expect(SurfaceSwitches().canTurnOff(surface, hotKeyWorks: true))
        }
    }

    @Test("Последнюю выключить нельзя", arguments: Surface.allCases)
    func lastOneStays(surface: Surface) {
        var switches = SurfaceSwitches(icon: false, notch: false, mini: false)
        switches[surface] = true
        #expect(!switches.canTurnOff(surface, hotKeyWorks: true))
    }

    @Test("Чёлку можно выключить, значок и мини-окно остаются")
    func notchOff() {
        var switches = SurfaceSwitches()
        switches.notch = false
        #expect(switches.icon && switches.mini)
        #expect(switches.canTurnOff(.icon, hotKeyWorks: true))
        #expect(switches.canTurnOff(.mini, hotKeyWorks: true))
    }

    @Test("Без рабочей клавиши мини-окно не считается способом открыть Boris")
    func miniNeedsHotKey() {
        let switches = SurfaceSwitches(icon: true, notch: false, mini: true)
        #expect(!switches.canTurnOff(.icon, hotKeyWorks: false))
        #expect(switches.canTurnOff(.icon, hotKeyWorks: true))
        #expect(switches.canTurnOff(.mini, hotKeyWorks: false))
    }

    @Test("Если клавиша перестала работать и ничего не осталось, значок возвращается")
    func iconComesBack() {
        let stranded = SurfaceSwitches(icon: false, notch: false, mini: true)
        #expect(stranded.withWayIn(hotKeyWorks: true) == stranded)
        #expect(stranded.withWayIn(hotKeyWorks: false) == SurfaceSwitches(icon: true, notch: false, mini: true))
    }

    @Test("Рабочие настройки при проверке не меняются")
    func healthyStaysAsIs() {
        let switches = SurfaceSwitches(icon: false, notch: true, mini: false)
        #expect(switches.withWayIn(hotKeyWorks: false) == switches)
    }

    @Test("Выбор поверхностей переживает сохранение")
    func survivesSaving() throws {
        let switches = SurfaceSwitches(icon: false, notch: true, mini: false)
        let data = try JSONEncoder().encode(switches)
        #expect(try JSONDecoder().decode(SurfaceSwitches.self, from: data) == switches)
    }
}

@Suite("Когда чёлка открыта")
struct SurfaceBehaviorTests {
    @Test("Наведение раскрывает, уход сворачивает")
    func hover() {
        var behavior = SurfaceBehavior()
        #expect(!behavior.isOpen)
        behavior.pointerEntered()
        #expect(behavior.isOpen)
        behavior.pointerLeft()
        #expect(!behavior.isOpen)
    }

    @Test("Новый запрос раскрывает без наведения")
    func newRequest() {
        var behavior = SurfaceBehavior()
        behavior.requestsChanged(to: 1, quiet: false)
        #expect(behavior.isOpen)
    }

    @Test("Ответ на последний запрос сворачивает")
    func answered() {
        var behavior = SurfaceBehavior()
        behavior.requestsChanged(to: 2, quiet: false)
        behavior.requestsChanged(to: 1, quiet: false)
        #expect(behavior.isOpen)
        behavior.requestsChanged(to: 0, quiet: false)
        #expect(!behavior.isOpen)
    }

    @Test("Пока курсор на чёлке, ответ её не сворачивает")
    func answeredWhilePointing() {
        var behavior = SurfaceBehavior()
        behavior.requestsChanged(to: 1, quiet: false)
        behavior.pointerEntered()
        behavior.requestsChanged(to: 0, quiet: false)
        #expect(behavior.isOpen)
        behavior.pointerLeft()
        #expect(!behavior.isOpen)
    }

    @Test("Убрав курсор, человек сворачивает её и при ожидающем запросе, а новый запрос снова раскрывает")
    func dismissedWithRequestWaiting() {
        var behavior = SurfaceBehavior()
        behavior.requestsChanged(to: 1, quiet: false)
        behavior.pointerEntered()
        behavior.pointerLeft()
        #expect(!behavior.isOpen)
        behavior.requestsChanged(to: 1, quiet: false)
        #expect(!behavior.isOpen)
        behavior.requestsChanged(to: 2, quiet: false)
        #expect(behavior.isOpen)
    }

    @Test("Курсор, только пролетевший над открытой карточкой, её не сворачивает")
    func crossedTooFastToCount() {
        var behavior = SurfaceBehavior()
        behavior.requestsChanged(to: 1, quiet: false)
        // Left before the pause on the way in was over, so "entered" never came.
        behavior.pointerLeft()
        #expect(behavior.isOpen)
        behavior.pointerEntered()
        behavior.pointerLeft()
        #expect(!behavior.isOpen)
    }

    @Test("В режиме «не беспокоить» запрос не раскрывает чёлку")
    func quiet() {
        var behavior = SurfaceBehavior()
        behavior.requestsChanged(to: 1, quiet: true)
        #expect(!behavior.isOpen)
    }

    @Test("Пока человек пишет в карточке, уход курсора не сворачивает")
    func typing() {
        var behavior = SurfaceBehavior()
        behavior.pointerEntered()
        behavior.typingChanged(true)
        behavior.pointerLeft()
        #expect(behavior.isOpen)
        behavior.requestsChanged(to: 0, quiet: false)
        #expect(behavior.isOpen)
        behavior.typingChanged(false)
        #expect(!behavior.isOpen)
    }

    @Test("С последней карточкой исчезает и поле: уже убранный курсор больше ничего не держит")
    func typingEndsWithLastCard() {
        var behavior = SurfaceBehavior()
        behavior.requestsChanged(to: 1, quiet: false)
        behavior.pointerEntered()
        behavior.typingChanged(true)
        behavior.pointerLeft()
        #expect(behavior.isOpen)
        behavior.requestsChanged(to: 0, quiet: false)
        #expect(!behavior.isOpen)
    }

    @Test("Последняя карточка ушла под курсором: чёлка открыта, пока он не уйдёт")
    func typingEndsWithLastCardUnderPointer() {
        var behavior = SurfaceBehavior()
        behavior.requestsChanged(to: 1, quiet: false)
        behavior.pointerEntered()
        behavior.typingChanged(true)
        behavior.requestsChanged(to: 0, quiet: false)
        #expect(behavior.isOpen)
        behavior.pointerLeft()
        #expect(!behavior.isOpen)
    }

    @Test("Конец ввода под курсором не сворачивает")
    func typingEndsWhilePointing() {
        var behavior = SurfaceBehavior()
        behavior.pointerEntered()
        behavior.typingChanged(true)
        behavior.typingChanged(false)
        #expect(behavior.isOpen)
    }
}

@Suite("Слова чёлки и панели")
struct SurfaceWordsTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let utc = TimeZone(identifier: "UTC") ?? .current

    private var usage: UsageSnapshot {
        UsageSnapshot(windows: [
            UsageWindow(id: "five_hour", kind: .fiveHour, percent: 62, resetsAt: now.addingTimeInterval(600)),
            UsageWindow(id: "seven_day", kind: .week, percent: 34),
            UsageWindow(id: "extra", kind: .extraSpend, percent: 10),
        ])
    }

    @Test("Простой режим: сколько работает")
    func simpleWorking() {
        let numbers = SurfaceNumbers(agents: 3, tokensToday: 1_840_000, usage: usage)
        #expect(SurfaceWords.closedLine(numbers, mode: .simple, onNotch: true) == SurfaceLine(main: "3 agents at work"))
        #expect(SurfaceWords.closedLine(SurfaceNumbers(agents: 1), mode: .simple, onNotch: true).main == "1 agent at work")
    }

    @Test("Простой режим: у выреза ждущий один занимает место, на панели рядом с работающими")
    func simpleWaiting() {
        let numbers = SurfaceNumbers(waiting: 1, agents: 3)
        #expect(SurfaceWords.closedLine(numbers, mode: .simple, onNotch: true) == SurfaceLine(waiting: "1 needs you"))
        #expect(SurfaceWords.closedLine(numbers, mode: .simple, onNotch: false) == SurfaceLine(main: "3 agents at work", waiting: "1 needs you"))
        #expect(SurfaceWords.closedLine(SurfaceNumbers(waiting: 2), mode: .simple, onNotch: false) == SurfaceLine(waiting: "2 need you"))
    }

    @Test("Ничего не идёт")
    func nothing() {
        #expect(SurfaceWords.closedLine(SurfaceNumbers(), mode: .simple, onNotch: true) == SurfaceLine(main: "Quiet"))
        #expect(SurfaceWords.closedLine(SurfaceNumbers(), mode: .technical, onNotch: true) == SurfaceLine(main: "Quiet"))
    }

    @Test("Технический режим добавляет токены, лимит и контекст")
    func technical() {
        let numbers = SurfaceNumbers(agents: 3, tokensToday: 1_840_000, usage: usage, context: .init(name: "boris", tokens: 128_000))
        #expect(SurfaceWords.closedLine(numbers, mode: .technical, onNotch: true) == SurfaceLine(main: "3 agents · 1.84M · 5 h 62% · ctx 128K"))
    }

    @Test("Технический режим не прячет того, кто ждёт")
    func technicalWaiting() {
        let line = SurfaceWords.closedLine(SurfaceNumbers(waiting: 1, tokensToday: 500), mode: .technical, onNotch: true)
        #expect(line == SurfaceLine(main: "500", waiting: "1 needs you"))
    }

    @Test("Ряд чисел показывает только то, что известно")
    func numbersRow() {
        let full = SurfaceNumbers(agents: 3, tokensToday: 1_840_000, usage: usage, context: .init(name: "boris", tokens: 128_000))
        let parts = SurfaceWords.numbersRow(full, now: now, timeZone: utc)
        #expect(parts.count == 4)
        #expect(parts[0] == "Today 1.84M")
        #expect(parts[1].hasPrefix("5 h 62%, resets at "))
        #expect(parts[2] == "Week 34%")
        #expect(parts[3] == "Context boris 128K")
        #expect(SurfaceWords.numbersRow(SurfaceNumbers(), now: now).isEmpty)
    }

    @Test("Длинное имя сессии не съедает число контекста")
    func longContextName() {
        let name = String(repeating: "Отчёт за квартал ", count: 8)
        let parts = SurfaceWords.numbersRow(SurfaceNumbers(context: .init(name: name, tokens: 128_000)), now: now, timeZone: utc)
        #expect(parts.count == 1)
        #expect(parts[0].hasSuffix(" 128K"))
        #expect(parts[0].count < 50)
    }

    @Test("Ширина из макета по состоянию")
    func designWidths() {
        #expect(SurfaceWords.closedNotchWidth(SurfaceNumbers(), mode: .simple) == 300)
        #expect(SurfaceWords.closedNotchWidth(SurfaceNumbers(), mode: .technical) == 300)
        #expect(SurfaceWords.closedNotchWidth(SurfaceNumbers(agents: 3), mode: .simple) == 380)
        #expect(SurfaceWords.closedNotchWidth(SurfaceNumbers(waiting: 1), mode: .simple) == 380)
        #expect(SurfaceWords.closedNotchWidth(SurfaceNumbers(agents: 3), mode: .technical) == 460)
    }

    @Test("Самый полный контекст берётся только из того, что работает")
    func fullestContext() {
        let working = WorkSession(id: "a", cwd: "/x/one", state: .running, root: WorkNode(id: "a", kind: .main, state: .running, children: [
            WorkNode(id: "a1", kind: .subagent, state: .running, contextTokens: 50_000),
            WorkNode(id: "a2", kind: .subagent, state: .finished, contextTokens: 900_000),
        ]))
        let finished = WorkSession(id: "b", cwd: "/x/two", state: .finished, root: WorkNode(id: "b", kind: .main, state: .finished, contextTokens: 800_000))
        let numbers = SurfaceNumbers(work: WorkModel(projects: [WorkProject(path: "/x", sessions: [working, finished])]), requests: 2, today: TokenUsage(input: 5), usage: nil)
        #expect(numbers.context == .init(name: "one", tokens: 50_000))
        #expect(numbers.waiting == 2)
        #expect(numbers.agents == 2)
        #expect(numbers.tokensToday == 5)
    }

    @Test("Строка сессии: простой режим без инструментов, технический с ними")
    func sessionDetail() {
        let waiting = WorkSession(id: "a", environment: .vsCode, cwd: "/x/one", state: .waiting, waitingFor: .permission(tool: "Bash"), root: WorkNode(id: "a", kind: .main, state: .waiting))
        #expect(SurfaceWords.sessionDetail(waiting, mode: .simple) == "VS Code · waiting for you")
        #expect(SurfaceWords.sessionDetail(waiting, mode: .technical) == "VS Code · Bash is waiting for permission")
        let running = WorkSession(id: "b", environment: .terminal, cwd: "/x/two", state: .running, root: WorkNode(id: "b", kind: .main, state: .running, step: StepBrief(kind: .edit, tool: "Edit", fileName: "a.swift")))
        #expect(SurfaceWords.sessionDetail(running, mode: .simple) == "Terminal · editing a.swift")
        #expect(SurfaceWords.sessionDetail(running, mode: .technical) == "Terminal · Edit a.swift")
    }

    @Test("Пока логи читаются в первый раз, токенов не ноль, а нет данных")
    func tokensNotKnownYet() {
        let unknown = SurfaceNumbers(work: WorkModel(), requests: 0, today: nil, usage: nil)
        #expect(unknown.tokensToday == nil)
        #expect(SurfaceWords.numbersRow(unknown, now: now) == ["Today no data"])
        // The closed notch has no room to say what has no data, so it says nothing about it.
        #expect(SurfaceWords.closedLine(SurfaceNumbers(agents: 2, tokensToday: nil), mode: .technical, onNotch: true).main == "2 agents")
        let known = SurfaceNumbers(work: WorkModel(), requests: 0, today: TokenUsage(), usage: nil)
        #expect(known.tokensToday == 0)
        #expect(SurfaceWords.numbersRow(known, now: now).isEmpty)
    }

    @Test("Справа: сколько ждёт, а в техническом режиме и сколько потратила")
    func sessionTrailing() {
        let waiting = WorkSession(id: "a", state: .waiting, startedAt: now.addingTimeInterval(-3000), lastActivity: now.addingTimeInterval(-420), root: WorkNode(id: "a", kind: .main, state: .waiting))
        #expect(SurfaceWords.sessionTrailing(waiting, mode: .simple, now: now) == "7 min")
        // The root holds the whole session, its agents included, so they must not be counted twice.
        let running = WorkSession(id: "b", state: .running, root: WorkNode(id: "b", kind: .main, state: .running, tokens: TokenUsage(input: 80_000, output: 4_200), children: [
            WorkNode(id: "b1", kind: .subagent, state: .running, tokens: TokenUsage(output: 4_200)),
        ]))
        #expect(SurfaceWords.sessionTrailing(running, mode: .simple, now: now) == "")
        #expect(SurfaceWords.sessionTrailing(running, mode: .technical, now: now) == "84.2K")
        // Before the first pass over the logs only what its agents metered live is known.
        let metered = WorkSession(id: "m", state: .running, root: WorkNode(id: "m", kind: .main, state: .running, children: [
            WorkNode(id: "m1", kind: .subagent, state: .running, tokens: TokenUsage(input: 1_000)),
            WorkNode(id: "m2", kind: .subagent, state: .running, tokens: TokenUsage(output: 500)),
        ]))
        #expect(SurfaceWords.sessionTrailing(metered, mode: .technical, now: now) == "1.5K")
        let empty = WorkSession(id: "c", state: .running, root: WorkNode(id: "c", kind: .main, state: .running))
        #expect(SurfaceWords.sessionTrailing(empty, mode: .technical, now: now) == "")
    }

    private func work(_ sessions: WorkSession...) -> WorkModel {
        WorkModel(projects: [WorkProject(path: "/x", sessions: sessions)])
    }

    private func failed(_ id: String = "a", at: TimeInterval = -60, failure: FailureInfo?, title: String? = "Migrations") -> WorkSession {
        WorkSession(id: id, cwd: "/x/\(id)", state: .finished, lastActivity: now.addingTimeInterval(at), root: WorkNode(id: id, kind: .main, state: .finished, children: [
            WorkNode(id: "\(id)1", kind: .subagent, title: title, state: .failed, failure: failure),
        ]))
    }

    @Test("Последний сбой простыми словами и техническими")
    func failureWords() {
        let session = failed(failure: FailureInfo(failureClass: .limit, resets: "18:40"))
        let simple = SurfaceWords.lastFailure(in: work(session), mode: .simple, now: now)
        #expect(simple?.name == "a")
        #expect(simple?.nameIsFolder == true)
        #expect(simple?.who == "helper “Migrations”")
        #expect(simple?.what == "Did not work out: the limit ran out, resets 18:40")
        let technical = SurfaceWords.lastFailure(in: work(session), mode: .technical, now: now)
        #expect(technical?.who == "subagent “Migrations”")
        #expect(technical?.what == "Limit reached, resets 18:40")
    }

    @Test("Берётся самый свежий сбой")
    func latestFailure() {
        let older = failed("old", at: -3000, failure: FailureInfo(failureClass: .network))
        let newer = failed("new", at: -60, failure: FailureInfo(failureClass: .api))
        #expect(SurfaceWords.lastFailure(in: work(older, newer), mode: .simple, now: now)?.name == "new")
        #expect(SurfaceWords.lastFailure(in: work(newer, older), mode: .simple, now: now)?.name == "new")
    }

    @Test("Старый сбой уже не новость, как и сбой без времени")
    func staleFailure() {
        let old = failed(at: -SurfaceWords.failureFreshFor - 1, failure: FailureInfo(failureClass: .network))
        #expect(SurfaceWords.lastFailure(in: work(old), mode: .simple, now: now) == nil)
        var undated = failed(failure: FailureInfo(failureClass: .network))
        undated.lastActivity = nil
        #expect(SurfaceWords.lastFailure(in: work(undated), mode: .simple, now: now) == nil)
    }

    @Test("Без сбоя ничего нет")
    func noFailure() {
        let fine = WorkSession(id: "a", state: .finished, lastActivity: now, root: WorkNode(id: "a", kind: .main, state: .finished))
        #expect(SurfaceWords.lastFailure(in: work(fine), mode: .simple, now: now) == nil)
        #expect(SurfaceWords.lastFailure(in: WorkModel(), mode: .simple, now: now) == nil)
    }

    @Test("Оборвавшаяся сессия тоже сбой")
    func interrupted() {
        let session = WorkSession(id: "a", state: .interrupted, lastActivity: now, root: WorkNode(id: "a", kind: .main, state: .interrupted))
        #expect(SurfaceWords.lastFailure(in: work(session), mode: .simple, now: now)?.what == "Cut off: Claude Code closed")
    }

    @Test("У workflow причина берётся из его сводки", arguments: [DisplayMode.simple, .technical])
    func workflowFailure(mode: DisplayMode) {
        let run = RunState(runId: "r", sessionId: "a", name: "Data", status: .allAgentsFailed, lastWrite: now, topFailure: .limit)
        let session = WorkSession(id: "a", state: .finished, lastActivity: now, root: WorkNode(id: "a", kind: .main, state: .finished, children: [
            WorkNode(id: "r", kind: .workflow, title: "Data", state: .failed, workflow: WorkflowDetails(run)),
        ]))
        let what = SurfaceWords.lastFailure(in: work(session), mode: mode, now: now)?.what
        #expect(what == (mode == .simple ? "Did not work out: the limit ran out" : "Limit reached"))
    }

    private func workflow(_ status: RunStatus, state: WorkState, agents: [WorkNode] = []) -> WorkSession {
        let run = RunState(runId: "r", sessionId: "a", name: "Data", status: status, lastWrite: now, topFailure: .limit)
        return WorkSession(id: "a", state: .finished, lastActivity: now, root: WorkNode(id: "a", kind: .main, state: .finished, children: [
            WorkNode(id: "r", kind: .workflow, title: "Data", state: state, workflow: WorkflowDetails(run), children: agents),
        ]))
    }

    private let limitAgent = WorkNode(id: "r1", kind: .workflowAgent, state: .failed, failure: FailureInfo(failureClass: .limit, resets: "18:40"))

    @Test("Когда сбросится лимит, у workflow знают его агенты")
    func workflowResets() {
        let session = workflow(.allAgentsFailed, state: .failed, agents: [limitAgent])
        #expect(SurfaceWords.lastFailure(in: work(session), mode: .simple, now: now)?.what == "Did not work out: the limit ran out, resets 18:40")
        #expect(SurfaceWords.lastFailure(in: work(session), mode: .technical, now: now)?.what == "Limit reached, resets 18:40")
    }

    @Test("Workflow, где упала только часть агентов, не называется неудавшимся целиком")
    func workflowPartlyDone() {
        let session = workflow(.completedWithErrors, state: .failed, agents: [limitAgent])
        #expect(SurfaceWords.lastFailure(in: work(session), mode: .simple, now: now)?.what == "Partly done: the limit ran out, resets 18:40")
        let unknownReset = workflow(.completedWithErrors, state: .failed)
        #expect(SurfaceWords.lastFailure(in: work(unknownReset), mode: .simple, now: now)?.what == "Partly done: the limit ran out")
        #expect(SurfaceWords.lastFailure(in: work(session), mode: .technical, now: now)?.what == "Limit reached, resets 18:40")
    }

    @Test("Оборвавшийся workflow виден, даже если сессия числится завершённой")
    func workflowInterrupted() {
        let session = workflow(.interrupted, state: .interrupted)
        let simple = SurfaceWords.lastFailure(in: work(session), mode: .simple, now: now)
        #expect(simple?.what == "Cut off: Claude Code closed")
        #expect(simple?.who == "Data")
        let technical = SurfaceWords.lastFailure(in: work(session), mode: .technical, now: now)
        #expect(technical?.what == "Interrupted: the process closed")
        #expect(technical?.who == "workflow “Data”")
    }

    @Test("Текст ошибки в слова не попадает, он только различает перегрузку")
    func errorTextStaysOut() {
        let secret = "overloaded while reading secret-token-123"
        let session = failed(failure: FailureInfo(failureClass: .api, text: secret))
        for mode in DisplayMode.allCases {
            let failure = SurfaceWords.lastFailure(in: work(session), mode: mode, now: now)
            #expect(failure?.what.contains("secret") == false)
            #expect(failure?.who.contains("secret") == false)
        }
        #expect(SurfaceWords.lastFailure(in: work(session), mode: .simple, now: now)?.what == "Claude is overloaded right now, try again later")
        #expect(SurfaceWords.lastFailure(in: work(session), mode: .technical, now: now)?.what == "API error: overloaded")
    }

    @Test("У каждой причины есть слова для обоих режимов", arguments: FailureClass.allCases)
    func everyClassHasWords(kind: FailureClass) {
        let session = failed(failure: FailureInfo(failureClass: kind))
        let simple = SurfaceWords.lastFailure(in: work(session), mode: .simple, now: now)?.what
        let technical = SurfaceWords.lastFailure(in: work(session), mode: .technical, now: now)?.what
        #expect(simple?.isEmpty == false)
        #expect(technical?.isEmpty == false)
        #expect(simple != technical)
    }

    @Test("Сбой без причины и названия всё равно что-то говорит")
    func bareFailure() {
        let session = failed(failure: nil, title: nil)
        let failure = SurfaceWords.lastFailure(in: work(session), mode: .simple, now: now)
        #expect(failure?.what == "Something went wrong")
        #expect(failure?.who == "")
    }
}

@Suite("Цвета чёлки")
struct SurfaceColorTests {
    @Test("Весь текст читается на чёрной чёлке в цветах тёмной темы")
    func textOnNotch() {
        for (name, text) in DesignTokens.textColors {
            #expect(text.dark.contrast(on: DesignTokens.notch.dark) >= 4.5, "\(name)")
        }
    }
}
