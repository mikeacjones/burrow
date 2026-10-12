import Foundation

/// Creates and removes linked git worktrees. Unlike `GitWorktreeResolver`,
/// this shells out to `git`, since it runs only on an explicit user action.
/// Every function blocks while git runs, so call them off the main thread.
enum GitWorktreeCommands {
    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// The directory git commands for a repository run in: the main checkout,
    /// or the repository itself if it is bare.
    static func repositoryDirectory(commonDir: String) -> String {
        (commonDir as NSString).lastPathComponent == ".git"
            ? (commonDir as NSString).deletingLastPathComponent
            : commonDir
    }

    /// Where a new worktree for `branch` goes: next to the repository, named
    /// `<repo>-<branch>` with slashes flattened, e.g. `~/src/foo-feat-bar`.
    static func defaultPath(commonDir: String, repoName: String, branch: String) -> String {
        var repoDir = repositoryDirectory(commonDir: commonDir)
        if (repoDir as NSString).lastPathComponent == ".bare" {
            repoDir = (repoDir as NSString).deletingLastPathComponent
        }
        let parent = (repoDir as NSString).deletingLastPathComponent
        let folder = "\(repoName)-\(branch.replacingOccurrences(of: "/", with: "-"))"
        return (parent as NSString).appendingPathComponent(folder)
    }

    /// Create a worktree for `branch` at `path`. The branch is created from the
    /// repository's current HEAD, or checked out if it already exists.
    static func create(commonDir: String, branch: String, path: String) -> Result<Void, Failure> {
        let repoDir = repositoryDirectory(commonDir: commonDir)

        guard git(["check-ref-format", "--branch", branch], in: repoDir).status == 0 else {
            return .failure(Failure(message: "“\(branch)” is not a valid branch name."))
        }

        let exists = git(["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"], in: repoDir).status == 0
        let args = exists
            ? ["worktree", "add", path, branch]
            : ["worktree", "add", "-b", branch, path]
        let result = git(args, in: repoDir)
        guard result.status == 0 else { return .failure(failure(result.output, "git worktree add failed.")) }
        return .success(())
    }

    /// What removing a worktree would lose, gathered before asking the user.
    struct RemovalCheck {
        /// Uncommitted or untracked files (`git status --porcelain` lines).
        let changedFiles: Int
        /// Commits on the worktree's branch that aren't on any remote-tracking
        /// branch. Zero means the branch can be deleted without losing work.
        let unpushedCommits: Int
    }

    static func checkRemoval(of worktree: GitWorktreeInfo) -> RemovalCheck {
        let status = git(["status", "--porcelain"], in: worktree.worktreeRoot)
        let changed = status.status == 0
            ? status.output.split(separator: "\n").count
            : 0
        var unpushed = 0
        if let branch = worktree.branch {
            // Compares against remote-tracking refs as of the last fetch.
            let count = git(
                ["rev-list", "--count", "refs/heads/\(branch)", "--not", "--remotes"],
                in: worktree.worktreeRoot)
            unpushed = Int(count.output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }
        return RemovalCheck(changedFiles: changed, unpushedCommits: unpushed)
    }

    /// Remove a linked worktree, and then its branch if `deleteBranch` is set.
    /// `force` discards uncommitted changes in the worktree.
    static func remove(_ worktree: GitWorktreeInfo, force: Bool, deleteBranch: Bool) -> Result<Void, Failure> {
        guard worktree.isLinkedWorktree else {
            return .failure(Failure(message: "The repository's main checkout can't be removed."))
        }
        let repoDir = repositoryDirectory(commonDir: worktree.commonDir)
        let args = ["worktree", "remove"] + (force ? ["--force"] : []) + [worktree.worktreeRoot]
        let removed = git(args, in: repoDir)
        guard removed.status == 0 else { return .failure(failure(removed.output, "git worktree remove failed.")) }

        if deleteBranch, let branch = worktree.branch {
            let deleted = git(["branch", "-D", branch], in: repoDir)
            guard deleted.status == 0 else {
                return .failure(failure(deleted.output, "The worktree was removed, but deleting “\(branch)” failed."))
            }
        }
        return .success(())
    }

    private static func failure(_ output: String, _ fallback: String) -> Failure {
        let message = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return Failure(message: message.isEmpty ? fallback : message)
    }

    private static func git(_ args: [String], in directory: String) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", directory] + args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return (-1, "Couldn't run git: \(error.localizedDescription)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
