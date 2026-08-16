# TUI / streaming / tool-card port backlog

**As of:** 2026-08-16
**Kind:** execution backlog (not a green-gate claim)  
**Reference pin:** `650c1db7c2e73c59cec88bf3c6359751d6cef1bd`  
**Rust clone:** `/Users/mweinbach/Projects/grok-build` (HEAD may be newer; enumerate from the pin first)  
**Produced from:** Rust-first audit of live streaming, tool-card paint, scrollback blocks, media, pager chrome, and the non-TUI Wave 19 tail.

The suite can stay green while the TUI stays lossy. The remaining work is not “more tools to implement.” It is that Rust’s typed stream and per-kind scrollback painters were collapsed into **text tokens + one generic tool card + start/end only**.

`PORT_STATUS.md` still markets many of these surfaces as live. Prefer this file + the cited source over that marketing language.

---

## How to use this file

- Work top-down. Do **not** start with mermaid, gboom, or credits.
- Enumerate from the Rust pin first. Cite `file:line`. Do not invent UX the pin lacks (no extra streaming cursor, no iTerm scrollback images, no auto-expand of failed edits).
- Assert through the live seam (`Sources/OpenGrokCLI`). A library type that nothing constructs is not done.
- Never `_ =` a status-returning fold/update.
- One owner per wave of the four shared files:
  - `Sources/OpenGrokCLI/LiveComposition.swift`
  - `Sources/OpenGrokCLI/LiveConversationStore.swift`
  - `Sources/OpenGrokCLI/LivePagerOutputs.swift`
  - `Sources/OpenGrokPagerRender/PagerFrameModel.swift`
- Painter slices may fan out only after Wave A lands the payload. They hand glue to the shared-file owner as text.
- Keep `appendToolCard` compiling between batches: add a dispatch arm the same day you add a kind.
- Do not update `PORT_STATUS.md` to “100% LIVE” for a painter that still uses `toolPreviewRows`.

### Status key

| Tag | Meaning |
| --- | --- |
| **TODO** | Not started |
| **LIVE** | Already reachable from the running binary — do not re-port |
| **UNWIRED** | Library exists; live path does not construct or consume it |
| **DIVERGED** | Exists but is lossy or wrong on screen |
| **ABSENT** | No Swift equivalent |
| **NOT A GAP** | Pin parity, or already closed |

---

## What is already live (do not re-port)

- Assistant **text** streams. The live loop uses `streamConversation`, not `conversationCollect` (`LiveComposition.swift:370-464`).
- Local tools emit a **running** card, then a **terminal** card, keyed by call ID (`LiveConversationStore.swift:1192-1225`, `LivePagerOutputs.swift:884`).
- Keyboard fold/expand, accent wave, and the 400 ms finish flash exist.
- The tools themselves mostly **execute**: read, edit, bash, web, memory, MCP `search_tool`/`use_tool`, image/video generation.
- Mermaid **library**, Kitty **encoder**, wrap-clipboard **library**, and `PagerDiff` **algorithm** exist — they are not wired through the live event/card model.
- Minimal native-scrollback mode, sticky headers, table **layout**, and most chrome (dashboard, settings, FPS HUD) are live.

The failure mode is the port’s usual one: **succeeds, does nothing, says nothing** — or worse, **succeeds and paints the wrong thing**.

---

## Why the TUI looks wrong

Three cuts in the live seam throw away most of what Rust paints.

### Cut 1 — the stream filter

`LiveComposition.swift` keeps only text tokens, `Completed`, and `Failed`. Reasoning, tool-argument deltas, retry, backend-hosted search, and typed failures fall through `default: continue`.

```447:461:Sources/OpenGrokCLI/LiveComposition.swift
            switch event {
            case .channelToken(_, .text, let text, _):
                ...
            case .completed(_, let response, _):
                ...
            case .failed(_, let error):
                throw CLIApplicationError.failed(error.message)
            default:
                continue
            }
```

### Cut 2 — the tool-update shape

`LiveConversationStore` emits one empty running event, waits for the whole invocation, then emits one flattened `promptText` string. Rust incrementally hydrates typed cards (command, path, hunks, HTTP metadata, search matches, stdout deltas).

```1194:1225:Sources/OpenGrokCLI/LiveConversationStore.swift
            await emit(.tool(OpenGrokShellToolUpdate(
                callID: call.callId,
                name: call.name,
                input: call.arguments,
                state: .running
            )))
            ...
                        content = result.promptText
                        await emit(.tool(OpenGrokShellToolUpdate(
                            ...
                            output: content,
                            state: .succeeded
                        )))
```

### Cut 3 — one painter

`appendToolCard` in `OpenGrokPagerRender.swift` paints every kind as a header + gray head/tail preview. Rust has separate painters for execute, read, edit, list, search, fetch, web/X search, memory, MCP search/use, hooks, and lifecycle.

### Cut 4 — restore fabricates success

On `/resume`, every restored tool is hard-coded `.succeeded`, and `.reasoning` / `.backendToolCall` / custom outputs are skipped.

```818:828:Sources/OpenGrokCLI/LivePagerOutputs.swift
                for call in assistant.toolCalls {
                    items.append(.tool(PagerToolCard(
                        name: call.name,
                        input: call.arguments,
                        output: resultsByCallID[call.id],
                        state: .succeeded
                    )))
                }
            case .system, .toolResult, .customToolOutput, .backendToolCall,
                 .reasoning:
                continue
```

---

## Suggested execution order

1. **A1 + A2 + A3** — events, restore, bash failure. Smallest visible honesty win.
2. **A4 + A5 + A6** — payload + live tail + fold preserve. Painters can start.
3. **B1 + B2** — execute + edit. Highest “tool cards look broken” payoff.
4. **D1 + D2 width** — thinking appears; tables stop clipping.
5. **C1–C3** then **C4–C7** — remaining cards stop looking like JSON.
6. **E7 + E8 + E2** — todo pane, honest `[stop]`, hooks.
7. **E3–E6, F1–F3** — transcript history + media.
8. **G** only when the TUI is no longer lying.

---

# Wave A — Live stream, honest restore, structured tool updates

**Goal:** The pager sees the same events Rust does. No more silent `default: continue`, no more “every resumed tool succeeded,” no more JSON-as-header.

**Unblocks:** every painter wave.

**Shared-file owner:** one agent for `LiveComposition.swift`, `LiveConversationStore.swift`, `LivePagerOutputs.swift`, `PagerFrameModel.swift`.

---

### A1. Forward non-text sampler events through the live turn

| | |
| --- | --- |
| **Status** | TODO (DIVERGED) |
| **Severity** | P0 |
| **Depends on** | — |

**What’s wrong:** `streamConversation` only handles text tokens, `.completed`, and `.failed`. Reasoning, tool-call fragments, retry, backend-tool start/end, and typed failures are dropped.

**Rust:** `xai-grok-shell/src/session/acp_session_impl/tool_calls.rs` maps `ChannelToken(reasoning)` → thought chunk, `ToolCallDelta` → tool-call delta, `Retrying` → retry state, `BackendTool*` → ACP tool cards. `scrollback/blocks/session_event.rs:208` paints typed auth/context/encrypted-history remedies.

**Change:**

- Widen `streamConversation` from `onTextDelta: (String)` to a typed live-event callback (or keep text and add a second sink).
- Add cases to `OpenGrokShellTurnUpdateKind` / `OpenGrokPagerEvent` for:
  - reasoning start / delta / end (with elapsed)
  - tool-call name/argument deltas (provisional card, keyed by request/tool index then call ID)
  - backend-tool start / update / end (web search, X search, code interpreter)
  - retrying (attempt, delay, reason)
  - typed failure (auth / context / rate-limit / encrypted-history), **not** a flattened string
- Consume them in `LiveConversationStore` → `LivePagerOutputs` / `LiveInteractiveControllerRenderer`.
- Do **not** persist partial tool-argument JSON. Rust does not either (`updates.rs:196`).
- Add Messages `ResponseStarted` / `ReasoningCompleted` on `Events.swift` if needed for thinking finalization (`Events.swift` currently has no equivalents of pin `events.rs:71`).

**Files:**

- `Sources/OpenGrokCLI/LiveComposition.swift`
- `Sources/OpenGrokShell/OpenGrokShell.swift`
- `Sources/OpenGrokPagerMinimal/OpenGrokPagerMinimal.swift`
- `Sources/OpenGrokCLI/LiveConversationStore.swift`
- `Sources/OpenGrokCLI/LivePagerOutputs.swift`
- `Sources/OpenGrokCLI/LiveInteractiveControllerRenderer.swift`
- `Sources/OpenGrokSampler/Events.swift`
- `Sources/OpenGrokSampler/StreamMessages.swift`

**Acceptance:**

- Synthetic stream: reasoning → tool-delta fragments → retry → backend web-search start/end → assistant text → completed.
- Assert ordered blocks appear **before** `.completed`.
- Auth/context `.failed` events keep their type; `Turn failed: …` is not the only signal.
- Partial JSON argument chunks update one card and never execute.

---

### A2. Persist and restore truthful tool outcomes

| | |
| --- | --- |
| **Status** | TODO (DIVERGED) |
| **Severity** | P0 |
| **Depends on** | — (can land with A1) |

**What’s wrong:** `/resume` hard-codes every card to `.succeeded` and skips reasoning / backend / custom output. `ToolResultItem` has no success/failure/cancelled field (`ConversationItem.swift:329`). Live turns already emit the right state; only restore lies.

**Rust:** `acp/tracker.rs:812-835`, `tracker.rs:1585-1587` preserve terminal status on replay.

**Change:**

- Add a UI/session sidecar (or optional outcome on the persisted result) for `.succeeded | .failed | .cancelled | .denied | .pending`. Do not invent a provider-wire field if that would corrupt exports.
- `seed(from:)` consumes that map.
- Project `.reasoning` and `.backendToolCall` / `.customToolOutput` through the **same** block builders as the live path.
- Skipping a standalone `.toolResult` row is fine **if** it is paired onto its call (`LivePagerOutputs.swift:771` already indexes them).

**Files:**

- `Sources/OpenGrokSamplingTypes/ConversationItem.swift` (or a session replay sidecar)
- `Sources/OpenGrokCLI/LiveConversationStore.swift`
- `Sources/OpenGrokCLI/LivePagerOutputs.swift`
- `Sources/OpenGrokCLI/LiveDashboardPeek.swift`

**Acceptance:**

- Persist succeeded / failed / denied / cancelled / unpaired.
- Resume: accents and states match the live turn.
- Reasoning → backend web search → assistant text survives in order.
- Custom-tool output is not dropped.

---

### A3. Classify nonzero terminal exits as failed

| | |
| --- | --- |
| **Status** | TODO (DIVERGED) |
| **Severity** | P0 |
| **Depends on** | — |

**What’s wrong:** `LiveToolExecutor` already has exit code, signal, timeout, truncation (~1689). If the process ran, the conversation store emits `.succeeded`. Failure is only text inside the output.

**Rust:** `xai-grok-tools/src/types/output.rs:727`; `tracker.rs:1606` — nonzero exit → failed execute card.

**Change:** Map `ShellCommandResult` exit/signal/timeout → `.failed` **before** the pager update. Keep the numeric detail (`exit code 7`) on the card.

**Files:**

- `Sources/OpenGrokCLI/LiveToolExecutor.swift`
- `Sources/OpenGrokCLI/LiveConversationStore.swift`

**Acceptance:** `exit 7` → `.failed`, error accent, visible exit detail. Signal-kill and timeout same. Exit 0 stays succeeded.

---

### A4. Structured tool payloads on the live event (stop flattening)

| | |
| --- | --- |
| **Status** | TODO (DIVERGED) |
| **Severity** | P0 |
| **Depends on** | A1 helpful, not required |
| **Note** | This is the payload contract every later painter consumes. |

**What’s wrong:** Running update is raw `call.arguments`. Success is `result.promptText`. Typed output from Read/List/Grep/Fetch/Search/Edit is discarded at the shell boundary. Kind is inferred from name alone (`PagerFrameModel.swift:112`). `glob` maps to List. `search_replace` / `run_terminal_cmd` often stay Generic. `LiveLeaderClient.swift:469` replaces a correct title with `"tool"` on sparse ACP updates.

**Rust:** `tracker.rs:1524-2046` factory uses kind, raw_input, raw_output, title, metadata, content, variant tags — not name alone. `tracker.rs:1524-1634` prefers `raw_input.command`, strips displayed `cd <session cwd> &&`. `tool/mod.rs:294-480` name fallback: `glob` is Search, `write` is Edit with `Creating`.

**Change:**

- Extend `OpenGrokShellToolUpdate` / `OpenGrokPagerToolUpdate` / `PagerToolCard` with:
  - typed kind (or factory input: name + raw JSON + variant tags)
  - parsed header fields (path, command, description, query, URL)
  - optional structured body (hunks, matches, citations, HTTP meta, media refs)
  - output-delta op: `replace` | `append` + truncation/gap/total-bytes
  - hook-run list (can be empty until E2)
  - `isExpanded` / fold mode preserved on upsert
- Factory (not `infer(fromToolNamed:)` alone):
  - `glob` → Search (today List)
  - `write` → Creating/Edit
  - `search_replace` / `strreplace` / `apply_patch` / `hashline_edit` → Edit
  - `run_terminal_cmd` / `run_terminal_command` / `bash` → Execute
  - `search_tool` → IntegrationSearch
  - `use_tool` → UseTool
  - `memory_search` → MemorySearch
  - `skill` → Skill
- Header formatting:
  - prefer `raw_input.command` / `description` over JSON
  - strip displayed `cd <session cwd> &&` only from the header (keep full command for copy)
  - elide process cwd from displayed paths
  - extract `file_path` / `filePath` / `target_file` / `path` / `url` / `query`

**Files:**

- `Sources/OpenGrokShell/OpenGrokShell.swift`
- `Sources/OpenGrokPagerMinimal/OpenGrokPagerMinimal.swift`
- `Sources/OpenGrokPagerRender/PagerFrameModel.swift`
- `Sources/OpenGrokCLI/LiveConversationStore.swift`
- `Sources/OpenGrokCLI/LivePagerOutputs.swift`
- `Sources/OpenGrokCLI/LiveLeaderClient.swift`

**Acceptance:**

- Live `search_replace` card kind is Edit; header is `Edit <path>`, not JSON.
- Live `run_terminal_cmd` is Execute; collapsed description-first; no raw JSON.
- `glob` → Search.
- Sparse leader update after an initial call keeps name/input.
- `apply` by call ID preserves `isExpanded`.

---

### A5. Incremental tool-output sink

| | |
| --- | --- |
| **Status** | TODO (DIVERGED / UNWIRED) |
| **Severity** | P0 |
| **Depends on** | A4 (delta op on the update type) |

**What’s wrong:** Executor awaits `process.run` and returns the whole blob. `ShellToolExecutionBridge` has no foreground progress stream. `ProcessRunner` has a PTY accumulator that never leaves the library (`OpenGrokExecutionTools.swift:628`). `RunTerminalCommandTool` advertises `bash_output_chunk` but is `BlockingTool`.

**Rust:** bash emits `output_delta` (`bash/mod.rs:1805`); tracker appends UTF-8 (`tracker.rs:1190`); execute painter shows a live tail (`execute.rs:20`).

**Change:**

- Add a call-ID-keyed output callback on the live terminal/tool path.
- `LiveConversationStore` emits append/replace updates **while** `.running`.
- `LivePagerOutputs.apply` merges into the existing card (A6 fold preservation).
- UTF-8-safe accumulation; support reset + gap + final drain (Rust `BashOutput`).

**Files:**

- `Sources/OpenGrokShell/ShellToolExecutionBridge.swift`
- `Sources/OpenGrokCLI/LiveToolExecutor.swift` (~1638–1689)
- `Sources/OpenGrokCLI/LiveConversationStore.swift`
- `Sources/OpenGrokShell/OpenGrokShell.swift`
- `Sources/OpenGrokCLI/LivePagerOutputs.swift`

**Acceptance:** Command prints `one`, sleeps, prints `two`. Same card shows `one` while still `.running`, then both lines on completion. Split multibyte UTF-8 across chunks does not corrupt.

---

### A6. Merge-in-place card updates (fold + timing)

| | |
| --- | --- |
| **Status** | TODO (DIVERGED) |
| **Severity** | P1 — do it in A; B/C will regress without it |
| **Depends on** | A4 |

**What’s wrong:** Every `apply` builds a new `PagerToolCard` with `isExpanded = false` and drops `detail`. Expanding a running card then receiving completion snaps it shut (`LivePagerOutputs.swift:884-912`).

**Rust:** `scrollback/state/mod.rs:1234` preserves pinned folds; `:1393` finish flash does not override a pinned fold.

**Change:** Upsert by call ID: keep fold mode, first `finishedAt`, kind/detail unless the update supplies new ones. Wave A may keep Boolean expansion; B/C add Truncated.

**Files:**

- `Sources/OpenGrokCLI/LivePagerOutputs.swift` (`apply(_:)`)

**Acceptance:** Expand running card → progress → success. Card stays expanded. First terminal `finishedAt` does not restart the 400 ms flash.

---

# Wave B — Execute and edit painters

**Depends on:** A3–A6.

---

### B1. Execute painter

| | |
| --- | --- |
| **Status** | LIVE (2026-08-15 — dedicated ANSI-aware painter and local user-bash fold lifecycle landed) |
| **Severity** | P0 |
| **Depends on** | A3, A4, A5, A6 |

**Rust:** `scrollback/blocks/tool/execute.rs` (header ~334, ANSI panel ~513, 2 head / 3 tail, fold ~723). Preview defaults in `appearance/config.rs:680`.

**Paint:**

- Collapsed: description if present, else command. Never raw JSON. Never `Run run_terminal_command`.
- Expanded: separately wrapped `$ command`, then ANSI-aware dark panel, 2+3 preview, `… +N lines`.
- Accents: running / success / error. Execute **keeps** a rail when collapsed (Read does not).
- Fold: agent calls collapsed ↔ truncated; user `!` streams truncated, finishes fully expanded.
- Copy: ANSI-stripped plain text (`execute.rs:122`).
- Do **not** auto-expand every agent command.

**Also:** `toolPreviewRows` today is this preview, applied to **every** tool (`OpenGrokPagerRender.swift:1281`). After B1 it is execute-only (or the execute body). Other kinds stop using it.

`ANSISegment.swift` already exists and is unused by the card painter.

**Files:**

- `Sources/OpenGrokPagerRender/OpenGrokPagerRender.swift` (dispatch + execute painter)
- `Sources/OpenGrokPagerRender/PagerFrameModel.swift` (execute payload)
- `Sources/OpenGrokTerminalCore/ANSISegment.swift` (wire it)
- `Sources/OpenGrokCLI/LiveScrollbackFocus.swift` (copy path)

**Acceptance:** Description-first collapsed; `$ command` after expand; SGR color + CR progress wrap correctly; clipboard has no escapes; exit 7 is error accent.

---

### B2. Edit / create painter + live structured diffs

| | |
| --- | --- |
| **Status** | LIVE (2026-08-15 — painter, multi-file structured payload bridge, highlighting, and adjacent-card stitching landed) |
| **Severity** | P0 |
| **Depends on** | A4, A6 |

**Rust:** `scrollback/blocks/tool/edit.rs` (hunks, `… N unchanged lines`, line-number gutters, insert/delete **backgrounds on wraps**, no on-screen `@@`/`+/-` columns). Copy is unified patch (`diff.rs:374`). Collapsed: trusted `+N/-N` or `(N edits)`. Write uses `Creating ` prefix. Failed stays collapsed. `commit_tests.rs:781` is `committed_edit_keeps_diff_line_backgrounds`.

**What’s wrong:** Edit tools return summaries, not old/new + regions. `PagerDiff.swift` is unused. `appendToolCard` is gray text. `search_replace` can infer as generic (`PagerFrameModel.swift:112` misses the live name).

**Change:**

1. Structured results from `SearchReplaceTool`, `ApplyPatchTool`, `WriteTool` (path, old/new or hunks, counts, trust).
2. `PagerDiff` builds the card body.
3. Dedicated painter: gutters, wrap-stable backgrounds, hunk separators.
4. `PagerMinimalCommitRender` must keep those backgrounds. Port `committed_edit_keeps_diff_line_backgrounds`.
5. Copy → `diffHunksToPatch`.
6. Classify live names: `search_replace`, `strreplace`, `apply_patch`, `hashline_edit`, `write`.

**Completed follow-ons:**

- `LiveEditHighlightWorker` performs bounded, latest-wins async file-scoped syntax highlighting after hunk-local rendering.
- Adjacent terminal same-file cards merge in place with `stitchOverlappingHunks`; multi-file cards remain independent.

**Files:**

- `Sources/OpenGrokFileTools/SearchReplaceTool.swift`
- `Sources/OpenGrokFileTools/ApplyPatchTool.swift`
- `Sources/OpenGrokFileTools/WriteTool.swift`
- `Sources/OpenGrokPagerRender/PagerFrameModel.swift`
- `Sources/OpenGrokPagerRender/PagerDiff.swift`
- `Sources/OpenGrokPagerRender/OpenGrokPagerRender.swift`
- `Sources/OpenGrokPagerRender/PagerMinimalCommitRender.swift`
- `Tests/OpenGrokPagerRenderTests/MinimalCommitRenderTests.swift`
- `Sources/OpenGrokCLI/LiveScrollbackFocus.swift`

**Acceptance:**

- Multi-hunk edit: gutters + insert/delete backgrounds on wrapped rows. **No** on-screen `@@`.
- Collapsed trusted `+1/-1`.
- `write` → `Creating <path>`.
- Committed buffer still has both background colors.
- Copy is a git-applicable patch.

**Honest non-gap:** Rust pin does not display literal `@@` hunk headers or `+/-` prefixes on screen. Those are copy-output only.

---

### B3. Double-click fold (execute/edit first, then all foldable cards)

| | |
| --- | --- |
| **Status** | LIVE (2026-08-15) |
| **Severity** | P1 |
| **Depends on** | A6; per-kind foldability from B1/C9 |

**Rust:** `app/agent_view/selection.rs:868` — single-click select, double-click fold, triple-click fold+scroll to top. Background-task double-click opens viewer.

**Swift:** click only selects; comment at `LiveInteractiveControllerRenderer.swift:3997` rejects double-click fold.

**Files:**

- `Sources/OpenGrokCLI/LiveInteractiveControllerRenderer.swift` (`completeScrollbackClick`)
- `Sources/OpenGrokCLI/LiveScrollbackFocus.swift` (`toggleFold`)

**Acceptance:** single = select; double = toggle fold; triple = toggle + scroll; non-foldable no-ops; later BgTask (E3) opens viewer.

---

# Wave C — Read, list, search, web, MCP, memory painters

**Depends on:** A4 structured payloads. Tools already produce most of the data.

After B1, **stop** routing these kinds through `toolPreviewRows`.

---

### C1. Read painter

| | |
| --- | --- |
| **Status** | LIVE — typed read payload + dedicated painter (2026-08-15) |
| **Severity** | P0 |
| **Depends on** | A4 |

**Rust:** `scrollback/blocks/tool/read.rs` — path surfaces (basename collapsed, cwd-relative expanded), `(11-20 of 200)`, `(empty)` / `(image)` / page count, dim line gutter, syntax/primary text, collapsed → truncated → collapsed. Empty reads not foldable. **No accent rail** on body.

**Swift:** `PagerWaveCToolPayload.swift` now preserves typed path/content/range/total data and `PagerWaveCToolRender.swift` paints the dedicated no-rail Read card.

**Files:** `PagerFrameModel.swift`, `LivePagerOutputs.swift`, `OpenGrokPagerRender.swift` (new Read painter), `ReadFileTool.swift` (keep; do not reimplement).

**Acceptance:** snapshots for range, empty, gutter separate from content, non-foldable empty.

---

### C2. List painter

| | |
| --- | --- |
| **Status** | LIVE — typed list payload + full-expand painter (2026-08-15) |
| **Severity** | P1 |
| **Depends on** | A4 |

**Rust:** `list_dir.rs` — colored/shortened path, `1 entry` / `N entries`, full expanded terminal-styled listing, errors not foldable.

**Swift:** `ListDirTool` now emits an honest visible-entry count, the pager retains the typed envelope, and the dedicated painter expands the full listing.

**Acceptance:** singular/plural count, full expand (not 2+3 truncate), error non-foldable.

---

### C3. Search painter + fix `glob`

| | |
| --- | --- |
| **Status** | LIVE — grouped grep/glob modes + dedicated painter (2026-08-15) |
| **Severity** | P0 |
| **Depends on** | A4 |

**Rust:** `search.rs` — quoted/colored pattern, glob/path spans, “N matches in M files”, mode metadata, grouped file sections, independent line-number column, `(no results)` still foldable. `tool/mod.rs:470` — `glob` is Search.

**Swift:** grep now emits grouped file/line records for Content, FilesWithMatches, and Count modes; glob emits typed file records and maps to Search.

**Acceptance:** zero results; 3 matches in 2 files; FilesWithMatches; Count; case-insensitive/multiline metadata; `glob` uses Search painter.

---

### C4. Web fetch painter

| | |
| --- | --- |
| **Status** | LIVE — metadata panel + URL-only selection (2026-08-15) |
| **Severity** | P1 |
| **Depends on** | A4 |

**Rust:** `web_fetch.rs` — `Fetch <url>`, status / content-type / bytes, 3-line truncated / 10-line expanded dark panel. One-shot (not streamed). Header selection is **URL only**.

**Swift:** `LiveWebTools.swift:444` already has URL/status/type/bytes; pager gets `promptText`.

**Honest non-gap:** lack of incremental fetch-body updates is pin-correct (`web_fetch.rs:209`).

**Acceptance:** collapsed header is only the URL; expanded 200 / markdown / 14.2 KB; 10-line marker; copy header copies URL only.

---

### C5. Web search + X search painter

| | |
| --- | --- |
| **Status** | LIVE — deduped web sites + distinct X Search card (2026-08-15) |
| **Severity** | P1 |
| **Depends on** | A1 (backend-hosted) + A4 |

**Rust:** `web_search.rs` — query header, deduped `(N sites)`, expanded ≤3 domains + `(+N more)`. X search label, no fake empty body. Tracker materializes backend actions at `tracker.rs:1717`.

**Swift:** web/X actions retain citation payloads, dedupe domains for the card, and keep X Search as a distinct header-only kind.

**Acceptance:** duplicate domains count once; 3 + overflow; X search titled `X Search`.

---

### C6. Memory search painter

| | |
| --- | --- |
| **Status** | LIVE — envelope parsed into numbered result rows (2026-08-15) |
| **Severity** | P1 |
| **Depends on** | A4 |

**Rust:** `memory_search.rs` — `Memory Search <query> (N results)`, numbered path/range/score/source, 3 snippet lines, honest `(no results)`.

**Swift:** `LiveMemoryComposition.swift`'s envelope is parsed at the pager boundary into numbered path/range/score/source rows and bounded snippets.

**Acceptance:** 0 / 1 / N result fixtures match pin headers and rows.

---

### C7. MCP `search_tool` / `use_tool` painters

| | |
| --- | --- |
| **Status** | LIVE — search/use payloads + dedicated MCP painters (2026-08-15) |
| **Severity** | P1 |
| **Depends on** | A4 |

**Rust:** `search_tool.rs` / `use_tool.rs` — `Search Tools <query> (N results)`; title-cased action + ghosted server; `use_tool` → `Server Action` + key/value args + 3/10 output.

**Swift:** both tools remain live; their raw/nested envelopes are parsed into dedicated Search Tools and Use Tool cards with semantic headers.

**Acceptance:** prefix-stripping tests; qualified and unqualified names; nested `tool_input`.

---

### C8. Generic Other leftovers

| | |
| --- | --- |
| **Status** | LIVE — label split, Q&A rows, and error fold policy (2026-08-15) |
| **Severity** | P1 |
| **Depends on** | A4 |

**Rust:** `other.rs` — `Label: content` split, AskUserQuestion numbered Q&A, media path + open button, error fold rules, elapsed time.

**Acceptance:** accepted / declined / plan-mode question results match pin rows.

**Scope note:** typed media path/open-button rendering remains Wave F1/F4; do not
duplicate that work here by scraping prose output. Rust's `started_at` /
`elapsed_ms` fields are shared timing state across every tool kind, not an
Other-only rendered acceptance surface; shared tool timing remains a separate
cross-wave parity follow-up.

---

### C9. Per-kind fold policy + rail policy

| | |
| --- | --- |
| **Status** | LIVE — per-kind folds/rails + verb-group headers (2026-08-15) |
| **Severity** | P1 / P2 |
| **Depends on** | B1, C1–C8 |

After painters exist:

- Read: collapsed ↔ truncated; empty not foldable.
- List/Search/Fetch: collapsed ↔ full; failed List not foldable; zero-result Search is.
- Generic: not foldable without foldable content.
- Rails: Read/List/Search **no** expanded rail (Rust); Execute yes.
- Verb-group headers aggregate eligible collapsed runs with running/past tense and first-appearance bucket order (`Reading 3 files`, `Read 1 file, Searched 1 pattern`).

**Files:** `PagerFrameModel.swift`, `LiveScrollbackFocus.swift` (`:315` currently marks every tool foldable), `OpenGrokPagerRender.swift`.

---

### C10. Header selection restricted to query/URL content

| | |
| --- | --- |
| **Status** | LIVE — semantic URL/query selection, including wraps (2026-08-15) |
| **Severity** | P2 |
| **Depends on** | C4–C7 |

**Rust:** fetch/search/memory header selection is the semantic URL or query only (`web_fetch.rs:140`, `web_search.rs:158`).

**Swift:** the Wave C header wrapper publishes only semantic URL/query spans, including exact concatenation across wrapped rows.

**Acceptance:** dragging/copying each fetch/search/memory/search-tool header returns only its URL/query, including wrapped headers.

---

# Wave D — Thinking + incremental markdown

**Depends on:** A1 reasoning events.

---

### D1. Live thinking block

| | |
| --- | --- |
| **Status** | LIVE (2026-08-15) |
| **Severity** | P0 (wiring) / P1 (markdown body) |
| **Depends on** | A1 |

**Rust:** `thinking.rs` + tracker pre-creates `Thinking…` when display is enabled (`tracker.rs:889`); live markdown; `Thought for …`; collapsed header-only; truncated last N styled lines; expanded full body; rail + bullet; completed auto-collapse unless sticky mode (`selection.rs:508`).

**Swift:** `appendThinking` exists (rail/bullet/3-line truncate at `OpenGrokPagerRender.swift:1047`) but takes **plaintext** and is never constructed. `Ctrl+E` can mutate reasoning messages (`LiveScrollbackFocus.swift:143`) but stores no sticky future mode. `OpenGrokShell.swift:161` and `OpenGrokPagerMinimal.swift:79` have no reasoning event.

**Change:**

- Build reasoning messages from A1 events.
- Same streaming styled-line pipeline as assistant.
- Persist `Ctrl+E` conversation-level mode for **future** blocks.
- Do **not** add a streaming cursor to thinking or assistant (see D3).

**Acceptance:** Interleaved reasoning + text → two blocks. Thinking streams, then collapses with elapsed. `Ctrl+E` expand-all; next completed thinking stays expanded.

---

### D2. Persistent streaming markdown + table width

| | |
| --- | --- |
| **Status** | LIVE (2026-08-15) |
| **Severity** | P0 (width) / P1 (checkpoints) |
| **Depends on** | — (width can land without A1) |

**What’s wrong:** Every ~50 ms batch reparses the **entire** answer (`LivePagerOutputs.swift:682`, `PagerMarkdownRendering.swift:24`). `StreamingMarkdownRenderer` exists (`OpenGrokMarkdown.swift:229`) and is unused. Tables render with no `maxTableWidth` (`OpenGrokMarkdown.swift:117` exists, live pager leaves it unset), then get clipped (`OpenGrokPagerRender.swift:971`).

**Rust:** `markdown_content.rs` + `streaming.rs` freeze stable prefixes; table-width change invalidates freeze (`streaming.rs:233`).

**Change:** Each active assistant/thinking block owns a `StreamingMarkdownRenderer`. `finish()` once. Pass content width; re-render on resize.

**Honest non-gap:** table **layout** (wrapped fragments, 11-glyph box, `maxTableWidth` engine) is already implemented. Only live width wiring and post-render clipping remain.

**Acceptance:** Chunked == one-shot for paragraphs, lists, fences, links, tables. Frozen prefix not recomputed. Six-column table at narrow width keeps both borders and wrapped cells.

---

### D3. Remove invented streaming cursor; keep timestamps

| | |
| --- | --- |
| **Status** | LIVE (2026-08-15) |
| **Severity** | P2 |
| **Depends on** | — |

Pin `agent.rs:165` has no cursor. Swift invents `▌` (`OpenGrokPagerRender.swift:954`) and the cursor steals the timestamp near the right edge (`:1023`).

**Acceptance:** Width-constrained streaming line still paints timestamp; no `▌`.

---

### D4. Fenced-code syntax + citation fences + line backgrounds

| | |
| --- | --- |
| **Status** | LIVE (2026-08-15) |
| **Severity** | P1 |
| **Depends on** | D2 helpful |

**Rust:** `syntax.rs:72` language highlighting; `syntax.rs:108` `10:20:path` citation fences. `markdown_content.rs:418` line backgrounds → `BlockLine`.

**Swift:** all fences are one yellow style (`MarkdownRenderEngine.swift:250`, `PagerMarkdownRendering.swift:56`). `MarkdownRenderLine` has no background (`OpenGrokMarkdown.swift:30`).

**Acceptance:** Swift/Rust fences highlight; `10:12:file.swift` resolves by path; fenced line background survives markdown → pager → `PaintLine`.

---

# Wave E — Non-tool transcript blocks + chrome

**Delivered on:** A1 typed transport via `PagerConversationItem.block` and the Wave E block model/render pipeline.

---

### E1. Session-event blocks

| | |
| --- | --- |
| **Status** | LIVE (2026-08-16 — typed variants + in-place recap) |
| **Severity** | P1 (typed failures are P0 via A1) |
| **Depends on** | A1 |

**Rust:** `session_event.rs` — turn failed (typed), compaction, retry/auth/context, hook annotations, model change, memory/goal, recap (one block, fill in place, `:421`).

**Swift:** `PagerSessionEventKind` covers every pinned event family; turn/runtime events create typed blocks, stop hooks attach to the event marker, and `/recap` upserts one stable block from pending to completed.

**Acceptance:** Every pin variant; recap updates the original item rather than appending a second one.

---

### E2. Hook + lifecycle cards

| | |
| --- | --- |
| **Status** | LIVE (2026-08-16 — typed lifecycle rows + hook sections) |
| **Severity** | P1 |
| **Depends on** | A4 hook-run field |

**Swift:** lifecycle and tool cards retain typed pre/post/stop runs, paint collapsed `[hooks: N/M]` suffixes, and expand into phase sections. Session-start lifecycle records are isolated from later tool/stop attachment.

**Rust:** `hook.rs` collapsed `[hooks: N/M]`; expanded pre/post sections; `lifecycle.rs` `session_start` / `user_prompt_submit` rows; stop hooks on the turn marker (`session_event.rs:302`). Attachment in `entry.rs:562` and `state/mod.rs:789`.

**Acceptance:** pre success + post failure → pinned suffix and sections. `session_start` cannot receive later tool hooks.

---

### E3. `BgTaskBlock`

| | |
| --- | --- |
| **Status** | LIVE (2026-08-16 — typed task lifecycle + live viewer) |
| **Severity** | P1 |
| **Depends on** | A1 item enum; B3 for double-click viewer |

**Rust:** `bg_task.rs` + `acp_handler/background.rs:74` — demote Execute → always-collapsed lifecycle row; started/completed/failed; viewer tails stdout by task ID (`block_viewer.rs:659`). **Does not** reuse the execute painter after backgrounding.

**Swift:** background/auto-background/monitor records upsert typed `PagerBackgroundTaskBlock` rows, terminal state and output tails update in place, the viewer polls live task output, and double-click opens it.

**Acceptance:** background / auto-background / success / fail / monitor; viewer tails; double-click opens viewer.

---

### E4. `SubagentBlock` + `SwarmBlock`

| | |
| --- | --- |
| **Status** | LIVE (2026-08-16 — typed activity cards + counters) |
| **Severity** | P1 |
| **Depends on** | A1 item enum |

**Rust:** `subagent.rs`, `swarm.rs` — typed lifecycle, member tree, turns/tools/duration/activity.

**Swift:** live host snapshots map to in-place subagent/swarm blocks with queued/running/waiting/terminal states, member trees, activity, outcome, turn/tool counters, and duration.

**Acceptance:** activity updates in place; completed/failed/cancelled accents; swarm member tree (queued/running/waiting/outcome, turns, tools, duration).

---

### E5. Workflow scrollback marker

| | |
| --- | --- |
| **Status** | LIVE (2026-08-16 — persistent typed workflow marker) |
| **Severity** | P1 |
| **Depends on** | A1 item enum |

**Swift:** workflow refreshes upsert a transcript marker containing objective, phase trail, agent count, state, and terminal outcome; closing `/workflows` no longer removes the durable record.

**Rust:** `workflow.rs` — objective, phase trail, agent count, outcome accent.

**Acceptance:** objective + phase trail + terminal outcome remain after the overlay closes.

---

### E6. Dedicated `/btw` block (and/or dismissible panel)

| | |
| --- | --- |
| **Status** | LIVE (2026-08-16 — one in-place foldable block) |
| **Severity** | P1 |
| **Depends on** | A1 item enum |

**Swift:** `/btw` creates one gold-accent typed block, performs the side call off-conversation, and fills that same block with the answer or failure copy without interleaving paired notes.

**Rust:** `btw.rs` (gold accent, foldable markdown) + `views/btw_overlay.rs` (dismissible panel).

**Acceptance:** one pending block (or one panel) filled in place; foldable; no interleave; Esc dismisses the panel variant.

---

### E7. Wire `LiveTodoStore` into a real pane

| | |
| --- | --- |
| **Status** | LIVE (2026-08-16 — fullscreen + minimal todo panes) |
| **Severity** | P1 |
| **Depends on** | — |

**Swift:** `LiveTodoStore` feeds ordered status-glyph rows in fullscreen and minimal layouts; completed filtering/toggle, the minimal eight-row cap, auto-hide, and force-show are wired.

**Rust:** `views/todo_pane.rs` + minimal `todo.rs` (8-row cap, auto-hide completed).

**Acceptance:** `todo_write` → live ordered rows; status glyphs; full-screen filtering/toggle; minimal cap + auto-hide + force-show.

---

### E8. Turn-status state machine

| | |
| --- | --- |
| **Status** | LIVE (2026-08-16 — typed phases + honest cancel affordance) |
| **Severity** | P0 for dishonest `[stop]`; P1 for the rest |
| **Depends on** | A1 retry/backend events |

**Rust:** `views/turn_status.rs:198-650` — thinking / responding / retrying / waiting / tools / cancel / compaction / bash; MCP startup; drain-blocked; parked watcher; `[stop]` only when cancel is real.

**Swift:** `LiveWaveETurnPhase` classifies thinking/responding/retrying/waiting/tools/compaction/bash and related status text; `[stop]` paints only when the active phase exposes a real fullscreen cancel action.

**Acceptance:** table-driven states; `[stop]` only with a valid cancel action; minimal keyboard-only has no cancel button.

---

### E9. Welcome / minimal auth

| | |
| --- | --- |
| **Status** | LIVE (2026-08-16 — welcome/minimal typed auth flow) |
| **Severity** | P1 |
| **Depends on** | — |

**Swift:** xAI and Codex login drive typed signing-in/trust/starting/failure states on welcome and minimal surfaces, preserve the exact URL, derive device codes, disable mouse capture for raw selection, and restore it on completion/failure.

**Rust:** `views/welcome/mod.rs:1022-1147` (device code, copy feedback, raw-URL mouse-disable); `pager-minimal/src/auth.rs`.

**Acceptance:** long URL copyable byte-for-byte; raw mode disables mouse; minimal signing-in → trust → starting.

---

### E10. Prompt-kind + quote-bar copy

| | |
| --- | --- |
| **Status** | LIVE (2026-08-16 — prompt kinds + copy-safe quote decoration) |
| **Severity** | P2 |
| **Depends on** | — |

**Swift:** standard/bash/cron/interjection/skill prompts retain distinct typed prefixes, and selection/copy strips decorative quote bars while preserving quoted content.

**Rust:** `user.rs` bash/cron/interjection/skill prefixes; `quote_bar.rs:144` excludes decorative bars from selection/copy.

**Acceptance:** bash / cron / skill / interjection prefixes; selecting `│ quoted` copies `quoted`.

---

### E11. `/context` categorical block

| | |
| --- | --- |
| **Status** | LIVE (2026-08-16 — categorical typed context block) |
| **Severity** | P1 |
| **Depends on** | A1 item enum (if it becomes a scrollback block) |

**Swift:** `/context` appends typed system/messages/reasoning/tool-definition/free rows with responsive 20-cell wide and 10-cell narrow bars, re-rendered through normal width/theme layout.

**Rust:** `context_info.rs:45` — system / messages / reasoning / free + tool-definition rows; 5×20 or 10×10 bars.

**Acceptance:** category totals; wide and narrow layouts; redraw after width/theme changes.

---

### E12. Credit bar + real `/usage`

| | |
| --- | --- |
| **Status** | LIVE (2026-08-16 — credit chrome + typed provider usage) |
| **Severity** | P1 |
| **Depends on** | billing client already in tree |

**Swift:** `PagerStatusBar` carries provider credit usage with 80% warning and 100% exhausted styling. `/usage` emits xAI/Codex/Antigravity sections from authoritative quota sources when present and explicitly marks only fallback estimates.

**Rust:** `credit_bar.rs:167-252`; `usage.rs` Codex / Antigravity / xAI sections.

**Acceptance:** credits used % + 80/100% warnings; xAI / Codex / Antigravity fixtures; no estimate marker when authoritative.

HEAD-only `usage_modal.rs` (tabbed modal at `92bece5d`) is **not** pin work.

---

### E13. Minimal remainders

| | |
| --- | --- |
| **Status** | LIVE (2026-08-16 — panels, plan commit/comments, ANSI transcript) |
| **Severity** | P1 |
| **Depends on** | B/C painters for full-view ANSI |

**Swift:** minimal mode paints `/resume` and `/mcps` below the prompt, commits approved plans once into native scrollback, preserves line-anchored comments, and `/transcript` uses expanded per-kind ANSI rendering rather than the plain final transcript.

---

### E14. Scroll-debug HUD + JSONL log

| | |
| --- | --- |
| **Status** | LIVE (2026-08-16 — HUD, aliases, env gates, JSONL) |
| **Severity** | P2 |
| **Depends on** | existing scroll normalizer |

**Swift:** `/debug [scroll|fps|log]`, `/scroll-debug`, `GROK_SCROLL_DEBUG`, and `GROK_SCROLL_LOG` drive the normalized scroll HUD and append JSONL diagnostics with raw/normalized deltas and viewport state.

**Honest non-gap:** `[animation].show_fps` remaining parse-only is pin parity; the pin also never reads it.

---

### E15. Credit-limit action card

| | |
| --- | --- |
| **Status** | LIVE (2026-08-16 — all actions + safe URL activation) |
| **Severity** | P1 |
| **Depends on** | A1 item enum |

**Rust:** `credit_limit.rs:18` — Enable PAYG / Increase PAYG Limit / Purchase Credits + clickable account URL.

**Swift:** typed credit-limit blocks cover Enable PAYG, Increase PAYG Limit, and Purchase Credits; account links activate only through the safe URL scheme gate.

**Acceptance:** all three action variants and safe URL activation.

---

# Wave F — Media, Mermaid, Gboom

**Depends on:** A4 media refs on cards; a post-flush compositor.

---

### F1. Typed image/video on tool cards

| | |
| --- | --- |
| **Status** | LIVE (2026-08-16) |
| **Severity** | P0 |
| **Depends on** | A4 media refs |

Typed image/video tool results now populate `PagerMediaRef` values on tool cards, while prose remains a separate rendered surface. Media rows reserve viewport geometry for the post-flush compositor.

**Rust:** `tracker.rs:1947` maps typed image/video output into media-bearing tool blocks; `other.rs:15` stores refs separately from prose.

**Acceptance:** fixture handlers produce media-bearing cards without parsing prose.

---

### F2. Kitty post-flush compositor

| | |
| --- | --- |
| **Status** | LIVE (2026-08-16) |
| **Severity** | P1 |
| **Depends on** | F1 |

`PagerInlineMediaCompositor` is called after terminal flush, transmits each Kitty image once, places visible media every frame, crops placements against the viewport, and clears images by ID. Scrollback composition remains disabled for iTerm2.

**Acceptance:** fake Kitty sink: transmit once, place per frame, crop on scroll, ID-specific clear. iTerm2 detection maps to `None`.

---

### F3. In-transcript Mermaid

| | |
| --- | --- |
| **Status** | LIVE (2026-08-16) |
| **Severity** | P1 |
| **Depends on** | D2 finish-time extraction; F2 for Open Image |

`OpenGrokPager` now imports `OpenGrokMermaid`. Closed Mermaid fences render as inline Unicode diagrams with one affordance row; `PagerMermaidWorker` caches completed renders and coalesces concurrent identical jobs. Streaming fences stay source-only until close.

**Rust pin is Unicode art inline** + Open Image / Copy Path / Copy Source (`mermaid_content.rs:125-262`). PNG is **not** inlined. Worker: `mermaid_worker.rs` (3 s timeout, cache, coalesced jobs) — ABSENT.

**Acceptance:** stream a fence in chunks; diagram only after close; one affordance row; concurrent identical requests render once.

---

### F4. Inline video poster / playback

| | |
| --- | --- |
| **Status** | LIVE (2026-08-16) |
| **Severity** | P1 |
| **Depends on** | F1, F2 |

**Rust:** `inline_media_ffmpeg.rs` + `prompt_images.rs:290` — `ffprobe`/`ffmpeg` poster, non-looping inline play, missing-binary hint.

**Swift:** `PagerInlineVideoDecoder` uses `ffprobe`/`ffmpeg` for a one-second poster and ordered 10 FPS frames. The compositor advances non-looping playback to the final frame and exposes the compact install hint when the binaries are absent.

**Acceptance:** fake ffmpeg yields a poster and ordered frames; playback stops on the last frame; missing binary produces a visible hint and path.

---

### F5. Wrap-clipboard OSC 999 on the live paste-miss path

| | |
| --- | --- |
| **Status** | LIVE (2026-08-16) |
| **Severity** | P2 |
| **Depends on** | — |

`LiveWrapClipboardPasteCoordinator` now owns the live paste-miss path: local clipboard text/image wins, a full miss emits one OSC 999 request, valid host frames create one image attachment, and malformed frames never leak into composer text.

**Honest non-gap:** this is composer attachments, not assistant transcript media. It cannot substitute for F1.

**Acceptance:** full miss emits OSC 999 once; local clipboard suppresses it; valid frame → one image chip; malformed frames never become text.

---

### F6. `/gboom`

| | |
| --- | --- |
| **Status** | LIVE (2026-08-16) |
| **Severity** | P1 for dispatch honesty; game itself P2 |
| **Depends on** | F2 |

The command remains hidden. Argument-bearing invocations use a dedicated pass-through queue kind so they reach the model without recursive slash-command replay. Bare `/gboom` opens an interactive raycast modal with keyboard/mouse controls, Kitty frame transmit/place/clear, and the pinned no-graphics notice.

**Acceptance:** command remains hidden; arguments pass through; bare command opens an interactive modal; fake Kitty sink receives and clears frames.

---

# Wave G — Non-TUI leftovers

Do **not** mix these into A–F. They are real, but they are not why the TUI looks broken.

| ID | Item | Status | Severity | Swift cite | Notes |
| --- | --- | --- | --- | --- | --- |
| G1 | Attach to a **still-running** subagent | DIVERGED | P2 | `LiveInteractiveControllerRenderer.swift:3357`, `LiveDashboardPeek.swift:199` | Completed/persisted attach is LIVE. Rust follows the in-memory child immediately (`dashboard.rs:367`). |
| G2 | Dashboard multi-select answering in the dashboard | **NOT A GAP** | — | `LiveInteractiveOverlays.swift:785` | Pin requires the attached session view (`peek.rs:289`). |
| G3 | Complete `GROK_*` session gate family | DIVERGED | P2 | `GrokEnvGates.swift:22` | Missing consumers include `GROK_TWO_PASS_COMPACTION`, `GROK_ASK_USER_QUESTION`, `GROK_WRITE_FILE`, `GROK_BACKEND_SEARCH`, `GROK_CANCEL_REWIND`, `GROK_MCP_LIVENESS_WATCHERS`, compaction mode/detail, telemetry trace upload. |
| G4 | `EffectiveFeatures` as live launch authority | DIVERGED | P2 | `EffectiveFeatures.swift:122`; only verified caller `LiveRecap.swift:580` | Other surfaces re-resolve independently. |
| G5 | Wire automatic worktree GC | UNWIRED | P2 | `GrokEnvGates.swift:158` | Accessors say wiring is pending. “Succeeds, does nothing.” |
| G6 | Code Mode hard interrupt | DIVERGED | P2 | `JavaScriptExecutionWatchdog.swift:31`, `JavaScriptCellRuntime.swift:114` | JSC 5 s ceiling; worker may continue. Rust `terminate_execution` is immediate. |
| G7 | Antigravity effort / resume / heartbeats / quota | DIVERGED | P2 | `LiveAntigravity.swift:10`, `:183`, `:238` | File explicitly lists these as absent. |
| G8 | Packed-Git OFS/REF on a live status path | UNWIRED | P2 | `OpenGrokGitStatus/ObjectStore.swift:296`; `Package.swift:371` | Algorithm exists; CLI does not import the target. |
| G9 | Linux custom CA + portable `wss://` | DIVERGED | P3 | `WebSocketClient.swift:264`, `OpenGrokHTTP.swift:810` | Extra CA parse is LIVE; Linux cannot apply it. WSS rejected off-Apple. |
| G10 | Windows named-pipe leader | ABSENT | P3 | `ACPLeaderSocket.swift:109` | Unix sockets only. |
| G11 | `--chat` / local-workspace flags | ABSENT | P3 | `CLICommand.swift:1659` | Parser rejects them. Feature-gated in Rust. |
| G12 | Platform CI green + Linux bwrap evidence | DIVERGED | P3 | `.github/workflows/ci.yml:14`; `PORT_STATUS.md:3` | Jobs and a real bwrap probe exist (`LiveSandboxComposition.swift:30`). No recorded green required job. |

### Wave G honest non-gaps

- Share upload/export clients are LIVE (`LiveShareComposition.swift:202`, `LiveComposition.swift:929`).
- Computer Hub MCP session bridging is LIVE (`ComputerHubWorkspaceExposure.swift:101`).
- Video **generation** (including `reference_to_video`) is LIVE under the production gate (`LiveVideoComposition.swift:119`). Presentation is F1/F4.
- “PTY-backed `run_terminal_cmd`” is an audit invention at this pin. Rust uses null stdin and pipes (`terminal.rs:688`); Swift `usePTY: false` matches.
- RemoteSettings allowlist is LIVE and fail-closed (`RemoteSettingsAllowlist.swift:32`). Missing feature authority is G4, not the allowlist.

---

## House rules while we do this

1. Enumerate from Rust pin `650c1db7` first. Cite `file:line`. Do not invent UX.
2. Assert through the live seam. A `PagerDiff` unit test is not a card on screen.
3. Never `_ =` a status-returning fold/update.
4. One owner of the four shared files per wave. Painter slices hand glue text to that owner.
5. Keep `appendToolCard` compiling between batches: add a dispatch arm the same day you add a kind.
6. Do not update `PORT_STATUS.md` to “100% LIVE” for a painter that still uses `toolPreviewRows`.
7. Tick items here when they land. Record dated test counts on the ledger, not in this file’s status table.

---

## Tick list (start state)

### Wave A
- [x] A1 Forward non-text sampler events (landed 2026-08-14; pager exhaustiveness glue by lead)
- [x] A2 Honest restore of tool outcomes (`ToolCallOutcomeMap` sidecar + seed/peek; save/load proven 2026-08-15)
- [x] A3 Nonzero bash exits are failed (`displayState` on success result)
- [x] A4 Structured tool payloads + factory (`PagerToolCard.make`; painters still generic)
- [x] A5 Incremental tool-output sink (protocol + live `onOutput` append; POSIX `read(2)` chunks 2026-08-15)
- [x] A6 Merge-in-place fold/timing

Wave A is **transport**, not painters. Execute/edit now use dedicated Wave B painters; read remains on the generic path until Wave C.

TerminalCore startup glue (2026-08-15, live): DA2 after raw mode + Kitty flag push; XTVERSION fire-and-forget write after `PlatformTerminalInput` is armed; DCS reply swallowed on the TTY byte path; `TerminalCapabilities` delegates to pin `KittyGraphics` (iTerm2 scrollback stays off).

### Wave B
- Completed 2026-08-15: execute and edit/create painters, ANSI SGR/CR rendering, local streaming `!` commands with the pinned fold lifecycle, multi-file structured edit payloads, committed wrap-stable diff backgrounds, patch/ANSI copy behavior, bounded latest-wins syntax highlighting, adjacent same-file card stitching, and click-count fold interaction all have focused regression coverage.
- Validation: `build-tests` and focused Wave B serial tests pass. The authoritative full serial run reaches all Wave B coverage but remains red only in the unrelated pre-existing `OpenGrokModelsTests.cancellationAbortsRefresh` expectation at `OpenGrokModelsTests.swift:914` (`CancellationError`).
- [x] B1 Execute painter
- [x] B2 Edit/create painter + committed backgrounds
- [x] B2-follow-on Highlight worker + same-file stitch
- [x] B3 Double-click fold

### Wave C
- Completed 2026-08-15: structured Read/List/Search/Fetch/Web/X/Memory/MCP payloads, dedicated painters, generic `Label: content` + AskUserQuestion rows, per-kind fold/rail rules, default-on verb-group headers, semantic header selection, and legacy-unstructured fallback for minimal full-output reprints.
- Validation: `build-tests`; focused Wave C serial tests pass (14 render, 5 live, 3 file-tool); focused Wave B regressions pass; the authoritative full serial run reaches all Wave C/minimal coverage and remains red only in the unrelated pre-existing `OpenGrokModelsTests.cancellationAbortsRefresh` expectation at `OpenGrokModelsTests.swift:914` (`CancellationError`).
- Scope: typed image/video path + open-button rendering remains Wave F1/F4; shared all-tool elapsed timing remains a separate cross-wave parity follow-up.
- [x] C1 Read painter
- [x] C2 List painter
- [x] C3 Search painter + `glob` → Search
- [x] C4 Web fetch painter
- [x] C5 Web/X search painter
- [x] C6 Memory search painter
- [x] C7 MCP `search_tool` / `use_tool` painters
- [x] C8 Generic Other accepted surface (Q&A/header/fold; media stays Wave F)
- [x] C9 Per-kind fold + rail policy
- [x] C10 Header selection = URL/query only

### Wave D
- Completed 2026-08-15: reasoning and assistant blocks own persistent streaming markdown renderers; stable prefixes reparse only the tail; `finish()` performs the pinned authoritative full render once; live content width invalidates and reflows tables; completed thinking records elapsed time, collapses by default, and honors sticky future `Ctrl+E` expansion.
- Presentation parity: assistant/thinking streams have no invented `▌`, timestamps remain available, Swift/Rust and `10:12:path.swift` citation fences receive semantic syntax spans, and code-line backgrounds survive markdown → pager → `PaintLine`.
- Validation: `build-tests`; focused Wave A–D, markdown (33 tests), performance, pager-render (800 tests), and fuzzing tests pass. The authoritative serial gate reaches all Wave D coverage and remains red in the pre-existing `OpenGrokModelsTests.cancellationAbortsRefresh` `CancellationError` plus an unrelated dashboard orchestration timing failure that passes its isolated 12-test suite.
- [x] D1 Live thinking block + sticky Ctrl+E
- [x] D2 Streaming markdown + table width
- [x] D3 Remove invented cursor
- [x] D4 Syntax / citation fences / line backgrounds

### Wave E
- Completed 2026-08-16: typed session/lifecycle/background/subagent/swarm/workflow/BTW/context/usage/credit blocks now update through the live renderer; recap and side-call records fill in place; todo, turn-state, auth, prompt-kind, minimal-panel, plan-comment, ANSI transcript, and scroll-debug chrome are wired.
- Presentation parity: provider credit thresholds, safe action links, live task viewers, subagent turn/tool counters, categorical context bars, raw selectable auth URLs, quote-copy stripping, honest `[stop]`, minimal eight-row todos, and expanded per-kind transcript output all have focused render and live-seam coverage.
- Validation: `build-tests`; 30 focused Wave E tests across four suites; the formerly affected auth/recap/usage/debug/mouse/table/executable suites; and all 814 pager-render tests pass. The authoritative serial gate reaches all Wave E coverage and is red only in the pre-existing `OpenGrokModelsTests.cancellationAbortsRefresh` unexpected `CancellationError()` at `OpenGrokModelsTests.swift:914`.
- [x] E1 Session-event blocks + in-place recap
- [x] E2 Hook + lifecycle cards
- [x] E3 BgTaskBlock + live viewer
- [x] E4 SubagentBlock + SwarmBlock
- [x] E5 Workflow scrollback marker
- [x] E6 `/btw` block or dismissible panel
- [x] E7 Todo pane from `LiveTodoStore`
- [x] E8 Turn-status state machine + honest `[stop]`
- [x] E9 Welcome / minimal auth
- [x] E10 Prompt-kind + quote-bar copy
- [x] E11 `/context` categorical block
- [x] E12 Credit bar + real `/usage`
- [x] E13 Minimal panels / plan commit / full-view `/transcript`
- [x] E14 Scroll-debug HUD + JSONL log
- [x] E15 Credit-limit action card

### Wave F
- Completed 2026-08-16: typed image/video refs flow onto tool cards; Kitty post-flush composition owns transmit/place/crop/clear; closed Mermaid fences render through a cached coalescing worker; inline video gains poster/non-looping playback; wrap-host clipboard images become composer attachments; and hidden `/gboom` opens the interactive graphics modal while argument-bearing forms pass through to the model.
- Presentation parity: media reserves scrollback rows instead of parsing prose, iTerm2 stays excluded from scrollback image composition, missing `ffmpeg` remains visible with its path, malformed OSC 999 payloads never become text, and GBOOM clears its image on every dismissal path.
- Validation: `build-tests`; 37 focused Wave F tests across media, Mermaid, wrap-clipboard, GBOOM renderer, and command-routing suites pass; the corrected `/docs` corpus pin and the isolated 12-test table-selection suite pass. The authoritative serial gate reaches all Wave F coverage and is red only in the pre-existing `OpenGrokModelsTests.cancellationAbortsRefresh` unexpected `CancellationError()` at `OpenGrokModelsTests.swift:914`.
- [x] F1 Typed image/video on tool cards
- [x] F2 Kitty post-flush compositor
- [x] F3 In-transcript Mermaid + worker
- [x] F4 Inline video poster / playback
- [x] F5 Wrap-clipboard OSC 999 live paste
- [x] F6 `/gboom` dispatch + game

### Wave G
- [ ] G1 Running-subagent attach
- [ ] G3 `GROK_*` gate family
- [ ] G4 `EffectiveFeatures` launch authority
- [ ] G5 Worktree auto-GC
- [ ] G6 Code Mode hard interrupt
- [ ] G7 Antigravity follow-ons
- [ ] G8 Packed-Git live import
- [ ] G9 Portable WSS + Linux custom CA
- [ ] G10 Windows named-pipe leader
- [ ] G11 `--chat` / local-workspace flags
- [ ] G12 Green platform CI + bwrap evidence
