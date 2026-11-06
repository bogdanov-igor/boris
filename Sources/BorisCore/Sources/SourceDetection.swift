import Darwin
import Foundation

/// Telling sources apart. The extension for VS Code runs in Cursor too and writes the same `claude-vscode` in the logs,
/// so only the processes around a session can tell those two apart.
public enum SourceDetection {
    /// What a session known to run in Cursor counts as, wherever its entrypoint is looked at.
    public static let cursorEntrypoint = "claude-cursor"

    /// Which editor a line of executables belongs to, starting from the process itself.
    public static func editor(inPaths paths: [String]) -> LoadGroup? {
        for path in paths {
            if path.contains("/.cursor/extensions/") { return .cursor }
            if path.contains("/.vscode/extensions/") { return .vsCode }
            switch LoadGrouping.mark(path: path) {
            case .cursor: return .cursor
            case .vsCode: return .vsCode
            default: continue
            }
        }
        return nil
    }

    /// The editor a running process is under, by asking the kernel about it and its parents.
    public static func editor(of pid: Int32) -> LoadGroup? {
        editor(inPaths: linePaths(from: pid))
    }

    /// - Parameters:
    ///   - entrypoint: what Claude says about itself.
    ///   - editor: what the processes say, asked only when the entrypoint leaves a choice.
    public static func source(entrypoint: String?, editor: () -> LoadGroup?) -> SourceID? {
        guard let entrypoint else { return nil }
        if entrypoint.contains("vscode"), editor() == .cursor { return .cursor }
        return SourceID(entrypoint: entrypoint)
    }

    /// The executables of a process and its parents.
    static func linePaths(from pid: Int32) -> [String] {
        var paths: [String] = []
        var current = pid
        var seen = Set<Int32>()
        while current > 1, seen.insert(current).inserted, seen.count <= 32 {
            if let path = executable(of: current) { paths.append(path) }
            var info = proc_bsdshortinfo()
            let size = Int32(MemoryLayout<proc_bsdshortinfo>.stride)
            guard proc_pidinfo(current, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size else { break }
            current = Int32(bitPattern: info.pbsi_ppid)
        }
        return paths
    }

    private static func executable(of pid: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = Int(proc_pidpath(pid, &buffer, UInt32(buffer.count)))
        return length > 0 ? String(decoding: buffer[0..<length], as: UTF8.self) : nil
    }
}

/// Finds out whose a transcript is by reading as little of it as possible.
public enum TranscriptHead {
    private static let marker = Data("\"entrypoint\":\"".utf8)
    /// Real logs have this word about 5 KB in. A record's text is in the same stretch, so no more is read than it takes, and nothing is parsed or kept.
    private static let step = 16 * 1024
    private static let limit = 256 * 1024

    /// - Returns: the word itself and how many bytes it took to find it. In the text of a record the marker would have its quotes escaped, so only a field of the record matches.
    public static func entrypoint(in url: URL) -> (entrypoint: String?, bytesRead: Int) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return (nil, 0) }
        defer { try? handle.close() }
        var data = Data()
        while data.count < limit, let chunk = try? handle.read(upToCount: step), !chunk.isEmpty {
            data.append(chunk)
            if let start = data.range(of: marker)?.upperBound, let end = data[start...].firstIndex(of: 0x22) {
                return (String(decoding: data[start..<end], as: UTF8.self), data.count)
            }
        }
        return (nil, data.count)
    }
}
