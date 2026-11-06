import BorisCore
import Darwin
import Foundation

/// What happened to the log since a viewer last looked.
public enum LogChange: Sendable, Equatable {
    case added(LogRecord)
    /// The last record happened again: it now counts this many, the last of them at this time.
    case repeated(count: Int, lastAt: Date)
    /// New lines stopped being saved, or are being saved again.
    case saving(Bool)
}

/// Keeps the log in one file under Boris's folder.
///
/// Everything happens on its own queue, so `write` costs the caller no more than handing over a small value. Any failure here is swallowed
/// on purpose: the log must never be why the app misbehaves. A file that cannot be opened is tried again later, and `isBroken` lets the viewer say so.
public final class AppLogStore: LogSink, @unchecked Sendable {
    public struct Limits: Sendable {
        public var maxBytes = 5 * 1024 * 1024
        /// Trimming goes below the limit, so that the file is not rewritten for every new line once it is full.
        public var trimmedBytes = 4 * 1024 * 1024
        public var keep: TimeInterval = 24 * 3600
        public var tidyEvery: TimeInterval = 3600
        /// A line that comes back after a longer pause stays a line of its own: a sound every five minutes is a pattern worth seeing.
        public var repeatWindow: TimeInterval = 60
        /// How long a repeat count may wait for the file and the viewer.
        public var repeatFlush: TimeInterval = 10
        public var reopenAfter: TimeInterval = 30

        public init() {}
    }

    public static var defaultFile: URL { BorisPaths.support.appendingPathComponent("app.log") }

    public let file: URL
    private let limits: Limits
    private let clock: @Sendable () -> Date
    private let queue = DispatchQueue(label: "app.boris.log", qos: .utility)

    private var descriptor: Int32 = -1
    private var size = 0
    private var lastOpenTry = Date.distantPast
    private var lastTidy = Date.distantPast
    private var last: LogRecord?
    /// Repeats of `last` not yet in the file.
    private var unwritten = 0
    private var flushPlanned = false
    private var viewer: (@Sendable (LogChange) -> Void)?
    private var broken = false {
        didSet { if broken != oldValue { viewer?(.saving(!broken)) } }
    }

    public init(file: URL = AppLogStore.defaultFile, limits: Limits = Limits(), clock: @escaping @Sendable () -> Date = { Date() }) {
        self.file = file
        self.limits = limits
        self.clock = clock
    }

    deinit {
        if descriptor >= 0 { close(descriptor) }
    }

    /// The first `AppLogStore` installed, which in the app is the only one.
    public static var current: AppLogStore? {
        AppLog.installed.lazy.compactMap { $0 as? AppLogStore }.first
    }

    public func write(_ record: LogRecord) {
        queue.async { self.take(record) }
    }

    public func flush() {
        queue.sync { self.writeRepeats() }
    }

    /// Lets a viewer start from all that is kept and hear what comes after, with nothing lost or told twice in between.
    /// Reads the file, so it does not belong on the main thread.
    public func attach(_ viewer: @escaping @Sendable (LogChange) -> Void) -> [LogRecord] {
        queue.sync {
            writeRepeats()
            self.viewer = viewer
            return readKept()
        }
    }

    public func detach() {
        queue.async { self.viewer = nil }
    }

    public func records() -> [LogRecord] {
        queue.sync {
            writeRepeats()
            return readKept()
        }
    }

    /// The newest lines, without reading the whole file.
    public func newest(_ count: Int) -> [LogRecord] {
        queue.sync {
            writeRepeats()
            let from = clock().addingTimeInterval(-limits.keep)
            return Array(LogFile.parse(tail(32 * 1024)).filter { $0.lastAt >= from }.suffix(count))
        }
    }

    /// The log cannot be written right now.
    public var isBroken: Bool {
        queue.sync { broken }
    }

    // MARK: - On the queue

    private func take(_ record: LogRecord) {
        if var repeated = last, repeated.says(sameAs: record), record.at.timeIntervalSince(repeated.lastAt) <= limits.repeatWindow {
            repeated.count += 1
            repeated.lastAt = record.at
            last = repeated
            unwritten += 1
            planFlush()
            return
        }
        writeRepeats()
        guard let data = LogFile.line(record).data(using: .utf8) else { return }
        let now = clock()
        if now.timeIntervalSince(lastTidy) >= limits.tidyEvery || size + data.count > limits.maxBytes { tidy(now: now, incoming: data.count) }
        guard append(data, now: now) else { return }
        last = record
        viewer?(.added(record))
    }

    private func planFlush() {
        guard !flushPlanned else { return }
        flushPlanned = true
        queue.asyncAfter(deadline: .now() + limits.repeatFlush) { [weak self] in
            self?.flushPlanned = false
            self?.writeRepeats()
        }
    }

    private func writeRepeats() {
        guard unwritten > 0, let last else { return }
        let extra = unwritten
        unwritten = 0
        if let data = LogFile.repeatLine(at: last.lastAt, extra: extra).data(using: .utf8) {
            let now = clock()
            if size + data.count > limits.maxBytes { tidy(now: now, incoming: data.count) }
            _ = append(data, now: now)
        }
        viewer?(.repeated(count: last.count, lastAt: last.lastAt))
    }

    private func append(_ data: Data, now: Date) -> Bool {
        guard openIfNeeded(now: now) else { return false }
        // Trimming did not work out, and the limit holds all the same.
        guard size + data.count <= limits.maxBytes else {
            markBroken()
            return false
        }
        let written = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        guard written == data.count else {
            markBroken()
            return false
        }
        size += written
        broken = false
        return true
    }

    private func markBroken() {
        broken = true
        closeFile()
    }

    private func closeFile() {
        if descriptor >= 0 { close(descriptor) }
        descriptor = -1
    }

    private func openIfNeeded(now: Date) -> Bool {
        if descriptor >= 0 { return true }
        // Not at every line: a file that cannot be opened would then cost a failed call for each of them.
        guard now.timeIntervalSince(lastOpenTry) >= limits.reopenAfter else { return false }
        lastOpenTry = now
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Not through a link, and without waiting for a reader if something other than a file has taken this name.
        let opened = open(file.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_NONBLOCK, S_IRUSR | S_IWUSR)
        guard opened >= 0 else {
            broken = true
            return false
        }
        var info = stat()
        guard fstat(opened, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            close(opened)
            broken = true
            return false
        }
        descriptor = opened
        size = Int(info.st_size)
        broken = false
        endLastLine()
        return true
    }

    /// A crash can leave half a line at the end, and the next one must not stick to it.
    private func endLastLine() {
        guard size > 0, let handle = try? FileHandle(forReadingFrom: file) else { return }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: UInt64(size - 1))) != nil, let end = try? handle.read(upToCount: 1), end.first != 0x0A else { return }
        var newline: UInt8 = 0x0A
        if Darwin.write(descriptor, &newline, 1) == 1 { size += 1 }
    }

    /// The last bytes of the file, starting at a whole line.
    private func tail(_ wanted: Int) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: file), let length = try? handle.seekToEnd() else { return Data() }
        defer { try? handle.close() }
        let start = length > UInt64(wanted) ? length - UInt64(wanted) : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return Data() }
        guard start > 0, let firstEnd = data.firstIndex(of: 0x0A) else { return data }
        return data[data.index(after: firstEnd)...]
    }

    private func readKept() -> [LogRecord] {
        let from = clock().addingTimeInterval(-limits.keep)
        return LogFile.parse(tail(limits.maxBytes)).filter { $0.lastAt >= from }
    }

    /// Drops what is too old or does not fit, and whatever cannot be read. Looks first, because usually there is nothing to do.
    private func tidy(now: Date, incoming: Int) {
        lastTidy = now
        writeRepeats()
        if descriptor >= 0 {
            // Someone removed the file while it was open, and lines would go nowhere.
            var info = stat()
            if fstat(descriptor, &info) != 0 || info.st_nlink == 0 {
                closeFile()
                lastOpenTry = .distantPast
            }
        }
        _ = openIfNeeded(now: now)
        let from = now.addingTimeInterval(-limits.keep)
        guard size + incoming > limits.maxBytes || startsBefore(from) else { return }

        var kept = LogFile.parse(tail(limits.maxBytes)).filter { $0.lastAt >= from }.map(LogFile.lines)
        var total = kept.reduce(0) { $0 + $1.utf8.count }
        var dropped = 0
        while total + incoming > limits.trimmedBytes, dropped < kept.count {
            total -= kept[dropped].utf8.count
            dropped += 1
        }
        kept.removeFirst(dropped)
        replaceFile(with: kept.joined())
    }

    private func startsBefore(_ date: Date) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        guard let start = try? handle.read(upToCount: 64), !start.isEmpty else { return false }
        // What cannot be read counts as old, so that a damaged start of the file goes away too.
        return start.withUnsafeBytes { raw in LogFile.time(atStartOf: raw.bindMemory(to: UInt8.self)) ?? .distantPast } < date
    }

    private func replaceFile(with text: String) {
        let fresh = file.deletingLastPathComponent().appendingPathComponent(file.lastPathComponent + ".new")
        guard FileManager.default.createFile(atPath: fresh.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) else {
            markBroken()
            return
        }
        guard rename(fresh.path, file.path) == 0 else {
            unlink(fresh.path)
            return
        }
        // The open file is the old one now. What comes next goes to the new one.
        closeFile()
        lastOpenTry = .distantPast
        _ = openIfNeeded(now: clock())
    }
}
