import AppKit
import GhosttyKit

/// A terminal session: a split tree of surfaces that lives independently of
/// any window, like a tmux session. A session is either attached to exactly
/// one window (which displays it) or detached (kept alive in the background).
@MainActor
final class TerminalSession: Identifiable {
    let id = UUID()

    /// Monotonic creation order, used for stable sidebar ordering.
    let order: Int

    /// The session's surfaces. While attached, the controller's `surfaceTree`
    /// is authoritative and this is kept in sync with it.
    fileprivate(set) var tree: SplitTree<Ghostty.SurfaceView>

    /// The window currently displaying this session, if any.
    fileprivate(set) weak var controller: TerminalController?

    /// The surface that had focus when the session was last displayed.
    fileprivate(set) var lastFocusedSurfaceID: UUID?

    /// The frame of the window that last displayed this session, used to
    /// restore the same window geometry when reattaching.
    fileprivate(set) var lastWindowFrame: NSRect?

    /// When the session was last attached or detached; the most recent
    /// detached session is the one reattached when reopening the app.
    fileprivate(set) var lastActive = Date()

    fileprivate init(tree: SplitTree<Ghostty.SurfaceView>, order: Int) {
        self.tree = tree
        self.order = order
    }

    var isAttached: Bool { controller != nil }

    /// The surfaces of this session (live from the window when attached).
    var surfaces: SplitTree<Ghostty.SurfaceView> { controller?.surfaceTree ?? tree }

    /// The surface that best represents this session (for title, cwd, branch).
    var primarySurface: Ghostty.SurfaceView? {
        if let controller, let focused = controller.focusedSurface, surfaces.contains(focused) {
            return focused
        }
        if let id = lastFocusedSurfaceID, let match = surfaces.first(where: { $0.id == id }) {
            return match
        }
        return surfaces.first
    }
}

/// Owns all terminal sessions and attaches/detaches them to windows.
///
/// Windows no longer use native tabs. Instead each window displays one session
/// at a time and the sidebar switches between them. Closing a window detaches
/// its session (processes keep running); only quitting the app terminates them.
@MainActor
final class SessionManager {
    static let shared = SessionManager()

    /// Master switch for session mode. When false, Ghostty's native tab
    /// behavior is used unchanged.
    nonisolated static let isEnabled = true

    private(set) var sessions: [TerminalSession] = []
    private var orderCounter = 0
    private var observers: [NSObjectProtocol] = []

    private init() {
        // Surfaces in detached sessions have no controller to handle their
        // close requests (e.g. the process exited), so we handle them here.
        observers.append(NotificationCenter.default.addObserver(
            forName: Ghostty.Notification.ghosttyCloseSurface,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let surface = notification.object as? Ghostty.SurfaceView else { return }
            MainActor.assumeIsolated { self?.detachedSurfaceDidRequestClose(surface) }
        })
    }

    var detachedSessions: [TerminalSession] { sessions.filter { !$0.isAttached } }

    func session(id: UUID) -> TerminalSession? {
        sessions.first { $0.id == id }
    }

    func session(attachedTo controller: TerminalController) -> TerminalSession? {
        sessions.first { $0.controller === controller }
    }

    func session(containing surface: Ghostty.SurfaceView) -> TerminalSession? {
        sessions.first { $0.surfaces.contains(surface) }
    }

    // MARK: Controller lifecycle hooks

    /// Called once a terminal window has loaded. Binds its surfaces to a session:
    /// either an existing detached session it is displaying (e.g. reattach) or a
    /// brand new one.
    func adopt(_ controller: TerminalController) {
        controllerTreeDidChange(controller, to: controller.surfaceTree)
    }

    /// Keep the attached session's tree in sync with the window (splits opened,
    /// closed, moved, …).
    func controllerTreeDidChange(_ controller: TerminalController, to tree: SplitTree<Ghostty.SurfaceView>) {
        guard !tree.isEmpty else { return }

        if let session = session(attachedTo: controller) {
            session.tree = tree
            return
        }

        // A window that starts out displaying surfaces from a detached session
        // (e.g. reopening the app) attaches that session rather than creating one.
        if let session = detachedSessions.first(where: { candidate in
            tree.contains { candidate.tree.contains($0) }
        }) {
            session.controller = controller
            session.tree = tree
            session.lastActive = Date()
            return
        }

        orderCounter += 1
        let session = TerminalSession(tree: tree, order: orderCounter)
        session.controller = controller
        sessions.append(session)
    }

    /// Called when a window is closing for any reason. Its session is detached
    /// and keeps running in the background.
    func controllerWillClose(_ controller: TerminalController) {
        guard let session = session(attachedTo: controller) else { return }
        detach(session, from: controller)
    }

    // MARK: Attach / detach

    /// Show a session in a window. If the session is already displayed in a
    /// different window, that window is brought forward instead.
    func attach(_ session: TerminalSession, to controller: TerminalController) {
        if let current = session.controller {
            if current !== controller {
                current.window?.makeKeyAndOrderFront(nil)
            }
            focus(session, in: current)
            return
        }

        if let previous = self.session(attachedTo: controller) {
            detach(previous, from: controller)
        }

        session.controller = controller
        session.lastActive = Date()
        controller.surfaceTree = session.tree
        focus(session, in: controller)
    }

    private func detach(_ session: TerminalSession, from controller: TerminalController) {
        if !controller.surfaceTree.isEmpty {
            session.tree = controller.surfaceTree
        }
        session.lastFocusedSurfaceID = controller.focusedSurface?.id ?? session.lastFocusedSurfaceID
        session.lastWindowFrame = controller.window?.frame ?? session.lastWindowFrame
        session.controller = nil
        session.lastActive = Date()

        // Stop rendering surfaces nobody can see. Output is still processed so
        // the session stays current; it just isn't drawn.
        for view in session.tree {
            if let surface = view.surface, view.isWindowVisible {
                ghostty_surface_set_occlusion(surface, false)
                view.isWindowVisible = false
            }
        }
    }

    private func focus(_ session: TerminalSession, in controller: TerminalController) {
        guard let target = session.primarySurface else { return }
        controller.focusedSurface = target
        DispatchQueue.main.async {
            Ghostty.moveFocus(to: target)
            if !NSApp.isActive {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    // MARK: Session creation and removal

    /// Create a new session (the replacement for "new tab") and attach it to
    /// the given window.
    @discardableResult
    func newSession(
        in controller: TerminalController,
        baseConfig: Ghostty.SurfaceConfiguration?
    ) -> TerminalSession? {
        guard let app = controller.ghostty.app else { return nil }
        let view = Ghostty.SurfaceView(app, baseConfig: baseConfig)

        orderCounter += 1
        let session = TerminalSession(tree: .init(view: view), order: orderCounter)
        sessions.append(session)
        attach(session, to: controller)
        return session
    }

    /// End the session displayed in a window (its last surface closed, or the
    /// user closed it). The window switches to the most recently used detached
    /// session, or closes if there are none.
    func endSession(in controller: TerminalController) {
        if let session = session(attachedTo: controller) {
            sessions.removeAll { $0 === session }
        }

        if let next = detachedSessions.max(by: { $0.lastActive < $1.lastActive }) {
            attach(next, to: controller)
        } else {
            controller.surfaceTree = .init()
            controller.window?.close()
        }
    }

    /// End a session that may or may not be displayed. Used by the sidebar.
    func close(_ session: TerminalSession) {
        if let controller = session.controller {
            controller.closeSession(withConfirmation: true)
        } else {
            confirmIfNeeded(session) { [weak self] in
                self?.sessions.removeAll { $0 === session }
            }
        }
    }

    private func confirmIfNeeded(_ session: TerminalSession, _ action: @escaping () -> Void) {
        guard session.tree.contains(where: { $0.needsConfirmQuit }) else {
            action()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Close Session?"
        alert.informativeText = "The session still has a running process. If you close it the process will be killed."
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        if alert.runModal() == .alertFirstButtonReturn {
            action()
        }
    }

    private func detachedSurfaceDidRequestClose(_ surface: Ghostty.SurfaceView) {
        guard let session = sessions.first(where: { !$0.isAttached && $0.tree.contains(surface) }),
              let node = session.tree.root?.node(view: surface) else { return }
        session.tree = session.tree.removing(node)
        if session.tree.isEmpty {
            sessions.removeAll { $0 === session }
        }
    }

    // MARK: App lifecycle

    /// Open a window for the most recently used detached session, or a fresh
    /// window if there are none. Used when the app is reopened from the Dock.
    func reattachOrNewWindow(_ ghostty: Ghostty.App) {
        if let session = detachedSessions.max(by: { $0.lastActive < $1.lastActive }) {
            // Reuse the undo-restore path: it recreates a window for an existing
            // tree with an exact frame and restores focus. `adopt` then binds
            // the new window to this session.
            let frame = session.lastWindowFrame
                ?? NSRect(x: 0, y: 0, width: 900, height: 600)
            let controller = TerminalController(ghostty, with: .init(
                frame: frame,
                surfaceTree: session.tree,
                focusedSurface: session.primarySurface?.id,
                tabIndex: nil,
                tabGroup: nil,
                tabColor: .none))
            if session.lastWindowFrame == nil { controller.window?.center() }
            controller.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            _ = TerminalController.newWindow(ghostty)
        }
    }

    /// Quitting terminates detached sessions too, so confirm when any of them
    /// still has a running process. Returns nil to defer to the default flow.
    func confirmQuitIfNeeded() -> NSApplication.TerminateReply? {
        let running = detachedSessions.filter { $0.tree.contains(where: { $0.needsConfirmQuit }) }
        guard !running.isEmpty else { return nil }

        let alert = NSAlert()
        alert.messageText = "Quit \(Burrow.appName)?"
        alert.informativeText = running.count == 1
            ? "A background session still has a running process. Quitting will terminate all sessions."
            : "\(running.count) background sessions still have running processes. Quitting will terminate all sessions."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    // MARK: Navigation

    /// Sessions in sidebar display order.
    var orderedSessions: [TerminalSession] {
        let ids = SessionStore.shared.groups.flatMap(\.sessions).map(\.id)
        let byID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        let ordered = ids.compactMap { byID[$0] }
        // Include anything the store hasn't picked up yet.
        return ordered + sessions.filter { s in !ordered.contains { $0 === s } }
    }

    /// Switch the window to the session `offset` positions away in sidebar
    /// order, skipping sessions displayed in other windows.
    func selectAdjacent(offset: Int, in controller: TerminalController) {
        let candidates = orderedSessions.filter { $0.controller == nil || $0.controller === controller }
        guard !candidates.isEmpty else { return }
        let current = candidates.firstIndex { $0.controller === controller } ?? -1
        let next = (current + offset + candidates.count) % candidates.count
        attach(candidates[next], to: controller)
    }

    /// Handle the goto_tab action. Returns true if handled.
    func gotoTab(_ tab: ghostty_action_goto_tab_e, in controller: TerminalController) -> Bool {
        switch tab {
        case GHOSTTY_GOTO_TAB_PREVIOUS:
            selectAdjacent(offset: -1, in: controller)
        case GHOSTTY_GOTO_TAB_NEXT:
            selectAdjacent(offset: 1, in: controller)
        case GHOSTTY_GOTO_TAB_LAST:
            if let last = orderedSessions.last { attach(last, to: controller) }
        default:
            let index = Int(tab.rawValue) - 1
            let ordered = orderedSessions
            guard index >= 0, !ordered.isEmpty else { return true }
            attach(ordered[min(index, ordered.count - 1)], to: controller)
        }
        return true
    }
}
