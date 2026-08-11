# Wave 20 — Deferred parity Batch 1 coordination

Date: 2026-08-10
Lead: coordinating agent (this chat)
Reference: `650c1db7c2e73c59cec88bf3c6359751d6cef1bd` at `/Users/mweinbach/Projects/open-grok` (read-only; use `git show`/`git grep` with that commit).

## Lead-only files (FORBIDDEN to slice agents)

- `Sources/OpenGrokCLI/LiveComposition.swift`
- `Sources/OpenGrokCLI/CLIRunner.swift`
- `Sources/OpenGrokCLI/LiveACPExtensionMethods.swift`
- `Package.swift`
- `PORT_STATUS.md`, `PARITY_ROADMAP.md`, `CRATE_MAP.md`

Hand back textual diffs / integration notes for those.

## Build rule

Slice agents: `zsh workflows/swift-safe-verify.zsh build --target <theirs>` only.
Lead owns `build-tests` and `test --no-parallel`.
No retry loops. Do not edit while another agent's verify run is in flight on shared files.

## Batch 1 slices

| ID | Owner focus | Primary paths |
|---|---|---|
| S1 | Share clients | **DONE** — `LiveShareHTTPClients` + `LiveShareRouteDependencies` wired through launcher; ACP `x.ai/share_session` still open |
| S2 | Model reconcile | **LEAD INTEGRATED** — pure helper + `applyReconciled` + post-refresh Task in makeAgentStack + credential-refresh sites |
| S3 | MCP preferences | **DONE** — toggle/toggle_tool + prefs store; connect-time `disabled_mcp_tools` filter wired at `MCPToolBridge.register` |
| S4 | Session info/state/close | **LEAD INTEGRATED** — `sessionInfoSnapshot` + latched `closeLive` at ACP composition site; comment updated in `LiveACPExtensionMethods` |
| S5 | TaskCompleted wake | **LEAD INTEGRATED** — wake sink on interjection/idle-prompt seam + bash poll watch; shutdown with monitor host |
| S6 | Computer Hub MCP | **LIBRARY + TESTS DONE** — `HubMCPBridgeCoordinator` live-seam proven; production connect deferred until an interactive session owns a hub MCP transport (leader `ComputerHubWorkspaceExposure` is the opposite direction and must not be overloaded) |

## Batch 1 exit

Lead integrates → `build-tests` → `test --no-parallel` with reported counts → then remaining Batch 2 (S7/S8/S10).

## Batch 2 (launched after Batch 1 close)

| ID | Focus | Status |
|---|---|---|
| S7 | search_tool / use_tool | **LEAD INTEGRATED** — meta-tools + live MCP search index + profile restore |
| S8 | Config authority spine | **LEAD INTEGRATED** — allowlist resolver wired through telemetry, workspace gate, share gate, privacy banner |
| S10 | Foreign-session scanners | **LEAD INTEGRATED** — `sessions list` uses `LiveForeignSessionScanner` + `.all`; SQLite/zstd/`most_recent` deferred |
| S9 | JSC module loader | DONE |
| S11 | Git OFS/REF delta | **DONE** — bounded OFS/REF delta resolution + 6 new tests; no lead wiring |
| S12 | XTVERSION | DONE + lead integrated |

## Also launched earlier (file-disjoint from Batch 1)

| ID | Focus | Primary paths |
|---|---|---|
| S9 | JSC module loader | **DONE** — loader + cache + cell engine wiring; no LiveComposition work |
| S11 | Git OFS/REF delta | `OpenGrokGitStatus/` |
| S12 | XTVERSION probe | **LEAD INTEGRATED** — `/doctor` folds `LiveXtversionCollector`; other TUI probes stay Unavailable |
| C1 | /usage docs + WorkflowHost retire | **DONE** — docs honest; legacy host retained with import-absence tests (`C1-cleanup.md`). Full delete blocked on `OpenGrokSessionRuntime`. |

## Batch 2 exit (2026-08-10)

Lead integrated S7/S8 follow-ups, wired share HTTP clients and MCP connect-time
disabled-tool filtering, fixed gate regressions, and re-ran the serial gate:
**5,786 tests / 105 summaries / exit 0 / zero issues** (2026-08-10).

Hub MCP production session connect remains deferred (S6 handoff).
ACP `x.ai/share_session` remains unwired (headless `open-grok share` is live).

## Deliberately NOT this wave (platform / architecture)

Linux sandbox proof · Windows named-pipe leader · Windows S2 exec · portable WSS · Linux custom-CA · CI evidence · voice · Antigravity · LSP · video · ACP SDK reverse bridge · durable subagent resume · relocation journal · auto-mode classifier · foreign writeback · PTY backend · V8 hard interrupt.
