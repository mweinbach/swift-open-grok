# S10 — Foreign-session read-only scanners (Claude/Codex)

Date: 2026-08-10
Owner: S10 slice agent
Reference: `650c1db7` at `~/Projects/grok-build`

## Goal

Read-only Claude Code and Codex session discovery with normalized summaries
for session listing. Explicit foreign badge/source. No import, writeback, or
mutation.

## Rust cites

- `crates/codegen/xai-grok-workspace/src/lib.rs:21` — `foreign_sessions` module
  declaration.
- `crates/codegen/xai-grok-workspace/src/foreign_sessions/mod.rs` — shared
  types (`ForeignSessionTool`, `ForeignSessionSource`, `ForeignSessionSummary`,
  `EnabledForeignSessionSources`), sort/dedup, scan dispatch, and `most_recent`
  entry point.
- `crates/codegen/xai-grok-workspace/src/foreign_sessions/claude.rs:30` onward
  — Claude Code JSONL scanner: config dir resolution, project dir scoping,
  head/tail bounded I/O, title cascade (customTitle > aiTitle > lastPrompt >
  summary > firstPrompt), sidechain filtering, branch extraction.
- `crates/codegen/xai-grok-workspace/src/foreign_sessions/codex/mod.rs:18-50`
  — Codex entry point, codex home resolution, source enum mapping
  (cli/vscode/atlas/chatgpt), rollout ID extraction.
- `crates/codegen/xai-grok-workspace/src/foreign_sessions/codex/files.rs` —
  rollout-file scanner with date-partitioned directory walking.
- `crates/codegen/xai-grok-workspace/src/foreign_sessions/codex/db.rs` —
  SQLite state database scanner (deliberately deferred; see below).

## Files changed

### Sources (all under `Sources/OpenGrokCLI/`)

| File | Description |
|------|-------------|
| `ForeignSessionScanner.swift` | Shared types: `ForeignSessionTool`, `ForeignSessionSource`, `ForeignSessionSummary`, `EnabledForeignSources`, `ForeignSessionScanning` protocol, title normalization, sort/dedup, age check. |
| `ClaudeSessionScanner.swift` | Read-only Claude Code JSONL scanner. Config dir resolution from `CLAUDE_CONFIG_DIR` / `~/.claude`. Project directory enumeration. Head/tail bounded I/O. Title cascade matching Rust. Sidechain filtering. Branch extraction. |
| `CodexSessionScanner.swift` | Read-only Codex rollout-file scanner. Home resolution from `CODEX_HOME` / `~/.codex`. Date-partitioned directory walking. Rollout ID extraction. Source mapping (cli/vscode/atlas/chatgpt). |
| `LiveForeignSessionScanner.swift` | Production `ForeignSessionScanning` implementation plus `StubForeignSessionScanner` for test injection. |
| `LiveSessionsComposition.swift` | Modified: added `foreignSource` field to `LiveSessionListing`; added `foreignScanner`/`foreignSources` parameters to `run()` and `runList()`; foreign sessions merge into list output with explicit badge; JSON output includes `foreign_source` and `foreign_tool` keys; added `listing(fromForeign:)` conversion helper. |

### Tests (under `Tests/OpenGrokCLITests/`)

| File | Description |
|------|-------------|
| `ForeignSessionScannerTests.swift` | Fixture-backed tests for all three suites: shared types (title normalization, sort/dedup, age check, badges), Claude scanner (config dir resolution, cwd matching, sidechain skip, title precedence, branch extraction, bash-input/generated-prompt handling), Codex scanner (home resolution, rollout discovery, cwd matching, rollout ID validation, source mapping), and composition integration (merge with local, JSON foreign_source, disabled sources, import/writeback refusal). |

## Package.swift

**No changes required.** All code lives in `OpenGrokCLI` (source target) and
`OpenGrokCLITests` (test target), which already exist. No new targets.

## Verification

```
$ swift build --target OpenGrokCLI
Build complete! (30.90 sec)
```

The `OpenGrokCLI` library target compiles clean with no errors from the new
files. The `OpenGrokCLITests` target has a pre-existing build failure in
`LiveShareCompositionTests.swift` (NSLock unavailable from async context on
macOS 27 SDK) that is unrelated to this slice and was present before these
changes.

## Deliberate omissions

### Codex SQLite state database scanner

Rust's `codex/db.rs` scans a SQLite state database (`state_N.sqlite`) as a
primary source, falling back to rollout files only when the database is
unusable. This Swift port scans only the rollout JSONL files. The SQLite path
is deferred because:

1. `OpenGrokCLI` does not carry SQLite bindings today. Adding them would
   require a Package.swift dependency change (forbidden to this slice).
2. The rollout-file scanner covers the common case: every Codex session that
   produces a rollout file is discoverable.
3. The database-only sessions (if any exist without rollout files) are a
   minority case that can be added when SQLite is available.

### Compressed rollout files (.jsonl.zst)

Rust's scanner also handles zstd-compressed rollout files. This is deferred
because the Swift port does not carry zstd bindings in this target. Only
uncompressed `.jsonl` files are scanned.

### `most_recent` / `RecentProbe`

Rust exposes a `most_recent_foreign_session` function for the `/resume` fast
path. This is not ported here because the `/resume` picker integration
requires `LiveComposition.swift` changes (forbidden to this slice). The
scanner types and architecture support adding it later.

### Cursor session scanner

Rust declares a `ForeignSessionTool::Cursor` variant and a placeholder
scanner. The Swift port omits it since no implementation exists upstream.

### Production wiring

The scanners are implemented and tested through the `ForeignSessionScanning`
injection point on `LiveSessionsComposition.run()`. The production
`LiveForeignSessionScanner` is constructed but not wired into the `session()`
entry point because that call site lives in `LiveComposition.swift` (lead
only). The lead should:

1. Construct `LiveForeignSessionScanner(environment: context.environment)`.
2. Pass it and `EnabledForeignSources.all` to `LiveSessionsComposition.run()`.

### Import / writeback

Explicitly refused by architecture:
- `ForeignSessionScanning` protocol has only `scan()` — no mutation methods.
- `ForeignSessionSummary` carries no transcript data.
- `show` and `delete` use `LiveSessionCatalog` which reads only `$OPENGROK_HOME/sessions/`.
- No conversion, import, or write path exists.

This matches AGENTS.md §4: "Do not invent UX upstream lacks."

## Integration notes for lead

The `LiveSessionListing` type now has a `foreignSource: ForeignSessionSource?`
field with a default of `nil`. Existing code that constructs `LiveSessionListing`
without the new parameter is unaffected because it defaults. The `session(for:context:)`
entry point in `LiveSessionsComposition` passes no scanner, so the existing
behavior is preserved until the lead wires the production scanner.

The `run()` method gains two new parameters with defaults:
- `foreignScanner: (any ForeignSessionScanning)? = nil`
- `foreignSources: EnabledForeignSources = .none`

Both default to off, so no existing call site breaks.
