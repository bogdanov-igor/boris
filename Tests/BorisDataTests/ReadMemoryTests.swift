import BorisData
import Foundation
import Testing

/// A list of past sessions reads thousands of files in one go, on one thread, with no pause in which Foundation would let go of what it read.
/// On 3 GB of real logs that reached 1.4 GB, and a person saw 850 MB in Activity Monitor.
@Suite("Память при чтении логов", .serialized)
struct ReadMemoryTests {
    private func footprint() -> UInt64 {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        return result == 0 ? usage.ri_phys_footprint : 0
    }

    @Test("Каждый прочитанный лог отпускает память сразу, а не когда прочитаны все")
    func eachReadLetsGo() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("boris-memory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("session.jsonl")
        // One long line: finding the title is then as quick as it gets, and the whole 4 MB are still read into memory each time.
        let megabyte = 1024 * 1024
        try Data(repeating: 0x78, count: 4 * megabyte).write(to: file)

        let before = footprint()
        var highest = before
        for _ in 0..<100 {
            _ = TranscriptReader.title(in: file)
            highest = max(highest, footprint())
        }
        // Without a pool of its own these 100 reads hold on to 400 MB. Tests running alongside may take a little of the margin.
        let grown = Int(highest) - Int(before)
        #expect(grown < 200 * megabyte, "grew by \(grown / megabyte) MB")
    }
}
