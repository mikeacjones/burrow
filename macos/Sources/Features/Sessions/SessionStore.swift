import AppKit
import Combine
import Foundation

/// One terminal session as displayed in the sidebar.
struct SessionItem: Identifiable, Equatable {
    let id: UUID
    var title: String
    var pwd: String?
    var git: GitWorktreeInfo?
    var agent: AgentKind?
    var activity: SessionActivity

    /// The window displaying this session, or nil if it is detached.
    var attachedWindow: ObjectIdentifier?

    /// Number of terminals (splits) in the session.
    var surfaceCount: Int

    var isAttached: Bool { attachedWindow != nil }

    /// A useful one-line description: the agent's task title, else the shell title.
    var subtitle: String? {
        let cleaned = TerminalTitle.clean(title)
        guard !cleaned.isEmpty else { return nil }
        if let agent, agent.genericTitles.contains(cleaned.lowercased()) { return nil }
        return cleaned
    }
}

/// Sessions belonging to the same git repository (or "Other" for non-git directories).
struct SessionGroup: Identifiable, Equatable {
    let id: String
    let name: String
    let isRepository: Bool
    var sessions: [SessionItem]

    /// Worktrees of this repository that have no session open, shown dimmed
    /// so a session can be started in them with one click.
    var idleWorktrees: [GitWorktreeInfo] = []
}

/// Derives git worktree and agent activity information for every session in
/// `SessionManager`, for display in the sidebar. A single shared instance backs
/// the sidebar in every window so they all stay in sync.
@MainActor
final class SessionStore: ObservableObject {
    static let shared = SessionStore()

    @Published private(set) var groups: [SessionGroup] = []

    @Published var isCollapsed: Bool {
        didSet { defaults.set(isCollapsed, forKey: Keys.collapsed) }
    }

    @Published var width: CGFloat {
        didSet { defaults.set(Double(width), forKey: Keys.width) }
    }

    /// Repository groups the user has folded closed.
    @Published var foldedGroups: Set<String> {
        didSet { defaults.set(Array(foldedGroups), forKey: Keys.folded) }
    }

    static let minWidth: CGFloat = 160
    static let maxWidth: CGFloat = 400
    static let railWidth: CGFloat = 40

    /// The horizontal space the sidebar currently takes in each window.
    var currentWidth: CGFloat { isCollapsed ? Self.railWidth : width }

    private enum Keys {
        static let collapsed = "SessionSidebarCollapsed"
        static let width = "SessionSidebarWidth"
        static let folded = "SessionSidebarFoldedGroups"
    }

    /// How often sessions are re-scanned. Everything per tick is cheap
    /// (a few file reads and libproc calls per surface).
    private static let refreshInterval: TimeInterval = 0.5

    /// A surface counts as working if it showed activity within this window.
    /// This smooths over brief pauses between agent steps.
    private static let workingGracePeriod: TimeInterval = 2.5

    /// Fraction of one CPU core above which an agent's process group is
    /// considered busy. Idle agent TUIs sit near zero.
    private static let busyCPUThreshold = 0.04

    private let defaults = UserDefaults.ghostty
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    private var activity: [UUID: ActivityTracker] = [:]
    private var processCache: [pid_t: ProcessIdentity] = [:]
    private var gitCache: [String: (info: GitWorktreeInfo?, at: Date)] = [:]
    private var worktreeCache: [String: (worktrees: [GitWorktreeInfo], at: Date)] = [:]

    private struct ProcessIdentity {
        let name: String
        let agent: AgentKind?
        let isShell: Bool
    }

    private struct ActivityTracker {
        var pgid: pid_t = 0
        var lastCPU: UInt64 = 0
        var lastSample = Date.distantPast
        var lastActive = Date.distantPast
        var wasWorking = false
        var unseenCompletion = false
    }

    /// Per-surface derived state, aggregated into a session row.
    private struct SurfaceState {
        let surface: Ghostty.SurfaceView
        let agent: AgentKind?
        let activity: SessionActivity
    }

    private init() {
        isCollapsed = defaults.bool(forKey: Keys.collapsed)
        let storedWidth = defaults.double(forKey: Keys.width)
        width = storedWidth > 0
            ? min(max(CGFloat(storedWidth), Self.minWidth), Self.maxWidth)
            : 220
        foldedGroups = Set(defaults.stringArray(forKey: Keys.folded) ?? [])
        start()
    }

    // MARK: Actions

    func toggleCollapsed() {
        isCollapsed.toggle()
    }

    func toggleFold(_ groupID: String) {
        if foldedGroups.contains(groupID) {
            foldedGroups.remove(groupID)
        } else {
            foldedGroups.insert(groupID)
        }
    }

    /// Show a session in the given window (or bring forward the window already showing it).
    func select(_ id: UUID, in controller: TerminalController?) {
        guard let session = SessionManager.shared.session(id: id),
              let controller = controller ?? Self.keyController else { return }
        SessionManager.shared.attach(session, to: controller)
        scheduleRefresh()
    }

    /// Start a new session in a worktree that doesn't have one yet.
    func openWorktree(_ worktree: GitWorktreeInfo, in controller: TerminalController?) {
        guard let controller = controller ?? Self.keyController else { return }
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = worktree.worktreeRoot
        SessionManager.shared.newSession(in: controller, baseConfig: config)
        scheduleRefresh()
    }

    func close(_ id: UUID) {
        guard let session = SessionManager.shared.session(id: id) else { return }
        SessionManager.shared.close(session)
        scheduleRefresh()
    }

    /// Switch the key window to the next/previous session in sidebar order.
    func selectAdjacent(offset: Int) {
        guard let controller = Self.keyController else { return }
        SessionManager.shared.selectAdjacent(offset: offset, in: controller)
        scheduleRefresh()
    }

    private static var keyController: TerminalController? {
        (NSApp.keyWindow?.windowController as? TerminalController) ?? TerminalController.all.first
    }

    // MARK: Refresh

    private func start() {
        let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        // Refresh promptly on window changes so the sidebar doesn't lag behind the timer.
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleRefresh() }
            })
        }
    }

    func scheduleRefresh() {
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }

    func refresh() {
        let now = Date()
        var items: [(order: Int, item: SessionItem)] = []
        var liveSurfaces: Set<UUID> = []
        var livePIDs: Set<pid_t> = []

        for session in SessionManager.shared.sessions {
            // A session is "being viewed" if it's on screen in the active app;
            // completions that happen while it isn't are flagged as unseen.
            let isViewed = NSApp.isActive && (session.controller?.window?.isVisible ?? false)

            var states: [SurfaceState] = []
            for surface in session.surfaces {
                liveSurfaces.insert(surface.id)
                let pid = surface.surfaceModel?.foregroundPID.map { pid_t($0) }
                let identity = pid.map { identify(pid: $0) }
                if let pid { livePIDs.insert(pid) }
                states.append(SurfaceState(
                    surface: surface,
                    agent: identity?.agent,
                    activity: activityState(
                        surface: surface, pid: pid, identity: identity,
                        isViewed: isViewed, now: now)))
            }

            // The row describes the most urgent agent in the session, falling
            // back to the session's focused surface.
            let primary = session.primarySurface
            let representative = states
                .filter { $0.agent != nil }
                .max { $0.activity.urgency < $1.activity.urgency }
                ?? states.first { $0.surface === primary }
                ?? states.first
            guard let representative else { continue }

            let pwd = primary?.pwd ?? representative.surface.pwd
            items.append((session.order, SessionItem(
                id: session.id,
                title: representative.surface.title,
                pwd: pwd,
                git: pwd.flatMap { gitInfo(for: $0, now: now) },
                agent: representative.agent,
                activity: representative.activity,
                attachedWindow: session.controller.map(ObjectIdentifier.init),
                surfaceCount: states.count)))
        }

        // Forget surfaces and processes that are gone.
        activity = activity.filter { liveSurfaces.contains($0.key) }
        processCache = processCache.filter { livePIDs.contains($0.key) }
        if gitCache.count > 256 { gitCache.removeAll() }

        let newGroups = group(items).map { group in
            guard group.isRepository else { return group }
            var group = group
            let open = Set(group.sessions.compactMap { $0.git?.worktreeRoot })
            group.idleWorktrees = worktrees(commonDir: group.id, now: now)
                .filter { !open.contains($0.worktreeRoot) }
            return group
        }
        if worktreeCache.count > 64 { worktreeCache.removeAll() }
        if newGroups != groups {
            groups = newGroups
        }
    }

    private func group(_ items: [(order: Int, item: SessionItem)]) -> [SessionGroup] {
        var byRepo: [String: (group: SessionGroup, orders: [UUID: Int])] = [:]
        for (order, item) in items {
            let key = item.git?.commonDir ?? "~other"
            if byRepo[key] == nil {
                byRepo[key] = (SessionGroup(
                    id: key,
                    name: item.git?.repoName ?? "Other",
                    isRepository: item.git != nil,
                    sessions: []), [:])
            }
            byRepo[key]?.group.sessions.append(item)
            byRepo[key]?.orders[item.id] = order
        }

        // Stable ordering: repos alphabetically (non-git last), sessions in the
        // order they were created, so rows don't jump around.
        return byRepo.values
            .map { entry in
                var group = entry.group
                group.sessions.sort { (entry.orders[$0.id] ?? 0) < (entry.orders[$1.id] ?? 0) }
                return group
            }
            .sorted { lhs, rhs in
                if lhs.isRepository != rhs.isRepository { return lhs.isRepository }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    // MARK: Derivation

    private func gitInfo(for pwd: String, now: Date) -> GitWorktreeInfo? {
        // Branch switches are picked up within this TTL.
        if let cached = gitCache[pwd], now.timeIntervalSince(cached.at) < 1.5 {
            return cached.info
        }
        let info = GitWorktreeResolver.resolve(directory: pwd)
        gitCache[pwd] = (info, now)
        return info
    }

    /// All worktrees of a repository, main checkout first, then by branch.
    private func worktrees(commonDir: String, now: Date) -> [GitWorktreeInfo] {
        if let cached = worktreeCache[commonDir], now.timeIntervalSince(cached.at) < 3 {
            return cached.worktrees
        }
        let worktrees = GitWorktreeResolver.worktrees(commonDir: commonDir).sorted { lhs, rhs in
            if lhs.isLinkedWorktree != rhs.isLinkedWorktree { return !lhs.isLinkedWorktree }
            return lhs.displayRef.localizedStandardCompare(rhs.displayRef) == .orderedAscending
        }
        worktreeCache[commonDir] = (worktrees, now)
        return worktrees
    }

    private func identify(pid: pid_t) -> ProcessIdentity {
        if let cached = processCache[pid] { return cached }
        let name = ProcessInspector.name(pid: pid) ?? ""
        // argv is unreadable for setuid processes (e.g. `top`), so fall back to the process name.
        let args = ProcessInspector.arguments(pid: pid).filter { !$0.isEmpty }
        let identity = ProcessIdentity(
            name: args.first.map { ($0 as NSString).lastPathComponent } ?? name,
            agent: AgentKind.detect(arguments: args, processName: name),
            isShell: ShellNames.isShell(name) || (args.first.map(ShellNames.isShell) ?? false))
        processCache[pid] = identity
        return identity
    }

    private func activityState(
        surface: Ghostty.SurfaceView,
        pid: pid_t?,
        identity: ProcessIdentity?,
        isViewed: Bool,
        now: Date
    ) -> SessionActivity {
        let id = surface.id
        guard let pid, let identity else { return .shell }
        guard identity.agent != nil else {
            activity[id] = nil
            return identity.isShell ? .shell : .command(identity.name)
        }

        var tracker = activity[id] ?? ActivityTracker()

        // CPU usage of the agent's whole process group since the last sample.
        let cpu = ProcessInspector.cpuTimeNanos(processGroup: pid)
        if tracker.pgid == pid, tracker.lastSample != .distantPast {
            let elapsed = now.timeIntervalSince(tracker.lastSample)
            let used = Double(cpu &- tracker.lastCPU) / 1_000_000_000
            if elapsed > 0, cpu >= tracker.lastCPU, used / elapsed > Self.busyCPUThreshold {
                tracker.lastActive = now
            }
        }
        tracker.pgid = pid
        tracker.lastCPU = cpu
        tracker.lastSample = now

        // Explicit signals from the agent itself.
        if TerminalTitle.hasSpinner(surface.title) {
            tracker.lastActive = now
        }
        if let progress = surface.progressReport, progress.state != .remove {
            tracker.lastActive = now
        }

        let working = now.timeIntervalSince(tracker.lastActive) < Self.workingGracePeriod
        if tracker.wasWorking && !working && !isViewed {
            tracker.unseenCompletion = true
        }
        if isViewed {
            tracker.unseenCompletion = false
        }
        tracker.wasWorking = working
        activity[id] = tracker

        if surface.bell { return .agentNeedsInput }
        if working { return .agentWorking }
        if tracker.unseenCompletion { return .agentDone }
        return .agentIdle
    }
}

extension SessionActivity {
    /// Ordering used to pick which surface represents a multi-split session.
    var urgency: Int {
        switch self {
        case .shell: return 0
        case .command: return 1
        case .agentIdle: return 2
        case .agentDone: return 3
        case .agentWorking: return 4
        case .agentNeedsInput: return 5
        }
    }
}
