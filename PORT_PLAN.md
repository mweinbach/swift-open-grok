# Open Grok Rust-to-Swift Port Plan

**Planning baseline:** 2026-07-20 (inventory and reference pin refreshed 2026-08-04)
**Destination:** `/Users/mweinbach/Projects/swift-open-grok`
**Read-only reference:** `xai-org/grok-build` at `9ed09e2ac3a2fd9147c7049ef4d75dcdcbd8fa05` (re-pinned **2026-08-05** from `80dff0a9dcb24121b976b9f920fbe442af40ea88`, itself re-pinned 2026-08-04 from `9739c4a2ad23cfea14312a481169757f3da494f4`), local clone `/Users/mweinbach/Projects/grok-build`; `/tmp/open-grok-reference` when present. `ProtocolFixtures/` were captured at the **old** `9739c4a2…` ref and must be recaptured against the current pin before grounding any parity claim — see `PORT_STATUS.md`.
**SwiftPM baseline:** `swift-tools-version: 6.1`
**Reference inventory:** 83 root Cargo workspace members + 1 standalone markdown fuzz crate = **84 crates** (was 82; the re-pin added `xai-workflow` and `xai-grok-extra-ca`).
**Swift source/test inventory (see `PORT_STATUS.md` counting method, recounted 2026-08-04):** **99** `Sources/` targets · **8** matching the ≤15-LOC placeholder rule, of which **7** are genuine placeholders and one is the thin `OpenGrokExecutable` `main` · **101** `Tests/` targets · **12** zero-test. The former **98 / 42 / 100 / 46** figures are superseded. Workers must not invoke SwiftPM; only `zsh workflows/swift-safe-verify.zsh` via the sole integration agent.

## Mission

A complete 12-wave Swift source-port architecture for Open Grok covering all 83 Cargo workspace members plus the standalone markdown fuzz crate (84 total), with protocol-first SwiftPM targets, actor-owned sessions, provider isolation, custom terminal/TUI, cross-platform adapters, disjoint slice ownership, persistence compatibility, licensing, and release-grade verification. Durable artifacts are written to PORT_PLAN.md, CRATE_MAP.md, and PORT_STATUS.md.

This document defines the implementation-ready target graph, ownership, invariants, tests, and dependency order required to avoid a superficial skeleton. Current implementation progress and blockers are tracked separately in `PORT_STATUS.md`.

## Reference audit

- Read the root `AGENTS.md`, generated root `Cargo.toml`, Cargo metadata, every crate manifest, and an inventory of every source/test tree.
- Read the requested architecture/runtime/provider/TUI/tool/permission documents and the related ACP, session, subagent, Code Mode, editing, memory/goals, hooks/plugins/skills, provider architecture, Codex compatibility, development, CLI, and user-guide surfaces.
- Audited root and crate-level LICENSE/NOTICE inputs, including Codex source pins, Ratatui lineage, Mermaid/layout crates, and Roboto.
- The exact crate mapping is in `CRATE_MAP.md`; current execution state is in `PORT_STATUS.md`.

## Architectural invariants

- All 84 Rust crates are mapped in CRATE_MAP.md: 83 root Cargo workspace members plus the separately rooted xai-grok-markdown-fuzz crate; no manifest or end-user surface is unassigned. The two crates added at the 2026-08-04 re-pin (xai-workflow, xai-grok-extra-ca) are mapped to proposed targets and are not yet started.
- The package builds with Swift 6.1 language/tooling constraints, emits one executable product named open-grok, preserves Open Grok branding, and never reads or writes ~/.grok.
- Interactive full-screen, inline/minimal, headless text/JSON/JSONL/schema, ACP stdio/headless/leader/serve/relay, and every documented CLI command/flag pass automated acceptance tests.
- Session actor tests prove ordered turns/tool calls/steering, exactly-once continuation completion, cooperative cancellation, local ownership, permission gating, background work, rewind, compaction, and clean shutdown.
- Provider tests prove model-metadata identity, independent backend/profile/auth axes, explicit-key precedence, xAI/Codex store isolation, Kimi/Fireworks policy, hosted-tool/history isolation, live switching, and monotonic non-xAI export closure.
- Tool tests cover registry modes/packs, file/search/edit attribution, process/background/monitor/scheduler/terminal/LSP/web/media/computer tools, MCP, hooks/plugins/skills, human controls, output caps, resource locks, and Code Mode nested dispatch.
- Permission/sandbox tests prove exact gate ordering, fail-open hooks, deny > ask > allow, bash-segment rules, folder trust, session/project grants, YOLO boundaries, process-wide sandbox pinning, and no silent platform weakening.
- Persistence compatibility tests load representative Rust sessions/config/auth/model caches/memory/goals/worktrees, preserve opaque and unknown data, and verify atomic migration, resume, fork, rewind, restore-code, recap, and recovery.
- Markdown/Mermaid/terminal/TUI golden and fuzz tests cover streaming equivalence, Unicode, resize, inline restoration, themes, tool cards, Code Mode transport hiding, images, diagrams, and large histories without crashes or unbounded growth.
- macOS and Linux pass the full build/test/E2E matrix; Windows compiles all neutral targets and passes supported adapters, with explicit tested unsupported results only for genuine OS capability gaps.
- Telemetry, traces, crash reports, feedback, update, relay, memory, and provider exports are redaction/privacy audited and blocked by configuration and monotonic provider boundaries before serialization.
- Release artifacts include verified checksums, isolated installer/update behavior, shell completions, LICENSE/NOTICE/THIRD-PARTY-NOTICES, source revisions for derived code, and an in-product notices view.

## Platform strategy

- Use protocol-first domain targets and Foundation value/network/file APIs; no AppKit, UIKit, or SwiftUI dependency is permitted in session, provider, tool, workspace, persistence, rendering-model, or terminal-core targets.
- Centralize compile-time seams in adapter targets using #if os(macOS), #if os(Linux), and #if os(Windows); platform-neutral callers consume capability values and typed unsupported errors rather than conditional code.
- Use one custom terminal/TUI stack: Unicode cell grid, viewport, ANSI/input parser, diff renderer, and Action -> reducer -> Effect runtime. macOS/Linux use POSIX TTY/PTY adapters; Windows uses Console/ConPTY adapters.
- Use macOS Keychain behind `SecretStore`. Linux reports unsupported until a Secret Service/libsecret adapter is linked, with an explicitly requested owner-only file store as the documented fallback. Windows reports unsupported until Credential Manager or an equivalent owner-only adapter is linked; never silently downgrade secure persistence.
- Use macOS Seatbelt, Linux sandbox capability adapters, and Windows restricted-token/job/filesystem seams behind SandboxEnforcer. If parity is impossible, startup/resume reports an explicit unsupported capability and never silently weakens a persisted sandbox mode.
- Use FSEvents/kqueue, inotify, and ReadDirectoryChangesW; IOPM, Linux inhibitor facilities, and SetThreadExecutionState; POSIX process groups/signals and Windows Job Objects behind dedicated protocols.
- Treat Swift 6 strict concurrency as a design constraint: Sendable values cross actors, blocking C/OS calls run in bounded adapters, and continuations are guarded for exactly-once resume.
- Test macOS and Linux as full supported platforms from early waves; continuously compile Windows and progressively enable ConPTY, Credential Manager, filesystem watch, updater, and sandbox acceptance where the OS supports equivalent guarantees.

## Dependency and concurrency strategy

- Use swift-tools-version 6.1 with one executable product named open-grok and Swift targets named as crate-equivalent OpenGrok modules; merge only Rust crates that are macro/build-only or inseparable implementation details, and split xai-grok-tools, xai-grok-shell, and xai-grok-pager into conflict-free component targets.
- Allow dependencies only from later waves to earlier waves. Slices within a wave target protocols from prior waves so they can be implemented in parallel; final facades and Package.swift edge integration occur in dedicated integration slices.
- Give every slice exclusive ownership of its Sources/<Target>/ and Tests/<Target>Tests/ paths. W0-S1 alone owns Package.swift and root tracking/legal files; no feature slice edits another target or root tracker.
- Use actors for live sessions, persistence journals, auth stores, model catalogs, memory indexes, JavaScript runtimes, background registries, MCP connections, and pager action processing. Use AsyncSequence/AsyncThrowingStream for ordered streams with bounded buffers and cooperative cancellation.
- Preserve serialization contracts with Rust golden fixtures before replacing internals. Schema/version migrations must read existing Rust state, retain unknown/provider-opaque fields, and write atomically under OPENGROK_HOME.
- Keep provider profile, API backend, wire dialect, hosted-tool policy, and credential resolver independent. Concrete auth and transport implementations conform to protocols defined in earlier waves; provider denial/export boundaries are evaluated before network serialization.
- Keep tool declaration/finalization separate from implementation and invocation. Every direct or Code Mode nested call uses the same preparation, plan/hook/permission gate, resource lock, dispatch, history, and attribution pipeline.
- Pin and audit non-Foundation dependencies only where an OS or algorithm requires them (SQLite C API, JavaScript engine, syntax grammars, compression/crypto as needed); wrap each in an OpenGrok target and record license/source revision.
- Integrate with target-scoped Swift Testing suites first, then compatibility, PTY E2E, fuzz/stress, platform, security, privacy, and release-license gates. All runtime tests isolate HOME, USERPROFILE, and OPENGROK_HOME.

### Actor ownership model

- `SessionActor`: sole owner of a live session timeline, turn loop, permission waits, steering, tool history, compaction coordination, Code Mode runtime generation, and close sequence.
- `SessionPersistenceActor`: serial atomic journal/snapshot writer and migration/recovery authority.
- `AuthStoreActor` per provider: isolated credential snapshots and refresh/logout state; no process-wide shared token cell across providers.
- `ModelCatalogActor` per provider partition: cache/ETag/TTL and user override merge without cross-provider mutation.
- `MemoryIndexActor`, `MCPConnectionActor`, `BackgroundTaskRegistryActor`, and `PagerRuntimeActor`: independently cancellable owners that exchange immutable Sendable events.
- Blocking OS/C calls execute in bounded adapters and report typed results back to owners; detached tasks never capture mutable actor state for later unsynchronized mutation.

### Fixed permission/tool order

1. Plan edit gate.
2. `PreToolUse` hooks; operational failures are fail-open but recorded.
3. Plan-file auto-approval.
4. Permission evaluation (`deny > ask > allow`) with trust/session/project/CLI policy.
5. Sandbox/capability and canonical resource-lock validation.
6. Dispatch.
7. Durable history and hunk attribution only after the operation result.

## End-user behavior coverage

| Surface | Required parity | Primary slices |
|---|---|---|
| Branding and paths | open-grok only; OPENGROK_HOME/~/.opengrok; project .opengrok; no ~/.grok | W0-S3, W10, W11-S1 |
| CLI and modes | Interactive, minimal, headless, JSON/JSONL/schema, inspect/auth/MCP/plugin/memory/models/sessions/setup/share/wrap/export/trace/update/version/completions/worktree/workspace/dashboard | W9, W10 |
| ACP | In-process, stdio, headless, leader, serve, WebSocket/relay, reverse RPC, durable/live notifications | W1-S2, W7-S5 |
| TUI | Custom terminal, Action/reducer/Effect, scrollback, input, modals, settings, slash commands, dashboard, themes | W2-S5, W8, W9 |
| Sessions | Actor ownership, ordered turns, cancellation, persistence, resume/load/continue, fork, rewind, restore code, recap | W6-S4, W7 |
| Providers/auth | xAI, Codex, Kimi, Fireworks, custom endpoints; API backend/profile/auth isolation; OAuth/API keys/catalogs/live switches | W3, W7-S3 |
| Streaming | Chat/Responses/Messages SSE, tool calls, reasoning, usage, structured output, images, retries, sticky state | W1-S3, W3-S3 |
| Tools | Registry, modes/packs, file/edit/search, bash/background/monitor/scheduler/terminal/LSP/web/media/computer/human controls | W1-S1, W5-S1..W5-S3 |
| Permissions/sandbox/worktrees | Exact gate order, rule DSL, trust, resource locks, sandbox pinning, fast worktrees | W4 |
| MCP/hooks/plugins/skills | Transports/OAuth/search/use, fail-open hooks, marketplace, trust/precedence/session activation | W5-S4, W5-S5, W5-S6 |
| Memory/goals/compaction | Index/search/flush/dream, goal state, local/provider compaction, Codex V2/unary | W6-S2, W6-S3, W7-S2 |
| Subagents | Task/swarm/workflow, max depth one, inherited permissions, worktrees, resume, usage fold, orphan recovery | W6-S5, W7-S4 |
| Code Mode | Direct/mixed/only, persistent JavaScript cells, yield/wait, nested tools, hidden transport, provider routes | W1-S4, W6-S1 |
| Rendering | Markdown streaming, Mermaid diagrams, themes, Unicode, inline/fullscreen/minimal, images | W8, W9 |
| Telemetry/update/voice | Tracing/OTel/Mixpanel privacy, release checks/install rollback, announcements, audio/voice | W2-S1, W5-S6, W9-S4, W11-S1 |
| Persistence/testing | Atomic journals/files, Rust migrations/fixtures, PTY E2E, fuzz/stress/perf, platform/security/license audits | W2-S2, W7-S2, W11 |

## Parallel ownership contract

- A slice may edit only its listed `Sources/<Target>/` and `Tests/<Target>Tests/` paths.
- Slices within a wave compile against protocols from earlier waves and do not import another same-wave concrete target.
- `W0-S1` alone edits `Package.swift`, root tracking documents, and root legal aggregation. Feature slices request dependency/target integration rather than editing the package manifest.
- Shared fixtures belong to `OpenGrokTestSupport`; feature-specific golden data stays in that feature's test target.
- No slice creates a second implementation of an existing protocol to avoid a dependency; missing contracts are resolved through the bootstrap/integration owner.

## Dependency waves and implementation slices

### Wave 0 — Bootstrap, branding, and shared foundations

Establish the SwiftPM integration contract, Open Grok path isolation, deterministic test infrastructure, and dependency-free shared values before any subsystem port begins.

#### W0-S1 — Bootstrap and integration control

Create the package/product topology and the only integration-owned root surfaces, including legal attribution and generated-protocol build support.

- **Rust crates:** `xai-proto-build`
- **Swift targets:** `OpenGrokBuildSupport`, `OpenGrokProtoBuildPlugin`
- **Owned paths:** `Sources/OpenGrokBuildSupport/`, `Tests/OpenGrokBuildSupportTests/`, `Plugins/OpenGrokProtoBuildPlugin/`, `Package.swift`, `PORT_PLAN.md`, `CRATE_MAP.md`, `PORT_STATUS.md`, `LICENSE`, `NOTICE`, `THIRD-PARTY-NOTICES`
- **Depends on:** None
- **Reference/invariants:** Reference: crates/build/xai-proto-build plus root Cargo/build/release metadata. This is the only slice allowed to edit Package.swift and root tracking documents; all later target declarations are integrated here after target-owned tests pass.
- **Acceptance:**
  - Package.swift declares swift-tools-version 6.1, an executable product named open-grok, and only target edges approved by the crate map; swift package describe succeeds after each integration batch.
  - A deterministic generation plugin can produce ACP/protocol fixtures without network access and fails when checked-in generated output is stale.
  - PORT_PLAN.md, CRATE_MAP.md, and PORT_STATUS.md remain the canonical ownership/dependency trackers and enumerate all 83 workspace crates plus xai-grok-markdown-fuzz.
  - Distributed LICENSE, NOTICE, and THIRD-PARTY-NOTICES inputs retain Codex, Ratatui, Mermaid/layout, Roboto, and transitive-package obligations.

#### W0-S2 — Hermetic test support

Port temp-environment, mock transport, fixture, clock, UUID, random, and process helpers so every later slice can test without touching a developer installation.

- **Rust crates:** `xai-grok-test-support`, `xai-test-utils`
- **Swift targets:** `OpenGrokTestSupport`, `OpenGrokTestUtilities`
- **Owned paths:** `Sources/OpenGrokTestSupport/`, `Tests/OpenGrokTestSupportTests/`, `Sources/OpenGrokTestUtilities/`, `Tests/OpenGrokTestUtilitiesTests/`
- **Depends on:** None
- **Reference/invariants:** Reference: crates/codegen/xai-grok-test-support and crates/common/xai-test-utils. Keep helpers dependency-light; subsystem-specific fixtures stay in their owning test targets.
- **Acceptance:**
  - Every test helper creates isolated HOME, USERPROFILE, and OPENGROK_HOME directories and refuses paths resolving to the real ~/.opengrok.
  - Deterministic clocks, UUIDs, randomness, mock HTTP/SSE, ACP channels, and tool runtimes are Sendable and safe under parallel Swift Testing execution.
  - Environment mutation is serialized and restored even after thrown errors or task cancellation.
  - Fixture helpers can replay raw Rust JSON/SSE/ACP bytes without normalizing unknown fields or event order.

#### W0-S3 — Branding, paths, environment, and version

Centralize Open Grok identity, state-directory resolution, environment policy, version parsing, and platform path semantics.

- **Rust crates:** `xai-grok-paths`, `xai-grok-env`, `xai-grok-version`
- **Swift targets:** `OpenGrokPaths`, `OpenGrokEnvironment`, `OpenGrokVersion`
- **Owned paths:** `Sources/OpenGrokPaths/`, `Tests/OpenGrokPathsTests/`, `Sources/OpenGrokEnvironment/`, `Tests/OpenGrokEnvironmentTests/`, `Sources/OpenGrokVersion/`, `Tests/OpenGrokVersionTests/`
- **Depends on:** None
- **Reference/invariants:** Reference: xai-grok-paths/src, xai-grok-env/src, xai-grok-version/src and release scripts. These targets must use Foundation FilePath/URL APIs and contain no TUI or provider policy.
- **Acceptance:**
  - OPENGROK_HOME wins over HOME/USERPROFILE and the fallback is exactly ~/.opengrok; tests prove ~/.grok is never read or written.
  - Project-local state resolves only to .opengrok and managed binaries resolve under $OPENGROK_HOME/bin/open-grok.
  - Path creation, canonicalization, owner-only permissions, atomic replacement, and Windows path/drive handling are represented by protocols with platform adapters.
  - Version parsing preserves Open Grok prerelease/channel strings and build-injected GROK_VERSION behavior.

#### W0-S4 — Shared serialization and identifiers

Define stable Sendable identifiers, JSON envelopes, error/value utilities, and proxy DTOs used across process, ACP, tool, and persistence boundaries.

- **Rust crates:** `xai-grok-shared`, `prod-mc-cli-chat-proxy-types`
- **Swift targets:** `OpenGrokShared`, `OpenGrokCLIChatProxyTypes`
- **Owned paths:** `Sources/OpenGrokShared/`, `Tests/OpenGrokSharedTests/`, `Sources/OpenGrokCLIChatProxyTypes/`, `Tests/OpenGrokCLIChatProxyTypesTests/`
- **Depends on:** None
- **Reference/invariants:** Reference: crates/codegen/xai-grok-shared and prod/mc/cli-chat-proxy-types. Prefer value types and explicit Codable implementations over global mutable registries.
- **Acceptance:**
  - Session, turn, tool-call, task, worktree, model, and request identifiers have stable Codable wire forms and deterministic ordering.
  - Unknown JSON object fields can be retained where Rust compatibility requires forward-compatible replay.
  - Error envelopes preserve machine code, user message, retryability, and structured details without relying on NSError identity.
  - Golden fixtures round-trip byte-significant proxy messages and reject malformed required fields.

### Wave 1 — Protocols, domain models, and configuration

Port the stable contracts that let later provider, tool, workspace, session, and UI slices compile independently against protocols rather than concrete implementations.

#### W1-S1 — Tool protocol stack

Port tool schemas, call/result content, runtime RPC, registration descriptors, output hints, and cancellation contracts.

- **Rust crates:** `xai-tool-types`, `xai-tool-protocol`, `xai-tool-runtime`, `xai-grok-tools-api`
- **Swift targets:** `OpenGrokToolTypes`, `OpenGrokToolProtocol`, `OpenGrokToolRuntime`, `OpenGrokToolsAPI`
- **Owned paths:** `Sources/OpenGrokToolTypes/`, `Tests/OpenGrokToolTypesTests/`, `Sources/OpenGrokToolProtocol/`, `Tests/OpenGrokToolProtocolTests/`, `Sources/OpenGrokToolRuntime/`, `Tests/OpenGrokToolRuntimeTests/`, `Sources/OpenGrokToolsAPI/`, `Tests/OpenGrokToolsAPITests/`
- **Depends on:** `W0-S4`
- **Reference/invariants:** Reference: crates/common/xai-tool-{types,protocol,runtime} and crates/codegen/xai-grok-tools-api. These targets define contracts only; no concrete filesystem, process, network, or permission work.
- **Acceptance:**
  - Tool declarations preserve JSON Schema, namespaces, annotations, visibility, packs, groups, modes, and direct-only flags.
  - Runtime messages preserve request IDs, streaming content blocks, image/generated-image hints, structured errors, cancellation, and timeout semantics.
  - Output-size metadata and truncation decisions are explicit values rather than hidden global constants.
  - Rust golden fixtures round-trip every tool call/result variant, including unknown future content blocks.

#### W1-S2 — ACP, lifecycle, interjection, and prompt queues

Port ACP wire types/channels plus the neutral lifecycle, interjection, and queued-prompt state machines used by shell and pager.

- **Rust crates:** `xai-acp-lib`, `xai-agent-lifecycle`, `xai-interjection-core`, `xai-prompt-queue`
- **Swift targets:** `OpenGrokACP`, `OpenGrokAgentLifecycle`, `OpenGrokInterjection`, `OpenGrokPromptQueue`
- **Owned paths:** `Sources/OpenGrokACP/`, `Tests/OpenGrokACPTests/`, `Sources/OpenGrokAgentLifecycle/`, `Tests/OpenGrokAgentLifecycleTests/`, `Sources/OpenGrokInterjection/`, `Tests/OpenGrokInterjectionTests/`, `Sources/OpenGrokPromptQueue/`, `Tests/OpenGrokPromptQueueTests/`
- **Depends on:** `W0-S4`
- **Reference/invariants:** Reference: xai-acp-lib, xai-agent-lifecycle, xai-interjection-core, and xai-prompt-queue. Transport implementations arrive in Wave 7.
- **Acceptance:**
  - ACP JSON-RPC IDs, methods, notifications, reverse requests, errors, and Open Grok extension metadata match captured Rust fixtures.
  - Lifecycle transitions reject invalid regressions and preserve queued, running, waiting, cancelling, completed, and failed ordering.
  - Interjections distinguish steer, follow-up, interrupt, and queued prompt behavior with deterministic dequeue order.
  - Channel cancellation closes pending continuations exactly once and never resumes a Swift continuation twice.

#### W1-S3 — Sampling, chat state, and token accounting

Port provider-neutral conversation history, stream events, usage, model capabilities, opaque backend items, chat reducers, and token estimates.

- **Rust crates:** `xai-grok-sampling-types`, `xai-chat-state`, `xai-token-estimation`
- **Swift targets:** `OpenGrokSamplingTypes`, `OpenGrokChatState`, `OpenGrokTokenEstimation`
- **Owned paths:** `Sources/OpenGrokSamplingTypes/`, `Tests/OpenGrokSamplingTypesTests/`, `Sources/OpenGrokChatState/`, `Tests/OpenGrokChatStateTests/`, `Sources/OpenGrokTokenEstimation/`, `Tests/OpenGrokTokenEstimationTests/`
- **Depends on:** `W0-S4`
- **Reference/invariants:** Reference: xai-grok-sampling-types, xai-chat-state, and xai-token-estimation. Provider credentials and HTTP behavior are deliberately absent.
- **Acceptance:**
  - ConversationRequest/Response and stream events are provider-neutral and retain typed opaque history tagged by backend/dialect.
  - Chat state applies deltas in arrival order, deduplicates terminal items correctly, and preserves reasoning/tool/media provenance.
  - Token estimates are monotonic for appended content, bounded for binary/media placeholders, and fixture-compatible with Rust thresholds.
  - Usage values preserve input, cached input, output, reasoning, provider quota windows, and aggregate child-agent folding.

#### W1-S4 — Workspace, extension, and Code Mode schemas

Port permission/workspace RPC values, hook/plugin descriptors, and the Code Mode cell protocol as independent Codable contracts.

- **Rust crates:** `xai-grok-workspace-types`, `xai-hooks-plugins-types`, `xai-grok-code-mode-protocol`
- **Swift targets:** `OpenGrokWorkspaceTypes`, `OpenGrokHooksPluginTypes`, `OpenGrokCodeModeProtocol`
- **Owned paths:** `Sources/OpenGrokWorkspaceTypes/`, `Tests/OpenGrokWorkspaceTypesTests/`, `Sources/OpenGrokHooksPluginTypes/`, `Tests/OpenGrokHooksPluginTypesTests/`, `Sources/OpenGrokCodeModeProtocol/`, `Tests/OpenGrokCodeModeProtocolTests/`
- **Depends on:** `W0-S4`
- **Reference/invariants:** Reference: xai-grok-workspace-types, xai-hooks-plugins-types, and the Codex-derived xai-grok-code-mode-protocol NOTICE-pinned source.
- **Acceptance:**
  - Permission requests/decisions encode allow, deny, ask, allow-once, allow-session, rule source, and audit context without losing order.
  - Workspace messages cover filesystem, process, terminal, worktree, foreign-session, and Computer Hub operations with explicit capabilities.
  - Hook/plugin/skill descriptors preserve trust source, precedence, command, matcher, timeout, environment, and failure policy.
  - Code Mode protocol covers exec, yield, wait, terminate, nested calls, structured content, images, generated images, stale cells, and runtime disposal.

#### W1-S5 — Configuration and managed policy

Port layered configuration, compatibility aliases, model/provider declarations, feature flags, themes, tools, permissions, hooks, plugins, skills, MCP, and managed overrides.

- **Rust crates:** `xai-grok-config-types`, `xai-grok-config`
- **Swift targets:** `OpenGrokConfigTypes`, `OpenGrokConfig`
- **Owned paths:** `Sources/OpenGrokConfigTypes/`, `Tests/OpenGrokConfigTypesTests/`, `Sources/OpenGrokConfig/`, `Tests/OpenGrokConfigTests/`
- **Depends on:** `W0-S3`, `W0-S4`
- **Reference/invariants:** Reference: xai-grok-config-types and xai-grok-config source/tests plus docs/agents/tui-and-config.md and user-guide configuration chapters.
- **Acceptance:**
  - Configuration precedence matches built-ins < user $OPENGROK_HOME config < project .opengrok config < environment < CLI, with managed policy applied at its documented authority.
  - TOML parsing preserves unknown keys for forward compatibility while validating enums, paths, URLs, durations, and mutually exclusive CLI/session options.
  - Legacy Code Mode booleans remain readable but new writes use direct, code_mode, or code_mode_only; restart-required settings are marked explicitly.
  - Fixture tests cover themes, model/provider entries, MCP transports, permissions, hooks, plugins, skills, memory, sandbox, pager, telemetry, update, and voice settings.

### Wave 2 — Cross-platform infrastructure and terminal core

Implement reusable networking, persistence, OS adaptation, filesystem observation, process control, and terminal primitives behind strict Sendable protocols.

#### W2-S1 — HTTP, reliability, tracing, and telemetry

Port async HTTP/SSE/WebSocket primitives, retry/circuit-breaker policy, structured tracing, OpenTelemetry export, and Mixpanel compatibility.

- **Rust crates:** `xai-grok-http`, `xai-circuit-breaker`, `xai-tracing`, `xai-tracing-macros`, `xai-grok-telemetry`, `xai-mixpanel`
- **Swift targets:** `OpenGrokHTTP`, `OpenGrokCircuitBreaker`, `OpenGrokTracing`, `OpenGrokTelemetry`
- **Owned paths:** `Sources/OpenGrokHTTP/`, `Tests/OpenGrokHTTPTests/`, `Sources/OpenGrokCircuitBreaker/`, `Tests/OpenGrokCircuitBreakerTests/`, `Sources/OpenGrokTracing/`, `Tests/OpenGrokTracingTests/`, `Sources/OpenGrokTelemetry/`, `Tests/OpenGrokTelemetryTests/`
- **Depends on:** `W0-S3`, `W0-S4`, `W1-S5`
- **Reference/invariants:** Reference: xai-grok-http, xai-circuit-breaker, xai-tracing plus macro behavior folded into ordinary Swift APIs, xai-grok-telemetry, and xai-mixpanel.
- **Acceptance:**
  - URLSession/FoundationNetworking clients support streaming bytes, cancellation, proxy/TLS settings, bounded buffering, response metadata, and deterministic mock transports.
  - Retry and circuit-breaker decisions use injectable clocks, honor Retry-After, distinguish retryable transport/status failures, and never retry partial non-idempotent streams.
  - Tracing spans preserve session/turn/tool/provider correlation while redacting credentials, prompts, private headers, and filesystem content by default.
  - OpenTelemetry, usage telemetry, and Mixpanel-compatible events are independently disableable and provider export boundaries can veto emission before serialization.

#### W2-S2 — SQLite journal, secrets, and file utilities

Port atomic file primitives, schema-versioned SQLite journaling, secure credential storage adapters, checksums, locking, and owner-only persistence.

- **Rust crates:** `xai-sqlite-journal`, `xai-grok-secrets`, `xai-file-utils`
- **Swift targets:** `OpenGrokSQLiteJournal`, `OpenGrokSecrets`, `OpenGrokFileUtils`
- **Owned paths:** `Sources/OpenGrokSQLiteJournal/`, `Tests/OpenGrokSQLiteJournalTests/`, `Sources/OpenGrokSecrets/`, `Tests/OpenGrokSecretsTests/`, `Sources/OpenGrokFileUtils/`, `Tests/OpenGrokFileUtilsTests/`
- **Depends on:** `W0-S2`, `W0-S3`, `W0-S4`, `W1-S5`
- **Reference/invariants:** Reference: xai-sqlite-journal, xai-grok-secrets, and xai-file-utils. Any third-party SQLite wrapper must be pinned, license-audited, and hidden behind OpenGrokSQLiteJournal.
- **Acceptance:**
  - SQLite operations are isolated in an actor, use explicit transactions/WAL policy, migrate deterministically, and recover from interrupted writes without partial logical records.
  - Atomic write/rename/fsync and advisory-lock behavior is tested on macOS and Linux, with Windows ReplaceFile/locking seams and explicit error mapping.
  - SecretStore uses Keychain on macOS; Linux defaults to typed unsupported with an explicitly requested owner-only fallback until Secret Service/libsecret is linked; Windows remains typed unsupported until Credential Manager or an equivalent owner-only adapter is linked. Plaintext fallback is never silent.
  - Checksum, permissions, canonicalization, and symlink tests cover hostile paths and concurrent writers.

#### W2-S3 — Filesystem watch, Git status, code graph, and hunk attribution

Port filesystem events, Git status/index reading, codebase graph extraction, and explicit agent hunk ownership.

- **Rust crates:** `xai-fsnotify`, `xai-gix-status`, `xai-codebase-graph`, `xai-hunk-tracker`
- **Swift targets:** `OpenGrokFSNotify`, `OpenGrokGitStatus`, `OpenGrokCodebaseGraph`, `OpenGrokHunkTracker`
- **Owned paths:** `Sources/OpenGrokFSNotify/`, `Tests/OpenGrokFSNotifyTests/`, `Sources/OpenGrokGitStatus/`, `Tests/OpenGrokGitStatusTests/`, `Sources/OpenGrokCodebaseGraph/`, `Tests/OpenGrokCodebaseGraphTests/`, `Sources/OpenGrokHunkTracker/`, `Tests/OpenGrokHunkTrackerTests/`
- **Depends on:** `W0-S2`, `W0-S3`, `W0-S4`
- **Reference/invariants:** Reference: xai-fsnotify, xai-gix-status, xai-codebase-graph, and xai-hunk-tracker source/tests.
- **Acceptance:**
  - Watch adapters normalize FSEvents/kqueue, inotify, and ReadDirectoryChangesW into ordered create/modify/remove/rename/overflow events with cancellation-safe teardown.
  - Git status matches Rust fixtures for staged, unstaged, untracked, ignored, rename, conflict, submodule, and worktree cases without invoking a shell for the pure path.
  - Code graph extraction is deterministic, incrementally invalidated, bounded, and independent of UI/provider layers.
  - Every successful agent write records session/agent attribution and changed hunks directly; filesystem notifications are never treated as authorship evidence.

#### W2-S4 — PTY, TTY, process, power, and crash adapters

Port pseudoterminal/process-group control, TTY detection/raw mode, power inhibition, CLI PTY diagnostics, and crash-report capture.

- **Rust crates:** `ptyctl`, `ptyctl-cli`, `xai-tty-utils`, `xai-system-power`, `xai-crash-handler`
- **Swift targets:** `OpenGrokPTY`, `OpenGrokPTYCLI`, `OpenGrokTTY`, `OpenGrokSystemPower`, `OpenGrokCrashHandler`
- **Owned paths:** `Sources/OpenGrokPTY/`, `Tests/OpenGrokPTYTests/`, `Sources/OpenGrokPTYCLI/`, `Tests/OpenGrokPTYCLITests/`, `Sources/OpenGrokTTY/`, `Tests/OpenGrokTTYTests/`, `Sources/OpenGrokSystemPower/`, `Tests/OpenGrokSystemPowerTests/`, `Sources/OpenGrokCrashHandler/`, `Tests/OpenGrokCrashHandlerTests/`
- **Depends on:** `W0-S2`, `W0-S3`, `W0-S4`
- **Reference/invariants:** Reference: ptyctl, ptyctl-cli, xai-tty-utils, xai-system-power, and xai-crash-handler.
- **Acceptance:**
  - macOS/Linux PTY adapters preserve window size, process groups, signals, EOF, exit status, and cancellation; Windows uses ConPTY with explicit unsupported errors only for absent semantics.
  - Raw-mode setup/restoration is idempotent and restored on normal exit, throw, cancellation, and crash signal paths.
  - Power inhibition maps to IOPM assertions, Linux inhibitor facilities, and SetThreadExecutionState through one lease protocol.
  - Crash reports redact secrets, write only below OPENGROK_HOME, and never corrupt active session journals.

#### W2-S5 — Custom terminal and text-area core

Create the platform-neutral cell grid, viewport, diff renderer, input event model, inline/fullscreen terminal driver, and Unicode text editor.

- **Rust crates:** `xai-ratatui-inline`, `xai-ratatui-textarea`
- **Swift targets:** `OpenGrokTerminalCore`, `OpenGrokTextArea`
- **Owned paths:** `Sources/OpenGrokTerminalCore/`, `Tests/OpenGrokTerminalCoreTests/`, `Sources/OpenGrokTextArea/`, `Tests/OpenGrokTextAreaTests/`
- **Depends on:** `W0-S2`, `W0-S4`
- **Reference/invariants:** Reference: xai-ratatui-inline and xai-ratatui-textarea, but the Swift design is a custom terminal abstraction rather than a framework-bound UI.
- **Acceptance:**
  - Terminal domain state imports no AppKit, UIKit, SwiftUI, or platform console module; adapters exchange cells, capabilities, and input events only.
  - Grid diffing, inline viewport restoration, alternate-screen behavior, resize, cursor shape, mouse, paste, focus, hyperlinks, color depth, and synchronized output have golden ANSI tests.
  - Text editing handles grapheme clusters, East Asian width, emoji, selections, undo/redo, multiline navigation, word motion, kill/yank, paste, and IME-safe committed text.
  - Ratatui-derived terminal behavior retains NOTICE attribution while Swift code is independently organized and differential-tested.

### Wave 3 — Authentication, models, providers, and streaming

Deliver isolated credential stores, catalog/model resolution, and provider-neutral sampling with exact xAI, Codex, Kimi, Fireworks, Chat, Responses, and Messages semantics.

#### W3-S1 — Provider authentication

Port xAI login/session refresh, API keys, OIDC/external auth, device flow, and the isolated Codex OAuth store/resolver.

- **Rust crates:** `xai-grok-auth`
- **Swift targets:** `OpenGrokAuth`
- **Owned paths:** `Sources/OpenGrokAuth/`, `Tests/OpenGrokAuthTests/`
- **Depends on:** `W0-S2`, `W0-S3`, `W0-S4`, `W1-S5`, `W2-S1`, `W2-S2`
- **Reference/invariants:** Reference: xai-grok-auth plus shell auth modules and docs/agents/providers.md, docs/provider-architecture.md, and docs/codex-provider-port.md.
- **Acceptance:**
  - Bare login/logout remains xAI; --codex and --all operate on the isolated Codex store, and Codex-only headless startup never requires xAI authentication.
  - Explicit model API keys outrank built-in OAuth; bearer plus account/FedRAMP headers come atomically from one credential snapshot.
  - Refresh, logout, account rotation, revocation, PKCE callback, device-code polling, OIDC, and external-auth cancellation tests fail closed without stale-token fallback.
  - xAI auth.json, Codex codex-auth.json, caches, billing state, and ACP primary-auth state cannot read or mutate one another.

#### W3-S2 — Model catalogs and provider profiles

Port built-in/remote/custom model catalogs, provider identity, capability metadata, live Codex model caching, filtering, aliases, and effort/tool-mode resolution.

- **Rust crates:** `xai-grok-models`
- **Swift targets:** `OpenGrokModels`
- **Owned paths:** `Sources/OpenGrokModels/`, `Tests/OpenGrokModelsTests/`
- **Depends on:** `W0-S2`, `W0-S3`, `W0-S4`, `W1-S3`, `W1-S5`, `W2-S1`
- **Reference/invariants:** Reference: xai-grok-models and shell model catalog modules; use injected credential snapshots so this slice remains independent of OpenGrokAuth.
- **Acceptance:**
  - Provider identity comes only from model metadata; unknown explicit providers/backends fail closed and provider omission retains only the documented legacy xAI default.
  - Catalog merge order preserves embedded fallback, provider live data, cache identity/TTL/ETag, remote catalog rules, and highest-priority user [model.*] entries.
  - Capabilities include backend, context, effort, reasoning summary, hosted tools/search, tool mode, multi-agent version, auto-compaction limit, comp_hash, and auxiliary-model policy.
  - Codex cache is separate from xAI models_cache.json and live Codex refresh cannot add/remove xAI models or inspect xAI credentials.

#### W3-S3 — Sampler and provider adapters

Port request conversion, Chat/Responses/Messages streaming, provider adapters, retries, structured output, hosted tools, usage, images, and cancellation.

- **Rust crates:** `xai-grok-sampler`
- **Swift targets:** `OpenGrokSampler`
- **Owned paths:** `Sources/OpenGrokSampler/`, `Tests/OpenGrokSamplerTests/`
- **Depends on:** `W0-S2`, `W0-S4`, `W1-S1`, `W1-S3`, `W1-S5`, `W2-S1`
- **Reference/invariants:** Reference: xai-grok-sampler source/tests and provider/Codex architecture docs. Neither adapters nor backends own credential persistence.
- **Acceptance:**
  - AsyncThrowingStream output preserves server event order, backpressure bounds, terminal/delta deduplication, tool argument assembly, usage, cancellation, and partial-response failure semantics.
  - ApiBackend, ProviderProfile, response dialect, hosted-tool schema, AuthScheme, and BearerResolver remain independent axes with one adapter per built-in provider.
  - xAI, Codex, Kimi, and Fireworks request/stream golden tests cover private headers, unknown-event policy, retries, cache/sticky turn state, structured output, hosted search, and credential isolation.
  - Codex output_item.done durability, reasoning/encrypted content, image sanitization, one 401 refresh, prompt-cache key, x-codex-turn-state, and provider-native history replay match the pinned compatibility contract.

### Wave 4 — Workspace, permissions, sandbox, worktrees, and Computer Hub

Enforce all local capability boundaries and provide the filesystem/process/worktree services used by tools and agents.

#### W4-S1 — Sandbox adapters

Port sandbox policy compilation, process launch integration, capability detection, and persisted sandbox-mode pinning.

- **Rust crates:** `xai-grok-sandbox`
- **Swift targets:** `OpenGrokSandbox`
- **Owned paths:** `Sources/OpenGrokSandbox/`, `Tests/OpenGrokSandboxTests/`
- **Depends on:** `W0-S2`, `W0-S3`, `W1-S4`, `W1-S5`, `W2-S2`, `W2-S4`
- **Reference/invariants:** Reference: xai-grok-sandbox and docs/agents/permissions-and-sandbox.md. Exact platform enforcement may differ, but capability outcomes and failure policy may not.
- **Acceptance:**
  - Sandbox mode is selected before agent work, persisted with the session, and cannot silently weaken on resume.
  - macOS Seatbelt, Linux capability/Landlock/bubblewrap-style enforcement, and Windows restricted-token/job/filesystem seams implement one protocol; unavailable guarantees produce explicit unsupported/fail-closed results.
  - Profiles allow only declared project, OPENGROK_HOME, temp, network, process, and tool-bundle capabilities and defend against symlink/path traversal escapes.
  - YOLO affects permission prompts only and never disables the process-wide sandbox selected at startup.

#### W4-S2 — Fast worktrees

Port worktree creation/removal/status, repository discovery, branch/ref safety, conflict handling, and session worktree metadata.

- **Rust crates:** `xai-fast-worktree`
- **Swift targets:** `OpenGrokFastWorktree`
- **Owned paths:** `Sources/OpenGrokFastWorktree/`, `Tests/OpenGrokFastWorktreeTests/`
- **Depends on:** `W0-S2`, `W0-S3`, `W2-S2`, `W2-S3`
- **Reference/invariants:** Reference: xai-fast-worktree and shell/workspace worktree consumers.
- **Acceptance:**
  - Create/list/remove operations match Git behavior for bare/non-bare repos, nested roots, dirty state, detached heads, branch collisions, and interrupted cleanup.
  - Worktree names/paths are deterministic, remain inside approved roots, and resist symlink and argument-injection attacks.
  - Operations expose progress/cancellation and leave recoverable metadata rather than half-created session state.
  - Fixture repositories validate parity with Rust fast-worktree outcomes on macOS and Linux; Windows path/ref cases are included.

#### W4-S3 — Workspace and permission engine

Port folder trust, permission rule parsing/evaluation, filesystem/process mediation, path locks, foreign sessions, terminal state, and workspace RPC services.

- **Rust crates:** `xai-grok-workspace`
- **Swift targets:** `OpenGrokWorkspace`
- **Owned paths:** `Sources/OpenGrokWorkspace/`, `Tests/OpenGrokWorkspaceTests/`
- **Depends on:** `W0-S2`, `W0-S3`, `W0-S4`, `W1-S1`, `W1-S4`, `W1-S5`, `W2-S2`, `W2-S3`, `W2-S4`
- **Reference/invariants:** Reference: xai-grok-workspace permission/, file_system/, foreign_sessions/, terminal/process code and docs/agents/permissions-and-sandbox.md.
- **Acceptance:**
  - Permission order is plan edit gate -> fail-open PreToolUse hooks -> plan-file auto-approval -> permission engine -> dispatch, with deny > ask > allow and exact rule-source audit data.
  - Rule DSL and bash segmentation match Rust for command chains, redirections, subshells, environment prefixes, quoted arguments, paths, network, and tool groups.
  - Folder trust, per-project rules, session grants, CLI allow/deny, permission modes, no-ask behavior, and YOLO produce deterministic decisions with deny/fail-closed tests.
  - Filesystem and process operations acquire canonical path/resource locks, enforce workspace/sandbox capabilities, and cannot race permission approval against changed arguments.

#### W4-S4 — Computer Hub and workspace client

Port Computer Hub core contracts/SDK plus local/remote workspace clients for terminals, processes, files, images, and capability discovery.

- **Rust crates:** `xai-computer-hub-core`, `xai-computer-hub-sdk`, `xai-grok-workspace-client`
- **Swift targets:** `OpenGrokComputerHubCore`, `OpenGrokComputerHubSDK`, `OpenGrokWorkspaceClient`
- **Owned paths:** `Sources/OpenGrokComputerHubCore/`, `Tests/OpenGrokComputerHubCoreTests/`, `Sources/OpenGrokComputerHubSDK/`, `Tests/OpenGrokComputerHubSDKTests/`, `Sources/OpenGrokWorkspaceClient/`, `Tests/OpenGrokWorkspaceClientTests/`
- **Depends on:** `W0-S2`, `W0-S4`, `W1-S1`, `W1-S4`, `W2-S1`, `W2-S4`
- **Reference/invariants:** Reference: xai-computer-hub-core, xai-computer-hub-sdk, and xai-grok-workspace-client; MCP adaptation is Wave 5.
- **Acceptance:**
  - Hub requests are capability-scoped, cancellable, bounded, and preserve structured text/image/binary results.
  - Local and remote clients expose the same protocol and reject unsupported operations explicitly rather than falling back to local execution.
  - Terminal/process session IDs, resize/input/output, lifecycle, and disconnect/reconnect ordering are fixture-tested.
  - No Hub adapter bypasses workspace permission or sandbox mediation when invoked by an agent.

### Wave 5 — Tools, MCP, extensions, and auxiliary product services

Implement the full tool catalog and extension ecosystem against the already-ported permission/workspace/provider contracts, with conflict-free target ownership.

#### W5-S1 — Tool registry, finalization, file search, and editing

Port registry construction/finalization and all read/search/list/write/patch/edit tools, including Code Mode namespace metadata.

- **Rust crates:** `xai-grok-tools`
- **Swift targets:** `OpenGrokToolRegistry`, `OpenGrokFileTools`
- **Owned paths:** `Sources/OpenGrokToolRegistry/`, `Tests/OpenGrokToolRegistryTests/`, `Sources/OpenGrokFileTools/`, `Tests/OpenGrokFileToolsTests/`
- **Depends on:** `W0-S2`, `W1-S1`, `W1-S3`, `W1-S4`, `W2-S2`, `W2-S3`, `W4-S3`
- **Reference/invariants:** Reference: xai-grok-tools registry, bridge, types, util, and file/edit/search implementation trees plus docs/agents/tools.md and editing.md.
- **Acceptance:**
  - Registry finalization deterministically applies tool mode, packs, allow/deny filters, capability checks, hosted tools, direct-only controls, MCP tools, and Code Mode namespaces.
  - read_file, list_dir, grep, glob/search, search_replace, apply_patch, hashline/OpenCode edit, write, and image/file readers match schemas, limits, and structured results.
  - Edit tools enforce plan gate and permissions before dispatch, use atomic writes/path locks, detect stale context, and record hunk attribution only after success.
  - Output caps preserve head/tail/truncation metadata and Code Mode nested calls re-enter the same full prepare/gate/dispatch pipeline.

#### W5-S2 — Execution, background, web, media, and computer tools

Port bash/process, terminal, background task, monitor, scheduler, web, browser/computer, media, clipboard, LSP, and related tool implementations.

- **Rust crates:** `xai-grok-tools`
- **Swift targets:** `OpenGrokExecutionTools`, `OpenGrokWebMediaTools`
- **Owned paths:** `Sources/OpenGrokExecutionTools/`, `Tests/OpenGrokExecutionToolsTests/`, `Sources/OpenGrokWebMediaTools/`, `Tests/OpenGrokWebMediaToolsTests/`
- **Depends on:** `W0-S2`, `W1-S1`, `W1-S3`, `W2-S1`, `W2-S4`, `W3-S3`, `W4-S3`, `W4-S4`
- **Reference/invariants:** Reference: xai-grok-tools implementations for bash/background/monitor/scheduler/terminal/web/media/computer/LSP/clipboard.
- **Acceptance:**
  - Foreground/background commands preserve environment/cwd, PTY choice, process groups, streaming, timeout escalation, cancellation, output files, and task IDs.
  - monitor, wait, kill, scheduler, terminal, LSP, web fetch/search, computer, image/media, clipboard, and power leases expose exact schemas and permission categories.
  - Network/media tools honor provider capabilities and export boundaries; Codex tokens are never reused for xAI media and hidden tools stay hidden after model switches.
  - All process/network/computer calls pass workspace permission and sandbox checks and have denial, cancellation, timeout, truncation, and resource-cleanup tests.

#### W5-S3 — Agent-control and human-interaction tools

Port plan/todo/goal, task/swarm/workflow, wait/kill, ask-user, interjection, usage, and collaboration tool surfaces without owning their later session engines.

- **Rust crates:** `xai-grok-tools`
- **Swift targets:** `OpenGrokAgentControlTools`
- **Owned paths:** `Sources/OpenGrokAgentControlTools/`, `Tests/OpenGrokAgentControlToolsTests/`
- **Depends on:** `W0-S2`, `W1-S1`, `W1-S2`, `W1-S4`, `W4-S2`, `W4-S3`
- **Reference/invariants:** Reference: xai-grok-tools agent/task/plan/goal/todo/ask-user implementations and tool-mode finalization rules.
- **Acceptance:**
  - ask_user_question supports ordered single/multi-select questions, recommended labels, previews, Other input, ACP reverse requests, and cancellation.
  - todo_write, update_goal, plan entry/exit, task, swarm, workflow, wait, and kill schemas match the Rust registry and expose immutable requests to injected engines.
  - Direct-only collaboration controls remain top-level in Code Mode Only and are excluded from generated tools.* namespaces.
  - No control tool mutates session state directly; tests prove all state changes pass through the owning session/coordinator actor.

#### W5-S4 — MCP transports, OAuth, and Computer Hub adapter

Port MCP configuration/discovery, stdio and network transports, OAuth, search/use meta-tools, resource/prompt support, and Computer Hub exposure.

- **Rust crates:** `xai-grok-mcp`, `xai-computer-hub-mcp-adapter`
- **Swift targets:** `OpenGrokMCP`, `OpenGrokComputerHubMCPAdapter`
- **Owned paths:** `Sources/OpenGrokMCP/`, `Tests/OpenGrokMCPTests/`, `Sources/OpenGrokComputerHubMCPAdapter/`, `Tests/OpenGrokComputerHubMCPAdapterTests/`
- **Depends on:** `W0-S2`, `W0-S3`, `W1-S1`, `W1-S4`, `W1-S5`, `W2-S1`, `W2-S2`, `W4-S4`
- **Reference/invariants:** Reference: xai-grok-mcp and xai-computer-hub-mcp-adapter plus docs/agents/tools.md and user-guide MCP chapter.
- **Acceptance:**
  - stdio, streamable HTTP/SSE, and supported WebSocket transports preserve initialization, capabilities, progress, cancellation, reconnect, stderr, and shutdown ordering.
  - OAuth discovery, PKCE/device/browser flows, token refresh, scopes, and secure persistence are server-scoped and never share provider credential stores.
  - search_tool and use_tool expose only finalized authorized MCP tools, preserve exact JSON schemas/content blocks, and enforce output limits.
  - Computer Hub MCP operations remain capability/permission mediated and malformed or disconnected servers cannot crash the tool registry.

#### W5-S5 — Hooks, plugins, skills, and marketplace

Port discovery, trust, precedence, hook execution, plugin manifests/marketplaces, skill loading, and session-scoped extension state.

- **Rust crates:** `xai-grok-hooks`, `xai-grok-plugin-marketplace`
- **Swift targets:** `OpenGrokHooks`, `OpenGrokPluginMarketplace`
- **Owned paths:** `Sources/OpenGrokHooks/`, `Tests/OpenGrokHooksTests/`, `Sources/OpenGrokPluginMarketplace/`, `Tests/OpenGrokPluginMarketplaceTests/`
- **Depends on:** `W0-S2`, `W0-S3`, `W1-S4`, `W1-S5`, `W2-S1`, `W2-S2`, `W4-S3`
- **Reference/invariants:** Reference: xai-grok-hooks, xai-grok-plugin-marketplace, hooks/plugins/skills docs, and shell/pager extension discovery consumers.
- **Acceptance:**
  - Hook discovery/order/matchers, command environment, timeout, JSON input/output, and allow/deny/modify responses match Rust; operational hook failures remain fail-open and observable.
  - Project extension files require folder trust and cannot escape configured roots or inject unapproved environment/commands.
  - Plugin install/update/remove/list/marketplace operations verify source, version, conflicts, permissions, atomic replacement, and rollback.
  - Skill precedence, frontmatter validation, activation, references/scripts, session load, and slash visibility match the documented user behavior.

#### W5-S6 — Agent definitions, announcements, update, and voice

Port AGENTS/rules/persona/skill composition and the independent announcement, updater, release-channel, audio capture/playback, and voice-session services.

- **Rust crates:** `xai-grok-agent`, `xai-grok-announcements`, `xai-grok-update`, `xai-grok-voice`
- **Swift targets:** `OpenGrokAgentDefinitions`, `OpenGrokAnnouncements`, `OpenGrokUpdate`, `OpenGrokVoice`
- **Owned paths:** `Sources/OpenGrokAgentDefinitions/`, `Tests/OpenGrokAgentDefinitionsTests/`, `Sources/OpenGrokAnnouncements/`, `Tests/OpenGrokAnnouncementsTests/`, `Sources/OpenGrokUpdate/`, `Tests/OpenGrokUpdateTests/`, `Sources/OpenGrokVoice/`, `Tests/OpenGrokVoiceTests/`
- **Depends on:** `W0-S2`, `W0-S3`, `W0-S4`, `W1-S3`, `W1-S5`, `W2-S1`, `W2-S2`, `W2-S4`, `W3-S3`
- **Reference/invariants:** Reference: xai-grok-agent, xai-grok-announcements, xai-grok-update, xai-grok-voice, CLI update/login surfaces, and user-guide voice/update behavior.
- **Acceptance:**
  - Instruction discovery honors AGENTS.md scope/precedence, user/project rules, personas, skills, tool capability mode, and deterministic prompt composition.
  - Announcements are cached and rendered without blocking startup; telemetry/export policy is applied before network requests.
  - Updater supports check/json/force-reinstall/version/channel semantics, GitHub Open Grok releases, SHA-256 verification, atomic replacement/rollback, disable flags, and platform-specific executable handling.
  - Voice/audio services are actor-isolated, permission-aware, cancellable, and use AVFoundation on macOS plus explicit Linux/Windows adapters or honest unsupported capability results.

### Wave 6 — Code Mode, compaction, memory, goals, and shell support

Port the stateful engines that sessions will own, with persistence-neutral protocols and exact lifecycle/cancellation behavior.

#### W6-S1 — Code Mode runtime

Port the Codex-derived persistent JavaScript cell runtime, nested tool bridge, yield/wait/terminate behavior, transport projection, and lifecycle reset rules.

- **Rust crates:** `xai-grok-code-mode`
- **Swift targets:** `OpenGrokCodeMode`, `OpenGrokJavaScriptRuntime`
- **Owned paths:** `Sources/OpenGrokCodeMode/`, `Tests/OpenGrokCodeModeTests/`, `Sources/OpenGrokJavaScriptRuntime/`, `Tests/OpenGrokJavaScriptRuntimeTests/`
- **Depends on:** `W0-S2`, `W1-S1`, `W1-S3`, `W1-S4`, `W2-S1`, `W5-S1`, `W5-S2`, `W5-S3`
- **Reference/invariants:** Reference: xai-grok-code-mode, xai-grok-code-mode-protocol, NOTICE-pinned Codex revision, docs/agents/code-mode.md, and docs/code-mode-port.md. The JavaScript engine is behind a protocol and must pass pinned behavioral fixtures on every supported OS.
- **Acceptance:**
  - One runtime is owned per compatible session timeline; rewind, incompatible provider/transport change, and session close dispose it and invalidate stale callbacks/cell IDs.
  - Codex native custom exec and xAI function-envelope exec project the same raw JavaScript contract; unsupported routes fail closed.
  - Cells can complete, yield nested tool calls, continue in background, resume, or terminate while preserving structured text/image/generated-image/error content and cancellation.
  - Outer exec/wait remain durable model history but are hidden as TUI transport details; only decoded nested tools/cards appear live and on replay.

#### W6-S2 — Compaction engine

Port provider-neutral/local compaction plus Codex remote compaction V2 and retained unary compatibility with atomic replacement semantics.

- **Rust crates:** `xai-grok-compaction`
- **Swift targets:** `OpenGrokCompaction`
- **Owned paths:** `Sources/OpenGrokCompaction/`, `Tests/OpenGrokCompactionTests/`
- **Depends on:** `W0-S2`, `W1-S3`, `W2-S1`, `W3-S2`, `W3-S3`
- **Reference/invariants:** Reference: xai-grok-compaction, sampler compaction paths, docs/agents/sessions.md, and docs/codex-provider-port.md.
- **Acceptance:**
  - Automatic/manual thresholds use model context, operator overrides, comp_hash changes, and token estimates exactly as documented.
  - Codex V2 sends a streaming Responses request with compaction_trigger and accepts exactly one durable compaction item only after response.completed; partial failures install nothing.
  - Legacy /responses/compact is selected before an operation and V2 failure never silently falls back; retries/auth refresh and sticky turn state remain operation-scoped.
  - Replacement history preserves bounded newest real-user messages, prompt markers, allowed images, opaque provider carriers, concurrent steering prefix rules, and provider-neutral fallback boundaries.

#### W6-S3 — Memory and goal state

Port memory files/index/search/embedding/flush/dream behavior and extract the pure goal state machine used by session/tool layers.

- **Rust crates:** `xai-grok-memory`, `xai-grok-shell`
- **Swift targets:** `OpenGrokMemory`, `OpenGrokGoalState`
- **Owned paths:** `Sources/OpenGrokMemory/`, `Tests/OpenGrokMemoryTests/`, `Sources/OpenGrokGoalState/`, `Tests/OpenGrokGoalStateTests/`
- **Depends on:** `W0-S2`, `W0-S3`, `W0-S4`, `W1-S3`, `W1-S5`, `W2-S2`, `W2-S3`, `W3-S3`
- **Reference/invariants:** Reference: xai-grok-memory and shell goal modules documented in docs/agents/memory-and-goals.md.
- **Acceptance:**
  - Memory resolves only under OPENGROK_HOME, maintains schema/versioned indexes atomically, and supports ranked search plus targeted reads with deterministic fixtures.
  - Memory flush/dream is cancellation-safe, resumable, bounded, and never exposes provider-prohibited session content to legacy xAI memory/embed/export services.
  - Goal transitions cover active/completed/blocked/resumed states, reject invalid completion/block combinations, and persist progress messages in order.
  - Provider provenance, session/tree ownership, feature flags, no-memory modes, and concurrent index/update tests enforce isolation.

#### W6-S4 — Shell base and session support

Port shared shell services, session DTOs/events, persistence interfaces, tool-history sinks, auth/model abstractions, and local ownership protocols.

- **Rust crates:** `xai-grok-shell-base`, `xai-grok-shell-session-support`
- **Swift targets:** `OpenGrokShellBase`, `OpenGrokShellSessionSupport`
- **Owned paths:** `Sources/OpenGrokShellBase/`, `Tests/OpenGrokShellBaseTests/`, `Sources/OpenGrokShellSessionSupport/`, `Tests/OpenGrokShellSessionSupportTests/`
- **Depends on:** `W0-S2`, `W0-S3`, `W0-S4`, `W1-S1`, `W1-S2`, `W1-S3`, `W1-S4`, `W1-S5`, `W2-S1`, `W2-S2`, `W3-S1`, `W3-S2`, `W3-S3`, `W4-S3`, `W5-S1`
- **Reference/invariants:** Reference: xai-grok-shell-base and xai-grok-shell-session-support; this slice deliberately excludes the concrete xai-grok-shell session actor.
- **Acceptance:**
  - Session snapshots/events are immutable Sendable values and all mutable live state is reachable only through an owning actor protocol.
  - Tool history distinguishes model-visible, durable replay, live UI, Code Mode transport, nested tools, and redacted/export-safe views.
  - Cancellation IDs and continuation registries enforce exactly-once completion with no detached task mutating session state directly.
  - Protocol fakes allow Wave 7 turn, persistence, provider, coordinator, and ACP slices to build independently.

#### W6-S5 — Subagent and persona resolution

Port role/persona/agent resolution, capability modes, hierarchy validation, and configuration merging used by task/swarm/workflow orchestration.

- **Rust crates:** `xai-grok-subagent-resolution`
- **Swift targets:** `OpenGrokSubagentResolution`
- **Owned paths:** `Sources/OpenGrokSubagentResolution/`, `Tests/OpenGrokSubagentResolutionTests/`
- **Depends on:** `W0-S2`, `W0-S4`, `W1-S4`, `W1-S5`, `W4-S2`, `W5-S6`
- **Reference/invariants:** Reference: xai-grok-subagent-resolution and docs/agents/subagents.md.
- **Acceptance:**
  - Resolution precedence across built-ins, user/project config, personas, agents JSON, and call-time overrides is deterministic and validated.
  - Maximum subagent depth is one, cycles/unknown roles fail before spawn, and capability/tool/permission modes cannot escalate beyond the parent.
  - Children inherit the parent's permission handle, receive a fresh inactive plan tracker, and carry explicit provider/session/worktree provenance.
  - Golden tests cover task, swarm, workflow, resume, best-of-N, role prompts, and invalid hierarchy/config cases.

### Wave 7 — Session actor, persistence, provider policy, coordination, and ACP

Assemble independently testable xai-grok-shell components around the shared actor-owned session contracts without yet coupling them to the pager.

#### W7-S1 — Turn loop and tool pipeline

Port the live session actor's turn state machine, sampling/tool loop, steering/interjections, permission gate sequence, cancellation, and background task integration.

- **Rust crates:** `xai-grok-shell`
- **Swift targets:** `OpenGrokSessionRuntime`
- **Owned paths:** `Sources/OpenGrokSessionRuntime/`, `Tests/OpenGrokSessionRuntimeTests/`
- **Depends on:** `W0-S2`, `W1-S1`, `W1-S2`, `W1-S3`, `W2-S1`, `W3-S3`, `W4-S3`, `W5-S1`, `W5-S2`, `W5-S3`, `W6-S1`, `W6-S4`
- **Reference/invariants:** Reference: xai-grok-shell/src/session turn loop, tool dispatch, interjection, plan, permission, and background modules plus agent-runtime.md.
- **Acceptance:**
  - One SessionActor owns each live session; prompt, stream delta, tool result, steer, permission response, compaction, rewind, cancel, and close events are processed serially.
  - Turn ordering matches Rust across multiple tool calls, queued prompts, interjections, partial streams, retries, background work, and max-turn termination.
  - Tool invocation always executes plan edit gate -> fail-open hooks -> plan-file auto-approval -> permission evaluation -> dispatch and records history/attribution only after outcomes.
  - Cancellation propagates to sampling, tools, Code Mode cells, permission prompts, and background waits without double completion or post-close mutation.

#### W7-S2 — Session persistence, history, fork, rewind, and resume

Port the persistence actor, storage layout, snapshots/events, session administration, fork/rewind/restore-code, recap, recovery, and migration logic.

- **Rust crates:** `xai-grok-shell`
- **Swift targets:** `OpenGrokSessionPersistence`
- **Owned paths:** `Sources/OpenGrokSessionPersistence/`, `Tests/OpenGrokSessionPersistenceTests/`
- **Depends on:** `W0-S2`, `W0-S3`, `W0-S4`, `W1-S3`, `W2-S2`, `W6-S2`, `W6-S3`, `W6-S4`
- **Reference/invariants:** Reference: xai-grok-shell persistence/session-admin modules and docs/agents/sessions.md.
- **Acceptance:**
  - All session state lives below OPENGROK_HOME with stable session IDs, metadata, transcripts, opaque provider items, usage, goals, worktrees, sandbox mode, and Code Mode resolution.
  - Persistence is serialized through one actor, uses atomic/checksummed writes or transactions, and recovers from interruption without accepting torn snapshots.
  - Resume/load/continue/fork/rewind semantics match CLI and ACP behavior, including transcript truncation, code restoration options, parent/child lineage, and replay filtering.
  - Golden migrations consume representative Rust sessions and preserve unknown fields, encrypted/opaque history, attribution, compaction, memory flags, and export-boundary markers.

#### W7-S3 — Provider-aware session composition

Port per-turn model/auth/backend resolution, live switching, usage, auxiliary requests, hosted-tool visibility, compaction selection, and monotonic export isolation.

- **Rust crates:** `xai-grok-shell`
- **Swift targets:** `OpenGrokProviderSession`
- **Owned paths:** `Sources/OpenGrokProviderSession/`, `Tests/OpenGrokProviderSessionTests/`
- **Depends on:** `W0-S2`, `W1-S3`, `W1-S5`, `W3-S1`, `W3-S2`, `W3-S3`, `W5-S2`, `W6-S1`, `W6-S2`, `W6-S3`, `W6-S4`
- **Reference/invariants:** Reference: xai-grok-shell auth/models/provider/usage/session composition and provider architecture docs.
- **Acceptance:**
  - Every turn resolves provider from model metadata and uses only that provider's credential source, headers, adapter, tools, auxiliary defaults, and retry policy.
  - Live model switches rebuild only provider-dependent state, preserve session ownership/history, hide incompatible tools/media, and never leak credentials or opaque history.
  - Once any non-xAI-export provider is used by a session or descendant, the persisted boundary remains closed for remote sync, relay, registry, feedback, prompt traces, and legacy memory exports.
  - Combined usage fetches providers independently; failure from one does not hide another, and quota windows retain provider duration/reset semantics.

#### W7-S4 — Subagent, swarm, workflow, and worktree coordinator

Port child-agent lifecycle, task/swarm/workflow scheduling, concurrency limits, role prompts, worktree assignment, resume, usage folding, and orphan reconciliation.

- **Rust crates:** `xai-grok-shell`
- **Swift targets:** `OpenGrokAgentCoordinator`
- **Owned paths:** `Sources/OpenGrokAgentCoordinator/`, `Tests/OpenGrokAgentCoordinatorTests/`
- **Depends on:** `W0-S2`, `W1-S2`, `W1-S3`, `W4-S2`, `W4-S3`, `W5-S3`, `W6-S4`, `W6-S5`
- **Reference/invariants:** Reference: xai-grok-shell subagent/coordinator modules and docs/agents/subagents.md.
- **Acceptance:**
  - Maximum depth one is enforced before spawn; children inherit permission handle and export boundary but receive fresh local session/plan/runtime ownership.
  - Task, swarm, workflow, best-of-N, wait, kill, resume, concurrency, cancellation, and completion notifications are deterministic under actor tests.
  - Worktree creation/cleanup, branch ownership, conflict reporting, restore behavior, and child attribution remain linked to persisted session lineage.
  - Child usage/history folds once into the parent, provider boundaries propagate monotonically, and startup reconciliation marks orphans without inventing completion.

#### W7-S5 — ACP stdio, headless, leader, server, and relay

Port ACP agent methods/extensions, reverse RPC, durable/live notifications, in-process channels, stdio, leader sockets, WebSocket serve/relay, and routing.

- **Rust crates:** `xai-grok-shell`
- **Swift targets:** `OpenGrokACPRuntime`
- **Owned paths:** `Sources/OpenGrokACPRuntime/`, `Tests/OpenGrokACPRuntimeTests/`
- **Depends on:** `W0-S2`, `W0-S3`, `W0-S4`, `W1-S2`, `W1-S4`, `W2-S1`, `W4-S3`, `W6-S4`
- **Reference/invariants:** Reference: xai-grok-shell ACP modules and docs/agents/acp.md.
- **Acceptance:**
  - initialize/auth/session new-load-resume-fork-list-prompt-cancel/set-model/set-mode methods and Open Grok meta keys match captured ACP fixtures.
  - Reverse permission, filesystem, terminal, and user-question requests are correlated, cancellable, and completed exactly once.
  - Durable transcript/session updates are separated from live-only progress/deltas so reconnect/replay neither drops history nor duplicates transient events.
  - In-process, stdio, headless, leader local routing, WebSocket serve, and relay transports share one protocol and preserve provider/export/auth restrictions.

### Wave 8 — Markdown, Mermaid, rendering, pager model, and shell composition

Build pure rendering/state foundations and the final shell facade so all Wave 9 pager features can proceed in parallel.

#### W8-S1 — Markdown core and streaming renderer

Port markdown parsing, incremental streaming, code fences/syntax, tables/lists/quotes/links, tool-safe text, and terminal span generation.

- **Rust crates:** `xai-grok-markdown-core`, `xai-grok-markdown`
- **Swift targets:** `OpenGrokMarkdownCore`, `OpenGrokMarkdown`
- **Owned paths:** `Sources/OpenGrokMarkdownCore/`, `Tests/OpenGrokMarkdownCoreTests/`, `Sources/OpenGrokMarkdown/`, `Tests/OpenGrokMarkdownTests/`
- **Depends on:** `W0-S2`, `W0-S4`, `W1-S3`, `W2-S5`
- **Reference/invariants:** Reference: xai-grok-markdown-core, xai-grok-markdown, their tests/fixtures, and the separate fuzz target.
- **Acceptance:**
  - Full and chunked streaming renders converge to identical semantic blocks for every split point in the fixture corpus.
  - CommonMark-like constructs, code fences/languages, tables, lists, quotes, links, inline styles, Unicode width, and malformed input never panic or corrupt terminal state.
  - Syntax/highlight/theme lookup is deterministic and degrades to plain styled text when a grammar is unavailable.
  - Rendered links/code/content retain source ranges needed for selection, copy, inspection, and replay.

#### W8-S2 — Mermaid parsing, layout, and terminal/SVG output

Port Mermaid diagram parsing/rendering plus the ordered graph, Graphlib, Dagre, SVG, theme, and deterministic font/layout stack.

- **Rust crates:** `xai-grok-mermaid`, `dagre_rust`, `graphlib_rust`, `ordered_hashmap`, `mermaid-to-svg`
- **Swift targets:** `OpenGrokMermaidLayout`, `OpenGrokMermaid`
- **Owned paths:** `Sources/OpenGrokMermaidLayout/`, `Tests/OpenGrokMermaidLayoutTests/`, `Sources/OpenGrokMermaid/`, `Tests/OpenGrokMermaidTests/`
- **Depends on:** `W0-S2`, `W0-S4`, `W2-S2`, `W2-S5`
- **Reference/invariants:** Reference: xai-grok-mermaid and third_party/{dagre_rust,graphlib_rust,ordered_hashmap,mermaid-to-svg}.
- **Acceptance:**
  - Supported flow, sequence, class, state, ER, gantt, journey, pie, mindmap, timeline, gitgraph, quadrant, sankey, XY, radar, packet, requirement, C4, kanban, and block fixtures render deterministically.
  - Graph ordering/ranking/coordinate algorithms preserve stable output for equal-rank and cyclic cases and enforce input/size/time limits.
  - SVG output is sanitized and terminal fallback remains readable when graphics protocols are unavailable.
  - Dagre/Graphlib/ordered-hashmap/Mermaid/Roboto notices and source provenance are retained in code comments, notices UI, and distribution artifacts.

#### W8-S3 — Pager rendering, themes, and terminal surfaces

Port pure layout, cell painting, themes, terminal capability negotiation, inline/fullscreen/minimal surfaces, image placement, and render snapshots.

- **Rust crates:** `xai-grok-pager-render`
- **Swift targets:** `OpenGrokPagerRender`
- **Owned paths:** `Sources/OpenGrokPagerRender/`, `Tests/OpenGrokPagerRenderTests/`
- **Depends on:** `W0-S2`, `W0-S4`, `W1-S5`, `W2-S5`
- **Reference/invariants:** Reference: xai-grok-pager-render terminal/theme/render trees and pager appearance docs.
- **Acceptance:**
  - Layout/rendering is a pure function of pager view state, terminal size/capabilities, theme, and time snapshot; no domain mutation occurs during paint.
  - Minimal, inline, and alternate-screen rendering restore host terminal contents/cursor correctly across resize, suspend, crash, and normal exit.
  - Theme parsing/selection, color fallback, status lines, overlays, mouse regions, images, and accessibility/plain-output modes have cell-grid golden tests.
  - Renderer remains independent of AppKit/UIKit and consumes only OpenGrokTerminalCore protocols.

#### W8-S4 — Pager state, actions, effects, and navigation model

Extract the pure Elm-style pager reducer, global state, focus/navigation, keyboard/mouse mapping, scrollback models, modal state, and effect descriptions.

- **Rust crates:** `xai-grok-pager`
- **Swift targets:** `OpenGrokPagerModel`
- **Owned paths:** `Sources/OpenGrokPagerModel/`, `Tests/OpenGrokPagerModelTests/`
- **Depends on:** `W0-S2`, `W0-S4`, `W1-S2`, `W1-S3`, `W1-S4`, `W1-S5`, `W2-S5`, `W7-S5`
- **Reference/invariants:** Reference: xai-grok-pager app/dispatch/action/effect/state, scrollback models, and keyboard/TUI docs.
- **Acceptance:**
  - All user/ACP/timer/terminal inputs become Actions; reducers synchronously return new state plus Effects and perform no I/O.
  - Focus, scroll, selection, compose editing, key chords, paste, mouse, resize, minimal/fullscreen transitions, and modal stacks are deterministic.
  - Live ACP updates and persisted replay reduce through compatible paths without duplicating messages/tool cards or exposing Code Mode transport wrappers.
  - Reducer/property tests cover invalid/out-of-order events, cancellation, reconnect, model switch, permission prompts, and terminal capability changes.

#### W8-S5 — Shell facade and composition root

Compose the Wave 7 session, persistence, provider, coordinator, and ACP components behind the Swift equivalent of xai-grok-shell.

- **Rust crates:** `xai-grok-shell`
- **Swift targets:** `OpenGrokShell`
- **Owned paths:** `Sources/OpenGrokShell/`, `Tests/OpenGrokShellTests/`
- **Depends on:** `W7-S1`, `W7-S2`, `W7-S3`, `W7-S4`, `W7-S5`
- **Reference/invariants:** Reference: xai-grok-shell crate boundary and pager-bin composition; all Package.swift edge changes remain owned by W0-S1.
- **Acceptance:**
  - A single public ShellFactory wires concrete actors/adapters without exposing mutable implementation state or service locators.
  - In-process pager, headless, stdio ACP, leader, serve, and relay entry points receive identical session/provider/tool behavior.
  - Shutdown waits for required persistence, terminates live streams/tools/cells/children, and bounds noncritical telemetry/update cleanup.
  - Composition tests use fakes to prove no dependency cycle, provider credential cross-wiring, permission bypass, or duplicate session actor.

### Wave 9 — TUI feature slices and minimal frontend

Implement the end-user terminal experience in parallel against the pure pager model, renderer, and shell facade.

#### W9-S1 — Pager runtime and effect executor

Port the terminal event loop, reducer driver, effect scheduling, ACP tracker, timers, cancellation, clipboard/terminal integration, and graceful shutdown.

- **Rust crates:** `xai-grok-pager`
- **Swift targets:** `OpenGrokPagerRuntime`
- **Owned paths:** `Sources/OpenGrokPagerRuntime/`, `Tests/OpenGrokPagerRuntimeTests/`
- **Depends on:** `W2-S4`, `W2-S5`, `W5-S2`, `W7-S5`, `W8-S3`, `W8-S4`, `W8-S5`
- **Reference/invariants:** Reference: xai-grok-pager app runtime, ACP tracker, terminal and effect modules.
- **Acceptance:**
  - Actions are processed serially; effects run in structured child tasks and return typed actions tagged to generation/session so stale completions are ignored.
  - Terminal/ACP/input/timer streams preserve ordering, bounded buffering, cancellation, reconnect, suspend/resume, and exact-once shutdown restoration.
  - Clipboard, external editor/browser, shell wrap, notifications, and terminal control pass through capability/OS adapters.
  - Runtime tests inject virtual terminal/time/ACP streams and prove no background task mutates pager state directly.

#### W9-S2 — Conversation, compose, scrollback, and tool-card UI

Port transcript rendering, streaming assistant/reasoning, compose input, selections, tool cards, diffs, images, citations, Markdown, Mermaid, and Code Mode nested display.

- **Rust crates:** `xai-grok-pager`
- **Swift targets:** `OpenGrokPagerConversationUI`
- **Owned paths:** `Sources/OpenGrokPagerConversationUI/`, `Tests/OpenGrokPagerConversationUITests/`
- **Depends on:** `W1-S1`, `W1-S3`, `W2-S5`, `W5-S1`, `W6-S1`, `W8-S1`, `W8-S2`, `W8-S3`, `W8-S4`
- **Reference/invariants:** Reference: xai-grok-pager scrollback/, agent_view/, widgets/, compose/input, and rendering tests.
- **Acceptance:**
  - Live stream and cold replay produce equivalent visible turns, reasoning, tool cards, diffs, citations, images, errors, usage, and compaction markers.
  - Outer Code Mode exec/wait/raw JavaScript/cell transport output stays hidden while decoded nested tool calls/results use ordinary cards.
  - Compose, selection/copy, search, folding, follow-tail, mouse regions, Unicode wrapping, resize anchoring, and large transcript virtualization match documented behavior.
  - Golden terminal snapshots cover direct/mixed/code-mode-only, permission prompts, failed/cancelled tools, background tasks, media, Markdown, Mermaid, and hunk attribution.

#### W9-S3 — Slash commands, settings, modals, extensions, and themes

Port command parsing/completion and the settings/model/permission/MCP/hook/plugin/skill/persona/theme/plan/memory/media/terminal modal flows.

- **Rust crates:** `xai-grok-pager`
- **Swift targets:** `OpenGrokPagerCommandUI`
- **Owned paths:** `Sources/OpenGrokPagerCommandUI/`, `Tests/OpenGrokPagerCommandUITests/`
- **Depends on:** `W1-S5`, `W3-S2`, `W4-S3`, `W5-S3`, `W5-S4`, `W5-S5`, `W5-S6`, `W8-S3`, `W8-S4`
- **Reference/invariants:** Reference: xai-grok-pager slash/, views/, settings/, modal code and docs/agents/tui-and-config.md.
- **Acceptance:**
  - Slash command names, aliases, arguments, completion, help, validation, and unavailable-state messaging match the user-guide surface.
  - Settings reads/writes layered config atomically, labels restart-required changes, preserves unknown keys, and supports reset/rollback.
  - Model/effort/code-mode/permission/sandbox/plan/memory/tool/MCP/hook/plugin/skill/persona/theme/media/terminal flows emit effects rather than performing I/O in reducers.
  - Modal focus, keyboard/mouse operation, previews, confirmations, errors, and cancellation have reducer and snapshot tests.

#### W9-S4 — Sessions, dashboard, usage, auth, update, and operational UI

Port session browser/actions, model/auth/login/logout, usage/quota, dashboard, announcements, update prompts, feedback/privacy, worktree/workspace, and diagnostics views.

- **Rust crates:** `xai-grok-pager`
- **Swift targets:** `OpenGrokPagerOperationsUI`
- **Owned paths:** `Sources/OpenGrokPagerOperationsUI/`, `Tests/OpenGrokPagerOperationsUITests/`
- **Depends on:** `W3-S1`, `W3-S2`, `W5-S6`, `W7-S2`, `W7-S3`, `W7-S4`, `W7-S5`, `W8-S3`, `W8-S4`
- **Reference/invariants:** Reference: xai-grok-pager session, dashboard, auth, usage, update, workspace/worktree, feedback/privacy views.
- **Acceptance:**
  - Session list/load/resume/fork/rewind/share/export/trace/worktree/restore-code actions reflect persisted state and require explicit confirmation for destructive operations.
  - xAI and Codex login/logout/status/usage remain visually and operationally isolated; one provider's failure does not suppress the other.
  - Dashboard surfaces sessions, tasks, background work, goals, usage, providers, worktrees, workspace daemon, telemetry/privacy, updates, and diagnostics without bypassing shell APIs.
  - Update/announcement/feedback/privacy/telemetry UI honors disable/export-boundary policy before requests and has offline/error/retry tests.

#### W9-S5 — Minimal frontend

Port the minimal pager mode as a first-class frontend sharing shell, reducer, terminal, streaming, permissions, and persistence behavior.

- **Rust crates:** `xai-grok-pager-minimal`
- **Swift targets:** `OpenGrokPagerMinimal`
- **Owned paths:** `Sources/OpenGrokPagerMinimal/`, `Tests/OpenGrokPagerMinimalTests/`
- **Depends on:** `W2-S5`, `W7-S1`, `W7-S2`, `W7-S5`, `W8-S3`, `W8-S4`, `W8-S5`
- **Reference/invariants:** Reference: xai-grok-pager-minimal and minimal-mode paths in pager/pager-bin.
- **Acceptance:**
  - Minimal mode supports prompts, streaming, tool/permission interaction, cancellation, session persistence, errors, and terminal restoration without importing full-screen views.
  - Switching minimal/fullscreen follows documented restart/runtime behavior and never creates a second session actor.
  - Plain/non-interactive terminals receive stable line-oriented output with no cursor-control leakage.
  - PTY snapshots cover narrow terminals, resize, Unicode, cancellation, permission prompts, and clean exit.

### Wave 10 — Product pager and CLI surfaces

Implement the final pager facade and the complete command-line contract as two independently testable targets using injected frontend/runtime factories.

#### W10-S1 — Open Grok pager facade

Compose all full and minimal TUI feature targets behind the final OpenGrokPager frontend without owning CLI parsing or distribution.

- **Rust crates:** `xai-grok-pager`
- **Swift targets:** `OpenGrokPager`
- **Owned paths:** `Sources/OpenGrokPager/`, `Tests/OpenGrokPagerTests/`
- **Depends on:** `W8-S5`, `W9-S1`, `W9-S2`, `W9-S3`, `W9-S4`, `W9-S5`
- **Reference/invariants:** Reference: xai-grok-pager crate boundary and pager-bin composition. The executable product is assembled in Wave 11 after the parallel CLI target is available.
- **Acceptance:**
  - OpenGrokPager composes exactly one pager runtime/model/shell session and exposes an injected Frontend protocol usable by the executable and PTY tests.
  - Interactive full-screen, inline, minimal, and plain-terminal selection preserves terminal restoration, session ownership, permissions, streaming, and persistence.
  - Feature composition does not bypass reducer/effect boundaries or create service locators, duplicate ACP channels, or duplicate session actors.
  - Facade integration snapshots cover startup, mode transitions, shutdown, reconnect, model switch, and extension registration.

#### W10-S2 — Complete CLI contract and runtime selection

Port the full command-line parser, validation, machine output, completions model, and command dispatcher against injected shell/frontend protocols.

- **Rust crates:** `xai-grok-pager-bin`
- **Swift targets:** `OpenGrokCLI`
- **Owned paths:** `Sources/OpenGrokCLI/`, `Tests/OpenGrokCLITests/`
- **Depends on:** `W3-S1`, `W3-S2`, `W5-S4`, `W5-S5`, `W5-S6`, `W8-S4`, `W8-S5`, `W9-S5`
- **Reference/invariants:** Reference: xai-grok-pager-bin/src and xai-grok-pager/src/app/cli.rs plus user-guide command documentation. This target compiles with fake FrontendFactory implementations and does not import OpenGrokPager.
- **Acceptance:**
  - CLI parsing supports interactive and headless prompt/output/json-schema plus agent stdio/headless/serve/leader and leader/no-leader selection using injected frontend factories in tests.
  - Commands match Rust: inspect, login/logout, mcp, plugin, memory, models, sessions, setup, share, wrap, export, trace, update, version, completions, worktree, workspace, dashboard, and agent subcommands.
  - Pager flags match cwd/debug/yolo/trust/allow/deny/model/effort/rules/system/session/fork/worktree/restore/plan/subagents/memory/tool/max-turn/permission/web/verify/background/best-of/sandbox/storage/hunk/terminal/fs/update/todo/screen/login/leader/prompt behavior and incompatibility validation.
  - Headless text/json/jsonl/output-schema and exit codes are deterministic; stdout contains only requested machine output while diagnostics/progress use stderr.

### Wave 11 — Distribution, differential verification, and release gates

Assemble the executable and prove behavioral parity, resilience, platform seams, security boundaries, performance, and licensing before declaring the source port complete.

#### W11-S1 — Executable assembly, distribution, installer, and completions

Assemble the open-grok executable from the independent pager and CLI targets and port release manifest/checksum/install/update handoff and platform artifact support.

- **Rust crates:** `xai-grok-pager-bin`, `xai-grok-update`, `xai-grok-version`
- **Swift targets:** `OpenGrokExecutable`, `OpenGrokDistributionSupport`
- **Owned paths:** `Sources/OpenGrokExecutable/`, `Tests/OpenGrokExecutableTests/`, `Sources/OpenGrokDistributionSupport/`, `Tests/OpenGrokDistributionSupportTests/`, `Scripts/`, `Distribution/`
- **Depends on:** `W0-S1`, `W0-S3`, `W2-S2`, `W5-S6`, `W10-S1`, `W10-S2`
- **Reference/invariants:** Reference: pager-bin, xai-grok-update, xai-grok-version, bin/ and scripts/ release/install helpers. Package.swift edits remain W0-S1-owned.
- **Acceptance:**
  - The executable product is exactly open-grok and wires OpenGrokCLI to OpenGrokPager/OpenGrokPagerMinimal and OpenGrokShell without duplicate actors or alternate behavior paths.
  - Release builds produce reproducible platform-named artifacts, SHA-256 files, install assets, LICENSE, NOTICE, and THIRD-PARTY-NOTICES.
  - Installer and updater write only $OPENGROK_HOME/bin/open-grok, preserve rollback, verify checksums before replacement, and never overwrite an unrelated upstream installation.
  - Bash, zsh, fish, and PowerShell completions are generated from the same CLI definition; macOS signing, Linux packaging, and Windows replacement limitations are explicit and smoke-tested.

#### W11-S2 — Protocol and Rust-fixture compatibility

Run cross-language golden fixtures for configuration, ACP, tools, providers, streams, session persistence, Code Mode, and CLI machine output.

- **Rust crates:** `xai-grok-test-support`, `xai-acp-lib`, `xai-tool-protocol`, `xai-grok-sampling-types`, `xai-grok-sampler`, `xai-grok-shell`
- **Swift targets:** `OpenGrokCompatibilityTests`
- **Owned paths:** `Tests/OpenGrokCompatibilityTests/`
- **Depends on:** `W10-S1`, `W10-S2`
- **Reference/invariants:** Reference tests are copied as attributed fixtures, not generated by invoking the read-only Rust tree during normal Swift test runs.
- **Acceptance:**
  - Swift decodes representative Rust fixtures and re-encodes semantically/byte-equivalently wherever the Rust contract is byte-significant.
  - ACP methods/meta, tool schemas/results, Chat/Responses/Messages streams, provider-native history, Code Mode cells, and persisted sessions pass differential tests.
  - CLI JSON/JSONL/schema outputs, exit codes, and redaction match captured Rust behavior.
  - Compatibility corpus records reference revision and intentional divergences; unexplained drift blocks release.

#### W11-S3 — PTY and end-to-end scenarios

Port the PTY harness and execute full TUI/minimal/headless/ACP scenarios against mock inference, auth, MCP, tools, and filesystem services.

- **Rust crates:** `xai-grok-pager-pty-harness`, `xai-grok-pager`, `ptyctl`
- **Swift targets:** `OpenGrokPagerPTYHarness`, `OpenGrokPagerPTYTests`
- **Owned paths:** `Sources/OpenGrokPagerPTYHarness/`, `Tests/OpenGrokPagerPTYHarnessTests/`, `Tests/OpenGrokPagerPTYTests/`
- **Depends on:** `W10-S1`, `W10-S2`
- **Reference/invariants:** Reference: xai-grok-pager-pty-harness and xai-grok-pager/tests/pty_e2e.
- **Acceptance:**
  - Scenario harness controls PTY size/input, virtual screen capture, mock HTTP/SSE, fake OAuth, MCP servers, workspace files, timeouts, and isolated OPENGROK_HOME.
  - Smoke and regression scenarios cover startup/login, streaming, tool/permission prompts, plan, Code Mode, subagents, sessions, rewind/compaction, MCP, background work, resize, suspend, and exit.
  - macOS and Linux CI run the full supported matrix; Windows runs ConPTY-capable scenarios and marks only genuinely unavailable features as explicit skips.
  - No scenario depends on developer credentials, network access, installed open-grok, or real ~/.opengrok state.

#### W11-S4 — Fuzzing, stress, and performance

Port markdown fuzzing and add stress/performance gates for stream parsing, terminal rendering, tools, persistence, memory, worktrees, and long sessions.

- **Rust crates:** `xai-grok-markdown-fuzz`, `xai-grok-markdown`, `xai-grok-sampler`, `xai-grok-tools`, `xai-grok-shell`
- **Swift targets:** `OpenGrokFuzzingTests`, `OpenGrokPerformanceTests`
- **Owned paths:** `Tests/OpenGrokFuzzingTests/`, `Tests/OpenGrokPerformanceTests/`
- **Depends on:** `W10-S1`, `W10-S2`
- **Reference/invariants:** Reference: xai-grok-markdown/fuzz plus sampler/tools/shell stress-worthy test surfaces.
- **Acceptance:**
  - Markdown full/streaming render fuzzing covers all render modes and asserts no crash, unbounded growth, invalid terminal state, or semantic divergence.
  - Fuzz targets cover SSE/event parsing, JSON/tool schemas, permission DSL, config, patches/search_replace, persisted sessions, and Code Mode protocol messages.
  - Stress tests cover cancellation races, thousands of stream events/tool calls, concurrent background tasks, large transcripts, worktree churn, and interrupted persistence.
  - Performance baselines cap startup, first render, steady-state render, stream throughput, memory search, session load, and idle CPU regressions on reference CI hardware.

#### W11-S5 — Cross-platform, security, privacy, and license release audit

Run the final matrix for macOS/Linux/Windows adapters, sandbox/permission/provider isolation, secret redaction, telemetry/privacy, updater safety, and notices.

- **Rust crates:** `xai-grok-sandbox`, `xai-grok-auth`, `xai-grok-telemetry`, `xai-grok-update`, `xai-grok-mermaid`, `xai-ratatui-inline`, `xai-grok-code-mode`
- **Swift targets:** `OpenGrokReleaseValidation`, `OpenGrokSecurityTests`
- **Owned paths:** `Sources/OpenGrokReleaseValidation/`, `Tests/OpenGrokReleaseValidationTests/`, `Tests/OpenGrokSecurityTests/`
- **Depends on:** `W10-S1`, `W10-S2`
- **Reference/invariants:** Reference: security-critical crates and every NOTICE/LICENSE source inventoried from the Rust repository.
- **Acceptance:**
  - macOS and Linux builds/tests are clean; Windows builds all platform-neutral targets and either passes adapters or returns documented unsupported capabilities without accidental fallback.
  - Adversarial tests cover path/symlink traversal, command injection, permission TOCTOU, sandbox weakening, credential/header/history cross-provider leaks, corrupt persistence, and malicious MCP/hooks/plugins.
  - Logs, traces, crash reports, telemetry, feedback, update, relay, memory, and notices UI are audited for secrets/private content and monotonic provider export policy.
  - A machine-generated license inventory matches Package.resolved/vendored code/assets, includes all required source revisions/notices, and is embedded in release artifacts and the in-product notices view.

## Global completion gate

- All 84 Rust crates are mapped in CRATE_MAP.md: 83 root Cargo workspace members plus the separately rooted xai-grok-markdown-fuzz crate; no manifest or end-user surface is unassigned. The two crates added at the 2026-08-04 re-pin (xai-workflow, xai-grok-extra-ca) are mapped to proposed targets and are not yet started.
- The package builds with Swift 6.1 language/tooling constraints, emits one executable product named open-grok, preserves Open Grok branding, and never reads or writes ~/.grok.
- Interactive full-screen, inline/minimal, headless text/JSON/JSONL/schema, ACP stdio/headless/leader/serve/relay, and every documented CLI command/flag pass automated acceptance tests.
- Session actor tests prove ordered turns/tool calls/steering, exactly-once continuation completion, cooperative cancellation, local ownership, permission gating, background work, rewind, compaction, and clean shutdown.
- Provider tests prove model-metadata identity, independent backend/profile/auth axes, explicit-key precedence, xAI/Codex store isolation, Kimi/Fireworks policy, hosted-tool/history isolation, live switching, and monotonic non-xAI export closure.
- Tool tests cover registry modes/packs, file/search/edit attribution, process/background/monitor/scheduler/terminal/LSP/web/media/computer tools, MCP, hooks/plugins/skills, human controls, output caps, resource locks, and Code Mode nested dispatch.
- Permission/sandbox tests prove exact gate ordering, fail-open hooks, deny > ask > allow, bash-segment rules, folder trust, session/project grants, YOLO boundaries, process-wide sandbox pinning, and no silent platform weakening.
- Persistence compatibility tests load representative Rust sessions/config/auth/model caches/memory/goals/worktrees, preserve opaque and unknown data, and verify atomic migration, resume, fork, rewind, restore-code, recap, and recovery.
- Markdown/Mermaid/terminal/TUI golden and fuzz tests cover streaming equivalence, Unicode, resize, inline restoration, themes, tool cards, Code Mode transport hiding, images, diagrams, and large histories without crashes or unbounded growth.
- macOS and Linux pass the full build/test/E2E matrix; Windows compiles all neutral targets and passes supported adapters, with explicit tested unsupported results only for genuine OS capability gaps.
- Telemetry, traces, crash reports, feedback, update, relay, memory, and provider exports are redaction/privacy audited and blocked by configuration and monotonic provider boundaries before serialization.
- Release artifacts include verified checksums, isolated installer/update behavior, shell completions, LICENSE/NOTICE/THIRD-PARTY-NOTICES, source revisions for derived code, and an in-product notices view.

## Integration sequence

1. Target owner lands source and target-scoped tests only.
2. Bootstrap/integration owner adds the target and approved edges to `Package.swift`, then runs `swift package describe` and target tests.
3. When all slices in a wave pass, run the wave integration matrix and update `PORT_STATUS.md`.
4. A later wave cannot be marked complete while any required prior slice is incomplete or its compatibility fixtures are absent.
5. Port completion requires every Wave 11 gate, distribution notice audit, and isolated-home smoke test to pass.
