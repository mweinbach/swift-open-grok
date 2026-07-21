// CLICommand.swift
//
// Parsed CLI command for the bootstrap surface. The full command/flag grammar
// is W10-S2; here we model only the bootstrap commands plus an `unknown`
// channel so dispatch is exhaustive and testable.

import Foundation

public enum CLICommand: Sendable, Equatable {
    case version
    case help
    case paths
    /// A recognized-but-not-yet-ported command (e.g. `sessions`, `login`).
    case notYetImplemented(String)
    /// An unrecognized command or flag.
    case unknown(String)
}

public enum CLICommandParser {
    /// Parse `args` (the arguments after the program name) into a command.
    public static func parse(_ args: [String]) -> CLICommand {
        guard let first = args.first else {
            return .help
        }
        switch first {
        case "--version", "version":
            return .version
        case "--help", "-h", "help":
            return .help
        case "paths", "path":
            return .paths
        // Known W10-S2 commands that are not yet ported. They are reported as
        // not-yet-implemented rather than unknown so the bootstrap CLI documents
        // the intended surface.
        case "inspect", "login", "logout", "mcp", "plugin", "memory", "models",
             "sessions", "setup", "share", "wrap", "export", "trace", "update",
             "completions", "worktree", "workspace", "dashboard", "agent":
            return .notYetImplemented(first)
        default:
            return .unknown(first)
        }
    }
}
