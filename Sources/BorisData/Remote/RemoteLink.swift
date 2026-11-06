import Foundation

/// Actions on a machine's hooks, for when the person asks. They go over a connection of their own and do not depend on the tunnel.
public struct RemoteHelper: Sendable {
    public var tool: SSHTool
    public var machine: String
    public var wait: Int

    public init(tool: SSHTool, machine: String, wait: Int) {
        self.tool = tool
        self.machine = machine
        self.wait = wait
    }

    /// The program itself, as it goes to the machine.
    public static var source: Data { Data(RemoteHelperSource.text.utf8) }

    /// The exact lines that will change in the machine's settings. The settings themselves do not leave it.
    public func previewHooks() async -> RemoteHookResult? { await act("preview") }
    public func installHooks() async -> RemoteHookResult? { await act("install") }
    public func uninstallHooks() async -> RemoteHookResult? { await act("uninstall") }
    /// Takes the hooks and the helper off the machine.
    public func purge() async -> RemoteHookResult? { await act("purge") }

    /// Nil means the machine could not be reached or could not answer.
    private func act(_ verb: String) async -> RemoteHookResult? {
        let result = await tool.run(machine: machine, command: RemoteCommand.helper(verb, wait: wait))
        guard result.failure == nil else { return nil }
        return RemoteHookResult(line: result.output)
    }
}

/// Keeps one tunnel to one machine alive: the helper is put in place, ssh runs with the machine's socket forwarded to a socket here,
/// the helper's numbers come back on its output, and a connection that drops is tried again for as long as the machine is on the list.
public final class RemoteLink: @unchecked Sendable {
    public enum State: Sendable, Equatable {
        case connecting
        case up(since: Date)
        case down(RemoteFailure)
        case stopped
    }

    public struct Timing: Sendable {
        /// Waits between attempts. The last one repeats for as long as it takes.
        public var retries: [TimeInterval] = [2, 5, 15, 30, 60]
        /// A connection that held this long starts counting attempts again.
        public var steady: TimeInterval = 60
        /// Longer than this without a word from the helper means the connection is gone, whatever ssh thinks.
        public var silence: TimeInterval = 60
        public var prepareTimeout: TimeInterval = 45

        public init() {}
    }

    /// Far more than a list of numbers can ever be. A machine must not be able to fill this Mac's memory.
    private static let lineLimit = 64 * 1024 * 1024
    private static let errorsKept = 16 * 1024

    private let machine: String
    private let localSocket: String
    private let tool: SSHTool
    private let wait: Int
    private let timing: Timing
    private let onState: @Sendable (State) -> Void
    private let onMessage: @Sendable (RemoteMessage) -> Void
    private let queue = DispatchQueue(label: "app.boris.remote-link")

    private var wanted = false
    private var attemptNumber = 0
    private var failures = 0
    private var process: Process?
    private var pending = Data()
    private var errors = Data()
    private var upSince: Date?
    private var lastHeard = Date()
    private var isBusy = false
    private var overflowed = false

    public init(machine: String, localSocket: String, tool: SSHTool, wait: Int, timing: Timing = Timing(), onState: @escaping @Sendable (State) -> Void, onMessage: @escaping @Sendable (RemoteMessage) -> Void) {
        self.machine = machine
        self.localSocket = localSocket
        self.tool = tool
        self.wait = wait
        self.timing = timing
        self.onState = onState
        self.onMessage = onMessage
    }

    public func start() {
        queue.async {
            guard !self.wanted else { return }
            self.wanted = true
            self.attempt()
        }
    }

    public func stop() {
        queue.sync {
            wanted = false
            attemptNumber += 1
            process?.terminate()
            process = nil
            isBusy = false
        }
        onState(.stopped)
    }

    /// The person asked, or the Mac woke up: no reason to sit out the rest of a wait.
    public func retryNow() {
        queue.async {
            guard self.wanted, !self.isBusy else { return }
            self.failures = 0
            self.attempt()
        }
    }

    // MARK: - One attempt

    private func attempt() {
        guard wanted, !isBusy else { return }
        isBusy = true
        attemptNumber += 1
        let number = attemptNumber
        onState(.connecting)
        let (tool, machine, wait, timeout) = (tool, machine, wait, timing.prepareTimeout)
        Task.detached { [weak self] in
            let result = await tool.run(machine: machine, command: RemoteCommand.prepare(wait: wait), input: RemoteHelper.source, timeout: timeout)
            self?.queue.async { self?.prepared(result, number: number) }
        }
    }

    private func prepared(_ result: SSHResult, number: Int) {
        guard wanted, number == attemptNumber else { return }
        if let failure = result.failure {
            fail(failure)
            return
        }
        guard case .info(let home, let vitals)? = RemoteMessage(line: result.output) else {
            fail(.helperBroken)
            return
        }
        onMessage(.alive(vitals))
        openTunnel(home: home, number: number)
    }

    private func openTunnel(home: String, number: Int) {
        guard let executable = tool.executable else {
            fail(.noSSH)
            return
        }
        let process = Process()
        process.executableURL = executable
        process.environment = tool.environment
        process.arguments = SSHTool.arguments(
            machine: machine,
            forward: (remote: home + "/.boris/hook.sock", local: localSocket),
            command: RemoteCommand.helper("watch", wait: wait)
        )
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        pending = Data()
        errors = Data()
        overflowed = false
        upSince = nil
        lastHeard = Date()
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async { self?.heard(data, number: number) }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async {
                guard let self, number == self.attemptNumber, self.errors.count < Self.errorsKept else { return }
                self.errors.append(data)
            }
        }
        process.terminationHandler = { [weak self] ended in
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            let status = ended.terminationStatus
            self?.queue.asyncAfter(deadline: .now() + 0.05) { self?.exited(status: status, number: number) }
        }
        do {
            try process.run()
        } catch {
            fail(.noSSH)
            return
        }
        self.process = process
        watchSilence(number: number)
    }

    private func heard(_ data: Data, number: Int) {
        guard number == attemptNumber else { return }
        lastHeard = Date()
        pending.append(data)
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<newline]
            let message = RemoteMessage(line: Data(line))
            pending.removeSubrange(pending.startIndex...newline)
            if case .hello? = message, upSince == nil {
                let now = Date()
                upSince = now
                onState(.up(since: now))
            }
            if let message { onMessage(message) }
        }
        if pending.count > Self.lineLimit {
            overflowed = true
            process?.terminate()
        }
    }

    private func watchSilence(number: Int) {
        queue.asyncAfter(deadline: .now() + min(timing.silence / 4, 5)) { [weak self] in
            guard let self, number == self.attemptNumber, let process = self.process else { return }
            if Date().timeIntervalSince(self.lastHeard) > self.timing.silence {
                // It stays ours until its exit is seen, and that goes on to a new attempt.
                process.terminate()
                return
            }
            self.watchSilence(number: number)
        }
    }

    private func exited(status: Int32, number: Int) {
        guard wanted, number == attemptNumber else { return }
        process = nil
        let failure: RemoteFailure
        if overflowed {
            failure = .helperBroken
        } else if upSince != nil {
            failure = .dropped
        } else {
            failure = RemoteFailure.classify(status: status, stderr: String(decoding: errors, as: UTF8.self))
        }
        if let upSince, Date().timeIntervalSince(upSince) >= timing.steady { failures = 0 }
        fail(failure)
    }

    private func fail(_ failure: RemoteFailure) {
        isBusy = false
        onState(.down(failure))
        guard !timing.retries.isEmpty else { return }
        let delay = timing.retries[min(failures, timing.retries.count - 1)]
        failures += 1
        let number = attemptNumber
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.wanted, !self.isBusy, number == self.attemptNumber else { return }
            self.attempt()
        }
    }
}
