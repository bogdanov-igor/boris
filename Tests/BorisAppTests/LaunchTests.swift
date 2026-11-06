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
        // othersRun, isAgent, takesOver, isDebug
        (false, false, false, false, LaunchClaim.run),
        (false, true, false, false, .run),
        (true, false, false, false, .askOtherAndLeave),
        (true, true, false, false, .takeOverFromHandOpened),
        (true, false, true, false, .takeOverFromAgent),
        (false, false, true, false, .takeOverFromAgent),
        (true, true, false, true, .leaveQuietly),
        (true, false, false, true, .leaveQuietly),
        (true, false, true, true, .leaveQuietly),
        (false, false, false, true, .run),
    ])
    func claims(others: Bool, agent: Bool, takesOver: Bool, debug: Bool, expected: LaunchClaim) {
        #expect(LaunchCoordinator.claim(othersRun: others, isAgent: agent, takesOverFromAgent: takesOver, isDebug: debug) == expected)
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

    @Test("Обычная копия включает и выключает задание, сохранив всё перед этим")
    func plainCopy() {
        let agent = FakeAgent()
        var started = 0
        let launch = LaunchCoordinator(agent: agent, environment: [:]) { started += 1 }
        var saved = 0
        #expect(launch.setAutostart(true) { saved += 1 })
        #expect(agent.registered == 1)
        #expect(launch.setAutostart(false) { saved += 1 })
        #expect(agent.unregistered == 1)
        #expect(saved == 2)
        #expect(started == 0)
    }

    @Test("Копия, которая сама и есть задание, не убирает его из-под себя: это делает новая копия и остаётся")
    func agentCopyHandsOver() {
        let agent = FakeAgent()
        agent.status = .enabled
        var started = 0
        var saved = 0
        let launch = LaunchCoordinator(agent: agent, environment: ["BORIS_LAUNCHD": "1"]) { started += 1 }
        #expect(launch.setAutostart(false) { saved += 1 })
        #expect(started == 1)
        #expect(saved == 1, "launchd убьёт эту копию без предупреждения")
        #expect(agent.unregistered == 0)
    }

    @Test("Новая копия убирает задание и работает, а настройки снова открыты")
    func plainCopyTakesOver() {
        let agent = FakeAgent()
        agent.status = .enabled
        // As a release build would. With no other copies listed, nothing is said to anybody.
        let launch = LaunchCoordinator(agent: agent, environment: ["BORIS_TAKE_OVER_FROM_AGENT": "1"], isDebug: false)
        #expect(launch.handOverToAgentIfNeeded() == false, "она не отдаёт работу заданию, которое сейчас уберёт")
        #expect(launch.claimInstance(others: []))
        #expect(agent.unregistered == 1)
        #expect(launch.shouldReopenSettings())
    }

    @Test("Система отказала: об этом сказано")
    func refused() {
        let agent = FakeAgent()
        agent.refuses = true
        let launch = LaunchCoordinator(agent: agent, environment: [:])
        #expect(!launch.setAutostart(true) {})
        #expect(!launch.setAutostart(false) {})
    }

    @Test("Обычному запуску открывать настройки незачем")
    func noReopenByDefault() {
        #expect(!LaunchCoordinator(agent: FakeAgent(), environment: [:]).shouldReopenSettings())
    }
}
