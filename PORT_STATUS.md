# Swift Open Grok Port Status

**As of:** 2026-07-22 (R10 foundation remediation)
**Overall state:** Wave 0 foundations and Wave 1–2 contract/infrastructure slices R01–R09 have substantial target-level implementations. **Integrated package build is still not verified green** under the sole safe verifier for the current working tree after R10 static foundation fixes (async OTLP export, collector-shaped gRPC TraceService path, real binary ProtocolFixtures, exact inventory counts, workflow SwiftPM ban). Executable product and full `swift test` remain blocked until the integration agent re-runs `zsh workflows/swift-safe-verify.zsh`.
**Destination was empty at baseline:** yes.
**Reference:** `xai-org/grok-build` at `9739c4a2ad23cfea14312a481169757f3da494f4` (`/tmp/open-grok-reference` when present).
**Swift toolchain used:** Apple Swift 6.4 (`swift-tools-version: 6.1`, `swiftLanguageModes: [.v6]`).
**Base commit before R10 edits:** `93584585eb038c155fbc773ad287f6ee2b043ff4`.

## Inventory counting method (reproducible)

Counts are mechanical over the committed tree (no Package.swift parsing):

1. **Production source targets** = directories under `Sources/` → **98**.
2. **Test targets** = directories under `Tests/` → **100**.
3. **Bootstrap placeholder production targets** = source directories whose Swift sources total **≤15 non-comment, non-blank lines** (classic empty-module stubs), **excluding** pure C helper targets `COpenGrokZlib`, `OpenGrokPTYC`, and `OpenGrokCrashHandlerC` (real C implementations, not placeholders) → **42**.
4. **Zero-test targets** = test directories with **no** `@Test` and **no** `func test[A-Z_]` in any `.swift` file → **46**.
5. **Non-placeholder production targets** = 98 − 42 = **56**. **Test targets with ≥1 test** = 100 − 46 = **54**.

## Honest integration snapshot (2026-07-22 / R10)

| Check | Result |
|---|---|
| `zsh workflows/swift-safe-verify.zsh build` (prior iter 1–3) | **Fail** historically (PTY mixed language → crash C/`HookEvent`/`SystemPower` → HTTP `NSLock` in async) |
| Post-iter-3 HTTP lock-box fix | Present in tree; **not re-verified** under the three-iteration cap before R10 |
| R10 static foundation fixes (this pass) | Async OTLP `exportSpan`/`exportOpenTelemetry`; real OTLP protobuf + gRPC TraceService path/framing/`grpc-status`; GitStatus pure SHA-1 + `COpenGrokZlib`; pack non-parity; CLI → `OpenGrokVersion`; ProtocolFixtures binary goldens + foundation formats; exact inventory; workflows ban bare SwiftPM |
| `swift build --build-tests` / `swift test` / product | **Not run in R10** (workers forbidden; sole integration agent owns verify) |
| Executable version/help/paths smokes | **Blocked** until product builds; composition tests cover CLI surface |
| CompactionTranscript.swift JSONValue correction | **Preserved** (do not revert) |
| Placeholder production targets | **42 / 98** bootstrap placeholders (≤15 non-comment LOC; see counting method) |
| Zero-test test targets | **46 / 100** (no `@Test` / `func test*`); **54** targets have executable tests |

### R10 foundation changes (static; pending integrated verify)

- `OpenGrokTelemetry`: `ExportTraceServiceRequest` protobuf encoder; product + external HTTP use `application/x-protobuf` with real protobuf; gRPC uses TraceService Export RPC path + framed protobuf + `grpc-status` validation; `exportSpan`/`exportOpenTelemetry` are async and await `HTTPTransport.send`; JSON twin only for diagnostics.
- `OpenGrokGitStatus`: removed CryptoKit; pure-Swift `PortableSHA1`; C target `COpenGrokZlib` (links libz) declared in `Package.swift`; pack-only objects throw `packedObjectUnsupported` (not silent empty HEAD).
- `OpenGrokCLI` version delegates to `OpenGrokVersion.installed` (empty `GROK_TEST_VERSION` parity).
- Tests: ToolRuntime assertion fixed; executable composition suites; telemetry MockHTTPTransport gRPC collector-compat + golden fixture re-encode; BuildSupport semantic fixture decode.
- `ProtocolFixtures/`: binary OTLP HTTP/gRPC goldens, git loose-object zlib, GCRX crash sample, tracing/storage/hunk/PTY/crash format fixtures + provenance + manifest at ref `9739c4a2…`.
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
| 1 | Protocols, domain models, and configuration | **In progress / target-level** — R01–R05; integrated graph not green | Wave 0 required slices present |
| 2 | HTTP, storage, FS/Git/graph, PTY/TTY/power/crash | **In progress** — R06–R09 + R10 wire/portability fixes; integrated verify incomplete | Wave 1 contracts usable |
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

## Known verification blockers

1. **Integrated build not re-verified** after HTTP async-lock + R10 foundation edits. Next sole integration agent must run `zsh workflows/swift-safe-verify.zsh build` then `build-tests`, `test`, and product smokes.
2. **Executable product not emitted until graph green:** `open-grok` depends on Shell/Pager composition stubs still present for later waves.
3. **Many placeholders remain** for later-wave runtime (providers, MCP runtime, TUI, session persistence, sandbox, etc.) — **42 / 98** production bootstrap stubs (counting method above).
4. **Portability gaps remaining:** Windows ConPTY/Credential Manager/LockFileEx; full Linux Secret Service; pack object reading; full tree-sitter not in Package.swift; OTLP gRPC uses collector-shaped TraceService Export requests (path + framing + `grpc-status`) over `HTTPTransport` rather than a dedicated HTTP/2 tonic client—trailers depend on the transport surfacing them.
5. **Target-green ≠ product parity:** focused slice harnesses do not prove integrated package green.
6. **Linux CI** still absent; SQLite/`COpenGrokZlib` strategy declared but not CI-proven here.

## Verifier command record (required for green claims)

Only these commands may ground a green build/test claim:

```sh
zsh workflows/swift-safe-verify.zsh build
zsh workflows/swift-safe-verify.zsh build-tests
zsh workflows/swift-safe-verify.zsh test
zsh workflows/swift-safe-verify.zsh build --product open-grok
```

Record: commit ID, `swift --version`, platform, test totals, and exit codes when verify succeeds.


## Per-crate port status (all 82 Rust crates accounted for)

Status legend: **pending** (bootstrap placeholder stub only) · **in-progress** (real implementation started; scaffold or partial) · **target-green** (implementation + focused tests reported by slice; not necessarily integrated-package green) · **ported** (historical Wave 0 “ported” label) · **deferred-with-reason**.

| # | Rust crate | Swift target(s) | Status | Notes |
|---:|---|---|---|---|
| 1 | `dagre_rust` | `OpenGrokMermaidLayout` | pending | W8-S2 stub. |
| 2 | `graphlib_rust` | `OpenGrokMermaidLayout` | pending | W8-S2 stub. |
| 3 | `mermaid-to-svg` | `OpenGrokMermaidLayout`, `OpenGrokMermaid` | pending | W8-S2 stub. |
| 4 | `ordered_hashmap` | `OpenGrokMermaidLayout` | pending | W8-S2 stub. |
| 5 | `prod-mc-cli-chat-proxy-types` | `OpenGrokCLIChatProxyTypes` | ported | W0-S4. |
| 6 | `ptyctl` | `OpenGrokPTY` (+ `OpenGrokPTYC`) | in-progress | R09 + remediations; C spawn shim target. |
| 7 | `ptyctl-cli` | `OpenGrokPTYCLI` | in-progress | R09 diagnostics. |
| 8 | `xai-acp-lib` | `OpenGrokACP` | target-green | R02. |
| 9 | `xai-agent-lifecycle` | `OpenGrokAgentLifecycle` | target-green | R02. |
| 10 | `xai-chat-state` | `OpenGrokChatState` | target-green | R03; CompactionTranscript preserved. |
| 11 | `xai-circuit-breaker` | `OpenGrokCircuitBreaker` | target-green | R06 + remediation. |
| 12 | `xai-codebase-graph` | `OpenGrokCodebaseGraph` | in-progress | R08 parser port (not tree-sitter runtime). |
| 13 | `xai-computer-hub-core` | `OpenGrokComputerHubCore` | pending | W4-S4 stub. |
| 14 | `xai-computer-hub-mcp-adapter` | `OpenGrokComputerHubMCPAdapter` | pending | W5-S4 stub. |
| 15 | `xai-computer-hub-sdk` | `OpenGrokComputerHubSDK` | pending | W4-S4 stub. |
| 16 | `xai-crash-handler` | `OpenGrokCrashHandler` (+ `OpenGrokCrashHandlerC`) | in-progress | R09 C sigaction/alt-stack shim. |
| 17 | `xai-fast-worktree` | `OpenGrokFastWorktree` | pending | W4-S2 stub. |
| 18 | `xai-file-utils` | `OpenGrokFileUtils` | target-green | R07 + remediation. |
| 19 | `xai-fsnotify` | `OpenGrokFSNotify` | in-progress | R08 native adapters remediations. |
| 20 | `xai-gix-status` | `OpenGrokGitStatus` | in-progress | R08 + R10 portable SHA-1, COpenGrokZlib, pack non-parity. |
| 21 | `xai-grok-agent` | `OpenGrokAgentDefinitions` | pending | W5-S6 stub. |
| 22 | `xai-grok-announcements` | `OpenGrokAnnouncements` | pending | W5-S6 stub. |
| 23 | `xai-grok-auth` | `OpenGrokAuth` | pending | W3-S1 stub. |
| 24 | `xai-grok-code-mode` | `OpenGrokCodeMode`, `OpenGrokJavaScriptRuntime` | pending | W6-S1 stub. |
| 25 | `xai-grok-code-mode-protocol` | `OpenGrokCodeModeProtocol` | target-green | R05 + remediation. |
| 26 | `xai-grok-compaction` | `OpenGrokCompaction` | pending | W6-S2 stub. |
| 27 | `xai-grok-config` | `OpenGrokConfig` | target-green | R04 + remediation (portable Ed25519, authority, TOML). |
| 28 | `xai-grok-config-types` | `OpenGrokConfigTypes` | target-green | R04 + remediation fixtures. |
| 29 | `xai-grok-env` | `OpenGrokEnvironment` | ported | W0-S3. |
| 30 | `xai-grok-hooks` | `OpenGrokHooks` | pending | W5-S5 stub. |
| 31 | `xai-grok-http` | `OpenGrokHTTP` | in-progress | R06 + remediation; integrated async lock fix pending re-verify. |
| 32 | `xai-grok-markdown` | `OpenGrokMarkdown` | pending | W8-S1 stub. |
| 33 | `xai-grok-markdown-core` | `OpenGrokMarkdownCore` | pending | W8-S1 stub. |
| 34 | `xai-grok-markdown-fuzz` | `OpenGrokFuzzingTests` | pending | W11-S4 stub. |
| 35 | `xai-grok-mcp` | `OpenGrokMCP` | pending | W5-S4 stub. |
| 36 | `xai-grok-memory` | `OpenGrokMemory` | pending | W6-S3 stub. |
| 37 | `xai-grok-mermaid` | `OpenGrokMermaid` | pending | W8-S2 stub. |
| 38 | `xai-grok-models` | `OpenGrokModels` | pending | W3-S2 stub. |
| 39 | `xai-grok-pager` | multi-target | pending | W8–W10 stubs. |
| 40 | `xai-grok-pager-bin` | `OpenGrokCLI`, `OpenGrokExecutable`, `OpenGrokDistributionSupport` | in-progress | Bootstrap CLI + R10 version parity/exec tests; product blocked by graph. |
| 41 | `xai-grok-pager-minimal` | `OpenGrokPagerMinimal` | pending | W9-S5 stub. |
| 42 | `xai-grok-pager-pty-harness` | `OpenGrokPagerPTYHarness`, `OpenGrokPagerPTYTests` | pending | W11-S3 stub. |
| 43 | `xai-grok-pager-render` | `OpenGrokPagerRender` | pending | W8-S3 stub. |
| 44 | `xai-grok-paths` | `OpenGrokPaths` | ported | W0-S3. |
| 45 | `xai-grok-plugin-marketplace` | `OpenGrokPluginMarketplace` | pending | W5-S5 stub. |
| 46 | `xai-grok-sampler` | `OpenGrokSampler` | pending | W3-S3 stub. |
| 47 | `xai-grok-sampling-types` | `OpenGrokSamplingTypes` | target-green | R03. |
| 48 | `xai-grok-sandbox` | `OpenGrokSandbox` | in-progress | Scaffold. |
| 49 | `xai-grok-secrets` | `OpenGrokSecrets` | target-green | R07 + remediation. |
| 50 | `xai-grok-shared` | `OpenGrokShared` | ported | W0-S4. |
| 51 | `xai-grok-shell` | multi-target | pending | W6–W8 stubs. |
| 52 | `xai-grok-shell-base` | `OpenGrokShellBase` | pending | W6-S4 stub. |
| 53 | `xai-grok-shell-session-support` | `OpenGrokShellSessionSupport` | pending | W6-S4 stub. |
| 54 | `xai-grok-subagent-resolution` | `OpenGrokSubagentResolution` | pending | W6-S5 stub. |
| 55 | `xai-grok-telemetry` | `OpenGrokTelemetry` | target-green | R06 + R10 real OTLP protobuf + TraceService gRPC path/framing (async export). |
| 56 | `xai-grok-test-support` | `OpenGrokTestSupport` | ported | W0-S2. |
| 57 | `xai-grok-tools` | multi-target | pending | W5 stubs. |
| 58 | `xai-grok-tools-api` | `OpenGrokToolsAPI` | target-green | R01. |
| 59 | `xai-grok-update` | `OpenGrokUpdate` | pending | W5-S6 stub. |
| 60 | `xai-grok-version` | `OpenGrokVersion` | ported | W0-S3 + build plugin. |
| 61 | `xai-grok-voice` | `OpenGrokVoice` | pending | W5-S6 stub. |
| 62 | `xai-grok-workspace` | `OpenGrokWorkspace` | pending | W4-S3 stub. |
| 63 | `xai-grok-workspace-client` | `OpenGrokWorkspaceClient` | pending | W4-S4 stub. |
| 64 | `xai-grok-workspace-types` | `OpenGrokWorkspaceTypes` | target-green | R05 + remediation; CodingKey fix in integration. |
| 65 | `xai-hooks-plugins-types` | `OpenGrokHooksPluginTypes` | target-green | R05 + remediation. |
| 66 | `xai-hunk-tracker` | `OpenGrokHunkTracker` | in-progress | R08 + remediation. |
| 67 | `xai-interjection-core` | `OpenGrokInterjection` | target-green | R02. |
| 68 | `xai-mixpanel` | `OpenGrokTelemetry` | deferred-with-reason | Absorbed into telemetry. |
| 69 | `xai-prompt-queue` | `OpenGrokPromptQueue` | target-green | R02. |
| 70 | `xai-proto-build` | `OpenGrokBuildSupport`, `OpenGrokProtoBuildPlugin` | ported | W0-S1. |
| 71 | `xai-ratatui-inline` | `OpenGrokTerminalCore` | in-progress | Scaffold; W2-S5. |
| 72 | `xai-ratatui-textarea` | `OpenGrokTextArea` | pending | W2-S5 stub. |
| 73 | `xai-sqlite-journal` | `OpenGrokSQLiteJournal` | target-green | R07 + remediation. |
| 74 | `xai-system-power` | `OpenGrokSystemPower` | in-progress | R09 + integration concurrency/IOKit fixes. |
| 75 | `xai-test-utils` | `OpenGrokTestUtilities` | ported | W0-S2. |
| 76 | `xai-token-estimation` | `OpenGrokTokenEstimation` | target-green | R03. |
| 77 | `xai-tool-protocol` | `OpenGrokToolProtocol` | target-green | R01. |
| 78 | `xai-tool-runtime` | `OpenGrokToolRuntime` | target-green | R01. |
| 79 | `xai-tool-types` | `OpenGrokToolTypes` | target-green | R01. |
| 80 | `xai-tracing` | `OpenGrokTracing` | target-green | R06 + exact-once span remediation. |
| 81 | `xai-tracing-macros` | `OpenGrokTracing` | deferred-with-reason | Absorbed into tracing APIs. |
| 82 | `xai-tty-utils` | `OpenGrokTTY` | in-progress | R09 nested raw-mode + posix_spawn sleeper tests. |

**Status tally (crate table):** ported/target-green ≈ 30 · in-progress ≈ 15 · deferred = 2 · pending/stub majority ≈ 35 · **total 82** Rust crates. Separate **source-target** inventory: **42 / 98** bootstrap placeholders, **46 / 100** zero-test targets (counting method above). Target-green is **not** executable product parity.

## Next action

1. Re-run `zsh workflows/swift-safe-verify.zsh build` to verify the HTTP async-lock fix and clear any subsequent integrated errors (iteration budget was exhausted at three).
2. Then `build-tests`, focused R04–R09 test filters, full `test`, and `build --product open-grok` with executable smokes.
3. Keep CompactionTranscript.swift and workflow artifacts intact.

## Protected artifacts

- `Sources/OpenGrokChatState/CompactionTranscript.swift` JSONValue pattern correction — **do not revert**.
- Workflow harness `workflows/run-grok45-port.zsh`, `workflows/swift-safe-verify.zsh`, and `.gitignore` entries for `.port-workflow` / scratch builds — retained.
- C helper targets `OpenGrokPTYC` and `OpenGrokCrashHandlerC` are required Package.swift edges for R09 shims.
