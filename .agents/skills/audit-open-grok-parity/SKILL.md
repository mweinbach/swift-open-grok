---
name: audit-open-grok-parity
description: "Audit and verify feature, security, protocol, and TUI parity between Rust open-grok (reference pin 650c1db7) and swift-open-grok. Use when evaluating what is live vs unwired vs absent, proving protocol compatibility, or finding behavioral gaps before/after porting waves."
---

# Audit Open Grok Parity

Instructions for performing systematic parity audits between the upstream Rust reference [`open-grok`](https://github.com/mweinbach/open-grok) (at pinned commit `650c1db7` or the location that houses the Rust repository) and the Swift port [`swift-open-grok`](https://github.com/mweinbach/swift-open-grok) (or the local directory that houses the Swift repository).

---

## 1. Golden Rule: Enumerate from Rust First

Auditing from the Swift port's perspective only reveals what someone set out to build; it cannot find what nobody claimed.

1. **Locate the reference repository**:
   - Reference source: [`github.com/mweinbach/open-grok`](https://github.com/mweinbach/open-grok) (or the location that houses the Rust repository, e.g. `../open-grok` or `../grok-build`).
   - Current reference pin: `650c1db7c2e73c59cec88bf3c6359751d6cef1bd` (recorded in [`PORT_STATUS.md`](PORT_STATUS.md)).
2. **Inspect Rust reference code directly**:
   ```sh
   # Show file at pinned commit
   git show 650c1db7:crates/codegen/<crate>/src/<file>.rs

   # Grep pattern across reference crates
   git grep -n "<pattern>" 650c1db7 -- crates/codegen/
   ```
3. **Map Rust crate to Swift target**:
   - Consult [`CRATE_MAP.md`](CRATE_MAP.md) and [`PORT_PLAN.md`](PORT_PLAN.md).

---

## 2. The Four Parity Classifications

Every audited feature must be classified using the standard ledger conventions:

| Classification | Meaning | Rule |
| --- | --- | --- |
| **LIVE** | Reachable from the running `open-grok` binary, TUI, or CLI. | Must be connected through `Sources/OpenGrokCLI` (`LiveComposition.swift` / `LiveInteractiveControllerRenderer.swift`). |
| **IMPLEMENTED-UNWIRED** | Implemented and unit-tested in a Swift target, but NOT wired into the CLI entry point. | Document as unwired; do NOT claim live. |
| **ABSENT** | Feature or flag does not exist in the Swift codebase. | Document as absent with reference Rust `file:line`. |
| **DIVERGED** | Deliberate behavioral or architectural divergence. | Must record the rationale and trade-offs in `PORT_STATUS.md`. |

---

## 3. Seven Audit Domains Checklist

### A. Session & Agent Runtime (`OpenGrokShell`, `OpenGrokSessionRuntime`)
- [ ] Turn loop execution, token streaming, and max turns handling (`--max-turns`).
- [ ] Subagent swarm coordinator, depth limit (`MAX_SUBAGENT_DEPTH = 1`), worktree isolation.
- [ ] Mid-turn interjection (`x.ai/interject`) buffer/drain seam.
- [ ] Memory flush/dream storage and search (`/dream`, `/remember`).
- [ ] Compaction lifecycle (`auto_compact_started` → checkpoint → `auto_compact_completed`).

### B. Tools & Execution (`OpenGrokToolRegistry`, `OpenGrokFileTools`, `OpenGrokExecutionTools`)
- [ ] Tool packs: default grok build, codex, flat-team mailboxes (`list_agents`, `send_message`, etc.).
- [ ] File edits: search/replace, apply_patch, hashline edits.
- [ ] Plan mode edit gate: editing restricted to `plan.md` only; non-edit tools pass through.
- [ ] Terminal execution: bash execution, output truncation caps, environment isolation.

### C. Workspace, Permissions & Sandbox (`OpenGrokWorkspace`, `OpenGrokSandbox`)
- [ ] **Fixed 7-Stage Gate Sequence**:
  1. Plan-mode edit gate
  2. PreToolUse hooks (fail-open, recorded)
  3. Plan-file auto-approval
  4. Permission evaluation (`deny > ask > allow`)
  5. Sandbox / resource lock validation
  6. Dispatch
  7. Durable history + explicit agent hunk attribution (`record_agent_write`).
- [ ] Folder trust and OS sandbox boundaries.

### D. TUI & Terminal Protocol (`OpenGrokPager`, `OpenGrokTerminalCore`)
- [ ] ANSI escape sequences & PTY CSI fragment filtering (`CsiFragmentFilter`).
- [ ] Mouse decoding: SGR 1006 and X10 modes, coordinate overflow guards (`>= 1_000_000`), wheel delta normalizer.
- [ ] Kitty Keyboard Protocol negotiation and decoding.
- [ ] Table rendering & cell/grid text selection, sticky header scrolling.
- [ ] Composer `PromptEditor` with single `OpenGrokTextArea` mutable buffer.
- [ ] FPS HUD (`GROK_FPS` / `/debug fps`).

### E. Multi-Provider & Auth Isolation (`OpenGrokSampler`, `OpenGrokAuth`)
- [ ] Independent credential stores: xAI (`auth.json`), Codex (`codex-auth.json`), Kimi, Fireworks, DeepSeek, Wafer, Z AI.
- [ ] Provider identity resolved from model metadata, never URLs or slug prefixes alone.
- [ ] Monotonic export boundary closing on non-xAI routes (`ever_used_codex`).

### F. ACP, MCP & Code Mode (`OpenGrokACPRuntime`, `OpenGrokCodeMode`)
- [ ] ACP reverse permissions (`session/request_permission`).
- [ ] MCP transport lifecycle and tool filtering.
- [ ] Persistent Code Mode runtime (JavaScriptCore) with per-cell timeline and nested tool dispatch.

### G. Config, CLI & Paths (`OpenGrokConfig`, `OpenGrokPaths`)
- [ ] `$OPENGROK_HOME` precedence over `~/.opengrok`.
- [ ] TOML config layers (`pager.toml`, `.opengrok/config.toml`).
- [ ] CLI flags: `--version`, `--json`, `paths`, `models`, `sessions list`.

---

## 4. Ledger Documentation Standard

When recording audit results in [`PORT_STATUS.md`](PORT_STATUS.md) or [`PARITY_ROADMAP.md`](PARITY_ROADMAP.md):

1. **Cite exact `file:line`** in both Rust reference and Swift codebase.
2. **Include dated verification evidence**:
   - Exit codes.
   - Swift Testing test and suite counts (e.g. `6,470 tests / 1,017 suites / 106 summaries, exit 0`).
   - Isolated CLI smoke proofs (`verify-open-grok` run id).
3. **Never claim CI green based solely on local macOS runs**.
