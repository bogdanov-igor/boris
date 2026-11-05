import Foundation

/// Sorts processes into groups by who they are and who started them. Everything here works on plain values, so any tree can be tried in a test.
public enum LoadGrouping {
    /// What an executable says about itself.
    /// - Parameter responsible: the executable of the program that asked for this process. A virtual machine has launchd for a parent,
    ///   so only this tells Cowork's machine from Docker's.
    public static func mark(path: String, responsible: String? = nil) -> LoadGroup? {
        let components = path.split(separator: "/")
        guard let name = components.last else { return nil }
        if name == "claude" || path.contains("/claude/versions/") { return .claude }
        if name == "com.apple.Virtualization.VirtualMachine" {
            return responsible.flatMap { mark(path: $0) } == .claudeDesktop ? .cowork : nil
        }
        for component in components where component.hasSuffix(".app") {
            if component.hasPrefix("Visual Studio Code") { return .vsCode }
            switch component {
            case "Cursor.app": return .cursor
            case "Claude.app": return .claudeDesktop
            case "Boris.app": return .boris
            default: break
            }
        }
        return nil
    }

    /// CPU time as a percent of the whole Mac: three busy cores of ten are 30.
    public static func percentOfMac(cpuNanoseconds: UInt64, overNanoseconds elapsed: UInt64, cores: Int) -> Double {
        guard elapsed > 0, cores > 0 else { return 0 }
        return Double(cpuNanoseconds) / Double(elapsed) / Double(cores) * 100
    }

    /// The group of each process, with every process in exactly one.
    /// - Parameters:
    ///   - sessions: the processes of running sessions. They and everything under them are Claude, whichever program they run in.
    ///   - off: sources with reading turned off. Their processes are the rest, Claude working inside them included.
    public static func groups(of processes: [LoadProcess], sessions: Set<Int32>, off: Set<LoadGroup> = []) -> [Int32: LoadGroup] {
        let tree = Tree(processes)
        var result: [Int32: LoadGroup] = [:]
        for process in processes {
            result[process.pid] = tree.owner(of: process, sessions: sessions).group(off: off)
        }
        return result
    }

    public static func load(
        processes: [LoadProcess],
        sessions: [String: Int32],
        off: Set<LoadGroup> = [],
        totalCPU: Double?,
        cpuPending: Bool = false,
        usedMemory: UInt64?,
        physicalMemory: UInt64,
        diskPercent: Double? = nil,
        claudeLogs: UInt64? = nil
    ) -> MacLoad {
        let tree = Tree(processes)
        let sessionPids = Set(sessions.values)
        var cpu: [LoadGroup: Double] = [:]
        var memory: [LoadGroup: Double] = [:]
        var offFound = Set<LoadGroup>()
        var perSession: [String: SessionLoad] = [:]
        var idsByPid: [Int32: [String]] = [:]
        for (id, pid) in sessions { idsByPid[pid, default: []].append(id) }

        for process in processes {
            let owner = tree.owner(of: process, sessions: sessionPids)
            let group = owner.group(off: off)
            if group != .rest {
                cpu[group, default: 0] += process.cpu
                memory[group, default: 0] += Double(process.memory)
            }
            offFound.formUnion(owner.named.intersection(off))
            for ancestor in tree.chain(from: process) {
                for id in idsByPid[ancestor.pid] ?? [] {
                    var load = perSession[id] ?? SessionLoad(cpu: 0, memory: 0)
                    load.cpu += process.cpu
                    load.memory += process.memory
                    perSession[id] = load
                }
            }
        }

        let bytesPerPercent = Double(physicalMemory) / 100
        return MacLoad(
            cpu: totalCPU.map { LoadSplit(total: $0, named: cpu) },
            cpuPending: cpuPending,
            memory: usedMemory.flatMap { used in
                guard bytesPerPercent > 0 else { return nil }
                return LoadSplit(total: Double(used) / bytesPerPercent, named: memory.mapValues { $0 / bytesPerPercent })
            },
            diskPercent: diskPercent,
            claudeLogs: claudeLogs,
            physicalMemory: physicalMemory,
            sessions: perSession,
            offWithProcesses: LoadGroup.allCases.filter(offFound.contains)
        )
    }

    /// Who a process answers to, up its whole line of parents.
    private struct Owner {
        var isClaude = false
        /// The closest program above it, or itself, that is not Claude.
        var program: LoadGroup?

        var named: Set<LoadGroup> {
            Set([isClaude ? .claude : nil, program].compactMap { $0 })
        }

        func group(off: Set<LoadGroup>) -> LoadGroup {
            if let program, off.contains(program) { return .rest }
            if isClaude { return off.contains(.claude) ? .rest : .claude }
            return program ?? .rest
        }
    }

    private struct Tree {
        private let byPid: [Int32: LoadProcess]

        init(_ processes: [LoadProcess]) {
            byPid = Dictionary(processes.map { ($0.pid, $0) }) { first, _ in first }
        }

        /// The process and its parents. launchd and other users' processes are not listed, so the line ends there.
        /// Parents read a moment apart can in theory form a loop, so the length is limited.
        func chain(from process: LoadProcess) -> [LoadProcess] {
            var result = [process]
            var current = process
            while result.count < 256, current.parent != current.pid, let parent = byPid[current.parent] {
                result.append(parent)
                current = parent
            }
            return result
        }

        func owner(of process: LoadProcess, sessions: Set<Int32>) -> Owner {
            var owner = Owner()
            for link in chain(from: process) {
                if link.mark == .claude || sessions.contains(link.pid) {
                    owner.isClaude = true
                } else if owner.program == nil, let mark = link.mark {
                    owner.program = mark
                }
            }
            return owner
        }
    }
}

/// What the session page can say about a session's load.
public enum SessionLoadPlace: Sendable, Equatable {
    /// Running on this Mac, with numbers to show.
    case here
    /// The machine is seen only as a whole, so there is no share of one session.
    case cowork
    case remote(host: String)
    /// Over, or not something that runs on this Mac: nothing to say.
    case none

    public init(_ session: WorkSession) {
        switch session.environment {
        case .cowork: self = .cowork
        case .remote(let host): self = .remote(host: host)
        case .chat: self = .none
        default: self = session.state.isActive ? .here : .none
        }
    }
}
