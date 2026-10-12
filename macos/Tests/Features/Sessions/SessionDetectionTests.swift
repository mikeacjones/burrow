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

    @Test func resolvesSymlinkedLaunchers() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agent-\(UUID().uuidString)")
        let target = dir.appendingPathComponent("cursor-agent/versions/1/cursor-agent")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: target.path, contents: Data())
        let link = dir.appendingPathComponent("agent")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(AgentKind.detect(arguments: [link.path, "--use-system-ca", "index.js"], processName: "agent")?.id == "cursor")
    }

    @Test(arguments: [
        ["vim", "/src/codex/main.go"],
        ["-zsh"],
        ["npm", "test"],
    ])
    func ignoresNonAgents(arguments: [String]) {
        #expect(AgentKind.detect(arguments: arguments, processName: nil) == nil)
    }

    @Test func titleCleaning() {
        #expect(TerminalTitle.clean("⠐ Fix the sidebar") == "Fix the sidebar")
        #expect(TerminalTitle.clean("◐ Sleep and echo command") == "Sleep and echo command")
        #expect(TerminalTitle.clean("✳ Claude Code") == "Claude Code")
    }

    @Test func shellNames() {
        #expect(ShellNames.isShell("-zsh"))
        #expect(ShellNames.isShell("/bin/bash"))
        #expect(!ShellNames.isShell("claude"))
    }
}

/// Screens and titles recorded from Claude Code 2.1, Codex 0.162 and Cursor
/// Agent 2026.10 while working, waiting for approval, and idle.
struct AgentStateDetectorTests {
    private func needsInput(_ screen: String, title: String = "") -> Bool {
        AgentStateDetector.needsInput(screen: screen, title: title)
    }

    private func working(_ screen: String, title: String = "") -> Bool {
        AgentStateDetector.working(screen: screen, title: title)
    }

    @Test func claude() {
        #expect(working("✻ Moonwalking… (esc to interrupt)"))
        #expect(needsInput("""
            Bash command
              echo hi > hello.txt
            Do you want to proceed?
            ❯ 1. Yes
              2. Yes, and always allow access to myrepo/ from this project
              3. No, and tell Claude what to do differently (esc)
            """))
        let idle = "⏺ The command ran and printed: finished\n✻ Cogitated for 11s\n❯ "
        #expect(!working(idle, title: "✳ Sleep and echo command"))
        #expect(!needsInput(idle, title: "✳ Sleep and echo command"))
    }

    @Test func codex() {
        #expect(working("• Working (2s • esc to interrupt)"))
        #expect(needsInput("""
            Allow this exact command to create it?
            $ echo hi > hello.txt
            › 1. Yes, proceed (y)
              2. Yes, and don't ask again for commands that start with `echo hi` (p)
            """))
        #expect(needsInput("", title: "[ ! ] Action Required | Reply ok | myrepo"))
        #expect(!working("› ", title: "Reply ok | myrepo"))
    }

    @Test func cursor() {
        #expect(working("", title: "One Word - ⏳ Working ..·"))
        #expect(working("→ Add a follow-up                 ctrl+c to stop"))
        #expect(needsInput("", title: "One Word - 🔐 Waiting for confirmation"))
        #expect(needsInput("Run this command?\nNot in allowlist: echo, sleep\n→ Run (once) (y)"))
        #expect(!working("→ Add a follow-up", title: "One Word - ✅ Ready"))
    }

    @Test func ignoresOrdinaryReplies() {
        // An agent asking a question in its reply is not an approval prompt.
        #expect(!needsInput("Want me to commit this? Do you want to also push it?"))
        #expect(!needsInput("I could allow this command in the config if you want."))
    }

    @Test func ignoresWhitespaceDifferences() {
        #expect(working("(esc   to\ninterrupt)"))
        #expect(needsInput("Yes,proceed(y)"))
    }
}
