# Parity Roadmap — remaining feature gap to full Rust parity

**Produced:** 2026-08-06, from a seven-domain read-only audit swarm against reference pin
`70002584da34e4c37ea14a3bce35341b7d04f9a7` (v0.1.220-open-grok.57), on the tree at the
Wave 12 green gate (4,195 tests / 602 suites, exit 0). Domains: session/agent runtime,
tool surface, pager UI, workspace/permissions/sandbox/hooks/plugins, auth/update/
distribution/announcements/voice, ACP/MCP/code-mode/workflow, config/CLI/settings/env.
Classifications follow the ledger convention: LIVE / IMPLEMENTED-UNWIRED / ABSENT /
DIVERGED, judged at the live seam (`Sources/OpenGrokCLI`), never at the library.

**Upstream drift note:** the reference clone already carries 2 commits past the pin
(`650c1db7…`: a reasoning hardening + the `.58` release). Fold that micro-delta into
whichever wave lands first.

**Wave 14 corrections (2026-08-07):** B3's "shared by in-pager `/login` … screen-mode
relaunch" was wrong: upstream `/login` never suspends (in-TUI OAuth/device code) and
screen-mode switch is a full-process exec relaunch (`screen_mode_relaunch.rs:222-247`).
B3's real consumers are `$PAGER` (landed, Wave 14) and `$EDITOR` (open). Wave 16 items
1 (question view + plan approval), 2 (plan tracker into `makeResources` — already landed
in Wave 13), and 5 (always-approve toggle, Wave 13; slash command, Wave 14) are done;
item 6's honest scope is send-now (landed) — true mid-turn injection needs the soft
`x.ai/interject` seam, which remains open.

---

## The shape of the gap

The port's foundations are in good health: the permission gate order is live end-to-end,
all three sampling backends stream with per-provider validation, compaction/memory/goals/
sessions/worktrees/plugins/update/sandbox(macOS) run on the live path, ACP stdio/serve/
leader work, Code Mode runs on JSC, and the Rhai workflow engine is live via `--workflow`.

What is missing clusters into five structural seams, not dozens of scattered features.
Every audit independently converged on the same first keystone:

1. **The subagent stack is built and dead.** `OpenGrokAgentCoordinator` (mailboxes,
   waiters, cancel), `OpenGrokSubagentResolution`, `OpenGrokAgentControlTools`,
   `OpenGrokAgentLifecycle`, and the `OpenGrokSessionRuntime` actor are implemented,
   tested — and constructed by nothing. In consequence the model is offered none of:
   `task`/`spawn_subagent`, `agent_swarm`, the collaboration quartet
   (`list_agents`/`send_message`/`followup_task`/`wait_agent`), team mailboxes, or the
   `workflow` model tool; `--no-subagents` has to be refused as unhonorable.
2. **The ACP extension surface is one method wide.** Only `x.ai/feedback` is routed;
   the entire `open-grok/*/models/apply` credential family, `x.ai/mcp/*`, session admin,
   btw/recap/share/interject, and inbound mode-change notifications are absent.
3. **MCP has no OAuth.** Config parses OAuth fields; no runtime, no
   `mcp_credentials.json`, no ACP SDK bridge — HTTP MCP servers requiring auth cannot work.
4. **The pager's blocked features share ten backings** (B1–B10 below); the largest are
   the multi-agent dashboard/AppView runtime and the native-scrollback/minimal stack.
5. **A wide "parses, nothing reads" belt** in config/settings/env/flags: ~30 Appearance
   settings rows persist with no renderer reader; a dozen CLI flags are accepted and
   ignored (against the port's own refusal pattern); most upstream `GROK_*` bool gates
   and `features.*` flags have no resolver; `RemoteSettings` decodes ~153 fields and
   applies a handful.

Deliberately recorded, not re-scoped here: telemetry dark-by-default, Linux/Windows
platform seams, share/export upload clients (scheduled Wave 17), Code Mode JSC-vs-V8.

---

## Wave plan (dependency-ordered)

### Wave 13 — Honesty batch + upstream micro-delta (mostly S/M)
The cheap wave that makes every later wave's claims trustworthy.
- **Startup `[ui]` hydration** (top config-audit gap): load effective `[ui]` TOML into
  the live renderer/controller before first paint (theme currently hard-defaults to
  grokNight at `LiveComposition.swift:~5473`; vim/appearance rows never load). Where a
  row's renderer does not exist yet (timeline, timestamps, compact_mode…), hide the row
  per the §4 house rule instead of letting it lie — B6 in Wave 18 un-hides them.
- **CLI flag honesty**: extend `unhonoredLaunchFlag` (LiveComposition.swift:1455-1505)
  over the accepted-and-ignored set: `--no-plan`, `--no-ask-user`, `--todo-gate`,
  `--compaction-mode/-detail`, `--hunk-tracker-mode`, `--storage-mode`,
  `--client-identifier`, `--installer`, `--terminal`, `--fs-read/-write`,
  `--no-auto-update`, `--force-login`, `--log-sampling`, `--no-wait-for-background`,
  `--background-wait-timeout`, `--chat`/`--local-workspace*`.
- **Small parity fixes**: marketplace update rollback (installer.rs:418+); stop
  advertising `memory_search`/`memory_get` when memory is disabled; align background
  tool advertised names to upstream renames (`get_command_or_subagent_output` family,
  `run_terminal_command`) or record permanent divergence; `todo_write` catalog kind.
- **Ledger corrections**: the stale rows every auditor tripped over — the 2026-08-04
  orphan table (Hooks/PluginMarketplace/ComputerHub/WorkspaceClient/Update/WebMedia/
  Memory/Goals now live), route-liveness snapshot (~L346), Wave-2 "queued prompts
  unimplemented" (~L1122), CRATE_MAP row 83 (Rhai landed inside `OpenGrokWorkflow`;
  no `OpenGrokWorkflowEngine` target needed — retire the legacy dual runtime in
  `OpenGrokWorkflow.swift` instead).
- **Re-pin micro-delta** to `650c1db7` (reasoning harden + `.58`) with the same
  fixture protocol as Wave 12.

### Wave 14 — Subagent keystone (XL; unlocks the most downstream)
Order within the wave is forced:
1. Construct `OpenGrokAgentCoordinator` in the live session stack; expose to the tool
   executor.
2. Shell child runner (`run_shell_child` parity: credentials, tool policy, MCP snapshot,
   compaction tiers) — mirror `LiveWorkflowChildAgent`.
3. `OpenGrokSubagentResolution` into spawn (persona/role/model overrides).
4. Register `task`/`spawn_subagent` gated by `subagents_enabled` + discovery
   (builder.rs:848-896); un-refuse `--no-subagents`.
5. `agent_swarm` + `ForegroundWaitKind.orchestration` honored in the queue/cancel path
   (today cancel always kills the cohort).
6. Collaboration quartet + mailboxes (`OpenGrokAgentControlTools`), locked to
   enablement per upstream `ad95b111`; nested-spawn strip rules.
7. Post-compaction subagent reminder; tasks-pane feed (consumed by Wave 18 B1).

### Wave 15 — ACP extension router + credential/MCP surface (XL)
1. Method-prefix extension router in `ACPRuntimeActor` replacing the single feedback
   handler (mirror acp_agent.rs:3794+ dispatch).
2. `open-grok/*/models/apply|refresh|clear|endpoint` family + **live-session credential
   rebind** (closes the recorded Wave 12 deferral: settings-key saves reach running
   sessions).
3. `x.ai/mcp/*` management methods + `sdk_call` reverse bridge + initialize meta
   advertisement.
4. **MCP OAuth** (oauth.rs/credentials.rs against already-parsed config fields) +
   `$OPENGROK_HOME/mcp_credentials.json`.
5. Inbound ext notifications (`yolo_mode_changed`, `swarm_mode_changed`,
   `permissions/reset`); outbound `session/prompt_complete`, MCP server notifications.
6. ACP session-admin parity (`x.ai/session/*`) or record the typed `session/*`
   divergence deliberately, dual-routing where peers need it.
7. Real `x.ai/btw` + `/btw` side-call semantics (one-shot sample, `btw_history.jsonl`,
   recap.rs:71-182) replacing the interject mapping.

### Wave 16 — Interaction gates + permission completions (L)
1. `ask_user_question` + `enter_plan_mode`/`exit_plan_mode` tools with subagent strip;
   pager `question_view`/`plan_approval_view` (B4).
2. Plan tracker into live `makeResources` (today the gate is live but unreachable —
   nothing calls `PlanModeTracker.enter`); `swarm_parent_auto_approve`.
3. Hook fire sites for the ~13 silent events (SessionStart, UserPromptSubmit,
   PostToolUse±Failure, PermissionDenied, StopFailure, Notification, Subagent*,
   Pre/PostCompact, SessionEnd) — the library dispatch already exists.
4. Prepare step 5: resource locks + sandbox capability inside `prepare` (or record the
   split and amend PORT_PLAN); hunk tracker into live `makeResources`.
5. Pager always-approve / permission-mode toggle bound to the live handle.
6. Mid-turn interjection (drain into the running turn as synthetic user item) — makes
   steer/Ctrl+Enter real instead of next-prompt-only.

### Wave 17 — Auth, distribution, announcements (L)
1. xAI browser OAuth / OIDC / device / external-auth in `LiveAuthComposition`
   (the OIDC/DeviceCode/ExternalAuth libraries are implemented-unwired); post-login
   managed-config sync (flow.rs:1027-1039).
2. B3 TUI suspend/restore host (park raw mode, run child, restore) — shared by
   in-pager `/login`, `$EDITOR` edit-prompt, `$PAGER` transcript, screen-mode relaunch.
3. In-pager `/login` provider picker (8 providers incl. Meta, login.rs:12-100).
4. Share signed-URL + backend clients; then CLI `export`/`trace` (recorded open items).
5. Launch/background auto-update check (`run_update_if_available`, respecting
   `--no-auto-update` once Wave 13 makes it honest).
6. Announcements: spawn refresh → cache → pager banner + hide/CTA (+`/announcements`).

### Wave 18 — Pager surfaces (XL)
1. **B1** multi-agent AppView/dashboard runtime (agent map, roster, peek/attach,
   leader bridge) → `/dashboard`, Ctrl+\, `/cd` + `SetWorkingDir`, tasks pane +
   Ctrl+G/`/tasks` (feeds from Wave 14), dashboard worktree dialog.
2. **B2** native scrollback (`xai-ratatui-inline` insert_before) + the full
   pager-minimal frontend (auth/welcome/commit/live/todo/overlay) → true `--minimal`,
   `/minimal`/`/fullscreen` via screen-mode relaunch (needs B3 from Wave 17).
3. **B6** chrome readers: timeline rail, per-block timestamps, compact_mode layout,
   context-bar hover widget (un-hide the Wave 13 rows).
4. **B9** config-agents/personas modal; release-notes viewer; privacy banner.

### Wave 19 — Long tail (parallelizable, mostly XL each)
Mouse block selection (click selects a transcript block; upstream's scrollback click
handling — the live pipeline is proven and pinned, Wave 14.1, only the feature is absent) ·
LSP tool (pull-diagnostics rewrite) · scheduler trio + `monitor` · video tools
(`image_to_video`/`reference_to_video`) · `search_tool`/`use_tool` MCP meta-discovery ·
voice live seam (B7: macOS capture + `__mic-capture` intercept + pipeline) · media
overlays (B10: kitty/iTerm images, mermaid, real `/gboom`) · foreign-session
scan/resume (Claude/Codex/Cursor) · auto-mode LLM permission classifier ·
memory embeddings + dream (`/dream`) · xAI `x_search` replay into Responses input ·
Code Mode V8 debt (hard interrupt, module loader) · Computer Hub MCP adapter wiring ·
PTY-backed `run_terminal_cmd` · local-workspace/chat env+flag family ·
`RemoteSettings` authority allowlist · env-gate table (`GROK_*` kill-switches) ·
`features.*` resolver consumed by tools/compaction/MCP watchers ·
relocation journal · antigravity runner.

---

## Standing rules for every wave

- Never register a command, tool, or settings row whose backing does not work
  end-to-end; hide or refuse honestly instead.
- Assert through the live seam; a coordinator constructed only by tests is the exact
  failure mode Waves 12's audits kept finding.
- Security-shaped changes (permission order, credential gating, replay) quote landed
  lines in reports and get regression tests ported from upstream.
- One agent owns the full build and suite per wave; slice agents build their targets
  only; green `test --no-parallel` with reported counts gates every merge; ledgers
  updated in the same wave that changes the truth.
