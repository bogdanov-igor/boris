import BorisCore
import Foundation

/// Tells a separate copy of a project from what Claude's logs say, opening as little as possible in the project.
///
/// Projects often live in ~/Documents, and reading a file there may make macOS ask the person for access.
/// So a main copy is told only by whether `.git` is a folder, which is not reading it. Only in a separate copy is its one-line `.git` file read:
/// Claude's logs do not say which project a copy made with `git worktree add` belongs to, and git writes that only there.
/// Copies Claude Code makes itself are known by their path, and nothing is read for them. That macOS stays silent about all this has not been tried on a clean account yet.
public enum GitPlaceReader {
    private static let walkLimit = 32
    /// A `.git` file is one short line. Anything longer is not one.
    private static let pointerLimit = 4096
    /// Where git keeps what it knows about each separate copy, inside the main copy's `.git` folder.
    private static let copiesInGit = "/.git/worktrees/"

    /// - Parameter branch: the `gitBranch` of a transcript. `HEAD` means no branch.
    public static func place(folder: String?, branch: String?) -> GitPlace? {
        guard let folder, !folder.isEmpty else { return nil }
        let branch = branch == "HEAD" || branch?.isEmpty == true ? nil : branch
        if let main = GitPlace.mainFolder(of: folder) {
            let rest = folder.dropFirst(main.count + GitPlace.claudeCopies.count)
            return GitPlace(branch: branch, isSeparateCopy: true, mainFolder: main, folderName: rest.split(separator: "/").first.map(String.init))
        }
        switch copyHolding(folder) {
        case .copy(let copy, let main):
            return GitPlace(branch: branch, isSeparateCopy: true, mainFolder: main, folderName: URL(fileURLWithPath: copy).lastPathComponent)
        case .notACopy:
            return branch.map { GitPlace(branch: $0) }
        }
    }

    private enum Holding {
        /// `main` is nil when the `.git` file could not be read or names no main copy.
        case copy(String, main: String?)
        case notACopy
    }

    /// In a separate copy `.git` is a file, and in a main copy it is a folder. The first one found on the way up decides.
    private static func copyHolding(_ folder: String) -> Holding {
        var current = normalized(folder)
        for _ in 0..<walkLimit {
            var info = stat()
            if lstat(current + "/.git", &info) == 0 {
                guard info.st_mode & S_IFMT == S_IFREG else { return .notACopy }
                guard let target = pointer(in: current) else { return .copy(current, main: nil) }
                if let range = target.range(of: copiesInGit) { return .copy(current, main: String(target[..<range.lowerBound])) }
                // A submodule also has a `.git` file, but it points into `.git/modules/` and is a project of its own.
                // Anything else, such as a copy of a bare repository, is still a copy, of a main copy nobody can open.
                return target.contains("/modules/") ? .notACopy : .copy(current, main: nil)
            }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current || parent.isEmpty { return .notACopy }
            current = parent
        }
        return .notACopy
    }

    /// The folder a `.git` file points to, as an absolute path. Git writes it as `gitdir: <path>`, and the path may be relative to the copy.
    private static func pointer(in copy: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: copy + "/.git") else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: pointerLimit), let text = String(data: data, encoding: .utf8) else { return nil }
        let prefix = "gitdir:"
        guard let line = text.split(whereSeparator: \.isNewline).first, line.hasPrefix(prefix) else { return nil }
        let path = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return nil }
        return normalized(path.hasPrefix("/") ? path : copy + "/" + path)
    }

    /// `.` and `..` worked out by the text alone. Unlike `standardizingPath` it keeps `/private` at the start, as Claude writes folders with it.
    static func normalized(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/") where part != "." {
            if part == ".." {
                if !parts.isEmpty { parts.removeLast() }
            } else {
                parts.append(part)
            }
        }
        return "/" + parts.joined(separator: "/")
    }
}
