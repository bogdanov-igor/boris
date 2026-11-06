#if DEBUG
import AppKit
import BorisCore
import BorisData
import Foundation

/// `BORIS_SNAPSHOT=/folder BORIS_APP_MEASURE=seconds` runs the real model and engine and prints one JSON line per stage:
/// how soon there is something to show, what the first read of the logs costs in memory and on the main thread, and the CPU at rest.
/// It opens no window and no menu bar item, and sends no notification. Claude's folder comes from `CLAUDE_CONFIG_DIR`,
/// and Boris's own files from `BORIS_STATE_DIR`, without which it does not start.
@MainActor
enum AppMeasure {
    private struct Reading {
        var cpuSeconds: Double
        var footprint: UInt64
        var peak: UInt64
    }

    private static func read() -> Reading {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        guard result == 0 else { return Reading(cpuSeconds: 0, footprint: 0, peak: 0) }
        // Not the times in `usage`: on Apple silicon they are in ticks of a clock, not nanoseconds, and the difference is a factor of 40.
        var times = rusage()
        getrusage(RUSAGE_SELF, &times)
        let cpu = Double(times.ru_utime.tv_sec + times.ru_stime.tv_sec) + Double(times.ru_utime.tv_usec + times.ru_stime.tv_usec) / 1_000_000
        return Reading(cpuSeconds: cpu, footprint: usage.ri_phys_footprint, peak: usage.ri_lifetime_max_phys_footprint)
    }

    /// The longest the main thread was away. A timer that fires late means the interface could not have answered either.
    @MainActor
    private final class MainThreadWatch {
        private let tick: TimeInterval = 0.05
        private var timer: Timer?
        private var last = Date()
        private(set) var longest: TimeInterval = 0

        func start() {
            last = Date()
            longest = 0
            timer = Timer.scheduledTimer(withTimeInterval: tick, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.fired() }
            }
        }

        private func fired() {
            let now = Date()
            longest = max(longest, now.timeIntervalSince(last) - tick)
            last = now
        }

        func stop() {
            timer?.invalidate()
            timer = nil
        }
    }

    /// The highest memory seen within a stage. The system's own peak covers the whole run, so it cannot tell stages apart.
    private final class MemoryWatch: @unchecked Sendable {
        private let lock = NSLock()
        private var highest: UInt64 = 0
        private let source = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))

        func start() {
            source.schedule(deadline: .now(), repeating: 0.05)
            source.setEventHandler { [weak self] in self?.sample() }
            source.resume()
        }

        private func sample() {
            var usage = rusage_info_v4()
            let result = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
            }
            guard result == 0 else { return }
            lock.withLock { highest = max(highest, usage.ri_phys_footprint) }
        }

        func takeHighest() -> UInt64 {
            lock.withLock {
                defer { highest = 0 }
                return highest
            }
        }

        func stop() {
            source.cancel()
        }
    }

    private static func megabytes(_ bytes: UInt64) -> Int {
        Int(bytes / (1024 * 1024))
    }

    private static func say(_ stage: String, _ fields: [String: Any]) {
        var line = fields
        line["stage"] = stage
        if let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]), let text = String(data: data, encoding: .utf8) {
            print(text)
            fflush(stdout)
        }
    }

    private static func until(seconds: TimeInterval, _ done: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if done() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return done()
    }

    /// A stage of reading: the main thread and the memory are watched, and it is over when `done` says so.
    private static func reading(_ stage: String, within limit: TimeInterval, _ done: () -> Bool) async -> Bool {
        let main = MainThreadWatch()
        let memory = MemoryWatch()
        let began = Date()
        main.start()
        memory.start()
        let finished = await until(seconds: limit, done)
        main.stop()
        memory.stop()
        say(stage, [
            "seconds": (Date().timeIntervalSince(began) * 100).rounded() / 100,
            "finished": finished,
            "stallMs": Int(main.longest * 1000),
            "highestMB": megabytes(memory.takeHighest()),
            "footprintMB": megabytes(read().footprint),
            "peakMB": megabytes(read().peak),
        ])
        return finished
    }

    /// Nothing is watched here, since the watching costs CPU as well.
    private static func resting(_ stage: String, seconds: TimeInterval) async {
        let before = read()
        try? await Task.sleep(for: .seconds(seconds))
        let after = read()
        say(stage, [
            "seconds": seconds,
            "cpuPercent": ((after.cpuSeconds - before.cpuSeconds) / seconds * 10000).rounded() / 100,
            "footprintMB": megabytes(after.footprint),
            "peakMB": megabytes(after.peak),
        ])
    }

    static func runIfRequested() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard let text = environment["BORIS_APP_MEASURE"], let rest = Double(text) else { return false }
        // Boris's own real files and a real notification are both out of the question for a measurement.
        guard environment["BORIS_STATE_DIR"] != nil, !BannerChannel.canRun else {
            FileHandle.standardError.write(Data("BORIS_APP_MEASURE needs BORIS_STATE_DIR, and BORIS_SMOKE=1 inside an app bundle.\n".utf8))
            exit(2)
        }
        Task { @MainActor in
            let model = AppModel(settings: AppSettings(defaults: nil), store: StateStore(), live: true)
            model.start()
            let limit: TimeInterval = 1500
            let opened = await reading("first data on screen", within: limit) { model.loaded }
            let read = await reading("first read of the logs", within: limit) { model.usage.book != nil && model.usage.progress == nil }
            // What the read leaves behind matters more than its peak, since it stays for as long as the app runs.
            try? await Task.sleep(for: .seconds(5))
            say("what is showing", ["sessions": model.work.sessions.count, "active": model.activeSessions.count, "tokenRecords": model.usage.records.count])
            await resting("at rest, windows closed", seconds: rest)

            model.setLookingClosely(true)
            model.page = .projects
            model.refreshPastSessions()
            let projects = await reading("Projects opened for the first time", within: limit) { model.pastLoaded }
            let follower = Task { await model.losses.follow(model) }
            let losses = await reading("Losses opened for the first time", within: limit) { model.losses.book != nil }
            follower.cancel()
            model.page = .now
            model.setLookingClosely(false)
            try? await Task.sleep(for: .seconds(5))
            await resting("at rest after every page, windows closed", seconds: rest)

            await model.stop()
            exit(opened && read && projects && losses ? 0 : 1)
        }
        return true
    }
}
#endif
