# Rust Crate to SwiftPM Target Map

**Baseline:** 2026-07-20 (inventory and reference pin refreshed 2026-08-04)
**Reference pin:** `xai-org/grok-build` at `650c1db7c2e73c59cec88bf3c6359751d6cef1bd` (re-pinned **2026-08-08** from `70002584da34e4c37ea14a3bce35341b7d04f9a7`, itself re-pinned 2026-08-06 from `9ed09e2ac3a2fd9147c7049ef4d75dcdcbd8fa05`). `ProtocolFixtures/` were re-evaluated and recaptured at the current `650c1db7…` ref; see `PORT_STATUS.md` for per-family evidence. The `.58` delta added no crates — the 84-package count below is unchanged (verified: `git diff 70002584..650c1db7` touches no `Cargo.toml`).
**Count:** **83** root workspace packages from `cargo metadata` plus `xai-grok-markdown-fuzz` in its own nested workspace = **89 total** (was 84; five additional crates — `xai-grok-bundle`, `xai-grok-diag-server`, `xai-grok-workspace-daemon`, `xai-grok-pager-diff`, `xai-grok-session-search` — were found and ported 2026-08-14).

**SwiftPM source/test inventory (committed tree, same method as `PORT_STATUS.md`, recounted 2026-08-04):**
**99** `Sources/` targets · **8** matching the ≤15-non-comment-LOC placeholder rule, of which **7** are genuine placeholders and one is the thin `OpenGrokExecutable` `main` (C helpers excluded) · **101** `Tests/` targets · **12** zero-test · **89** with ≥1 test. The previously published **98 / 42 / 100 / 46** figures are superseded.

## Mapping rules

- Names use `OpenGrok...` Swift modules while preserving the public executable name `open-grok`.
- Small Rust build/macro helpers may be absorbed into the target that owns their behavior; this is stated explicitly below.
- The three largest Rust crates are intentionally split: `xai-grok-tools` into tool-domain targets, `xai-grok-shell` into actor/runtime targets, and `xai-grok-pager` into pure model/runtime/feature targets.
- Third-party Rust crates are ported into an attributed Mermaid layout target; they are not published as misleading first-party standalone products.
- Every mapped target has a unique owner in `PORT_PLAN.md`; Package.swift integration remains `W0-S1`-owned.

| # | Rust crate | Manifest/source boundary | Swift target(s) | Slice(s) | Port role / rationale |
|---:|---|---|---|---|---|
| 1 | `dagre_rust` | `third_party/dagre_rust/Cargo.toml` | `OpenGrokMermaidLayout` | `W8-S2` | Dagre graph layout algorithms. |
| 2 | `graphlib_rust` | `third_party/graphlib_rust/Cargo.toml` | `OpenGrokMermaidLayout` | `W8-S2` | Graph data structures/traversal. |
| 3 | `mermaid-to-svg` | `third_party/mermaid-to-svg/Cargo.toml` | `OpenGrokMermaidLayout`, `OpenGrokMermaid` | `W8-S2` | Mermaid parsers, diagram layout, SVG rendering, themes, and supported diagram families. |
| 4 | `ordered_hashmap` | `third_party/ordered_hashmap/Cargo.toml` | `OpenGrokMermaidLayout` | `W8-S2` | Deterministic insertion-ordered map used by diagram layout. |
| 5 | `prod-mc-cli-chat-proxy-types` | `prod/mc/cli-chat-proxy-types/Cargo.toml` | `OpenGrokCLIChatProxyTypes` | `W0-S4` | CLI/chat proxy DTOs and compatibility envelopes. |
| 6 | `ptyctl` | `crates/codegen/ptyctl/Cargo.toml` | `OpenGrokPTY` | `W2-S4`, `W11-S3` | PTY/ConPTY and child process control. |
| 7 | `ptyctl-cli` | `crates/codegen/ptyctl-cli/Cargo.toml` | `OpenGrokPTYCLI` | `W2-S4` | PTY diagnostic/control executable support. |
| 8 | `xai-acp-lib` | `crates/codegen/xai-acp-lib/Cargo.toml` | `OpenGrokACP` | `W1-S2`, `W11-S2` | ACP JSON-RPC types, methods, notifications, reverse requests, and channels. |
| 9 | `xai-agent-lifecycle` | `crates/codegen/xai-agent-lifecycle/Cargo.toml` | `OpenGrokAgentLifecycle` | `W1-S2` | Agent/task lifecycle state machine. |
| 10 | `xai-chat-state` | `crates/codegen/xai-chat-state/Cargo.toml` | `OpenGrokChatState` | `W1-S3` | Conversation/stream reducer and durable chat state. |
| 11 | `xai-circuit-breaker` | `crates/common/xai-circuit-breaker/Cargo.toml` | `OpenGrokCircuitBreaker` | `W2-S1` | Retry/circuit breaker state and policy. |
| 12 | `xai-codebase-graph` | `crates/codegen/xai-codebase-graph/Cargo.toml` | `OpenGrokCodebaseGraph` | `W2-S3` | Codebase graph extraction and incremental invalidation. |
| 13 | `xai-computer-hub-core` | `crates/common/xai-computer-hub-core/Cargo.toml` | `OpenGrokComputerHubCore` | `W4-S4` | Computer Hub values and capability model. |
| 14 | `xai-computer-hub-mcp-adapter` | `crates/common/xai-computer-hub-mcp-adapter/Cargo.toml` | `OpenGrokComputerHubMCPAdapter` | `W5-S4` | MCP projection of permission-mediated Computer Hub operations. |
| 15 | `xai-computer-hub-sdk` | `crates/common/xai-computer-hub-sdk/Cargo.toml` | `OpenGrokComputerHubSDK` | `W4-S4` | Computer Hub client SDK. |
| 16 | `xai-crash-handler` | `crates/codegen/xai-crash-handler/Cargo.toml` | `OpenGrokCrashHandler` | `W2-S4` | Crash capture, redaction, and terminal/session-safe cleanup. |
| 17 | `xai-fast-worktree` | `crates/codegen/xai-fast-worktree/Cargo.toml` | `OpenGrokFastWorktree` | `W4-S2` | Fast safe Git worktree lifecycle. |
| 18 | `xai-file-utils` | `crates/codegen/xai-file-utils/Cargo.toml` | `OpenGrokFileUtils` | `W2-S2` | Atomic files, locks, checksums, permissions, and path utilities. |
| 19 | `xai-fsnotify` | `crates/codegen/xai-fsnotify/Cargo.toml` | `OpenGrokFSNotify` | `W2-S3` | Cross-platform filesystem observation. |
| 20 | `xai-gix-status` | `crates/codegen/xai-gix-status/Cargo.toml` | `OpenGrokGitStatus` | `W2-S3` | Pure Git status/index/worktree inspection. |
| 21 | `xai-grok-agent` | `crates/codegen/xai-grok-agent/Cargo.toml` | `OpenGrokAgentDefinitions` | `W5-S6` | AGENTS/rules/persona/skill/capability prompt composition. |
| 22 | `xai-grok-announcements` | `crates/codegen/xai-grok-announcements/Cargo.toml` | `OpenGrokAnnouncements` | `W5-S6` | Announcement fetch/cache/policy. |
| 23 | `xai-grok-auth` | `crates/codegen/xai-grok-auth/Cargo.toml` | `OpenGrokAuth` | `W3-S1`, `W11-S5` | xAI/API-key/OIDC/external/device auth and isolated Codex OAuth. |
| 24 | `xai-grok-code-mode` | `crates/codegen/xai-grok-code-mode/Cargo.toml` | `OpenGrokCodeMode`, `OpenGrokJavaScriptRuntime` | `W6-S1`, `W11-S5` | Persistent JavaScript cells, nested tools, yield/wait/cancel, provider projection, and lifecycle. |
| 25 | `xai-grok-code-mode-protocol` | `crates/codegen/xai-grok-code-mode-protocol/Cargo.toml` | `OpenGrokCodeModeProtocol` | `W1-S4` | Codex-derived JavaScript cell/nested-tool wire protocol. |
| 26 | `xai-grok-compaction` | `crates/common/xai-grok-compaction/Cargo.toml` | `OpenGrokCompaction` | `W6-S2` | Local/provider-neutral and Codex V2/unary compaction. |
| 27 | `xai-grok-config` | `crates/codegen/xai-grok-config/Cargo.toml` | `OpenGrokConfig` | `W1-S5` | TOML loading, merging, validation, managed policy, and persistence. |
| 28 | `xai-grok-config-types` | `crates/codegen/xai-grok-config-types/Cargo.toml` | `OpenGrokConfigTypes` | `W1-S5` | Typed layered configuration schema. |
| 29 | `xai-grok-env` | `crates/codegen/xai-grok-env/Cargo.toml` | `OpenGrokEnvironment` | `W0-S3` | Environment access, parsing, and scoped overrides. |
| 30 | `xai-grok-hooks` | `crates/codegen/xai-grok-hooks/Cargo.toml` | `OpenGrokHooks` | `W5-S5` | Hook discovery/matching/execution with fail-open operational failures. |
| 31 | `xai-grok-http` | `crates/codegen/xai-grok-http/Cargo.toml` | `OpenGrokHTTP` | `W2-S1` | HTTP/SSE/WebSocket transport primitives. |
| 32 | `xai-grok-markdown` | `crates/codegen/xai-grok-markdown/Cargo.toml` | `OpenGrokMarkdown` | `W8-S1`, `W11-S4` | Streaming terminal Markdown rendering. |
| 33 | `xai-grok-markdown-core` | `crates/codegen/xai-grok-markdown-core/Cargo.toml` | `OpenGrokMarkdownCore` | `W8-S1` | Markdown AST/core parsing. |
| 34 | `xai-grok-markdown-fuzz` | `crates/codegen/xai-grok-markdown/fuzz/Cargo.toml` | `OpenGrokFuzzingTests` | `W11-S4` | Standalone cargo-fuzz workspace for all Markdown render modes; mapped to Swift fuzz tests. |
| 35 | `xai-grok-mcp` | `crates/codegen/xai-grok-mcp/Cargo.toml` | `OpenGrokMCP` | `W5-S4` | MCP transports, OAuth, discovery, search/use, resources, and prompts. |
| 36 | `xai-grok-memory` | `crates/codegen/xai-grok-memory/Cargo.toml` | `OpenGrokMemory` | `W6-S3` | Memory store, index, search, embedding, flush, and dream. |
| 37 | `xai-grok-mermaid` | `crates/codegen/xai-grok-mermaid/Cargo.toml` | `OpenGrokMermaid` | `W8-S2`, `W11-S5` | Open Grok Mermaid integration/assets/terminal fallback. |
| 38 | `xai-grok-models` | `crates/codegen/xai-grok-models/Cargo.toml` | `OpenGrokModels` | `W3-S2` | Model catalogs, provider profiles, capabilities, caches, aliases, and custom models. |
| 39 | `xai-grok-pager` | `crates/codegen/xai-grok-pager/Cargo.toml` | `OpenGrokPagerModel`, `OpenGrokPagerRuntime`, `OpenGrokPagerConversationUI`, `OpenGrokPagerCommandUI`, `OpenGrokPagerOperationsUI`, `OpenGrokPager` | `W8-S4`, `W9-S1`, `W9-S2`, `W9-S3`, `W9-S4`, `W10-S1`, `W11-S3` | Very large pager crate split into pure model, independent UI feature targets, runtime, and final facade. |
| 40 | `xai-grok-pager-bin` | `crates/codegen/xai-grok-pager-bin/Cargo.toml` | `OpenGrokCLI`, `OpenGrokExecutable`, `OpenGrokDistributionSupport` | `W10-S2`, `W11-S1` | CLI parsing/validation plus final open-grok executable, completions, and distribution composition. |
| 41 | `xai-grok-pager-minimal` | `crates/codegen/xai-grok-pager-minimal/Cargo.toml` | `OpenGrokPagerMinimal` | `W9-S5` | Minimal/plain terminal frontend. |
| 42 | `xai-grok-pager-pty-harness` | `crates/codegen/xai-grok-pager-pty-harness/Cargo.toml` | `OpenGrokPagerPTYHarness`, `OpenGrokPagerPTYTests` | `W11-S3` | Full PTY scenario harness and E2E tests. |
| 43 | `xai-grok-pager-render` | `crates/codegen/xai-grok-pager-render/Cargo.toml` | `OpenGrokPagerRender` | `W8-S3` | Pure terminal layout, theme, and cell rendering. |
| 44 | `xai-grok-paths` | `crates/codegen/xai-grok-paths/Cargo.toml` | `OpenGrokPaths` | `W0-S3` | OPENGROK_HOME, ~/.opengrok, .opengrok, managed binary and project path policy. |
| 45 | `xai-grok-plugin-marketplace` | `crates/codegen/xai-grok-plugin-marketplace/Cargo.toml` | `OpenGrokPluginMarketplace` | `W5-S5` | Plugin marketplace/install/update/remove/rollback. |
| 46 | `xai-grok-sampler` | `crates/codegen/xai-grok-sampler/Cargo.toml` | `OpenGrokSampler` | `W3-S3`, `W11-S2`, `W11-S4` | Chat/Responses/Messages adapters, streaming, retries, tools, usage, and provider isolation. |
| 47 | `xai-grok-sampling-types` | `crates/codegen/xai-grok-sampling-types/Cargo.toml` | `OpenGrokSamplingTypes` | `W1-S3`, `W11-S2` | Provider-neutral conversation, stream, usage, model capability, and opaque backend values. |
| 48 | `xai-grok-sandbox` | `crates/codegen/xai-grok-sandbox/Cargo.toml` | `OpenGrokSandbox` | `W4-S1`, `W11-S5` | Sandbox policy, platform enforcement, capability detection, and resume pinning. |
| 49 | `xai-grok-secrets` | `crates/codegen/xai-grok-secrets/Cargo.toml` | `OpenGrokSecrets` | `W2-S2` | Secure-store protocol and platform adapters. |
| 50 | `xai-grok-shared` | `crates/codegen/xai-grok-shared/Cargo.toml` | `OpenGrokShared` | `W0-S4` | Cross-cutting identifiers, values, errors, and serialization utilities. |
| 51 | `xai-grok-shell` | `crates/codegen/xai-grok-shell/Cargo.toml` | `OpenGrokGoalState`, `OpenGrokSessionRuntime`, `OpenGrokSessionPersistence`, `OpenGrokProviderSession`, `OpenGrokAgentCoordinator`, `OpenGrokACPRuntime`, `OpenGrokShell` | `W6-S3`, `W7-S1`, `W7-S2`, `W7-S3`, `W7-S4`, `W7-S5`, `W8-S5`, `W11-S2`, `W11-S4` | Large shell crate split into pure goal state, actor/runtime components, and final facade. |
| 52 | `xai-grok-shell-base` | `crates/codegen/xai-grok-shell-base/Cargo.toml` | `OpenGrokShellBase` | `W6-S4` | Shared shell services and abstractions. |
| 53 | `xai-grok-shell-session-support` | `crates/codegen/xai-grok-shell-session-support/Cargo.toml` | `OpenGrokShellSessionSupport` | `W6-S4` | Session DTOs/events/history/persistence support. |
| 54 | `xai-grok-subagent-resolution` | `crates/codegen/xai-grok-subagent-resolution/Cargo.toml` | `OpenGrokSubagentResolution` | `W6-S5` | Agent/persona/role/capability hierarchy resolution. |
| 55 | `xai-grok-telemetry` | `crates/codegen/xai-grok-telemetry/Cargo.toml` | `OpenGrokTelemetry` | `W2-S1`, `W11-S5` | OpenTelemetry and product telemetry policy/export. |
| 56 | `xai-grok-test-support` | `crates/codegen/xai-grok-test-support/Cargo.toml` | `OpenGrokTestSupport` | `W0-S2`, `W11-S2` | Hermetic environment, mock inference/SSE/ACP, and shared integration fixtures. |
| 57 | `xai-grok-tools` | `crates/codegen/xai-grok-tools/Cargo.toml` | `OpenGrokToolRegistry`, `OpenGrokFileTools`, `OpenGrokExecutionTools`, `OpenGrokWebMediaTools`, `OpenGrokAgentControlTools` | `W5-S1`, `W5-S2`, `W5-S3`, `W11-S4` | Large tool crate intentionally split into registry/file/execution/web-media/agent-control targets. |
| 58 | `xai-grok-tools-api` | `crates/codegen/xai-grok-tools-api/Cargo.toml` | `OpenGrokToolsAPI` | `W1-S1` | Public tool registration/invocation API boundary. |
| 59 | `xai-grok-update` | `crates/codegen/xai-grok-update/Cargo.toml` | `OpenGrokUpdate` | `W5-S6`, `W11-S1`, `W11-S5` | Release checks, channels, checksums, replacement, and rollback. |
| 60 | `xai-grok-version` | `crates/codegen/xai-grok-version/Cargo.toml` | `OpenGrokVersion` | `W0-S3`, `W11-S1` | Canonical Open Grok version and release-channel parsing. |
| 61 | `xai-grok-voice` | `crates/codegen/xai-grok-voice/Cargo.toml` | `OpenGrokVoice` | `W5-S6` | Voice/audio capture, playback, and session service. |
| 62 | `xai-grok-workspace` | `crates/codegen/xai-grok-workspace/Cargo.toml` | `OpenGrokWorkspace` | `W4-S3` | Permission engine, trusted workspace, filesystem/process mediation, path locks, and foreign sessions. |
| 63 | `xai-grok-workspace-client` | `crates/codegen/xai-grok-workspace-client/Cargo.toml` | `OpenGrokWorkspaceClient` | `W4-S4` | Local/remote workspace service client. |
| 64 | `xai-grok-workspace-types` | `crates/codegen/xai-grok-workspace-types/Cargo.toml` | `OpenGrokWorkspaceTypes` | `W1-S4` | Workspace, permission, filesystem, process, terminal, and worktree DTOs. |
| 65 | `xai-hooks-plugins-types` | `crates/codegen/xai-hooks-plugins-types/Cargo.toml` | `OpenGrokHooksPluginTypes` | `W1-S4` | Hook/plugin/skill descriptors and trust metadata. |
| 66 | `xai-hunk-tracker` | `crates/codegen/xai-hunk-tracker/Cargo.toml` | `OpenGrokHunkTracker` | `W2-S3` | Explicit agent/session hunk attribution. |
| 67 | `xai-interjection-core` | `crates/common/xai-interjection-core/Cargo.toml` | `OpenGrokInterjection` | `W1-S2` | Steer/follow-up/interrupt semantics. |
| 68 | `xai-mixpanel` | `crates/codegen/xai-mixpanel/Cargo.toml` | `OpenGrokTelemetry` | `W2-S1` | Mixpanel-compatible event support is absorbed into telemetry. |
| 69 | `xai-prompt-queue` | `crates/codegen/xai-prompt-queue/Cargo.toml` | `OpenGrokPromptQueue` | `W1-S2` | Ordered queued prompt state. |
| 70 | `xai-proto-build` | `crates/build/xai-proto-build/Cargo.toml` | `OpenGrokBuildSupport`, `OpenGrokProtoBuildPlugin` | `W0-S1` | Generated protobuf/protocol build support; represented as deterministic SwiftPM build support/plugin. |
| 71 | `xai-ratatui-inline` | `crates/codegen/xai-ratatui-inline/Cargo.toml` | `OpenGrokTerminalCore` | `W2-S5`, `W11-S5` | Ratatui-derived inline/fullscreen terminal behavior reimplemented in custom terminal core. |
| 72 | `xai-ratatui-textarea` | `crates/codegen/xai-ratatui-textarea/Cargo.toml` | `OpenGrokTextArea` | `W2-S5` | Unicode terminal text editor. |
| 73 | `xai-sqlite-journal` | `crates/codegen/xai-sqlite-journal/Cargo.toml` | `OpenGrokSQLiteJournal` | `W2-S2` | Transactional journal, migrations, and recovery. |
| 74 | `xai-system-power` | `crates/codegen/xai-system-power/Cargo.toml` | `OpenGrokSystemPower` | `W2-S4` | Cross-platform power inhibition leases. |
| 75 | `xai-test-utils` | `crates/common/xai-test-utils/Cargo.toml` | `OpenGrokTestUtilities` | `W0-S2` | Dependency-light test helpers and deterministic guards. |
| 76 | `xai-token-estimation` | `crates/codegen/xai-token-estimation/Cargo.toml` | `OpenGrokTokenEstimation` | `W1-S3` | Token/context estimation and thresholds. |
| 77 | `xai-tool-protocol` | `crates/common/xai-tool-protocol/Cargo.toml` | `OpenGrokToolProtocol` | `W1-S1`, `W11-S2` | Tool runtime/RPC wire protocol. |
| 78 | `xai-tool-runtime` | `crates/common/xai-tool-runtime/Cargo.toml` | `OpenGrokToolRuntime` | `W1-S1` | Runtime interfaces, cancellation, streaming, and invocation messages. |
| 79 | `xai-tool-types` | `crates/common/xai-tool-types/Cargo.toml` | `OpenGrokToolTypes` | `W1-S1` | Tool declarations, calls, results, schemas, annotations, and content blocks. |
| 80 | `xai-tracing` | `crates/common/xai-tracing/Cargo.toml` | `OpenGrokTracing` | `W2-S1` | Structured spans, correlation, and redaction. |
| 81 | `xai-tracing-macros` | `crates/codegen/xai-tracing-macros/Cargo.toml` | `OpenGrokTracing` | `W2-S1` | Rust tracing macros are absorbed into ordinary Swift tracing wrappers; no macro target needed. |
| 82 | `xai-tty-utils` | `crates/codegen/xai-tty-utils/Cargo.toml` | `OpenGrokTTY` | `W2-S4` | TTY capabilities, raw mode, and console handling. |
| 83 | `xai-workflow` | `crates/codegen/xai-workflow/Cargo.toml` | proposed `OpenGrokWorkflowEngine` | `W6-S5` (proposed) | **Added upstream since the old pin.** Native Rhai workflow engine: script engine, host bindings, run journal, run metadata, execution, and validation. Proposed as a **new target** rather than folded into the existing `OpenGrokWorkflow`, because that target was ported against the removed JavaScript workflow model — folding would hide a rewrite behind an unchanged name. If a later slice decides the Rhai engine and the workflow tool surface belong together, merge deliberately and record the decision here. |
| 84 | `xai-grok-extra-ca` | `crates/codegen/xai-grok-extra-ca/Cargo.toml` | `OpenGrokExtraCA` | `W2-S1` | **Implemented partial.** Opt-in PEM loading is default-off, cached once, capped at 1 MiB, validated into DER, and consumed centrally by `OpenGrokHTTP` for buffered, Darwin streaming, and WebSocket sessions. Linux FoundationNetworking still lacks a server-trust challenge/anchor-installation API, so Linux buffered and streaming requests remain strict system-root-only until a portable TLS backend lands. |
| 85 | `xai-grok-bundle` | `crates/codegen/xai-grok-bundle/Cargo.toml` | `OpenGrokCLI` (SubagentBundleArchive, SubagentBundleCache, LiveBundleComposition) | — | Subagent bundle archive extraction (gzip/tar), bundle manifest/cache management, download lifecycle, ACP extension handler. Absorbed into `OpenGrokCLI`. |
| 86 | `xai-grok-diag-server` | `crates/codegen/xai-grok-diag-server/Cargo.toml` | `OpenGrokDiagnostics` (DiagServer, DiagHandle, DiagServerTypes) | — | In-guest diagnostics HTTP server: TCP loopback + Unix domain sockets, `/ready`, `/statusz`, `/logs` endpoints. |
| 87 | `xai-grok-workspace-daemon` | `crates/codegen/xai-grok-workspace-daemon/Cargo.toml` | `OpenGrokWorkspace` (WorkspaceDaemon, PidFile, PreviewSupervisor, PreviewScraper) | — | Process daemonization, single-instance pidfile locking, preview proxy supervision with exponential backoff, activity/metrics scraping. |
| 88 | `xai-grok-pager-diff` | `crates/codegen/xai-grok-pager-diff/Cargo.toml` | `OpenGrokPagerRender` (PagerDiff) | — | Line-level LCS diff engine, hunk extraction, stitch-collapse for sequential file-state edits, unified-patch text generation for TUI tool edit cards. |
| 89 | `xai-grok-session-search` | `crates/codegen/xai-grok-session-search/Cargo.toml` | `OpenGrokCLI` (LiveSessionSearch) | — | Session full-text search index, search gate integration, session discovery and ranking. |


Rows 83–89 are appended in discovery order rather than inserted alphabetically, so existing row numbers stay stable across the re-pin.

## Coverage checks

- Mapped crate rows: **89**.
- Unique Swift target owners in the plan: **106** committed, plus **1** proposed for the new upstream crate.
- Uncovered crates: **0**.
- `xai-grok-markdown-fuzz` is intentionally counted even though its manifest declares a nested standalone workspace and is absent from root `cargo metadata`.
- Re-run the plan validation before changing target splits; any unmapped manifest or duplicate target/path owner is a release-blocking architecture error.
