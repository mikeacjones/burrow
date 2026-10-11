import AppKit

/// Adds session sidebar commands to the View menu.
///
/// These are installed programmatically (rather than in MainMenu.xib) to keep
/// this fork's footprint on upstream files minimal.
@MainActor
final class SessionSidebarMenu: NSObject {
    static let shared = SessionSidebarMenu()

    func install() {
        guard let mainMenu = NSApp.mainMenu,
              let viewMenu = mainMenu.items.first(where: { $0.submenu?.title == "View" })?.submenu,
              !viewMenu.items.contains(where: { $0.target === self }) else { return }

        let items = [
            item("Toggle Session Sidebar", #selector(toggleSidebar(_:)), key: "s"),
            item("Next Session", #selector(nextSession(_:)), key: "]"),
            item("Previous Session", #selector(previousSession(_:)), key: "["),
        ]
        for (index, item) in items.enumerated() {
            viewMenu.insertItem(item, at: index)
        }
        viewMenu.insertItem(.separator(), at: items.count)
    }

    private func item(_ title: String, _ action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = [.control, .command]
        item.target = self
        return item
    }

    @objc private func toggleSidebar(_ sender: Any?) {
        SessionStore.shared.toggleCollapsed()
    }

    @objc private func nextSession(_ sender: Any?) {
        SessionStore.shared.selectAdjacent(offset: 1)
    }

    @objc private func previousSession(_ sender: Any?) {
        SessionStore.shared.selectAdjacent(offset: -1)
    }
}
