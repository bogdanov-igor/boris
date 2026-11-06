import BorisCore
import Darwin
import Foundation

/// What a reading needs to know from the rest of the app.
public struct LoadRequest: Sendable, Equatable {
    /// The process of each running session on this Mac.
    public var sessions: [String: Int32]
    public var off: LoadOff
    /// CPU load is the difference between two readings. After a pause the old one says nothing about now, so it is dropped.
    public var restart: Bool

    public init(sessions: [String: Int32] = [:], off: LoadOff = LoadOff(), restart: Bool = false) {
        self.sessions = sessions
        self.off = off
        self.restart = restart
    }
}

/// Reads the load straight from the kernel. No `ps` or `top` is started, and only this user's processes are looked at:
/// everybody else's load is in the rest, which is what remains of the Mac's total.
public actor MacLoadSampler {
    /// What a reading keeps about a process until the next one. Its name and path do not stay here.
    struct Seen: Equatable {
        var start: UInt64
        var cpuNanoseconds: UInt64
        /// Tells one program from another without keeping its name.
        var program: Int
        var mark: LoadGroup?

        /// - Parameters:
        ///   - before: what the last reading kept under this process number.
        ///   - mark: asked only for a new process or program, because it means looking up the path.
        /// - Returns: what to keep, and the CPU time spent since the last reading.
        static func next(after before: Seen?, start: UInt64, cpuNanoseconds: UInt64, program: Int, mark: () -> LoadGroup?) -> (seen: Seen, spent: UInt64) {
            // A number can be used again by a new process, which started at another moment.
            // A process not seen before started after the last reading, so all its time was spent since then.
            let sameProcess = before?.start == start ? before : nil
            // A process that turns into another program keeps its number, its start and its CPU time, as a shell does when it hands over to Claude.
            let sameProgram = sameProcess?.program == program ? sameProcess : nil
            let spent = cpuNanoseconds &- (sameProcess?.cpuNanoseconds ?? 0)
            let seen = Seen(start: start, cpuNanoseconds: cpuNanoseconds, program: program, mark: sameProgram.map(\.mark) ?? mark())
            return (seen, spent <= cpuNanoseconds ? spent : 0)
        }
    }

    private static let host = mach_host_self()
    /// Disk space and the size of the logs change slowly, and reading them costs more than everything else together.
    private static let diskPeriod: UInt64 = 60 * 1_000_000_000
    private static let logsPeriod: UInt64 = 300 * 1_000_000_000

    private let logRoots: @Sendable () -> [URL]
    private let ownPid = getpid()
    private let cores = ProcessInfo.processInfo.activeProcessorCount
    private let physicalMemory = ProcessInfo.processInfo.physicalMemory
    private let timebase: (numer: UInt64, denom: UInt64)
    private var pids = [Int32](repeating: 0, count: 4096)
    private(set) var seen: [Int32: Seen] = [:]
    private var previousAt: UInt64?
    private var previousTicks: (user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)?
    private var lastCPU: Double?
    private var disk: (at: UInt64, percent: Double?)?
    private var logs: (at: UInt64, bytes: UInt64?)?

    /// - Parameter logRoots: the folders where Claude keeps its logs.
    public init(logRoots: @escaping @Sendable () -> [URL]) {
        self.logRoots = logRoots
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        timebase = (UInt64(max(info.numer, 1)), UInt64(max(info.denom, 1)))
    }

    public func read(_ request: LoadRequest) -> MacLoad {
        if request.restart {
            previousAt = nil
            previousTicks = nil
            lastCPU = nil
            seen.removeAll(keepingCapacity: true)
        }
        let now = DispatchTime.now().uptimeNanoseconds
        let processes = readProcesses(now: now)
        let cpu = readTotalCPU()
        return LoadGrouping.load(
            processes: processes,
            sessions: request.sessions,
            off: request.off,
            totalCPU: cpu.percent,
            cpuPending: cpu.pending,
            usedMemory: Self.readUsedMemory(),
            physicalMemory: physicalMemory,
            diskPercent: readDisk(now: now),
            claudeLogs: readLogs(now: now)
        )
    }

    // MARK: - Processes

    private func readProcesses(now: UInt64) -> [LoadProcess] {
        let elapsed = previousAt.map { now - $0 }
        previousAt = now
        var next: [Int32: Seen] = [:]
        var result: [LoadProcess] = []
        for pid in listOwnPids() {
            guard let usage = Self.usage(of: pid), let info = Self.shortInfo(of: pid) else { continue }
            let nanoseconds = (usage.ri_user_time &+ usage.ri_system_time) * timebase.numer / timebase.denom
            let (kept, spent) = Seen.next(after: seen[pid], start: usage.ri_proc_start_abstime, cpuNanoseconds: nanoseconds, program: info.program) { markOf(pid) }
            next[pid] = kept
            let cpu = elapsed.map { LoadGrouping.percentOfMac(cpuNanoseconds: spent, overNanoseconds: $0, cores: cores) } ?? 0
            result.append(LoadProcess(pid: pid, parent: info.parent, mark: kept.mark, cpu: cpu, memory: usage.ri_phys_footprint))
        }
        seen = next
        return result
    }

    private func listOwnPids() -> ArraySlice<Int32> {
        let stride = MemoryLayout<Int32>.stride
        var used = proc_listpids(UInt32(PROC_UID_ONLY), getuid(), &pids, Int32(pids.count * stride))
        if Int(used) >= pids.count * stride {
            pids = [Int32](repeating: 0, count: pids.count * 2)
            used = proc_listpids(UInt32(PROC_UID_ONLY), getuid(), &pids, Int32(pids.count * stride))
        }
        return pids[0..<max(0, Int(used) / stride)]
    }

    /// Looks up the path, then forgets it: only what it says about the process stays.
    private func markOf(_ pid: Int32) -> LoadGroup? {
        if pid == ownPid { return .boris }
        guard let path = Self.path(of: pid) else { return nil }
        let isMachine = path.hasSuffix("/com.apple.Virtualization.VirtualMachine")
        return LoadGrouping.mark(path: path, responsible: isMachine ? Self.responsiblePath(for: pid) : nil)
    }

    private static func usage(of pid: Int32) -> rusage_info_v4? {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return result == 0 ? usage : nil
    }

    private static func shortInfo(of pid: Int32) -> (parent: Int32, program: Int)? {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size else { return nil }
        var hasher = Hasher()
        withUnsafeBytes(of: info.pbsi_comm) { hasher.combine(bytes: $0) }
        return (Int32(bitPattern: info.pbsi_ppid), hasher.finalize())
    }

    private static func path(of pid: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = Int(proc_pidpath(pid, &buffer, UInt32(buffer.count)))
        return length > 0 ? String(decoding: buffer[0..<length], as: UTF8.self) : nil
    }

    /// There is no public way to ask which program started a virtual machine. If the system ever removes this call,
    /// Cowork's load simply goes to the rest.
    private static func responsiblePath(for pid: Int32) -> String? {
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "responsibility_get_pid_responsible_for_pid") else { return nil }
        typealias Function = @convention(c) (pid_t) -> pid_t
        let responsible = unsafeBitCast(symbol, to: Function.self)(pid)
        return responsible > 0 ? path(of: responsible) : nil
    }

    // MARK: - The whole Mac

    private func readTotalCPU() -> (percent: Double?, pending: Bool) {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(Self.host, HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard result == KERN_SUCCESS else {
            previousTicks = nil
            lastCPU = nil
            return (nil, false)
        }
        let ticks = (user: info.cpu_ticks.0, system: info.cpu_ticks.1, idle: info.cpu_ticks.2, nice: info.cpu_ticks.3)
        defer { previousTicks = ticks }
        guard let old = previousTicks else { return (nil, true) }
        // The counters are 32 bits and wrap around, so the difference is taken with wrapping too.
        let busy = Double(ticks.user &- old.user) + Double(ticks.system &- old.system) + Double(ticks.nice &- old.nice)
        let total = busy + Double(ticks.idle &- old.idle)
        // The kernel updates the counters in bursts, measured up to 0.9 s apart, so no change means nothing new yet.
        guard total > 0 else { return (lastCPU, lastCPU == nil) }
        lastCPU = busy / total * 100
        return (lastCPU, false)
    }

    /// What Activity Monitor calls Memory Used: app memory, wired and compressed, without the file cache that is free for the taking.
    private static func readUsedMemory() -> UInt64? {
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        let appPages = UInt64(info.internal_page_count) &- min(UInt64(info.purgeable_count), UInt64(info.internal_page_count))
        return (appPages + UInt64(info.wire_count) + UInt64(info.compressor_page_count)) * UInt64(getpagesize())
    }

    private func readDisk(now: UInt64) -> Double? {
        if let disk, now - disk.at < Self.diskPeriod { return disk.percent }
        let percent = Self.diskPercent(of: FileManager.default.homeDirectoryForCurrentUser)
        disk = (now, percent)
        return percent
    }

    /// The same free space Finder shows, with what the system can clear up counted as free.
    static func diskPercent(of folder: URL) -> Double? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? folder.resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity, total > 0,
              let free = values.volumeAvailableCapacityForImportantUsage
        else { return nil }
        return min(max(1 - Double(free) / Double(total), 0), 1) * 100
    }

    private func readLogs(now: UInt64) -> UInt64? {
        if let logs, now - logs.at < Self.logsPeriod { return logs.bytes }
        let bytes = Self.size(of: logRoots())
        logs = (now, bytes)
        return bytes
    }

    /// Adds up the sizes the file system already knows. No file is opened. Nil when no folder exists.
    static func size(of folders: [URL]) -> UInt64? {
        let manager = FileManager.default
        var total: UInt64?
        for folder in folders {
            // The enumerator is happy to walk a folder that does not exist, and finds nothing.
            guard manager.fileExists(atPath: folder.path),
                  let walker = manager.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey], errorHandler: { _, _ in true })
            else { continue }
            total = total ?? 0
            for case let url as URL in walker {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                total = (total ?? 0) + UInt64(size)
            }
        }
        return total
    }
}
