import CoreServices
import Foundation

/// Uncommitted changes and unpushed/unpulled commits in one worktree.
struct GitStatusSummary: Equatable {
    /// Staged, unstaged, conflicted, and untracked paths.
    var changedFiles = 0

    /// Commits on the branch that aren't on its upstream, and upstream commits
    /// not on the branch (as of the last fetch). Zero without an upstream.
    var ahead = 0
    var behind = 0

    var isClean: Bool { changedFiles == 0 && ahead == 0 && behind == 0 }

    /// Parses `git status --porcelain=v2 --branch`.
    static func parse(_ output: String) -> GitStatusSummary {
        var summary = GitStatusSummary()
        for line in output.split(separator: "\n") {
            if line.hasPrefix("# branch.ab ") {
                for part in line.dropFirst("# branch.ab ".count).split(separator: " ") {
                    if part.hasPrefix("+") { summary.ahead = Int(part.dropFirst()) ?? 0 }
                    if part.hasPrefix("-") { summary.behind = Int(part.dropFirst()) ?? 0 }
                }
            } else if !line.hasPrefix("#") {
                summary.changedFiles += 1
            }
        }
        return summary
    }
}

/// Keeps a `GitStatusSummary` for each watched worktree.
///
/// Unlike `GitWorktreeResolver`, this has to run `git status`, which walks the
/// whole worktree. So it never polls: each worktree is watched with FSEvents
/// (its directory, plus the shared git dir for commits, pushes, and fetches),
/// and git runs only after something changed. Bursts of changes are coalesced
/// by the FSEvents latency, and at most one `git status` runs per worktree.
@MainActor
final class GitStatusMonitor {
    private(set) var statuses: [String: GitStatusSummary] = [:]

    /// Called when any worktree's status changes.
    var onChange: (() -> Void)?

    /// How long FSEvents gathers changes before reporting them.
    private static let latency: CFTimeInterval = 1.0

    /// A `git status` taking longer than this (a huge repository) is killed.
    nonisolated private static let timeout: TimeInterval = 10

    private var watches: [String: Watch] = [:]

    /// Watch exactly these worktrees: start watching new ones (reading their
    /// status right away) and stop watching any not listed.
    func watch(_ worktrees: [GitWorktreeInfo]) {
        var wanted: [String: String] = [:]
        for worktree in worktrees { wanted[worktree.worktreeRoot] = worktree.commonDir }

        var changed = false
        for root in watches.keys where wanted[root] == nil {
            watches[root]?.stop()
            watches[root] = nil
            if statuses.removeValue(forKey: root) != nil { changed = true }
        }
        if changed { onChange?() }

        for (root, commonDir) in wanted where watches[root] == nil {
            // A main checkout's git dir is inside the worktree, so is already covered.
            let paths = commonDir.hasPrefix(root + "/") ? [root] : [root, commonDir]
            watches[root] = Watch(paths: paths, latency: Self.latency) { [weak self] in
                MainActor.assumeIsolated { self?.update(root) }
            }
            update(root)
        }
    }

    private func update(_ root: String) {
        guard let watch = watches[root] else { return }
        // Changes made while git runs may have been missed, so run again after.
        if watch.running {
            watch.dirty = true
            return
        }
        watch.running = true
        let id = ObjectIdentifier(watch)
        DispatchQueue.global(qos: .utility).async {
            let summary = Self.status(root: root)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // Dropped if the worktree stopped being watched meanwhile.
                    guard let watch = self.watches[root], ObjectIdentifier(watch) == id else { return }
                    watch.running = false
                    if self.statuses[root] != summary {
                        self.statuses[root] = summary
                        self.onChange?()
                    }
                    if watch.dirty {
                        watch.dirty = false
                        self.update(root)
                    }
                }
            }
        }
    }

    /// Runs `git status`. Optional locks are off so git never writes the index,
    /// which would collide with git commands an agent runs in the worktree (and
    /// trigger another FSEvents callback).
    nonisolated private static func status(root: String) -> GitStatusSummary? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "--no-optional-locks", "-C", root, "status", "--porcelain=v2", "--branch"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let kill = DispatchWorkItem { process.terminate() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: kill)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        kill.cancel()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { return nil }
        guard let output = String(bytes: data, encoding: .utf8) else { return nil }
        return GitStatusSummary.parse(output)
    }

    /// An FSEvents stream delivering on the main queue.
    private final class Watch {
        private var stream: FSEventStreamRef?
        private let onEvent: () -> Void
        var running = false
        var dirty = false

        init(paths: [String], latency: CFTimeInterval, onEvent: @escaping () -> Void) {
            self.onEvent = onEvent
            var context = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passUnretained(self).toOpaque(),
                retain: nil, release: nil, copyDescription: nil)
            let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
                guard let info else { return }
                Unmanaged<Watch>.fromOpaque(info).takeUnretainedValue().onEvent()
            }
            guard let stream = FSEventStreamCreate(
                nil, callback, &context, paths as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
                FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone)) else { return }
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
            self.stream = stream
        }

        /// Stops the stream; called on the main queue, so no callback is in flight.
        func stop() {
            guard let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }

        deinit { stop() }
    }
}
