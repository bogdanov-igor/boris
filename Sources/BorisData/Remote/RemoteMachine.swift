import BorisCore
import Foundation

/// A machine the person added. Nothing here is a secret: its name is what they type after `ssh`, and everything else about getting in stays with ssh.
public struct RemoteMachine: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    /// The person agreed to the hooks on that machine and has not taken them off.
    public var hooksWanted: Bool

    public init(name: String, id: String = RemoteMachine.newId(), hooksWanted: Bool = false) {
        self.id = id
        self.name = name
        self.hooksWanted = hooksWanted
    }

    /// Names the local socket and the file of numbers, so it has to fit into a socket's short path.
    public static func newId() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
    }

    /// What ssh will take as a machine and not as an option. `-oProxyCommand=…` typed as a name would run a program on this Mac.
    public static func isAcceptable(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 253, let first = name.unicodeScalars.first else { return false }
        let start = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_["))
        let rest = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-%+@:[]"))
        return name.unicodeScalars.allSatisfy { $0.isASCII && rest.contains($0) } && start.contains(first)
    }
}

/// Where Boris keeps what it knows about remote machines: the list and their numbers. Neither is a secret, and nothing is lost for good without them.
public struct RemoteStore: Sendable {
    public let folder: URL

    /// A socket's whole path has to fit in 104 bytes on a Mac.
    private static let socketPathLimit = 104

    public init(folder: URL = BorisPaths.support) {
        self.folder = folder
    }

    private var machinesFile: URL { folder.appendingPathComponent("remote-machines.json") }
    private var ownFolder: URL { folder.appendingPathComponent("remote", isDirectory: true) }

    public func machines() -> [RemoteMachine] {
        guard let data = try? Data(contentsOf: machinesFile) else { return [] }
        return (try? JSONDecoder().decode([RemoteMachine].self, from: data)) ?? []
    }

    public func save(_ machines: [RemoteMachine]) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(machines) {
            try? data.write(to: machinesFile, options: .atomic)
        }
    }

    public func rows(of id: String) -> [RemoteSpendRow] {
        guard let data = try? Data(contentsOf: ownFolder.appendingPathComponent("\(id).json")) else { return [] }
        return (try? JSONDecoder().decode([RemoteSpendRow].self, from: data)) ?? []
    }

    public func save(rows: [RemoteSpendRow], of id: String) {
        makeOwnFolder()
        if let data = try? JSONEncoder().encode(rows) {
            try? data.write(to: ownFolder.appendingPathComponent("\(id).json"), options: .atomic)
        }
    }

    /// What ssh forwards the machine's socket to. A home folder with a long name moves it to the per-user temporary folder.
    public func socket(of id: String) -> String {
        let usual = ownFolder.appendingPathComponent("\(id).sock").path
        if usual.utf8.count < Self.socketPathLimit {
            makeOwnFolder()
            return usual
        }
        return (NSTemporaryDirectory() as NSString).appendingPathComponent("boris-\(id).sock")
    }

    public func forget(_ id: String) {
        try? FileManager.default.removeItem(at: ownFolder.appendingPathComponent("\(id).json"))
        unlink(socket(of: id))
    }

    private func makeOwnFolder() {
        try? FileManager.default.createDirectory(at: ownFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
}
