# AGENTS.md — swift-open-grok

Instructions for AI coding agents (and humans) working in this repository.

**What this is:** a Swift source port of [Open Grok](https://github.com/mweinbach/open-grok) (Rust).  
The reference clone lives at [`github.com/mweinbach/open-grok`](https://github.com/mweinbach/open-grok) (or the location that houses those repos, e.g. `../open-grok` or `~/Projects/grok-build`) and is **read-only**.  
The pinned reference commit is recorded at the top of [`PORT_STATUS.md`](PORT_STATUS.md).


| Concept | Value |
| --- | --- |
| Public binary | `open-grok` |
| User state | `$OPENGROK_HOME` or `~/.opengrok` — **never** `~/.grok` |
| Project config | `.opengrok/` in the repo |
| Language | Swift 6, strict concurrency, `swift-tools-version: 6.1` |
| Toolchain | pinned in `.swift-version` |
| Ledgers | `PORT_STATUS.md` (truth), `PORT_PLAN.md` (architecture), `CRATE_MAP.md` (crate→target) |

---

## 1. Building and verifying — read this first

**Never invoke SwiftPM directly.** Everything goes through the serializing wrapper:

```sh
# Build workspace
zsh workflows/swift-safe-verify.zsh build

# Build test suites
zsh workflows/swift-safe-verify.zsh build-tests

# Authoritative green gate: run all tests serially
zsh workflows/swift-safe-verify.zsh test --no-parallel

# Build open-grok executable product
zsh workflows/swift-safe-verify.zsh build --product open-grok
```

- **`test --no-parallel` is the green gate.** Default parallel is usually green too, but shared-runner load makes serial the honest signal.
- **A zero-match `--filter` still exits 0.** Always check the reported *test count*, never the exit code alone. Filters match **type** names, not `@Suite`/`@Test` display names.
- **`build-tests` compiles but does not link.** A test-target link error passes straight through it and only appears under `test`. "build-tests green" is necessary, not sufficient.
- **Every build and every suite run has a 10-minute wall-clock ceiling**, enforced by the wrapper (`SWIFT_SAFE_TIMEOUT_SECONDS`, default 600). A healthy run finishes well inside it; a run that hits the ceiling is a hang or a runaway test, not a slow build — investigate, don't just raise the ceiling. Raise it per-run (`SWIFT_SAFE_TIMEOUT_SECONDS=1200 zsh workflows/…`) only for a known cold build. If you interrupt a `test` run by hand, **check for an orphaned `swiftpm-testing-helper`** (`pgrep -fl swiftpm-testing-helper`) — the wrapper's kill cleans up its own tree, but an interrupt can strand the helper, and a stranded helper running an animated-renderer test has ballooned to 100+ GB of RSS here before anyone noticed.

### When several agents share the tree

- **Exactly one agent owns the full build and the suite.** Everyone else gets `swift build --target <theirs>` and nothing more.
- **Never wrap a build in an `until`/`while` retry loop.** It grabs the lock, releases, sleeps, grabs again, and starves whoever is trying to finish.
- A private `SWIFT_SAFE_SCRATCH_PATH` avoids the **lock** but not the **CPU**. It does not make a concurrent build free.
- **Do not edit source while someone else's run is in flight** — it corrupts their results exactly as effectively as a competing build. If you did, say so immediately and name the files and the window.

---

## 2. Rust Crate to Swift Target Mapping

The Rust workspace consists of 84 crates mapped into structured SwiftPM modules in `Sources/` (see [`CRATE_MAP.md`](CRATE_MAP.md) for the exhaustive catalog). The primary subsystems map as follows:

| Upstream Rust Crate (`grok-build`) | Primary Swift Target(s) (`swift-open-grok`) | Subsystem Responsibility |
| --- | --- | --- |
| `crates/codegen/xai-grok-pager-bin` | `OpenGrokCLI`, `OpenGrokExecutable` | CLI entry point, live composition launcher, interactive controller renderer, slash commands, application runner. |
| `crates/codegen/xai-grok-pager` | `OpenGrokPager`, `OpenGrokPagerRender`, `OpenGrokPagerCommandUI`, `OpenGrokPagerConversationUI`, `OpenGrokPagerOperationsUI` | Interactive controller state machine, ANSI terminal rendering engine, overlays (modals, dashboard, picker), input routing. |
| `crates/codegen/xai-grok-pager-minimal` | `OpenGrokPagerMinimal` | Minimal/plain frame host for scrollback and headless terminal operation. |
| `crates/codegen/xai-grok-shell` | `OpenGrokShell`, `OpenGrokSessionRuntime`, `OpenGrokAgentCoordinator`, `OpenGrokACPRuntime`, `OpenGrokProviderSession`, `OpenGrokGoalState` | Agent turns, sessions, actor pipelines, subagent swarms, ACP server, goal tracking. |
| `crates/codegen/xai-grok-sampler` / `sampling-types` | `OpenGrokSampler`, `OpenGrokSamplingTypes` | Multi-provider streaming HTTP/wire adapters (xAI, Codex, Kimi, Fireworks, DeepSeek, Wafer, Z AI), token estimation, model capabilities. |
| `crates/codegen/xai-grok-tools` / `tools-api` | `OpenGrokToolRegistry`, `OpenGrokFileTools`, `OpenGrokExecutionTools`, `OpenGrokWebMediaTools`, `OpenGrokAgentControlTools`, `OpenGrokToolsAPI` | Bash/terminal execution, file read/edit/patch, web browsing, image tools, subagent spawn, flat-team mailboxes. |
| `crates/codegen/xai-grok-workspace` | `OpenGrokWorkspace`, `OpenGrokSandbox`, `OpenGrokFastWorktree`, `OpenGrokHunkTracker` | Permission engine (`deny > ask > allow`), folder trust, sandboxing, worktrees, explicit agent hunk attribution. |
| `crates/codegen/xai-ratatui-textarea` / `ratatui-inline` | `OpenGrokTextArea`, `OpenGrokTerminalCore`, `OpenGrokTTY` | Unicode editor buffer, multi-cursor, syntax highlighting, ANSI escape parsing, mouse protocol decoders. |
| `crates/codegen/xai-grok-code-mode*` | `OpenGrokCodeMode`, `OpenGrokJavaScriptRuntime`, `OpenGrokCodeModeProtocol` | Persistent V8/JavaScriptCore execution cells, nested tool dispatch, yield/wait/cancel lifecycle. |
| `crates/codegen/xai-grok-markdown*` / `mermaid*` | `OpenGrokMarkdown`, `OpenGrokMarkdownCore`, `OpenGrokMermaid`, `OpenGrokMermaidLayout` | Streaming terminal Markdown renderer, table formatting, syntax highlight, Mermaid layout engine. |
| `crates/codegen/xai-grok-config*` / `paths` | `OpenGrokConfig`, `OpenGrokConfigTypes`, `OpenGrokPaths` | Multi-layer TOML configuration (`$OPENGROK_HOME`, `.opengrok/`), authority merging, managed policies. |
| `crates/codegen/xai-grok-auth` | `OpenGrokAuth` | Isolated multi-provider credentials store, OAuth tokens, API keys, zero-data-retention (ZDR) validation. |

---

## 3. Modular Architecture: Preventing Monolithic (>25k LOC) Files

To avoid massive, unmaintainable source files (such as the former 18,767-line `LiveComposition.swift`), code in complex subsystems is decomposed into domain-aligned files adhering to strict Swift 6 concurrency:

```
Sources/OpenGrokCLI/
├── LiveComposition.swift                   # Launcher, sampling tuning, and composition roots (~4,000 LOC)
├── LiveSecurityPolicy.swift                # Security policies, write denial prompters, directory registry (~500 LOC)
├── LiveToolExecutor.swift                  # Tool executor and terminal tool runtime (~1,700 LOC)
├── LiveConversationStore.swift             # Conversation store, history, agent profiles, sampling driver (~1,200 LOC)
├── LivePagerOutputs.swift                  # Pager runtime adapters, sessions, sinks, chrome, output formats (~1,300 LOC)
├── LiveInteractiveControllerRenderer.swift # Primary actor declaration, stored properties, init, lifecycle (~4,000 LOC)
├── LiveInteractiveInputRouting.swift       # Extension: Keyboard chords, mouse routing, hit-testing, motion/ticks (~800 LOC)
├── LiveInteractiveCommands.swift           # Extension: Slash commands dispatcher and individual handlers (~1,500 LOC)
├── LiveInteractiveOverlays.swift           # Extension: Dashboard, settings modal, theme picker, privacy, question sheets (~1,800 LOC)
├── LiveInteractiveSelection.swift          # Extension: Text selection, dragging, autoscroll, copy, table selection (~1,200 LOC)
└── LiveInteractiveProbes.swift             # Extension: Testing inspection hooks and live-seam probes (~500 LOC)
```

### Modularization Rules & Guidelines

1. **Target File Size Ceiling**: Keep individual Swift files under **~3,000 LOC**. When a subsystem approaches or exceeds this ceiling, decompose it along domain boundaries.
2. **Actor Stored Properties in Primary File**:
   - In Swift, extensions cannot define stored properties. All stored properties (`var` and `let`) must be declared in the primary `actor` or `class` definition file (e.g. `LiveInteractiveControllerRenderer.swift`).
   - Declare properties as `internal` (or `internal(set) var`) rather than `private`, allowing extensions in the same module (`OpenGrokCLI`) to read and mutate them under actor isolation.
3. **Domain-Aligned Extensions**:
   - Use `extension TargetActor { ... }` in separate files to group methods by domain (e.g. commands, overlays, input routing, text selection, probes).
   - In Swift 6, extensions in the same module automatically inherit the actor isolation of the primary type without thread hops or concurrency warnings.
4. **Subsystem Extraction**:
   - Distinct services with their own state or lifecycle (e.g. `LiveSecurityPolicy`, `LiveToolExecutor`, `LiveConversationStore`, `LivePagerOutputs`) should be declared as independent structs/actors in dedicated files rather than nested inside the controller.

---

## 4. TUI Logic, Mouse Input, & Protocol Parity

Terminal event parsing, escape sequences, and interactive TUI logic must have exact parity with the upstream Rust reference (`xai-org/grok-build` / `open-grok`):

- **SGR 1006 / X10 Mouse Tracking**:
  - Mouse event decoding (`TerminalInput.swift`) must handle mouse clicks, releases, drags, and wheel events.
  - Correctly decode modifier keys (`Shift`, `Ctrl`, `Alt`/`Option`) from the SGR parameter mask `(code >> 2) & 0x07`.
  - Guard against coordinate overflow (`>= 1_000_000`) caused by corrupted input.
- **Middle-Click Paste**: Middle-click on the terminal input or prompt editor pastes from the system selection clipboard.
- **PTY CSI Fragment Filtering**: Retain incomplete escape fragments across PTY chunk boundaries (`CsiFragmentFilter.swift`) to prevent raw CSI fragments from flashing on screen.
- **Kitty Keyboard Protocol**: Probe and negotiate Kitty keyboard protocol modes for progressive enhancement when supported by the terminal.
- **Interactive Component Hit-Testing**:
  - Collapsible tool output cards: Header rect hit-testing toggles expansion on click/double-click.
  - Dropdown & modal scrollbars: Support thumb dragging and track click-to-scroll.
  - Prompt `@file:line` chips: Double-click opens full-screen line viewer overlay.
  - Tasks pane: Interactive `[×]` (kill) and `[⤢]` (inspect) buttons dispatch task actions.

---

## 5. Swift traps this repo has actually hit

Each of these cost real debugging time here. They are not hypothetical.

- **`\r\n` is ONE `Character`.** Splitting on `"\n"` fails on CRLF. Use `Character.isNewline`. Worse at the byte level: an SSE scanner matching only `"\n\n"` never finds a boundary in a `"\r\n\r\n"` stream, so everything accumulates and the whole response decodes to nothing — silent, and only against real servers. **Any byte-level delimiter scan must handle CRLF explicitly.** (Three separate bugs so far: release parsers, PTY screen, SSE framing.)
- **`Process.waitUntilExit()` can never return.** It parks the calling thread's run loop on a death notification; if the child exits first, the notification is spent and the wait hangs forever. Probabilistic — it wedged serial suites for hours while parallel stayed green. **Use `terminationHandler` bridged to a continuation.** Grep for `waitUntilExit` before landing process-spawning code.
- **Adding an associated value to an existing enum case does not break stale matches.** `case .foo:` keeps compiling and silently drops the payload — the opposite of the exhaustiveness help you get from adding a *new* case. Grep every match site by hand. A `static var foo { .foo(x: nil) }` compat shim has the same hazard on the construction side.
- **`try?` flattens `T?` into one silent `nil`.** Same family as above: the compiler stays quiet while a value disappears.
- **Process-cwd defaults are a silent-divergence footgun.** A library initializer defaulting to `FileManager.default.currentDirectoryPath` resolves project config against the *process* cwd, not the session cwd. Make such parameters required.
- **Under `swiftpm-testing-helper`, `Bundle.main` and `argv[0]` point into the toolchain and `Bundle.allBundles` is empty.** Tests that locate resources or the built binary through `Bundle` **silently skip while reporting green**. Anchor to compile-time `#filePath`.
- **JavaScriptCore cannot interrupt a running script on demand.** `JSContextGroupSetExecutionTimeLimit` fires at most once per VM entry and never re-arms. Code Mode termination closes the cell's stream immediately and reclaims the thread via a per-entry ceiling; a hard guarantee needs a child process.
- **A stale object file surfaces as a LINK error naming an innocent file.** If every `Sources/` target compiles and only the link fails, suspect stale artifacts before suspecting a peer. Discriminator: compare the mangled symbol the referencing `.o` needs against `nm` on the module. **Before reporting a link error to someone else, open the named file and confirm the call site exists** — one tool call.

---

## 6. The failure mode this port generates

**"Succeeds, does nothing, says nothing."** A port is exactly where behavior gets dropped while structure survives: it compiles, the types line up, the call returns, and the thing quietly does not happen. Real examples from this repo — config keys that parsed and had no reader; `memory_search` answering "no results" on a workspace where memory is disabled; `/remember` writing correctly to disk, reporting "Saved", and being permanently unfindable; a permission gate returning `nil` (meaning *dispatch*) while being reported as fail-closed.

In none of these was the fix the code that broke. Each mechanism did exactly what it was written to do. **What was missing was any path for the silent case to announce itself.**

Two practices catch this class. Both are cheap and reviewable:

1. **Assert reachability through the live seam.** Test what the model is actually offered, what actually runs, and what actually lands on disk — never against composition types. A composition-level test passes just as happily when nothing constructs the composition.
2. **Never `_ =` a status-returning call.** A discarded return value is how a test hides the very thing it was written to catch. If a call reports success or failure, assert on it at the step it happens, not three assertions downstream.

---

## 7. Parity rules

- **Enumerate from the Rust side first.** Auditing from the port's perspective can only find what someone set out to build; it cannot find what nobody claimed.
- **Cite `file:line` in the reference** for any behavior you implement or any divergence you keep.
- **Do not invent UX upstream lacks**, however nice — and do not "fix" a strictness mismatch by loosening without checking. Strictness is only safe when the grammar is *complete*; this port carries flags upstream does not have.
- **Never register a command, tool, or menu row whose backing feature does not exist.** A no-op on a dropdown is worse than an absent entry.
- **Deliberate divergences get recorded, not hidden**, in `PORT_STATUS.md` with the reason.

---

## 8. Security posture

- The **fixed gate order** is in `PORT_PLAN.md` and is not negotiable: plan gate → PreToolUse hooks (fail-open, recorded) → plan-file auto-approval → permission evaluation (`deny > ask > allow`) → sandbox/resource-lock validation → dispatch → durable history and hunk attribution *after* the result.
- **Fail-closed means fail-closed.** No pipeline means *cannot authorize*, so deny. (Contrast: no `task_id` means *nothing to authorize*, so proceed. Encode the distinction where a reader will see it.)
- **The point of fail-closed is not having to make a reachability argument.** "That path is unreachable today" is not a reason to leave a gate permissive — the next author copies whichever gate they open first.
- **Never widen a bypass to make a test pass.** `OPENGROK_ALLOW_WRITES` authorizes *writes*; using it to authorize *execution* conflates two controls and leaves the supported path untested. Make the test use the flag a real user would type.
- **For anything security-shaped, quote the landed lines** in your report rather than describing them. The failure mode is summarizing from memory of your intent after the tree moved. Quoting forces the read and makes the claim auditable.
- Anyone may re-read anyone's landed code. That is a license, not an accusation — in wave 8 a fail-open gate was caught by a peer who declined to accept the author's summary.

---

## 9. House style

- Swift 6 strict concurrency is a design constraint, not a lint: `Sendable` values cross actors, blocking C/OS calls live in bounded adapters, continuations are guarded for exactly-once resume.
- No AppKit/UIKit/SwiftUI in session, provider, tool, workspace, persistence, rendering-model, or terminal-core targets.
- Platform seams go in adapter targets behind `#if os(...)`; callers consume capability values and typed unsupported errors, never conditional code.
- Comments explain *why* — a constraint the code cannot show. Not what the next line does, not where it came from.
- **When a deliberate tradeoff is load-bearing, write down what it costs, not only why it's right.** A comment that argues only the upside reads as the author defending a choice and gets deleted along with the constraint it was protecting. One that names the downside — "this will fail two suites together if you reword the message; that is expected, here is why, don't loosen it" — reads as a decision already weighed, and it is the only thing that survives contact with someone staring at a red suite looking for the fastest green.
- Match the surrounding file's naming, comment density, and idiom.

---

## 10. Ledger discipline

`PORT_STATUS.md` is the honesty ledger and the reason this port is auditable.

- **Every green claim needs real exit codes and test totals** from a real run, dated.
- **"Implemented" ≠ "reachable."** Distinguish *live* (reachable from the running executable) from *implemented-unwired* (tested library, no importer) from *absent*. Most gaps in this port's history were the middle case, which is why a green suite and a missing feature coexist comfortably.
- Record what you deliberately did **not** do, and why. "Not done" is a fine answer; a silent omission is not.
- If you decline a task because completing it would be harmful, say so and explain. That is a valid outcome. (Telemetry stayed dark in wave 8 for exactly this reason: our default was inverted from upstream's, so wiring emission first would have shipped it on by default.)

---

## 11. Skills index for agents

When working on porting, verification, parity audits, or upstream synchronizations in this repository, load the matching repo skill below:

| Task / Domain | Repo Skill |
| --- | --- |
| Port, refactor, implement, or test a Swift target / subsystem | [`develop-swift-open-grok`](.agents/skills/develop-swift-open-grok/SKILL.md) |
| Coordinate parallel multi-agent waves, subagents, and DAG slices | [`coordinate-agent-teamwork`](.agents/skills/coordinate-agent-teamwork/SKILL.md) |
| Drive real CLI, isolated OPENGROK_HOME, doctor, evidence, or live PTY | [`verify-open-grok`](.agents/skills/verify-open-grok/SKILL.md) |
| Audit parity against Rust reference (`650c1db7`) across all domains | [`audit-open-grok-parity`](.agents/skills/audit-open-grok-parity/SKILL.md) |
| Re-evaluate Rust pin, update protocol fixtures, forward-port deltas | [`sync-open-grok-upstream`](.agents/skills/sync-open-grok-upstream/SKILL.md) |


