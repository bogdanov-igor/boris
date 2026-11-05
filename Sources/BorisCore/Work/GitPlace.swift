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

    /// The same copy, even when its branch was read at different moments or not at all.
    public func isSameCopy(as other: GitPlace) -> Bool {
        isSeparateCopy == other.isSeparateCopy && mainFolder == other.mainFolder && folderName == other.folderName
    }
}
