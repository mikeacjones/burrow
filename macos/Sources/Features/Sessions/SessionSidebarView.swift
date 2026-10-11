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
                VStack(alignment: .leading, spacing: 10) {
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
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundColor(.secondary)
            if working > 0 {
                HStack(spacing: 3) {
                    CursorSpinner(size: 9)
                    Text("\(working)").font(.system(size: 10, weight: .medium)).foregroundColor(.secondary)
                }
                .help("\(working) agent(s) working")
            }
            if waiting > 0 {
                HStack(spacing: 4) {
                    PulsingDot(color: SessionPalette.attention, size: 6)
                    Text("\(waiting)").font(.system(size: 10, weight: .medium)).foregroundColor(.secondary)
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

    private var folded: Bool { store.foldedGroups.contains(group.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            groupHeader
            if !folded {
                ForEach(group.sessions) { session in
                    SessionRow(store: store, window: window, session: session)
                }
            }
        }
    }

    private var groupHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(.secondary)
                .rotationEffect(.degrees(folded ? 0 : 90))
                .frame(width: 10)
            Image(systemName: group.isRepository ? "shippingbox" : "folder")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            Text(group.name)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)

            // When folded, keep important activity visible.
            if folded {
                ForEach(group.sessions.filter(\.activity.isNoteworthy)) { session in
                    SessionIndicator(activity: session.activity)
                }
            }
            Text("\(group.sessions.count)")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.15)) { store.toggleFold(group.id) }
        }
        .help(group.isRepository ? group.id : "Sessions outside a git repository")
    }
}

private struct SessionRow: View {
    @ObservedObject var store: SessionStore
    let window: SidebarWindowRef
    let session: SessionItem
    @State private var hovering = false

    private var isCurrent: Bool { session.attachedWindow == window.id }
    private var isInOtherWindow: Bool { session.isAttached && !isCurrent }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            SessionIndicator(activity: session.activity)
                .frame(width: 20, height: 16)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(primaryLabel)
                        .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let worktree = session.worktreeLabel {
                        Text(worktree)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.08)))
                            .help("Worktree: \(session.git?.worktreeRoot ?? worktree)")
                    }
                    Spacer(minLength: 0)
                    if session.surfaceCount > 1 {
                        Label("\(session.surfaceCount)", systemImage: "square.split.2x1")
                            .labelStyle(.titleAndIcon)
                            .font(.system(size: 9, weight: .medium))
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
        .onTapGesture { store.select(session.id, in: window.controller) }
        .help(session.pwd ?? session.title)
        .contextMenu { contextMenu }
    }

    private var rowFill: Color {
        if isCurrent { return Color.accentColor.opacity(0.25) }
        if hovering { return Color.primary.opacity(0.07) }
        return .clear
    }

    private var primaryLabel: String {
        if let git = session.git { return git.displayRef }
        if let pwd = session.pwd { return abbreviate(pwd) }
        return session.title.isEmpty ? "Terminal" : session.title
    }

    @ViewBuilder
    private var statusLine: some View {
        let agent = session.agent?.displayName ?? ""
        switch session.activity {
        case .agentWorking:
            ShimmerText(text: "\(agent) · \(session.subtitle ?? "Thinking…")")
        case .agentNeedsInput:
            detail("\(agent) · Needs input", color: SessionPalette.attention)
        case .agentDone:
            detail("\(agent) · Done\(session.subtitle.map { " — \($0)" } ?? "")", color: SessionPalette.done)
        case .agentIdle:
            detail("\(agent) · \(session.subtitle ?? "Idle")", color: .secondary)
        case .command(let name):
            detail(name, color: .secondary)
        case .shell:
            if session.git != nil, let pwd = session.pwd {
                detail(abbreviate(pwd), color: .secondary.opacity(0.8))
            } else if let subtitle = session.subtitle, subtitle != primaryLabel {
                detail(subtitle, color: .secondary.opacity(0.8))
            }
        }
    }

    private func detail(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(color)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    @ViewBuilder
    private var contextMenu: some View {
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
    }

    private func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
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
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundColor(.secondary)
                            .padding(.top, 6)
                            .help(group.name)
                        ForEach(group.sessions) { session in
                            SessionIndicator(activity: session.activity)
                                .frame(width: 30, height: 22)
                                .background(
                                    RoundedRectangle(cornerRadius: 5)
                                        .fill(session.attachedWindow == window.id ? Color.accentColor.opacity(0.25) : .clear))
                                .contentShape(Rectangle())
                                .onTapGesture { store.select(session.id, in: window.controller) }
                                .help(railTooltip(group: group, session: session))
                        }
                    }
                }
                .padding(.bottom, 12)
            }
        }
    }

    private func initials(_ name: String) -> String {
        String(name.filter { $0.isLetter || $0.isNumber }.prefix(2)).uppercased()
    }

    private func railTooltip(group: SessionGroup, session: SessionItem) -> String {
        var parts = [group.name]
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
