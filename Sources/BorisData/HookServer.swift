import Foundation
import BorisCore

/// A permission request held open until someone answers or the hook gives up.
public struct PendingPermission: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let session: String
    /// The agent that asked, when it was not the session itself.
    public let agent: String?
    public let tool: String
    public let command: String
    public let project: String?
}

/// Listens on a Unix socket only this user can reach. There is no network port, so no other process can impersonate Boris.
public final class HookServer: @unchecked Sendable {
    private let path: String
    private let queue = DispatchQueue(label: "app.boris.hooks", qos: .userInitiated)
    private var listener: Int32 = -1
    private var source: DispatchSourceRead?
    private var waiting: [UUID: (fd: Int32, source: DispatchSourceRead)] = [:]
    private static let maxPending = 8

    public var onSignal: (@Sendable (HookSignal) -> Void)?
    public var onPermission: (@Sendable (PendingPermission) -> Void)?
    public var onPermissionGone: (@Sendable (UUID) -> Void)?

    public init(path: String) {
        self.path = path
    }

    public static var defaultPath: String {
        ProcessInfo.processInfo.environment["BORIS_HOOK_SOCKET"] ?? BorisPaths.support.appendingPathComponent("hook.sock").path
    }

    public func start() -> Bool {
        queue.sync { startOnQueue() }
    }

    private func startOnQueue() -> Bool {
        guard listener < 0 else { return true }
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd)
            return false
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let previous = umask(0o077)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(previous)
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 32) == 0 else {
            close(fd)
            return false
        }
        listener = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptClient() }
        source.resume()
        self.source = source
        return true
    }

    public func stop() {
        queue.sync {
            source?.cancel()
            source = nil
            if listener >= 0 { close(listener) }
            listener = -1
            unlink(path)
            for (_, entry) in waiting {
                entry.source.cancel()
                close(entry.fd)
            }
            waiting = [:]
        }
    }

    /// Sends the answer down the connection of this exact request. An answer to a closed request goes nowhere.
    public func answer(_ id: UUID, allow: Bool) {
        queue.async { [weak self] in
            guard let self, let entry = self.waiting.removeValue(forKey: id) else { return }
            let text = allow ? "allow\n" : "deny\n"
            _ = text.withCString { write(entry.fd, $0, strlen($0)) }
            entry.source.cancel()
            close(entry.fd)
        }
    }

    private func acceptClient() {
        let fd = accept(listener, nil, nil)
        guard fd >= 0 else { return }
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
            close(fd)
            return
        }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        guard let payload = readMessage(fd) else {
            close(fd)
            return
        }
        guard payload["wait"] as? Bool == true else {
            close(fd)
            if let signal = HookSignal(payload: payload) { onSignal?(signal) }
            return
        }
        hold(fd, payload: payload)
    }

    private func readMessage(_ fd: Int32) -> [String: Any]? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while data.count < 1024 * 1024 {
            let count = read(fd, &buffer, buffer.count)
            guard count > 0 else { break }
            data.append(contentsOf: buffer[0..<count])
            if buffer[0..<count].contains(0x0A) { break }
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func hold(_ fd: Int32, payload: [String: Any]) {
        guard waiting.count < Self.maxPending, let session = payload["session_id"] as? String else {
            close(fd)
            return
        }
        let id = UUID()
        let tool = payload["tool_name"] as? String ?? "?"
        let request = PendingPermission(
            id: id,
            session: session,
            agent: payload["agent_id"] as? String,
            tool: tool,
            command: payload["command_text"] as? String ?? "",
            project: (payload["cwd"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent }
        )
        // When the hook gives up, it closes its end, and the request disappears from the menu.
        let closed = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        closed.setEventHandler { [weak self] in
            guard let self else { return }
            var byte: UInt8 = 0
            guard read(fd, &byte, 1) <= 0, self.waiting.removeValue(forKey: id) != nil else { return }
            closed.cancel()
            close(fd)
            self.onPermissionGone?(id)
        }
        closed.resume()
        waiting[id] = (fd, closed)
        onPermission?(request)
        onSignal?(.permissionAsked(session: session, tool: tool))
    }
}
