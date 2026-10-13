import Foundation

/// A known CLI coding agent that can be detected as the foreground process of
/// a terminal session.
struct AgentKind: Equatable, Hashable {
    let id: String
    let displayName: String

    /// Executable basenames that identify this agent.
    let executables: Set<String>

    /// Substrings of argv entries that identify this agent when it runs under
    /// an interpreter (e.g. `node /…/@anthropic-ai/claude-code/cli.js`).
    let pathHints: [String]

    /// Titles the agent sets that carry no information beyond its own name.
    let genericTitles: Set<String>

    /// Shell command that continues the agent's most recent conversation in
    /// the current directory, if the agent supports it.
    var resumeCommand: String?

    static let catalog: [AgentKind] = [
        .init(id: "claude", displayName: "Claude",
              executables: ["claude"], pathHints: ["claude-code", "/claude/"],
              genericTitles: ["claude", "claude code"],
              resumeCommand: "claude --continue"),
        .init(id: "codex", displayName: "Codex",
              executables: ["codex"], pathHints: ["@openai/codex", "/codex/"],
              genericTitles: ["codex"],
              resumeCommand: "codex resume --last"),
        .init(id: "cursor", displayName: "Cursor",
              executables: ["cursor-agent"], pathHints: ["cursor-agent"],
              genericTitles: ["cursor", "cursor agent", "cursor-agent"],
              resumeCommand: "cursor-agent --continue"),
        .init(id: "gemini", displayName: "Gemini",
              executables: ["gemini"], pathHints: ["gemini-cli"],
              genericTitles: ["gemini", "gemini cli"]),
        .init(id: "aider", displayName: "Aider",
              executables: ["aider"], pathHints: ["/aider/", "aider-chat"],
              genericTitles: ["aider"]),
        .init(id: "opencode", displayName: "OpenCode",
              executables: ["opencode"], pathHints: ["opencode"],
              genericTitles: ["opencode"]),
        .init(id: "amp", displayName: "Amp",
              executables: ["amp"], pathHints: ["@sourcegraph/amp"],
              genericTitles: ["amp"]),
        .init(id: "copilot", displayName: "Copilot",
              executables: ["copilot"], pathHints: ["@github/copilot"],
              genericTitles: ["copilot", "github copilot"]),
        .init(id: "goose", displayName: "Goose",
              executables: ["goose"], pathHints: [],
              genericTitles: ["goose"]),
        .init(id: "crush", displayName: "Crush",
              executables: ["crush"], pathHints: [],
              genericTitles: ["crush"]),
        .init(id: "qwen", displayName: "Qwen",
              executables: ["qwen"], pathHints: ["qwen-code"],
              genericTitles: ["qwen", "qwen code"]),
        .init(id: "droid", displayName: "Droid",
              executables: ["droid"], pathHints: [],
              genericTitles: ["droid"]),
        .init(id: "antigravity", displayName: "Antigravity",
              executables: ["agy"], pathHints: [],
              genericTitles: ["antigravity", "agy"]),
    ]

    /// Identify an agent from a process's argv. Looks at the first few
    /// arguments so interpreter-launched agents (`node`, `bun`, `python -m`)
    /// are recognized too.
    static func detect(arguments: [String], processName: String?) -> AgentKind? {
        // Only argv[0] identifies the program, unless it is an interpreter, in
        // which case the script path follows (possibly after a flag like `-m`).
        var candidates = Array(arguments.prefix(1))
        if let first = arguments.first {
            // Launchers are often symlinks with generic names (Cursor's is
            // `~/.local/bin/agent` -> `.../cursor-agent/versions/.../cursor-agent`).
            if first.hasPrefix("/") {
                let resolved = URL(fileURLWithPath: first).resolvingSymlinksInPath().path
                if resolved != first { candidates.append(resolved) }
            }
            if interpreters.contains(basename(first)) {
                candidates += arguments.dropFirst().prefix(2)
            }
        }
        if let processName { candidates.append(processName) }

        for agent in catalog {
            for arg in candidates {
                if agent.executables.contains(basename(arg)) { return agent }
                if agent.pathHints.contains(where: { arg.contains($0) }) { return agent }
            }
        }
        return nil
    }

    private static let interpreters: Set<String> = [
        "node", "bun", "deno", "python", "python3", "ruby", "uv", "uvx", "npx",
    ]

    private static func basename(_ path: String) -> String {
        (path as NSString).lastPathComponent.lowercased()
    }
}

/// Activity state for a session, as shown by the sidebar indicator.
enum SessionActivity: Equatable {
    /// Plain shell prompt, nothing interesting running.
    case shell

    /// A non-agent foreground command (e.g. `npm test`, `vim`).
    case command(String)

    /// An agent is running and waiting for the user.
    case agentIdle

    /// An agent is actively working (thinking, streaming, running tools).
    case agentWorking

    /// An agent finished its turn but still has background work running
    /// (shells, monitors, subagents) that it will pick back up.
    case agentWaitingOnBackground

    /// An agent rang the bell or otherwise asked for attention.
    case agentNeedsInput

    /// An agent finished working while the session was in the background.
    case agentDone
}

enum ShellNames {
    static let all: Set<String> = [
        "zsh", "bash", "fish", "sh", "dash", "ksh", "tcsh", "csh",
        "nu", "elvish", "xonsh", "pwsh", "login",
    ]

    static func isShell(_ name: String) -> Bool {
        // Login shells show up as "-zsh".
        let trimmed = name.hasPrefix("-") ? String(name.dropFirst()) : name
        return all.contains((trimmed as NSString).lastPathComponent.lowercased())
    }
}

enum TerminalTitle {
    /// Leading glyphs agents use in titles to signal state (spinners, stars, dots).
    private static let statusGlyphs: Set<Character> = ["✳", "✶", "✻", "✽", "✢", "·", "*", "●", "○", "◐", "◓", "◑", "◒"]

    /// Strip leading status/spinner glyphs from a title.
    static func clean(_ title: String) -> String {
        var result = Substring(title)
        while let first = result.first,
              first.isWhitespace || statusGlyphs.contains(first)
                || first.unicodeScalars.allSatisfy({ (0x2800...0x28FF).contains($0.value) }) {
            result = result.dropFirst()
        }
        return String(result).trimmingCharacters(in: .whitespaces)
    }
}

/// Reads an agent's state from what it shows: the bottom of its screen and
/// its terminal title. Agents draw distinctive text while working ("esc to
/// interrupt") and when asking for approval (their prompt's option lines),
/// which is far more reliable than inferring state from CPU use.
///
/// Matching ignores case and whitespace so it is robust to how a TUI lays
/// out its text.
enum AgentStateDetector {
    /// Option lines and labels that only appear in an agent's approval prompt.
    /// These are specific on purpose: loose phrases like "do you want to"
    /// also match ordinary replies ("Do you want me to commit this?").
    static let needsInputScreenMarkers: [String] = [
        // Claude Code
        "yes, and always allow",
        "yes, and switch to auto mode",
        "yes, and don't ask again",
        "tell claude what to do differently",
        // Codex
        "yes, proceed (y)",
        "don't ask again for commands",
        "allow this exact command",
        // Cursor
        "run this command? not in allowlist",
        "run (once) (y)",
        "waiting for approval",
        "skip & tell the agent",
    ]

    /// Titles agents set while waiting on the user.
    static let needsInputTitleMarkers: [String] = [
        "action required",              // Codex
        "waiting for confirmation",     // Cursor
        "🔐",                           // Cursor
    ]

    /// Footer text agents show only while a turn is running.
    static let workingScreenMarkers: [String] = [
        "esc to interrupt",             // Claude Code, Codex
        "esc to cancel",                // Gemini
        "esc interrupt",                // OpenCode
        "ctrl+c to interrupt",
        "ctrl-c to interrupt",
        "ctrl+c to stop",               // Cursor
    ]

    /// Titles agents set while working.
    static let workingTitleMarkers: [String] = [
        "⏳ working",                   // Cursor
    ]

    /// Footer counts of background work, e.g. Claude Code's
    /// "3 shells, 1 monitor" or "2 background tasks".
    static let backgroundFooterPattern =
        #"(?i)\b\d+\s+(shells?|monitors?|bashes|background\s+tasks?|local\s+agents?)\b"#

    /// How many trailing non-empty lines count as the footer. Kept small so a
    /// transcript line like "3 shells still running" doesn't stick around
    /// after the work has finished.
    static let footerLineCount = 3

    static func hasBackgroundWork(screen: String) -> Bool {
        let footer = screen
            .split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .suffix(footerLineCount)
            .joined(separator: "\n")
        return footer.range(of: backgroundFooterPattern, options: .regularExpression) != nil
    }

    static func needsInput(screen: String, title: String) -> Bool {
        let screen = normalize(screen), title = normalize(title)
        return needsInputScreenMarkers.contains { screen.contains(normalize($0)) }
            || needsInputTitleMarkers.contains { title.contains(normalize($0)) }
    }

    static func working(screen: String, title: String) -> Bool {
        let screen = normalize(screen), title = normalize(title)
        return workingScreenMarkers.contains { screen.contains(normalize($0)) }
            || workingTitleMarkers.contains { title.contains(normalize($0)) }
    }

    /// Lowercased with all whitespace removed.
    static func normalize(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
    }
}
