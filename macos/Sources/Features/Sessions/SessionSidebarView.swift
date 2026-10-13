import AppKit
import SwiftUI

/// Wraps a window's terminal content with the session sidebar on the left.
struct SessionSidebarLayout<Content: View>: View {
    @ObservedObject var ghostty: Ghostty.App
    @ObservedObject private var store = SessionStore.shared
    private let window: SidebarWindowRef
    let content: Content

    init(ghostty: Ghostty.App, controller: TerminalController, @ViewBuilder content: () -> Content) {
        self.ghostty = ghostty
        self.window = SidebarWindowRef(controller)
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if store.isCollapsed {
                    SessionRail(store: store, window: window)
                } else {
                    SessionSidebar(store: store, window: window)
                }
            }
            .frame(width: store.currentWidth)
            .frame(maxHeight: .infinity)
            .background(sidebarBackground)

            SidebarResizeHandle(store: store)

            content
        }
    }

    private var sidebarBackground: some View {
        // Match the terminal background so the sidebar reads as part of the
        // window, with a slight wash to separate it from the terminal.
        ZStack {
            ghostty.config.backgroundColor.opacity(ghostty.config.backgroundOpacity)
            Color.primary.opacity(0.035)
        }
    }
}

// MARK: Expanded sidebar

private struct SessionSidebar: View {
    @ObservedObject var store: SessionStore
    let window: SidebarWindowRef

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(store.groups) { group in
                        SessionGroupSection(store: store, window: window, group: group)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
        }
    }

    private var header: some View {
        let sessions = store.groups.flatMap(\.sessions)
        let working = sessions.filter { $0.activity == .agentWorking }.count
        let waiting = sessions.filter { $0.activity == .agentNeedsInput }.count

        return HStack(spacing: 8) {
            Text("SESSIONS")
                .font(store.sessionFont.font(scale: 10 / 12, weight: .semibold))
                .tracking(0.8)
                .foregroundColor(.secondary)
            if working > 0 {
                HStack(spacing: 3) {
                    CursorSpinner(size: 9)
                    Text("\(working)").font(store.sessionFont.font(scale: 10 / 12, weight: .medium)).foregroundColor(.secondary)
                }
                .help("\(working) agent(s) working")
            }
            if waiting > 0 {
                HStack(spacing: 4) {
                    PulsingDot(color: SessionPalette.attention, size: 6)
                    Text("\(waiting)").font(store.sessionFont.font(scale: 10 / 12, weight: .medium)).foregroundColor(.secondary)
                }
                .help("\(waiting) agent(s) waiting for input")
            }
            Spacer()
            Button {
                window.controller?.newTab(nil)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("New Session (⌘T)")
            SidebarToggleButton(store: store)
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(height: 32)
    }
}

private struct SessionGroupSection: View {
    @ObservedObject var store: SessionStore
    let window: SidebarWindowRef
    let group: SessionGroup
    @State private var renaming = false
    @State private var hovering = false
    @State private var newWorktree: NewWorktreeState?

    private enum NewWorktreeState: Equatable {
        case naming
        case creating(String)
    }

    private var folded: Bool { store.foldedGroups.contains(group.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            groupHeader
            if let newWorktree {
                newWorktreeRow(newWorktree)
            }
            if !folded {
                ForEach(group.rows) { row in
                    rowView(row)
                        .onDrag {
                            store.dragging = .row(group: group.id, key: row.orderKey)
                            return NSItemProvider(object: row.orderKey as NSString)
                        }
                        .onDrop(of: [.text], delegate: SidebarDropDelegate(
                            store: store, groupID: group.id, rowKey: row.orderKey))
                }
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: SidebarRow) -> some View {
        switch row {
        case .session(let session):
            SessionRow(store: store, window: window, session: session)
        case .worktree(let worktree):
            WorktreeRow(store: store, window: window, worktree: worktree)
        }
    }

    private func startNewWorktree() {
        if folded { store.toggleFold(group.id) }
        newWorktree = .naming
    }

    private func newWorktreeRow(_ state: NewWorktreeState) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Group {
                if case .creating = state {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: 20, height: 16)

            switch state {
            case .naming:
                InlineRenameField(
                    initial: "",
                    placeholder: "New branch",
                    font: store.sessionFont.font(),
                    commitsOnBlur: false
                ) { branch in
                    let branch = branch?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    guard !branch.isEmpty else {
                        newWorktree = nil
                        refocusTerminal(window)
                        return
                    }
                    newWorktree = .creating(branch)
                    store.createWorktree(in: group, branch: branch, controller: window.controller) {
                        newWorktree = nil
                    }
                }
            case .creating(let branch):
                Text(branch)
                    .font(store.sessionFont.font())
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .help("Creates the branch and a worktree folder next to the repository")
    }

    private var groupHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.secondary)
                .rotationEffect(.degrees(folded ? 0 : 90))
                .frame(width: 10)
            Image(systemName: group.isRepository ? "shippingbox" : "folder")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            if renaming {
                InlineRenameField(initial: group.name, font: store.repoFont.font()) { name in
                    renaming = false
                    if let name { store.renameGroup(group.id, to: name) }
                    refocusTerminal(window)
                }
            } else {
                Text(group.name)
                    .font(store.repoFont.font())
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)

            // When folded, keep important activity visible.
            if folded {
                ForEach(group.sessions.filter(\.activity.isNoteworthy)) { session in
                    SessionIndicator(activity: session.activity)
                }
            }
            if group.isRepository && hovering && newWorktree == nil {
                Button(action: startNewWorktree) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help("New Worktree")
            }
            Text("\(group.sessions.count)")
                .font(store.repoFont.font(scale: 11 / 14, weight: .medium))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            guard !renaming else { return }
            withAnimation(.easeOut(duration: 0.15)) { store.toggleFold(group.id) }
        }
        .onDrag {
            store.dragging = .group(group.id)
            return NSItemProvider(object: group.id as NSString)
        }
        .onDrop(of: [.text], delegate: SidebarDropDelegate(store: store, groupID: group.id, rowKey: nil))
        .help(group.isRepository ? group.id : "Sessions outside a git repository")
        .contextMenu {
            if group.isRepository {
                Button("New Worktree…", action: startNewWorktree)
                    .disabled(newWorktree != nil)
                Divider()
            }
            Button("Rename…") { renaming = true }
            if store.groupNames[group.id] != nil {
                Button("Reset Name") { store.renameGroup(group.id, to: nil) }
            }
            Divider()
            Button(group.isRepository ? "Close Repository" : "Close All Sessions") { store.closeGroup(group) }
        }
    }
}

private struct SessionRow: View {
    @ObservedObject var store: SessionStore
    let window: SidebarWindowRef
    let session: SessionItem
    @State private var hovering = false
    @State private var renaming = false

    private var isCurrent: Bool { session.attachedWindow == window.id }
    private var isInOtherWindow: Bool { session.isAttached && !isCurrent }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            SessionIndicator(activity: session.activity)
                .frame(width: 20, height: 16)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    if renaming {
                        InlineRenameField(
                            initial: session.customName ?? "",
                            placeholder: branchLabel,
                            font: store.sessionFont.font(weight: store.sessionFont.weight.bolder)
                        ) { name in
                            renaming = false
                            if let name { store.renameSession(session.id, to: name) }
                            refocusTerminal(window)
                        }
                    } else {
                        Text(session.customName ?? branchLabel)
                            .font(store.sessionFont.font(weight: isCurrent ? store.sessionFont.weight.bolder : nil))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                    if let root = session.git?.worktreeRoot, let status = store.gitStatuses[root] {
                        GitStatusBadges(status: status, font: store.sessionFont.font(scale: 0.75, weight: .medium))
                    }
                    if session.surfaceCount > 1 {
                        Label("\(session.surfaceCount)", systemImage: "square.split.2x1")
                            .labelStyle(.titleAndIcon)
                            .font(store.sessionFont.font(scale: 0.75, weight: .medium))
                            .foregroundColor(.secondary)
                            .help("\(session.surfaceCount) splits")
                    }
                    if isInOtherWindow {
                        Image(systemName: "macwindow")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                            .help("Shown in another window")
                    }
                }
                statusLine
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(rowFill))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            guard !renaming else { return }
            store.select(session.id, in: window.controller)
        }
        .help(session.pwd ?? session.title)
        .contextMenu { contextMenu }
    }

    private var rowFill: Color {
        if isCurrent { return Color.accentColor.opacity(0.25) }
        if hovering { return Color.primary.opacity(0.07) }
        return .clear
    }

    /// The branch (or directory, outside git) that identifies the session.
    private var branchLabel: String {
        if let git = session.git { return git.displayRef }
        if let pwd = session.pwd { return abbreviate(pwd) }
        return session.title.isEmpty ? "Terminal" : session.title
    }

    /// When the session has a custom name, the branch moves to the status line.
    private func withBranch(_ text: String) -> String {
        session.customName == nil ? text : "\(branchLabel) · \(text)"
    }

    @ViewBuilder
    private var statusLine: some View {
        let agent = session.agent?.displayName ?? ""
        switch session.activity {
        case .agentWorking:
            ShimmerText(text: withBranch("\(agent) · \(session.subtitle ?? "Thinking…")"), font: store.sessionFont.font(scale: 11 / 12, weight: .regular))
        case .agentNeedsInput:
            detail(withBranch("\(agent) · Needs input"), color: SessionPalette.attention)
        case .agentDone:
            detail(withBranch("\(agent) · Done\(session.subtitle.map { " — \($0)" } ?? "")"), color: SessionPalette.done)
        case .agentIdle:
            detail(withBranch("\(agent) · \(session.subtitle ?? "Idle")"), color: .secondary)
        case .command(let name):
            detail(withBranch(name), color: .secondary)
        case .shell:
            if session.customName != nil {
                detail(branchLabel, color: .secondary.opacity(0.8))
            } else if session.git != nil, let pwd = session.pwd {
                detail(abbreviate(pwd), color: .secondary.opacity(0.8))
            } else if let subtitle = session.subtitle, subtitle != branchLabel {
                detail(subtitle, color: .secondary.opacity(0.8))
            }
        }
    }

    private func detail(_ text: String, color: Color) -> some View {
        Text(text)
            .font(store.sessionFont.font(scale: 11 / 12, weight: .regular))
            .foregroundColor(color)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button("Rename…") { renaming = true }
        if session.customName != nil {
            Button("Reset Name") { store.renameSession(session.id, to: nil) }
        }
        Divider()
        if let pwd = session.pwd {
            Button("Copy Path") { copy(pwd) }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: pwd)])
            }
        }
        if let branch = session.git?.branch {
            Button("Copy Branch Name") { copy(branch) }
        }
        Divider()
        Button("Close Session") { store.close(session.id) }
        if let git = session.git, git.isLinkedWorktree {
            Button("Remove Worktree") { store.removeWorktree(git) }
        }
    }

    private func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

/// A worktree with no open session: dimmed, and clicking it opens a session there.
private struct WorktreeRow: View {
    @ObservedObject var store: SessionStore
    let window: SidebarWindowRef
    let worktree: GitWorktreeInfo
    @State private var hovering = false

    /// The agent that was running here when Burrow last quit, if any.
    private var agent: AgentKind? { store.resumableAgents[worktree.worktreeRoot] }

    private func open(resume: Bool) {
        store.openWorktree(worktree, in: window.controller, resume: resume)
    }

    private var helpText: String {
        let path = abbreviate(worktree.worktreeRoot)
        guard let agent else { return "Open a session in \(path)" }
        return "Resume \(agent.displayName) in \(path) (⌥-click for a shell)"
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: hovering ? "plus.circle.fill" : "circle.dashed")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .frame(width: 20, height: 16)

            Text(worktree.displayRef)
                .font(store.sessionFont.font())
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if let status = store.gitStatuses[worktree.worktreeRoot] {
                GitStatusBadges(status: status, font: store.sessionFont.font(scale: 0.75, weight: .medium))
            }
            if let agent {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9, weight: .medium))
                    Text(agent.displayName)
                        .font(store.sessionFont.font(scale: 11 / 12))
                        .lineLimit(1)
                }
                .foregroundColor(.secondary)
                .fixedSize()
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .opacity(hovering ? 0.85 : 0.45)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(hovering ? Color.primary.opacity(0.05) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            open(resume: !NSEvent.modifierFlags.contains(.option))
        }
        .help(helpText)
        .contextMenu {
            if let agent {
                Button("Resume \(agent.displayName)") { open(resume: true) }
                Button("Open Shell") { open(resume: false) }
            } else {
                Button("Open Session") { open(resume: false) }
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: worktree.worktreeRoot)])
            }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(worktree.worktreeRoot, forType: .string)
            }
            if worktree.isLinkedWorktree {
                Divider()
                Button("Remove Worktree") { store.removeWorktree(worktree) }
            }
        }
    }
}

/// Compact git status for a row: `●3` uncommitted files, `↑2` commits to
/// push, `↓1` commits to pull. Nothing at all when the worktree is clean.
private struct GitStatusBadges: View {
    let status: GitStatusSummary
    let font: Font

    var body: some View {
        if !status.isClean {
            HStack(spacing: 4) {
                if status.changedFiles > 0 {
                    Text("●\(status.changedFiles)").foregroundColor(SessionPalette.attention)
                }
                if status.ahead > 0 {
                    Text("↑\(status.ahead)").foregroundColor(SessionPalette.done)
                }
                if status.behind > 0 {
                    Text("↓\(status.behind)").foregroundColor(.secondary)
                }
            }
            .font(font)
            .monospacedDigit()
            .fixedSize()
            .help(helpText)
        }
    }

    private var helpText: String {
        var parts: [String] = []
        if status.changedFiles > 0 {
            parts.append("\(status.changedFiles) uncommitted file\(status.changedFiles == 1 ? "" : "s")")
        }
        if status.ahead > 0 {
            parts.append("\(status.ahead) commit\(status.ahead == 1 ? "" : "s") to push")
        }
        if status.behind > 0 {
            parts.append("\(status.behind) commit\(status.behind == 1 ? "" : "s") to pull (as of last fetch)")
        }
        return parts.joined(separator: "\n")
    }
}

// MARK: Renaming and reordering

/// An inline text field for renaming. Return commits, Escape cancels, and
/// clicking away commits. Committing an empty name clears the custom name.
private struct InlineRenameField: View {
    let initial: String
    var placeholder: String = "Name"
    let font: Font
    /// Whether clicking away commits (like Finder renames) or cancels.
    var commitsOnBlur = true
    /// Called with the new name, or nil if editing was cancelled.
    let onFinish: (String?) -> Void

    @State private var draft = ""
    @State private var finished = false
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $draft)
            .textFieldStyle(.plain)
            .font(font)
            .focused($focused)
            .onAppear {
                draft = initial
                DispatchQueue.main.async { focused = true }
            }
            .onSubmit { finish(draft) }
            .onExitCommand { finish(nil) }
            .onChange(of: focused) { isFocused in
                if !isFocused { finish(commitsOnBlur ? draft : nil) }
            }
    }

    private func finish(_ value: String?) {
        guard !finished else { return }
        finished = true
        onFinish(value)
    }
}

/// Live reordering: as a dragged group or row passes over another, it moves
/// into that position.
private struct SidebarDropDelegate: DropDelegate {
    let store: SessionStore
    let groupID: String
    /// The row this delegate is attached to, or nil for a group header.
    let rowKey: String?

    func validateDrop(info: DropInfo) -> Bool { store.dragging != nil }

    func dropEntered(info: DropInfo) {
        switch store.dragging {
        case .group(let dragged):
            withAnimation(.easeOut(duration: 0.15)) { store.moveGroup(dragged, onto: groupID) }
        case .row(let draggedGroup, let draggedKey):
            // Rows only move within their own repository.
            guard draggedGroup == groupID, let rowKey else { return }
            withAnimation(.easeOut(duration: 0.15)) { store.moveRow(draggedKey, onto: rowKey, in: groupID) }
        case nil:
            break
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        store.dragging = nil
        return true
    }
}

/// Return keyboard focus to the window's terminal (e.g. after renaming).
@MainActor
private func refocusTerminal(_ window: SidebarWindowRef) {
    guard let surface = window.controller?.focusedSurface else { return }
    Ghostty.moveFocus(to: surface)
}

// MARK: Collapsed rail

private struct SessionRail: View {
    @ObservedObject var store: SessionStore
    let window: SidebarWindowRef

    var body: some View {
        VStack(spacing: 0) {
            SidebarToggleButton(store: store)
                .frame(height: 32)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 4) {
                    ForEach(store.groups) { group in
                        Text(initials(group.name))
                            .font(store.repoFont.font(scale: 9 / 14, weight: .bold))
                            .foregroundColor(.secondary)
                            .padding(.top, 6)
                            .help(group.name)
                        ForEach(group.rows) { row in
                            railItem(row, group: group)
                        }
                    }
                }
                .padding(.bottom, 12)
            }
        }
    }

    @ViewBuilder
    private func railItem(_ row: SidebarRow, group: SessionGroup) -> some View {
        switch row {
        case .session(let session):
            SessionIndicator(activity: session.activity)
                .frame(width: 30, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(session.attachedWindow == window.id ? Color.accentColor.opacity(0.25) : .clear))
                .contentShape(Rectangle())
                .onTapGesture { store.select(session.id, in: window.controller) }
                .help(railTooltip(group: group, session: session))
        case .worktree(let worktree):
            Image(systemName: "circle.dashed")
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .opacity(0.5)
                .frame(width: 30, height: 20)
                .contentShape(Rectangle())
                .onTapGesture { store.openWorktree(worktree, in: window.controller) }
                .help("\(group.name) · \(worktree.displayRef) — click to open")
        }
    }

    private func initials(_ name: String) -> String {
        String(name.filter { $0.isLetter || $0.isNumber }.prefix(2)).uppercased()
    }

    private func railTooltip(group: SessionGroup, session: SessionItem) -> String {
        var parts = [group.name]
        if let name = session.customName { parts.append(name) }
        if let ref = session.git?.displayRef { parts.append(ref) }
        if let agent = session.agent { parts.append(agent.displayName) }
        return parts.joined(separator: " · ")
    }
}

// MARK: Chrome

private struct SidebarToggleButton: View {
    @ObservedObject var store: SessionStore

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) { store.toggleCollapsed() }
        } label: {
            Image(systemName: "sidebar.left")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(store.isCollapsed ? "Expand Sessions (⌃⌘S)" : "Collapse Sessions (⌃⌘S)")
    }
}

/// A thin divider that can be dragged to resize the expanded sidebar.
private struct SidebarResizeHandle: View {
    @ObservedObject var store: SessionStore
    @State private var dragStart: CGFloat?

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.1))
            .frame(width: 1)
            .overlay(
                Color.clear
                    .frame(width: 7)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        guard !store.isCollapsed else { return }
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                guard !store.isCollapsed else { return }
                                let start = dragStart ?? store.width
                                dragStart = start
                                store.width = min(max(start + value.translation.width, SessionStore.minWidth), SessionStore.maxWidth)
                            }
                            .onEnded { _ in dragStart = nil }))
    }
}

/// A weak reference to the window a sidebar instance lives in.
struct SidebarWindowRef {
    weak var controller: TerminalController?
    let id: ObjectIdentifier

    init(_ controller: TerminalController) {
        self.controller = controller
        self.id = ObjectIdentifier(controller)
    }
}

private func abbreviate(_ path: String) -> String {
    let home = NSHomeDirectory()
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
}

extension SessionActivity {
    /// Activity worth surfacing even when a group is folded.
    var isNoteworthy: Bool {
        switch self {
        case .agentWorking, .agentNeedsInput, .agentDone: return true
        default: return false
        }
    }
}
