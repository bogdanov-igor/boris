import Foundation
import Testing

/// Tests that measure time: how soon something shows up, or how long the main thread waits.
///
/// In the shared test process they ran beside hundreds of other tests, which held the main thread and every thread of the pool,
/// so a failure measured those tests and not the code. Here they have a process of their own, which runs after the others are done,
/// and they take turns inside it. Their limits are the same as before.
@Suite("Замеры времени", .serialized)
enum TimingTests {}

/// A throwaway folder removed when the value goes away.
final class TempFolder: @unchecked Sendable {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("boris-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    func write(_ name: String, _ text: String) -> URL {
        let file = url.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: file, atomically: false, encoding: .utf8)
        return file
    }

    func append(_ name: String, _ text: String) {
        let file = url.appendingPathComponent(name)
        guard let handle = try? FileHandle(forWritingTo: file) else { return }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(text.utf8))
        try? handle.close()
    }
}

/// Set once from another thread, read by the test.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
