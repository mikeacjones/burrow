import GhosttyKit

extension Ghostty.SurfaceView {
    /// The last `lines` lines of the terminal's active screen. Unlike the
    /// viewport, this is unaffected by the user scrolling back through history,
    /// so an agent's footer is still seen.
    func activeScreenTail(lines: Int = 20) -> String {
        guard let surface else { return "" }
        var text = ghostty_text_s()
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_ACTIVE, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_ACTIVE, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false)
        guard ghostty_surface_read_text(surface, selection, &text) else { return "" }
        defer { ghostty_surface_free_text(surface, &text) }
        let all = String(cString: text.text)
        return all.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
    }
}

extension Notification.Name {
    /// Posted (object: the SurfaceView) when a terminal requests a desktop
    /// notification (OSC 9 / OSC 777). Agents use this to ask for attention,
    /// e.g. Claude Code's "Claude needs your permission".
    static let burrowSurfaceDidNotify = Notification.Name("io.github.mikeacjones.burrow.surfaceDidNotify")
}
