// ForeignSessionScanner.swift
//
// Read-only discovery of foreign coding-agent sessions (Claude Code, Codex).
//
// Rust reference (`~/Projects/grok-build` commit 650c1db7):
//
//   * `crates/codegen/xai-grok-workspace/src/foreign_sessions/mod.rs` —
//     top-level types, sort, dedup, and the enabled-source gate.
//   * `crates/codegen/xai-grok-workspace/src/foreign_sessions/claude.rs:30`
//     — Claude Code JSONL scanner.
//   * `crates/codegen/xai-grok-workspace/src/foreign_sessions/codex/mod.rs:18-50`
//     — Codex rollout/state-db scanner.
//
// This is deliberately read-only: no import, no writeback, no mutation of any
// foreign store. Attempting any of those is an explicit refusal (AGENTS.md §4).
//
// The scanners live in OpenGrokCLI rather than a new target to avoid
// Package.swift contention in wave-20.

import Foundation

// MARK: - Types

/// Which coding agent produced the foreign session.
///
/// Mirrors Rust's `ForeignSessionTool` enum. The raw values serve as stable
/// identifiers in JSON output and dedupe keys.
public enum ForeignSessionTool: String, Sendable, Equatable, Comparable, Hashable {
    case claude
    case codex

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// The specific client that created the session. A tool may have multiple
/// sources: Codex sessions can originate from the CLI, VS Code, Atlas, or
/// ChatGPT.
///
/// Mirrors Rust's `ForeignSessionSource`.
public enum ForeignSessionSource: String, Sendable, Equatable, Comparable, Hashable {
    case claudeCode = "claude_code"
    case codexCli = "codex_cli"
    case codexVsCode = "codex_vscode"
    case codexAtlas = "codex_atlas"
    case codexChatGpt = "codex_chatgpt"

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Human-readable badge for text output.
    public var badge: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codexCli: return "Codex CLI"
        case .codexVsCode: return "Codex VS Code"
        case .codexAtlas: return "Codex Atlas"
        case .codexChatGpt: return "Codex ChatGPT"
        }
    }
}

/// A normalized read-only summary of a foreign session.
///
/// Mirrors Rust's `ForeignSessionSummary`. Carries enough for the list view
/// and JSON output, but never the full transcript — that would require import,
/// which this slice explicitly refuses.
public struct ForeignSessionSummary: Sendable, Equatable {
    public var tool: ForeignSessionTool
    public var source: ForeignSessionSource
    public var nativeID: String
    public var title: String
    public var cwd: String
    public var updatedAt: Date
    public var branch: String?

    public init(
        tool: ForeignSessionTool,
        source: ForeignSessionSource,
        nativeID: String,
        title: String,
        cwd: String,
        updatedAt: Date,
        branch: String? = nil
    ) {
        self.tool = tool
        self.source = source
        self.nativeID = nativeID
        self.title = title
        self.cwd = cwd
        self.updatedAt = updatedAt
        self.branch = branch
    }
}

/// Which foreign sources to scan. Defaults to all-off so the feature is
/// opt-in, matching Rust's `EnabledForeignSessionSources`.
///
/// Cursor is intentionally absent: at pin `650c1db7` the Rust Cursor scan
/// path is a no-op (`scan_cursor = |_| Vec::new()`), so this port never
/// enables Cursor vendor I/O.
public struct EnabledForeignSources: Sendable, Equatable {
    public var claude: Bool
    public var codex: Bool

    public init(claude: Bool = false, codex: Bool = false) {
        self.claude = claude
        self.codex = codex
    }

    public static let all = EnabledForeignSources(claude: true, codex: true)
    public static let none = EnabledForeignSources()

    public var anyEnabled: Bool { claude || codex }
}

/// Resolved `[compat.*.sessions]` cells before the resume-skill gate.
///
/// Defaults ON, matching Rust `CompatConfig` session cells
/// (`xai-grok-tools/src/types/compat.rs`). Cursor is tracked for fail-closed
/// resolution parity but never opens a scanner (upstream Cursor scan is empty).
public struct ForeignSessionCompatSessions: Sendable, Equatable {
    public var claude: Bool
    public var codex: Bool
    public var cursor: Bool

    public init(claude: Bool = true, codex: Bool = true, cursor: Bool = true) {
        self.claude = claude
        self.codex = codex
        self.cursor = cursor
    }

    public static let all = ForeignSessionCompatSessions()
    public static let none = ForeignSessionCompatSessions(
        claude: false,
        codex: false,
        cursor: false
    )
}

/// Resume skills that authorize foreign-session filesystem I/O.
///
/// Mirrors Rust `ForeignPickerSource::skill_name`
/// (`xai-grok-pager/src/app/foreign_sessions.rs`). `resume-cursor` is listed
/// for path/parity tests but never enables a scan at this pin.
public enum ForeignSessionResumeSkill: String, Sendable, CaseIterable {
    case claude = "resume-claude"
    case codex = "resume-codex"
    case cursor = "resume-cursor"
}

/// Skill paths Rust probes before any vendor store I/O:
/// `$OPENGROK_HOME/bundled/skills/<skill>/SKILL.md` then
/// `$OPENGROK_HOME/skills/<skill>/SKILL.md`.
public func foreignSessionResumeSkillPaths(
    skill: ForeignSessionResumeSkill,
    openGrokHome: URL
) -> [URL] {
    [
        openGrokHome
            .appendingPathComponent("bundled", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent(skill.rawValue, isDirectory: true)
            .appendingPathComponent("SKILL.md"),
        openGrokHome
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent(skill.rawValue, isDirectory: true)
            .appendingPathComponent("SKILL.md"),
    ]
}

/// Pure source gate: `compat.<vendor>.sessions` AND a matching resume skill
/// file. Skill paths are not probed when the compat cell is off
/// (`async_gate_checks_compat_before_skill_metadata` at
/// `xai-grok-pager/src/app/foreign_sessions.rs`).
///
/// Cursor is omitted: the pin's Cursor scanner is a no-op, so neither skill
/// probes nor vendor I/O run for Cursor from this route.
public func gatedForeignSessionSources(
    compat: ForeignSessionCompatSessions,
    openGrokHome: URL,
    skillExists: (URL) -> Bool
) -> EnabledForeignSources {
    var enabled = EnabledForeignSources.none
    if compat.claude {
        let paths = foreignSessionResumeSkillPaths(skill: .claude, openGrokHome: openGrokHome)
        if paths.contains(where: skillExists) {
            enabled.claude = true
        }
    }
    if compat.codex {
        let paths = foreignSessionResumeSkillPaths(skill: .codex, openGrokHome: openGrokHome)
        if paths.contains(where: skillExists) {
            enabled.codex = true
        }
    }
    return enabled
}

// MARK: - Scanner protocol

/// Injectable scanner interface so tests can substitute fixtures without
/// touching the filesystem.
public protocol ForeignSessionScanning: Sendable {
    func scan(cwd: String, enabled: EnabledForeignSources) -> [ForeignSessionSummary]
}

// MARK: - Limits

/// Shared constants matching Rust's foreign_sessions/mod.rs.
public enum ForeignSessionLimits {
    public static let maxSessionsPerTool = 50
    public static let maxSessionAge: TimeInterval = 30 * 24 * 60 * 60
    public static let maxTitleChars = 200
    static let maxFutureSkew: TimeInterval = 5 * 60
}

// MARK: - Title normalization

/// Collapse whitespace and cap at `maxTitleChars`, appending "…" when
/// truncated. Matches Rust's `normalize_title`.
public func normalizeForeignTitle(_ value: String) -> String? {
    let normalized = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    guard !normalized.isEmpty else { return nil }
    if normalized.count <= ForeignSessionLimits.maxTitleChars {
        return normalized
    }
    let prefix = String(normalized.prefix(ForeignSessionLimits.maxTitleChars - 1))
    return prefix + "…"
}

// MARK: - Sort and dedup

/// Sort newest-first with stable tie-breaking, then dedup by native ID per
/// tool, capping at `maxSessionsPerTool`. Mirrors Rust's `finish_tool_scan`
/// and `sort_sessions`.
public func finishForeignToolScan(
    _ sessions: inout [ForeignSessionSummary]
) {
    sessions.sort { a, b in
        if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
        if a.tool != b.tool { return a.tool < b.tool }
        if a.nativeID != b.nativeID { return a.nativeID < b.nativeID }
        if a.source != b.source { return a.source < b.source }
        if a.title != b.title { return a.title < b.title }
        return a.cwd < b.cwd
    }
    var seen = Set<String>()
    sessions.removeAll { session in
        !seen.insert(session.nativeID).inserted
    }
    if sessions.count > ForeignSessionLimits.maxSessionsPerTool {
        sessions.removeSubrange(ForeignSessionLimits.maxSessionsPerTool...)
    }
}

// MARK: - Age check

/// Whether `date` is within `window` of `now`, allowing small future skew.
/// Mirrors Rust's `is_within`.
func isForeignSessionWithin(_ date: Date, now: Date, window: TimeInterval) -> Bool {
    let elapsed = now.timeIntervalSince(date)
    if elapsed >= 0 {
        return elapsed <= window
    }
    return -elapsed <= ForeignSessionLimits.maxFutureSkew
}
