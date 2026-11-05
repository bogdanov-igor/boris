/// Where a folder stands in git, as far as a person cares.
public struct GitPlace: Sendable, Equatable {
    public var branch: String?
    /// True for a separate copy of a project (a git worktree).
    public var isSeparateCopy: Bool
    /// The main copy's folder, when it can be told from the path.
    public var mainFolder: String?
    /// The folder's own name, for a copy whose branch is not known.
    public var folderName: String?

    public init(branch: String? = nil, isSeparateCopy: Bool = false, mainFolder: String? = nil, folderName: String? = nil) {
        self.branch = branch
        self.isSeparateCopy = isSeparateCopy
        self.mainFolder = mainFolder
        self.folderName = folderName
    }

    public var label: String? { branch ?? folderName }

    /// Where Claude Code itself puts the copies it makes.
    public static let claudeCopies = "/.claude/worktrees/"

    /// The main copy of a project, for a folder inside one of Claude Code's own copies. It holds even after the copy is removed.
    public static func mainFolder(of folder: String) -> String? {
        folder.range(of: claudeCopies).map { String(folder[..<$0.lowerBound]) }
    }

    /// The project some work belongs to, going by its folder alone: the main copy for a separate copy, and none for Cowork, whose folder lives inside a virtual machine.
    public static func projectPath(cwd: String?, environment: WorkEnvironment?) -> String? {
        guard environment != .cowork, let cwd, !cwd.isEmpty else { return nil }
        return mainFolder(of: cwd) ?? cwd
    }

    /// The same copy, even when its branch was read at different moments or not at all.
    public func isSameCopy(as other: GitPlace) -> Bool {
        isSeparateCopy == other.isSeparateCopy && mainFolder == other.mainFolder && folderName == other.folderName
    }
}
