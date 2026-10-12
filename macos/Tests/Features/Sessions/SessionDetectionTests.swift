import Foundation
import Testing
@testable import Ghostty

struct GitWorktreeResolverTests {
    /// Builds a repository with a linked worktree and a detached worktree by
    /// writing git's metadata files directly (no `git` binary needed).
    private func makeFixture() throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("gwr-\(UUID().uuidString)")
        let main = root.appendingPathComponent("myrepo")
        let gitDir = main.appendingPathComponent(".git")
        try fm.createDirectory(at: gitDir.appendingPathComponent("worktrees/feature"), withIntermediateDirectories: true)
        try fm.createDirectory(at: gitDir.appendingPathComponent("worktrees/detached"), withIntermediateDirectories: true)
        try "ref: refs/heads/main\n".write(to: gitDir.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)

        // Linked worktree on a branch, using a relative commondir like git does.
        let feature = root.appendingPathComponent("myrepo-feature")
        try fm.createDirectory(at: feature.appendingPathComponent("src/deep"), withIntermediateDirectories: true)
        let featureGit = gitDir.appendingPathComponent("worktrees/feature")
        try "gitdir: \(featureGit.path)\n".write(to: feature.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        try "../..\n".write(to: featureGit.appendingPathComponent("commondir"), atomically: true, encoding: .utf8)
        try "ref: refs/heads/feature/sidebar\n".write(to: featureGit.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        try "\(feature.appendingPathComponent(".git").path)\n".write(
            to: featureGit.appendingPathComponent("gitdir"), atomically: true, encoding: .utf8)

        // Linked worktree with a detached HEAD.
        let detached = root.appendingPathComponent("myrepo-detached")
        try fm.createDirectory(at: detached, withIntermediateDirectories: true)
        let detachedGit = gitDir.appendingPathComponent("worktrees/detached")
        try "gitdir: \(detachedGit.path)\n".write(to: detached.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        try "../..\n".write(to: detachedGit.appendingPathComponent("commondir"), atomically: true, encoding: .utf8)
        try "d4587c5e0000000000000000000000000000000\n".write(to: detachedGit.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        try "\(detached.appendingPathComponent(".git").path)\n".write(
            to: detachedGit.appendingPathComponent("gitdir"), atomically: true, encoding: .utf8)

        return root
    }

    @Test func mainCheckout() throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }

        let info = try #require(GitWorktreeResolver.resolve(directory: root.appendingPathComponent("myrepo").path))
        #expect(info.repoName == "myrepo")
        #expect(info.branch == "main")
        #expect(!info.isLinkedWorktree)
    }

    @Test func linkedWorktreeGroupsWithMainRepo() throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }

        let main = try #require(GitWorktreeResolver.resolve(directory: root.appendingPathComponent("myrepo").path))
        let linked = try #require(GitWorktreeResolver.resolve(
            directory: root.appendingPathComponent("myrepo-feature/src/deep").path))
        #expect(linked.commonDir == main.commonDir)
        #expect(linked.repoName == "myrepo")
        #expect(linked.branch == "feature/sidebar")
        #expect(linked.isLinkedWorktree)
        #expect(linked.worktreeName == "myrepo-feature")
    }

    @Test func detachedHead() throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }

        let info = try #require(GitWorktreeResolver.resolve(directory: root.appendingPathComponent("myrepo-detached").path))
        #expect(info.branch == nil)
        #expect(info.displayRef == "@d4587c5")
    }

    @Test func listsAllWorktrees() throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }

        let main = try #require(GitWorktreeResolver.resolve(directory: root.appendingPathComponent("myrepo").path))
        let worktrees = GitWorktreeResolver.worktrees(commonDir: main.commonDir)
        #expect(Set(worktrees.map(\.worktreeName)) == ["myrepo", "myrepo-feature", "myrepo-detached"])
        #expect(worktrees.first { !$0.isLinkedWorktree }?.branch == "main")
        #expect(worktrees.contains { $0.branch == "feature/sidebar" })
    }

    @Test func skipsPrunedWorktrees() throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }

        // A worktree whose directory was deleted without `git worktree prune`.
        try FileManager.default.removeItem(at: root.appendingPathComponent("myrepo-detached"))
        let main = try #require(GitWorktreeResolver.resolve(directory: root.appendingPathComponent("myrepo").path))
        let names = GitWorktreeResolver.worktrees(commonDir: main.commonDir).map(\.worktreeName)
        #expect(!names.contains("myrepo-detached"))
    }

    @Test func outsideRepository() {
        #expect(GitWorktreeResolver.resolve(directory: "/") == nil)
    }
}

struct AgentDetectionTests {
    @Test(arguments: [
        (["claude"], "claude"),
        (["/Users/x/.local/bin/claude", "--resume"], "claude"),
        (["node", "/Users/x/.local/share/cursor-agent/versions/1/index.js"], "cursor"),
        (["node", "/opt/homebrew/lib/node_modules/@openai/codex/bin/codex.js"], "codex"),
        (["python3", "-m", "aider"], "aider"),
        (["gemini"], "gemini"),
    ])
    func detectsAgents(arguments: [String], expected: String) {
        #expect(AgentKind.detect(arguments: arguments, processName: nil)?.id == expected)
    }

    @Test(arguments: [
        ["vim", "/src/codex/main.go"],
        ["-zsh"],
        ["npm", "test"],
    ])
    func ignoresNonAgents(arguments: [String]) {
        #expect(AgentKind.detect(arguments: arguments, processName: nil) == nil)
    }

    @Test func titleSpinnerDetection() {
        #expect(TerminalTitle.hasSpinner("⠐ Fix the sidebar"))
        #expect(TerminalTitle.hasSpinner("⠀⠞ Cursor first frame"))
        #expect(!TerminalTitle.hasSpinner("✳ Claude Code"))
        #expect(!TerminalTitle.hasSpinner("plain title"))
        #expect(TerminalTitle.clean("⠐ Fix the sidebar") == "Fix the sidebar")
        #expect(TerminalTitle.clean("✳ Claude Code") == "Claude Code")
    }

    @Test func shellNames() {
        #expect(ShellNames.isShell("-zsh"))
        #expect(ShellNames.isShell("/bin/bash"))
        #expect(!ShellNames.isShell("claude"))
    }
}
