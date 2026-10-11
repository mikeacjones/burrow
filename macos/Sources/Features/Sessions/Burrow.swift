import Foundation

/// Product-level settings for Burrow, this fork of Ghostty.
enum Burrow {
    /// User-facing application name.
    static let appName = "Burrow"

    /// Ghostty's Sparkle updater points at Ghostty's release feed, which would
    /// replace Burrow with upstream Ghostty, so updates are disabled.
    static let updatesEnabled = false
}
