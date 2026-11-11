import AppKit
import BorisCore
import Foundation
import ServiceManagement
import Testing
@testable import Boris

private let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// A launchd job that exists only here.
@MainActor
private final class FakeAgent: LoginAgent {
    var status = SMAppService.Status.notRegistered
    var registered = 0
    var unregistered = 0
    var refuses = false

    func register() throws {
        if refuses { throw CocoaError(.featureUnsupported) }
        registered += 1
        status = .enabled
    }

    func unregister() throws {
        if refuses { throw CocoaError(.featureUnsupported) }
        unregistered += 1
        status = .notRegistered
    }
}

/// Defaults that live only in memory, so that no check touches the app's own.
private final class MemoryDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]

    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func set(_ value: Bool, forKey key: String) { values[key] = value }
    override func set(_ value: Int, forKey key: String) { values[key] = value }
    override func removeObject(forKey key: String) { values[key] = nil }
    override func object(forKey key: String) -> Any? { values[key] }
    override func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    override func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
}

/// The debug build started as a real process. It is told not to show anything, in case the guard fails, and has a home of its own, so nothing real can be reached.
@Suite("Отладочный запуск")
struct DebugLaunchTests {
    private let executable = packageRoot.appendingPathComponent(".build/debug/Boris")

    private func launch(extra: [String: String] = [:]) throws -> (code: Int32, output: String, home: URL) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("boris-launch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = executable
        process.environment = ["HOME": home.path, "CFFIXED_USER_HOME": home.path, "BORIS_STATE_DIR": home.path, "BORIS_SMOKE": "1", "BORIS_NO_STATUS_ITEM": "1"].merging(extra) { _, new in new }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let deadline = Date().addingTimeInterval(30)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (process.terminationStatus, text, home)
    }

    @Test("Без разрешения процесс уходит сразу: без окон и без настроек, даже если другие копии запущены")
    func stopsBeforeAnything() throws {
        #expect(FileManager.default.isExecutableFile(atPath: executable.path))
        let (code, output, home) = try launch()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(code == 2, "вывод: \(output)")
        #expect(output.contains("was not asked to run"), "останавливает первая проверка, а не вторая")
        #expect(!output.contains("Another Boris"), "другие копии не решают, чем кончится этот запуск")
        #expect(!output.contains("icon visible"), "приложение не дошло до настоящего запуска")
        let left = try FileManager.default.contentsOfDirectory(atPath: home.path)
        #expect(left.isEmpty, "ничего не записано: \(left)")
    }
}

@MainActor
@Suite("Автозапуск и другие копии")
struct AutostartTests {
    @Test("Что делает новая копия, когда другие уже идут", arguments: [
        // othersRun, isAgent, isDebug
        (false, false, false, LaunchClaim.run),
        (false, true, false, .run),
        (true, false, false, .askOtherAndLeave),
        (true, true, false, .takeOverFromHandOpened),
        (true, true, true, .leaveQuietly),
        (true, false, true, .leaveQuietly),
        (false, false, true, .run),
    ])
    func claims(others: Bool, agent: Bool, debug: Bool, expected: LaunchClaim) {
        #expect(LaunchCoordinator.claim(othersRun: others, isAgent: agent, isDebug: debug) == expected)
    }

    @Test("Копия от launchd уходит сразу, только если автозапуск выключен и прошлый раз Boris закрыли как обычно", arguments: [
        // isAgent, autostartOff, lastRunEndedNormally, leaves
        (true, true, true, true),
        (true, true, false, false),
        (true, false, true, false),
        (true, false, false, false),
        (false, true, true, false),
        (false, true, false, false),
        (false, false, true, false),
    ])
    func leavesAtLogin(agent: Bool, off: Bool, normal: Bool, leaves: Bool) {
        #expect(LaunchCoordinator.leavesAtStart(isAgent: agent, autostartOff: off, lastRunEndedNormally: normal) == leaves)
    }

    @Test("Автозапуск выключен: после обычного выхода копия от launchd уходит, после падения остаётся")
    func agentCopyAtLogin() {
        let defaults = MemoryDefaults()
        let agent = FakeAgent()
        agent.status = .enabled
        let running = LaunchCoordinator(agent: agent, environment: ["BORIS_LAUNCHD": "1"], isDebug: false, defaults: defaults, pid: 100)
        #expect(running.setAutostart(false) {})
        running.noteRunStarted()

        let afterCrash = LaunchCoordinator(agent: agent, environment: ["BORIS_LAUNCHD": "1"], isDebug: false, defaults: defaults, pid: 101)
        #expect(afterCrash.claimInstance(others: []), "метка работающей копии осталась: это падение")

        afterCrash.noteRunStarted()
        running.noteQuitNormally()
        #expect(defaults.integer(forKey: LaunchCoordinator.runningKey) == 101, "чужую метку копия не снимает")
        afterCrash.noteQuitNormally()
        let atLogin = LaunchCoordinator(agent: agent, environment: ["BORIS_LAUNCHD": "1"], isDebug: false, defaults: defaults, pid: 102)
        #expect(!atLogin.claimInstance(others: []), "закрыли как обычно: при входе Boris не запускается")
        let byHand = LaunchCoordinator(agent: agent, environment: [:], isDebug: false, defaults: defaults, pid: 103)
        #expect(byHand.claimInstance(others: []), "открытый вручную запускается всегда")

        #expect(atLogin.setAutostart(true) {})
        #expect(atLogin.claimInstance(others: []), "автозапуск включён")
        #expect(agent.unregistered == 0, "задание launchd остаётся в обоих случаях")
    }

    @Test("Задание launchd возвращается, если его нет, а прежнее выключение автозапуска сохраняется")
    func agentKeptRegistered() {
        let first = FakeAgent()
        let fresh = MemoryDefaults()
        let launch = LaunchCoordinator(agent: first, environment: [:], defaults: fresh)
        launch.keepAgentRegistered()
        #expect(first.registered == 1)
        #expect(launch.autostartState == .on, "при первом запуске автозапуск включён")

        let removed = FakeAgent()
        let earlier = MemoryDefaults()
        earlier.set(true, forKey: LaunchCoordinator.configuredKey)
        let upgraded = LaunchCoordinator(agent: removed, environment: [:], defaults: earlier)
        upgraded.keepAgentRegistered()
        #expect(removed.registered == 1, "прежняя версия убирала задание, когда автозапуск выключали")
        #expect(upgraded.autostartState == .off)

        let refused = FakeAgent()
        refused.status = .requiresApproval
        LaunchCoordinator(agent: refused, environment: [:], defaults: MemoryDefaults()).keepAgentRegistered()
        #expect(refused.registered == 0, "выключенное в Системных настройках включает только человек")
    }

    @Test("Задание launchd поднимает после падения и не поднимает после выхода")
    func agentPlist() throws {
        let data = try Data(contentsOf: packageRoot.appendingPathComponent("Resources/\(LaunchCoordinator.agentPlist)"))
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["Label"] as? String == LaunchCoordinator.agentLabel)
        #expect(plist["RunAtLoad"] as? Bool == true)
        #expect((plist["KeepAlive"] as? [String: Any])?["SuccessfulExit"] as? Bool == false, "выход с нулём из меню не перезапускает, падение перезапускает")
        #expect((plist["ThrottleInterval"] as? Int ?? 99) <= 10, "поднимается за несколько секунд")
        #expect(plist["BundleProgram"] as? String == "Contents/MacOS/Boris")
        #expect((plist["EnvironmentVariables"] as? [String: String])?["BORIS_LAUNCHD"] == "1")
        let script = try String(contentsOf: packageRoot.appendingPathComponent("scripts/build-app.sh"), encoding: .utf8)
        #expect(script.contains("Contents/Library/LaunchAgents"), "сборка кладёт задание туда, где его ищет SMAppService")
    }

    @Test("README на обоих языках говорит, как поставить Boris, и не называет его недоделанным")
    func readmeSaysHowToInstall() throws {
        let readme = try String(contentsOf: packageRoot.appendingPathComponent("README.md"), encoding: .utf8)
        let russian = try #require(readme.range(of: "## Русский"))
        let english = try #require(readme.range(of: "## English"))
        #expect(russian.lowerBound < english.lowerBound)
        for part in [String(readme[russian.lowerBound..<english.lowerBound]), String(readme[english.lowerBound...])] {
            #expect(part.contains("scripts/install.sh"))
            #expect(part.contains("macOS 14"))
        }
        #expect(!readme.contains("в разработке") && !readme.contains("in development"))
        #expect(FileManager.default.isExecutableFile(atPath: packageRoot.appendingPathComponent("scripts/install.sh").path))
    }

    @Test("Состояние автозапуска берётся у системы", arguments: [
        (SMAppService.Status.enabled, AutostartState.on),
        (.notRegistered, .off),
        (.notFound, .off),
        (.requiresApproval, .needsApproval),
    ])
    func state(status: SMAppService.Status, expected: AutostartState) {
        let agent = FakeAgent()
        agent.status = status
        #expect(LaunchCoordinator(agent: agent, environment: [:]).autostartState == expected)
    }

    @Test("Выключение автозапуска не убирает задание, а включение ставит его, если его нет, сохранив всё перед этим")
    func plainCopy() {
        let agent = FakeAgent()
        let launch = LaunchCoordinator(agent: agent, environment: [:], defaults: MemoryDefaults())
        var saved = 0
        #expect(launch.setAutostart(true) { saved += 1 })
        #expect(agent.registered == 1)
        #expect(launch.autostartState == .on)
        #expect(launch.shouldReopenSettings(), "копия задания откроет настройки снова")
        #expect(launch.setAutostart(false) { saved += 1 })
        #expect(agent.unregistered == 0)
        #expect(agent.registered == 1)
        #expect(launch.autostartState == .off)
        #expect(saved == 2)
    }

    @Test("Копия, которая сама и есть задание, выключает автозапуск и остаётся")
    func agentCopyStays() {
        let agent = FakeAgent()
        agent.status = .enabled
        let launch = LaunchCoordinator(agent: agent, environment: ["BORIS_LAUNCHD": "1"], defaults: MemoryDefaults())
        #expect(launch.setAutostart(false) {})
        #expect(agent.unregistered == 0)
        #expect(launch.autostartState == .off)
        #expect(!launch.shouldReopenSettings(), "ничья копия не сменилась")
    }

    @Test("Система отказала: об этом сказано")
    func refused() {
        let agent = FakeAgent()
        agent.refuses = true
        let launch = LaunchCoordinator(agent: agent, environment: [:], defaults: MemoryDefaults())
        #expect(!launch.setAutostart(true) {})
        #expect(!launch.setAutostart(false) {})
        #expect(launch.autostartState == .off)
    }

    @Test("Обычному запуску открывать настройки незачем")
    func noReopenByDefault() {
        #expect(!LaunchCoordinator(agent: FakeAgent(), environment: [:]).shouldReopenSettings())
    }
}

@Suite("Проверка собранного приложения")
struct BuiltAppCheckTests {
    private let app = URL(fileURLWithPath: "/Applications/Boris.app")

    @Test("Внутри приложения уведомления настоящие, а проверка с BORIS_SMOKE=1 обходится без них")
    func smokeKeepsBannersOff() {
        #expect(BannerChannel.canRun(bundle: app, environment: [:]))
        #expect(!BannerChannel.canRun(bundle: app, environment: ["BORIS_SMOKE": "1"]))
        #expect(!BannerChannel.canRun(bundle: URL(fileURLWithPath: "/x/.build/debug"), environment: [:]), "вне приложения центр уведомлений падает")
    }

    /// The measurement refuses to run where real notifications could go out, and the script that runs it inside the built app must get past that.
    @Test("Замер в check-network.py проходит проверку режима замера внутри приложения")
    func networkCheckGetsPastTheGuard() throws {
        let script = try String(contentsOf: packageRoot.appendingPathComponent("scripts/check-network.py"), encoding: .utf8)
        let line = try #require(script.split(separator: "\n").first { $0.contains("BORIS_APP_MEASURE=") })
        #expect(line.contains("BORIS_STATE_DIR="))
        #expect(line.contains("BORIS_SMOKE=\"1\""))
        #expect(!BannerChannel.canRun(bundle: app, environment: ["BORIS_SMOKE": "1", "BORIS_STATE_DIR": "/tmp/x", "BORIS_APP_MEASURE": "10"]))
    }
}
