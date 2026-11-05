import AppKit
import BorisCore
import BorisData
import Carbon.HIToolbox
import SwiftUI
import Testing
@testable import Boris

/// Draws a view in a real window far off screen, and lets keys reach it as they would reach a key window.
@MainActor
private final class OffScreen {
    let window: NSWindow

    init<Content: View>(_ view: Content, size: CGSize = CGSize(width: 420, height: 600)) {
        _ = NSApplication.shared
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.orderBack(nil)
    }

    /// Suspends rather than running the loop in place: a test on the main actor is itself a block on the main queue, and what views post there waits until it lets go.
    func settle() async {
        for _ in 0..<15 {
            window.contentView?.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// For what must become true. Polling keeps this from depending on how busy the machine is.
    func wait(until condition: () -> Bool) async -> Bool {
        for _ in 0..<250 {
            window.contentView?.layoutSubtreeIfNeeded()
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    func press(keyCode: UInt16, characters: String) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)
        guard let event else { return }
        // The two ways a key reaches a window: as an equivalent, which is how a default button hears it, and to whoever has the focus.
        if !window.performKeyEquivalent(with: event) { window.sendEvent(event) }
    }

    func close() {
        window.orderOut(nil)
    }
}

private func model() -> AppModel {
    MainActor.assumeIsolated {
        let settings = AppSettings(defaults: nil)
        settings.allowKey = HotKeyCombo(keyCode: UInt32(kVK_F19), carbonModifiers: UInt32(cmdKey | optionKey | controlKey | shiftKey))
        settings.denyKey = HotKeyCombo(keyCode: UInt32(kVK_F18), carbonModifiers: UInt32(cmdKey | optionKey | controlKey | shiftKey))
        return AppModel(settings: settings, store: nil, live: false)
    }
}

/// Named, so that a test's report does not carry a quarter of a megabyte of text.
enum LongRequest: CaseIterable {
    case lines, windowsLines, oneLine

    var text: String {
        switch self {
        case .lines: return String(repeating: "abcdefgh abcdefgh abcdefgh\n", count: 9_000)
        case .windowsLines: return String(repeating: "abcdefgh abcdefgh abcdefgh\r\n", count: 9_000)
        case .oneLine: return String(repeating: "abcdefgh ", count: 28_000)
        }
    }
}

private let contents: [RequestContent] = [
    .command("make deploy", unsandboxed: false),
    .file(path: "/x/a.swift", lines: [RequestDiffLine(added: true, text: "line")], whole: false, everyOccurrence: false),
    .questions([RequestQuestion(text: "Какую базу?", options: [.init(label: "SQLite")])]),
    .plan("1. Шаг"),
    .other("{ }"),
]

@Suite("Карточки запросов", .serialized)
@MainActor
struct RequestCardTests {
    /// Proves the check below can catch what it looks for: a default button in the same window does hear the same Enter.
    @Test("Проверка настоящая: кнопка по умолчанию в таком же окне на этот Enter срабатывает")
    func enterHarnessCatchesDefaultButton() async {
        var presses = 0
        let screen = OffScreen(Button("Да") { presses += 1 }.keyboardShortcut(.defaultAction))
        defer { screen.close() }
        await screen.settle()
        screen.press(keyCode: UInt16(kVK_Return), characters: "\r")
        await screen.settle()
        #expect(presses == 1)
    }

    @Test("Enter ничего не разрешает: ни на одной карточке")
    func enterAllowsNothing() async {
        for content in contents {
            let app = model()
            let asked = PendingPermission(session: "s1", tool: "x", content: content, project: "proj", askedAt: Date().addingTimeInterval(-30))
            app.hooks.showRequestsForSnapshot(open: [asked], expired: [], decisions: [])
            // With an answer chosen, so that a question has something Enter could send.
            if case .questions(let questions) = content, let first = questions.first, let label = first.options.first?.label {
                app.hooks.updateDraft(asked.id) { $0.toggle(label, in: first) }
            }
            let screen = OffScreen(RequestCardList(model: app))
            defer { screen.close() }
            #expect(await screen.wait { app.hooks.hotKeyTarget == asked }, "карточка действительно нарисована: \(content)")
            // Past the pause after a card appears: it swallows any answer, and would hide a wrong one from this test.
            try? await Task.sleep(for: .seconds(HookController.settleTime + 0.1))
            for (key, text) in [(UInt16(kVK_Return), "\r"), (UInt16(kVK_ANSI_KeypadEnter), "\u{3}")] {
                screen.press(keyCode: key, characters: text)
                await screen.settle()
            }
            #expect(app.hooks.pending == [asked], "\(content)")
            #expect(app.hooks.queue.decisions.isEmpty, "\(content)")
        }
    }

    @Test("Enter в поле причины ничего не отправляет")
    func enterInReasonField() async {
        let app = model()
        let asked = PendingPermission(session: "s1", tool: "Bash", content: .command("make deploy", unsandboxed: false), project: "proj", askedAt: Date().addingTimeInterval(-30))
        app.hooks.showRequestsForSnapshot(open: [asked], expired: [], decisions: [])
        app.hooks.updateDraft(asked.id) { $0.denying = true; $0.reason = "причина" }
        let screen = OffScreen(RequestCardList(model: app))
        defer { screen.close() }
        #expect(await screen.wait { app.hooks.hotKeyTarget == asked })
        try? await Task.sleep(for: .seconds(HookController.settleTime + 0.1))
        screen.press(keyCode: UInt16(kVK_Return), characters: "\r")
        await screen.settle()
        #expect(app.hooks.pending == [asked])
        #expect(app.hooks.queue.decisions.isEmpty)
    }

    @Test("Esc закрывает форму отказа и ничего не отправляет")
    func escapeGoesBack() async {
        let app = model()
        let asked = PendingPermission(session: "s1", tool: "Bash", content: .command("make deploy", unsandboxed: false), project: "proj", askedAt: Date().addingTimeInterval(-30))
        app.hooks.showRequestsForSnapshot(open: [asked], expired: [], decisions: [])
        app.hooks.updateDraft(asked.id) { $0.denying = true; $0.reason = "причина" }
        let screen = OffScreen(RequestCardList(model: app))
        defer { screen.close() }
        await screen.settle()
        screen.press(keyCode: UInt16(kVK_Escape), characters: "\u{1b}")
        await screen.settle()
        #expect(app.hooks.draft(asked.id).denying == false)
        #expect(app.hooks.draft(asked.id).reason.isEmpty)
        #expect(app.hooks.pending == [asked])
        #expect(app.hooks.queue.decisions.isEmpty)
    }

    @Test("Карточка за краем списка не считается видимой")
    func scrolledOutOfView() async {
        let app = model()
        let asked = PendingPermission(session: "s1", tool: "Bash", content: .command("make deploy", unsandboxed: false), project: "proj", askedAt: Date().addingTimeInterval(-30))
        app.hooks.showRequestsForSnapshot(open: [asked], expired: [], decisions: [])

        let below = OffScreen(ScrollView {
            VStack(spacing: 0) {
                Color.clear.frame(height: 2000)
                RequestCardList(model: app)
            }
        }, size: CGSize(width: 420, height: 300))
        await below.settle()
        #expect(app.hooks.hotKeyTarget == nil, "карточка далеко внизу списка")
        below.close()
    }

    @Test("Карточка наверху списка доступна клавишам и показывает их")
    func cardInViewIsTarget() async {
        let app = model()
        let asked = PendingPermission(session: "s1", tool: "Bash", content: .command("make deploy", unsandboxed: false), project: "proj", askedAt: Date().addingTimeInterval(-30))
        app.hooks.showRequestsForSnapshot(open: [asked], expired: [], decisions: [])
        let top = OffScreen(ScrollView { RequestCardList(model: app) }, size: CGSize(width: 420, height: 300))
        defer { top.close() }
        #expect(await top.wait { app.hooks.hotKeyTarget == asked })
    }

    @Test("Сессия ждёт без хуков: предложение подключить есть, а ответить нельзя")
    func waitingWithoutHooks() {
        let app = model()
        let session = WorkSession(id: "s1", environment: .vsCode, cwd: "/x/proj", state: .waiting, root: WorkNode(id: "s1", kind: .main, state: .waiting))
        let work = WorkModel(projects: [WorkProject(path: session.cwd, sessions: [session])])
        app.hooks.note(work: work)
        #expect(app.hooks.connection == .notConnected)
        #expect(app.hooks.queue.rows(now: Date()) == [.waiting(session)])
        #expect(app.requestCount == 1)
        #expect(app.hooks.hotKeyTarget == nil)
        #expect(app.hooks.keysWanted == (false, false), "ни клавиш, ни кнопки разрешения")
        var offered = 0
        app.hooks.onConnect = { offered += 1 }
        app.hooks.onConnect?()
        #expect(offered == 1)
    }

    @Test("Счётчик считает запросы, а не сессии")
    func countsRequests() {
        let app = model()
        let main = PendingPermission(session: "s1", tool: "Bash", content: .command("a", unsandboxed: false))
        let helper = PendingPermission(session: "s1", agent: "h1", tool: "Bash", content: .command("b", unsandboxed: false))
        app.hooks.showRequestsForSnapshot(open: [main, helper], expired: [], decisions: [])
        #expect(app.requestCount == 2)
    }

    @Test("Заголовки простого режима не называют инструментов, а технический называет")
    func titles() {
        func title(_ tool: String, _ content: RequestContent, _ mode: DisplayMode, denying: Bool = false) -> String {
            RequestWords.title(PendingPermission(session: "s", tool: tool, content: content), denying: denying, mode: mode)
        }
        Localizer.use(.en)
        let cases: [(String, RequestContent)] = [
            ("Bash", .command("x", unsandboxed: false)),
            ("Edit", .file(path: "/a", lines: [], whole: false, everyOccurrence: false)),
            ("AskUserQuestion", .questions([])),
            ("ExitPlanMode", .plan("p")),
            ("mcp__x__y", .other("{}")),
            ("WebFetch", .other("{}")),
        ]
        for (tool, content) in cases {
            #expect(!title(tool, content, .simple).contains(tool), "\(tool)")
            #expect(title(tool, content, .technical).contains(tool), "\(tool)")
        }
        #expect(title("Bash", .command("x", unsandboxed: false), .simple) == "Wants to run a command")
        #expect(title("Bash", .command("x", unsandboxed: false), .simple, denying: true) == "Deny command")
        #expect(title("Bash", .command("x", unsandboxed: false), .technical) == "Permission · Bash")
    }

    @Test("Технический режим добавляет инструмент и режим разрешений")
    func technicalMeta() {
        Localizer.use(.en)
        #expect(RequestWords.technicalMeta(PendingPermission(session: "s", tool: "Bash", content: .command("x", unsandboxed: false), mode: "default")) == "Bash · default mode")
        #expect(RequestWords.technicalMeta(PendingPermission(session: "s", tool: "AskUserQuestion", content: .questions([]))) == "AskUserQuestion")
    }

    @Test("Путь внутри проекта короткий, а файл вне проекта не выглядит как файл проекта")
    func paths() {
        #expect(RequestWords.path("/x/proj/src/auth.swift", cwd: "/x/proj") == "src/auth.swift")
        #expect(RequestWords.path("/etc/hosts", cwd: "/x/proj") == "/etc/hosts")
        #expect(RequestWords.path("/elsewhere/proj/.ssh/config", cwd: "/x/proj") == "/elsewhere/proj/.ssh/config")
        #expect(RequestWords.path("/x/proj-two/a", cwd: "/x/proj") == "/x/proj-two/a")
        #expect(RequestWords.path("/a/b", cwd: nil) == "/a/b")
    }

    @Test("Часы показывают остаток и не уходят в минус")
    func clock() {
        #expect(RequestWords.clock(102) == "1:42")
        #expect(RequestWords.clock(120) == "2:00")
        #expect(RequestWords.clock(0.4) == "0:01")
        #expect(RequestWords.clock(-5) == "0:00")
        #expect(RequestWords.clock(1e300) == "1440:00", "странное число из повреждённой истории не роняет приложение")
    }

    /// As much as a request can hold and still be allowed. These stood the whole app still: over ten seconds for the command, and minutes for the plan.
    @Test("Самый длинный запрос не останавливает приложение", arguments: LongRequest.allCases)
    func longestRequestStaysQuick(shape: LongRequest) async {
        let lines = RequestLines.split(shape.text).map { RequestDiffLine(added: true, text: $0) }
        let views: [(String, AnyView)] = [
            ("plan", AnyView(RequestPlanBox(plan: shape.text, maxHeight: 320))),
            ("whole text", AnyView(RequestWholeText(text: shape.text))),
            ("folded text", AnyView(RequestTextBox(text: shape.text))),
            ("diff", AnyView(RequestDiffBox(path: "/x/a", lines: lines))),
        ]
        for (name, view) in views {
            let began = Date()
            let screen = OffScreen(view, size: CGSize(width: 420, height: 400))
            screen.window.contentView?.layoutSubtreeIfNeeded()
            screen.window.contentView?.display()
            screen.close()
            #expect(Date().timeIntervalSince(began) < 5, "\(name)")
        }
    }

    @Test("Длинный план и длинная команда не теряют ни строки")
    func longTextKeepsEveryLine() {
        let text = "первая\n\nтретья\r\nчетвёртая\u{2028}пятая"
        #expect(RequestLines.split(text) == ["первая", "", "третья", "четвёртая", "пятая"])
    }

    @Test("Открыть можно только то, куда есть куда идти")
    func opening() {
        func can(_ environment: WorkEnvironment?, pid: Int32? = nil) -> Bool {
            SessionNavigator.canOpen(WorkSession(id: "s", environment: environment, state: .waiting, root: WorkNode(id: "s", kind: .main)), pid: pid)
        }
        #expect(can(.vsCode))
        #expect(can(.cursor))
        #expect(can(.claudeDesktop))
        #expect(can(.cowork))
        #expect(can(.terminal, pid: 42))
        #expect(!can(.terminal))
        #expect(!can(.program))
        #expect(!can(.insideClaude))
        #expect(!SessionNavigator.canOpen(nil, pid: nil))
    }
}
