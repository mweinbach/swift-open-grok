# Swift Open Grok Port Status

**As of:** 2026-08-04 (inventory + functional audit refresh; reference re-pinned)
**Overall state:** The package builds and tests green on macOS, and `open-grok` now launches a working full-screen TUI agent rather than a bootstrap shell. This remains an incomplete source port rather than a full Rust-parity release: a large share of the implemented library surface is not reachable from the executable, and all non-launch CLI routes still refuse.
**Destination was empty at baseline:** yes.
**Reference:** `xai-org/grok-build` at `80dff0a9dcb24121b976b9f920fbe442af40ea88` (re-pinned 2026-08-04 from `9739c4a2ad23cfea14312a481169757f3da494f4`; +202 commits, releases `v0.1.220-open-grok.22` through `.53`). Local read-only clone: `/Users/mweinbach/Projects/grok-build` (`/tmp/open-grok-reference` when present).
**Fixture pin caveat:** every artifact under `ProtocolFixtures/` was captured at the **old** ref `9739c4a2…` and its provenance/manifest still name that ref. Fixtures are **not** re-captured against `80dff0a9…` and must be re-captured before any fixture-grounded parity claim against the new baseline.
**Swift toolchain used:** Apple Swift 6.4 (`swift-tools-version: 6.1`, `swiftLanguageModes: [.v6]`); `swift --version` reported target `arm64-apple-macosx27.0.0`.
**Base commit before R10 edits:** `93584585eb038c155fbc773ad287f6ee2b043ff4`.

## Luna integration verification snapshot (2026-07-23; resumed serialized remediation)

| Command | Outcome |
|---|---|
| `git diff --check` | **Exit 0**. |
| `zsh workflows/swift-safe-verify.zsh build` | **Exit 0**. |
| `zsh workflows/swift-safe-verify.zsh build-tests` | **Exit 0**. |
| `zsh workflows/swift-safe-verify.zsh test` | **Exit 0** — 100 Swift Testing runs, 1,672 tests, no failures; 100 legacy XCTest runners reported 0 cases. |
| `zsh workflows/swift-safe-verify.zsh build --product open-grok` | **Exit 0**. |
| `open-grok --version`, `help`, and isolated `paths` smokes | **Pass** — version `0.1.220-open-grok.21`; state remained under `/tmp/open-grok-smoke-home`. |

Integration verification is green for the current worktree. `CompactionTranscript.swift` and workflow artifacts remain intact. SwiftPM reports four non-failing warnings for fixture files not declared as resources. The test totals above are from the 2026-07-23 run and have **not** been re-verified since; the 2026-08-04 refresh below is inventory and source inspection only, not a new verifier run.


## Inventory counting method (reproducible)

Counts are mechanical over the committed tree (no Package.swift parsing), recomputed **2026-08-04**:

1. **Production source targets** = directories under `Sources/` → **99**.
2. **Test targets** = directories under `Tests/` → **101**.
3. **Bootstrap placeholder production targets** = source directories whose Swift sources total **≤15 non-comment, non-blank lines** (classic empty-module stubs), **excluding** pure C helper targets `COpenGrokZlib`, `OpenGrokPTYC`, and `OpenGrokCrashHandlerC` (real C implementations, not placeholders) → **8**.
4. **Zero-test targets** = test directories with **no** `@Test` and **no** `func test[A-Z_]` in any `.swift` file → **12**.
5. **Non-placeholder production targets** = 99 − 8 = **91**. **Test targets with ≥1 test** = 101 − 12 = **89**.

The eight targets meeting the ≤15-line rule are exactly:

| Target | Non-comment LOC | Character |
|---|---:|---|
| `OpenGrokCodeMode` | 1 | true placeholder |
| `OpenGrokJavaScriptRuntime` | 1 | true placeholder |
| `OpenGrokMermaid` | 1 | true placeholder |
| `OpenGrokMermaidLayout` | 1 | true placeholder |
| `OpenGrokDistributionSupport` | 1 | true placeholder |
| `OpenGrokReleaseValidation` | 1 | true placeholder |
| `OpenGrokPagerPTYHarness` | 1 | true placeholder |
| `OpenGrokExecutable` | 15 | **not** a placeholder — thin `main` that hands off to `OpenGrokCLI` |

So the honest figure is **7 real placeholders out of 99** production targets, plus one legitimately small entry point. The previously published **42 / 98** figure is superseded and was stale by roughly 35 targets.

The twelve zero-test targets are `OpenGrokCodeModeTests`, `OpenGrokCompatibilityTests`, `OpenGrokDistributionSupportTests`, `OpenGrokFuzzingTests`, `OpenGrokJavaScriptRuntimeTests`, `OpenGrokMermaidLayoutTests`, `OpenGrokMermaidTests`, `OpenGrokPagerPTYHarnessTests`, `OpenGrokPagerPTYTests`, `OpenGrokPerformanceTests`, `OpenGrokReleaseValidationTests`, and `OpenGrokSecurityTests`. Note the pattern: the remaining empty test targets are the placeholder modules plus the four cross-cutting gate suites (compatibility, fuzzing, performance, security), which are the release gates the port has not yet earned.

Verifier commands used for this recount (read-only; no SwiftPM invoked):

```sh
ls Sources | wc -l
ls Tests | wc -l
for d in Sources/*/; do
  t=$(basename "$d")
  case "$t" in COpenGrokZlib|OpenGrokPTYC|OpenGrokCrashHandlerC) continue;; esac
  n=$(find "$d" -name '*.swift' -exec cat {} + | grep -v '^[[:space:]]*$' | grep -v '^[[:space:]]*//' | wc -l)
  [ "$n" -le 15 ] && echo "$t $n"
done
for d in Tests/*/; do
  grep -rqE '@Test|func test[A-Z_]' "$d" --include='*.swift' || echo "ZERO: $(basename "$d")"
done
```

## Live executable capability snapshot (2026-08-04, source-audited)

This section replaces the former "executable is bootstrap-only" claim, which is no longer true. Each item was verified by reading the named file.

**Snapshot caveat:** this describes the tree as audited on 2026-08-04. The three active build-out slices in "Next action" were landing uncommitted files at that moment (Codex credential provider and live auth composition, a write tool pack, and pager markdown/styled-text rendering). Where an item below says a capability is missing, it means missing from the audited state — the in-flight slices are the work to close exactly those gaps, and this section should be re-audited when they land.

**What the executable actually does.** `open-grok` in `interactive`, `minimal`, and `headless` modes runs a real multi-turn agent loop (`Sources/OpenGrokCLI/LiveComposition.swift`, ~96 KB, with terminal output through `Sources/OpenGrokPagerRender/PagerTerminalRenderer.swift`):

- Full-screen alternate-screen TUI with cell-diffed rendering; `--no-alt-screen` opts out.
- Structured tool lifecycle cards for each call.
- Multi-turn conversation loop with session persistence and resume: `--session-id`/`-s`, `--resume`/`-r`, `--continue`/`-c`, and `--fork-session`, stored as JSON under `$OPENGROK_HOME/sessions/`.
- Agent profiles selected with `--profile` / `--agent-profile`, which also filter the exposed tool set.
- Headless output formats `plain`, `json`, `streaming-json`, and `streaming-messages-json`.

**Live providers are API-key only.** xAI, Kimi/Moonshot, and Fireworks resolve. Codex is rejected twice in `resolveSamplingConfiguration` (`LiveComposition.swift:845` and `:863`) with `unsupported(route: "Codex OAuth provider")` — even though `Sources/OpenGrokAuth/` (~4,000 non-comment lines) already implements Codex OAuth/PKCE and device-code flows. This is a wiring gap, not a missing implementation.

**Live tools are read-only.** The registry exposes `run_terminal_cmd` plus the `.explore` `FileToolPack` preset (`read_file`, `list_dir`, `grep`). No write, edit, or patch tool is wired into the live path, so the agent cannot currently modify a workspace.

**Streaming is implemented but unused on the live path.** `OpenGrokSampler` provides `StreamChatCompletions`, `StreamResponses`, and `StreamMessages`, but the live loop calls `conversationCollect` and renders the whole reply at once. Token-by-token output is a composition change, not new provider work.

**All non-launch CLI routes refuse.** `login`, `logout`, `sessions`, `mcp`, `plugin`, `workflow`, `doctor`, `serve`, `acp`, `update`, `memory`, `dashboard`, `workspace`, `worktree`, `inspect`, `completions`, `setup`, `share`, `wrap`, `export`, and `trace` all parse their arguments correctly and then throw `CLIApplicationError.unsupported`, surfaced as `route '<name>' is not available in the current Swift composition` (`Sources/OpenGrokCLI/OpenGrokApplication.swift:10`). Argument parsing is real; only the handlers are missing.

### Real-but-orphaned libraries

These targets are implemented **and** tested but are imported by nothing on the executable's path — verified by grepping `^import <Target>$` across `Sources/` outside each target's own directory:

`OpenGrokMarkdown` + `OpenGrokMarkdownCore`, `OpenGrokMCP`, `OpenGrokHooks`, `OpenGrokMemory`, `OpenGrokVoice`, `OpenGrokUpdate`, `OpenGrokExecutionTools`, `OpenGrokSandbox`, and the pager feature targets `OpenGrokPagerModel`, `OpenGrokPagerRuntime`, `OpenGrokPagerCommandUI`, `OpenGrokPagerConversationUI`, `OpenGrokPagerOperationsUI`.

This is the port's largest honesty gap and the reason "91 non-placeholder targets" must not be read as "91 targets of shipped behavior". The `OpenGrokCLI` import set is exactly: `OpenGrokAgentDefinitions`, `OpenGrokFileTools`, `OpenGrokModels`, `OpenGrokPager`, `OpenGrokPagerMinimal`, `OpenGrokPagerRender`, `OpenGrokProviderSession`, `OpenGrokSampler`, `OpenGrokSamplingTypes`, `OpenGrokShared`, `OpenGrokShell`, `OpenGrokShellBase`, `OpenGrokTerminalCore`, `OpenGrokToolRegistry`, `OpenGrokTTY`, `OpenGrokVersion`.

## Honest integration snapshot (2026-07-22 / R10)

| Check | Result |
|---|---|
| `zsh workflows/swift-safe-verify.zsh build` (prior iter 1–3) | **Fail** historically (PTY mixed language → crash C/`HookEvent`/`SystemPower` → HTTP `NSLock` in async) |
| Post-iter-3 HTTP lock-box fix | Present in tree; **not re-verified** under the three-iteration cap before R10 |
| R10 static foundation fixes (this pass) | Async OTLP `exportSpan`/`exportOpenTelemetry`; real OTLP protobuf + gRPC TraceService path/framing/`grpc-status`; GitStatus pure SHA-1 + `COpenGrokZlib`; pack non-parity; CLI → `OpenGrokVersion`; ProtocolFixtures binary goldens + foundation formats; exact inventory; workflows ban bare SwiftPM |
| `swift build --build-tests` / `swift test` / product | **Not run in R10** (workers forbidden; sole integration agent owns verify) |
| Executable version/help/paths smokes | **Blocked** until product builds; composition tests cover CLI surface |
| CompactionTranscript.swift JSONValue correction | **Preserved** (do not revert) |
| Placeholder production targets | Recorded as **42 / 98** at R10; **superseded** — the 2026-08-04 recount is **8 / 99** matching the rule, of which **7** are real placeholders |
| Zero-test test targets | Recorded as **46 / 100** at R10; **superseded** — the 2026-08-04 recount is **12 / 101**, leaving **89** targets with executable tests |

### R10 foundation changes (integrated-verified)

- `OpenGrokTelemetry`: `ExportTraceServiceRequest` protobuf encoder; product + external HTTP use `application/x-protobuf` with real protobuf; gRPC uses TraceService Export RPC path + framed protobuf + `grpc-status` validation; `exportSpan`/`exportOpenTelemetry` are async and await `HTTPTransport.send`; JSON twin only for diagnostics.
- `OpenGrokGitStatus`: removed CryptoKit; pure-Swift `PortableSHA1`; C target `COpenGrokZlib` (links libz) declared in `Package.swift`; pack-only objects throw `packedObjectUnsupported` (not silent empty HEAD).
- `OpenGrokCLI` version delegates to `OpenGrokVersion.installed` (empty `GROK_TEST_VERSION` parity).
- Tests: ToolRuntime assertion fixed; executable composition suites; telemetry MockHTTPTransport gRPC collector-compat + golden fixture re-encode; BuildSupport semantic fixture decode.
- `ProtocolFixtures/`: binary OTLP HTTP/gRPC goldens, git loose-object zlib, GCRX crash sample, tracing/storage/hunk/PTY/crash format fixtures + provenance + manifest at ref `9739c4a2…` — **still pinned to the old ref after the 2026-08-04 re-pin to `80dff0a9…`; recapture required**.
- Docs/workflows: exact inventory; worker/reviewer/remediation prompts forbid bare SwiftPM; only integration may run `workflows/swift-safe-verify.zsh`.

### Integration fixes already in tree (prior cycle)

- Split C shims into `OpenGrokPTYC` and `OpenGrokCrashHandlerC`; `Package.swift` edges updated.
- Crash C shim: include `<sys/stat.h>` for `fchmod`.
- `HookEventNameWire` CodingKey helper: single failable `init?(stringValue:)`.
- `OpenGrokSystemPower`: concurrency/IOKit fixes.
- `OpenGrokHTTP` `BoundedStreamMailbox`: async-safe nonisolated lock box.

## Implementation status by wave

| Wave | Goal | Status | Entry condition |
|---|---|---|---|
| 0 | Bootstrap, branding, and shared foundations | Target-green for W0 libraries | Planning artifacts accepted |
| 1 | Protocols, domain models, and configuration | **In progress** — R01–R05 plus later remediation; current package graph green | Wave 0 required slices present |
| 2 | HTTP, storage, FS/Git/graph, PTY/TTY/power/crash | **In progress** — R06–R10 plus later remediation; current package graph green | Wave 1 contracts usable |
| 3–11 | Providers through distribution | Mostly scaffold/stub | Prior waves integrated and green |

## Slice status legend

- **Not started:** no target implementation is integrated.
- **In progress:** owner is editing only assigned source/test paths.
- **Target green:** target-scoped build/tests pass, but Package.swift/wave integration may be pending.
- **Integrated:** bootstrap owner added target edges and wave integration tests pass.
- **Blocked:** a concrete missing contract/platform dependency is recorded with an owner; never use a silent stub for security or persistence behavior.
- **Complete:** acceptance checks and required differential/E2E gates pass.

## Ownership rules

- Integration / R10 may edit `Package.swift`, `PORT_STATUS.md`, root workflow/status files, `ProtocolFixtures`, and plugins when listed in ownedPaths.
- Every other slice owns exactly the paths listed in `PORT_PLAN.md`; no two slices share a `Sources/<Target>/` or `Tests/<Target>Tests/` path.
- Same-wave slices use earlier-wave protocols and test fakes. They do not create imports on same-wave concrete targets.
- Status changes must name the slice ID, target-scoped checks, integrated checks, and any known parity divergence.
- **Workers never invoke SwiftPM directly**; only `zsh workflows/swift-safe-verify.zsh` via the sole integration verifier.

## Architecture decisions locked for the port

- Public branding and executable: **Open Grok / `open-grok`**.
- State isolation: **`$OPENGROK_HOME` or `~/.opengrok`; never `~/.grok`**.
- SwiftPM baseline: **6.1**, Swift 6 strict concurrency.
- UI: custom terminal abstraction and reducer/effect runtime; no domain coupling to AppKit/UIKit/SwiftUI.
- Session ownership: one actor per live session, immutable Sendable cross-actor events, cooperative cancellation.
- Provider policy: model metadata identity; backend/profile/auth separated; explicit keys win; credential/history/tool/export isolation.
- Tool policy: fixed plan/hook/auto-approve/permission/sandbox/dispatch order and direct write attribution.
- Persistence: atomic, schema-versioned, Rust-compatible migration under OPENGROK_HOME.
- Platforms: macOS and Linux full support targets; Windows continuously compiled with dedicated adapters and only explicit genuine capability gaps.
- Licensing: Apache-2.0 first-party; preserve all derived-source revisions and third-party notices in source, distribution, and notices UI.
- **C shims:** platform C helpers live in pure-C targets (`OpenGrokPTYC`, `OpenGrokCrashHandlerC`); SwiftPM does not allow mixed-language source trees in one target.
- **OTLP:** export bodies are real protobuf (`ExportTraceServiceRequest`), never JSON labeled `application/x-protobuf`.
- **Git status:** portable pure-Swift SHA-1; zlib via Compression (Apple) or linked `COpenGrokZlib`/libz; pack-only objects are explicit non-parity.

## Upstream drift since re-pin baseline

Between the old pin `9739c4a2ad23cfea14312a481169757f3da494f4` and the new pin `80dff0a9dcb24121b976b9f920fbe442af40ea88` upstream moved **202 commits** across releases `v0.1.220-open-grok.22` … `.53`, touching **1,515 files (+235,433 / −73,762)**. Everything below was verified against `/Users/mweinbach/Projects/grok-build` at `80dff0a9…` rather than taken from the release notes alone.

Ordered by how much it breaks data the Swift port already persists or decodes.

### 1. Data-layer breakage (fix before anything else)

- **Session storage.** `chat_format_version` is now a hard check rather than advisory, and a whole working-directory **relocation subsystem** landed with its own journal (`crates/codegen/xai-grok-shell/src/session/storage/relocation/{mod,journal,fs}.rs`). Workflow run manifests carry a supported version **range**. Swift `OpenGrokSessionPersistence` and the live session store under `$OPENGROK_HOME/sessions/` predate all of this.
- **Auth store.** Credential keys are now per-provider scoped (`wafer::api_key`, `kimi_code::api_key`, `perplexity::api_key`), a `SentCredential` provenance type records which credential was actually sent, `requires_manual_reauth` is persisted, and there is an explicit 401 retry budget. `OpenGrokAuth` and `OpenGrokSecrets` still assume the flat pre-scoping key layout.
- **Config schema.** New keys `worktree_auto_gc`, `workflows_enabled`, `image_edit_model_override`, a `[auth_provider.*]` table, hooks declared inline in `config.toml`, feature-flag settings (`crates/codegen/xai-grok-config-types/src/flags.rs`), and signed managed config. **Remote feature flags were removed entirely** — the old `feature_flags` surface in `xai-grok-config-types/src/lib.rs` at the previous pin is gone at HEAD, resolution is local config/env only. Any Swift code that plans to fetch remote flags should be deleted rather than ported.
- **Model catalog resolution.** Catalog code split into `crates/codegen/xai-grok-shell/src/agent/models/{cache,endpoint,fetch,resolution}.rs` (replacing the flat `cli_models.rs` / `codex_models.rs` / `fireworks_models.rs` / `kimi_models.rs` files at the old pin), with **changed resolution semantics**. `OpenGrokModels` mirrors the superseded layout.

### 2. Breaking behavioral rewrite: workflows

Workflows were rewritten onto a **native Rhai engine** in a new crate `crates/codegen/xai-workflow` (`engine.rs`, `host.rs`, `journal.rs`, `meta.rs`, `run.rs`, `validate.rs`; depends on `rhai`).

- The JavaScript workflow surface is gone: `crates/codegen/xai-grok-tools/src/implementations/grok_build/workflow/prelude.js` exists at the old pin and is absent at HEAD, and the workflow tool directory collapsed to a single `mod.rs`.
- Correction to the brief: `WorkflowToolInput` was **not** removed. It moved out of `xai-grok-tools/src/types/tool_io.rs` into `workflow/mod.rs` and survives as the tool's argument type. What was removed is the JS script layer, not the tool input.
- Runs are **always background** now, returning a run id immediately; `run_in_background: false` restores blocking inline results. Progress is pollable and lands in `<session>/workflows/<run_id>/progress.log`; kill is graceful and journals completed steps. Resume gained `resume_mode: "positional"` and `resume_through`, and journal keys ignore display-only `label`/`phase` changes.
- New TUI surfaces: a `/workflows` overlay and `/ultracode`.

The Swift `OpenGrokWorkflow` target was written against the pre-rewrite JS model and needs re-porting, not patching.

### 3. New crates (raising the mapped total 82 → 84)

- `crates/codegen/xai-workflow` — the Rhai workflow engine above.
- `crates/codegen/xai-grok-extra-ca` — opt-in extra TLS roots from `OPENGROK_EXTRA_CA_BUNDLE` (PEM path), default-off with no I/O when unset, parsed once into a `OnceLock`, additive to webpki roots, 1 MiB cap, and warn-and-continue on a bad bundle. Small and self-contained; a good early catch-up slice.

Both are mapped with proposed Swift targets in `CRATE_MAP.md`.

### 4. New providers, models, and sampling surface

- **New providers:** Wafer AI, DeepSeek (including the V4 Flash Responses dialect), OpenCode Go, and Kimi Code `k3` / `k3-256k` (`crates/codegen/xai-grok-sampler/src/{client,provider}.rs`).
- **Sampling types additions:** `tool_overrides`, `RedactedThinking`, cache-creation token accounting, and `stop_sequence`.
- Antigravity subagents; `/fast` Codex routing; per-subagent `reasoning_effort`; OpenAI image-generation tools; an LSP pull-diagnostics rewrite.
- A shared subagent coordinator actor now owns pending/active/completed state, waiters, the foreground await budget, buffered completions, and cancellation for every child kind (task, swarm member, workflow agent, Antigravity CLI run).

### 5. Product surface

`/tutorial` onboarding tour; a four-knob version policy (soft `minimum`/`maximum` steering the updater, hard `required_minimum`/`required_maximum` gating startup, fail-open, resolved from local config/env only); and Settings → Advanced exposure of previously config-only feature flags.

### Drift caveats

- The Swift port targets the **old** pin's behavior throughout. Nothing in this section is implemented on the Swift side; it is a catch-up backlog, not a status claim.
- `ProtocolFixtures/` still encodes old-pin wire formats (see the fixture pin caveat in the header). Recapture is a prerequisite for treating any of the above as fixture-verified.

## Known remaining gaps

1. **No current macOS verifier blocker** as of the last verifier run (2026-07-23): the serialized package, tests, product build, and executable smokes were green. Not re-run since.
2. **Reachability, not placeholders, is the real gap.** The executable is no longer bootstrap-only, but a large tested library surface is orphaned (see the live capability snapshot): Markdown, MCP, hooks, memory, voice, update, execution tools, sandbox, and every pager feature target are imported by nothing on the CLI path.
3. **The live agent streams and can write, but writes are gated off by default.** `run_terminal_cmd` plus the write-capable `.build` file pack (`read_file`, `list_dir`, `grep`, `glob`, `view_image`, `search_replace`, `write`, `apply_patch`) are wired through `PermissionPipeline`, and assistant text is forwarded as deltas. Mutations are refused unless `OPENGROK_ALLOW_WRITES=1` is set, because no interactive permission prompter exists yet — that prompter is the remaining work, not the tools.
4. **Codex is wired.** `resolveSamplingConfiguration` routes through `LiveCredentialResolver`, and account-pinning headers reach both the sampler and `ProviderSession`. Untested against a live Codex account: no end-to-end OAuth run has been performed, only isolated-store unit tests.
5. **`login`/`logout` now run** (including `--all`, `--codex`); the remaining non-launch routes still refuse after parsing.
6. **Few placeholders remain:** **7** true production stubs out of **99** (`OpenGrokCodeMode`, `OpenGrokJavaScriptRuntime`, `OpenGrokMermaid`, `OpenGrokMermaidLayout`, `OpenGrokDistributionSupport`, `OpenGrokReleaseValidation`, `OpenGrokPagerPTYHarness`), plus the four empty cross-cutting gate suites.
7. **The port is 202 commits behind upstream** with known data-layer breakage; see "Upstream drift since re-pin baseline".
8. **`ProtocolFixtures/` are stale** relative to the new pin and cannot ground parity claims until recaptured.
9. **Portability gaps remaining:** Windows ConPTY/Credential Manager/LockFileEx; full Linux Secret Service; pack object reading; full tree-sitter not in Package.swift; OTLP gRPC uses collector-shaped TraceService Export requests (path + framing + `grpc-status`) over `HTTPTransport` rather than a dedicated HTTP/2 tonic client—trailers depend on the transport surfacing them.
10. **Package-green ≠ Rust parity:** focused and integrated Swift tests do not prove full source-port behavior.
11. **Native Linux and Windows CI** remain absent; declared platform strategies are not CI-proven here.

## Verifier command record (required for green claims)

Only these commands may ground a green build/test claim:

```sh
zsh workflows/swift-safe-verify.zsh build
zsh workflows/swift-safe-verify.zsh build-tests
zsh workflows/swift-safe-verify.zsh test
zsh workflows/swift-safe-verify.zsh build --product open-grok
```

Record: commit ID, `swift --version`, platform, test totals, and exit codes when verify succeeds.

### Build-out wave 1 integration — 2026-08-04

Integration of four parallel slices (docs re-pin, TUI streaming + markdown,
write/edit tool pack, auth login/logout). **All changes are uncommitted in the
working tree**; the commit base below is the tree the changes sit on, not a
commit containing them.

- Commit base: `864afaa9342c434f8af39d6d813c6f4045ce173d`
- `swift --version`: Apple Swift 6.3.3 (`swift-6.3.3-RELEASE`), target `arm64-apple-macosx28.0`
- Platform: Darwin 27.0.0 arm64 (macOS), SDK macOS 27.0 from Xcode-beta

| Command | Exit |
|---|---|
| `swift-safe-verify.zsh build` | **0** |
| `swift-safe-verify.zsh build-tests` | **0** |
| `swift-safe-verify.zsh test` | **1** (see below) |
| `swift-safe-verify.zsh build --product open-grok` | **0** |

Test totals: **2157 tests in 319 suites**. `test` is **not green**. Two
pre-existing flaky tests account for every failure; no failure is attributable
to the integrated slices:

- `cancellationAndBoundedShutdown` (`OpenGrokShellTests.swift:221`,
  `counts.cancel == 0` vs `1`) — fails roughly **1 run in 5 even in complete
  isolation**. A genuine race in `OpenGrokShell`, a target no slice touched.
- `non-PTY spawn captures stdout` / `run without PTY (pipe path)` /
  `PlatformPTYAdapter spawns echo via PTY` (`OpenGrokPTY`, `OpenGrokPTYCLI`) —
  empty subprocess capture under load. Pass **4/4 in isolation**.

Run under `--no-parallel` the same tree yields **2157 tests with 1-2 issues**,
drawn only from that list (default parallel runs surface 9-10, and the failing
set varies run to run). Recorded as flaky-not-green rather than green.

Toolchain note: the run initially could not proceed at all. A swiftly
`swift-6.2-RELEASE` toolchain (target `macosx28.0`, `+assertions`) paired with
the Xcode-beta macOS 27.0 SDK **hangs indefinitely** rebuilding SDK module
interfaces — a three-line `import Foundation` file did not compile in 90s, and a
`swift-frontend` spun 13+ minutes of CPU inside
`ImplicitModuleInterfaceBuilder::buildSwiftModuleInternal` with no cache writes.
Swift 6.3.3 (installed mid-session) compiles the same file in 10s. Green above is
6.3.3; Xcode-beta's bundled Swift 6.4 also builds this tree.

Integration fixes required to reach the state above:

- `Package.swift` now declares `platforms: [.macOS(.v12)]`. Without it the Apple
  deployment target floats with the toolchain default (10.13) and
  `OpenGrokTestSupport`'s Network.framework use fails to compile.
- `Package.swift`: made three transitive edges explicit for `OpenGrokPager`
  (`OpenGrokMarkdown`, `OpenGrokPagerRender`, `OpenGrokTerminalCore`) and added
  `OpenGrokHTTP`, `OpenGrokWorkspace`, `OpenGrokMarkdown` to `OpenGrokCLI`.
- `OpenGrokPagerRender`: the new styled-span painter treated
  `CellBuffer.setString`'s return value as an absolute column; it returns the
  **width written**, so every span after the first painted over its predecessor.
  One bug, three failing new tests.
- `OpenGrokToolRegistry`: `prepareAndCall` reported the pipeline's internal audit
  code (`"permission_handle"`) instead of a denial's own message, so permission
  refusals reached the model as an opaque token.
- Two `compactMap` closures needed explicit result types under 6.3.3 inference.

Permission-gate decision (live file mutations): **fail-closed with an env
opt-in**. There is no parsed-but-ignored yolo/permission flag in
`CLICommandParser`, and `OpenGrokPagerInteractiveController` owns the input
stream with no seam for a mid-turn prompt, so no interactive prompter was wired.
Interactive and headless both install `.prompt(LiveWriteDenialPrompter())`: reads
and greps auto-allow, and every mutation is refused with a message naming
`OPENGROK_ALLOW_WRITES=1`, which switches the session to `.allowAll`. A prompter
is used rather than `.denyMutations` so the refusal is actionable. Read-only
agent profiles never see the mutating tools at all — that is the separate
`capabilityMode` listing gate.

#### Flake-fix addendum — 2026-08-04 (later the same day)

The `OpenGrokShell` cancellation race called out above is fixed. The suite is
green under `--no-parallel`; default parallel is still red on the pre-existing
PTY capture flake.

| Command | Exit | Result |
|---|---|---|
| `swift-safe-verify.zsh test --no-parallel` | **0** | 2157 tests, 319 suites, 0 issues, 47.472s |
| `swift-safe-verify.zsh test` (default parallel) ×3 | **1 / 1 / 1** | 2, 3 and 2 issues; 14.2–14.4s each |
| `--filter cancellationAndBoundedShutdown` ×20 isolated (two batches of 10) | **0** ×20 | the 1-in-5 race does not reproduce |
| `--filter "OpenGrokShellTests\|OpenGrokHooks"` after the PTY revert below | **0** | 31 tests, 0.071s |

**Shell cancellation race — fixed** (`Sources/OpenGrokShell/OpenGrokShell.swift`,
+62/−2). `submitTurn` returned a handle before its spawned task had entered the
driver's `beginTurn`, so a cancel arriving in that window called
`provider.cancelTurn` while the provider had no active turn: the request was
silently dropped (`counts.cancel == 0`) and the turn then ran to completion. The
provider session handed to the driver is now wrapped in an observer that reports
when the provider turn actually begins, and `cancelTurn`/`shutdown` wait for that
signal — bounded, so a driver that never begins a turn cannot wedge them — before
delivering the out-of-band cancel.

**Hook timeouts no longer block** (`Sources/OpenGrokHooks/HookRunner.swift`,
+20/−14). On timeout the runner reported `timed out after Nms` on schedule but
then blocked for the child's entire lifetime, because the racing task group
awaits its uncancellable `waitUntilExit` child when the group scope exits. The
wait is now poll-based and cancellable, and `terminate()` escalates to `SIGKILL`
after 200ms. `--filter OpenGrokHooks`: **30.1s → 0.079s** for 24 tests; the
timeout test itself went from 30.1s to 0.028s.

**PTY capture — diagnosed, not fixed; `OpenGrokPTY.swift` is at HEAD.** macOS
discards a terminal's output queue once the last slave descriptor closes, so a
short-lived child's output must be read *before it exits*. The reader polls from
the Swift cooperative pool and under parallel test load is not always scheduled
even once in that window; `finish(with:)` then closes the master and ends the
stream, so the bytes are already gone. Two attempts; the first stays reverted,
the second was re-landed (see below):

- A 341-line rework replacing the polling reader with a dedicated `poll` thread
  started before the child spawns. It fixed the loss but deadlocked: the stream
  then ended only on terminal EOF, so whenever an unrelated concurrently-spawned
  process inherited a pty slave descriptor the hangup never arrived and every
  consumer awaiting the stream waited forever. Preserved at
  `<scratch>/OpenGrokPTY-flakefix-rework.swift`.
- A minimal 43-line alternative (drain the master at reap before closing it,
  with the reader task and the drain serialized through a shared `readLock`).
  It preserves the original teardown, so it cannot hang, and it lowered the
  failure rate — but it does not close the window, because draining at reap
  still happens after the slave closed. Briefly reverted because the
  default-parallel suite was still red with it in; **re-landed** the same
  evening on the grounds that the parallel red is the identical pre-existing
  flake with or without it, while the drain fix removes a real data-loss cause
  and was covered by the `--no-parallel` green run.

Both artifacts are preserved durably in the (gitignored) repo directory
`.port-workflow/preserved/` — `OpenGrokPTY-flakefix-rework.swift` and
`OpenGrokPTY-drain-readlock.patch`.

A complete fix needs both halves: a reader woken on data arrival *and* stream
termination at child reap. Note the `--no-parallel` green above was measured
with both PTY fixes in the tree; it was re-confirmed green for the shell and
hooks scopes after the PTY revert.

Tests still failing under default parallel execution:

- `PlatformPTYAdapter spawns echo via PTY and captures output`,
  `run collects interactive PTY output`, `repeated launches leak-free`
  (`OpenGrokPTY`, `OpenGrokPTYCLI`) — empty subprocess capture, cause above.
- `branch collision detection for already-checked-out branch`
  (`OpenGrokFastWorktreeTests.swift:584`) — one run of three.

**Known issue — `spawnEchoUpstream` accept-loop deadlock.** A sampled stack of a
frozen test helper showed no PTY frames at all: the main thread was parked in the
runner's run loop and the only notable threads were blocked in `accept()` inside
`OpenGrokTestSupportTests.spawnEchoUpstream`
(`Tests/OpenGrokTestSupportTests/OpenGrokTestSupportTests.swift:1166`). That
fixture's accept loop and its per-connection reader loops never exit and the
listening socket is never closed, so the threads leak for the life of the
process. The cooperative pool was idle, meaning the suite was blocked on a
suspended async task with nothing to resume it. Not fixed in this pass.

**Measurement caveat.** Several runs recorded earlier that evening as "hung" or
"load-flaky" were measured while a stray load generator (64 busy-loop shells from
a flake-reproduction experiment, 18:35–19:33) saturated all 32 cores. Those
numbers are not trustworthy; every figure in the table above is from after the
machine was quiesced. Separately, red PTY runs are worth a second look before
being read as capture regressions: three of four scoped failures in that window
were `spawnFailed("openpty failed: ...")` — pty allocation refused because
SIGKILLed runs had left orphaned `/bin/sh` children holding slave descriptors.
Killing the orphans cleared it.

Also landed, outside the two assigned targets, all test-only: fixed sleeps
replaced with polling in `OpenGrokCodebaseGraphTests` (the 20ms debounce is not
observable within a fixed 80–120ms sleep under load), a longer producer stall in
`productionStreamMailboxBoundsPendingBytes`, a longer scheduling wait in the
`EnvVarGuard` concurrency test, and a longer sleep in the hooks timeout test so
its assertion cannot be won by a starved timer.

#### Combined-tree verification — 2026-08-05 (wave 1 + flake fixes + TUI parity)

Final verification over the full uncommitted working tree: the wave-1
integration, the shell-race/HookRunner/PTY-drain fixes, and the TUI design/logic
parity slice (Rust-pager-derived chrome, accent-rail tool cards, themes,
scrollback, input history, local slash commands, Esc/Ctrl-C semantics; spec and
divergences recorded by the slice; new golden-frame and keybinding tests).

| Command | Exit |
|---|---|
| `swift-safe-verify.zsh build` | **0** |
| `swift-safe-verify.zsh build-tests` | **0** |
| `swift-safe-verify.zsh test` (default parallel) | **1** — 2174 tests / 319 suites, 1 issue (known PTY capture flake class) |
| `swift-safe-verify.zsh test --no-parallel` ×3 | **0 / 1 / 0**, then a fourth run **0** — the single 1-issue serial run did not reproduce and its failing test was not captured |
| `swift-safe-verify.zsh build --product open-grok` | **0** |

Test count grew 2157 → **2174** (TUI parity tests). `--no-parallel` remains the
green gate; default parallel still surfaces the documented PTY capture flake
intermittently. The one-off serial issue is recorded as an unidentified
intermittent, not attributed to any slice — three surrounding serial runs on the
identical tree were clean.

#### Build-out wave 2 integration — 2026-08-05

Integration of two parallel slices — the overlay/modal framework in
`OpenGrokPagerRender` and SGR mouse decoding in `OpenGrokTerminalCore` — into the
live interactive path, plus the interactive permission modal those two enable.
**All changes are uncommitted in the working tree**; the commit base below is the
tree the changes sit on, not a commit containing them.

- Commit base: `9318be73d5110ba1bbc3203a2e6d3f7187d8313f`
- `swift --version`: Apple Swift 6.3.3 (`swift-6.3.3-RELEASE`), target `arm64-apple-macosx28.0`
- Platform: Darwin 27.0.0 arm64 (macOS)

| Command | Exit |
|---|---|
| `swift-safe-verify.zsh build` | **0** |
| `swift-safe-verify.zsh build-tests` | **0** |
| `swift-safe-verify.zsh test` (default parallel) | **1** ×2 — 2257 tests / 331 suites, 1 then 6 issues, all drawn from the documented flake set (`OpenGrokPTYTests`/`OpenGrokPTYCLITests` subprocess capture, `OpenGrokExecutionToolsTests` capture, `OpenGrokFastWorktreeTests` branch collision) |
| `swift-safe-verify.zsh test --no-parallel` | **0** ×3 — 2257 tests / 331 suites, 0 issues, 111.0 / 122.1 / 123.8s (a fourth, earlier serial run was red; see the caveat below) |
| `swift-safe-verify.zsh build --product open-grok` | **0** |

Test count grew 2174 → **2257** (+83; **8** of them the end-to-end integration
tests added in this pass — permission allow/deny/keyboard-nav/env-bypass, the
welcome screen, `/help`, `/model`, and mouse-reporting bracketing — the rest the
two slices' own suites). Scoped filters all green:
`OpenGrokPagerRenderTests` 61, `OpenGrokTerminalCoreTests` 79,
`OpenGrokPagerTests` 23, `OpenGrokCLITests` 11, and the wave-2
overlay/permission/mouse subset 8/8.

**What was wired.**

- **Overlay routing.** `LiveInteractiveControllerRenderer` owns a
  `PagerOverlayStack` and passes it into `PagerRenderState`. Input reaches it
  through a new `OpenGrokPagerInteractiveRenderAdapter.handleInput(_:)` that
  `OpenGrokPagerInteractiveController`'s input pump calls **before** the
  interrupt classifier and the prompt state machine; the default implementation
  returns `.notHandled`, so headless and test renderers are unchanged. `.selected`
  and `.permission` outcomes are handled inside the renderer, where the stack
  lives, rather than round-tripping through the controller.
- **Welcome screen.** Auto-pushed in `begin()` when the session starts with no
  history, with `capturesInput: false` so the composer beneath it stays live, and
  popped when the first turn starts.
- **`/help`** is now the "Keyboard Shortcuts" modal instead of a transcript dump.
  `/model` and `/toggle-mouse-reporting` were added to the command registry.
- **Permission modal replaces the env gate in interactive mode.** A shared
  `PagerPermissionCoordinator` is created per run; the interactive renderer
  installs itself as its presenter, and `LivePermissionModalPrompter` suspends
  the mutating tool on `decision(for:)`. "Allow for session" flips an actor-held
  session policy so a second mutation does not re-prompt.
- **Mouse.** `ANSIMouse.enableReporting` is written immediately inside `?1049h`
  and `ANSIMouse.trackingReset` immediately before `?1049l`, both in
  `PagerTerminalRenderer` (config flag `useMouseReporting`), so the disable
  always lands on the buffer that saw the enable. Signal and crash restore paths
  already emitted `?1000l…?1006l` before `?1049l` and needed no change. SGR
  reports are recovered from the TTY decoder's `.unknown(Data)` fallthrough and
  emitted as `InputEvent.mouse`. Wheel scrolls the transcript by
  `MouseWheelTuning.linesPerEvent` (per-terminal, from `TERM_PROGRAM`) through
  the existing scroll functions, so the overscroll-to-follow rule is inherited
  rather than re-implemented; wheel inside the focused overlay moves its
  selection one row per report. Clicks hit-test `PagerRenderResult.overlays`,
  read fresh every frame: a row click takes the same path as `Enter`, the close
  button dismisses, and a footer-hint click replays the key it names.

**Permission UX decisions.**

- `OPENGROK_ALLOW_WRITES=1` remains an explicit bypass that skips prompting
  entirely, ahead of the coordinator.
- Headless and non-TTY stay fail-closed with the same actionable denial message.
  The gate is `PagerPermissionCoordinator.hasPresenter` (added in integration)
  rather than a second construction path, so a tool can never suspend on a sheet
  nobody will paint.
- Ctrl+C and Ctrl+D are **exempt** from overlay routing. Every other key is
  swallowed by an active modal, but a permission sheet that trapped the session
  would be worse than the parity loss.
- Teardown resolves outstanding requests with `.deny` on turn cancel, EOF,
  shutdown, failure, and in `restoreTerminal()` — which detaches the presenter
  first, so anything arriving after teardown fails closed instead of suspending.

**Divergences.**

- The permission sheet renders a diff preview (`+`/`-` rows, 5 then `… +N`); the
  reference shows only `Allow {tool} to {path}?` and puts the diff in the
  transcript. Inherited from the overlay slice's brief; pass an empty
  `diffPreview` to match the reference. The live prompter currently passes none,
  because `PermissionPrompter` receives an `AccessKind`, not the hunks.
- `Enter` submits and `Tab` accepts a completion; the reference lets `Enter`
  accept the highlighted row.
- **No `Ctrl+R` mouse-reporting binding.** The reference registers it under
  `When::ScrollbackFocused` only. This port has a single focus region, so there
  is no way to distinguish it from the prompt's `Ctrl+R` history search;
  `/toggle-mouse-reporting` is the only entry point.
- `/toggle-mouse-reporting` is **always available**. The reference hides both it
  and its keybinding behind an opt-in feature flag
  (`[ui] mouse_reporting_toggle` / `GROK_MOUSE_REPORTING_TOGGLE`, default off,
  cached at startup); that flag is not ported. Reporting itself starts on in
  both.
- Wheel acceleration is not ported — one report is worth `linesPerEvent` lines
  with no rolling-window multiplier. The constants are recorded in
  `INTEGRATION-mouse.md`.
- **Legacy X10 mouse reports still leak.** SGR is recovered from
  `.unknown(Data)`, but `TerminalInputDecoder` treats `ESC [ M` as a complete CSI
  and its three coordinate bytes reach the text stream as ghost input. The fix is
  the prefilter described in `INTEGRATION-mouse.md` §2 — run `MouseStreamParser`
  ahead of `TerminalInputDecoder` on the raw byte stream — which needs a change
  inside `OpenGrokTTY`. Mitigated, not fixed, by enabling `?1006h` last.

**Deferred.**

- **Link clicks.** `PagerRenderResult.links` is published and the click path
  hit-tests overlays only; a click outside an overlay is dropped rather than
  opening a link. The reference also requires mouse-up on the same cell as
  mouse-down, which needs down-cell tracking that does not exist yet. No
  selection, drag, double/triple-click, or hover either.
- **Live model switch.** `/model` posts `Model set to X` and relabels the
  composer. The sampler's model is fixed at session construction and nothing
  downstream can change it mid-session, so the picker is honest about being
  advisory rather than silently inert.
- **Queued prompts / steering** (spec §14) — still unimplemented.

**Serial-run caveat.** The first `--no-parallel` run over this tree was **exit 1
with 1 issue**, at `LocalShellProcessBackendTests.swift:194`
("foreground block budget moves work into the background", a `sleep 1`
subprocess whose completion is awaited with a 5s budget). It is the same
load-sensitive subprocess class as the documented PTY flakes, it is outside every
target this wave touched, and it passed **5/5** re-run in isolation. Three
subsequent serial runs — including the last two over the exact final tree — were
clean. Recorded as a new member of the known flake set, not as a regression.

#### Build-out wave 3 — 2026-08-05 (final combined gates)

Four parallel slices, committed individually as each verified:

- `ad098d4` — complete PTY fix (pre-fork poll(2) reader + reap-or-EOF
  termination; 300/300 capture in the standalone probe vs 0/300 reading at
  reap) and the `spawnEchoUpstream` fixture lifecycle.
- `e2ea8f3` — upstream data-layer catch-up at the `80dff0a9` pin: scoped auth
  keys, new config schema with remote-flag removal, `chat_format_version`
  hard-check, workflow manifest version range, Kimi Code k3/k3-256k with
  endpoint-aware default selection.
- `e9935ea` — live `/model` switching (in-place rebuild, history preserved,
  fail-closed without credentials) and queued prompts via `OpenGrokPromptQueue`.
- `0097d9d` — Code Mode engine + persistent JavaScriptCore cell runtime,
  replacing the two largest placeholder targets. JSC cannot interrupt a running
  script on demand; termination closes the cell stream immediately and a
  per-entry execution ceiling reclaims the thread (hard interrupt would need a
  child process).

Final gates over the committed tree (Swift 6.3.3, Darwin 27.0.0 arm64):

| Command | Exit |
|---|---|
| `swift-safe-verify.zsh test` (default parallel) | **0** — 2395 tests / 363 suites, 23.4s |
| `swift-safe-verify.zsh test --no-parallel` | **0** — 2395 tests / 363 suites, 132.8s |
| `swift-safe-verify.zsh build --product open-grok` | **0** |

**Default parallel is green for the first time on merit** — the PTY capture
flake that dominated every prior parallel red is fixed at the mechanism level,
not suppressed. Test count 2257 → **2395** (+138). Remaining known flake
class: load-sensitive subprocess-completion budgets (see the serial-run caveat
above); members pass repeatedly in isolation.

Operational lessons recorded this wave: the two-lock problem (the verify
wrapper's lock dir plus SwiftPM's own `.build/workflow-safe` lock — a queued
run is indistinguishable from a hung one by CPU alone; check for SwiftPM's
"another instance" message), kill process groups rather than wrappers, and
`swift test --filter` with a zero-match regex exits 0 — verify reported test
counts, never exit codes alone.

Remaining placeholder targets: `OpenGrokMermaid`, `OpenGrokMermaidLayout`,
`OpenGrokDistributionSupport`, `OpenGrokReleaseValidation`,
`OpenGrokPagerPTYHarness`.

#### Build-out wave 4 — 2026-08-05 (Code Mode live, Rhai workflows, MCP/hooks, fixtures)

Five slices committed individually (`5ea18fb`, `1c143bf`, `64242c9`, `993efc4`,
`931667e`):

- Fixtures re-grounded at `80dff0a9` (per-family verified-unchanged or
  recaptured); `OpenGrokDistributionSupport` and `OpenGrokReleaseValidation`
  implemented (a CRLF fix matters: Swift models `\r\n` as one `Character`).
- The Rhai workflow engine ported with a working interpreter — both upstream
  built-ins (`ultracode`, `deep-research`) parse and execute end-to-end against
  a stub host; journal hashes pinned by independently-derived goldens. Agent
  execution remains an injected seam (not yet wired to live subagents).
- Code Mode wired into live sessions (direct/code_mode/code_mode_only; nested
  tools.* calls re-enter the full permission pipeline; transport projection;
  cells terminate on turn cancel — a documented divergence from Rust's
  cross-turn callback parking).
- MCP servers and hooks live: stdio transport and TOML config decoding were
  missing outright, not just unwired; `{server}__{tool}` naming per the Rust
  delimiter; an `AccessKind.mcpTool` misclassification meant `mcp` deny rules
  silently never matched (fixed); PreToolUse hooks gate dispatch through the
  locked order. `mcp add/remove` await a TOML serializer (parse-only today);
  Stop hooks await a turn-end seam.
- **`Process.waitUntilExit` is banned in this codebase.** It parks the calling
  thread's run loop on a death notification; a child exiting before the run
  loop is entered spends the notification and the wait never returns. This
  wedged two full `--no-parallel` runs (~3.5h each) while parallel stayed green
  by winning the race per-process; a standalone repro wedged within ~200 spawn
  iterations (preserved in `.port-workflow/preserved/repro*.swift`). Hook exit
  now arrives via `terminationHandler` bridged to a cancellable continuation.
  Grep for `waitUntilExit` before landing any process-spawning code.

Final gates over the committed tree (Swift 6.3.3): `test` parallel **0** —
2677 tests / 399 suites, 26s; `test --no-parallel` **0** ×2 — 152s / 153s;
`build --product open-grok` **0**. Test count 2395 → **2677** (+282).

Known traps left for a cleanup pass: `OpenGrokShared` and
`OpenGrokCodeModeProtocol` both extend `JSONValue` with `uint64Value` — a CLI
file importing both hits an ambiguous-member error; the `[ui] code_mode`
config path vs `RESTART_REQUIRED_PATHS` naming `["features","code_mode"]`
needs reconciling; `LocalShellProcessBackendTests.swift:194` remains a
load-sensitive budget flake (one pre-fix serial occurrence, green since).


## Per-crate port status (all 84 Rust crates accounted for)

Statuses below were re-verified on 2026-08-04 by measuring each Swift target's non-comment LOC, checking its test target for `@Test`/`func test*`, and grepping `^import <Target>$` across `Sources/` to establish reachability from the executable. Labels are no longer inherited from the slice reports that produced them.

Status legend:

- **pending** — bootstrap placeholder stub only (≤15 non-comment LOC).
- **in-progress** — real implementation started; scaffold or partial.
- **target-green** — implementation plus focused tests; not necessarily integrated-package green.
- **orphaned** — **new label.** Substantial implementation with passing tests that is imported by nothing on the `open-grok` executable path. Code exists; behavior does not ship. This is deliberately *not* folded into target-green, because target-green was being read as "works in the product".
- **live** — **new label.** Implementation is reachable from the running executable and exercised by `open-grok` launch.
- **ported** — historical Wave 0 label.
- **deferred-with-reason** — intentionally absorbed elsewhere.

| # | Rust crate | Swift target(s) | Status | Notes |
|---:|---|---|---|---|
| 1 | `dagre_rust` | `OpenGrokMermaidLayout` | pending | W8-S2 stub. |
| 2 | `graphlib_rust` | `OpenGrokMermaidLayout` | pending | W8-S2 stub. |
| 3 | `mermaid-to-svg` | `OpenGrokMermaidLayout`, `OpenGrokMermaid` | pending | W8-S2 stub. |
| 4 | `ordered_hashmap` | `OpenGrokMermaidLayout` | pending | W8-S2 stub. |
| 5 | `prod-mc-cli-chat-proxy-types` | `OpenGrokCLIChatProxyTypes` | ported | W0-S4. |
| 6 | `ptyctl` | `OpenGrokPTY` (+ `OpenGrokPTYC`) | in-progress | R09 + remediations; process-group readiness, signal masks, and cancellation-aware waits verified green. |
| 7 | `ptyctl-cli` | `OpenGrokPTYCLI` | in-progress | R09 diagnostics; full 14-test lifecycle suite green. |
| 8 | `xai-acp-lib` | `OpenGrokACP` | target-green | R02. |
| 9 | `xai-agent-lifecycle` | `OpenGrokAgentLifecycle` | target-green | R02. |
| 10 | `xai-chat-state` | `OpenGrokChatState` | target-green | R03; CompactionTranscript preserved. |
| 11 | `xai-circuit-breaker` | `OpenGrokCircuitBreaker` | target-green | R06 + remediation. |
| 12 | `xai-codebase-graph` | `OpenGrokCodebaseGraph` | in-progress | R08 parser port (not tree-sitter runtime). |
| 13 | `xai-computer-hub-core` | `OpenGrokComputerHubCore` | orphaned | 691 LOC + tests; reached only from the SDK/adapter/workspace-client cluster, which is itself unreachable from the CLI. Was mislabeled "pending". |
| 14 | `xai-computer-hub-mcp-adapter` | `OpenGrokComputerHubMCPAdapter` | orphaned | 346 LOC + tests; no importer. Was mislabeled "pending". |
| 15 | `xai-computer-hub-sdk` | `OpenGrokComputerHubSDK` | orphaned | 887 LOC + tests; imported only by `OpenGrokWorkspaceClient`. Was mislabeled "pending". |
| 16 | `xai-crash-handler` | `OpenGrokCrashHandler` (+ `OpenGrokCrashHandlerC`) | in-progress | R09 C sigaction/alt-stack shim. |
| 17 | `xai-fast-worktree` | `OpenGrokFastWorktree` | orphaned | 2,037 LOC + tests, but no importer; `worktree` CLI route refuses. |
| 18 | `xai-file-utils` | `OpenGrokFileUtils` | target-green | R07 + remediation. |
| 19 | `xai-fsnotify` | `OpenGrokFSNotify` | in-progress | R08 native adapters remediations. |
| 20 | `xai-gix-status` | `OpenGrokGitStatus` | in-progress | R08 + R10 portable SHA-1, COpenGrokZlib, pack non-parity. |
| 21 | `xai-grok-agent` | `OpenGrokAgentDefinitions` | live | 1,554 LOC + tests; imported by `OpenGrokCLI` and drives `--profile` agent-profile selection and live tool filtering. Was mislabeled "pending". |
| 22 | `xai-grok-announcements` | `OpenGrokAnnouncements` | orphaned | 403 LOC + tests; no importer. Was mislabeled "pending". |
| 23 | `xai-grok-auth` | `OpenGrokAuth` | live | 3,958 LOC + tests. Reached from the CLI as of the 2026-08-04 wave-1 integration: `login`/`logout` run through `LiveAuthComposition`, and `resolveSamplingConfiguration` resolves credentials via `LiveCredentialResolver`. Not exercised against a live Codex account. |
| 24 | `xai-grok-code-mode` | `OpenGrokCodeMode`, `OpenGrokJavaScriptRuntime` | pending | W6-S1 stub. |
| 25 | `xai-grok-code-mode-protocol` | `OpenGrokCodeModeProtocol` | target-green | R05 + remediation. |
| 26 | `xai-grok-compaction` | `OpenGrokCompaction` | in-progress | 1,481 LOC + tests, reachable via `OpenGrokProviderSession`. Was mislabeled "pending". |
| 27 | `xai-grok-config` | `OpenGrokConfig` | target-green | R04 + remediation (portable Ed25519, authority, TOML). |
| 28 | `xai-grok-config-types` | `OpenGrokConfigTypes` | target-green | R04 + remediation fixtures. |
| 29 | `xai-grok-env` | `OpenGrokEnvironment` | ported | W0-S3. |
| 30 | `xai-grok-hooks` | `OpenGrokHooks` | orphaned | 1,447 LOC + tests; no importer. The permission pipeline's `PreToolUse` stage therefore does not run in the product. Was mislabeled "pending". |
| 31 | `xai-grok-http` | `OpenGrokHTTP` | in-progress | R06 + remediation; integrated async lock fix verified green. |
| 32 | `xai-grok-markdown` | `OpenGrokMarkdown` | orphaned | 754 LOC + tests; no importer, so the TUI renders assistant replies as plain text. Was mislabeled "pending". |
| 33 | `xai-grok-markdown-core` | `OpenGrokMarkdownCore` | orphaned | 1,033 LOC + tests; imported only by `OpenGrokMarkdown`. Was mislabeled "pending". |
| 34 | `xai-grok-markdown-fuzz` | `OpenGrokFuzzingTests` | pending | Test target exists but contains zero tests. |
| 35 | `xai-grok-mcp` | `OpenGrokMCP` | orphaned | 1,798 LOC + tests; no importer, and the `mcp` CLI route refuses. Was mislabeled "pending". |
| 36 | `xai-grok-memory` | `OpenGrokMemory` | orphaned | 1,159 LOC + tests; no importer, and the `memory` CLI route refuses. Was mislabeled "pending". |
| 37 | `xai-grok-mermaid` | `OpenGrokMermaid` | pending | W8-S2 stub. |
| 38 | `xai-grok-models` | `OpenGrokModels` | in-progress | Metadata decoding and CFBoolean/NSNumber remediation integrated. |
| 39 | `xai-grok-pager` | `OpenGrokPager` (live) · `OpenGrokPagerModel`, `OpenGrokPagerRuntime`, `OpenGrokPagerConversationUI`, `OpenGrokPagerCommandUI`, `OpenGrokPagerOperationsUI` (orphaned) | split | The `OpenGrokPager` facade (1,227 LOC) is imported by the CLI, but the five feature targets behind it (866/466/353/321/508 LOC, all tested) have no importer. Was mislabeled "pending" for the whole crate. |
| 40 | `xai-grok-pager-bin` | `OpenGrokCLI`, `OpenGrokExecutable`, `OpenGrokDistributionSupport` | live (partial) | `OpenGrokCLI` is 3,534 LOC and now hosts the working live agent composition; `OpenGrokExecutable` is a 15-line `main`. `OpenGrokDistributionSupport` remains a 1-line placeholder, so completions/distribution are absent. |
| 41 | `xai-grok-pager-minimal` | `OpenGrokPagerMinimal` | live | 287 LOC + tests; imported by the CLI and the pager facade; backs `--minimal`. Was mislabeled "pending". |
| 42 | `xai-grok-pager-pty-harness` | `OpenGrokPagerPTYHarness`, `OpenGrokPagerPTYTests` | pending | Genuine 1-line placeholder; PTY E2E test target has zero tests. |
| 43 | `xai-grok-pager-render` | `OpenGrokPagerRender` | live | 1,399 LOC + tests; provides the cell-diffed alt-screen renderer used by the live TUI. Was mislabeled "pending". |
| 44 | `xai-grok-paths` | `OpenGrokPaths` | ported | W0-S3. |
| 45 | `xai-grok-plugin-marketplace` | `OpenGrokPluginMarketplace` | orphaned | 1,058 LOC + tests; no importer, and the `plugin` CLI route refuses. Was mislabeled "pending". |
| 46 | `xai-grok-sampler` | `OpenGrokSampler` | live (partial) | 5,106 LOC + tests; drives the live agent for xAI/Kimi/Fireworks. `StreamChatCompletions`/`StreamResponses`/`StreamMessages` exist but the live path calls `conversationCollect`, so streaming ships unused. |
| 47 | `xai-grok-sampling-types` | `OpenGrokSamplingTypes` | target-green | R03. |
| 48 | `xai-grok-sandbox` | `OpenGrokSandbox` | orphaned | 1,805 LOC + tests, well past "scaffold", but no importer — the live agent runs `run_terminal_cmd` outside any sandbox enforcement. |
| 49 | `xai-grok-secrets` | `OpenGrokSecrets` | target-green | R07 + remediation. |
| 50 | `xai-grok-shared` | `OpenGrokShared` | ported | W0-S4. |
| 51 | `xai-grok-shell` | `OpenGrokShell`, `OpenGrokACPRuntime`, `OpenGrokSessionPersistence`, `OpenGrokProviderSession` (live) · `OpenGrokSessionRuntime`, `OpenGrokAgentCoordinator`, `OpenGrokGoalState` (orphaned) | split | `OpenGrokShell` (1,364 LOC) is imported by the CLI and pulls in ACP runtime, session persistence, and provider session. `OpenGrokSessionRuntime` (282) and its dependents `OpenGrokAgentCoordinator` (328) and `OpenGrokWorkflow` have no importer. `OpenGrokGoalState` (1,271 LOC + tests) is unreferenced. Was mislabeled "pending". |
| 52 | `xai-grok-shell-base` | `OpenGrokShellBase` | live | 2,194 LOC + tests; imported by the CLI and `OpenGrokShell`. Was mislabeled "pending". |
| 53 | `xai-grok-shell-session-support` | `OpenGrokShellSessionSupport` | live | 1,880 LOC + tests; imported by `OpenGrokShell`, backing `--session-id`/`--resume`/`--continue`/`--fork-session` persistence under `$OPENGROK_HOME/sessions/`. Was mislabeled "pending". |
| 54 | `xai-grok-subagent-resolution` | `OpenGrokSubagentResolution` | orphaned | 1,422 LOC + tests; no importer. Was mislabeled "pending". |
| 55 | `xai-grok-telemetry` | `OpenGrokTelemetry` | target-green | R06 + R10 real OTLP protobuf + TraceService gRPC path/framing (async export). |
| 56 | `xai-grok-test-support` | `OpenGrokTestSupport` | ported | W0-S2. |
| 57 | `xai-grok-tools` | `OpenGrokToolRegistry`, `OpenGrokFileTools` (live) · `OpenGrokExecutionTools`, `OpenGrokWebMediaTools`, `OpenGrokAgentControlTools` (orphaned) | split | The registry (1,888 LOC) and file tools (1,425 LOC) are on the live path, but only the read-only `.explore` preset (`read_file`, `list_dir`, `grep`) is exposed; `run_terminal_cmd` is defined inline in `LiveComposition.swift` rather than sourced from `OpenGrokExecutionTools` (923 LOC, unimported). `OpenGrokWebMediaTools` (1,909) and `OpenGrokAgentControlTools` (76, thin) are unimported. **No write or edit tool is wired.** Was mislabeled "pending". |
| 58 | `xai-grok-tools-api` | `OpenGrokToolsAPI` | target-green | R01. |
| 59 | `xai-grok-update` | `OpenGrokUpdate` | orphaned | 893 LOC + tests; no importer, and the `update` CLI route refuses. Was mislabeled "pending". |
| 60 | `xai-grok-version` | `OpenGrokVersion` | ported | W0-S3 + build plugin. |
| 61 | `xai-grok-voice` | `OpenGrokVoice` | orphaned | 1,352 LOC + tests; no importer. Was mislabeled "pending". |
| 62 | `xai-grok-workspace` | `OpenGrokWorkspace` | live (partial) | 2,669 LOC + tests, reachable via `OpenGrokToolRegistry`/`OpenGrokFileTools`/`OpenGrokACPRuntime`. The permission engine exists but the live tool set is read-only, so the gate order is not yet exercised end to end on a mutating operation. |
| 63 | `xai-grok-workspace-client` | `OpenGrokWorkspaceClient` | orphaned | 238 LOC + tests; no importer. |
| 64 | `xai-grok-workspace-types` | `OpenGrokWorkspaceTypes` | target-green | R05 + remediation; CodingKey fix in integration. |
| 65 | `xai-hooks-plugins-types` | `OpenGrokHooksPluginTypes` | target-green | R05 + remediation. |
| 66 | `xai-hunk-tracker` | `OpenGrokHunkTracker` | in-progress | R08 + remediation. |
| 67 | `xai-interjection-core` | `OpenGrokInterjection` | target-green | R02. |
| 68 | `xai-mixpanel` | `OpenGrokTelemetry` | deferred-with-reason | Absorbed into telemetry. |
| 69 | `xai-prompt-queue` | `OpenGrokPromptQueue` | target-green | R02. |
| 70 | `xai-proto-build` | `OpenGrokBuildSupport`, `OpenGrokProtoBuildPlugin` | ported | W0-S1. |
| 71 | `xai-ratatui-inline` | `OpenGrokTerminalCore` | in-progress | Scaffold; W2-S5. |
| 72 | `xai-ratatui-textarea` | `OpenGrokTextArea` | in-progress | Editing behavior and overflow-safe optimal wrapping remediations integrated. |
| 73 | `xai-sqlite-journal` | `OpenGrokSQLiteJournal` | target-green | R07 + remediation. |
| 74 | `xai-system-power` | `OpenGrokSystemPower` | in-progress | R09 + integration concurrency/IOKit fixes. |
| 75 | `xai-test-utils` | `OpenGrokTestUtilities` | ported | W0-S2. |
| 76 | `xai-token-estimation` | `OpenGrokTokenEstimation` | target-green | R03. |
| 77 | `xai-tool-protocol` | `OpenGrokToolProtocol` | target-green | R01. |
| 78 | `xai-tool-runtime` | `OpenGrokToolRuntime` | target-green | R01. |
| 79 | `xai-tool-types` | `OpenGrokToolTypes` | target-green | R01. |
| 80 | `xai-tracing` | `OpenGrokTracing` | target-green | R06 + exact-once span remediation. |
| 81 | `xai-tracing-macros` | `OpenGrokTracing` | deferred-with-reason | Absorbed into tracing APIs. |
| 82 | `xai-tty-utils` | `OpenGrokTTY` | live | 1,385 LOC + tests; imported by the CLI for raw mode and terminal capability detection. |
| 83 | `xai-workflow` | *(proposed)* `OpenGrokWorkflowEngine` | not started | **New upstream crate at the `80dff0a9…` re-pin.** Native Rhai workflow engine (`engine`/`host`/`journal`/`meta`/`run`/`validate`). The existing `OpenGrokWorkflow` target (1,296 LOC) was ported against the removed JS workflow model and needs re-porting, not extension. See "Upstream drift". |
| 84 | `xai-grok-extra-ca` | *(proposed)* `OpenGrokExtraCA` | not started | **New upstream crate at the `80dff0a9…` re-pin.** Opt-in extra TLS roots from `OPENGROK_EXTRA_CA_BUNDLE`; default-off, 1 MiB cap, warn-and-continue. Small, self-contained, no dependents — a good first catch-up slice. |

Rows 83–84 are appended in discovery order rather than inserted alphabetically, so existing row numbers stay stable across the re-pin.

**Status tally (crate table, 2026-08-04):** **live / live-partial ≈ 14** (reachable from the running executable) · **orphaned ≈ 18** (implemented and tested, imported by nothing on the CLI path) · **target-green / ported ≈ 30** (contract and foundation targets consumed transitively) · **in-progress ≈ 12** · **pending ≈ 6** · **deferred-with-reason = 2** · **not started = 2** (the new upstream crates) · **total 84** Rust crates.

Separate **source-target** inventory: **8 / 99** targets match the ≤15-LOC placeholder rule (**7** genuine placeholders plus the thin `main`), and **12 / 101** test targets have no tests. The former **42 / 98** and **46 / 100** figures are superseded.

Read the tally with care in both directions. The placeholder count fell from 42 to 7 because real implementations landed, but "orphaned ≈ 18" is the offsetting truth: roughly a fifth of the crate map is code that compiles and passes its own tests while contributing nothing to `open-grok` behavior. Neither target-green nor a low placeholder count is executable product parity.

## Next action

The work has moved from "fill in placeholders" to "connect implemented code to the executable". Three slices are **in progress in parallel**; they touch disjoint paths and are not sequenced behind one another.

### Active build-out wave (in progress, parallel)

1. **TUI streaming + markdown.** Switch the live loop from `conversationCollect` to the existing `StreamChatCompletions`/`StreamResponses`/`StreamMessages` paths, and wire `OpenGrokMarkdown`/`OpenGrokMarkdownCore` into `PagerTerminalRenderer` so replies render incrementally as formatted text instead of arriving as one plain-text block. Both dependencies are already implemented and tested; this is composition work.
2. **Write/edit tools behind the permission engine.** Expand the live tool set beyond the read-only `.explore` pack to the write/patch/edit tools in `OpenGrokFileTools`, routed through `OpenGrokWorkspace`'s permission engine in the documented gate order, with `OpenGrokHooks` supplying `PreToolUse` and hunk attribution recorded only after success. This is the first slice that exercises the gate order on a mutating operation.
3. **`login`/`logout` + Codex provider enablement.** Implement the two auth routes against `OpenGrokAuth` and remove the two `unsupported(route: "Codex OAuth provider")` rejections in `resolveSamplingConfiguration`, so the already-complete Codex OAuth/PKCE/device-code implementation becomes reachable.

### Then, in order

4. **Upstream catch-up** against the new `80dff0a9…` pin, data layer first: session storage (`chat_format_version` hard check, relocation subsystem and journal), auth store (scoped keys, `SentCredential`, `requires_manual_reauth`, 401 budget), config schema (new keys, `[auth_provider.*]`, local-only feature flags with remote flags deleted), and model resolution (`agent/models/{cache,endpoint,fetch,resolution}`). Recapture `ProtocolFixtures/` at the new ref before claiming any of it verified. Then the workflow re-port onto the Rhai engine, then the new providers and sampling-type additions. Full detail in "Upstream drift since re-pin baseline".
5. **Code Mode and the JavaScript runtime** (`OpenGrokCodeMode`, `OpenGrokJavaScriptRuntime`), plus the remaining stubs: `OpenGrokMermaid`/`OpenGrokMermaidLayout`, `OpenGrokDistributionSupport`, `OpenGrokReleaseValidation`, `OpenGrokPagerPTYHarness`.
6. **Reconnect the remaining orphans** — MCP, memory, voice, update, plugin marketplace, sandbox, worktrees, and the pager feature targets — by implementing their refusing CLI routes.
7. **Native Linux and Windows CI**, then close platform-specific capability gaps.
8. Throughout: preserve `CompactionTranscript.swift`, workflow artifacts, and serialized verifier discipline.

## Protected artifacts

- `Sources/OpenGrokChatState/CompactionTranscript.swift` JSONValue pattern correction — **do not revert**.
- Registered workflow `.opengrok/workflows/swift-open-grok-safe-resume.rhai`, legacy harness `workflows/run-grok45-port.zsh`, safe verifier `workflows/swift-safe-verify.zsh`, and `.gitignore` entries for `.port-workflow` / scratch builds — retained.
- C helper targets `OpenGrokPTYC` and `OpenGrokCrashHandlerC` are required Package.swift edges for R09 shims.
