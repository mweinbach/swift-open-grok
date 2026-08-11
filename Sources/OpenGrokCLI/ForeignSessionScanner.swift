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
public struct EnabledForeignSources: Sendable, Equatable {
    public var claude: Bool
    public var codex: Bool

    public init(claude: Bool = false, codex: Bool = false) {
        self.claude = claude
        self.codex = codex
    }

    public static let all = EnabledForeignSources(claude: true, codex: true)
    public static let none = EnabledForeignSources()
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
