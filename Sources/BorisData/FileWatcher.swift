import CoreServices
import Foundation

/// A change noticed by the file system, reduced to what the scanner has to look at again.
public enum FileChange: Sendable, Equatable, Hashable {
    case run(String)
    /// Something changed in a session's `workflows` folder, where final files appear.
    case session(String)
    case discovery
    case sessions
    /// A transcript was written directly in this project folder.
    case project(String)
}

public enum FileChangeParser {
    public static func changes(in paths: [String]) -> Set<FileChange> {
        var result: Set<FileChange> = []
        for path in paths {
            if let range = path.range(of: "/subagents/workflows/wf_") {
                let rest = path[range.lowerBound...].dropFirst("/subagents/workflows/".count)
                if let run = rest.split(separator: "/").first { result.insert(.run(String(run))) }
            } else if path.contains("/sessions") {
                result.insert(.sessions)
            } else if let session = session(in: path) {
                // Final files appear here. A directory-level event has no run id, only its folder.
                result.insert(.session(session))
                result.insert(.discovery)
            } else if path.contains("/subagents/workflows") {
                result.insert(.discovery)
            } else if let project = projectFolder(in: path) {
                result.insert(.project(project))
            }
        }
        return result
    }

    /// `.../projects/<project>` itself, with or without a file name after it.
    private static func projectFolder(in path: String) -> String? {
        let parts = path.split(separator: "/").map(String.init)
        guard let index = parts.lastIndex(of: "projects"), index + 1 < parts.count, parts.count <= index + 3 else { return nil }
        if parts.count == index + 3, !parts[index + 2].hasSuffix(".jsonl") { return nil }
        return "/" + parts[...(index + 1)].joined(separator: "/")
    }

    /// `.../projects/<project>/<session>/workflows[/scripts]`.
    private static func session(in path: String) -> String? {
        let parts = path.split(separator: "/").map(String.init)
        guard let index = parts.lastIndex(of: "workflows"), index > 0, parts[index - 1] != "subagents" else { return nil }
        return parts[index - 1]
    }
}

/// Directory-level FSEvents. They only say "look here", which keeps bursts of hundreds of writes cheap.
public final class FileWatcher: @unchecked Sendable {
    private let handler: @Sendable ([String]) -> Void
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "app.boris.filewatcher", qos: .utility)

    public init(handler: @escaping @Sendable ([String]) -> Void) {
        self.handler = handler
    }

    deinit { stop() }

    public func start(paths: [URL], latency: TimeInterval = 0.5) {
        stop()
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let raw = unsafeBitCast(eventPaths, to: NSArray.self)
            watcher.handler((0..<count).compactMap { raw[$0] as? String })
        }
        guard let created = FSEventStreamCreate(
            nil,
            callback,
            &context,
            paths.map(\.path) as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            UInt32(kFSEventStreamCreateFlagUseCFTypes)
        ) else { return }
        stream = created
        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
