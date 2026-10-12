import AppKit
import Combine
import Foundation
import GhosttyKit
import SwiftUI

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

    /// A user-chosen name for the session (like a tab title override).
    var customName: String?

    /// Key used for custom row ordering. Keyed by worktree so a position is
    /// kept when a session in that worktree is opened or closed.
    var orderKey: String { git?.worktreeRoot ?? "session:\(id.uuidString)" }

    var isAttached: Bool { attachedWindow != nil }

    /// A useful one-line description: the agent's task title, else the shell title.
    var subtitle: String? {
        let cleaned = TerminalTitle.clean(title)
        guard !cleaned.isEmpty else { return nil }
        if let agent, agent.genericTitles.contains(cleaned.lowercased()) { return nil }
        return cleaned
    }
}

/// A row in a repository group: an open session, or a worktree with no session.
enum SidebarRow: Identifiable, Equatable {
    case session(SessionItem)
    case worktree(GitWorktreeInfo)

    var id: String {
        switch self {
        case .session(let item): return "session:\(item.id.uuidString)"
        case .worktree(let worktree): return "worktree:\(worktree.worktreeRoot)"
        }
    }

    var orderKey: String {
        switch self {
        case .session(let item): return item.orderKey
        case .worktree(let worktree): return worktree.worktreeRoot
        }
    }
}

/// Sessions belonging to the same git repository (or "Other" for non-git directories).
struct SessionGroup: Identifiable, Equatable {
    let id: String
    var name: String
    /// The repository's own name, unaffected by a user-chosen group name.
    let repoName: String
    let isRepository: Bool
    var sessions: [SessionItem]

    /// Worktrees of this repository that have no session open, shown dimmed
    /// so a session can be started in them with one click.
    var idleWorktrees: [GitWorktreeInfo] = []

    /// Sessions and idle worktrees in display order.
    var rows: [SidebarRow] = []
}

/// A resolved sidebar font: family (nil = system font), size, and weight.
struct SidebarFontStyle: Equatable {
    var family: String?
    var size: CGFloat
    var weight: Font.Weight

    static let defaultRepo = SidebarFontStyle(family: nil, size: 14, weight: .semibold)
    static let defaultSession = SidebarFontStyle(family: nil, size: 12, weight: .regular)

    /// A font in this style, optionally scaled and with a different weight.
    func font(scale: CGFloat = 1, weight: Font.Weight? = nil) -> Font {
        let size = (self.size * scale).rounded(.toNearestOrAwayFromZero)
        let weight = weight ?? self.weight
        guard let family else { return .system(size: size, weight: weight) }
        return .custom(family, size: size).weight(weight)
    }

    /// Parses a weight name from the config (`thin` … `heavy`).
    static func weight(named name: String, default defaultValue: Font.Weight) -> Font.Weight {
        switch name {
        case "thin": return .thin
        case "light": return .light
        case "regular": return .regular
        case "medium": return .medium
        case "semibold": return .semibold
        case "bold": return .bold
        case "heavy": return .heavy
        default: return defaultValue
        }
    }
}

extension Font.Weight {
    /// One step heavier, used to emphasize the session shown in a window.
    var bolder: Font.Weight {
        switch self {
        case .ultraLight: return .thin
        case .thin: return .light
        case .light: return .regular
        case .regular: return .semibold
        case .medium: return .semibold
        case .semibold: return .bold
        case .bold: return .heavy
        default: return .black
        }
    }
}

/// What is currently being dragged in the sidebar, for reordering.
enum SidebarDrag: Equatable {
    case group(String)
    case row(group: String, key: String)
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

    /// Custom order of repository groups (by group id), set by dragging.
    @Published private(set) var groupOrder: [String] {
        didSet { defaults.set(groupOrder, forKey: Keys.groupOrder) }
    }

    /// Custom order of rows within each group (group id -> row order keys).
    @Published private(set) var rowOrder: [String: [String]] {
        didSet { defaults.set(rowOrder, forKey: Keys.rowOrder) }
    }

    /// User-chosen names for repository groups.
    @Published private(set) var groupNames: [String: String] {
        didSet { defaults.set(groupNames, forKey: Keys.groupNames) }
    }

    /// Fonts for repository headers and session rows, from the
    /// `sidebar-*-font-*` options. Families fall back to `sidebar-font-family`
    /// and then to the terminal's font.
    @Published private(set) var repoFont = SidebarFontStyle.defaultRepo
    @Published private(set) var sessionFont = SidebarFontStyle.defaultSession
    private var needsFontResolve = true

    /// The item currently being dragged, if any.
    var dragging: SidebarDrag?

    static let minWidth: CGFloat = 160
    static let maxWidth: CGFloat = 400
    static let railWidth: CGFloat = 40

    /// The horizontal space the sidebar currently takes in each window.
    var currentWidth: CGFloat { isCollapsed ? Self.railWidth : width }

    private enum Keys {
        static let collapsed = "SessionSidebarCollapsed"
        static let width = "SessionSidebarWidth"
        static let folded = "SessionSidebarFoldedGroups"
        static let groupOrder = "SessionSidebarGroupOrder"
        static let rowOrder = "SessionSidebarRowOrder"
        static let groupNames = "SessionSidebarGroupNames"
    }

    /// How often sessions are re-scanned. Everything per tick is cheap
    /// (a few file reads and libproc calls per surface).
    private static let refreshInterval: TimeInterval = 0.5

    /// An agent must show no working signal for this long before it counts
    /// as idle, so brief gaps between steps don't flicker.
    private static let idleDebounce: TimeInterval = 1.0

    /// A title that changed at least twice within this window is animating
    /// (a spinner), which agents use to show they're working.
    private static let titleAnimationWindow: TimeInterval = 3.0

    /// How recently an agent must have been working for its notification to
    /// count as a request for input.
    private static let notificationWindow: TimeInterval = 15

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
        var lastTitle = ""
        var titleChanges: [Date] = []
        var lastWorking = Date.distantPast
        /// Whether the current working stretch included explicit working text
        /// (e.g. "esc to interrupt"). Only those count as a finished turn, so
        /// an agent's startup animation doesn't show as "done".
        var sawMarkedWorking = false
        /// Set when the agent requests a desktop notification (e.g. Claude's
        /// "needs your permission"); cleared once it resumes work or the
        /// session is viewed.
        var notified = false
        var wasWorking = false
        var unseenCompletion = false
    }

    /// Per-surface derived state, aggregated into a session row.
    private struct SurfaceState {
        let surface: Ghostty.SurfaceView
        let pid: pid_t?
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
        groupOrder = defaults.stringArray(forKey: Keys.groupOrder) ?? []
        rowOrder = defaults.dictionary(forKey: Keys.rowOrder) as? [String: [String]] ?? [:]
        groupNames = defaults.dictionary(forKey: Keys.groupNames) as? [String: String] ?? [:]
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

    // MARK: Reordering

    /// Move a group so it sits where `target` is (dragging up or down).
    func moveGroup(_ dragged: String, onto target: String) {
        var ids = groups.map(\.id)
        guard dragged != target,
              let from = ids.firstIndex(of: dragged),
              let to = ids.firstIndex(of: target) else { return }
        ids.remove(at: from)
        ids.insert(dragged, at: to)
        groupOrder = ids
        applyOrdering()
    }

    /// Move a row within its group so it sits where `target` is.
    func moveRow(_ dragged: String, onto target: String, in groupID: String) {
        guard dragged != target, let group = groups.first(where: { $0.id == groupID }) else { return }
        var keys: [String] = []
        for row in group.rows where !keys.contains(row.orderKey) { keys.append(row.orderKey) }
        guard let from = keys.firstIndex(of: dragged), let to = keys.firstIndex(of: target) else { return }
        keys.remove(at: from)
        keys.insert(dragged, at: to)
        rowOrder[groupID] = keys
        applyOrdering()
    }

    /// Re-sort the current groups immediately (for live drag feedback).
    private func applyOrdering() {
        let ordered = order(groups)
        if ordered != groups { groups = ordered }
    }

    // MARK: Renaming

    func renameGroup(_ groupID: String, to name: String?) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        groupNames[groupID] = trimmed.isEmpty ? nil : trimmed
        scheduleRefresh()
    }

    func renameSession(_ id: UUID, to name: String?) {
        guard let session = SessionManager.shared.session(id: id) else { return }
        SessionManager.shared.rename(session, to: name)
        scheduleRefresh()
    }

    // MARK: Font

    private func resolveFonts() {
        guard let config = (NSApp.delegate as? AppDelegate)?.ghostty.config else { return }
        let repoFamily = config.sidebarRepoFontFamily ?? config.sidebarFontFamily
        let sessionFamily = config.sidebarSessionFontFamily ?? config.sidebarFontFamily

        // Unset families default to the font the terminal actually renders with.
        var terminalFamily: String?
        if repoFamily == nil || sessionFamily == nil {
            terminalFamily = self.terminalFontFamily()
        }

        let repo = SidebarFontStyle(
            family: repoFamily ?? terminalFamily,
            size: CGFloat(max(config.sidebarRepoFontSize, 6)),
            weight: SidebarFontStyle.weight(named: config.sidebarRepoFontWeight, default: .semibold))
        let session = SidebarFontStyle(
            family: sessionFamily ?? terminalFamily,
            size: CGFloat(max(config.sidebarSessionFontSize, 6)),
            weight: SidebarFontStyle.weight(named: config.sidebarSessionFontWeight, default: .regular))
        if repo != repoFont { repoFont = repo }
        if session != sessionFont { sessionFont = session }

        // If we needed the terminal's font but no terminal exists yet, retry
        // on the next refresh.
        let waitingForTerminal = terminalFamily == nil && (repoFamily == nil || sessionFamily == nil)
        needsFontResolve = waitingForTerminal
    }

    private func terminalFontFamily() -> String? {
        for session in SessionManager.shared.sessions {
            guard let surface = session.primarySurface?.surface,
                  let raw = ghostty_surface_quicklook_font(surface) else { continue }
            let font = Unmanaged<CTFont>.fromOpaque(raw).takeRetainedValue()
            return CTFontCopyFamilyName(font) as String
        }
        return nil
    }

    /// Start a new session in a worktree that doesn't have one yet.
    func openWorktree(_ worktree: GitWorktreeInfo, in controller: TerminalController?) {
        openSession(at: worktree.worktreeRoot, in: controller)
    }

    private func openSession(at directory: String, in controller: TerminalController?) {
        guard let controller = controller ?? Self.keyController else { return }
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = directory
        SessionManager.shared.newSession(in: controller, baseConfig: config)
        scheduleRefresh()
    }

    /// Create a branch and a worktree for it next to the repository, then open
    /// a session there. Errors are shown in an alert. `completion` runs on the
    /// main thread once git finishes.
    func createWorktree(
        in group: SessionGroup,
        branch: String,
        controller: TerminalController?,
        completion: @escaping () -> Void
    ) {
        let branch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard group.isRepository, !branch.isEmpty else { return completion() }
        let commonDir = group.id
        let path = GitWorktreeCommands.defaultPath(
            commonDir: commonDir, repoName: group.repoName, branch: branch)

        DispatchQueue.global(qos: .userInitiated).async {
            let result = GitWorktreeCommands.create(commonDir: commonDir, branch: branch, path: path)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    switch result {
                    case .success:
                        self.worktreeCache[commonDir] = nil
                        self.openSession(at: path, in: controller)
                    case .failure(let failure):
                        let alert = NSAlert()
                        alert.messageText = "Couldn't create worktree “\(branch)”"
                        alert.informativeText = failure.message
                        alert.alertStyle = .warning
                        alert.runModal()
                    }
                    completion()
                }
            }
        }
    }

    /// Remove a linked worktree and its branch. Asks first only if something
    /// would be lost: open sessions in it, uncommitted files, or commits on its
    /// branch that aren't on a remote (then deleting the branch is opt-in).
    /// A clean worktree whose branch is pushed is removed without asking.
    func removeWorktree(_ worktree: GitWorktreeInfo) {
        guard worktree.isLinkedWorktree else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let check = GitWorktreeCommands.checkRemoval(of: worktree)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.finishRemoving(worktree, check: check) }
            }
        }
    }

    private func finishRemoving(_ worktree: GitWorktreeInfo, check: GitWorktreeCommands.RemovalCheck) {
        let openSessions = groups.flatMap(\.sessions).filter { $0.git?.worktreeRoot == worktree.worktreeRoot }
        let branch = worktree.branch
        let branchPushed = branch != nil && check.unpushedCommits == 0
        var deleteBranch = branchPushed

        if !openSessions.isEmpty || check.changedFiles > 0 || (branch != nil && !branchPushed) {
            var notes: [String] = []
            if !openSessions.isEmpty {
                notes.append(openSessions.count == 1
                    ? "Its open session will be closed."
                    : "Its \(openSessions.count) open sessions will be closed.")
            }
            if check.changedFiles > 0 {
                notes.append("\(check.changedFiles) uncommitted or untracked file(s) will be deleted.")
            }
            if let branch, branchPushed {
                notes.append("Branch “\(branch)” is on a remote and will be deleted too.")
            } else if let branch {
                notes.append("Branch “\(branch)” has \(check.unpushedCommits) commit(s) that aren't on any remote.")
            }

            let alert = NSAlert()
            alert.messageText = "Remove worktree “\(worktree.displayRef)”?"
            alert.informativeText = notes.joined(separator: "\n\n")
            alert.alertStyle = .warning
            let remove = alert.addButton(withTitle: "Remove")
            remove.hasDestructiveAction = true
            alert.addButton(withTitle: "Cancel")
            var checkbox: NSButton?
            if let branch, !branchPushed {
                let box = NSButton(checkboxWithTitle: "Also delete branch “\(branch)”", target: nil, action: nil)
                box.state = .off
                alert.accessoryView = box
                checkbox = box
            }
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            if let checkbox { deleteBranch = checkbox.state == .on }
        }

        for session in openSessions {
            guard let session = SessionManager.shared.session(id: session.id) else { continue }
            SessionManager.shared.close(session, withConfirmation: false)
        }

        let force = check.changedFiles > 0
        DispatchQueue.global(qos: .userInitiated).async {
            let result = GitWorktreeCommands.remove(worktree, force: force, deleteBranch: deleteBranch)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.worktreeCache[worktree.commonDir] = nil
                    self.gitCache = self.gitCache.filter { !$0.key.hasPrefix(worktree.worktreeRoot) }
                    self.scheduleRefresh()
                    if case .failure(let failure) = result {
                        let alert = NSAlert()
                        alert.messageText = "Couldn't remove worktree “\(worktree.displayRef)”"
                        alert.informativeText = failure.message
                        alert.alertStyle = .warning
                        alert.runModal()
                    }
                }
            }
        }
    }

    /// Close every session in a group. Asks once if any of them still has a
    /// running process, rather than once per session.
    func closeGroup(_ group: SessionGroup) {
        let sessions = group.sessions.compactMap { SessionManager.shared.session(id: $0.id) }
        guard !sessions.isEmpty else { return }
        let running = sessions.filter { $0.surfaces.contains { $0.needsConfirmQuit } }.count
        if running > 0 {
            let alert = NSAlert()
            alert.messageText = "Close all sessions in “\(group.name)”?"
            alert.informativeText = running == 1
                ? "1 session still has a running process. If you close it the process will be killed."
                : "\(running) sessions still have running processes. If you close them the processes will be killed."
            alert.alertStyle = .warning
            let close = alert.addButton(withTitle: "Close \(sessions.count == 1 ? "Session" : "\(sessions.count) Sessions")")
            close.hasDestructiveAction = true
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        for session in sessions {
            SessionManager.shared.close(session, withConfirmation: false)
        }
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
        observers.append(center.addObserver(forName: .burrowSurfaceDidNotify, object: nil, queue: .main) { [weak self] note in
            guard let surface = note.object as? Ghostty.SurfaceView else { return }
            MainActor.assumeIsolated { self?.surfaceDidNotify(surface) }
        })
        observers.append(center.addObserver(forName: .ghosttyConfigDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.needsFontResolve = true
                self?.scheduleRefresh()
            }
        })
    }

    /// A notification only means "needs input" if it arrives mid-turn, e.g.
    /// Claude's "needs your permission" a few seconds after it stalls on an
    /// approval. Agents also notify long after finishing (Claude's "waiting for
    /// your input" after 60s idle), which is just idle.
    private func surfaceDidNotify(_ surface: Ghostty.SurfaceView) {
        var tracker = activity[surface.id] ?? ActivityTracker()
        if Date().timeIntervalSince(tracker.lastWorking) < Self.notificationWindow {
            tracker.notified = true
            activity[surface.id] = tracker
            scheduleRefresh()
        }
    }

    func scheduleRefresh() {
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }

    func refresh() {
        let now = Date()
        if needsFontResolve { resolveFonts() }
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
                    pid: pid,
                    agent: identity?.agent,
                    activity: activityState(
                        surface: surface, identity: identity,
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

            // Agents can change directory without the shell knowing (e.g.
            // Claude switching into a new worktree), so an agent row follows
            // the agent process's own cwd.
            let agentPwd = representative.agent != nil
                ? representative.pid.flatMap(ProcessInspector.currentDirectory)
                : nil
            let pwd = agentPwd ?? primary?.pwd ?? representative.surface.pwd
            items.append((session.order, SessionItem(
                id: session.id,
                title: representative.surface.title,
                pwd: pwd,
                git: pwd.flatMap { gitInfo(for: $0, now: now) },
                agent: representative.agent,
                activity: representative.activity,
                attachedWindow: session.controller.map(ObjectIdentifier.init),
                surfaceCount: states.count,
                customName: session.displayName)))
        }

        // Forget surfaces and processes that are gone.
        activity = activity.filter { liveSurfaces.contains($0.key) }
        processCache = processCache.filter { livePIDs.contains($0.key) }
        if gitCache.count > 256 { gitCache.removeAll() }

        let newGroups = order(group(items).map { group in
            var group = group
            if let name = groupNames[group.id] { group.name = name }
            guard group.isRepository else { return group }
            let open = Set(group.sessions.compactMap { $0.git?.worktreeRoot })
            group.idleWorktrees = worktrees(commonDir: group.id, now: now)
                .filter { !open.contains($0.worktreeRoot) }
            return group
        })
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
                    repoName: item.git?.repoName ?? "Other",
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

    /// Apply the user's custom group and row ordering. Anything without a
    /// custom position keeps its default order, after the ordered items.
    private func order(_ groups: [SessionGroup]) -> [SessionGroup] {
        let groupIndex = Dictionary(groupOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let sortedGroups = groups.enumerated().sorted { lhs, rhs in
            let l = groupIndex[lhs.element.id] ?? Int.max
            let r = groupIndex[rhs.element.id] ?? Int.max
            return l != r ? l < r : lhs.offset < rhs.offset
        }.map(\.element)

        return sortedGroups.map { group in
            var group = group
            let defaultRows = group.sessions.map(SidebarRow.session) + group.idleWorktrees.map(SidebarRow.worktree)
            let keyIndex = Dictionary(
                (rowOrder[group.id] ?? []).enumerated().map { ($1, $0) },
                uniquingKeysWith: { a, _ in a })
            group.rows = defaultRows.enumerated().sorted { lhs, rhs in
                let l = keyIndex[lhs.element.orderKey] ?? Int.max
                let r = keyIndex[rhs.element.orderKey] ?? Int.max
                return l != r ? l < r : lhs.offset < rhs.offset
            }.map(\.element)
            group.sessions = group.rows.compactMap {
                if case .session(let item) = $0 { return item }
                return nil
            }
            group.idleWorktrees = group.rows.compactMap {
                if case .worktree(let worktree) = $0 { return worktree }
                return nil
            }
            return group
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
        identity: ProcessIdentity?,
        isViewed: Bool,
        now: Date
    ) -> SessionActivity {
        let id = surface.id
        guard let identity else { return .shell }
        guard identity.agent != nil else {
            activity[id] = nil
            return identity.isShell ? .shell : .command(identity.name)
        }

        var tracker = activity[id] ?? ActivityTracker()

        // Agents report their own state through what they draw: footer text
        // and approval prompts on screen, their title, progress (OSC 9;4),
        // notifications, and the bell.
        // Only changes to the title's leading status glyph count as animation
        // ("◐ Fix bug" -> "◑ Fix bug"); a title changing to new text (e.g. the
        // shell's title being replaced when an agent starts) is not.
        let title = surface.title
        if title != tracker.lastTitle {
            if !tracker.lastTitle.isEmpty, TerminalTitle.clean(title) == TerminalTitle.clean(tracker.lastTitle) {
                tracker.titleChanges.append(now)
            }
            tracker.lastTitle = title
        }
        tracker.titleChanges.removeAll { now.timeIntervalSince($0) > Self.titleAnimationWindow }
        let titleAnimating = tracker.titleChanges.count >= 2

        let screen = surface.activeScreenTail()
        let markedWorking = AgentStateDetector.working(screen: screen, title: title)
        let progressActive = surface.progressReport.map { $0.state != .remove } ?? false

        // Explicit "working" text means any earlier attention request was answered.
        if markedWorking || isViewed { tracker.notified = false }

        let needsInput = AgentStateDetector.needsInput(screen: screen, title: title)
            || surface.bell
            || tracker.notified
        if markedWorking || titleAnimating || progressActive {
            tracker.lastWorking = now
        }
        let working = !needsInput && now.timeIntervalSince(tracker.lastWorking) < Self.idleDebounce
        if working && markedWorking { tracker.sawMarkedWorking = true }

        if tracker.wasWorking && !working && !needsInput && !isViewed && tracker.sawMarkedWorking {
            tracker.unseenCompletion = true
        }
        if !working { tracker.sawMarkedWorking = false }
        if isViewed || working {
            tracker.unseenCompletion = false
        }
        tracker.wasWorking = working
        activity[id] = tracker

        if needsInput { return .agentNeedsInput }
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
