import Foundation

/// Git information about the worktree containing a directory.
struct GitWorktreeInfo: Equatable {
    /// The shared git directory. Every worktree of the same repository resolves
    /// to the same common dir, which makes it the grouping key for the sidebar.
    let commonDir: String

    /// Human-friendly repository name derived from the common dir.
    let repoName: String

    /// Root directory of this worktree (the directory containing `.git`).
    let worktreeRoot: String

    /// The checked out branch, or nil if HEAD is detached.
    let branch: String?

    /// Short commit SHA when HEAD is detached.
    let detachedHead: String?

    /// True if this is a linked worktree (created with `git worktree add`)
    /// rather than the repository's main checkout.
    let isLinkedWorktree: Bool

    /// The directory name of the worktree, useful when it differs from the branch.
    var worktreeName: String { (worktreeRoot as NSString).lastPathComponent }

    /// Branch name, falling back to the detached SHA.
    var displayRef: String { branch ?? detachedHead.map { "@\($0)" } ?? "HEAD" }
}

/// Resolves git worktree information by reading git's on-disk metadata directly.
///
/// This intentionally never shells out to `git`: it runs frequently (to pick up
/// branch switches) for every session, so it only reads a handful of small files.
enum GitWorktreeResolver {
    private static let fm = FileManager.default

    static func resolve(directory: String) -> GitWorktreeInfo? {
        var dir = (directory as NSString).standardizingPath
        while true {
            if let info = inspect(worktreeRoot: dir) { return info }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir || parent.isEmpty { return nil }
            dir = parent
        }
    }

    private static func inspect(worktreeRoot dir: String) -> GitWorktreeInfo? {
        let dotGit = (dir as NSString).appendingPathComponent(".git")
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dotGit, isDirectory: &isDir) else { return nil }

        // `.git` is a directory for a main checkout and a file containing
        // `gitdir: <path>` for linked worktrees and submodules.
        let gitDir: String
        if isDir.boolValue {
            gitDir = dotGit
        } else {
            guard let contents = readTrimmed(dotGit),
                  contents.hasPrefix("gitdir:") else { return nil }
            let path = contents.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
            gitDir = absolute(path, relativeTo: dir)
        }

        // Linked worktrees point back to the shared repository via `commondir`.
        var commonDir = gitDir
        if let common = readTrimmed((gitDir as NSString).appendingPathComponent("commondir")) {
            commonDir = absolute(common, relativeTo: gitDir)
        }

        let head = readTrimmed((gitDir as NSString).appendingPathComponent("HEAD")) ?? ""
        var branch: String?
        var detached: String?
        if head.hasPrefix("ref:") {
            let ref = head.dropFirst("ref:".count).trimmingCharacters(in: .whitespaces)
            branch = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
        } else if !head.isEmpty {
            detached = String(head.prefix(7))
        }

        return GitWorktreeInfo(
            commonDir: commonDir,
            repoName: repoName(commonDir: commonDir),
            worktreeRoot: dir,
            branch: branch,
            detachedHead: detached,
            isLinkedWorktree: gitDir != commonDir)
    }

    /// Derive a display name for a repository from its common git dir:
    ///   ~/src/foo/.git      -> foo
    ///   ~/src/foo.git       -> foo   (bare repo used for worktrees)
    ///   ~/src/foo/.bare     -> foo   (common "bare + worktrees" layout)
    private static func repoName(commonDir: String) -> String {
        let last = (commonDir as NSString).lastPathComponent
        let parent = ((commonDir as NSString).deletingLastPathComponent as NSString).lastPathComponent
        switch last {
        case ".git", ".bare", ".repo":
            return parent
        default:
            return last.hasSuffix(".git") ? String(last.dropLast(4)) : last
        }
    }

    private static func absolute(_ path: String, relativeTo base: String) -> String {
        let full = path.hasPrefix("/") ? path : (base as NSString).appendingPathComponent(path)
        return (full as NSString).standardizingPath
    }

    private static func readTrimmed(_ path: String) -> String? {
        guard let data = fm.contents(atPath: path),
              let str = String(data: data, encoding: .utf8) else { return nil }
        return str.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
