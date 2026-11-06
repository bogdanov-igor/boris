import Foundation
import BorisCore

/// A request held open until someone answers, the wait runs out or the hook goes away.
public struct PendingPermission: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let session: String
    /// The agent that asked, by its bare id, when it was not the main agent.
    public let agent: String?
    public let agentType: String?
    public let tool: String
    public let command: String
    public let content: RequestContent
    public let project: String?
    /// The session's working folder, which is what tells a file of the project from any other.
    public let cwd: String?
    /// Claude's permission mode at the moment of asking.
    public let mode: String?
    public let askedAt: Date
    public let deadline: Date
    /// Finds the end of this very call among the session's tools.
    public let digest: String?

    public init(id: UUID = UUID(), session: String, agent: String? = nil, agentType: String? = nil, tool: String, command: String = "", content: RequestContent, project: String? = nil, cwd: String? = nil, mode: String? = nil, askedAt: Date = Date(), deadline: Date = Date().addingTimeInterval(120), digest: String? = nil) {
        self.id = id
        self.session = session
        self.agent = agent
        self.agentType = agentType
        self.tool = tool
        self.command = command
        self.content = content
        self.project = project
        self.cwd = cwd
        self.mode = mode
        self.askedAt = askedAt
        self.deadline = deadline
        self.digest = digest
    }
}

/// Listens on a Unix socket only this user can reach. There is no network port, so no other process can impersonate Boris.
public final class HookServer: @unchecked Sendable {
    private let path: String
    private let queue = DispatchQueue(label: "app.boris.hooks", qos: .userInitiated)
    private var listener: Int32 = -1
    private var source: DispatchSourceRead?
    private var waiting: [UUID: (fd: Int32, source: DispatchSourceRead)] = [:]
    private var answerWindow: TimeInterval = 120
    /// A guard against running out of file descriptors. A request above it stays in Claude and its session still shows as waiting.
    private static let maxPending = 64

    public var onSignal: (@Sendable (HookSignal) -> Void)?
    public var onPermission: (@Sendable (PendingPermission) -> Void)?
    /// The hook went away by itself: Claude got its answer in another way, or the session closed.
    public var onPermissionGone: (@Sendable (UUID) -> Void)?
    /// The wait ran out, and the hook was let go without a decision.
    public var onPermissionExpired: (@Sendable (UUID) -> Void)?
    /// A tool with this input has finished.
    public var onToolDone: (@Sendable (_ session: String, _ digest: String) -> Void)?

    public init(path: String) {
        self.path = path
    }

    public static var defaultPath: String {
        movedPath ?? BorisPaths.support.appendingPathComponent("hook.sock").path
    }

    /// Where a check has put the socket. The real one is always in its place.
    public static var movedPath: String? {
        #if DEBUG
        ProcessInfo.processInfo.environment["BORIS_HOOK_SOCKET"]
        #else
        nil
        #endif
    }

    /// How long the next requests wait for an answer. Those already open keep their time.
    public func setAnswerWindow(_ seconds: TimeInterval) {
        queue.async { self.answerWindow = seconds }
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
        // The descriptor must outlive the source that watches it, or a new socket with the same number loses its events.
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
        return true
    }

    /// Every open hook sees its connection close and exits without a decision, so the requests stay in Claude.
    public func stop() {
        queue.sync {
            source?.cancel()
            source = nil
            listener = -1
            unlink(path)
            for (_, entry) in waiting { entry.source.cancel() }
            waiting = [:]
        }
    }

    /// Sends the answer down the connection of this exact request. An answer to a closed request goes nowhere.
    public func answer(_ id: UUID, _ answer: HookAnswer) {
        queue.async { [weak self] in
            guard let self, let entry = self.waiting.removeValue(forKey: id) else { return }
            _ = answer.line.withUnsafeBytes { write(entry.fd, $0.baseAddress, $0.count) }
            entry.source.cancel()
        }
    }

    /// Lets the hook go without a decision.
    public func release(_ id: UUID) {
        queue.async { [weak self] in
            self?.waiting.removeValue(forKey: id)?.source.cancel()
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
        // A hook that has just gone away must not take the whole app with it when the answer is written.
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        guard let payload = readMessage(fd) else {
            close(fd)
            return
        }
        guard payload["wait"] as? Bool == true else {
            close(fd)
            if let session = payload["session_id"] as? String, let digest = payload["input_digest"] as? String {
                onToolDone?(session, digest)
            }
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
        guard let session = payload["session_id"] as? String else {
            close(fd)
            return
        }
        let tool = payload["tool_name"] as? String ?? "?"
        guard waiting.count < Self.maxPending else {
            close(fd)
            onSignal?(.permissionAsked(session: session, tool: tool))
            return
        }
        let id = UUID()
        let now = Date()
        let window = answerWindow
        let flat = payload["command_text"] as? String ?? ""
        let request = PendingPermission(
            id: id,
            session: session,
            agent: (payload["agent_id"] as? String).map { $0.hasPrefix("agent-") ? String($0.dropFirst(6)) : $0 },
            agentType: payload["agent_type"] as? String,
            tool: tool,
            command: flat,
            content: RequestContent.parse(tool: tool, input: payload["tool_input"] as? [String: Any], flat: flat),
            project: (payload["cwd"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent },
            cwd: payload["cwd"] as? String,
            mode: payload["permission_mode"] as? String,
            askedAt: now,
            deadline: now.addingTimeInterval(window),
            digest: payload["input_digest"] as? String
        )
        // When the hook goes away, it closes its end, and the request disappears from the queue.
        let closed = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        closed.setEventHandler { [weak self] in
            guard let self else { return }
            var byte: UInt8 = 0
            guard read(fd, &byte, 1) <= 0, let entry = self.waiting.removeValue(forKey: id) else { return }
            entry.source.cancel()
            self.onPermissionGone?(id)
        }
        // Closing here and not earlier, because the descriptor must outlive the source that watches it.
        closed.setCancelHandler { close(fd) }
        closed.resume()
        waiting[id] = (fd, closed)
        // The clock of the wall: a Mac waking from sleep should not owe the person the hours it slept.
        queue.asyncAfter(wallDeadline: .now() + window) { [weak self] in
            guard let self, let entry = self.waiting.removeValue(forKey: id) else { return }
            entry.source.cancel()
            self.onPermissionExpired?(id)
        }
        onPermission?(request)
        onSignal?(.permissionAsked(session: session, tool: tool))
    }
}
