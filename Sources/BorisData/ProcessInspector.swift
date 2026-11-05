import Foundation

/// Asks the kernel about processes directly, without starting `ps`.
public enum ProcessInspector {
    /// The real start time of a running process, or nil if it is not running.
    public static func startTime(pid: Int32) -> Date? {
        guard let info = info(pid: pid), info.kp_proc.p_stat != SZOMB else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
    }

    public static func parent(pid: Int32) -> Int32? {
        info(pid: pid)?.kp_eproc.e_ppid
    }

    /// The process itself and everything above it, up to the system's first process.
    public static func ancestors(of pid: Int32) -> [Int32] {
        var result: [Int32] = []
        var current: Int32? = pid
        while let value = current, value > 1, !result.contains(value) {
            result.append(value)
            current = parent(pid: value)
        }
        return result
    }

    private static func info(pid: Int32) -> kinfo_proc? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        return info
    }
}
