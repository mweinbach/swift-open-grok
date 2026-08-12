// LiveForeignSessionScanner.swift
//
// Production `ForeignSessionScanning` implementation that delegates to the
// Claude and Codex scanners against the real filesystem.
//
// Rust reference (`~/Projects/grok-build` commit 650c1db7):
//   * `foreign_sessions/mod.rs` `scan_foreign_sessions` — gated dispatch to
//     per-tool scanners with cwd canonicalization and cross-tool sort.
//
// Compat + resume-skill gating happens *before* this type is called
// (`LiveSessionsComposition.resolveProductionForeignSources`). Callers must
// pass an `EnabledForeignSources` that is already skill-gated; this scanner
// only honors the per-tool bools and never performs vendor I/O for a disabled
// tool.
//
// This is the composition seam: tests inject a stub scanner, and the live
// binary gets this one. The scanner is intentionally synchronous — the Rust
// reference is synchronous too, and the bounded I/O keeps it fast.

import Foundation

/// Production scanner that reads Claude and Codex stores from the filesystem.
public struct LiveForeignSessionScanner: ForeignSessionScanning {
    private let environment: [String: String]

    public init(environment: [String: String] = [:]) {
        self.environment = environment
    }

    public func scan(
        cwd: String,
        enabled: EnabledForeignSources
    ) -> [ForeignSessionSummary] {
        guard enabled.claude || enabled.codex else { return [] }
        let now = Date()
        var sessions: [ForeignSessionSummary] = []
        if enabled.claude {
            sessions.append(contentsOf: ClaudeSessionScanner.scan(
                requestedCwd: cwd,
                now: now,
                environment: environment
            ))
        }
        if enabled.codex {
            sessions.append(contentsOf: CodexSessionScanner.scan(
                requestedCwd: cwd,
                now: now,
                environment: environment
            ))
        }
        sessions.sort { a, b in
            if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
            if a.tool != b.tool { return a.tool < b.tool }
            if a.nativeID != b.nativeID { return a.nativeID < b.nativeID }
            return a.source < b.source
        }
        return sessions
    }
}

/// A scanner that always returns a fixed set of summaries. Tests use this
/// to supply fixtures without touching the filesystem.
public struct StubForeignSessionScanner: ForeignSessionScanning {
    public var sessions: [ForeignSessionSummary]

    public init(sessions: [ForeignSessionSummary] = []) {
        self.sessions = sessions
    }

    public func scan(
        cwd: String,
        enabled: EnabledForeignSources
    ) -> [ForeignSessionSummary] {
        sessions.filter { session in
            switch session.tool {
            case .claude: return enabled.claude
            case .codex: return enabled.codex
            }
        }
    }
}
