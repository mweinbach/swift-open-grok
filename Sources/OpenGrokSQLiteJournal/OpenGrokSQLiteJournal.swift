// OpenGrokSQLiteJournal.swift
//
// Open Grok — Swift port of `xai-sqlite-journal` plus an actor-isolated,
// schema-versioned record journal for session / worktree / managed-state
// consumers.
//
// Reference: crates/codegen/xai-sqlite-journal
//
// Invariants:
//   * WAL only on local filesystems; TRUNCATE on network mounts.
//   * Env kill-switch: OPENGROK_SQLITE_JOURNAL_MODE or GROK_SQLITE_JOURNAL_MODE.
//   * Per-host DB filenames under TRUNCATE so peers never share WAL -shm.
//   * Actor isolation; explicit transactions; deterministic migrations.
//   * System SQLite via `import SQLite3` (no third-party package).

import Foundation
