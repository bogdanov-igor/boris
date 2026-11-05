import BorisCore
import Foundation

/// Tells a separate copy of a project from what Claude's logs say, without opening anything in the project.
///
/// Projects often live in ~/Documents, and reading a file there would make macOS ask the person for access.
/// Looking at whether `.git` is a file or a folder asks nothing, so that is as far as this goes.
public enum GitPlaceReader {
    /// Where Claude Code itself puts the copies it makes.
    private static let claudeCopies = "/.claude/worktrees/"
    private static let walkLimit = 32

    /// - Parameter branch: the `gitBranch` of a transcript. `HEAD` means no branch.
    public static func place(folder: String?, branch: String?) -> GitPlace? {
        guard let folder, !folder.isEmpty else { return nil }
        let branch = branch == "HEAD" || branch?.isEmpty == true ? nil : branch
        if let main = mainFolder(of: folder) {
            let rest = folder.dropFirst(main.count + claudeCopies.count)
            return GitPlace(branch: branch, isSeparateCopy: true, mainFolder: main, folderName: rest.split(separator: "/").first.map(String.init))
        }
        if let copy = copyHolding(folder) {
            return GitPlace(branch: branch, isSeparateCopy: true, folderName: URL(fileURLWithPath: copy).lastPathComponent)
        }
        return branch.map { GitPlace(branch: $0) }
    }

    /// The main copy of a project, for a folder inside one of Claude Code's own copies. It holds even after the copy is removed.
    public static func mainFolder(of folder: String) -> String? {
        folder.range(of: claudeCopies).map { String(folder[..<$0.lowerBound]) }
    }

    /// In a separate copy `.git` is a file, and in a main copy it is a folder. The first one found on the way up decides.
    private static func copyHolding(_ folder: String) -> String? {
        var current = (folder as NSString).standardizingPath
        for _ in 0..<walkLimit {
            var info = stat()
            if lstat(current + "/.git", &info) == 0 {
                return info.st_mode & S_IFMT == S_IFREG ? current : nil
            }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current || parent.isEmpty { return nil }
            current = parent
        }
        return nil
    }
}
