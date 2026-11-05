import Foundation
import BorisCore

public enum SessionReader {
    public struct Result: Sendable, Equatable {
        public var sessions: [SessionInfo]
        public var unreadable: Int
    }

    /// Reads only `<pid>.json`. The neighbouring `.key` files are credentials and are never opened.
    public static func read(_ paths: ClaudePaths) -> Result {
        var sessions: [SessionInfo] = []
        var unreadable = 0
        for name in FileInfo.names(in: paths.sessions) where name.hasSuffix(".json") {
            let url = paths.sessions.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url), let session = parse(data, fileName: name) else {
                unreadable += 1
                continue
            }
            sessions.append(session)
        }
        return Result(sessions: sessions, unreadable: unreadable)
    }

    static func parse(_ data: Data, fileName: String) -> SessionInfo? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessionId = object["sessionId"] as? String
        else { return nil }
        let pidFromName = Int32(fileName.replacingOccurrences(of: ".json", with: ""))
        guard let pid = (object["pid"] as? NSNumber)?.int32Value ?? pidFromName else { return nil }
        var session = SessionInfo(
            sessionId: sessionId,
            pid: pid,
            cwd: object["cwd"] as? String,
            entrypoint: object["entrypoint"] as? String,
            name: object["name"] as? String,
            status: object["status"] as? String,
            waitingFor: object["waitingFor"] as? String,
            version: object["version"] as? String,
            procStart: ProcStart.parse(object["procStart"] as? String),
            startedAt: milliseconds(object["startedAt"]),
            statusUpdatedAt: milliseconds(object["statusUpdatedAt"])
        )
        session.nameSource = object["nameSource"] as? String
        return session
    }

    private static func milliseconds(_ value: Any?) -> Date? {
        guard let number = value as? NSNumber else { return nil }
        return Date(timeIntervalSince1970: number.doubleValue / 1000)
    }

    /// Whether the file describes a process that is really running now.
    public static func isLive(_ session: SessionInfo, tolerance: TimeInterval = 2) -> Bool {
        guard let start = ProcessInspector.startTime(pid: session.pid) else { return false }
        if let declared = session.procStart {
            return abs(start.timeIntervalSince(declared)) <= tolerance
        }
        return true
    }
}
