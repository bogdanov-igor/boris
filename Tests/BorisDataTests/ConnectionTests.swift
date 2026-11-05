import BorisCore
import Foundation
import Testing
@testable import BorisData

@Suite("Политика компании")
struct ManagedSettingsTests {
    private let plan = HookInstaller.Plan(helperPath: "/a/boris-hook", permissions: false, permissionWait: 30)

    private func plist(_ values: [String: Any], in folder: TempFolder, name: String) throws -> URL {
        let data = try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
        return folder.write(name, String(decoding: data, as: UTF8.self))
    }

    @Test("Запрет виден в файле политики", arguments: ["disableAllHooks", "allowManagedHooksOnly"])
    func file(key: String) {
        let folder = TempFolder()
        folder.write("managed-settings.json", #"{"\#(key)": true}"#)
        #expect(ManagedSettings(folder: folder.url, profiles: []).blocksUserHooks)
    }

    @Test("Запрет виден в дополнительных файлах политики")
    func dropIn() {
        let folder = TempFolder()
        folder.write("managed-settings.json", #"{"model": "opus"}"#)
        folder.write("managed-settings.d/20-hooks.json", #"{"allowManagedHooksOnly": true}"#)
        #expect(ManagedSettings(folder: folder.url, profiles: []).blocksUserHooks)
    }

    @Test("Запрет виден в профиле MDM")
    func profile() throws {
        let folder = TempFolder()
        let file = try plist(["allowManagedHooksOnly": true], in: folder, name: "profile.plist")
        #expect(ManagedSettings(folder: folder.url, profiles: [file]).blocksUserHooks)
    }

    @Test("Запрета нет: пустая папка, false, чужие ключи, повреждённый файл", arguments: [nil, #"{"disableAllHooks": false, "allowManagedHooksOnly": false}"#, #"{"model": "opus"}"#, "{not json"])
    func notBlocked(text: String?) {
        let folder = TempFolder()
        if let text { folder.write("managed-settings.json", text) }
        #expect(!ManagedSettings(folder: folder.url, profiles: [folder.url.appendingPathComponent("missing.plist")]).blocksUserHooks)
    }

    @Test("Политика важнее того, что записано в настройках")
    func policyWins() throws {
        let policy = TempFolder()
        policy.write("managed-settings.json", #"{"allowManagedHooksOnly": true}"#)
        let folder = TempFolder()
        let file = folder.url.appendingPathComponent("settings.json")
        let nothing = ManagedSettings(folder: folder.url.appendingPathComponent("none"), profiles: [])
        try HookInstaller.install(at: file, plan: plan)
        #expect(HookInstaller.status(at: file, plan: plan, managed: nothing) == .installed)
        #expect(HookInstaller.status(at: file, plan: plan, managed: ManagedSettings(folder: policy.url, profiles: [])) == .disabledByPolicy)
    }

    @Test("Свой disableAllHooks не выдаётся за запрет компании")
    func ownChoice() {
        let folder = TempFolder()
        let file = folder.write("settings.json", #"{"disableAllHooks": true}"#)
        let nothing = ManagedSettings(folder: folder.url.appendingPathComponent("none"), profiles: [])
        #expect(HookInstaller.status(at: file, plan: plan, managed: nothing) == .disabledInSettings)
    }
}

@Suite("Состояние подключения")
struct ConnectionTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var since: Date { now.addingTimeInterval(-3600) }

    private func session(entrypoint: String = "cli", status: String = "busy", changedAgo: TimeInterval = 600) -> SessionInfo {
        SessionInfo(sessionId: "s", pid: 1, entrypoint: entrypoint, status: status, statusUpdatedAt: now.addingTimeInterval(-changedAgo))
    }

    private func status(_ hooks: HookConnection = .connected, sessions: [SessionInfo] = [], lastEvent: TimeInterval? = nil, world: WorldSnapshot? = nil) -> ConnectionStatus {
        var state = HookState()
        if let lastEvent { state.apply(.turnStopped(session: "x"), now: now.addingTimeInterval(-lastEvent)) }
        return ConnectionStatus(world: world ?? WorldSnapshot(takenAt: now, sessions: sessions), hooks: hooks, hookState: state, hooksSince: since, now: now)
    }

    @Test("Состояние складывается из файла настроек и желания человека")
    func connection() {
        #expect(HookConnection(wanted: false, status: .notInstalled) == .notConnected)
        #expect(HookConnection(wanted: true, status: .notInstalled) == .damaged)
        #expect(HookConnection(wanted: true, status: .installed) == .connected)
        #expect(HookConnection(wanted: false, status: .installed) == .connected)
        #expect(HookConnection(wanted: true, status: .outdated) == .damaged)
        #expect(HookConnection(wanted: true, status: .unreadable) == .settingsUnreadable)
        #expect(HookConnection(wanted: true, status: .disabledByPolicy) == .disabledByPolicy)
        #expect(HookConnection(wanted: false, status: .disabledInSettings) == .disabledInSettings)
        #expect(HookConnection.notConnected.canConnect)
        #expect(HookConnection.damaged.canConnect)
        #expect(!HookConnection.disabledByPolicy.canConnect)
        #expect(!HookConnection.settingsUnreadable.canConnect)
    }

    @Test("Всё работает: проблем нет")
    func allGood() {
        #expect(status(sessions: [session()], lastEvent: 10).problems.isEmpty)
    }

    @Test("Не подключены: это не проблема и о молчании речи нет")
    func notConnected() {
        let state = status(.notConnected, sessions: [session()])
        #expect(state.problems.isEmpty)
        #expect(!state.hooksSilent)
    }

    @Test("Подключены, Claude работает, событий нет: проблема")
    func silent() {
        #expect(status(sessions: [session()], lastEvent: nil).problems == [.hooksSilent])
        #expect(status(sessions: [session(changedAgo: 600)], lastEvent: 1800).problems == [.hooksSilent])
    }

    @Test("Не проблема", arguments: [
        // Long command: an event came after the status changed.
        (600.0, 300.0, "cli", "busy"),
        // Claude has only just started, and its first tool is still ahead.
        (60.0, 1800.0, "cli", "busy"),
        // Nothing is going on.
        (600.0, 1800.0, "cli", "idle"),
        // The session was already busy when hooks appeared.
        (7200.0, 9000.0, "cli", "busy"),
        // Cowork and programs on the SDK may not load the person's settings.
        (600.0, 1800.0, "local-agent", "busy"),
        (600.0, 1800.0, "sdk-cli", "busy"),
    ])
    func notSilent(changedAgo: TimeInterval, lastEvent: TimeInterval, entrypoint: String, state: String) {
        #expect(!status(sessions: [session(entrypoint: entrypoint, status: state, changedAgo: changedAgo)], lastEvent: lastEvent).hooksSilent)
    }

    @Test("Каждая поломка называется своим именем")
    func problems() {
        #expect(status(.damaged).problems == [.hooksDamaged])
        #expect(status(.settingsUnreadable).problems == [.settingsUnreadable])
        #expect(status(.disabledByPolicy).problems == [.hooksDisabledByPolicy])
        #expect(status(.disabledInSettings).problems == [.hooksDisabledInSettings])
        let missing = WorldSnapshot(takenAt: now, claudeFolderFound: false)
        #expect(status(.notConnected, world: missing).problems == [.claudeFolderMissing])
        let changed = WorldSnapshot(takenAt: now, formatIssues: [.unknownJournalEvent("teleport")])
        #expect(status(.notConnected, world: changed).problems == [.formatChanged])
        let unreadable = WorldSnapshot(takenAt: now, formatIssues: [.unreadableSessions])
        #expect(status(.notConnected, world: unreadable).problems == [.filesUnreadable, .formatChanged])
    }

    @Test("Морж считает сломанным то, что перестало работать само, а не выключено намеренно")
    func brokenForTheWalrus() {
        #expect(!status(sessions: [session()], lastEvent: 10).isBroken)
        #expect(!status(.notConnected).isBroken)
        #expect(!status(.disabledByPolicy).isBroken)
        #expect(!status(.disabledInSettings).isBroken)
        #expect(status(.damaged).isBroken)
        #expect(status(.settingsUnreadable).isBroken)
        #expect(status(sessions: [session()], lastEvent: nil).isBroken)
        #expect(status(.notConnected, world: WorldSnapshot(takenAt: now, claudeFolderFound: false)).isBroken)
        #expect(status(.notConnected, world: WorldSnapshot(takenAt: now, formatIssues: [.unknownJournalEvent("teleport")])).isBroken)
    }

    @Test("Лимиты: нет данных, свежие, устаревшие с возрастом")
    func limits() {
        #expect(status(.notConnected).limits == .noData)
        let fresh = WorldSnapshot(takenAt: now, usage: UsageSnapshot(fetchedAt: now.addingTimeInterval(-60)))
        #expect(status(.notConnected, world: fresh).limits == .fresh)
        let old = WorldSnapshot(takenAt: now, usage: UsageSnapshot(fetchedAt: now.addingTimeInterval(-3600)))
        #expect(status(.notConnected, world: old).limits == .stale(age: 3600))
    }

    @Test("SubagentStart: сигнал с голым идентификатором агента")
    func subagentStartSignal() {
        let signal = HookSignal(payload: ["hook_event_name": "SubagentStart", "session_id": "s", "agent_id": "agent-abc123", "agent_type": "Explore"])
        #expect(signal == .agentStarted(session: "s", agent: "abc123"))
    }

    @Test("Любое событие отмечает время, а статусов не меняет")
    func lastEvent() {
        var state = HookState()
        #expect(state.lastEventAt == nil)
        state.apply(.agentStarted(session: "s", agent: "a"), now: now)
        #expect(state.lastEventAt == now)
    }

    @Test("Отчёт не содержит путей и текста, но называет проблемы")
    func report() {
        let folder = TempFolder()
        folder.write("sessions/1.json", #"{"sessionId":"s","cwd":"/secret/project","name":"private title"}"#)
        let world = WorldSnapshot(takenAt: now, sessions: [SessionInfo(sessionId: "s", pid: 1, cwd: "/secret/project", version: "2.1.312")], formatIssues: [.unreadableFinal(runId: "wf_secret")])
        let connection = status(.damaged, lastEvent: 42, world: world)
        let text = Diagnostics.report(world: world, paths: ClaudePaths(root: folder.url), appVersion: "0.1.0", connection: connection, now: now)
        #expect(!text.contains("/secret"))
        #expect(!text.contains("private title"))
        #expect(!text.contains("wf_secret"))
        #expect(text.contains("Hooks: damaged"))
        #expect(text.contains("Last hook event: 42 s ago"))
        #expect(text.contains("formatChanged"))
        #expect(text.contains("Limits: no data"))
    }
}
