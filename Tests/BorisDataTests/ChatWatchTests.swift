import BorisCore
import Foundation
import Testing
@testable import BorisData

/// Stands in for Claude Desktop's window and counts every approach to it.
private final class FakeProbe: ChatWindowProbe, @unchecked Sendable {
    private let lock = NSLock()
    private var permissionChecks = 0
    private var asks = 0
    private var looks = 0
    private var stops = 0
    private var allowed: Bool
    private var nextLook: ChatLook

    init(allowed: Bool = true, look: ChatLook = .notAnswering) {
        self.allowed = allowed
        nextLook = look
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func hasPermission() -> Bool {
        locked {
            permissionChecks += 1
            return allowed
        }
    }

    func askForPermission() { locked { asks += 1 } }

    func look() -> ChatLook {
        locked {
            looks += 1
            return nextLook
        }
    }

    func stopLooking() { locked { stops += 1 } }

    func set(look: ChatLook) { locked { nextLook = look } }
    func allow() { locked { allowed = true } }

    var counts: (permission: Int, asks: Int, looks: Int, stops: Int) { locked { (permissionChecks, asks, looks, stops) } }
    /// Every call at all, whichever it was.
    var touches: Int { locked { permissionChecks + asks + looks + stops } }
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(10)
    while Date() < end {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

@Suite("Обычный чат: согласие и окно Claude Desktop")
@MainActor
struct ChatWatchTests {
    @Test("Без согласия нет ни одного обращения: ни к окну, ни к macOS. Чат показан как не подключённый")
    func noConsent() async throws {
        let probe = FakeProbe()
        let watch = ChatWatch(probe: probe, period: .milliseconds(1))
        watch.update(consent: false)
        try await Task.sleep(for: .milliseconds(60))
        #expect(probe.touches == 0)
        #expect(!watch.isLooking)
        #expect(watch.tracker.connection == .notConnected)
        #expect(watch.tracker.session == nil)
        #expect(watch.takeEvents().isEmpty)
    }

    @Test("Согласие есть, разрешения нет: к окну не обращается, ждёт разрешения и замечает его")
    func noPermissionYet() async throws {
        let probe = FakeProbe(allowed: false)
        let watch = ChatWatch(probe: probe, period: .milliseconds(1))
        watch.update(consent: true)
        #expect(await waitUntil { watch.tracker.connection == .needsPermission })
        try await Task.sleep(for: .milliseconds(30))
        #expect(probe.counts.looks == 0)
        #expect(probe.counts.asks == 0)
        probe.allow()
        #expect(await waitUntil { watch.tracker.connection == .connected })
        #expect(probe.counts.looks > 0)
        watch.update(consent: false)
    }

    @Test("macOS спрашивают только по просьбе человека, а не от самого слежения")
    func asksOnlyWhenTold() async throws {
        let probe = FakeProbe()
        let watch = ChatWatch(probe: probe, period: .milliseconds(1))
        watch.update(consent: true)
        #expect(await waitUntil { probe.counts.looks > 3 })
        #expect(probe.counts.asks == 0)
        watch.askForPermission()
        #expect(probe.counts.asks == 1)
        watch.update(consent: false)
    }

    @Test("Ответ стал готов за спиной: одно событие, сессия, и всё без текста")
    func readyEvent() async throws {
        let probe = FakeProbe(look: .answering)
        let watch = ChatWatch(probe: probe, period: .milliseconds(1))
        var changes = 0
        watch.onChange = { changes += 1 }
        watch.update(consent: true)
        #expect(await waitUntil { watch.tracker.session?.state == .running })
        probe.set(look: .notAnswering)
        #expect(await waitUntil { watch.tracker.session?.state == .finished })
        let events = watch.takeEvents()
        #expect(events.count == 1)
        #expect(events.first?.kind == .sessionFinished)
        #expect(events.first?.environment == .chat)
        #expect(events.first?.name == nil)
        #expect(events.first?.project == nil)
        #expect(watch.takeEvents().isEmpty)
        #expect(changes >= 2)
        watch.update(consent: false)
    }

    @Test("Выключение останавливает всё: больше ни одного обращения, а Claude Desktop отпущен")
    func withdraw() async throws {
        let probe = FakeProbe(look: .answering)
        let watch = ChatWatch(probe: probe, period: .milliseconds(1))
        watch.update(consent: true)
        #expect(await waitUntil { watch.tracker.session != nil })
        watch.update(consent: false)
        #expect(!watch.isLooking)
        #expect(watch.tracker.connection == .notConnected)
        #expect(watch.tracker.session == nil)
        #expect(await waitUntil { probe.counts.stops == 1 })
        // A look that was already under way may still finish, and nothing after it starts.
        try await Task.sleep(for: .milliseconds(20))
        let before = probe.touches
        try await Task.sleep(for: .milliseconds(40))
        #expect(probe.touches == before)
    }

    @Test("При выходе из Boris Claude Desktop отпущен, а без слежения его никто не трогает")
    func quitting() async throws {
        let idle = FakeProbe()
        let unused = ChatWatch(probe: idle)
        unused.quit()
        #expect(idle.touches == 0)

        let probe = FakeProbe()
        let watch = ChatWatch(probe: probe, period: .milliseconds(1))
        watch.update(consent: true)
        #expect(await waitUntil { probe.counts.looks > 0 })
        watch.quit()
        #expect(probe.counts.stops == 1)
        #expect(!watch.isLooking)
    }

    @Test("Повторное включение не запускает второй цикл")
    func onlyOneLoop() async throws {
        let probe = FakeProbe()
        let watch = ChatWatch(probe: probe, period: .seconds(60))
        watch.update(consent: true)
        watch.update(consent: true)
        #expect(await waitUntil { probe.counts.looks >= 1 })
        try await Task.sleep(for: .milliseconds(30))
        #expect(probe.counts.looks == 1)
        watch.update(consent: false)
    }

    @Test("Заменитель для снимков ничего не трогает и не притворяется подключённым")
    func standIn() {
        let probe = NoChatProbe()
        #expect(!probe.hasPermission())
        #expect(probe.look() == .noPermission)
    }
}

@Suite("Обычный чат: окно другого приложения трогает только одно место")
struct ChatAccessGuardTests {
    private var sources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
    }

    private func files(containing needle: Regex<Substring>) -> [String] {
        let walker = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        let files = (walker?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
        return files.filter { ((try? String(contentsOf: $0, encoding: .utf8)) ?? "").contains(needle) }.map(\.lastPathComponent).sorted()
    }

    @Test("Вызовы Accessibility есть только в одном файле")
    func onlyOneFile() {
        #expect(files(containing: /AXUIElement|AXIsProcessTrusted/) == ["ChatWindowReader.swift"])
    }

    @Test("Настоящая проба создаётся только в модели приложения, и только для живого запуска")
    func onlyLive() throws {
        #expect(files(containing: /AccessibilityChatProbe\(\)/) == ["AppModel.swift"])
        let model = try String(contentsOf: sources.appendingPathComponent("Boris/App/AppModel.swift"), encoding: .utf8)
        #expect(model.contains("live ? AccessibilityChatProbe() : NoChatProbe()"))
    }

    @Test("Текст элементов окна не запрашивается: только подпись кнопки, вид и дети")
    func neverAsksForText() throws {
        let reader = try String(contentsOf: sources.appendingPathComponent("BorisData/ChatWindowReader.swift"), encoding: .utf8)
        for attribute in ["kAXValueAttribute", "AXValue", "kAXSelectedText", "AXSelectedText", "kAXHelpAttribute"] {
            #expect(!reader.contains(attribute), "\(attribute)")
        }
    }
}

@Suite("Обычный чат в списках сессий")
struct ChatInListsTests {
    @Test("У чата нет лога, но это не значит, что его удалили")
    func notGone() {
        var tracker = ChatTracker()
        let start = Date().addingTimeInterval(-600)
        _ = tracker.note(.answering, now: start)
        _ = tracker.note(.notAnswering, now: start)
        _ = tracker.note(.notAnswering, now: start)
        let work = WorkModel().withChat(tracker.session)
        #expect(ProjectBook.sessions(work: work, past: [], logsReadAt: Date()).map(\.id) == [ChatTracker.sessionId])
        // Any other finished session that is not among the logs has lost its log.
        let other = WorkSession(id: "x", state: .finished, lastActivity: start, root: WorkNode(id: "x", kind: .main))
        #expect(ProjectBook.sessions(work: WorkModel(projects: [WorkProject(path: nil, sessions: [other])]), past: [], logsReadAt: Date()).isEmpty)
    }
}
