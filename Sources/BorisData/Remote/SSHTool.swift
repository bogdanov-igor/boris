import Foundation

/// Why a machine cannot be reached, in terms a person can do something about.
public enum RemoteFailure: Sendable, Equatable {
    case noSSH
    /// The machine wants a password or a code, or refused the key. Boris cannot type anything into ssh.
    case refused
    /// This Mac does not know the machine yet, or its key changed.
    case hostKey
    case unknownName
    case unreachable
    case noPython
    case dropped
    /// The helper ran and said nothing that makes sense.
    case helperBroken
    case other(Int32)

    /// Goes by what ssh prints. That text is only searched and never kept, shown or logged: a machine's banner can say anything.
    static func classify(status: Int32, stderr: String) -> RemoteFailure {
        if status == RemoteCommand.noPythonStatus || status == 127 { return .noPython }
        let text = stderr.lowercased()
        func says(_ words: String...) -> Bool { words.contains { text.contains($0) } }
        if says("permission denied", "too many authentication failures", "no supported authentication") { return .refused }
        if says("host key verification failed", "remote host identification has changed") { return .hostKey }
        if says("could not resolve hostname", "name or service not known", "nodename nor servname") { return .unknownName }
        if says("connection refused", "timed out", "no route to host", "network is unreachable", "host is down") { return .unreachable }
        if says("connection closed", "closed by remote host", "connection reset", "broken pipe", "timeout, server") { return .dropped }
        return .other(status)
    }
}

/// What one command on the machine gave back.
public struct SSHResult: Sendable, Equatable {
    public var status: Int32
    public var output: Data
    public var failure: RemoteFailure?

    public init(status: Int32, output: Data, failure: RemoteFailure?) {
        self.status = status
        self.output = output
        self.failure = failure
    }
}

/// What runs on the machine. Everything goes through `sh -c`, because a person's login shell may be anything.
enum RemoteCommand {
    static let noPythonStatus: Int32 = 72
    static let folder = #""$HOME/.boris""#
    private static let helper = #""$HOME/.boris/boris-hook""#
    private static let new = #""$HOME/.boris/boris-hook.new""#

    /// Puts the helper in place when it differs, and clears the socket a dropped connection left behind: a machine refuses to forward over one that exists.
    static func prepare(wait: Int) -> String {
        let script = [
            "umask 077",
            // The umask does nothing for a folder that is already there.
            "mkdir -p \(folder) && chmod 700 \(folder) || exit 71",
            "command -v python3 >/dev/null 2>&1 || exit \(noPythonStatus)",
            "cat > \(new) || exit 73",
            "if cmp -s \(new) \(helper); then rm -f \(new); else chmod 700 \(new) && mv -f \(new) \(helper) || exit 73; fi",
            #"rm -f "$HOME/.boris/hook.sock""#,
            "exec python3 \(helper) info --wait \(wait)",
        ].joined(separator: "; ")
        return "sh -c '\(script)'"
    }

    static func helper(_ verb: String, wait: Int) -> String {
        "sh -c 'exec python3 \(helper) \(verb) --wait \(wait)'"
    }
}

/// The ssh on this Mac, with the person's own keys and config. Boris adds only what keeps it from asking questions and from touching other connections.
public struct SSHTool: Sendable {
    public var executable: URL?
    public var environment: [String: String]

    public init(executable: URL?, environment: [String: String]) {
        self.executable = executable
        self.environment = environment
    }

    /// Whatever `ssh` the PATH finds, and the system's one when it finds none.
    public static func system(environment: [String: String] = ProcessInfo.processInfo.environment) -> SSHTool {
        SSHTool(executable: find(in: environment) ?? URL(fileURLWithPath: "/usr/bin/ssh"), environment: environment)
    }

    public static func find(in environment: [String: String]) -> URL? {
        for folder in (environment["PATH"] ?? "").split(separator: ":") {
            let file = URL(fileURLWithPath: String(folder)).appendingPathComponent("ssh")
            if FileManager.default.isExecutableFile(atPath: file.path) { return file }
        }
        return nil
    }

    /// `BatchMode` makes ssh fail instead of waiting for a password nobody can type. Its own connection, and never a shared one:
    /// if this one became the master of a person's terminal sessions, stopping Boris would cut them off.
    static let options = [
        "-T", "-x", "-a",
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=10",
        "-o", "ServerAliveInterval=15",
        "-o", "ServerAliveCountMax=3",
        "-o", "ControlMaster=no",
        "-o", "ControlPath=none",
        "-o", "RemoteCommand=none",
        "-o", "PermitLocalCommand=no",
        "-o", "ExitOnForwardFailure=no",
        "-o", "LogLevel=ERROR",
    ]

    /// A colon separates the two sides, so one inside a path has to be escaped.
    static func forwardSpec(remote: String, local: String) -> String {
        func escaped(_ path: String) -> String {
            path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ":", with: "\\:")
        }
        return "\(escaped(remote)):\(escaped(local))"
    }

    static func arguments(machine: String, forward: (remote: String, local: String)? = nil, command: String) -> [String] {
        var result = options
        if let forward { result += ["-R", forwardSpec(remote: forward.remote, local: forward.local)] }
        return result + ["--", machine, command]
    }

    /// One command on the machine. Blocks nothing: ssh runs as its own process, and a stuck one is stopped at `timeout`.
    public func run(machine: String, command: String, input: Data? = nil, timeout: TimeInterval = 45) async -> SSHResult {
        guard RemoteMachine.isAcceptable(machine), let executable else { return SSHResult(status: -1, output: Data(), failure: .noSSH) }
        return await withCheckedContinuation { continuation in
            SSHOneShot(executable: executable, environment: environment, arguments: Self.arguments(machine: machine, command: command), input: input, timeout: timeout) {
                continuation.resume(returning: $0)
            }.start()
        }
    }
}

/// One run of ssh from start to finish, with its output collected.
private final class SSHOneShot: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.boris.ssh")
    private let process = Process()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private let input: Data?
    private let timeout: TimeInterval
    private let finished: @Sendable (SSHResult) -> Void
    private var output = Data()
    private var errors = Data()
    private var timedOut = false
    private var done = false

    private static let errorsKept = 16 * 1024

    init(executable: URL, environment: [String: String], arguments: [String], input: Data?, timeout: TimeInterval, finished: @escaping @Sendable (SSHResult) -> Void) {
        process.executableURL = executable
        process.environment = environment
        process.arguments = arguments
        self.input = input
        self.timeout = timeout
        self.finished = finished
    }

    func start() {
        queue.async { self.launch() }
    }

    private func launch() {
        process.standardOutput = stdout
        process.standardError = stderr
        // From a file, because writing to a pipe of a process that has just died would raise a signal that ends this app.
        var inputFile: URL?
        if let input {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("boris-ssh-\(UUID().uuidString)")
            FileManager.default.createFile(atPath: file.path, contents: input, attributes: [.posixPermissions: 0o600])
            inputFile = file
            process.standardInput = (try? FileHandle(forReadingFrom: file)) ?? FileHandle.nullDevice
        } else {
            process.standardInput = FileHandle.nullDevice
        }
        defer { if let inputFile { try? FileManager.default.removeItem(at: inputFile) } }
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.queue.async { self?.output.append(data) }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.queue.async {
                guard let self, self.errors.count < Self.errorsKept else { return }
                self.errors.append(data)
            }
        }
        process.terminationHandler = { [self] _ in
            // A moment for the last output to arrive, without trusting a child that may hold the pipe open forever.
            queue.asyncAfter(deadline: .now() + 0.05) { self.finish() }
        }
        do {
            try process.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            done = true
            finished(SSHResult(status: -1, output: Data(), failure: .noSSH))
            return
        }
        queue.asyncAfter(deadline: .now() + timeout) { [self] in
            guard !done, process.isRunning else { return }
            timedOut = true
            process.terminate()
        }
    }

    private func finish() {
        guard !done else { return }
        done = true
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        output.append(Self.drain(stdout))
        errors.append(Self.drain(stderr))
        let status = process.terminationStatus
        let failure: RemoteFailure? = timedOut ? .unreachable : (status == 0 ? nil : RemoteFailure.classify(status: status, stderr: String(decoding: errors, as: UTF8.self)))
        finished(SSHResult(status: status, output: output, failure: failure))
    }

    private static func drain(_ pipe: Pipe) -> Data {
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            guard count > 0 else { return result }
            result.append(contentsOf: buffer[0..<count])
        }
    }
}
