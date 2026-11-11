import BorisCore
import Darwin
import Foundation
import Testing
@testable import BorisData

@Suite("Живость сессий на настоящих процессах")
struct SessionLifeTests {
    private func startedProcess() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        return process
    }

    private func procStart(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter.string(from: date)
    }

    private func writeSession(_ folder: TempFolder, pid: Int32, start: Date, id: String = "s1") {
        let updated = Int(Date().timeIntervalSince1970 * 1000)
        folder.write(
            "sessions/\(pid).json",
            #"{"sessionId":"\#(id)","pid":\#(pid),"procStart":"\#(procStart(start))","cwd":"/x/proj","entrypoint":"cli","status":"busy","statusUpdatedAt":\#(updated)}"#
        )
    }

    @Test("После kill -9 файл остаётся, а сессия становится прерванной")
    func killedProcess() async throws {
        let folder = TempFolder()
        let process = try startedProcess()
        defer { if process.isRunning { process.terminate() } }
        let pid = process.processIdentifier
        let start = try #require(ProcessInspector.startTime(pid: pid))
        writeSession(folder, pid: pid, start: start)
        let scanner = RunScanner(paths: ClaudePaths(root: folder.url))

        let alive = await scanner.scan(now: Date())
        #expect(alive.sessions.map(\.sessionId) == ["s1"])
        #expect(alive.endedSessions.isEmpty)
        #expect(WorkBuilder.build(world: alive, runs: []).sessions.first?.state == .running)

        #expect(kill(pid, SIGKILL) == 0)
        waitUntilGone(process)

        let dead = await scanner.scan(now: Date())
        #expect(dead.sessions.isEmpty)
        #expect(dead.endedSessions.map(\.sessionId) == ["s1"])
        let model = WorkBuilder.build(world: dead, runs: [])
        #expect(model.sessions.first?.state == .interrupted)
        #expect(!model.isWorking)
    }

    @Test("Номер процесса занят другим: сессия не считается живой")
    func reusedPid() async throws {
        let folder = TempFolder()
        let pid = ProcessInfo.processInfo.processIdentifier
        let start = try #require(ProcessInspector.startTime(pid: pid))
        // The file says the process started a day earlier, so this pid now belongs to someone else.
        writeSession(folder, pid: pid, start: start.addingTimeInterval(-86_400))
        let world = await RunScanner(paths: ClaudePaths(root: folder.url)).scan(now: Date())
        #expect(world.sessions.isEmpty)
        #expect(world.endedSessions.map(\.sessionId) == ["s1"])
    }

    @Test("Файл, оставленный давно, не считается сегодняшней работой")
    func oldLeftover() async throws {
        let folder = TempFolder()
        folder.write("sessions/99999.json", #"{"sessionId":"old","pid":99999,"cwd":"/x","status":"busy","statusUpdatedAt":1000000}"#)
        let world = await RunScanner(paths: ClaudePaths(root: folder.url)).scan(now: Date())
        #expect(world.endedSessions.isEmpty)
    }

    @Test("Живая сессия ждёт разрешения по самому файлу, без хуков")
    func waitingFromFile() async throws {
        let folder = TempFolder()
        let pid = ProcessInfo.processInfo.processIdentifier
        let start = try #require(ProcessInspector.startTime(pid: pid))
        folder.write(
            "sessions/\(pid).json",
            #"{"sessionId":"s1","pid":\#(pid),"procStart":"\#(procStart(start))","cwd":"/x","status":"waiting","waitingFor":"approve Bash: npm test"}"#
        )
        let world = await RunScanner(paths: ClaudePaths(root: folder.url)).scan(now: Date())
        let session = try #require(WorkBuilder.build(world: world, runs: []).sessions.first)
        #expect(session.state == .waiting)
        #expect(session.waitingFor == .permission(tool: "Bash"))
    }
}
