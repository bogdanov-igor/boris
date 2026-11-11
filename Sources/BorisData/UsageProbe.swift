import BorisCore
import Darwin
import Foundation

/// Keeps the limits fresh without touching the network or any token: Claude Code itself is started for a few seconds and asked for `/usage`,
/// which rewrites its own cache. What it prints is only searched for its trust question and never kept.
public struct UsageProbe: Sendable {
    public enum Outcome: Sendable, Equatable {
        case refreshed, failed
    }

    public var binary: URL
    /// An empty folder of its own, which is how its sessions are told apart and hidden from the lists.
    public var folder: URL
    public var profile: URL
    /// Set when Claude Code keeps its settings somewhere other than the usual place.
    public var configFolder: String?
    public var trustAfter: TimeInterval = 1
    public var askAfter: TimeInterval = 4
    /// Counted only while the Mac is awake. A refresh takes 6 to 9 seconds, the trust question included.
    public var timeout: TimeInterval = 20
    /// How long it gets to remove its own session file on the way out.
    public var exitGrace: TimeInterval = 8
    var clock = ProbeClock.mac

    public init(binary: URL, folder: URL, profile: URL, configFolder: String?) {
        self.binary = binary
        self.folder = folder
        self.profile = profile
        self.configFolder = configFolder
    }

    /// Claude Code does not rewrite a cache this young, and it is fresh anyway.
    static let youngCache: TimeInterval = 90

    /// Blocks for up to `timeout` and `exitGrace`, so it goes on a background queue.
    public func run() -> Outcome {
        if Date().timeIntervalSince1970 - fetchedAt() < Self.youngCache {
            AppLog.note(.limitsAlreadyFresh)
            return .refreshed
        }
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0 else { return Self.failed(.noTerminal) }
        defer { close(master) }
        var name = [CChar](repeating: 0, count: 128)
        // `ptsname` shares one buffer across threads. Without O_NOCTTY this app could become the terminal's owner and get its hang-up signal.
        guard grantpt(master) == 0, unlockpt(master) == 0, ptsname_r(master, &name, name.count) == 0 else { return Self.failed(.noTerminal) }
        let slave = open(name, O_RDWR | O_NOCTTY)
        guard slave >= 0 else { return Self.failed(.noTerminal) }
        let terminal = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
        var size = winsize(ws_row: 50, ws_col: 150, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, TIOCSWINSZ, &size)
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)

        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = binary
        process.arguments = ["--no-chrome", "--setting-sources", "local"]
        process.currentDirectoryURL = folder
        // A clean environment and no shared settings: no hooks, and a child of this app must look like nothing else.
        var environment = ["TERM": "xterm-256color"]
        for key in ["HOME", "USER", "LOGNAME", "PATH", "SHELL", "TMPDIR", "LANG"] {
            environment[key] = ProcessInfo.processInfo.environment[key]
        }
        if let configFolder { environment["CLAUDE_CONFIG_DIR"] = configFolder }
        process.environment = environment
        process.standardInput = terminal
        process.standardOutput = terminal
        process.standardError = terminal
        do {
            try process.run()
        } catch {
            return Self.failed(.couldNotStart)
        }
        var buffer = [UInt8](repeating: 0, count: 8192)
        let clock = clock
        defer {
            // Its output is still read meanwhile: on a full terminal buffer it would hang while exiting. Force is the last resort.
            process.terminate()
            let deadline = clock.awake() + exitGrace
            while process.isRunning, clock.awake() < deadline {
                _ = read(master, &buffer, buffer.count)
                usleep(100_000)
            }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }

        let before = fetchedAt()
        var seenFile = FileInfo.modified(profile)
        let began = clock.awake()
        let sleptBefore = clock.asleep()
        var screen = [UInt8]()
        var answeredTrust = false
        var asked = false
        // An answer to the trust question moves this: the screen behind it needs its own time to come up.
        var askFrom = began + askAfter
        func send(_ text: String) {
            _ = text.withCString { write(master, $0, strlen($0)) }
        }
        while clock.awake() - began < timeout, process.isRunning {
            // With the lid closed the Mac wakes for 2 to 10 seconds every few minutes, and Claude Code froze halfway when it fell asleep again.
            // Waiting on into the next such wake kept it there for minutes, so a sleep ends the attempt at once.
            if clock.asleep() - sleptBefore > 1 { return fetchedAt() != before ? .refreshed : Self.failed(.macSlept) }
            let count = read(master, &buffer, buffer.count)
            if count > 0 {
                screen.append(contentsOf: buffer[0..<count])
                if screen.count > 16 * 1024 { screen.removeFirst(screen.count - 16 * 1024) }
            }
            let elapsed = clock.awake() - began
            if !answeredTrust, elapsed > trustAfter, String(decoding: screen, as: UTF8.self).lowercased().contains("trust") {
                // The cursor starts on «No, exit». This is Boris's own empty folder, not a project.
                answeredTrust = true
                usleep(500_000)
                send("\u{1B}[B")
                usleep(500_000)
                send("\r")
                screen.removeAll()
                askFrom = clock.awake() + askAfter
                continue
            }
            // Typed earlier, the command and its Enter would answer whatever comes up first, and the trust question starts on «No, exit».
            if !asked, clock.awake() > askFrom, Self.showsText(screen) {
                asked = true
                send("/usage")
                usleep(800_000)
                send("\r")
            }
            // The file can be big, so it is parsed only after it has changed.
            if asked, FileInfo.modified(profile) != seenFile {
                seenFile = FileInfo.modified(profile)
                if fetchedAt() != before { return .refreshed }
            }
            usleep(200_000)
        }
        // It may have written the cache and quit between two looks.
        return fetchedAt() != before ? .refreshed : Self.failed(.noFreshData)
    }

    private static func failed(_ why: LogWord) -> Outcome {
        AppLog.note(.limitsRefreshProblem, .word(why))
        return .failed
    }

    /// Whether the program has drawn anything yet. Terminal settings and a window title come before that and are not a screen.
    static func showsText(_ screen: [UInt8]) -> Bool {
        var text = String(decoding: screen, as: UTF8.self)
        for sequence in ["\u{1B}\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)?", "\u{1B}\\[[0-9;?>=<]*[ -/]*[@-~]"] {
            text = text.replacingOccurrences(of: sequence, with: "", options: .regularExpression)
        }
        return text.range(of: "[A-Za-z]{3}", options: .regularExpression) != nil
    }

    private func fetchedAt() -> Double {
        UsageReader.read(profile)?.fetchedAt?.timeIntervalSince1970 ?? 0
    }
}

/// Time as the probe counts it: how long the Mac has been awake and how long it has slept. Both only grow, and setting the clock moves neither.
struct ProbeClock: Sendable {
    var awake: @Sendable () -> TimeInterval
    var asleep: @Sendable () -> TimeInterval

    // The first clock goes on while the Mac sleeps, the second one stops.
    static let mac = ProbeClock(awake: { seconds(CLOCK_UPTIME_RAW) }, asleep: { seconds(CLOCK_MONOTONIC_RAW) - seconds(CLOCK_UPTIME_RAW) })

    private static func seconds(_ clock: clockid_t) -> TimeInterval {
        TimeInterval(clock_gettime_nsec_np(clock)) / 1_000_000_000
    }
}
