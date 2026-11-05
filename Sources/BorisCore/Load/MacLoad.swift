import Foundation

/// Who a share of the Mac's load belongs to, in the order they are shown.
public enum LoadGroup: String, Sendable, CaseIterable, Hashable {
    case claude, cowork, vsCode, cursor, claudeDesktop, boris, rest

    public var title: String {
        switch self {
        case .claude: return "Claude"
        case .cowork: return "Cowork"
        case .vsCode: return "VS Code"
        case .cursor: return "Cursor"
        case .claudeDesktop: return "Claude Desktop"
        case .boris: return "Boris"
        case .rest: return L("The rest")
        }
    }
}

/// One process of this user as the grouping sees it.
public struct LoadProcess: Sendable, Equatable {
    public var pid: Int32
    public var parent: Int32
    /// What its executable alone says about it. Most processes say nothing and take after their parent.
    public var mark: LoadGroup?
    /// Percent of the whole Mac, where 100 is all its cores.
    public var cpu: Double
    public var memory: UInt64

    public init(pid: Int32, parent: Int32, mark: LoadGroup? = nil, cpu: Double = 0, memory: UInt64 = 0) {
        self.pid = pid
        self.parent = parent
        self.mark = mark
        self.cpu = cpu
        self.memory = memory
    }
}

/// A total and who it is made of. The parts add up to the total, in the rounded numbers on screen too.
public struct LoadSplit: Sendable, Equatable {
    public struct Part: Sendable, Equatable {
        public var group: LoadGroup
        public var value: Double
        /// Whole percents, chosen so that they sum to `LoadSplit.points`.
        public var points: Int
    }

    /// Percent of the whole Mac.
    public var total: Double
    public var points: Int
    public var parts: [Part]

    /// - Parameter named: what the named groups take. Whatever is left of the total is the rest.
    ///   Processes measured a moment apart or sharing memory can add up to more than the total, so then they are scaled to fit it.
    public init(total: Double, named: [LoadGroup: Double]) {
        let total = min(max(total, 0), 100)
        var named = named.mapValues { max($0, 0) }
        named[.rest] = nil
        let sum = named.values.reduce(0, +)
        if sum > total, sum > 0 {
            named = named.mapValues { $0 * total / sum }
        }
        named[.rest] = max(total - min(sum, total), 0)
        self.total = total
        points = Int(total.rounded())

        let shown = LoadGroup.allCases.compactMap { group in named[group].map { (group, $0) } }
        let whole = Self.apportion(shown.map(\.1), to: points)
        parts = zip(shown, whole).compactMap { item, points in
            // A rest of nothing is not worth a line, unlike a named group that is running but quiet.
            item.0 == .rest && points == 0 ? nil : Part(group: item.0, value: item.1, points: points)
        }
    }

    public func part(_ group: LoadGroup) -> Part? {
        parts.first { $0.group == group }
    }

    /// Whole numbers that sum exactly to `target`: every value is rounded down, and what is missing goes to the largest remainders.
    private static func apportion(_ values: [Double], to target: Int) -> [Int] {
        var result = values.map { Int($0) }
        let missing = target - result.reduce(0, +)
        let order = values.indices.sorted { a, b in
            let left = values[a] - Double(Int(values[a]))
            let right = values[b] - Double(Int(values[b]))
            return left == right ? a < b : left > right
        }
        guard missing > 0, !order.isEmpty else { return result }
        for step in 0..<missing {
            result[order[step % order.count]] += 1
        }
        return result
    }
}

/// What one session takes with its agents and commands.
public struct SessionLoad: Sendable, Equatable {
    /// Percent of the whole Mac.
    public var cpu: Double
    public var memory: UInt64

    public init(cpu: Double, memory: UInt64) {
        self.cpu = cpu
        self.memory = memory
    }
}

/// The Mac at one moment. Nil means the value could not be read, which is not the same as zero.
public struct MacLoad: Sendable, Equatable {
    public var cpu: LoadSplit?
    /// CPU load is the difference between two readings, so right after a block appears it is on its way, not missing.
    public var cpuPending: Bool
    public var memory: LoadSplit?
    public var diskPercent: Double?
    public var claudeLogs: UInt64?
    public var physicalMemory: UInt64
    public var sessions: [String: SessionLoad]
    /// Sources with reading turned off that have something running: they are counted in the rest.
    public var offWithProcesses: [LoadGroup]

    public init(cpu: LoadSplit? = nil, cpuPending: Bool = false, memory: LoadSplit? = nil, diskPercent: Double? = nil, claudeLogs: UInt64? = nil, physicalMemory: UInt64 = 0, sessions: [String: SessionLoad] = [:], offWithProcesses: [LoadGroup] = []) {
        self.cpu = cpu
        self.cpuPending = cpuPending
        self.memory = memory
        self.diskPercent = diskPercent
        self.claudeLogs = claudeLogs
        self.physicalMemory = physicalMemory
        self.sessions = sessions
        self.offWithProcesses = offWithProcesses
    }
}
