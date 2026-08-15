# TUI / streaming / tool-card port backlog

**As of:** 2026-08-14  
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
| **Status** | TODO (DIVERGED) |
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
| **Status** | TODO (DIVERGED / UNWIRED) |
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

**Defer (P2 follow-ons, still this family):**

- `edit_highlight_worker` (async file-scoped syntax after hunk-local) — ABSENT.
- `stitchOverlappingHunks` for adjacent same-file cards — algorithm already at `PagerDiff.swift:418`, UNWIRED.

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
| **Status** | TODO (ABSENT) |
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
| **Status** | TODO (DIVERGED) — typed output UNWIRED |
| **Severity** | P0 |
| **Depends on** | A4 |

**Rust:** `scrollback/blocks/tool/read.rs` — path surfaces (basename collapsed, cwd-relative expanded), `(11-20 of 200)`, `(empty)` / `(image)` / page count, dim line gutter, syntax/primary text, collapsed → truncated → collapsed. Empty reads not foldable. **No accent rail** on body.

**Swift already has:** `ReadFileTool` typed path/content/range/total (`ReadFileTool.swift:130`). Flattened at `LiveConversationStore.swift:1217`.

**Files:** `PagerFrameModel.swift`, `LivePagerOutputs.swift`, `OpenGrokPagerRender.swift` (new Read painter), `ReadFileTool.swift` (keep; do not reimplement).

**Acceptance:** snapshots for range, empty, gutter separate from content, non-foldable empty.

---

### C2. List painter

| | |
| --- | --- |
| **Status** | TODO (DIVERGED) — typed output UNWIRED |
| **Severity** | P1 |
| **Depends on** | A4 |

**Rust:** `list_dir.rs` — colored/shortened path, `1 entry` / `N entries`, full expanded terminal-styled listing, errors not foldable.

**Swift already has:** `ListDirTool` path/content/count (`ListDirTool.swift:64`).

**Acceptance:** singular/plural count, full expand (not 2+3 truncate), error non-foldable.

---

### C3. Search painter + fix `glob`

| | |
| --- | --- |
| **Status** | TODO (DIVERGED) |
| **Severity** | P0 |
| **Depends on** | A4 |

**Rust:** `search.rs` — quoted/colored pattern, glob/path spans, “N matches in M files”, mode metadata, grouped file sections, independent line-number column, `(no results)` still foldable. `tool/mod.rs:470` — `glob` is Search.

**Swift:** `GrepTool.swift:85` lacks grouped file+line records and output mode. `PagerFrameModel.swift:119` maps `glob` → `.list`.

**Acceptance:** zero results; 3 matches in 2 files; FilesWithMatches; Count; case-insensitive/multiline metadata; `glob` uses Search painter.

---

### C4. Web fetch painter

| | |
| --- | --- |
| **Status** | TODO (DIVERGED) — metadata UNWIRED |
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
| **Status** | TODO (DIVERGED) |
| **Severity** | P1 |
| **Depends on** | A1 (backend-hosted) + A4 |

**Rust:** `web_search.rs` — query header, deduped `(N sites)`, expanded ≤3 domains + `(+N more)`. X search label, no fake empty body. Tracker materializes backend actions at `tracker.rs:1717`.

**Swift:** citations flattened to a `Sources:` appendix (`LiveWebTools.swift:485`); `x_search` is generic; backend X/web is dropped in A1’s `default: continue`.

**Acceptance:** duplicate domains count once; 3 + overflow; X search titled `X Search`.

---

### C6. Memory search painter

| | |
| --- | --- |
| **Status** | TODO (DIVERGED) — envelope already LIVE |
| **Severity** | P1 |
| **Depends on** | A4 |

**Rust:** `memory_search.rs` — `Memory Search <query> (N results)`, numbered path/range/score/source, 3 snippet lines, honest `(no results)`.

**Swift:** `LiveMemoryComposition.swift:411` already emits the Rust-parsable envelope. Kind falls through to `.generic`.

**Acceptance:** 0 / 1 / N result fixtures match pin headers and rows.

---

### C7. MCP `search_tool` / `use_tool` painters

| | |
| --- | --- |
| **Status** | TODO (DIVERGED) — tools themselves LIVE |
| **Severity** | P1 |
| **Depends on** | A4 |

**Rust:** `search_tool.rs` / `use_tool.rs` — `Search Tools <query> (N results)`; title-cased action + ghosted server; `use_tool` → `Server Action` + key/value args + 3/10 output.

**Swift:** both tools are live (`LiveToolExecutor.swift:473`); cards are raw JSON.

**Acceptance:** prefix-stripping tests; qualified and unqualified names; nested `tool_input`.

---

### C8. Generic Other leftovers

| | |
| --- | --- |
| **Status** | TODO (DIVERGED) |
| **Severity** | P1 |
| **Depends on** | A4 |

**Rust:** `other.rs` — `Label: content` split, AskUserQuestion numbered Q&A, media path + open button, error fold rules, elapsed time.

**Acceptance:** accepted / declined / plan-mode question results match pin rows.

---

### C9. Per-kind fold policy + rail policy

| | |
| --- | --- |
| **Status** | TODO (DIVERGED) |
| **Severity** | P1 / P2 |
| **Depends on** | B1, C1–C8 |

After painters exist:

- Read: collapsed ↔ truncated; empty not foldable.
- List/Search/Fetch: collapsed ↔ full; failed List not foldable; zero-result Search is.
- Generic: not foldable without foldable content.
- Rails: Read/List/Search **no** expanded rail (Rust); Execute yes.
- Verb-group headers (`Reading 3 files`) are ABSENT (`tool/mod.rs:98-146`). Port after individual painters, not before.

**Files:** `PagerFrameModel.swift`, `LiveScrollbackFocus.swift` (`:315` currently marks every tool foldable), `OpenGrokPagerRender.swift`.

---

### C10. Header selection restricted to query/URL content

| | |
| --- | --- |
| **Status** | TODO (DIVERGED) |
| **Severity** | P2 |
| **Depends on** | C4–C7 |

**Rust:** fetch/search/memory header selection is the semantic URL or query only (`web_fetch.rs:140`, `web_search.rs:158`).

**Swift:** `OpenGrokPagerRender.swift:1233` marks the complete painted header — bullet, verb, detail — as selectable.

**Acceptance:** dragging/copying each fetch/search/memory/search-tool header returns only its URL/query, including wrapped headers.

---

# Wave D — Thinking + incremental markdown

**Depends on:** A1 reasoning events.

---

### D1. Live thinking block

| | |
| --- | --- |
| **Status** | TODO (ABSENT live construction; painter UNWIRED) |
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
| **Status** | TODO (UNWIRED renderer + DIVERGED width) |
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
| **Status** | TODO (DIVERGED) |
| **Severity** | P2 |
| **Depends on** | — |

Pin `agent.rs:165` has no cursor. Swift invents `▌` (`OpenGrokPagerRender.swift:954`) and the cursor steals the timestamp near the right edge (`:1023`).

**Acceptance:** Width-constrained streaming line still paints timestamp; no `▌`.

---

### D4. Fenced-code syntax + citation fences + line backgrounds

| | |
| --- | --- |
| **Status** | TODO (DIVERGED / ABSENT) |
| **Severity** | P1 |
| **Depends on** | D2 helpful |

**Rust:** `syntax.rs:72` language highlighting; `syntax.rs:108` `10:20:path` citation fences. `markdown_content.rs:418` line backgrounds → `BlockLine`.

**Swift:** all fences are one yellow style (`MarkdownRenderEngine.swift:250`, `PagerMarkdownRendering.swift:56`). `MarkdownRenderLine` has no background (`OpenGrokMarkdown.swift:30`).

**Acceptance:** Swift/Rust fences highlight; `10:12:file.swift` resolves by path; fenced line background survives markdown → pager → `PaintLine`.

---

# Wave E — Non-tool transcript blocks + chrome

**Depends on:** A1 typed transport. Extend `PagerConversationItem` beyond `.message | .tool | .separator` (`PagerFrameModel.swift:166`).

---

### E1. Session-event blocks

| | |
| --- | --- |
| **Status** | TODO (ABSENT typed item) |
| **Severity** | P1 (typed failures are P0 via A1) |
| **Depends on** | A1 |

**Rust:** `session_event.rs` — turn failed (typed), compaction, retry/auth/context, hook annotations, model change, memory/goal, recap (one block, fill in place, `:421`).

**Swift:** `Turn failed: <string>` (`LiveInteractiveControllerRenderer.swift:1519`); recap = “Recap…” note + second note (`:2412`). Pager event enum has no session-event channel (`OpenGrokPagerMinimal.swift:79`).

**Acceptance:** Every pin variant; recap updates the original item rather than appending a second one.

---

### E2. Hook + lifecycle cards

| | |
| --- | --- |
| **Status** | TODO (ABSENT presentation; execution LIVE) |
| **Severity** | P1 |
| **Depends on** | A4 hook-run field |

Hooks **execute** (`LiveToolExecutor.swift:769`, `LiveHooksComposition.swift:26`) and are discarded from the UI path.

**Rust:** `hook.rs` collapsed `[hooks: N/M]`; expanded pre/post sections; `lifecycle.rs` `session_start` / `user_prompt_submit` rows; stop hooks on the turn marker (`session_event.rs:302`). Attachment in `entry.rs:562` and `state/mod.rs:789`.

**Acceptance:** pre success + post failure → pinned suffix and sections. `session_start` cannot receive later tool hooks.

---

### E3. `BgTaskBlock`

| | |
| --- | --- |
| **Status** | TODO (ABSENT transcript block; `/tasks` LIVE) |
| **Severity** | P1 |
| **Depends on** | A1 item enum; B3 for double-click viewer |

**Rust:** `bg_task.rs` + `acp_handler/background.rs:74` — demote Execute → always-collapsed lifecycle row; started/completed/failed; viewer tails stdout by task ID (`block_viewer.rs:659`). **Does not** reuse the execute painter after backgrounding.

**Swift:** `/tasks` is live (`LiveTasksPane.swift:149`); overlay viewer is a **static snapshot** (`LiveInteractiveOverlays.swift:1022`). No in-transcript demotion.

**Acceptance:** background / auto-background / success / fail / monitor; viewer tails; double-click opens viewer.

---

### E4. `SubagentBlock` + `SwarmBlock`

| | |
| --- | --- |
| **Status** | TODO (ABSENT painters; runtimes LIVE) |
| **Severity** | P1 |
| **Depends on** | A1 item enum |

**Rust:** `subagent.rs`, `swarm.rs` — typed lifecycle, member tree, turns/tools/duration/activity.

**Swift:** snapshots feed `/tasks`/dashboard or a generic card (`LiveInteractiveControllerRenderer.swift:2123`).

**Acceptance:** activity updates in place; completed/failed/cancelled accents; swarm member tree (queued/running/waiting/outcome, turns, tools, duration).

---

### E5. Workflow scrollback marker

| | |
| --- | --- |
| **Status** | TODO (DIVERGED — modal LIVE, transcript ABSENT) |
| **Severity** | P1 |
| **Depends on** | A1 item enum |

`/workflows` modal is live (`LiveWorkflowOverlay.swift:18`). Closing it removes the only structured view (`LiveInteractiveOverlays.swift:2003`).

**Rust:** `workflow.rs` — objective, phase trail, agent count, outcome accent.

**Acceptance:** objective + phase trail + terminal outcome remain after the overlay closes.

---

### E6. Dedicated `/btw` block (and/or dismissible panel)

| | |
| --- | --- |
| **Status** | TODO (DIVERGED) |
| **Severity** | P1 |
| **Depends on** | A1 item enum |

Today: two system notes that can interleave with the main turn (`LiveInteractiveControllerRenderer.swift:2530`). Source explicitly records the dedicated panel/block as absent.

**Rust:** `btw.rs` (gold accent, foldable markdown) + `views/btw_overlay.rs` (dismissible panel).

**Acceptance:** one pending block (or one panel) filled in place; foldable; no interleave; Esc dismisses the panel variant.

---

### E7. Wire `LiveTodoStore` into a real pane

| | |
| --- | --- |
| **Status** | TODO (UNWIRED) |
| **Severity** | P1 |
| **Depends on** | — |

`todo_write` works (`LiveTodoTools.swift:50`). Fullscreen and minimal pass `todosHeight: 0` (`PagerMinimalFrameHost.swift:350`). `/tasks` is **not** this pane.

**Rust:** `views/todo_pane.rs` + minimal `todo.rs` (8-row cap, auto-hide completed).

**Acceptance:** `todo_write` → live ordered rows; status glyphs; full-screen filtering/toggle; minimal cap + auto-hide + force-show.

This is a textbook “succeeds, does nothing, says nothing” on a user-facing list.

---

### E8. Turn-status state machine

| | |
| --- | --- |
| **Status** | TODO (DIVERGED) |
| **Severity** | P0 for dishonest `[stop]`; P1 for the rest |
| **Depends on** | A1 retry/backend events |

**Rust:** `views/turn_status.rs:198-650` — thinking / responding / retrying / waiting / tools / cancel / compaction / bash; MCP startup; drain-blocked; parked watcher; `[stop]` only when cancel is real.

**Swift:** freeform label + elapsed + unconditional `[stop]` (`PagerFrameModel.swift:275`, `OpenGrokPagerRender.swift:1812`).

**Acceptance:** table-driven states; `[stop]` only with a valid cancel action; minimal keyboard-only has no cancel button.

---

### E9. Welcome / minimal auth

| | |
| --- | --- |
| **Status** | TODO (DIVERGED) |
| **Severity** | P1 |
| **Depends on** | — |

Auth is transcript notes (`LiveInteractiveControllerRenderer.swift:2292`). Welcome model has no auth/device-code/raw-URL fields (`PagerOverlay.swift:451`). No minimal `auth.rs` painter.

**Rust:** `views/welcome/mod.rs:1022-1147` (device code, copy feedback, raw-URL mouse-disable); `pager-minimal/src/auth.rs`.

**Acceptance:** long URL copyable byte-for-byte; raw mode disables mouse; minimal signing-in → trust → starting.

Static welcome hero/menu/changelog/shimmer is LIVE — only the authentication subview is missing.

---

### E10. Prompt-kind + quote-bar copy

| | |
| --- | --- |
| **Status** | TODO (DIVERGED) |
| **Severity** | P2 |
| **Depends on** | — |

User prompts are one style (`LivePagerOutputs.swift:693`, `PagerFrameModel.swift:15`). Quote `│` is copied with the text (`OpenGrokPagerRender.swift:2550`).

**Rust:** `user.rs` bash/cron/interjection/skill prefixes; `quote_bar.rs:144` excludes decorative bars from selection/copy.

**Acceptance:** bash / cron / skill / interjection prefixes; selecting `│ quoted` copies `quoted`.

Standard user-prompt painting (prefix, band, padding, wrapping, timestamps) is LIVE.

---

### E11. `/context` categorical block

| | |
| --- | --- |
| **Status** | TODO (DIVERGED) |
| **Severity** | P1 |
| **Depends on** | A1 item enum (if it becomes a scrollback block) |

Modal is aggregate only (`LiveScrollbackFocus.swift:340`, `LiveInteractiveOverlays.swift:2073`).

**Rust:** `context_info.rs:45` — system / messages / reasoning / free + tool-definition rows; 5×20 or 10×10 bars.

**Acceptance:** category totals; wide and narrow layouts; redraw after width/theme changes.

---

### E12. Credit bar + real `/usage`

| | |
| --- | --- |
| **Status** | TODO (ABSENT chrome / DIVERGED usage) |
| **Severity** | P1 |
| **Depends on** | billing client already in tree |

No credit fields on `PagerStatusBar` (`PagerFrameModel.swift:209`). `/usage` is estimated session tokens (`LiveSessionServices.swift:236`).

**Rust:** `credit_bar.rs:167-252`; `usage.rs` Codex / Antigravity / xAI sections.

**Acceptance:** credits used % + 80/100% warnings; xAI / Codex / Antigravity fixtures; no estimate marker when authoritative.

HEAD-only `usage_modal.rs` (tabbed modal at `92bece5d`) is **not** pin work.

---

### E13. Minimal remainders

| | |
| --- | --- |
| **Status** | TODO (DIVERGED); welcome card LIVE |
| **Severity** | P1 |
| **Depends on** | B/C painters for full-view ANSI |

Recorded in `PagerMinimalFrameHost.swift:593` as deferred:

- Below-prompt `/resume` and `/mcps` panels (`pager-minimal/src/panel.rs`) vs centered overlays (`:650`).
- Plan: commit full plan once into native scrollback + compact controls (`plan.rs:65`); line comments (`plan_approval_view.rs:38`). Current overlay omits per-line comments (`PagerOverlay.swift:1010`).
- `/transcript` = expanded ANSI per-kind render (`full_view.rs`), not `conversation.transcript` (`LiveInteractiveControllerRenderer.swift:2968`).

**Honest non-gap:** native-scrollback minimal frontend and one-shot welcome card are LIVE (`LiveInteractiveControllerRenderer.swift:965`, `PagerMinimalFrameHost.swift:518`).

---

### E14. Scroll-debug HUD + JSONL log

| | |
| --- | --- |
| **Status** | TODO (ABSENT) |
| **Severity** | P2 |
| **Depends on** | existing scroll normalizer |

`/debug` is FPS-only (`OpenGrokPagerInteractive.swift:340`). Pin has `GROK_SCROLL_DEBUG`, `/scroll-debug`, `GROK_SCROLL_LOG` (`scroll_debug_hud.rs`, `scroll_log.rs`).

**Honest non-gap:** `[animation].show_fps` remaining parse-only is pin parity; the pin also never reads it.

---

### E15. Credit-limit action card

| | |
| --- | --- |
| **Status** | TODO (ABSENT) |
| **Severity** | P1 |
| **Depends on** | A1 item enum |

**Rust:** `credit_limit.rs:18` — Enable PAYG / Increase PAYG Limit / Purchase Credits + clickable account URL.

No Swift `CreditLimit` / `EnablePayg` surface exists.

**Acceptance:** all three action variants and safe URL activation.

---

# Wave F — Media, Mermaid, Gboom

**Depends on:** A4 media refs on cards; a post-flush compositor.

---

### F1. Typed image/video on tool cards

| | |
| --- | --- |
| **Status** | TODO (DIVERGED) — generation LIVE |
| **Severity** | P0 |
| **Depends on** | A4 media refs |

Generation is live (`LiveToolExecutor.swift:338`). Pager gets `Saved image: <path>` (`LiveImageTools.swift:457`, `LiveVideoComposition.swift:50`).

**Rust:** `tracker.rs:1947` maps typed image/video output into media-bearing tool blocks; `other.rs:15` stores refs separately from prose.

**Acceptance:** fixture handlers produce media-bearing cards without parsing prose.

---

### F2. Kitty post-flush compositor

| | |
| --- | --- |
| **Status** | TODO (UNWIRED + DIVERGED protocol bytes) |
| **Severity** | P1 |
| **Depends on** | F1 |

Encoder exists (`TerminalCapabilities.swift:52`), **no production caller** from `LiveInteractiveControllerRenderer.swift:1931`. iTerm2 must stay **off** for scrollback (pin `terminal/image.rs:171`). Fix ID/chunk fields before wiring (`TerminalCapabilities.swift:133` diverges: hardcodes ID `1`, enables iTerm2, continuation chunks omit pin fields).

**Acceptance:** fake Kitty sink: transmit once, place per frame, crop on scroll, ID-specific clear. iTerm2 detection maps to `None`.

---

### F3. In-transcript Mermaid

| | |
| --- | --- |
| **Status** | TODO (UNWIRED library; worker ABSENT) |
| **Severity** | P1 |
| **Depends on** | D2 finish-time extraction; F2 for Open Image |

Library is SVG (`OpenGrokMermaid.swift:38`), not imported by CLI (`Package.swift:371`). File comments record that rasterization, terminal negotiation, and pager integration are not implemented (`:98`).

**Rust pin is Unicode art inline** + Open Image / Copy Path / Copy Source (`mermaid_content.rs:125-262`). PNG is **not** inlined. Worker: `mermaid_worker.rs` (3 s timeout, cache, coalesced jobs) — ABSENT.

**Acceptance:** stream a fence in chunks; diagram only after close; one affordance row; concurrent identical requests render once.

---

### F4. Inline video poster / playback

| | |
| --- | --- |
| **Status** | TODO (ABSENT) |
| **Severity** | P1 |
| **Depends on** | F1, F2 |

**Rust:** `inline_media_ffmpeg.rs` + `prompt_images.rs:290` — `ffprobe`/`ffmpeg` poster, non-looping inline play, missing-binary hint.

**Swift:** `LiveVideoComposition.swift:376` is path text only.

**Acceptance:** fake ffmpeg yields a poster and ordered frames; playback stops on the last frame; missing binary produces a visible hint and path.

---

### F5. Wrap-clipboard OSC 999 on the live paste-miss path

| | |
| --- | --- |
| **Status** | TODO (UNWIRED) |
| **Severity** | P2 |
| **Depends on** | — |

Library exists (`OpenGrokTerminalCore/WrapClipboardImage.swift`, `OpenGrokPagerRender/WrapClipboardImage.swift`). Live paste never requests it.

**Honest non-gap:** this is composer attachments, not assistant transcript media. It cannot substitute for F1.

**Acceptance:** full miss emits OSC 999 once; local clipboard suppresses it; valid frame → one image chip; malformed frames never become text.

---

### F6. `/gboom`

| | |
| --- | --- |
| **Status** | TODO (DIVERGED) |
| **Severity** | P1 for dispatch honesty; game itself P2 |
| **Depends on** | F2 |

Hidden command must stay hidden. Arguments must **pass through** as a prompt (`OpenGrokPagerInteractiveController.swift:3369` swallows them). Bare `/gboom` is a Kitty game (`gboom/mod.rs:84`), not Braille art (`LivePagerOverlayText.swift:175`).

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
- [x] A2 Honest restore of tool outcomes (`ToolCallOutcomeMap` sidecar + seed/peek)
- [x] A3 Nonzero bash exits are failed (`displayState` on success result)
- [x] A4 Structured tool payloads + factory (`PagerToolCard.make`; painters still generic)
- [x] A5 Incremental tool-output sink (protocol + live `onOutput` append)
- [x] A6 Merge-in-place fold/timing

Wave A is **transport**, not painters. Execute/edit/read cards still share `appendToolCard` until Wave B/C.

### Wave B
- [ ] B1 Execute painter
- [ ] B2 Edit/create painter + committed backgrounds
- [ ] B2-follow-on Highlight worker + same-file stitch
- [ ] B3 Double-click fold

### Wave C
- [ ] C1 Read painter
- [ ] C2 List painter
- [ ] C3 Search painter + `glob` → Search
- [ ] C4 Web fetch painter
- [ ] C5 Web/X search painter
- [ ] C6 Memory search painter
- [ ] C7 MCP `search_tool` / `use_tool` painters
- [ ] C8 Generic Other (Q&A, media, elapsed)
- [ ] C9 Per-kind fold + rail policy
- [ ] C10 Header selection = URL/query only

### Wave D
- [ ] D1 Live thinking block + sticky Ctrl+E
- [ ] D2 Streaming markdown + table width
- [ ] D3 Remove invented cursor
- [ ] D4 Syntax / citation fences / line backgrounds

### Wave E
- [ ] E1 Session-event blocks + in-place recap
- [ ] E2 Hook + lifecycle cards
- [ ] E3 BgTaskBlock + live viewer
- [ ] E4 SubagentBlock + SwarmBlock
- [ ] E5 Workflow scrollback marker
- [ ] E6 `/btw` block or dismissible panel
- [ ] E7 Todo pane from `LiveTodoStore`
- [ ] E8 Turn-status state machine + honest `[stop]`
- [ ] E9 Welcome / minimal auth
- [ ] E10 Prompt-kind + quote-bar copy
- [ ] E11 `/context` categorical block
- [ ] E12 Credit bar + real `/usage`
- [ ] E13 Minimal panels / plan commit / full-view `/transcript`
- [ ] E14 Scroll-debug HUD + JSONL log
- [ ] E15 Credit-limit action card

### Wave F
- [ ] F1 Typed image/video on tool cards
- [ ] F2 Kitty post-flush compositor
- [ ] F3 In-transcript Mermaid + worker
- [ ] F4 Inline video poster / playback
- [ ] F5 Wrap-clipboard OSC 999 live paste
- [ ] F6 `/gboom` dispatch + game

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
