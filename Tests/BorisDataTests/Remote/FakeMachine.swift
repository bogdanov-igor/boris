import Foundation
@testable import BorisData

/// A "remote machine" in a temporary folder, reached through the fake ssh from the fixtures. No real machine, no real ssh, no network.
final class FakeMachine: @unchecked Sendable {
    let root: URL
    var home: URL { root.appendingPathComponent("home") }
    var control: URL { root.appendingPathComponent("control") }
    private var bin: URL { root.appendingPathComponent("bin") }
    var claude: URL { home.appendingPathComponent(".claude") }
    var boris: URL { home.appendingPathComponent(".boris") }
    /// A socket's whole path has to fit in 104 bytes, so the folder goes by a short name.
    var localSocket: String { root.appendingPathComponent("here.sock").path }

    init() {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("r\(UUID().uuidString.prefix(8))")
        for folder in [home, control, bin, claude] {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/fake-ssh")
        try? FileManager.default.copyItem(at: script, to: bin.appendingPathComponent("ssh"))
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    var environment: [String: String] {
        [
            "PATH": "\(bin.path):/usr/bin:/bin",
            "FAKE_SSH_CONTROL": control.path,
            "FAKE_SSH_HOME": home.path,
            "BORIS_REMOTE_TICK": "0.05",
            "BORIS_REMOTE_MANAGED": root.appendingPathComponent("managed").path,
        ]
    }

    /// Found the way the app finds it: on the PATH.
    var tool: SSHTool { SSHTool(executable: SSHTool.find(in: environment), environment: environment) }

    func failNext(_ message: String) {
        try? message.write(to: control.appendingPathComponent("fail"), atomically: true, encoding: .utf8)
    }

    func stopFailing() {
        try? FileManager.default.removeItem(at: control.appendingPathComponent("fail"))
    }

    func dropConnection() {
        FileManager.default.createFile(atPath: control.appendingPathComponent("drop").path, contents: Data())
    }

    func allowConnections() {
        try? FileManager.default.removeItem(at: control.appendingPathComponent("drop"))
    }

    func refuseSocketForward() {
        FileManager.default.createFile(atPath: control.appendingPathComponent("nosocket").path, contents: Data())
    }

    /// Every ssh this machine was called with.
    var calls: [[String]] {
        let text = (try? String(contentsOf: control.appendingPathComponent("calls"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map { $0.components(separatedBy: "\u{1F}") }
    }

    /// Puts the helper where a connection would, for checks that run it directly.
    func installHelper() {
        try? FileManager.default.createDirectory(at: boris, withIntermediateDirectories: true)
        let file = boris.appendingPathComponent("boris-hook")
        try? RemoteHelper.source.write(to: file)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
    }

    struct Output {
        var status: Int32
        var text: String
        var data: Data
    }

    /// Runs the helper as this machine would, with its output collected. A file stands in for stdin: writing to a pipe of a process that has exited ends the test run.
    func helper(_ arguments: [String], input: String? = nil, environment extra: [String: String] = [:]) throws -> Output {
        installHelper()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", boris.appendingPathComponent("boris-hook").path] + arguments
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin", "BORIS_REMOTE_TICK": "0.05", "BORIS_REMOTE_MANAGED": root.appendingPathComponent("managed").path].merging(extra) { _, new in new }
        let stdinFile = root.appendingPathComponent("stdin-\(UUID().uuidString)")
        try (input ?? "").write(to: stdinFile, atomically: true, encoding: .utf8)
        process.standardInput = try FileHandle(forReadingFrom: stdinFile)
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try? FileManager.default.removeItem(at: stdinFile)
        return Output(status: process.terminationStatus, text: String(decoding: data, as: UTF8.self), data: data)
    }

    // MARK: - What Claude would leave on this machine

    @discardableResult
    func writeClaudeFile(_ path: String, _ text: String) -> URL {
        let file = claude.appendingPathComponent(path)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    func appendClaudeFile(_ path: String, _ text: String) {
        guard let handle = try? FileHandle(forWritingTo: claude.appendingPathComponent(path)) else { return }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(text.utf8))
        try? handle.close()
    }

    /// A session listed as running, with this test process standing in for Claude.
    func listSession(_ id: String, status: String = "busy", cwd: String = "/srv/app", extra: String = "") {
        let pid = ProcessInfo.processInfo.processIdentifier
        writeClaudeFile("sessions/\(pid).json", #"{"pid":\#(pid),"sessionId":"\#(id)","cwd":"\#(cwd)","status":"\#(status)","startedAt":1762400000000,"statusUpdatedAt":1762400100000,"version":"2.1.0"\#(extra)}"#)
    }

    func unlistSessions() {
        try? FileManager.default.removeItem(at: claude.appendingPathComponent("sessions"))
    }

    /// One assistant message with spend. Everything Claude writes around the numbers is what must never leave.
    static func assistantLine(id: String = "m1", input: Int = 100, output: Int = 20, cacheRead: Int = 3, cacheWrite: Int = 4, model: String = "claude-sonnet-5-5", cwd: String = "/srv/app", timestamp: String = "2026-11-05T12:03:00.000Z", text: String = "ok") -> String {
        #"{"type":"assistant","timestamp":"\#(timestamp)","cwd":"\#(cwd)","message":{"id":"\#(id)","model":"\#(model)","stop_reason":"end_turn","content":[{"type":"text","text":"\#(text)"}],"usage":{"input_tokens":\#(input),"output_tokens":\#(output),"cache_read_input_tokens":\#(cacheRead),"cache_creation_input_tokens":\#(cacheWrite)}}}"# + "\n"
    }
}

/// Waits for something that happens on another thread or in another process. The machine may be busy, so the limit is generous.
func arrives(seconds: Double = 40, _ condition: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}
