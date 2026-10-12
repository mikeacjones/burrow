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
        /// The reason given by `git worktree lock`, if the worktree is locked
        /// by something that may still be using it. Stale locks are nil.
        let activeLock: String?
        /// Whether the worktree has a lock left by a process that has exited,
        /// which is removed without asking.
        let staleLock: Bool
        var isLocked: Bool { activeLock != nil || staleLock }
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
        let lock = lockReason(of: worktree)
        let stale = lock.map(isStale) ?? false
        return RemovalCheck(
            changedFiles: changed,
            unpushedCommits: unpushed,
            activeLock: stale ? nil : lock,
            staleLock: stale)
    }

    /// The worktree's lock reason ("" if locked without one), or nil if it
    /// isn't locked. Read from `<gitdir>/locked`.
    private static func lockReason(of worktree: GitWorktreeInfo) -> String? {
        let dotGit = (worktree.worktreeRoot as NSString).appendingPathComponent(".git")
        guard let contents = try? String(contentsOfFile: dotGit, encoding: .utf8),
              contents.hasPrefix("gitdir:") else { return nil }
        var gitDir = contents.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
        if !gitDir.hasPrefix("/") {
            gitDir = (worktree.worktreeRoot as NSString).appendingPathComponent(gitDir)
        }
        let lockFile = (gitDir as NSString).appendingPathComponent("locked")
        guard let reason = try? String(contentsOfFile: lockFile, encoding: .utf8) else { return nil }
        return reason.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether a lock was left by a process that has since exited. Claude Code
    /// locks the worktrees it creates with a reason like
    /// "claude session x (pid 123 start Mon Oct 12 12:08:22 2026)" (UTC) and
    /// doesn't always unlock them. The lock is stale if that pid is gone or now
    /// belongs to a process that started at a different time. Locks without a
    /// pid are never considered stale.
    private static func isStale(_ reason: String) -> Bool {
        guard let match = reason.firstMatch(of: #/\(pid (\d+) start ([^)]+)\)/#),
              let pid = pid_t(match.1) else { return false }
        guard let started = ProcessInspector.startTime(pid: pid) else { return true }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        guard let lockedStart = formatter.date(from: String(match.2)) else { return false }
        return abs(started.timeIntervalSince(lockedStart)) > 2
    }

    /// Remove a linked worktree, and then its branch if `deleteBranch` is set.
    /// `force` discards uncommitted changes in the worktree, and `unlock`
    /// removes its lock first.
    static func remove(
        _ worktree: GitWorktreeInfo,
        force: Bool,
        unlock: Bool,
        deleteBranch: Bool
    ) -> Result<Void, Failure> {
        guard worktree.isLinkedWorktree else {
            return .failure(Failure(message: "The repository's main checkout can't be removed."))
        }
        let repoDir = repositoryDirectory(commonDir: worktree.commonDir)
        if unlock {
            let unlocked = git(["worktree", "unlock", worktree.worktreeRoot], in: repoDir)
            guard unlocked.status == 0 else { return .failure(failure(unlocked.output, "git worktree unlock failed.")) }
        }
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
