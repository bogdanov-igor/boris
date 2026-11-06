import Foundation

/// Which load is not to be named, in the terms of processes. Sources and load groups do not match one to one:
/// «Claude» covers the terminal and every editor, and Claude Desktop is home to three sources.
public struct LoadOff: Sendable, Equatable, ExpressibleByArrayLiteral {
    /// Programs that get no row of their own. Their processes are the rest.
    public var programs: Set<LoadGroup> = []
    /// Programs whose Claude is not counted as Claude.
    public var claudeIn: Set<LoadGroup> = []
    /// Claude under no program, as it runs in a terminal.
    public var claudeOnItsOwn = false
    /// Processes of sessions whose source is off. Programs on the SDK look like Claude in a terminal without this.
    public var sessions: Set<Int32> = []

    public init() {}

    /// Groups turned off whole, each with Claude working inside it. `.claude` takes Claude out everywhere.
    public init(arrayLiteral groups: LoadGroup...) {
        for group in groups {
            if group == .claude {
                claudeOnItsOwn = true
                claudeIn.formUnion(LoadGroup.allCases)
            } else {
                programs.insert(group)
                claudeIn.insert(group)
            }
        }
    }

    public var isEmpty: Bool { self == LoadOff() }
}

extension SourceSettings {
    /// - Parameter hiddenSessions: processes of running sessions whose source is off.
    public func loadOff(hiddenSessions: Set<Int32> = []) -> LoadOff {
        var off = LoadOff()
        off.sessions = hiddenSessions
        off.claudeOnItsOwn = !reads(.terminal)
        for (source, group) in [(SourceID.vsCode, LoadGroup.vsCode), (.cursor, .cursor)] where !reads(source) {
            off.programs.insert(group)
            off.claudeIn.insert(group)
        }
        if !reads(.claudeDesktop) { off.claudeIn.insert(.claudeDesktop) }
        if !reads(.cowork) { off.programs.insert(.cowork) }
        // The app has a row for as long as anything in it is being watched.
        if !reads(.claudeDesktop), !reads(.cowork), !reads(.chat) { off.programs.insert(.claudeDesktop) }
        return off
    }
}
