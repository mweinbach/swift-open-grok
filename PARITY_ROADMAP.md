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
B3's real consumers are `$PAGER` (landed, Wave 14) and `$EDITOR` (landed later). Wave 16 items
1 (question view + plan approval), 2 (plan tracker into `makeResources` — already landed
in Wave 13), and 5 (always-approve toggle, Wave 13; slash command, Wave 14) are done;
item 6 first landed as send-now and was later completed by E5's true mid-turn
`x.ai/interject` buffer/drain seam.

**Wave 20 update (2026-08-10):** Batch 2 closes the named deferred-audit buildable
slices: live `search_tool`/`use_tool`, remote-settings allowlist authority,
foreign-session listing, JSC module loader, git pack OFS/REF deltas, XTVERSION in
`/doctor`, MCP connect-time disabled-tool filtering, and production share HTTP
clients on the headless `open-grok share` route. Follow-on closes ACP
`x.ai/share_session`, CLI `--tools`/`--disallowed-tools`, child reasoning effort,
`SetPlanMode(Off)` / settings `plan_mode`, and allowlisted remote `session_recap`.
Follow-on batch 2 also lands JWKS id_token validation, `--max-turns`,
`page_flip_on_send`, and dream docs honesty. The deferred runtime wave then lands
auto-mode heuristic classification, hub MCP→harness session connect, `/dream`
consolidation, macOS `__mic-capture` voice + `/voice`, LSP `pull_diagnostics`,
and backend-gated `image_to_video`. Auto-mode LLM side-query and full LSP
post-edit sync landed 2026-08-11, followed the same day by `reference_to_video`,
the ACP reverse permission bridge (`session/request_permission`), a minimal
Antigravity runner, and the first non-red platform CI — macOS/Linux/Windows had
each failed on every push for three independent reasons, so every prior green
claim was macOS-local only.

**Local correctness wave (2026-08-11):** ACP reverse permission install is now
live-proven through `liveACPServices`; Hub MCP `closeCount` double-close flake
is fixed (`McpTransportCloseOnce`); same-process `resume_from` /
`resume_agent_ids` inherit source childCWD/worktree identity; foreign
`sessions list` gates Claude/Codex scans on effective config + resume skill
(`foreign_sessions.rs:281-365`). Prior same-day serial gate: **5,366** cases /
**926** suites / **74** nonempty summaries, exit 0 twice; no known remaining
local flakes from the recorded Rhai + Hub MCP pair. Still open at the live seam:
**Antigravity follow-ons**, durable cross-process subagent resume, relocation
journal, portable WSS/custom CA, Windows WinSock loopback / relaunch, and
**platform CI reliability** (no platform job green; macOS live-composition CI
stop remains). Details and quoted security install lines:
`PORT_STATUS.md` → Local correctness wave.

**Local TUI interaction wave (2026-08-11):** motion clock / finish-flash /
ordered delivery / welcome shimmer / suspend pause-restore; full X10
preservation; iTerm/WezTerm wheel 1/1 + modal wheel quarantine; transcript
left-click visible-block selection via last-painted hit geometry +
`focusScrollback`. Local serial gate that day (no platform CI rerun):
`build-tests` exit 0; focused TUI matrix **154 tests / 25 suites**; real PTY
filters **5 tests / 2 suites**; full `test --no-parallel` count-only
**5,423** cases / **932** suites / **74** nonempty summaries, elapsed
303.118s, exit 0. Details: `PORT_STATUS.md` → Local TUI interaction wave.

**Local remaining-TUI-gap follow-on (2026-08-12):** full Rust-style mouse
scroll stream normalizer (80ms stream, 16ms dedicated clock, residual/coast,
acceleration, remux/terminal profiles) + live `scroll_speed` / `scroll_mode` /
`scroll_lines` / `invert_scroll` readers (settings reset re-resolves project
layer); active background chip/motion via idempotent push cache (shell/monitor,
running non-workflow subagents, all scheduled, active workflows; atomic
scheduler provisional replacement; chip appears/spins/disappears and demand
parks); direct mouse scrollbar click/drag, safe same-cell transcript links,
composer focus/cursor via `PromptEditor` (block click remains; priorities/
modal/X10); macOS CoreGraphics refresh-rate probe → auto cadence (Linux honest
skip; Windows unsupported); `$OPENGROK_HOME/pager.toml` animation `fps` /
`wave_rows` live (`show_fps` HUD absent); mouse-reporting toggle gate
(env > effective ui > default false; command hidden/refused off; scrollback
Ctrl+R on; prompt inert; terminal-write rollback); Standard URL schemes only
`http`/`https`/`mailto` before LinkSpan / OSC8 / opener. Local serial gate
(**no platform CI rerun**): `build-tests` exit 0; comprehensive remaining-gap
filter **223 tests / 41 suites** (27/9 + 32/6 + 54/7 + 6/1 + 104/18);
background lifecycle+spinner **50 tests / 9 suites**; real PTY filters
**5 tests / 2 suites**; full `test --no-parallel` count-only **5,599** cases /
**965** suites / **74** nonempty summaries, elapsed 329.038s, exit 0;
verify-open-grok isolated CLI smoke `20260812-remaining-tui` (doctor/version
`.58`, sessions list empty exit0, help sessions exit0, cleanup
succeeded/artifacts retained). Contemporaneous “still absent” sticky-headers /
text-drag / native-hover notes are **superseded** by the sticky-header +
transcript text-selection follow-on below. Contemporaneous `show_fps` HUD
absent / mouse-off / composer-drag notes are **superseded** by the final TUI
divergence closure below. Do **not** keep background spinner,
scroll normalizer, composer focus/cursor, safe link click, scrollbar
click/drag, mouse-reporting toggle, or macOS display probe in current deferred
lists. Details + security quotes: `PORT_STATUS.md` → Local remaining-TUI-gap
follow-on.

**Local sticky-header + transcript text-selection follow-on (2026-08-12,
deep-tui):** sticky headers default-live when `!compact` (pinned user-prompt
collapse/push/clip/fade, reduced content band, sticky-aware mouse hits/gaps,
action-time PageUp/PageDown header recompute, compact old behavior,
scrollbar/timeline logical offsets; no settings toggle reader — default true
forced; cosmetic min-height/ellipsis/indexed-fade divergence may remain where
comments retain it); linear transcript text drag/multi-click (last-painted
selectable geometry, Unicode/offscreen reflow-safe OSC 52 copy, drag threshold,
chrome→text conversion, X10, URL/word double + line triple in `word_select`,
flash/hold/`word_select` live settings + legacy-key transaction/reset,
autoscroll dedicated clock/action-time reclamp, resize-safe frozen width,
Esc/new-down clear, suspend deadline); Appearance/Mouse `keep_text_selection`
live; link native/modifier gate aligned; timeline test interaction update is
**test-only proof**, not a product feature. Local serial gate (**no platform CI
rerun**): `build-tests` exit 0; expanded deep TUI filter **310 tests / 47
suites** (27/9 + 32/6 + 99/10 + 6/1 + 146/21); real PTY filters **5 tests / 2
suites**; full `test --no-parallel` count-only **5,682** cases / **970** suites
/ **74** nonempty summaries, elapsed 345.286s, exit 0; verify-open-grok
isolated CLI smoke `20260812-deep-tui` (doctor/version `.58`, sessions list
empty exit0, help sessions exit0, cleanup succeeded/artifacts retained).
Contemporaneous “still honest divergences” (table cell/grid→linear; sticky
header rows not text-drag selectable; composer `PromptEditor` drag/multi-click
/ `OpenGrokTextArea` not adopted; `sticky_headers` config/settings toggle;
FPS HUD/`show_fps` and mouse-off sticky hint/banner; Windows display probe)
are **superseded** by the final TUI divergence closure below. Do **not** keep
broad “sticky headers absent” or “text drag/multi-click absent” claims
current; do **not** keep `keep_text_selection` or the native-hover/Cmd-modifier
link gate in current deferred lists. Details: `PORT_STATUS.md` → Local
sticky-header + transcript text-selection follow-on.

**Local final TUI divergence closure (2026-08-12):** table box-grid selection
live (paint-text geometry detection; fail-closed linear on malformed/border-start;
cell/grid drag hysteresis; cell partial copy and TSV grid; triple cell / whole
table; keyed sidecar frozen; stale/reflow paint none; empty valid cell no linear
fallback; table-shaped assistant paint no soft-wrap). Sticky header text not
drag-selectable is **pin parity, not a divergence** (header band never publishes
selectable geometry). `$OPENGROK_HOME/pager.toml [scrollback.display].sticky_headers`
one-shot config live, default true, compact override; no env / no settings row is
**upstream parity, not a gap**; wrong-type parse diagnostic visible; project
`pager.toml` not authority. Composer `PromptEditor` uses one `OpenGrokTextArea`
as the sole mutable buffer (live click/drag/double word/triple line/wheel/
edge-autoscroll/selection highlight+OSC52; same wrap for paint/hit; UTF-8
internals at `Character` boundary; selection replacement; X10 up-none;
overlay/resize/suspend cancel; readline fallthrough with host policy intercept).
FPS HUD live via raw `GROK_FPS` nonempty `!= 0` and `/debug fps` (120 samples,
250ms cache, full frame layout+writer timing, 2×32 top-right);
`[animation].show_fps` remains parse-only because the pin also never reads it
(no settings row/motion gate); `/debug` only advertises `fps` because scroll/log
HUDs are absent. Mouse-off sticky toast live (successful off ⇒ focus-swapped
sticky `Ctrl+r…` scrollback / `/toggle…` prompt; transient wins; on clears +
`Mouse reporting on`; idle scroll-clock expiry; rollback/minimal; occluder);
invented transcript-note claim retired. Windows refresh probe remains
unsupported; Linux skip matches the pin. Local serial gate (**no platform CI
rerun**): `build-tests` exit 0; focused real `PagerPTYSessionTests` **exactly 3
tests in 1 suite**, 2.894s, exit 0; first full verbose serial exit 0, 367.631s
(terminal body truncated — do **not** use its partial count); authoritative
count-filtered second full `test --no-parallel` **6,470** cases / **1,017**
suites / **106** nonempty summaries (one summary is 10 tests in 0 suites),
elapsed 354.149s, exit 0; verify-open-grok isolated CLI smoke
`20260812-divergence-close` (doctor/version `.58` exit0; paths isolated `/tmp`
home; models json nonempty default `grok-4.5`; sessions fresh empty exit0; help
exit0; cleanup succeeded/artifacts retained — does **not** by itself prove
interactive TUI). Honest leftovers only (do not claim fixed): wrapped-fragment
table-cell parity (`OpenGrokMarkdown` still fits/truncates cells instead of
upstream wrapped cell fragments/`maxTableWidth` — synthetic/pure only);
composer prompt-widget extras (paste chips/image elements, `@` file-ref
search/view, predicted prompt/Ghostty extras; Ctrl-V internal clipboard and
prompt paging/per-family key-table divergences as applicable — do **not** claim
full prompt-widget parity); parse-only `[animation].show_fps`; narrower `/debug
fps` command surface; auth welcome raw-url mouse-disable/clear; Windows display
probe. Do **not** keep table cell/grid→linear, sticky-header-not-selectable as a
divergence, composer `PromptEditor`/`OpenGrokTextArea` adoption, `sticky_headers`
config/settings toggle as a gap, FPS HUD absent, or mouse-off sticky banner
absent in current deferred lists. Details: `PORT_STATUS.md` → Local final TUI
divergence closure.

**Wave 19 update (2026-08-10):** the deferred-dashboard batch is now landed rather
than standing. Retained dashboard sessions can dispatch prompts and replies; `/cd`,
typed `SetWorkingDir`, and the Ctrl+L location picker share one working-directory
path; Ctrl+R renames rows; completed or persisted subagents can be peeked and
attached; reply plus single/freeform question resolution are live; Ctrl+W launches
the worktree flow; Ctrl+/ owns dashboard search while literal `/` remains prompt
editing; and the leader publishes/consumes typed `x.ai/sessions/list` plus
`x.ai/sessions/changed` roster traffic. Running-subagent attach remains honestly
blocked until child sessions are durable/resumable, and dashboard multiselect
questions still require the attached session view. The pinned Rust layout is
vertical-only (`views/dashboard/layout.rs:223`), so the former "wide side peek"
deferral was an audit invention, not upstream work. The same wave also hardened MCP
OAuth credential recovery/revocation, recap over-budget trimming, Windows PATHEXT
lookup, packed-Git non-delta reads, docs lookup/extraction helpers, and the live
settings/profile honesty gates.

---

## Historical Wave 12 audit shape (superseded by later closures)

This section preserves the 2026-08-06 audit baseline. It is **not** the current
capability list: closure labels in the wave plan below and `PORT_STATUS.md` govern
current truth. At that baseline, the port's foundations were in good health: the
permission gate order was live end-to-end,
all three sampling backends stream with per-provider validation, compaction/memory/goals/
sessions/worktrees/plugins/update/sandbox(macOS) run on the live path, ACP stdio/serve/
leader work, Code Mode runs on JSC, and the Rhai workflow engine is live via `--workflow`.

The missing work then clustered into five structural seams, not dozens of scattered
features. Several of these keystones have since closed; the bullets remain as the
historical audit input that shaped Waves 13-18:

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
4. **MCP OAuth — CLOSED 2026-08-08; recovery/revoke hardened 2026-08-10**
   (`oauth.rs`/`credentials.rs`) + `$OPENGROK_HOME/mcp_credentials.json`.
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
1. **In-TUI xAI browser OAuth — CLOSED 2026-08-08.** External/devbox/device variants
   and post-login managed-config sync (`flow.rs:1027-1039`) remain separate work.
2. B3 TUI suspend/restore host (park raw mode, run child, restore) — shared by
   in-pager `/login`, `$EDITOR` edit-prompt, `$PAGER` transcript, screen-mode relaunch.
3. In-pager `/login` provider picker (8 providers incl. Meta, login.rs:12-100).
4. Share signed-URL + backend clients; then CLI `export`/`trace` (recorded open items).
5. Launch/background auto-update check (`run_update_if_available`, respecting
   `--no-auto-update` once Wave 13 makes it honest).
6. Announcements: spawn refresh → cache → pager banner + hide/CTA (+`/announcements`).

### Wave 18 — Pager surfaces (XL)
1. **B1 — CLOSED 2026-08-10** (dashboard roster and navigation are live in the
   pager): session/dormant roster, read-only selection-following peek, `Enter`
   attach through `/resume`, bare `x` close for eligible rows, `Ctrl+T` pin,
   `Shift+Up`/`Shift+Down` reorder, `Ctrl+G` grouping, `Ctrl+/` search/filter,
   section collapse/navigation, and the stepped `Esc` behavior. The historical
   AppView scope remains useful as a reference snapshot. Wave 19 closes the recorded
   follow-ons: retained-session dispatch/replies, `/cd`/`SetWorkingDir` plus Ctrl+L
   location selection, Ctrl+R rename, subagent peek and completed/persisted attach,
   reply plus single/freeform question handling, Ctrl+W worktree launch, Ctrl+/
   search, and the typed leader roster bridge. Running-subagent attach still refuses
   until a durable resumable child-session record exists, and multiselect dashboard
   questions stay in the attached session view. The pinned Rust dashboard is
   vertical-only, so "wide side peek" is retired as a stale audit assumption.
   Cleanup hardening exercises the real controller/renderer actor, stores, overlay
   stack, and terminal paint without overclaiming binary/PTY/raw-decoder proof.
2. **B2 — CLOSED 2026-08-10** (see the Wave 18 B2 ledger section: W1-W4 welcome,
   S1 screen_mode reader, N insertBefore, M1-M4 the live minimal frontend, S2
   `/minimal`//`/fullscreen` + exec relaunch; the B3 dependency turned out
   unnecessary — relaunch is a process exec, not the suspend seam). Recorded
   remainders: the minimal todo//btw//panel//plan//full_view//auth modules and the
   flat live-region stance. Ctrl+E expansion closed in the recorded B2 follow-up.
3. **B6 — CLOSED 2026-08-10** (timeline rail, per-block timestamps, compact-mode
   layout, and the context-bar hover widget are now live; unrelated settings
   that still lack renderer readers remain honestly hidden).
4. **B9 — CLOSED 2026-08-08** (config-agents/personas modal; release-notes viewer;
   privacy banner — the Wave 18 B9 ledger section).

### Wave 19 — Long tail (deferred batch landed; remaining work below)
Completed 2026-08-10: the B1 follow-ons described above; typed leader roster
snapshot/deltas and IPC fanout; settings/profile honesty for absent voice,
Antigravity, auto-permission, dream, LSP, video, and MCP meta-tools; MCP OAuth
credential-file recovery, live re-probe, and best-effort RFC 7009 revoke; deterministic
recap budget trimming; Windows PATHEXT resolution; pack-index-v2 lookup plus bounded
non-delta object inflate; and versioned atomic docs extraction/how-to lookup.

Platform/evidence tail: capable-Linux sandbox proof · Windows named-pipe leader IPC +
S2 exec emulation · portable secure WebSockets · Linux custom-CA installation · signed
share upload/export clients · post-change Linux/Windows CI and required-check evidence ·
B1 residuals: attach to a still-running subagent and dashboard-native multiselect
question resolution ·
Mouse long-tail (closed by Local TUI interaction wave + 2026-08-12 remaining-TUI-gap
follow-on + sticky-header/text-selection deep-tui + final TUI divergence
closure: scroll-stream normalizer/acceleration, live scroll settings,
background chip/spinner push, scrollbar click/drag, safe same-cell links,
composer focus/cursor, mouse-reporting toggle, macOS display probe, sticky
headers default-live when `!compact`, linear transcript text drag/multi-click
+ live `keep_text_selection`, native/modifier link gate, table box-grid
selection, `sticky_headers` one-shot `pager.toml` config, composer
`PromptEditor`/`OpenGrokTextArea` buffer, FPS HUD via `GROK_FPS`/`/debug fps`,
mouse-off sticky toast). Remaining: wrapped-fragment table-cell parity
(`OpenGrokMarkdown` fits/truncates vs upstream wrapped cell fragments/`maxTableWidth`
— synthetic/pure only); composer prompt-widget leftovers (paste chips/image
elements, `@` file-ref search/view, predicted prompt/Ghostty extras; Ctrl-V
internal clipboard; prompt paging/per-family key-table — do **not** claim full
prompt-widget parity); `[animation].show_fps` parse-only (pin also never reads
it; no settings row/motion gate); `/debug` advertises only `fps` (scroll/log
HUDs absent); auth welcome raw-url mouse-disable/clear; Windows display probe
(Linux skip matches pin) ·
video tools (`reference_to_video`) · `search_tool`/`use_tool` MCP meta-discovery ·
media overlays (B10: kitty/iTerm images, mermaid, real `/gboom`) · foreign-session
scan/resume (Claude/Codex/Cursor) ·
Code Mode V8 debt (hard interrupt, module loader) · Computer Hub MCP adapter wiring ·
PTY-backed `run_terminal_cmd` · local-workspace/chat env+flag family ·
`RemoteSettings` authority allowlist · env-gate table (`GROK_*` kill-switches) ·
`features.*` resolver consumed by tools/compaction/MCP watchers ·
relocation journal · antigravity runner · packed Git OFS_DELTA/REF_DELTA resolution ·
startup invocation of the landed docs extraction helper.

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
