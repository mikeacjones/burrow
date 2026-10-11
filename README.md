# Burrow

A macOS terminal for running many CLI coding agents across git worktrees.
Burrow is a fork of [Ghostty](https://github.com/ghostty-org/ghostty).

## What's different from Ghostty

- **Sessions instead of tabs.** Each window shows one session (a terminal or a
  tree of splits) and a collapsible sidebar on the left switches between them,
  like attaching to tmux sessions.
- **Grouped by repository.** Sessions are grouped under their git repository
  automatically. Linked worktrees group with their main checkout, and each row
  shows its branch (or detached commit) and worktree.
- **Agent status.** Claude, Codex, Cursor, Gemini, Aider, OpenCode, Amp, Copilot
  and others are detected in each session, showing whether they're working
  (with Cursor CLI's spinner), waiting for input, or finished in the background.
- **Closing a window detaches.** Sessions keep running after their window
  closes; click the Dock icon to reattach. Only quitting (⌘Q) terminates them.

## Shortcuts

| Shortcut | Action |
| --- | --- |
| ⌘T | New session |
| ⌘1–9, ⌃⌘] / ⌃⌘[ | Switch sessions |
| ⌘⌥W | Close session |
| ⌃⌘S | Collapse/expand the sidebar |
| ⌘W | Close the focused terminal |

Right-click a session in the sidebar to copy its path or branch, reveal it in
Finder, or close it.

## Building

Requires Xcode (with the Metal toolchain: `xcodebuild -downloadComponent MetalToolchain`)
and Zig 0.16 (`brew install zig@0.16`).

```sh
# Core library (only needed when Zig code changes)
/opt/homebrew/opt/zig@0.16/bin/zig build -Doptimize=ReleaseFast -Demit-macos-app=false

# App: build/ReleaseLocal/Burrow.app (or -configuration Debug)
cd macos
xcodebuild -project Ghostty.xcodeproj -scheme Ghostty -configuration ReleaseLocal SYMROOT=$PWD/build build
```

Burrow's code lives in `macos/Sources/Features/Sessions/`. Changes to upstream
files are marked with `ghostty-fork` comments to keep merging from Ghostty simple.
`SessionManager.isEnabled` switches back to Ghostty's native tabs.

Burrow reads the same configuration as Ghostty (`~/.config/ghostty/config`).
Auto-updates are disabled, since Ghostty's update feed would replace Burrow.

## License

MIT, as with Ghostty. See [LICENSE](LICENSE). Ghostty's original README is in
[README.ghostty.md](README.ghostty.md).
