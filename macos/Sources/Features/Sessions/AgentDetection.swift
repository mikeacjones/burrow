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

    static let catalog: [AgentKind] = [
        .init(id: "claude", displayName: "Claude",
              executables: ["claude"], pathHints: ["claude-code", "/claude/"],
              genericTitles: ["claude", "claude code"]),
        .init(id: "codex", displayName: "Codex",
              executables: ["codex"], pathHints: ["@openai/codex", "/codex/"],
              genericTitles: ["codex"]),
        .init(id: "cursor", displayName: "Cursor",
              executables: ["cursor-agent"], pathHints: ["cursor-agent"],
              genericTitles: ["cursor", "cursor agent", "cursor-agent"]),
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
        if let first = arguments.first, interpreters.contains(basename(first)) {
            candidates += arguments.dropFirst().prefix(2)
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

    /// True if the title starts with a braille spinner frame, which agents
    /// (Claude Code, Cursor, Gemini, …) animate in the title while working.
    static func hasSpinner(_ title: String) -> Bool {
        // Spinners can be two cells wide and start with the blank pattern
        // (U+2800, e.g. Cursor's "⠀⠞"), so require a non-blank cell in the
        // leading run of braille characters.
        let braille = title.unicodeScalars.prefix { (0x2800...0x28FF).contains($0.value) }
        return braille.contains { $0.value != 0x2800 }
    }

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
