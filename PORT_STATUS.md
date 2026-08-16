# Swift Open Grok Port Status

**As of:** 2026-08-16 (Wave G — non-TUI parity closure). **The current Wave G tree is locally green but has not been pushed, so there is no current remote platform-green claim.** The latest pushed CI run is Wave F commit `ae45c76` from 2026-08-16 and failed its macOS, Linux, and Windows compile jobs. Local Wave G serial gate: `build-tests` exit 0; authoritative full `test --no-parallel` exit 0 — exactly **7,573 Swift Testing cases in 1,137 suites across 106 nonempty summaries passed** (0 failures, 0 recorded issues).

**Overall state:** The package builds and tests green on macOS locally, and `open-grok` launches a working full-screen TUI agent with multiple live utility routes. All core subsystems (All 9 Model Providers [xAI, Codex, Kimi Platform & Code, Fireworks AI, DeepSeek, Meta Muse Spark, OpenCode Go, Wafer AI, Z AI], Multi-Provider Scoped Storage & CLI Auth Management, Provider Wire Policies & Dialects, Dynamic Catalog Broker Resolution, MCP Meta-Discovery `search_tool`/`use_tool` & FNV-1a Fingerprints, Background Monitor Tool with Token-Bucket Rate Limiter & Suppression Tracker, Cursor Rules on Read Attachment & Scope Scanner, Memory MMR Maximal Marginal Relevance & Query Expansion, Bounded Stdio MCP Auto-Restart & Backoff, Durable Session Relocation Journal & Transactional Authority, Image Normalization & Resizing with SHA-256 Digest Cache, Pre-Warmed Subagent Git Worktree Pool, Native Workflow Engine & Rhai AST/Interpreter/Journal/Escalation, Interactive Terminal Composer Rich Elements & Image Framing, Markdown Table Wrapped-Fragment & 11-Glyph Box Drawing Layout Parity, Tool Catalog Schemas & Protocol Output Caps, Agent Runtime & Turn Pipeline, ACP Transports, Custom Models Settings UI & Store Persistence, Steady-State Cache Tracking & Cold-Start Diagnostics, Fuzzy Path Matcher & Scoring, Background Directory Matcher Daemon, File Search @-Completion Dropdown Engine, Wrap Clipboard Image Framing, Prompt Cache Tracking & Break Diagnostics, Custom Model Store & Persistence, Web Search Filter Precedence, Turn-End Drain Queue Hooks, Compaction Checkpoints & Two-Pass Prefire, Workspace Primitives, StructuredOutput Synthetic Tool Loop, and Monotonic Export Boundary) are 100% LIVE, audited CLEAN, and verified.
**Destination was empty at baseline:** yes.
**Reference:** `xai-org/grok-build` at `650c1db7c2e73c59cec88bf3c6359751d6cef1bd` (release `v0.1.220-open-grok.58`) / Forward Sync `eb215dd0` (`v1.0.0-open-grok.63`).
**Swift toolchain used:** Apple Swift 6.4 (`swift-tools-version: 6.1`, `swiftLanguageModes: [.v6]`); `swift --version` reported target `arm64-apple-macosx27.0.0`.

## Wave G — Non-TUI parity closure (2026-08-16, complete locally)

Current truth for the Wave G backlog against reference pin `650c1db7`:

1. **Running subagent attachment** — live attachments read retained in-memory conversation items while a child is still running; Antigravity publishes its starting transcript and phase before coordinator exposure.
2. **Session feature gates** — the remaining `GROK_*` family covers two-pass compaction, ask-user-question, write-file, backend search, cancel rewind, MCP liveness watchers, compaction mode/detail, and telemetry trace upload.
3. **Single launch authority** — `EffectiveFeatures.resolve` produces the session feature document consumed by launch composition instead of independent live-surface re-resolution.
4. **Automatic worktree GC** — launch-time GC is policy-gated, throttled, protects active/primary paths, and reports disabled, throttled, dry-run, or collected outcomes.
5. **Code Mode hard interrupt** — the packaged JavaScript worker subprocess provides immediate process termination while preserving the actor command/control terminal signals.
6. **Antigravity follow-ons** — reasoning effort planning, conversation continuation, log-phase heartbeats, available-model state, and quota caching are live.
7. **Packed Git status** — the live pure-status path reads pack-index-v2 objects and resolves bounded OFS/REF deltas with system zlib support.
8. **Portable secure WebSockets** — `wss://` uses the portable connection path and the Foundation trust bridge prepares additional trust roots on supported hosts.
9. **Windows leader IPC** — the leader listener/dialer uses path-derived Windows named pipes while Unix platforms retain domain sockets.
10. **Chat/local workspace CLI** — `--chat`, local workspace create/attach, and cwd flags parse, validate their relationships, and reach executable composition.
11. **Platform gate implementation** — CI defines blocking macOS/Linux build-and-test jobs, Windows compile coverage, diagnostic Windows tests, and a privileged Linux bwrap namespace probe. Post-push platform conclusions remain evidence to collect, not missing product wiring.

Verification (local macOS, 2026-08-16):

| Command | Result |
|---|---|
| `zsh workflows/swift-safe-verify.zsh build-tests` | exit 0 |
| `SWIFT_SAFE_TIMEOUT_SECONDS=2400 zsh workflows/swift-safe-verify.zsh test --no-parallel` | exit 0; **7,573 tests / 1,137 suites / 106 nonempty summaries**, 0 failures |
| `SWIFT_SAFE_TIMEOUT_SECONDS=900 zsh workflows/swift-safe-verify.zsh test-target OpenGrokCLITests --no-parallel` | exit 0; **1,570 tests / 237 suites**, 0 failures |
| `SWIFT_SAFE_TIMEOUT_SECONDS=300 zsh workflows/swift-safe-verify.zsh test --filter 'runningChildAttachment' --no-parallel` | exit 0; **1 test / 1 suite** |
| `SWIFT_SAFE_TIMEOUT_SECONDS=300 zsh workflows/swift-safe-verify.zsh test --filter 'resizeAndAutoscrollUseFrozenSidecar' --no-parallel` | exit 0; **1 test / 1 suite** |

The full gate also retires two suite-order flakes found during closure: Antigravity
registration now exposes its initial attachment state atomically, and the long-cadence
table-selection regression advances the injected monotonic paint clock rather than
waiting on a five-second wall-clock boundary.

## Wave 27 — Multi-Provider Subsystem Porting: Scopes & Storage, CLI Auth Commands, Wire Policies & Dialects, Catalog Resolution (2026-08-14, complete)

Current truth for the verified 2026-08-14 Wave 27 Multi-Provider Porting across Multi-Provider Scoped Storage & Logout (`OpenGrokAuth`), CLI Multi-Provider Login/Logout/Status (`OpenGrokCLI`), Provider Wire Policies & Dialect Formatting (`OpenGrokSampler`, `OpenGrokSamplingTypes`), and Multi-Provider Catalog Resolution (`OpenGrokModels`):

**Verification (lead, local macOS, 2026-08-14; serial gate):**
- `zsh workflows/swift-safe-verify.zsh build` — exit 0.
- `zsh workflows/swift-safe-verify.zsh build-tests` — exit 0.
- `zsh workflows/swift-safe-verify.zsh build --product open-grok` — exit 0: clean binary build in **3.67s**.
- Authoritative full `zsh workflows/swift-safe-verify.zsh test --no-parallel` — exit 0: exactly **7,156** Swift Testing cases in **1,095** suites, elapsed **329.722s** (100% green, 0 failures, 0 regressions).
- CLI Smokes: `open-grok --version` reports `Open Grok 1.0.0-open-grok.63` (exit 0); `paths --json` and `models --json` exit 0.

### Slices Completed & Landed

1. **Slice 1: Multi-Provider Scopes, Storage & Logout (`OpenGrokAuth`, `ae90872`)**
   - Expanded `AuthAccountTarget` to all 9 supported providers plus `.all`: `xai`, `codex`, `kimi`, `fireworks`, `deepseek`, `meta`, `openCodeGo`, `wafer`, `zai`, `all`.
   - Added typed storage and cleanup helpers for all provider scopes in `ProviderScopes.swift`.
   - Implemented target-aware `logout(target:...)` clearing provider-specific scopes from `auth.json` with multi-target rollback safety and populated `MultiLogoutResult` (`MultiProviderAuthTests.swift`).

2. **Slice 2: CLI Multi-Provider Login, Logout & Status (`OpenGrokCLI`, `e7f7375`)**
   - Implemented `open-grok login <provider> [api-key]` and `open-grok logout <provider>` across all 9 providers with alias resolution.
   - Interactive secret line prompt fallback for terminal sessions.
   - Extended `LiveAuthStatus` to report structured JSON and human-readable status lines across all 9 providers (`MultiProviderAuthCLITests.swift`).

3. **Slice 3: Provider Wire Policies, Request Gating & Dialect Serialization (`OpenGrokSampler`, `OpenGrokSamplingTypes`, `1ad26af`)**
   - Verified `ProviderProfile` constants across all 9 providers.
   - Added header sanitization (stripping `x-grok-*` headers for standard providers, retaining for xAI), Codex session affinity headers, and dialect patching for DeepSeek, Meta, and Codex (`ProviderWireTests.swift`).

4. **Slice 4: Multi-Provider Catalog Resolution and Model Metadata (`OpenGrokModels`, `d814e15`)**
   - Verified provider identification and classification across all 9 providers with `ModelPartitionKind` and `ModelCatalogPartition`.
   - Handled all provider environment variables and alias fallbacks (`XAI_API_KEY`, `CODEX_API_KEY`, `KIMI_API_KEY`, `FIREWORKS_API_KEY`, `DEEPSEEK_API_KEY`, `META_API_KEY`, `OPENCODE_GO_API_KEY`, `WAFER_API_KEY`, `ZAI_API_KEY`).
   - Integrated custom model merging into catalog resolution pipeline (`MultiProviderCatalogTests.swift`).

### Landed Commits

- `ae90872` — Support multi-provider scopes and logout orchestration in OpenGrokAuth
- `d814e15` — feat(models): implement multi-provider catalog resolution and metadata
- `e7f7375` — Implement CLI multi-provider login, logout, and status in OpenGrokCLI
- `1ad26af` — feat(sampler): verify provider wire policies, request sanitization, and responses dialect patching

## Wave 26 — Multi-Agent Subsystem Porting: MCP Meta-Discovery, Monitor Tool & Rate Limiting, Cursor Rules on Read, Memory MMR & Query Expansion (2026-08-14, complete)

Current truth for the verified 2026-08-14 Wave 26 Multi-Agent Porting across MCP Meta-Discovery (`search_tool` & `use_tool`) (`OpenGrokAgentControlTools`), Background Monitor Tool with Token-Bucket Rate Limiter (`OpenGrokExecutionTools`), Cursor Rules on Read Attachment (`OpenGrokFileTools`), and Memory MMR & Query Expansion (`OpenGrokMemory`):

**Verification (lead, local macOS, 2026-08-14; serial gate):**
- `zsh workflows/swift-safe-verify.zsh build` — exit 0.
- `zsh workflows/swift-safe-verify.zsh build-tests` — exit 0.
- `zsh workflows/swift-safe-verify.zsh build --product open-grok` — exit 0: clean binary build in **2.55s**.
- Authoritative full `zsh workflows/swift-safe-verify.zsh test --no-parallel` — exit 0: exactly **7,090** Swift Testing cases in **1,080** suites, elapsed **318.630s** (100% green, 0 failures, 0 regressions).
- CLI Smokes: `open-grok --version` reports `Open Grok 1.0.0-open-grok.63` (exit 0); `paths --json` and `models --json` exit 0.

### Slices Completed & Landed

1. **Slice 1: MCP Meta-Discovery (`search_tool` & `use_tool`) (`OpenGrokAgentControlTools`, `e97d5e8`)**
   - Ported from Rust reference `crates/codegen/xai-grok-tools/src/implementations/search_tool/` and `use_tool/`.
   - Deterministic 64-bit FNV-1a hashing (`fnv1aHash`) with offset basis `0xcbf29ce484222325` and prime `0x00000100000001B3`.
   - `ServerFingerprint` (`toolCount`, `descriptionHash`, `toolNamesHash`) and `fingerprintServers(_:)`.
   - `buildServerReminder(_:)` and `buildDeltaReminder(old:newSummaries:)` for connected/updated/disconnected MCP servers.
   - `SearchTool`: BM25 keyword search engine with compound identifier tokenization ($k_1 = 1.2, b = 0.75$), server-level result grouping, exact-match fast paths, and description truncation (`MAX_MCP_DESCRIPTION_LENGTH = 2048`).
   - `UseTool`: Integration tool invoker with fully-qualified naming validation (`server__tool`) and argument normalization (`SearchToolTests.swift`).

2. **Slice 2: Background Monitor Tool & Token-Bucket Rate Limiter (`OpenGrokExecutionTools`, `dc3bc91`)**
   - Ported from Rust reference `crates/codegen/xai-grok-tools/src/implementations/grok_build/monitor/`.
   - `MonitorInput` & `MonitorOutput` with 10-hour default/max deadline (`36_000_000ms`) and persistent bypass.
   - `TokenBucket`: 10-token capacity, 1 token / 2,000ms refill schedule.
   - `SuppressionTracker`: suppression counting, catch-up notice generation (`[N events suppressed...]`), and 30-second continuous overload auto-kill (`AUTO_KILL_THRESHOLD_MS = 30_000ms`).
   - `LineProcessor`: ANSI escape sequence stripping, 500-char line truncation, 3,000-char batching, 200ms debounce, and 1 MB buffer cap (`MonitorToolTests.swift`).

3. **Slice 3: Cursor Rules on Read Attachment (`OpenGrokFileTools`, `1c44050`, `7e856ba`)**
   - Ported from Rust reference `crates/codegen/xai-grok-tools/src/implementations/cursor_rules_on_read.rs` (768 LOC).
   - `.cursorrules` and `.cursor/rules/*.mdc` frontmatter parser supporting CRLF/LF line endings, `alwaysApply`, `globs`, and `description`.
   - `CursorRulesOnReadTracker`: upward directory scope walk, scanned directory caching, relative glob pattern matching, and per-session rule injection deduplication.
   - `appendCursorRulesForRead`: XML block attachment (`<cursor_rule path="...">...</cursor_rule>`) to full and concise read outputs (`CursorRulesOnReadTests.swift`).

4. **Slice 4: Memory MMR (Maximal Marginal Relevance) & Query Expansion (`OpenGrokMemory`, `79f45b4`)**
   - Ported from Rust reference `crates/codegen/xai-grok-memory/src/mmr.rs` and `query_expansion.rs`.
   - `cosineSimilarity`: Dot product divided by vector norms with bounds clamping.
   - `MMRRanker`: Maximal Marginal Relevance ranking over candidate vectors with lambda balance parameter (`lambda: 0.0 ... 1.0`, default `0.7`) and pairwise redundancy penalties.
   - `QueryExpander`: Code search token analyzer splitting camelCase, snake_case, file extensions, and punctuation (`MMRQueryExpansionTests.swift`).

### Landed Commits

- `7e856ba` — fix(cursor-rules): handle CRLF Character count accurately in splitFrontmatter
- `dc3bc91` — feat(tools): implement background monitor tool and token-bucket rate limiter
- `e97d5e8` — feat(OpenGrokAgentControlTools): implement MCP Meta-Discovery tools (search_tool & use_tool)
- `1c44050` — Implement Cursor rules on read attachment in OpenGrokFileTools
- `79f45b4` — feat(memory): implement MMR diversity reranker and query expander

## Wave 25 — Multi-Agent Subsystem Porting: Stdio MCP Auto-Restart, Session Relocation Journal, Image Normalization & Cache, Pre-Warmed Worktree Pool (2026-08-14, complete)

Current truth for the verified 2026-08-14 Wave 25 Multi-Agent Porting across Bounded Stdio MCP Auto-Restart & Backoff (`OpenGrokMCP`), Durable Session Relocation Journal (`OpenGrokSessionPersistence`), Image Normalization & Resizing with SHA-256 Digest Cache (`OpenGrokWebMediaTools`), and Pre-Warmed Git Worktree Pool (`OpenGrokFastWorktree`):

**Verification (lead, local macOS, 2026-08-14; serial gate):**
- `zsh workflows/swift-safe-verify.zsh build` — exit 0.
- `zsh workflows/swift-safe-verify.zsh build-tests` — exit 0.
- `zsh workflows/swift-safe-verify.zsh build --product open-grok` — exit 0: clean binary build in **2.90s**.
- Authoritative full `zsh workflows/swift-safe-verify.zsh test --no-parallel` — exit 0: exactly **7,024** Swift Testing cases in **1,075** suites, elapsed **316.912s** (100% green, 0 failures, 0 regressions).
- CLI Smokes: `open-grok --version` reports `Open Grok 1.0.0-open-grok.63` (exit 0); `paths --json` and `models --json` exit 0.

### Slices Completed & Landed

1. **Slice 1: Bounded Stdio MCP Auto-Restart & Exponential Backoff (`OpenGrokMCP`, `2953475`)**
   - Ported from Rust reference `crates/codegen/xai-grok-shell/src/session/mcp_restart.rs` (1,519 LOC).
   - Implemented `McpRestartState` (Sendable, Codable, Equatable) and `McpRestart` state machine.
   - Bounded stdio MCP auto-restart loop with exponential backoff schedule (`BACKOFF = [1.0, 4.0, 16.0]`): 3 attempts at `+1s`, `+4s`, `+16s` with a 21-second total exhaustion window.
   - Guard rails: non-restart filter (`transportClosed` / `handshakeFailed` only), stdio transport check (skips HTTP/OAuth), ignores intentional shutdown / `killOnDrop`, and checks disabled/unconfigured server state.
   - Status updates & tool cleanup: pushes `.restarting` / `.unavailable` status reason payloads and unregisters server tools upon exhaustion (`McpRestartTests.swift`).

2. **Slice 2: Durable Session Relocation Journal & Transactional Authority (`OpenGrokSessionPersistence`, `4875cc2`)**
   - Ported from Rust reference `crates/codegen/xai-grok-shell/src/session/storage/relocation/`.
   - 7-stage relocation authority lifecycle (`initiated → sourceVerified → targetPublished → ready → sourcePruned → committed / rolledBack`).
   - Authority boundary rule: Source path is authoritative through `targetPublished`; Target path becomes authoritative once `ready`. Rollbacks strictly refused after `ready`.
   - Atomic rollback, torn write recovery, transaction leasing, and directory collision detection (`RelocationJournalTests.swift`).

3. **Slice 3: Image Normalization, Resizing & Digest Hash Cache (`OpenGrokWebMediaTools`, `5956759`)**
   - Ported from Rust reference `crates/codegen/xai-grok-shell/src/session/image_normalize.rs` and `normalize_cache.rs`.
   - `ImageNormalizer`: Header-based dimension sniffer (PNG, JPEG, GIF, WebP, BMP), aspect-ratio-preserving downsampling bounding box calculator (`maxSide = 2000`, `maxPixels = 2_408_448`), and quality step-down recompression.
   - `ImageNormalizeCache`: Thread-safe, disk-backed cache stored under `$OPENGROK_HOME/cache/image_normalize/` keyed by SHA-256 content hash (`<sha256>.png` and metadata) to avoid re-encoding on consecutive turns.
   - Text-only model fallback markdown placeholder block generator (`[Image: <dimensions>, <format>]`) (`ImageNormalizeTests.swift`).

4. **Slice 4: Pre-Warmed Subagent Git Worktree Pool (`OpenGrokFastWorktree`, `e9c81cf`, `fa3bb8a`)**
   - Ported from Rust reference `crates/codegen/xai-grok-shell/src/session/worktree_pool.rs` (~2,400 LOC).
   - `WorktreePool`: Actor managing a bounded pool of pre-warmed clean Git worktrees under `$OPENGROK_HOME/worktrees/pool/` for near-zero latency subagent spawning.
   - Methods: `warmPool(targetCount:)`, `acquireLease(for:)`, `releaseLease(_:)`, `prune(maxAge:)`.
   - Automatic background replenishment to maintain warm capacity, dirty state wiping (`git reset --hard HEAD` + `git clean -fdx`), branch recycling, and stale lock reclamation (`WorktreePoolTests.swift`).

### Landed Commits

- `aab2d25` — fix(scheduler): advance simulated test clock cleanly for detached mode tests
- `3f3d1fe` — fix(scheduler): prevent timer race on zero-delay scheduled tasks
- `fa3bb8a` — fix(worktree,shell,interjection): polish test harness synchronization and prune bounds
- `e9c81cf` — feat(worktree): implement pre-warmed subagent git worktree pool
- `5956759` — feat(media): implement image normalization, resizing, and digest hash cache
- `4875cc2` — Implement durable session relocation journal and transactional authority
- `2953475` — Implement bounded stdio MCP auto-restart and exponential backoff

## Wave 24 — Native Workflow Engine, Rich Composer Elements & Image Framing, Markdown Table Parity & Tool Extras Audit (2026-08-14, complete)

Current truth for the verified 2026-08-14 Wave 24 Multi-Agent Porting across Native Workflow Engine (`xai-workflow` → `OpenGrokWorkflow`), Interactive Terminal Composer Rich Elements & Image Framing, Markdown Table Wrapped-Fragment & Layout Parity (`OpenGrokMarkdown`), and Tool Extras & Parity Audit Closure (`OpenGrokToolRegistry`, `OpenGrokToolProtocol`):

**Verification (lead, local macOS, 2026-08-14; serial gate):**
- `zsh workflows/swift-safe-verify.zsh build` — exit 0.
- `zsh workflows/swift-safe-verify.zsh build-tests` — exit 0.
- `zsh workflows/swift-safe-verify.zsh build --product open-grok` — exit 0: clean binary build in **2.50s**.
- Authoritative full `zsh workflows/swift-safe-verify.zsh test --no-parallel` — exit 0: exactly **6,987** Swift Testing cases in **1,071** suites, elapsed **335.609s** (100% green, 0 failures, 0 regressions).
- CLI Smokes: `open-grok --version` reports `Open Grok 1.0.0-open-grok.63` (exit 0); `paths --json` and `models --json` exit 0.

### Slices Completed & Landed

1. **Task 1: Native Workflow Engine Port (`OpenGrokWorkflow`)**
   - Implemented native Rhai AST, Lexer, Parser, and Interpreter (`RhaiAST.swift`, `RhaiLexer.swift`, `RhaiParser.swift`, `RhaiInterpreter.swift`, `RhaiEngine.swift`, `RhaiHost.swift`).
   - Configured deterministic 100,000,000 operation execution limit (`RhaiLimits.swift`) preventing infinite loops and runaway scripts.
   - Built host environment bindings (`RhaiHost.swift`), run metadata (`RhaiMeta.swift`, `RhaiRun.swift`), and built-in function library (`RhaiBuiltins.swift`).
   - Implemented durable execution journal (`RhaiJournal.swift`) with 16-byte SHA-256 request hashing (`RhaiSHA256.swift`), torn line recovery for interrupted/corrupted writes, escalation fulfillment, and error pruning / manifest verification.
   - Landed empirical adversarial stress suites (`RhaiEngineAdversarialStressTests.swift`) validating operation budget exhaustion, non-determinism guards, and journal recovery (`4b77439`).

2. **Task 2: Interactive Terminal Composer Rich Elements & Image Framing (`OpenGrokTerminalCore`, `OpenGrokPagerRender`, `OpenGrokCLI`)**
   - Implemented `WrapClipboardImage` OSC 999 protocol (`ESC ] 999;GrokWrapClipboardImage? BEL`, `MAGIC_IMG` / `GROK_WRAP_IMG`, `MAGIC_NONE` / `GROK_WRAP_NONE`, 20 MiB ceiling) across terminal core and pager render layers.
   - Added `PastedImage` chips in composer buffer and image element metadata representation.
   - Implemented `PromptSuggestionController` ghost text engine with predictive autocomplete, inline rendering, Tab acceptance, and prompt boundary detection.
   - Added Ghostty protocol extras, Ghostty Cmd+A selection gating, Kitty 4096-byte chunked graphics protocol with z-index ordering, and Alacritty KKP DA2 <= 2401 progressive enhancement workaround.
   - Added empirical adversarial stress suites (`PromptSuggestionAdversarialTests.swift`, `WrapClipboardImageAdversarialTests.swift`) (`4b77439`).

3. **Task 3: Markdown Table Wrapped-Fragment & Layout Parity (`OpenGrokMarkdown`)**
   - Implemented full terminal markdown table layout engine (`MarkdownTableLayout.swift`, `MarkdownRenderEngine.swift`) matching upstream `xai-grok-markdown`.
   - 11-glyph box drawing grid (`TableBorders.box`: `┌ ┬ ┐ ├ ┼ ┤ └ ┴ ┘ │ ─`) with top border, intermediate body dividers `├─┼─┤`, and bottom border.
   - Two-tier column width budget allocation distributing excess terminal width, respecting unbreakable word minimums and grapheme hard floors (`maxTableWidth` constraints).
   - Grapheme cluster emergency splitting and soft word wrapping with `cellWordSeparator`.
   - Multi-line visual row layout with monotonic source cursor alignment and styled span slicing.
   - Streaming table checkpoints (`CheckpointKind.table` freeze boundary).
   - Unit & adversarial stress tests (`MarkdownTableParityTests.swift`, `MarkdownTableAdversarialStressTests.swift`) (`9986b8d`, `4b77439`).

4. **Task 4: Tool Extras & Parity Audit Closure (`OpenGrokToolRegistry`, `OpenGrokToolProtocol`)**
   - Audited and verified all 32 built-in tool catalog schemas (`BuiltinToolCatalog` in `Catalog.swift`) across `OpenGrokFileTools`, `OpenGrokExecutionTools`, `OpenGrokWebMediaTools`, and `OpenGrokAgentControlTools` against upstream `xai-grok-tools`.
   - Implemented strict parameter validation, type annotations, and required property definitions.
   - Enforced output byte and character caps (`40_000` byte / `20_000` char caps, `32_768` byte mailbox payload ceiling, `1_000` line read limit, `2_048` char MCP tool description limit with `\u{2026} [truncated]`).
   - Integrated with 7-stage permission pipeline (`deny > ask > allow`, plan-mode gate, hook dispatch, session worktrees, and explicit hunk tracking).
   - Created comprehensive tool protocol verification suites (`ToolProtocolSchemaTests.swift`, `ToolProtocolPipelineWireTests.swift`, `ToolProtocolOutputCapTests.swift`) (`f84067f`).

### Landed Commits

- `4b77439` — Add adversarial empirical stress suites for Wave 1 milestones
- `f84067f` — Audit tool catalog schemas and add comprehensive protocol test suites
- `9986b8d` — Port markdown table wrapped-fragment & layout parity
- `4704aeb` — docs(ledger): record @-file completion live wiring in Wave 23
- `66cdfb6` — feat(pager): wire @-file search completion in interactive controller
- `70ce924` — docs(ledger): record Wave 23 completion with 6,886 tests in 1,060 suites passed
- `7cf66eb` — test(settings): update catalog expectations for 11 custom models entries
- `7b6813f` — feat(settings): wire custom models persistence and cold-start cache rendering
- `45774ed` — Track steady-state cache hit rate and cold start labeling
- `1b8c5f5` — feat(pager): custom models settings catalog definitions and validation
- `ca54f1d` — docs(ledger): record Wave 22 completion with 6,870 tests in 1,058 suites passed

## Wave 23 — Custom Models Settings & Steady-State Cache Telemetry (2026-08-14, complete)

Current truth for the verified 2026-08-14 Wave 23 Multi-Agent Porting against Rust commits `d8b8db24` and `1ff5a4a9`:

**Verification (lead, local macOS, 2026-08-14; serial gate):**
- `zsh workflows/swift-safe-verify.zsh build` — exit 0.
- `zsh workflows/swift-safe-verify.zsh build-tests` — exit 0.
- `zsh workflows/swift-safe-verify.zsh build --product open-grok` — exit 0.
- Authoritative full `zsh workflows/swift-safe-verify.zsh test --no-parallel` — exit 0: exactly **6,886** Swift Testing cases in **1,060** suites, elapsed **286.67s** (100% green).
- CLI Smokes: `open-grok --version` reports `Open Grok 1.0.0-open-grok.63` (exit 0); `paths --json` and `models --json` exit 0.

### Slices Completed & Landed

1. **Slice 1: Steady-State Cache Hit Rate & Cold-Start Labeling (`OpenGrokSessionRuntime`, `OpenGrokACPRuntime`)** — Added `steadyInputTokens` and `steadyCachedTokens` to `SessionCacheSnapshot` and `PromptCacheSummary`. Excluded cold turn #1 from steady totals to avoid permanent percentage dilution. Added intact prefix dip diagnostics when `< 90%` hit rate is due to appended tokens. Updated `x.ai/session_cache` RPC schema (`45774ed`).
2. **Slice 2: Custom Models Settings Catalog & Validation (`OpenGrokPagerRender`)** — Added `custom_models` group and 10 child setting entries (`custom_models.list`, `custom_model_id`, `custom_model_slug`, `custom_model_name`, `custom_model_provider`, `custom_model_base_url`, `custom_model_context_window`, `custom_model_backend`, `custom_model_env_key`, `custom_model_save`). Added `customModelKeyIsValid` and `customModelSlugIsValid` validators (`1b8c5f5`).
3. **Slice 3: Settings Persistence Store & Cold-Start Telemetry Formatting (`OpenGrokCLI`, `OpenGrokPagerRender`)** — Implemented draft custom model persistence via `CustomModelStore` and `PagerSettingsStore`. Wired `applySettingsEvent` for save, draft update, and deletion on multi-select uncheck. Updated `/usage` and `/cache` modal readout to render `Turn #1 — cold start` without 0.0% dilution (`7b6813f`, `7cf66eb`).
4. **Slice 4: Interactive Controller @-File Completion Wiring (`OpenGrokPager`, `OpenGrokCLI`)** — Added `setFileSearchSuggestions` hook and `AtContext` detection in `OpenGrokPagerInteractiveController.swift`. Wired `FuzzyFileTreeWalker` and `FuzzyMatcher` in `LiveComposition.swift` so typing `@` in the interactive composer opens fuzzy path autocomplete and Tab replaces `@query` with `@path/to/file` (`66cdfb6`).

## Wave 22 — Fuzzy File Search, @-Completion Dropdown & Wrap Clipboard Image (2026-08-14, complete)

Current truth for the verified 2026-08-14 Wave 22 Multi-Agent Porting against Rust crates `xai-fuzzy-file-search`, `views/file_search/`, and `wrap_clipboard_image.rs`:

**Verification (lead, local macOS, 2026-08-14; serial gate):**
- `zsh workflows/swift-safe-verify.zsh build` — exit 0.
- `zsh workflows/swift-safe-verify.zsh build-tests` — exit 0.
- `zsh workflows/swift-safe-verify.zsh build --product open-grok` — exit 0.
- Authoritative full `zsh workflows/swift-safe-verify.zsh test --no-parallel` — exit 0: exactly **6,870** Swift Testing cases in **1,058** suites, elapsed **290.70s** (100% green).
- CLI Smokes: `open-grok --version` reports `Open Grok 1.0.0-open-grok.63` (exit 0); `paths --json` and `models --json` exit 0.

### Slices Completed & Landed

1. **Slice 1: Fuzzy Path Matching & Background Directory Indexer (`OpenGrokWorkspace`)** — Implemented `FuzzyMatcher.swift` and `FuzzyFileMatcher.swift` with bonus scoring (prefix, consecutive, word boundaries after `/`, `_`, `-`, `.`, camelCase transitions, exact basename matches), dynamic programming matrix with safe backtrack, `.gitignore` rules engine, and `FuzzyFileMatcherDaemon` background actor (`FuzzyMatcherTests.swift`).
2. **Slice 2: @-Completion Context & State Machine (`OpenGrokPager`)** — Implemented `FileSearchContext.swift` and `FileSearchState.swift` with `AtContext` parsing (`detect_with_drill`, `@` token extraction, directory/hidden mode flags, email false-positive guard), dropdown navigation (`selectNext`, `selectPrevious`, `pageMove`), stale generation fences (`minGeneration`), and prompt text replacements (`FileSearchTests.swift`).
3. **Slice 3: File Search Dropdown Renderer (`OpenGrokPagerRender`)** — Implemented `FileSearchDropdown.swift` rendering matched items into `CellBuffer` with `PagerGlyphs.promptArrow`, selection and hover backgrounds, highlighted matching characters, path truncation with ellipsis (`…`), directory suffix `/`, and scrollbars.
4. **Slice 4: Wrap Clipboard Image Paste Framing (`OpenGrokTerminalCore`)** — Implemented `WrapClipboardImage.swift` with `MAGIC_IMG` (`GROK_WRAP_IMG`), `MAGIC_NONE` (`GROK_WRAP_NONE`), `MAX_WRAP_IMAGE_BYTES` (20 MiB), `requestOscBytes()` (`ESC ] 999;GrokWrapClipboardImage? BEL`), and robust line-based decoding (`WrapClipboardImageTests.swift`).

## Wave 21 — v1.0.0-open-grok.63 Convergence (2026-08-14, complete)

Current truth for the verified 2026-08-14 Wave 21 Multi-Agent Convergence against Rust pin `eb215dd0` / `v1.0.0-open-grok.63`:

**Verification (lead, local macOS, 2026-08-14; serial gate):**
- `zsh workflows/swift-safe-verify.zsh build` — exit 0.
- `zsh workflows/swift-safe-verify.zsh build-tests` — exit 0.
- `zsh workflows/swift-safe-verify.zsh build --product open-grok` — exit 0.
- Authoritative full `zsh workflows/swift-safe-verify.zsh test --no-parallel` — exit 0: exactly **6,811** Swift Testing cases in **1,052** suites, elapsed **300.38s** (100% green).
- CLI Smokes: `open-grok --version` reports `Open Grok 1.0.0-open-grok.63` (exit 0); `paths --json` and `models --json` exit 0.

### Slices Completed & Landed

1. **Slice 1: Token Usage Prompt Cache Hit Rate Helpers & Version Bump** — Bumped `OPEN_GROK_VERSION` to `1.0.0-open-grok.63`. Added `cacheHitRate` (`Double?`) and `cacheHitRatePct` (`Double`) across `TokenUsage`, `UsageTotals`, and `PromptUsageModel` with zero-division safety and steady-state calculations (`Usage.swift`, `UsageTests.swift`).
2. **Slice 2: Prompt Cache Tracking & Session Cache Query** — Implemented `PromptCacheTracker.swift`, `SessionCacheQuery.swift`, and `PromptCacheTrackerTests.swift` capturing `CacheBreakReason` (`systemPromptChanged`, `toolsChanged`, `messageSequenceChanged`, `compaction`, `modelChanged`, `historyRelocated`, `unknown`), `CacheBreakEvent`, `SessionCacheSnapshot`, turn-over-turn cache performance, and `x.ai/session_cache` RPC handler.
3. **Slice 3: Custom Model Store & Persistent Configuration** — Implemented `CustomModelStore.swift` and `CustomModelStoreTests.swift` managing `$OPENGROK_HOME/custom_models.json` atomically with full CRUD operations (`listCustomModels`, `upsertCustomModel`, `deleteCustomModel`), newline validation with `Character.isNewline`, and `mergeCustomModels` ensuring custom models survive live `/models` catalog refreshes.
4. **Slice 4: Pager `/cache` Slash Command & `/usage` Hit Rate Display** — Added `/cache` (aliases `/cache-status`, `/prompt-cache`) command in `OpenGrokPagerCommandUI`, `OpenGrokPagerInteractiveController`, and `LiveInteractiveOverlays`. Added `LiveCacheComposition` and integrated prompt cache hit rate percentages into `/usage` modal readout.
5. **Slice 5: Web Search Domain Filters & Turn-End Drain Queue Hooks** — Implemented `WebSearchFilter.swift` and `WebSearchFilterTests.swift` enforcing config allowlist/blocklist precedence over model-requested domain filters. Implemented `TurnEndHooks.swift` queueing `StopFailure` and `StopCancelled` hooks with `TURN_END_DRAIN_BUDGET = 250ms`.

## Core Subsystems Parity Porting (2026-08-14, complete)

Current truth for the verified 2026-08-14 Core Subsystems Parity Porting against Rust pin `b849ec76` / `v1.0.0-open-grok.62`:

**Verification (lead, local macOS, 2026-08-14; serial gate):**
- `zsh workflows/swift-safe-verify.zsh build` — exit 0.
- `zsh workflows/swift-safe-verify.zsh build-tests` — exit 0.
- `zsh workflows/swift-safe-verify.zsh build --product open-grok` — exit 0.
- Authoritative full `zsh workflows/swift-safe-verify.zsh test --no-parallel` — exit 0: exactly **6,778** Swift Testing cases in **1,048** suites, elapsed **285.72s** (100% green).

### Core Porting Milestones Completed & Landed

1. **Milestone 1: Compaction Checkpoints & Cross-Compaction Rewind** — Implemented `CompactionCheckpointFile`, `CompactionCheckpointInfo`, atomic disk persistence under `compaction_checkpoints/<id>.json`, and deterministic `replayToPrompt` state machine. Restores pre-compaction prompt history and `originalUserInfo` across rewind points (`cf20aec`, `d2bcfb6`, `6690486`).
2. **Milestone 2: Two-Pass Prefire Background Compaction** — Implemented `TwoPassCompaction.swift` with 95% token weight splitting, tool boundary snapping, substantive `<summary>` extraction, 12,000 char capping, 64-bit FNV-1a sequence fingerprinting, speculative background Pass 1 prefire at `threshold - 10%` lead, fast-path Pass 2 apply, single-pass fallback, and multi-dimensional cache invalidation (`b4cdd21`).
3. **Milestone 3: StructuredOutput Synthetic Tool Loop & Monotonic Export Boundary** — Implemented `StructuredOutput` synthetic tool loop (`STRUCTURED_OUTPUT_TOOL = "StructuredOutput"`, up to 3 validation retries) for non-native schema backends. Enforced irreversible monotonic export boundary (`ever_used_codex` / `everUsedNonXAI`) across session routes, sharing endpoints, and subagent executions (`f39f0c9`, `0851a23`).
4. **Milestone 4: Comprehensive 4-Tier E2E Test Suite & Parity Hardening** — Created 93+ dedicated tests across Tier 1 (Feature Coverage), Tier 2 (Boundary & Error Resilience), Tier 3 (Cross-Feature Pairwise Interactions), and Tier 4 (Real-World Multi-Turn Workflows). Full serial suite passed 6,778/6,778 tests across 1,048 suites with 0 regressions. Verified product binary `open-grok`. Published `TEST_READY.md`.

### Slices Completed & Landed

1. **Slice 1: Version Constants & CLI Expectations** — Bumped version constant from `0.1.220-open-grok.58` to `1.0.0-open-grok.62` across `OpenGrokVersionBuildPlugin`, `CompiledVersion.generated.swift`, and all CLI test expectations (`fc618b4`).
2. **Slice 2: Z AI Provider & Models Catalog** — Implemented `.zai` across `OpenGrokSamplingTypes`, `OpenGrokSampler`, `OpenGrokAuth`, `OpenGrokModels`, `OpenGrokPager`, `OpenGrokProviderSession`, and `OpenGrokCLI`. Added curated GLM catalog with 8 models, reasoning effort levels, and Coding Plan endpoint support (`48f7e36`).
3. **Slice 3: Subagent Swarm Detach & `swarm_wait` Tool** — Implemented `SwarmRegistry`, `DetachedSwarm`, `renderDetachedSwarmXML`, and `swarm_wait` tool in `LiveSubagentSwarm.swift` and `LiveToolExecutor.swift`. Swarm cohorts detach into session registry on mid-turn steer instead of hard cancel, allowing `swarm_wait` rejoin or non-blocking polling (`62dde77`).
4. **Slice 4: Owner-Only POSIX Permissions (0700/0600)** — Implemented `setDirOwnerOnly` and `createDirAllOwnerOnly` in `OpenGrokConfig/Paths.swift` securing session directories and search index storage with 0700/0600 permissions (`73dd4e9`).
5. **Slice 5: Sandbox Trailing Glob Normalization** — Created `OpenGrokSandbox/AllowPath.swift` implementing `normalizeAllowPath` for `/**`, `/**/`, `/**/*`, `/*` trailing patterns (`21ab256`).
6. **Slice 6: Active Model Reuse on Session Resume** — Implemented `AttachOperation`, `LoadModelSelectionOrigin`, and `resumeReusesActiveModel` in `OpenGrokACPRuntime/AttachOperation.swift` (`1439f50`).
7. **Slice 7: Session Rename `/rename` & ACP Title Updates** — Created `OpenGrokSessionPersistence/SessionTitleSanitize.swift` with `isForbiddenTitleCharacter`, `sanitizeRenameTitle`, `maxTitleBytes`, and `resetToAuto` title handling (`051804b`).
8. **Slice 8: Invalid Image Error Code & Image Stripping** — Added `parseAPIErrorCode`, `tryParseStreamError`, `isImageProcessingError`, and `stripImagesWithURLs` in `SamplingError.swift` and `LiveConversationStore.swift` (`c9196c7`).

## Local final TUI divergence closure (2026-08-12, complete)

Current truth for the verified 2026-08-12 final TUI divergence closures against
pin `650c1db7` (verify-open-grok run `20260812-divergence-close`). Historical
sections below (including **Local sticky-header + transcript text-selection
follow-on**, **Local remaining-TUI-gap follow-on**, and **Local TUI interaction
wave**) keep their contemporaneous wording; where they conflict on table
box-grid selection, sticky-header drag-selectability, `sticky_headers` config,
composer `PromptEditor` / `OpenGrokTextArea`, FPS HUD / `GROK_FPS` / `/debug fps`,
mouse-off sticky toast, or the invented mouse-off transcript-note claim,
**this section wins**. Prior 2026-08-12 honest lists that still name table
cell/grid→linear degradation, sticky header rows not text-drag selectable as a
divergence, composer `PromptEditor` drag/multi-click / `OpenGrokTextArea` not
adopted, `sticky_headers` config/settings toggle as a gap, FPS HUD / `show_fps`
absent, or mouse-off sticky hint/banner absent (including the invented
transcript-note claim) are **superseded** by the closures and honest leftovers
below.

**Verification (lead, local macOS, 2026-08-12; no platform CI rerun):**

- `zsh workflows/swift-safe-verify.zsh build-tests` — exit 0.
- Focused real `PagerPTYSessionTests` — exit 0, **exactly 3 tests in 1 suite**,
  2.894s.
- First full verbose serial — exit 0, **367.631s**; terminal body truncated, so
  do **not** use its partial count.
- Authoritative count-filtered second full
  `zsh workflows/swift-safe-verify.zsh test --no-parallel` — exit 0: exactly
  **6,470** Swift Testing cases, **1,017** suites, **106** nonempty summaries
  (one summary is 10 tests in 0 suites), elapsed **354.149s**. This is
  final-tree serial.
- Real-CLI smoke (`verify-open-grok`, separate from Swift totals): isolated run
  `20260812-divergence-close`; helper `doctor` / version `0.1.220-open-grok.58`
  exit 0; paths isolated `/tmp` home; models json nonempty default `grok-4.5`;
  `sessions` fresh empty exit 0; `help` exit 0; cleanup succeeded; artifacts
  retained. Does **not** by itself prove interactive TUI.
- **No platform CI run** for this closure — keep the standing warning above.

### Closures (live)

1. **Table box-grid selection** — paint-text geometry detection; fail-closed
   linear on malformed/border-start; cell/grid drag hysteresis; cell partial
   copy and TSV grid; triple cell / whole table; keyed sidecar frozen;
   stale/reflow paint none; empty valid cell no linear fallback; table-shaped
   assistant paint no soft-wrap. The prior “table cell/grid selection degrades
   to linear” claim is **superseded** except the honest leftover below.
2. **Sticky header text not drag-selectable is PIN PARITY, not a divergence** —
   the header band never publishes selectable geometry. Reclassify/remove the
   prior “sticky header rows are not text-drag selectable” divergence claim.
   `$OPENGROK_HOME/pager.toml [scrollback.display].sticky_headers` one-shot
   config is now live, default **true**, compact override. No env / no settings
   row is **upstream parity, not a gap**. Wrong-type parse diagnostic is
   visible; project `pager.toml` is not authority. The prior
   “`sticky_headers` config/settings toggle absent” gap is **superseded**.
3. **Composer `PromptEditor` uses one `OpenGrokTextArea` as the sole mutable
   buffer.** Live click / drag / double word / triple line / wheel /
   edge-autoscroll / selection highlight + OSC 52; same wrap for paint/hit;
   UTF-8 internals at `Character` boundary; selection replacement; X10
   up-none; overlay / resize / suspend cancel; readline fallthrough with host
   policy intercept. The prior “composer `PromptEditor` drag/multi-click still
   absent; full `OpenGrokTextArea` not adopted” claim is **superseded**. Do
   **not** claim full prompt-widget parity (honest leftovers below).
4. **FPS HUD** live via raw `GROK_FPS` nonempty `!= 0` and `/debug fps`; 120
   samples, 250ms cache, full frame layout+writer timing, 2×32 top-right.
   `[animation].show_fps` remains parse-only because the pin also never reads
   it; no settings row / motion gate. `/debug` only advertises `fps` because
   scroll/log HUDs are absent — narrower command surface, recorded below. The
   prior “FPS HUD / `show_fps` absent” gap is **superseded** for the live HUD
   path.
5. **Mouse-off sticky toast** live: successful off ⇒ focus-swapped sticky
   (`Ctrl+r…` scrollback, `/toggle…` prompt); transient wins; on clears +
   `Mouse reporting on`; idle scroll-clock expiry; rollback/minimal; occluder.
   The old invented transcript-note behavior is removed:
   `/toggle-mouse-reporting` no longer appends a system transcript note. Auth welcome raw-url
   mouse-disable/clear remains an honest existing auth divergence.

### Honest leftovers (not claimed fixed)

- **Wrapped-fragment table-cell parity:** **SUPERSEDED in Wave 24:** `OpenGrokMarkdown` now fully implements upstream wrapped cell fragments, two-tier column width budget allocation, `maxTableWidth` layout, 11-glyph box borders (`TableBorders.box`) with intermediate body dividers (`├─┼─┤`), and streaming table checkpoints matching `xai-grok-markdown`.
- **Composer prompt-widget leftovers:** **SUPERSEDED in Wave 22–24:** `@` file-ref search/view landed in Wave 22–23; paste chips, image elements, `WrapClipboardImage` OSC 999 protocol, predicted prompt suggestions (`PromptSuggestionController`), Ghostty Cmd+A selection gating, Kitty chunked graphics, and Alacritty KKP workarounds landed in Wave 24.
- **`[animation].show_fps`** remains parse-only (pin also never reads it); no
  settings row / motion gate.
- **`/debug` advertises only `fps`** because scroll/log HUDs are absent
  (narrower command surface than a full debug-HUD family).
- **Auth welcome raw-url mouse-disable/clear** (`auth_show_raw_url` /
  `auth_mouse_disabled`) remains an existing auth divergence: this port has no
  welcome raw-url mouse-capture state, so it does **not** couple sticky-toast
  clear to an invented auth path.
- **Windows display-refresh probe** remains unsupported; Linux skip matches the
  pin.

Do **not** keep table cell/grid→linear degradation, sticky-header-not-selectable
as a divergence, composer `PromptEditor` / `OpenGrokTextArea` adoption,
`sticky_headers` config/settings toggle as a gap, FPS HUD absent, or mouse-off
sticky banner absent (including the invented transcript-note claim) in current
deferred lists.

## Local sticky-header + transcript text-selection follow-on (2026-08-12, complete)

Contemporaneous record of the verified sticky-header + linear transcript
text-selection closures against pin `650c1db7` (verify-open-grok run
`20260812-deep-tui`). **Superseded as current truth** by **Local final TUI
divergence closure** above for table box-grid selection, sticky-header
drag-selectability (now pin parity), `sticky_headers` config, composer
`PromptEditor` / `OpenGrokTextArea`, FPS HUD, mouse-off sticky toast, and the
invented mouse-off transcript-note claim. Historical sections below (including
**Local remaining-TUI-gap follow-on** and **Local TUI interaction wave**) keep
their contemporaneous wording; where they conflict on sticky headers, transcript
text drag/multi-click, `keep_text_selection`, or the native/modifier link gate,
**this section still wins over those older sections**, but not over the final
TUI divergence closure. Prior remaining-gap lists that still name broad “sticky
headers absent” or “text drag/multi-click absent” remain **superseded** by the
closures below.

**Verification (lead, local macOS, 2026-08-12; no platform CI rerun):**

- `zsh workflows/swift-safe-verify.zsh build-tests` — exit 0.
- Expanded deep TUI filter — exit 0, **exactly 310 tests in 47 suites**
  (sum of five test-run summaries: 27/9 + 32/6 + 99/10 + 6/1 + 146/21).
- Real PTY filters `PagerPTYSessionTests|InferencePTYScenarioTests` — exit 0,
  **5 tests in 2 suites**.
- `zsh workflows/swift-safe-verify.zsh test --no-parallel` count-only — exit 0:
  exactly **5,682** Swift Testing cases, **970** suites, **74** nonempty test-run
  summaries, elapsed **345.286s**, zero failed summaries/issues. Authoritative
  final-tree serial.
- Real-CLI smoke (`verify-open-grok`, separate from Swift totals): isolated run
  `20260812-deep-tui`; helper `doctor` exit 0 / version `0.1.220-open-grok.58`;
  `sessions list` exit 0 with fresh-home empty listing; `help sessions` exit 0;
  cleanup succeeded; artifacts retained. Does **not** claim TUI sticky-header or
  text-selection behavior.
- **No platform CI run** for this follow-on — keep the standing warning above.

### Closures (live)

1. **Sticky headers default-live when `!compact`** — pinned user-prompt
   collapse/push/clip/fade, reduced content band, sticky-aware mouse hits/gaps,
   action-time PageUp/PageDown header recompute, compact keeps the old
   (non-sticky) behavior, scrollbar/timeline logical offsets honor the sticky
   band. No settings-toggle reader yet; default **true** is forced. Cosmetic
   min-height / ellipsis / indexed-fade divergence may remain where code comments
   retain it — not claimed closed.
2. **Linear transcript text drag / multi-click** — last-painted selectable
   geometry; Unicode / offscreen reflow-safe copy via OSC 52; drag threshold;
   chrome→text conversion; X10; URL/word double-click + line triple-click in
   `word_select`; flash / hold / `word_select` live settings + legacy-key
   transaction/reset; autoscroll dedicated clock + action-time reclamp;
   resize-safe frozen width; Esc / new-down clear; suspend deadline.
   Appearance/Mouse **`keep_text_selection`** is live (leaves the hidden-rows
   list). Link native/modifier gate is aligned (prior bare left-click same-cell
   divergence note is **superseded** for that gate).
3. **Timeline test interaction update** is **test-only proof**, not a product
   feature claim — do not read suite coverage of timeline interaction as a new
   live timeline capability beyond what prior waves already recorded.

### Honest remaining divergences (contemporaneous deep-tui; superseded)

*Superseded later 2026-08-12 by Local final TUI divergence closure.*
Contemporaneous wording kept:

- **Table cell/grid selection** degrades to linear selection.
- **Sticky header rows are not text-drag selectable.**
- **Composer `PromptEditor` drag/multi-click** still absent; full
  `OpenGrokTextArea` not adopted.
- **`sticky_headers` config/settings toggle** absent even though default sticky
  behavior is live (forced default true; no reader/row).
- **FPS HUD / `show_fps`** and **mouse-off sticky hint/banner** (port still has
  no sticky-toast surface for mouse-off; slash toggle note remains).
- **Windows display-refresh probe** (unsupported); Linux remains an honest skip
  (unsupported by Rust at this pin too).
- **Auth welcome raw-url mouse-disable** (`auth_show_raw_url` /
  `auth_mouse_disabled` at `app_view.rs:4872-4892`) is an existing auth
  divergence: this port has no welcome raw-url mouse-capture state, so it does
  **not** couple sticky-toast clear to an invented auth path. Upstream clears
  sticky toast when re-enabling capture after the auth URL is hidden; keep that
  as a recorded auth gap, not a sticky-toast feature.

Do **not** keep broad “sticky headers absent” or “transcript text drag /
multi-click absent” claims in current deferred lists — those paths are closed
above. Do **not** keep `keep_text_selection` or the Rust native-hover /
Cmd-modifier link gate in current deferred lists either. For current leftovers
(wrapped-fragment table cells, composer prompt-widget extras, parse-only
`show_fps`, narrower `/debug fps`, auth welcome raw-url, Windows probe), see
**Local final TUI divergence closure**.

## Local remaining-TUI-gap follow-on (2026-08-12, complete)

Verified remaining-TUI-gap closures against pin `650c1db7` (scroll stream,
background chip, direct mouse, display probe, animation `pager.toml`,
mouse-reporting toggle, link-scheme safety). For table box-grid selection,
sticky-header drag-selectability / `sticky_headers` config, composer
`PromptEditor` / `OpenGrokTextArea`, FPS HUD, and mouse-off sticky toast, see
**Local final TUI divergence closure** above — **that section wins**. For sticky
headers, transcript text drag/multi-click, `keep_text_selection`, and the
native/modifier link gate, see **Local sticky-header + transcript text-selection
follow-on** above — **that section wins over this one**. Historical sections
below (including **Local TUI interaction wave**) keep their contemporaneous
wording; where they conflict on scroll stream, background chip, direct mouse
(scrollbar/link/composer), display-refresh probe, pager animation config,
mouse-reporting toggle, or link-scheme safety, **this section wins**.

**Verification (lead, local macOS, 2026-08-12; no platform CI rerun):**

- `zsh workflows/swift-safe-verify.zsh build-tests` — exit 0.
- Comprehensive remaining-gap filter — exit 0, **exactly 223 tests in 41 suites**
  (sum of five test-run summaries: 27/9 + 32/6 + 54/7 + 6/1 + 104/18).
- Background lifecycle+spinner focused — exit 0, **50 tests in 9 suites**.
- Real PTY filters `PagerPTYSessionTests|InferencePTYScenarioTests` — exit 0,
  **5 tests in 2 suites**.
- `zsh workflows/swift-safe-verify.zsh test --no-parallel` count-only — exit 0:
  exactly **5,599** Swift Testing cases, **965** suites, **74** nonempty test-run
  summaries, elapsed **333.910s**, zero failed summaries/issues. Authoritative
  final-tree serial rerun after link-scheme filtering + mouse terminal-write
  rollback.
- Real-CLI smoke (`verify-open-grok`, separate from Swift totals): isolated run
  `20260812-remaining-tui`; helper `doctor` exit 0 / version `0.1.220-open-grok.58`;
  `sessions list` exit 0 with fresh-home empty listing; `help sessions` exit 0;
  cleanup succeeded; artifacts retained. Does **not** claim TUI mouse or animation
  behavior.
- **No platform CI run** for this follow-on — keep the standing warning above.

### Closures (live)

1. **Full Rust-style mouse scroll stream normalizer** — 80ms stream window, 16ms
   dedicated scroll clock, residual/coast, acceleration, remux/terminal profiles;
   live `scroll_speed` / `scroll_mode` / `scroll_lines` / `invert_scroll` readers and
   Appearance/Mouse rows; settings reset re-resolves the project layer. The prior
   "wheel acceleration is not ported" / hidden-scroll-settings notes are
   **superseded**.
2. **Active background chip/motion feed** via an idempotent push cache — shell/
   monitor, running non-workflow subagents, all scheduled work, and active
   workflows; atomic scheduler provisional replacement. Chip appears/spins/
   disappears and demand parks. The prior "background-task count/spinner remains
   render-only" gap is **superseded**.
3. **Direct mouse** — scrollbar click/drag; safe same-cell transcript links;
   composer focus/cursor via `PromptEditor`; block click remains. Hit priorities,
   capturing modal quarantine, and X10 up-none are honored. Prior deferred link-
   click / scrollbar-drag / composer-mouse claims for these paths are
   **superseded**.
4. **macOS CoreGraphics refresh-rate probe** feeds auto cadence; Linux is an
   honest skip (Rust also unsupported there); Windows remains unsupported. The
   Wave 12 "Display-refresh probe: `probedRefreshHz` is nil" deferral is
   **superseded** for macOS.
5. **`$OPENGROK_HOME/pager.toml` animation** `fps` / `wave_rows` are live readers.
   `show_fps` HUD remains absent (recorded gap below).
   *Superseded later 2026-08-12 by Local final TUI divergence closure: FPS HUD
   live via raw `GROK_FPS` nonempty `!= 0` and `/debug fps`; `[animation].show_fps`
   remains parse-only because the pin also never reads it.*
6. **Mouse-reporting toggle feature gate** — env > effective `[ui]` > default
   `false`; command hidden/refused when off; scrollback `Ctrl+R` when on; prompt
   focus inert for the chord; in-memory rollback on failed terminal write.
7. **Security — Standard URL schemes only** (`http` / `https` / `mailto`) before
   `LinkSpan` publish, OSC 8 emission, and the opener; `file` / `javascript` /
   custom / relative rejected. Quoted landed lines (re-read 2026-08-12; AGENTS §5):

   `Sources/OpenGrokPagerRender/PagerLinkSchemeSafety.swift:28-46` (allows table):

   ```
   public func allows(scheme: String) -> Bool {
       let normalized = scheme.lowercased()
       switch self {
       case .standard:
           switch normalized {
           case "http", "https", "mailto":
               return true
           default:
               return false
           }
       case .editorExtended:
           switch normalized {
           case "http", "https", "mailto", "file", "vscode", "cursor", "idea", "zed":
               return true
           default:
               return false
           }
       }
   }
   ```

   `Sources/OpenGrokPagerRender/PagerLinkSchemeSafety.swift:56-87` (safe parser):

   ```
   public func pagerURLIsSafeToOpen(
       _ url: String,
       filter: PagerLinkSchemeFilter = .standard
   ) -> Bool {
       let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
       guard !trimmed.isEmpty else { return false }

       if let parsed = URL(string: trimmed),
          let scheme = parsed.scheme,
          !scheme.isEmpty
       {
           return filter.allows(scheme: scheme)
       }

       // Fallback: scheme via "://" when Foundation rejects the string
       // (`link_opener.rs:266-269`). Lowercase before matching the filter.
       if let separator = trimmed.range(of: "://") {
           let scheme = String(trimmed[..<separator.lowerBound])
           return filter.allows(scheme: scheme)
       }

       // mailto may lack "//"; only that scheme gets the bare-colon fallback
       // (`link_opener.rs:271-277`). Other colon forms (tel:, javascript:) stay
       // rejected unless Foundation already classified them above.
       if let colon = trimmed.firstIndex(of: ":") {
           let scheme = String(trimmed[..<colon])
           if scheme.lowercased() == "mailto" {
               return filter.allows(scheme: scheme)
           }
       }

       return false
   }
   ```

   `Sources/OpenGrokCLI/LiveComposition.swift:12693-12701` (guard/open):

   ```
   private func openExternalURL(_ url: String) {
       guard pagerURLIsSafeToOpen(url) else { return }
       let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
       guard let openBrowser = urlOpener,
             let parsed = URL(string: trimmed) else {
           note("Could not open a browser. Open this URL manually:\n\(trimmed)")
           return
       }
       openBrowser(parsed)
   }
   ```

   `Sources/OpenGrokPagerRender/PagerTerminalRenderer.swift:749-756`
   (defense-in-depth):

   ```
       for span in spans {
           // Defense in depth: never emit OSC 8 for a scheme Standard rejects,
           // even if a stale LinkSpan slipped past paint-time filtering
           // (`link_opener.rs:261-278` / `hyperlinks.rs:28-46` at pin 650c1db7).
           guard pagerURLIsSafeToOpen(span.url) else { continue }
           let start = max(area.left, span.colStart)
           let end = min(area.right, span.colEnd)
           guard span.row >= area.top, span.row < area.bottom, start < end else { continue }
   ```

### Honest remaining gaps (contemporaneous remaining-TUI-gap; superseded in part)

*Superseded later 2026-08-12 by Local sticky-header + transcript text-selection
follow-on for:* sticky headers (default-live when `!compact`); linear transcript
text drag/multi-click + live `keep_text_selection`; Rust native-hover /
Cmd-modifier link gate alignment. *Superseded later 2026-08-12 by Local final
TUI divergence closure for:* table box-grid selection; sticky-header
drag-selectability (pin parity, not a divergence); `sticky_headers` one-shot
`pager.toml` config; composer `PromptEditor` / `OpenGrokTextArea`; FPS HUD /
`GROK_FPS` / `/debug fps`; mouse-off sticky toast (invented transcript-note
claim retired). Contemporaneous “still open” wording kept: table
cell/grid→linear degradation; sticky header rows not text-drag selectable;
composer `PromptEditor` drag/multi-click / full `OpenGrokTextArea`;
`sticky_headers` config/settings toggle; mouse-off sticky hint/banner; FPS HUD /
`show_fps`; Windows display probe. For current leftovers see **Local final TUI
divergence closure**.

Do **not** keep background spinner, scroll normalizer/acceleration, composer
focus/cursor, safe link click, scrollbar click/drag, mouse-reporting toggle, or
macOS display probe in current deferred lists — those are closed above.

## Local TUI interaction wave (2026-08-11, complete)

Verified local TUI animation + mouse interaction closures against pin `650c1db7`
as of 2026-08-11. For table box-grid selection, sticky-header drag-selectability /
`sticky_headers` config, composer `PromptEditor` / `OpenGrokTextArea`, FPS HUD,
and mouse-off sticky toast, see **Local final TUI divergence closure** above. For
sticky headers / transcript text selection / `keep_text_selection` /
native-modifier link gate, see **Local sticky-header + transcript text-selection
follow-on** above. For scroll stream, background chip, scrollbar/link/composer
mouse, display probe, animation `pager.toml`, mouse-reporting toggle, and
link-scheme safety, see **Local remaining-TUI-gap follow-on** above. Historical
wording below is preserved.

**Verification (lead, local macOS, 2026-08-11; no platform CI rerun):**

- `zsh workflows/swift-safe-verify.zsh build-tests` — exit 0.
- Focused final TUI matrix — exit 0, **exactly 154 tests in 25 suites** (sum of five
  test-run summaries: 28/4, 15/1, 14/3, 67/12, 30/5).
- Real PTY filters `PagerPTYSessionTests|InferencePTYScenarioTests` — exit 0,
  **5 tests in 2 suites**.
- `zsh workflows/swift-safe-verify.zsh test --no-parallel` count-only — exit 0:
  exactly **5,423** Swift Testing cases, **932** suites, **74** nonempty test-run
  summaries, elapsed **303.118s**, zero failed summaries/issues.
- Real-CLI smoke (`verify-open-grok`, separate from Swift totals): isolated run
  `20260811-212555-45552`; helper `doctor` exit 0 / version `0.1.220-open-grok.58`;
  `sessions list` exit 0 with fresh-home `No sessions found.`; `help sessions`
  exit 0; cleanup succeeded; artifacts retained. Does **not** claim TUI mouse or
  animation behavior.

### Animations (live)

1. **Live elapsed / finish-flash stamps** use a monotonic extrapolated motion clock
   seeded at begin, so idle gaps and pre-first-tick sessions do not jump or skip flash.
2. **Motion state delivery** is ordered/coalesced; sink replacement awaits old delivery;
   stale fast demand cannot re-arm after `.none`.
3. **Welcome shimmer** breath and diagonal match pinned Rust; the renderer uses the
   helper.
4. **TUI suspend** explicitly pauses/cancel-awaits the controller ticker and pending
   flush, paints nothing during child ownership, restores then re-arms; a shutdown latch
   prevents child return from rearming into teardown; renderer errors now propagate
   rather than being swallowed.

### Mouse (live)

5. **`TerminalInputDecoder` preserves full legacy X10 reports**, including split
   reads/releases/wheel, so coordinate bytes no longer become composer keys; SGR remains
   live. The earlier build-out-wave-2 "Legacy X10 mouse reports still leak" claim is
   **superseded**.
6. **iTerm/WezTerm wheel tuning is 1/1**; capturing modals quarantine outside wheel;
   horizontal wheel is a no-op.
7. **Transcript left down/up** selects visible blocks through exact last-painted hit
   geometry, excludes gaps/system/separators/scrollbar/rail/modal/composer, freezes
   down-frame geometry, handles X10 up-none, and returns `focusScrollback` so keyboard
   focus matches paint. The Wave 14.1 "mouse block selection is a feature gap" claim is
   **superseded** for this left-click visible-block path.

### Honest remaining gaps (contemporaneous 2026-08-11; superseded in part)

*Superseded 2026-08-12 by Local remaining-TUI-gap follow-on for:* background-task
count/spinner push seam; full Rust scroll-stream normalizer/acceleration + live
`scroll_*` / `invert_scroll` readers; link click (safe same-cell); scrollbar
click/drag; composer focus/cursor via `PromptEditor`; opt-in mouse-toggle /
scrollback `Ctrl+R`; macOS display-refresh probing. *Superseded later 2026-08-12
by Local sticky-header + transcript text-selection follow-on for:* sticky headers
(default-live when `!compact`); linear transcript text drag/multi-click + live
`keep_text_selection`; Rust native-hover/Cmd-modifier link gate. *Superseded
later 2026-08-12 by Local final TUI divergence closure for:* table box-grid
selection; sticky-header drag-selectability (pin parity); `sticky_headers`
one-shot config; composer `PromptEditor` / `OpenGrokTextArea`; FPS HUD; mouse-off
sticky toast. Contemporaneous “still open” wording kept: table cell/grid→linear
degradation; sticky header rows not text-drag selectable; composer drag/select /
full `OpenGrokTextArea`; `sticky_headers` config/settings toggle; mouse-off
sticky hint/banner; FPS HUD/`show_fps`; Windows display probe. For current
leftovers see **Local final TUI divergence closure**.

## Local correctness wave (2026-08-11, complete)

Current truth for the same-day local correctness closures (ACP / Hub MCP / same-process
resume / foreign `sessions list`). For TUI table/composer/FPS/mouse-off toast,
sticky/text-selection, remaining TUI gaps, animation / mouse, see **Local final TUI
divergence closure**, **Local sticky-header + transcript text-selection follow-on**,
**Local remaining-TUI-gap follow-on**, and **Local TUI interaction wave** above.
Historical sections below keep their contemporaneous wording; where they conflict
with this section's closures, **this section wins**.

**Verification (lead, 2026-08-11; no platform CI rerun):**

- `zsh workflows/swift-safe-verify.zsh build-tests` — exit 0.
- Focused filter (ACP composition, foreign gating, subagent tool/swarm, Hub
  adapter/coordinator) — exit 0, **60 tests in 13 suites**.
- `zsh workflows/swift-safe-verify.zsh test --no-parallel` — exit 0 twice; count-only
  second run: exactly **5,366** Swift Testing cases, **926** suites, **74** nonempty
  test-run summaries, elapsed **314.694s**, zero failed summaries/issues.
- Real-CLI smoke (`verify-open-grok`, separate from Swift totals): isolated run
  `20260811-181209-36619` under `/tmp/open-grok-verify-…`; helper `doctor` exit 0 /
  version `0.1.220-open-grok.58`; `sessions list` evidence exit 0 with fresh-home
  `No sessions found.`; `help sessions` evidence exit 0; cleanup succeeded; artifacts
  retained under `.cursor/skills/verify-open-grok/artifacts/`. Does **not** claim
  foreign-fixture `sessions list` behavior.

**Live closures:**

1. **ACP reverse permission bridge — LIVE-PROVEN.** Tests attach a fake reverse
   client to composed `liveACPServices` components and assert
   `session/request_permission`; rejection, no channel, and transport error all leave
   `mayDispatch` false. Security install lines (quote required):

   ```
   let acpPermissionPrompter = LiveACPPermissionPrompter()
   let permissionPipeline = foundation.toolExecutor.toolPermissionPipeline()
   if let permissions = await foundation.toolExecutor.permissionHandle() {
       await permissions.setPrompter(acpPermissionPrompter)
   }
   ```

   Landed at `Sources/OpenGrokCLI/LiveComposition.swift:3134-3138`. The earlier
   "live-unproven / no harness constructs `liveACPServices`" record below is
   **superseded**.

2. **Hub MCP `closeCount` flake — root cause fixed.** Explicit `McpBridge.shutdown`
   and `deinit` independently closed the same transport. `McpTransportCloseOnce`
   now single-flights explicit close, shares sticky success/failure, never retries
   success, and permits one bounded deinit best-effort retry only after failure.
   Tests cover the adapter and `HubMCPBridgeCoordinator`. Do **not** overclaim a
   direct `LiveHubSessionMCP.stop` close proof — its adapter close is a no-op. The
   Rhai flake was already fixed; there are **no known remaining local flaky tests
   from that pair**. CI reliability remains unproven.

3. **Same-process `resume_from` / `agent_swarm resume_agent_ids`.** Record/inherit
   source `childCWD` / worktree identity; caller cwd is ignored; missing non-worktree
   cwd and missing recorded worktree fall back to parent per pinned Rust
   `subagent/mod.rs:1590-1632`. Cross-process durable subagent metadata/resume
   remains deferred.

4. **Foreign `sessions list` gating.** No longer scans Claude/Codex unconditionally.
   Uses authoritative effective config + env and the matching resume skill gate
   before vendor I/O, with zero scanner calls when disabled; `--cwd` controls
   project config and scanner matching (pinned Rust `foreign_sessions.rs:281-365`).
   Import/writeback and Cursor scan are **not** required parity at this pin — do not
   advertise them as active deferred parity.

### Still deferred from the audit

Durable cross-process subagent resume, relocation journal, portable WSS/custom CA,
Windows WinSock loopback server, the reproducible macOS live-composition CI stop
(`OpenGrok executable parity composition` /
`live composition applies agent profiles with CLI model precedence`), and the
Antigravity follow-ons listed in the Antigravity section below.

## Wave 20 — Deferred parity Batch 2 (2026-08-10, complete)

**Scope.** Batch 1 (share protocols, model reconcile, MCP prefs, session admin,
TaskCompleted wake, hub coordinator library) plus Batch 2 (search_tool/use_tool,
config authority spine, foreign-session scanners, JSC module loader, git pack
deltas, XTVERSION, legacy workflow inventory). Lead integration wired the
remaining deferred seams below.

**Verification:** `zsh workflows/swift-safe-verify.zsh test --no-parallel` exited 0
on 2026-08-10 with **5,786 Swift Testing cases across 105 nonempty summaries** and
zero issues.

### Live closures (lead-integrated)

- **search_tool / use_tool:** meta-tool handlers register on the live toolset;
  `LiveMCPToolSearchIndex` refreshes after MCP connect and ACP mutations; built-in
  profiles advertise the tools again (`builder.rs:2243-2261`, `use_tool/mod.rs:63-77`).
- **Config authority spine:** `AllowlistedRemoteSettings` is the only projection
  path for remote fields consumed by telemetry, workspace command gate, share gate,
  and privacy banner refresh (`config.rs:3031-3037`).
- **MCP disabled tools at connect:** `MCPToolBridge.register` skips per-server
  disabled tool names read from `disabled_mcp_tools`; disabled servers are skipped
  at `connectConfiguredServers` (`run_loop.rs:1515`, `mcp.rs:994`).
- **Share HTTP clients:** `LiveShareSignedUploadHTTPClient` and
  `LiveShareBackendHTTPClient` reach the launcher through
  `LiveShareRouteDependencies`; headless `open-grok share` can upload via signed
  URL (best-effort) and complete the backend upsert/save/share flow
  (`share.rs:150-199`, `client.rs:360-388`).
- **Foreign sessions:** `LiveForeignSessionScanner` feeds `sessions list` with
  Claude/Codex summaries (read-only). **Later the same day (Local correctness
  wave):** gated on authoritative effective config + env and the matching resume
  skill before vendor I/O (`foreign_sessions.rs:281-365`); import/writeback and
  Cursor scan are not required parity at this pin.
- **XTVERSION / doctor:** `LiveXtversionCollector` folds into `/doctor` when a TTY
  is available (`xtversion.rs:38-65`).

### Wave 20 follow-on (2026-08-10)

Landed after the Wave 20 serial gate; focused proof before the commit gate:

- **ACP `x.ai/share_session`:** `LiveShareACPHandler` returns the raw `share_url`
  object (no ExtMethodResult envelope) through the live ACP extension router;
  export-boundary registration covers resident ACP sessions (`share.rs:31-56`).
- **CLI `--tools` / `--disallowed-tools`:** unrefused; `resolveLaunchPolicy` merges
  into `LiveAgentToolPolicy` at tool-executor construction (`config.rs:1733-1768`).
- **Child reasoning effort:** `OpenGrokLiveSamplingRequest.reasoningEffort` reaches
  the production sampler; `LiveSubagentHost.runChild` parses persona effort tokens
  (`handle_request.rs:705-714`).
- **`SetPlanMode(Off)` / settings `plan_mode`:** `disarmPlanMode` → `exitPlanMode()`;
  settings apply accepts a bool like swarm (`exit_plan_mode` path).
- **`session_recap` remote gate:** allowlisted through `AllowlistedRemoteSettings` →
  `EffectiveFeatures` → `LiveRecap.enabled` (`config.rs:2657-2667`).

**Verification:** `zsh workflows/swift-safe-verify.zsh test --no-parallel`
exited 0 on 2026-08-10 with **5,801 Swift Testing cases across 105 nonempty
summaries** and zero issues. Focused pre-gate: ConfigSpine **34**,
share/ACP/launch/child-effort **32**, plan+child-effort **11**.

### Wave 20 follow-on batch 2 (2026-08-10)

- **Dream honesty:** `/dream` and auto-dream claims removed from live docs and
  memory setting copy; settings row already hidden until consolidation exists.
- **OIDC JWKS id_token validation:** browser login verifies signature + claims
  via discovery `jwks_uri` before persist (`protocol.rs:639-715`).
- **CLI `--max-turns`:** unrefused; `LiveShellSamplingDriver` stops before the
  next sampler round when `toolTurnCount + 1 > limit` (`turn.rs:3130-3140`),
  returning `stopReason: "max_turns_reached"`.
- **`page_flip_on_send`:** live on `turnStarted` via `revealBlock` + per-frame
  re-pin; Appearance settings row restored (`queue.rs:420-421`, `nav.rs:608-619`).

**Verification:** `zsh workflows/swift-safe-verify.zsh test --no-parallel`
exited 0 on 2026-08-10 with **5,819 Swift Testing cases across 105 nonempty
summaries** and zero issues.

### Deferred runtime wave (2026-08-10)

Rust-parity recommended slices against pin `650c1db7`, lead-wired through
`LiveComposition` / pager / settings honesty:

- **Auto-mode heuristic + LLM classifier:** `HeuristicPermissionClassifier` is
  the default; entering `.auto` (Shift+Tab / settings / ACP) installs
  `LlmPermissionClassifier` via `LiveAutoModeComposition` (aux sampler + JSON
  schema, 30s timeout → ask; unparseable → heuristic). Deliberate gap: no
  tree-sitter shell parse — opaque shell Blocks (Rust fail-closed when parse
  fails).
- **Hub MCP session connect (Rust direction):** local MCP clients bridge onto the
  hub `ToolHarness` via `MCPClientTransportAdapter` + `LiveHubSessionMCP`
  (`handle.rs:start_session_mcp_servers`, `mcp.rs:21+`). S6
  `HubMCPBridgeCoordinator` stays loopback/test-only.
- **Dream runtime + `/dream`:** lock/gates + consolidation in `OpenGrokMemory`;
  live command uses the auxiliary sampler route; `memory.dream.enabled` unhidden;
  docs restored. Auto-dream at session-end remains a follow-on.
- **Voice:** macOS `__mic-capture` child path (not in-process AVFoundation in the
  TUI); `/voice` toggles dictation into the prompt; settings rows unhide only when
  `VoiceCapabilities.detect()` reports capture support.
- **LSP `pull_diagnostics` + post-edit sync:** `OpenGrokLSP` registers the tool
  when `features.lsp_tools` is on and `lsp.json` has servers; after
  `search_replace` / `edit`, live `LiveToolExecutor` re-reads disk, notifies
  the session, drains diagnostics into a `<system-reminder>` (Rust
  `LspDiagnosticsReminder`).
- **`image_to_video`:** backend-gated beside image tools; tier-restricted upsell;
  no `reference_to_video` / `/imagine-video`.

**Verification:** `zsh workflows/swift-safe-verify.zsh test --no-parallel`
exited 0 on 2026-08-10 with **5,872 Swift Testing cases across 106 nonempty
summaries** and zero issues.

### Auto-mode LLM + full LSP sync (2026-08-11)

Lead-wired the two remaining deferred-runtime library seams:

- **LLM auto classifier:** `LlmPermissionClassifier` +
  `LiveAutoModeComposition.installLLMClassifier` on `.auto`; transcript refresh
  before each tool batch; settings `permission_mode` and ACP
  `x.ai/yolo_mode_changed` route through `LiveSessionPermissionMode`.
- **Full LSP sync:** document tracking + `publishDiagnostics` +
  `notifyFileChanged` / `drainDiagnostics` on the live edit path (above).

**Verification:** `zsh workflows/swift-safe-verify.zsh test --no-parallel`
exited 0 on 2026-08-11 with **5,285 Swift Testing cases across 74 nonempty
summaries** and zero issues (one prior serial attempt hit an unrelated flaky
`RhaiEngine` peakConcurrency assertion; re-run was clean).

### Platform CI, `reference_to_video`, ACP reverse permissions (2026-08-11)

**CI had never been green.** Every push since the platform jobs were added
failed, on all three platforms, for three independent reasons — so no platform
except the author's laptop had ever produced signal, and every "green gate"
claim above this line was macOS-local only:

- **macOS** built the advertised-tool list as one seven-term `+` chain with a
  trailing closure and blew the type checker's budget on a cold runner
  (`LiveComposition.swift`). It compiled locally only off a warm incremental
  cache — the break was invisible to every local gate and red on every push.
  Now built by appends.
- **Linux** ran `bwrap` under Docker's default seccomp/AppArmor profile, where
  `unshare(CLONE_NEWUSER)` is `EPERM`; the sandbox probe failed and took the
  build and the serial suite with it. The container now runs `--privileged`.
  Behind it sat a second, never-compiled break: `Sources/OpenGrokSandbox/Platform.swift`
  passed an optional `baseAddress` to `Glibc.execve`, which is non-optional on
  Linux and implicitly unwrapped on Darwin — i.e. the sandbox exec path had
  never compiled on the platform whose sandbox it implements.
- **Windows** compiled the POSIX-only PTY C shim unconditionally (`pid_t`,
  `<sys/ioctl.h>`) and declared a zlib shim against an SDK with no `<zlib.h>`.
  The C shim is now `#if !defined(_WIN32)`-guarded and the zlib target is
  dropped on Windows, which arms `ObjectStore`'s existing typed
  "zlib … unavailable on this platform" arm.

Also fixed: the LSP tests landed in the previous wave used `await` in a `defer`
body, which this toolchain accepts and CI's rejects. They now route through
`withLSPSession`, which shuts the session down on the throwing path too — the
naive rewrite (shutdown after the last assertion) strands a language-server
child process whenever a `try #require` fires first.

**Live closures:**

- **`reference_to_video`:** registered as a pair with `image_to_video` under the
  one video-gen gate, exactly as upstream advertises them
  (`builder.rs:781-788`). Base model `grok-imagine-video`, 2–7 reference images,
  required `aspect_ratio`, Rust's validation order and verbatim refusal strings
  (`video_gen/mod.rs:1136-1189`), and the SuperGrok upsell returned as success
  text with no HTTP (`mod.rs:713`, `:1170-1173`). The advertised-tool parity pin
  was extended rather than loosened.
- **ACP reverse permission bridge:** `LiveACPPermissionPrompter` issues
  `session/request_permission` to the ACP client, upstream's always-ask posture
  (`permission/prompter.rs:775-781`). Every unavailable path — no reverse
  sender, transport error, encode/decode failure, unknown option id, timeout —
  denies; `cancelled` maps to cancelled, never allow. `PermissionHandle` gained
  `setPrompter` because `prompter` is actor-isolated state.

**Verification:** `zsh workflows/swift-safe-verify.zsh test --no-parallel`
exited 0 on 2026-08-11 with **5,306 Swift Testing cases across 74 nonempty
summaries** and zero issues.

**Recorded honestly, not fixed (contemporaneous 2026-08-11 morning; superseded
by Local correctness wave above):**

- ~~The prompter's *install* line in `liveACPServices` has no reachability test.~~
  **Superseded:** composition tests now attach a fake reverse client through
  `liveACPServices` and prove install + fail-closed outcomes; see Local
  correctness wave §1 and `LiveComposition.swift:3134-3138`.
- ~~**Two tests are flaky under full-suite load**~~ / ~~hub MCP
  `transport.closeCount == 1` flake is **not** fixed~~ — **superseded:** Rhai
  rendezvous fix already landed; Hub MCP double-close root cause fixed via
  `McpTransportCloseOnce` (Local correctness wave §2). No known remaining local
  flaky tests from that pair; **CI reliability remains unproven** (do not treat
  local green as platform-CI green).

### Antigravity (2026-08-11) — minimal slice live

`antigravity:<model>` now routes out of process to `agy --print` instead of
spawning an in-process child session, matching upstream's dispatch
(`antigravity.rs:35,41,67-81`, `antigravity_runner.rs:100-127`). The runner
builds upstream's argv (`build_command`, `:549-578`), classifies stdout as text
because `agy` exits 0 on errors (`classify_output`, `:483-526`), and bounds the
child through `terminationHandler` — never `waitUntilExit`, per §2. Defaults
match upstream: subagents off, `skip_permissions` on, with a caller-pinned
read-only capability mode clamping it off (`antigravity_runner.rs:259-271`).

The two settings rows are no longer hard-hidden; they are gated on `agy` being
installed, the same shape voice uses and the same gate upstream applies
(`settings_modal/state.rs:977-1000`). On a machine without the CLI they stay
invisible, so no row advertises a feature that cannot run.

**Deliberately not done:** log-tail phase heartbeats, the Language-Server HTTP
quota/models probe, the `/usage` Antigravity section, `--conversation` resume
(resuming an Antigravity child refuses), and effort-suffix retries — the bulk of
`antigravity.rs` past the core `run_print` path.

### Platform state after the CI unbreak (2026-08-11, PR #1)

Each platform now fails *later* than it ever has, which is what turned three
opaque red jobs into a concrete queue of real defects:

| Platform | Before | After |
| --- | --- | --- |
| macOS | died in `Build` (type-check budget) | builds, links, compiles tests, runs the suite |
| Linux | died at the bubblewrap probe | clears the probe, builds product **and** all test targets, runs the suite |
| Windows | died on the first C target | past the C targets and `OpenGrokPaths`, now in test support |

Findings from the first runs that actually executed, and what was done:

- **Linux died on SIGPIPE (signal 13)** a moment into the suite — **fixed.** The
  portable socket shim wrote with `write(2)`, which raises SIGPIPE once the peer
  is gone; SIGPIPE is fatal by default on Linux, and Apple never reaches that
  branch at all (the Swift layer prefers Network.framework whenever it can
  import it), so no macOS run could have caught it. Writes now request `EPIPE`
  via `MSG_NOSIGNAL`, `SO_NOSIGPIPE` is set at connect/accept where that is the
  spelling, and the executable installs the process-wide ignore at startup
  rather than leaving it to whichever subsystem initializes first.
- **Windows** needed POSIX assumptions removed from `OpenGrokTestSupport`
  (`CountingServer`, `HttpServer`, `EnvGuard`) and a `String.Index.distance(to:)`
  call that does not exist. The two loopback servers now refuse on Windows with
  a typed `HttpServerError.unsupportedPlatform` instead of pretending to bind;
  `EnvGuard` routes through `_putenv_s`. A real Windows loopback server belongs
  on the WinSock path `COpenGrokSockets` already implements — not done.
- **macOS still fails its gate, and not on an assertion.** The run goes quiet
  for eight and a half minutes and then exits 1 with no recorded issue and no
  signal name. Two of three runs stopped the instant
  `DefaultProtoCompiler falls back to PATH lookup` printed `started` and never
  printed `passed`; the third stopped one test earlier. That test and its
  neighbours are hermetic — injected `pathLookup`, `validateCandidates: false`,
  no subprocess — so the test body itself cannot stall for minutes, and the
  varying stop point argues against a single hanging assertion.

  It is not the wrapper ceiling either: the gate now has 2400s and the whole
  job finished in 19 minutes. The shape that fits is resource exhaustion — a
  long silence with no output followed by death, on a runner with a fraction of
  the dev machine's RAM. §1 already records a stranded helper ballooning past
  100 GB of RSS here, so unbounded growth is a known hazard in this suite
  rather than a novel guess. One concrete thing to rule out first: the
  `bin/protoc` parent walk in `discoverProtoc` loops on
  `deletingLastPathComponent()` and exits only when the path stops changing,
  which is a convergence assumption about Foundation URL behavior that has
  never been exercised against a CI runner's `NSTemporaryDirectory()`. Sample
  RSS during the gate before changing anything.

  **Update (PR #1 review pass, below):** that parent walk was in fact
  non-terminating for a relative `workingDirectory` and has been bounded. That
  is a real defect, but it is not confirmed to be *this* failure — see the
  macOS entry in the review-pass section.

Also raised: the CI serial-gate steps now run with
`SWIFT_SAFE_TIMEOUT_SECONDS=2400`. The first macOS run to reach the suite was
killed at exactly the wrapper's 600s default and read as a test failure. The
cost is that a real hang now takes 40 minutes to surface.

### PR #1 review pass (2026-08-11) — automated-review findings

Sixteen findings from the PR's automated reviewer were worked. Everything below
landed with a regression test asserting through the seam the defect actually
used, not against composition types.

**Crash-on-input (both were process death, not tool errors):**

- `reference_to_video` / `image_to_video` `duration`: `UInt32(someInt64)` traps
  above `UInt32.max`, so `duration: 4294967296` killed the agent. Parsing now
  goes through a three-case `VideoDurationArgument` (`absent` / `seconds` /
  `malformed`) using `UInt32(exactly:)`.
- `OPENGROK_SUBAGENT_TIMEOUT_MS`: `Double("1e309")` is `.infinity` and passed
  the `> 0` check, then trapped in `Int(timeout.rounded(.down))` before the
  child launched. Now requires finite and `<= 86_400s`, else the default.

**Silent-default (the §3 shape):** a malformed `duration` — negative,
nonnumeric, or a `Double`/`UInt64` the old parser did not match — returned
`nil`, which validation reads as *omitted*, so a billable generation ran at the
six-second default. Malformed and absent are now distinct.

**Path traversal:** `task_id` is decoder-supported but not advertised, so
nothing constrained it, and the Antigravity runner joined it into
`$OPENGROK_HOME/sessions/<session>/subagents/<childID>` before
`createDirectory` and `agy --log-file`. `spawn` now rejects any id that is not
a safe single path component (`isSafeSubagentChildID`, same alphabet as
`LiveConversationStore.validateSessionID`). Rejected, not sanitized.

**ACP reverse permission bridge — five fail-open holes, all closed by
tightening:**

- `.read` / `.grep` / `.webSearch` returned an unconditional `.allow` from the
  prompter. `PermissionHandle` already allows safe access itself
  (`PermissionManager.swift:355-363`); anything reaching the prompter got there
  because a policy *forced* the ask, or because `requestExitPlanApproval` asks
  under `.read(nil)`. Both were silently auto-approved. Now they prompt.
- `allow-always` grants lived on the shared prompter, so a grant by one ACP
  session authorized every later session. Grants are now keyed by
  `AcpSessionId`.
- `x.ai/permissions/reset` reset only `PermissionHandle`. The prompter's own
  grants survived, so the advertised reset did not revoke what the client had
  just granted. The handler now clears both.
- `reject-always` for bash ("No, and don't run bash commands") behaved as
  `reject-once`; the next bash request re-prompted and could be approved. It is
  now recorded and outranks a later allow.
- `allow all edits during this session` authorized *protected* targets —
  `.opengrok` hooks/config, SSH keys, shell startup files, `/etc` — which
  `PermissionHandle` deliberately withholds from session grants
  (`PermissionManager.swift:337-352, :365`). The prompter now applies
  `protectedEditPath` before honoring its own grant.

**Cancellation, two places:**

- A `session/cancel` during an outstanding permission request was caught by a
  generic `catch` and converted to `.reject`, recording a false PermissionDenied
  audit event and firing deny hooks for an operation the user merely cancelled.
  Cancellation now returns `.cancelled`, which is still not allow.
- An Antigravity child did not inherit cancellation: `Task.detached(…).value`
  is not a cancellation point for a nonthrowing task, so `kill_task` and
  session teardown reported cancelled while `agy
  --dangerously-skip-permissions` kept mutating the workspace until it exited
  on its own. `AntigravityProcessCanceller` now bridges
  `withTaskCancellationHandler` to `terminate()` with a 2s SIGKILL escalation.

**Concurrency (ACP session attribution).** `bindSession` was one actor slot set
per turn, so with overlapping `session/prompt` requests the later bind won for
both and a permission request could be shown under the wrong session — user
action displayed for session B authorizing session A. The turn's session now
rides a `@TaskLocal` through structured concurrency into the tool call, with a
begin/end refcount as the fallback for any dispatch that loses the task-local.
**Deliberate divergence:** when the task-local is absent *and* several sessions
have turns in flight, the request is refused as ambiguous rather than
attributed by guess. Upstream threads the session through the request instead;
`PermissionPrompter.prompt` here carries no session parameter. Cost: a client
running genuinely concurrent prompts on a dispatch path that loses the
task-local gets denials instead of prompts. That is the fail-closed direction,
and it is testable (`ambiguousSessionFailsClosed`).

**Reachability:** `spawn_subagent`'s description enumerated only
`LiveModelCatalogResolver.catalog()` and told the model it **MUST** use only
those slugs, while `spawn` accepted `antigravity:*` — so the Antigravity
bypass this PR added was unreachable through the ordinary model-driven path.
The description now names the `antigravity:<model>` form when the feature is
enabled and the CLI is installed. **Deliberately not** enumerating the roster:
that needs `agy models`, a 15s-timeout subprocess, and this description is
built during session construction.

**Windows:** the Antigravity runner sent every bare name and every
backslash-only path to `/usr/bin/env`, which does not exist on Windows, so the
feature could not launch there even with `agy.exe` on `PATH`. Launch now
resolves through `resolveExecutablePath` (PATH + `PATHEXT`) first and keeps
`/usr/bin/env` as the POSIX fallback only. Untested on a real Windows runner —
that job still does not compile.

**macOS gate — changed, NOT diagnosed.** `discoverProtoc`'s parent walk exited
only when `deletingLastPathComponent()` reached a fixed point, which never
happens for a *relative* URL: it keeps prepending `..`, so the loop spins
building longer paths and stat-ing each. `URL(fileURLWithPath: "")` is exactly
that URL, and an empty `NSTemporaryDirectory()` produces it. The walk now
standardizes to an absolute path first and carries a 256-iteration bound, with
a termination test (`defaultProtoCompilerRelativeWorkingDirectoryTerminates`).

This fits the evidence — three of three runs died in
`DefaultProtoCompiler falls back to PATH lookup`, the first test in that file to
exhaust the walk instead of breaking early — but it is **not confirmed as the
cause**. It did not reproduce on Linux: that suite runs 56 tests in 0.043s with
no measurable RSS growth. The RSS sample §1 asked for was taken on Linux only;
no macOS host was available to this pass. If the macOS gate still dies at the
same test, this fix was not it.

**Linux gate — the hang, found and fixed.** The Linux job did not fail, it
stopped: 2130 seconds of silence, then the wrapper's ceiling (exit 124). It
reproduces in isolation in about fifteen seconds under
`--filter PullDiagnosticsTests`, so it was never load-dependent — Linux had
simply never run far enough to reach these tests. `LSPStdioClient.close()`
parked forever on the child's termination: `terminate()` returned, the child
survived, and `terminationHandler` never fired. Two further hang paths in the
same file were found while tracing it — a response race that dropped the reply
(the pending continuation was stored *after* the write, by a separate task),
and a timeout that could not fire because it was a task-group sibling and the
group could not tear down around a non-cancellable child. All three are fixed;
`--filter "PullDiagnosticsTests|SyncDiagnostics|LSPConfigTests"` reports 11
tests in 3 suites passing in 8.1s. **Pre-existing on `main`**, exposed rather
than caused by this PR.

**Windows divergence (2026-08-11, deliberate): no suspend/resume
notifications.** `OpenGrokSystemPower` called
`PowerRegisterSuspendResumeNotification`,
`PowerUnregisterSuspendResumeNotification`,
`DEVICE_NOTIFY_SUBSCRIBE_PARAMETERS` and `DEVICE_NOTIFY_CALLBACK`, which live
in `powrprof.h` and are not re-exported by Swift's WinSDK overlay — so the
module could not compile and the Windows job died there on every push. Since
no Windows binary has ever existed, that code has never run. `startListener`
now returns `nil` on Windows, which is what
`SystemPowerNotifications.start` already documents as "no power notifications,
degrade gracefully", so no caller needs a Windows branch. **Cost: Windows gets
no willSleep/didWake callbacks and anything keyed to sleep transitions is inert
there.** Power *leases* still work; `SetThreadExecutionState` is in
`winbase.h` and compiles. Restoring the notifications needs a C shim target
including `<powrprof.h>` and linking `PowrProf.lib`, the same shape as
`OpenGrokPTYC`.

**Verified CI state after this pass** (run
[31524927247](https://github.com/mweinbach/swift-open-grok/actions/runs/31524927247),
head `2eee3bd`, 2026-08-11):

| Job | Before this pass | After |
| --- | --- | --- |
| Linux | exit **124** — 2130s silent, killed at the wrapper ceiling, no suite result at all | exit **1** — full suite runs, **5,832 tests in 935 suites in 333.8s, 28 issues** |
| macOS | exit 1, died in `DefaultProtoCompiler falls back to PATH lookup` (3 of 3 runs) | exit 1, that test now **passes in 0.017s**; dies later, in `OpenGrok executable parity composition` |
| Windows | 4 `cannot find … in scope` in `OpenGrokSystemPower` | that module compiles; next module `OpenGrokPTY` fails (run [31526565339](https://github.com/mweinbach/swift-open-grok/actions/runs/31526565339)) |

**The Windows tail regenerates, and this pass stops chasing it.** Removing the
`powrprof.h` calls advanced the job by exactly one module: `OpenGrokPTY` now
fails with ~10 `NSLock.lock()/unlock()` "unavailable from asynchronous
contexts" errors plus a `Bool`/`Int` mismatch. That is the same class already
fixed once in this PR for `OpenGrokTTY`, recurring in a module the compiler
had never reached. None of it is caused by this PR's changes; it is a
pre-existing backlog that only becomes visible one module at a time, and each
attempt costs a full CI round trip because nothing local can type-check the
Windows configuration. Fixing `OpenGrokPTY` is mechanical and probably worth
doing — but expect the module after it, and do not treat "Windows compiles"
as near.

Linux going from *no signal* to *a complete suite result in five and a half
minutes* is the single largest change here. Its 28 remaining issues are
pre-existing and none are in code this PR touched: 14 are
`OpenGrokSQLiteJournal` reporting "SQLite3 module not available" in the
`swift:6.3.3-jammy` container, 4 are voice capability on a machine with no
capture device, and the rest are the dashboard, auto-update, welcome-banner,
agents-config, pager-docs and security-release-gate suites. They were
invisible before only because the suite never finished.

**macOS is NOT fixed, and the proto change is not confirmed as its cause.**
The named suspect was real and its test now passes, but the job still exits 1
— now inside `OpenGrok executable parity composition`, on
`live composition applies agent profiles with CLI model precedence`, a test
that stands up the whole live application. Same signature as before: silence,
then exit 1, no assertion and no signal name. That suite is expensive on Linux
too (a 92-second gap in the same place) but does not die there, so the Linux
reproduction technique that cracked the LSP hang does not apply, and no macOS
host was available to this pass. Recorded as open rather than guessed at.

The new stop point is at least **reproducible**: runs 31524927247 and
31527210106 both die on that same test, having both passed the proto tests
that previously killed them. Whoever picks this up on a macOS host has a
named test to attach to rather than a nine-minute silence to bisect.

**Not acted on, surfaced instead:** the reviewer's request to remove
`options: --privileged` from the Linux PR job, and its request to restore the
600s suite ceiling. Both are `.github/workflows/ci.yml` changes whose current
values were chosen deliberately in this PR with their costs recorded in-file;
changing CI config to satisfy a review comment is out of scope for this pass.
The `--privileged` point is a real supply-chain observation about
`pull_request` builds and belongs to whoever owns the runner policy.

### Still deferred from the audit

**Superseded wording note (2026-08-11 local correctness wave):** current deferred
list lives under **Local correctness wave → Still deferred from the audit**.
Updated from the obsolete "macOS proto-test hang" phrasing: durable
cross-process subagent resume, relocation journal, portable WSS/custom CA, the
Windows WinSock loopback server, the reproducible macOS live-composition CI stop
(`OpenGrok executable parity composition` /
`live composition applies agent profiles with CLI model precedence`), and the
Antigravity follow-ons listed above.

## Wave 19 — Deferred parity follow-ons (2026-08-10, complete)

**Scope.** Re-audited the named Wave 18 deferrals against pinned Rust commit
`650c1db7` and implemented every behavior that had a safe live seam, then used the
same GPT-5.6 Sol batch to rank fifty additional gaps and land seven independent
buildable-now slices. The audit artifact is
`.opengrok/swarm-handoffs/deferred-audit.md`.

### Dashboard dispatch and retained rows

The dashboard now keeps live session handles instead of rebuilding tabs on every
selection, so a selected session can accept a new prompt or a reply and can be left
and restored without losing its active controller. This follows the upstream
dispatch/new-session split (`app/dispatch/dashboard.rs:1130,1179,1191`). `/cd`, typed
`SetWorkingDir`, and Ctrl+L location selection converge on the same validated
working-directory mutation (`slash/commands/cd.rs:1,37,44` and
`app/dispatch/dashboard.rs:779,888`); Ctrl+R provides inline rename
(`app/dispatch/dashboard.rs:1852`); Ctrl+W routes through the real worktree launch
path (`app/dispatch/dashboard.rs:594,682,972,1179`); and Ctrl+/ is the distinct
dashboard search mode while literal `/` remains prompt editing
(`views/dashboard/state.rs:442,1635,3527,3661`).

Subagent rows now paint live status and output, support peek, and attach when the
child has a persisted/resumable session; a still-running child refuses attach
because the Swift child runner does not yet own a durable session record. Reply and
single/freeform question resolution are live (`app/dispatch/dashboard.rs:1741,1764,
1807,2519`); multiselect stays in the attached session view rather than fabricating
dashboard semantics. The prior "wide-layout side-panel peek" deferral is retired:
the pinned Rust dashboard uses vertical layout only (`views/dashboard/layout.rs:223`).

### Typed leader bridge

`OpenGrokACPRuntime` now defines the typed `x.ai/sessions/list` snapshot and
`x.ai/sessions/changed` lifecycle delta, publishes input/working/idle state changes,
fans them out only over leader IPC, and exposes a client stream. Interactive leader
mode starts directly in the dashboard, preserves remote activity states, applies
snapshot/delta repaint, and resumes the selected remote session in its recorded
working directory. This ports the roster protocol and lifecycle shapes from
`xai-grok-shell/src/agent/roster.rs:1,20,43,52,79,85,94` and the leader fanout from
`xai-grok-shell/src/leader/server.rs:391,6277`. Windows named-pipe leader transport
remains open; this wave does not weaken the Windows refusal.

### Broader audited closures

- **Settings/profile honesty:** live settings hide Antigravity and capability-gated
  voice rows; auto / dream / LSP / `image_to_video` are live as of the deferred
  runtime wave (voice still capability-gated). Built-in profiles still omit
  `reference_to_video` until reference artifacts exist. Rust anchors include
  `voice/mod.rs:10-16,30-33`, `permission/auto_mode.rs:301-312`,
  `memory/src/dream.rs:32-40,114`, `agent_ops.rs:4474-4504`, and
  `builder.rs:2243-2261`.
- **MCP OAuth recovery/revoke:** the browser flow polls the owner-only credential
  file inside the callback timeout, a recovered credential re-probes and registers
  the live client, and delete performs best-effort RFC 7009 revoke followed by
  authoritative local deletion and live teardown (`extensions/mcp/oauth.rs:27-37,
  387-485`; `credentials.rs:291-300,392-406`). Scope-upgrade consent remains open.
- **Recap budget:** over-budget recap input now deterministically applies the
  500k-window, 85% threshold, and 4k headroom; strips reasoning/tool tails first;
  preserves the newest suffix; and marks a truncated retained item
  (`session/helpers/session_recap.rs:93-164`,
  `xai-chat-state/src/compaction_utils.rs:206-390`). Remote-settings and automatic
  watermark scheduling remain separate work.
- **Windows command lookup:** production shell resolution now honors PATHEXT order
  and executable suffixes (`xai-grok-config/src/shell.rs:230,239,521`). Windows host
  execution and COMSPEC/CreateProcess quoting still need platform evidence.
- **Packed Git phase 1:** pack index v2 lookup, bounded non-delta inflate, checksum,
  OID, and object-size validation are live; OFS_DELTA/REF_DELTA objects refuse with a
  typed error rather than misreading data. Upstream delegates the complete behavior
  to gix (`xai-fast-worktree/src/git/status.rs:31,57-59`).
- **Docs helpers:** how-to lookup and versioned atomic user-guide extraction now exist
  (`xai-grok-pager/src/docs.rs:48,171,192,208,227,241`). Startup auto-extraction is
  intentionally still open until the helper has a production lifecycle owner.

### Verification snapshot

| Command / proof | Outcome |
|---|---|
| Dashboard follow-on focused suites | Exit 0; 62 tests. |
| Leader roster/protocol/composition focused suites | Exit 0; 31 tests, plus the post-integration stdio/wire/live-host regressions. |
| MCP OAuth/revoke focused suites | Exit 0; 21 + 13 + 4 tests. |
| Git pack / Windows PATHEXT / docs helper focused suites | Exit 0; 28 / 6 / 4 + 17 tests. |
| `zsh workflows/swift-safe-verify.zsh build-tests` | Exit 0. |
| `zsh workflows/swift-safe-verify.zsh test --no-parallel` | **Exit 0**; 4,982 Swift Testing cases across 73 nonempty summaries; 105 XCTest harness launches, zero legacy XCTest cases; zero issues. |
| `zsh workflows/swift-safe-verify.zsh build --product open-grok` | Exit 0. |
| `control-open-grok` baseline map | All version, paths, help, models, and empty-session entry points passed against `/tmp/open-grok-verify-20260810-161948-49821`; the unknown-help negative control exited 2 as expected, evidence was retained, and the isolated home was removed. |

## Wave 15 — Slash-command parity batch (2026-08-07, in progress)

**Scope.** The remaining upstream slash commands with live backings, audited from the Rust
side and landed in dependency order: D1 `/login` + `/logout` (this entry), D2 `/plan` +
`/view-plan`, D3 `/fork` + `/tasks` (pending).

### D1 — in-pager `/login` and `/logout` (serial gate: exit 0, 4,377 tests, zero issues)

`/login` opens upstream's 8-provider picker (order, display copy, and the full alias table
verbatim from `login.rs:30-101`) with live secret statuses read fresh at open
(env override → stored → missing, `dispatch/settings/ui.rs:37-48`); `/login codex` runs the
browser OAuth flow non-blocking against the real callback listener and refreshes the model
catalog on success (`effects/mod.rs:1690-1699`) so Codex rows appear in `/model`; `/logout`
and `/logout codex` delete the real credential stores under their file locks (xAI scope +
API-key scope via `AuthManager.clear()`; codex via best-effort revoke then store removal)
with upstream's completion copy and an added env-key warning. 19 new tests: 11
controller-seam (registry/dispatch/alias/error-copy/completion pins) and 8 live-seam
(painted picker round-trip, real-listener codex flow, single-flight guard, all four logout
outcomes on real store files in isolated homes).

**Lead fix after delegate handoff:** the delegate's never-run paint test caught its own
unit's §3 trap — picker statuses rode `PagerListRow.summary`, which the list painter never
draws (`summary` is filter-haystack only; `detail` is the painted right-aligned channel).
Statuses were computed and invisible. Fixed by routing through `detail`; the one-shot
single-flight counter read was also converted to a bounded poll (it flaked at 0 under
parallel-suite load before the spawned flow's first statement ran).

**Recorded divergences:**

- `/login xai` prints an honest CLI-route notice instead of upstream's in-TUI xAI OAuth
  flow (`dispatch/auth.rs:668-706`); the only wired xAI sign-in is the CLI API-key route.
  Cost: no in-TUI xAI sign-in until the OIDC browser flow is wired at this seam.
- API-key providers deep-link the settings modal at the provider's key row instead of
  upstream's dedicated `Open*ApiKeyEditor` modals. Same save path and scopes; cost is the
  extra visual context of the full settings list.
- Codex login is single-flight behind an explicit guard with a notice; upstream's only
  guard is the port-bind fallback ladder (`codex_auth.rs:706-714`).
- The auth URL prints into the transcript with upstream's CLI announce copy
  (`codex_auth.rs:823-824`); upstream's raw-terminal TUI shows no URL at all.
- `/logout` is local store deletion, not upstream's ACP revocation + tab teardown
  (`effects/mod.rs:1657-1678`). Cost worth knowing: the running session's in-memory
  credential survives until restart or a new session.

**Known limitations, deliberate:** an abandoned `/login codex` flow has no cancellation
plumbing — the listener thread blocks until its 600 s timeout (the CLI route shares this),
and `restoreTerminal` does not cancel the pending task. Separately noted render gap:
`PagerListRow.summary` is documented as upstream's indented sub-line (`picker.rs:900`) but
no painter draws it anywhere — any future row description needs `detail` or a painter fix.

### D2 — `/plan` and `/view-plan` (serial gate: exit 0, 4,392 tests, zero issues)

Bare `/plan` arms the live plan gate through the SAME `PermissionPipeline.enterPlanMode`
seam the `enter_plan_mode` tool uses (no controller-side mirror; the already-in-plan check
reads `permissionPipeline.planModeActive`); `/plan <description>` preserves upstream's
`SetModeThenPrompt` ordering (`dispatch/modes.rs:31-36`) — the renderer's arm completes
inside `emit` before the returned `.submit` enqueues the description, so the description's
turn cannot start with the gate disarmed; `/view-plan` (aliases `show-plan`, `plan-view`)
reopens a pending `exit_plan_mode` approval or previews the tracker-resolved on-disk plan,
with upstream's "No plan written yet." copy for the empty case. 15 new tests: 9
controller-seam (registry/alias/dispatch/ordering pins) and 6 live-seam (the arm observed
by real tool dispatch via a plan-gated write probe, idempotence after a real tool arm,
painted preview of a real plan file, no-plan note, approval reopen).

**Lead fix after delegate handoff:** the slash arm's nil-pipeline path was silent —
`armPlanMode()` no-opped and the caller still noted "✓ Plan mode: on", a false success
report on a permission control (this file's own convention, `gateKillTask` /
`gateTerminalCommand`, is explicit refusal when the pipeline is missing). `armPlanMode()`
is now status-returning and the slash path refuses with "No active session" when the arm
has nowhere to land. Residual, recorded: on the description form in that same partial
construction the controller still submits the prompt after the refusal note (stopping it
needs a status channel through `emit`; the interactive composition always has a pipeline).

**Recorded divergences:**

- Preview is a read-only scrollable text modal titled `plan.md`, not upstream's fullscreen
  line viewer with commenting and action buttons (`agent_view/plan.rs:125-167`). Cost: no
  plan commenting from the preview.
- Plan body precedence: no `latest_inline_plan_content` channel (`plan.rs:93-112`) —
  approval content serves the reopen branch, disk otherwise. A plan not yet flushed to
  disk shows "No plan written yet."
- Plan file location: the tracker's resolved path (`<workspace>/.opengrok/plan.md`), not
  upstream's `<grok home>/sessions/<urlencoded_cwd>/<session_id>/plan.md` (`plan.rs:29-41`)
  — reused deliberately so `/view-plan` and the plan-file auto-approval gate name one file.
- The description form prints "✓ Plan mode: on" where upstream shows a persistent plan
  chip instead of a toast; the port has no chip (roadmap: status-bar surface).
- Shared-parser whitespace collapse in the description (precedent: `/remember`, `/btw`);
  `SetPlanMode(Off)` and the dashboard/session-less offering have no port surface.

### D3 — `/fork` and `/tasks` (serial gate: exit 0, 4,434 tests, zero issues, ~225 s)

`/fork` ports `parse_fork_args` verbatim (`fork.rs:50-96`, byte-identical error copy:
mutual exclusion, duplicate flags, the `--at` deferral, unknown-flags-start-the-directive)
and performs a REAL on-disk fork of the current session through the same
`LiveConversationStore.fork` the CLI `--fork-session` route uses (id validation,
legacy-boundary refusal, items + rewind-sidecar copy, `parentSessionID`); the note names
both open routes. `/tasks` paints the `tasks_block_text` port (`status_blocks.rs:48-178`)
fed by the live workflow registry, subagent host, and shell task list. 42 new tests
(25 controller-seam, 17 live-seam/formatter). Recorded divergences: fork spawns no peer
tab (single-session port; one extra step to open the fork), `--worktree` and the directive
form refuse honestly (no backing that both forks and isolates; no pending-prompt field in
the session record — refusing beats silently dropping user text), no scheduled/Monitor/
"stopping" rows (no `/loop`, no monitor tool, no `pending_kill` flag), workflow durations
derived from the journal (no stored end time), `/fork` dispatch reads the raw argument
tail so the whitespace-sensitive grammar sees arguments as typed.

**Product bug found by this unit's live-seam test — walk-up infinite loop (the 128 GB
incident).** `projectAgentDirectories(cwd:)` (and the sibling `agentsFiles` walk) guarded
its ancestor loop with `parent.path == current.path`. The parent of `/` depends on URL
flavor: `URL(fileURLWithPath:)` repeats `/` (terminates), but URLs built by chained
`appendingPathComponent` (NSURL-bridged) grow `/..` forever — the loop never breaks and
each iteration percent-decodes an ever-longer path. The D3 subagent-host test passed a
chained-flavor cwd and `LiveSubagentHost.init` spun unbounded, ballooning the test runner
past 100 GB RSS (sampled stacks pinned the loop at `OpenGrokSubagentResolution.swift:1408`
inside `_xzm_malloc_large_huge`). The live app dodges it only because its cwd happens to
be `fileURLWithPath`-flavored — a reachability argument, not a guarantee. Fixed with a
strictly-shorter-parent guard at the three URL-parameter walk sites
(`projectAgentDirectories`, `agentsFiles`, `Config.projectDirChain` — the last was
depth-bounded but emitted junk `/..` entries); audited the remaining walk-up loops:
`SkillDiscovery` standardizes each parent (`/..` collapses back to `/`, terminates),
`FastWorktree.rejectSymlinkEscape` loops on `path != "/"` (reached), and the
FSNotify/GitStatus walks build their URLs internally from String paths (terminating
flavor by construction).

**Lead fixes to the delegate's tests:** the capturing sink decoded frame bytes one
scalar per byte, mangling every multi-byte glyph ("·" → "Â·") so the
"Task · long sleeper" needle missed a frame that contained it — now byte-level ANSI strip
then UTF-8 decode; the fixture's 1 ms paint cadence let a 30-second running-task
animation accumulate frames at >100 MB/s into the sink — now 10 fps; the sink carries a
compact `customMirror` so a failed `#expect` can never again dump the whole byte buffer
as decimal text.

**Verification-infrastructure hardening (same incident):** `swift-safe-verify.zsh`'s
wall-clock ceiling default dropped 900 s → 600 s (a healthy build or suite finishes well
inside 10 minutes; AGENTS.md §1 now says so), and the ceiling/trap kills now target the
command's process group via a `setpgrp` re-exec — a pid-only kill stranded
`swiftpm-testing-helper`, and the stranded helper is what ran the wedged suite to 100+ GB
unnoticed. Kill path proven live: a 60 s ceiling tripped mid-suite exited 124 with no
surviving helper.

### E1 — `/docs` with the How-to Guides corpus (serial gate: exit 0, 4,459 tests, zero issues)

`/docs` (aliases `howto`, `guides`) ports `DocsCommand` verbatim (`docs.rs:70-102`): bare
or a how-to token opens the in-TUI guides browser, a web token opens
`https://docs.x.ai/build/overview` through the same injected opener seam the codex login
uses, a guide title opens that guide's markdown viewer, and unknown targets get the
byte-exact error (including Rust's `{:?}` quoting for the ASCII range). The 26-guide
corpus (24 user-guide files + 2 reference docs, **456,088 bytes**) lives as generated
Swift source — NOT SwiftPM resources, which silently break under
`swiftpm-testing-helper` (AGENTS.md §2). Most entries remain mechanically emitted from
the reference clone; `03-keyboard-shortcuts.md` and `23-dashboard.md` are explicitly
port-maintained so the shipped guides describe the controls that actually work instead
of advertising deferred upstream surfaces. The suite pins every per-file byte count and
semantically prevents deferred dashboard controls from leaking into the live table or
example. Current coverage is **26 tests**: 17 controller/corpus tests + 9 live-renderer
reachability tests.

**Parity bug found during lead review — completion tie-break inverted.** The registry's
final sort key compared CANONICAL command names where upstream compares the MATCHED
trigger's display text (`slash/mod.rs:1003` via `registry.rs:76` — an alias row is
"/howto", "/m"). The moment `/docs` gained its `howto` alias, a tied `/h` query ranked
`/docs` above `/help` — upstream never does. Fixed in
`OpenGrokPagerCommandUI.completions` (matched-trigger text ascending); two stale pins in
`OpenGrokPagerCommandUITests` that encoded the buggy order were corrected to upstream's
(`/m` → model-via-alias before memory; accepting an unavailable row returns nil).

**Recorded divergences:** no `arg_placeholder` channel (shared with `/plan`, `/fork`);
`{:?}` quoting exact for ASCII, not `escape_debug`'s exotic ranges; Esc closes the doc
viewer outright (no upstream DocViewer→DocPicker modal shuttle); the opener is
fire-and-forget (no `BrowserUnavailable` detection or OSC-52 clipboard leg — a
composition with no opener paints the manual-URL fallback); label truncation in the
narrower port sheet follows upstream's own label-yields-to-right-label rule
(`picker.rs:1017-1023`) but bites sooner. Deliberately not built: `extract_user_guide_docs`
(startup extraction for model consumption) and the model-facing `get_howto_doc` helpers —
implemented-unwired surface until a consumer exists.

### Slash-command surface: the audited remainder (2026-08-07 survey)

A read-only survey classified every still-missing upstream command against live port
backings. BUILDABLE-NOW: `/announcements show` (the hide arm is live; the surface lacks
only an unhide API) and `/imagine` (inject-skill prompt; `imagineInstruction` and the
live image tool pack exist — gate on `imageGenEnabled`). Everything else is SKIP-ABSENT
until its backing feature lands, each verified at the dispatch layer: `/edit-prompt`
(upstream itself is minimal-mode-only — `external_editor.rs:10-13` returns early in
fullscreen and `dispatch/tests/router.rs:65-70` pins the refusal; a fullscreen-only port
registering it would be a dead surface), `/fast` (no live per-session service-tier
override; the wire types in `ServiceTier.swift` are implemented-unwired), `/auto` (no
LLM classifier; the live permission toggle is deliberately ask↔always-approve only),
`/swarm` (`agent_swarm` deliberately unwired in `LiveSubagentHost`), `/recap` (needs a
real `x.ai/recap` aux side-call rendered to scrollback; the port's `/btw` interjection
buffer is the wrong seam), `/hooks`/`/plugins`/`/marketplace`/`/skills` (the Extensions
modal doesn't exist; `openExtensions` is inert), `/doctor` (~9.2k-line diagnostics probe
and fix stack absent; the CLI route is an honest stub), `/scroll-debug`/`/debug` (no
debug HUDs). These unlock bottom-up as the backing features land.

### E2 — `/announcements show` + `/imagine` (serial gate: exit 0, 4,476 tests, zero issues; 2026-08-08)

The survey's two BUILDABLE-NOW commands. `/announcements` now carries upstream's full
"hide | show" surface (`announcements.rs:12-62`): `show` clears the session's hide keys
from the REAL persisted store (skipping the write when nothing changed, mirroring
`router.rs:991-1005`) and the banner repaints; the old hide arm's mislabeled
last-announcement notice was fixed in passing (it keyed off `hideCurrent()`'s next-banner
return and reported "no announcement to hide" when hiding the final one). `/imagine`
registers ONLY when `image_gen` is in the session's advertised toolset — the gate reads
the model-facing tool list, so it inherits credential failures and profile filters, not
just the config flag — and expands into `imagineInstruction(prompt)` (byte-identical to
`slash_commands.rs:98-125`, pinned as literals) submitted as the turn's prompt through a
new `.notice`/`.submit` local-command outcome. 17 new tests.

**Recorded divergences:** registration gates at surface-existence rather than upstream's
`has_session_announcements` (the registry is fixed before the detached feed fetch lands;
an empty-feed session lists the row and both arms answer honestly); the port notices on
hide/show success where upstream is silent; `/announcements`' bare submit gets the usage
error instead of parking in the argument phase (`requiresArguments` derives from `<`
markers; "hide | show" has none); no argument-suggestion or placeholder channel (the
standing `/docs`/`/fork` divergence); `/imagine`'s transcript paints the expanded
instruction, not upstream's `"/imagine {prompt}"` echo (typed text is preserved in prompt
history); conditionally-registered local commands list after the builtins, in upstream's
relative order. `/imagine-video` stays unregistered — no video tool pack exists.

### E3 — Fast service tier live + `/fast` (serial gate: exit 0, 4,497 tests, zero issues; 2026-08-08)

The first backing-feature slice: the Fast (priority routing) tier now travels catalog →
session sampling config → both wire backends. `ModelInfo.serviceTiers` parses from Codex
wire catalogs (incl. legacy `additional_speed_tiers`) and the Fireworks curated builder
(`fireworks_models.rs:167-171`); the donor merge inherits tiers on remote refresh; the
chat-completions wire type gained its missing `service_tier` field and the Responses body
emits only concrete tiers (standard routing is the ABSENCE of the field);
Kimi/DeepSeek/OpenCodeGo/Wafer strip it, Fireworks forwards (`provider.rs` pins). The
`/model` switch path carries a `String??` tier with upstream's preserve/clear/set
semantics and validates it against the target entry; `/fast` toggles through that same
switch path (effort preserved — `nil` would re-resolve the catalog default and drop an
`/effort` override), with upstream's copy byte-exact ("No active model", "current model
does not support Fast mode", "Fast mode enabled/disabled", the " · Fast" switch marker).

**Brief-error caught by the delegate, verified by the lead:** the lead's brief claimed
upstream pins compaction to `service_tier: None` (a misread of `sampler_turn.rs:757`, the
no-config fallback). Upstream does the opposite — both Codex compact retain-lists keep
`service_tier` (`client.rs:683,712`) and upstream's own test pins `"priority"` surviving
in the compact body (`client.rs:3827-3858`). The port carries the tier on compaction, and
the requested "compaction never carries it" test was deliberately NOT written. What
upstream does pin to None: aux samplers and subagents.

**Lead fixes to the delegate's tests:** two wire tests resolved models through the
embedded default catalog, whose entries carry NO tiers — upstream's embedded defaults
are identical (config.rs builds them with empty tier lists; tiered curated entries
arrive only via the Fireworks provider-catalog refresh). The fixtures now model the
post-refresh catalog (curated partition pinned at the mock's base URL), and
`LiveModelCatalogStore` gained an `applyFireworksCatalog` pass-through (mirroring the
OpenCodeGo seam; the manager's fingerprint gate still applies) so hermetic compositions
can publish a provider catalog without network.

**Recorded divergences:** `/fast` registers always (fixed registry) with upstream's error
copy at dispatch instead of upstream's dynamic `visible()`; tier-only toggle copy is
upstream's byte-exact but the base "Switched to X" shape keeps the port's pre-existing
divergence; Fireworks curated reasoning-efforts assignment (`fireworks_models.rs:164-166`)
not ported *(label corrected at the 2026-08-08 re-pin: this is NOT pre-existing — the
assignment IS the `.58` delta this entry was unknowingly citing; closed by R1 in the
re-pin wave)*; `default_service_tier` parsed and deliberately
never auto-applied. **Deliberately unfinished:** resume does not restore a persisted tier
— the port's resume path restores neither model nor effort into the live coordinator
today, so the tier follows that pre-existing gap; out of the box only Fireworks curated
models are fast-capable (Codex tiers go live when the remote catalog carries
`service_tiers`).

### E4 — `/recap` on a real one-shot side-call (serial gate: exit 0, 4,528 tests, zero issues; 2026-08-08)

`/recap` (alias `/summarize`) samples a READ-ONLY snapshot: the session's conversation
prefix verbatim (reasoning stripped, trailing tool-run popped for a clean boundary) plus
upstream's instruction turn — machine-extracted from `session_recap.rs:38-59` and pinned
by SHA-256 so drift fails the suite — resolved through upstream's model-choice policy
(explicit `models.recap` → Codex-only Automatic economical pick → active route), tidied
(upstream's own tidy tests ported) and painted as "Recap — {summary}". Failures paint
upstream's unavailable copy and never break the session; the conversation is provably
unmutated (the live test pins the NEXT turn's request body free of recap items). The
`recap_model` settings row's dead storage path was fixed (`models.recap_model` →
`models.recap`, the key upstream persists and `recap_model()` reads) — the "parses,
nothing reads" pair from the roadmap is now closed from both ends. 28 new tests.

**Brief correction, delegate-verified and lead-accepted:** the tier-None claim holds only
for the RESOLVED aux route (`agent/config.rs:6097`); the non-Codex Automatic fallback is
`config = active` and carries the session tier (`sampler_turn.rs:850,1162`). Both
behaviors are pinned live: an explicit recap pin on a Fast session sends no
`service_tier` while surrounding turns carry `"priority"`; the Automatic fallback on a
Fireworks Fast session carries it.

**Recorded divergences:** the side-call goes tool-free (upstream ships the main turn's
tool specs for prefix-cache parity and forbids use through the instruction alone,
`recap.rs:354-358`; the render layer has no reach into the live tool surface — same
choice as the compaction sampler); in-progress paints a "Recap…" note instead of
upstream's in-place spinner block; the over-budget front-trim (`budget_recap_items`) is
not ported (sessions auto-compact at the same 85% threshold; degenerate overflow fails
into the unavailable copy); no remote-settings leg on the `session_recap` gate; no
request artifacts or conv-id stamp. The auto arm (watermark, idle gate) is out of scope
by design. **Flagged for future slices:** `memory_model` and `fork_secondary_model`
settings rows share the dead-storage-path defect fixed here for `recap_model`.

### E5 — true mid-turn interjection (serial gate: exit 0, 4,537 tests, zero issues; 2026-08-08)

Closes Wave 16 item 6. A session-side buffer (`LiveSessionInterjections` actor) drains at
upstream's four points — top of every sampler round (upstream's before-request and
after-tool-results drains are one point here, since the loop re-enters the top after
tools; deliberately BEFORE compaction so injected items count toward the budget), the
pre-completion drain (an interjection during the final round gets one more round), and
the late drain during turn-end bookkeeping — injecting synthetic user items
(`syntheticReason: .interjection`) that persist at turn commit. `/btw` reroutes through
the controller→session seam (the single-process stand-in for `x.ai/interject`): mid-turn
it merges into the running turn with a user-block echo; idle or stranded it becomes an
`interject-fallback-`-prefixed front-of-queue prompt (upstream's
`flush_stranded_interjections` at the completion and `.turnFailed` arms); cancellation
drops the buffer (run_loop.rs:989-991). The old hold-until-next-prompt buffer and its
"Held for the running turn" copy are gone. `formatInterjection` verified drift-free
against upstream's `format_interjection` (byte-length gate, scalar-walk truncation,
identical envelope). 11 tests across three seams (format pins, session-actor wire tests
with a canned tool-round sampler asserting the round-2 items array, live typed `/btw`).

**Brief departure, delegate-verified and lead-re-verified:** the brief asked to reroute
Enter-steers through the seam; upstream's steer is cancel-and-send
(`Action::SendPromptNow`, `agent_view/prompt.rs:616-631`), which the port already
matches (Wave 14 steering honesty) — rerouting would have invented UX upstream lacks.
Upstream's other `Action::Interject` producers (queue force-interject, queued-row
edit-save, plan review comments) have no port surfaces yet; the seam is ready for them.

**Recorded divergences:** `/btw` remains a divergence, upgraded — upstream answers it
off-conversation as a side question in a panel; the port injects into the conversation
(now genuinely mid-turn). Skill expansion at the interjection seam unported. Drained
interjections persist at turn commit, not at injection (a turn cancelled after a drain
loses them with the rest of the turn's items — existing port-wide behavior). Fallback id
is UUIDv4 behind the byte-identical prefix. The leader-client pager installs no seam, so
`/btw` there degrades to the idle fallback. The auth-retry inner loop re-samples without
re-draining.

### E6 — in-TUI xAI browser OAuth (serial gate: exit 0, 4,554 tests, zero issues; 2026-08-08)

Closes the D1 divergence: `/login xai` (and the picker's xAI row) runs the real loopback
flow — discovery → PKCE → CORS-aware callback listener (accept LOOP with the
accounts-app CORS grant, because upstream's consent page delivers the code via
cross-origin fetch; a preflight or favicon probe must not consume a one-shot accept) →
code exchange → the ONE store write via `AuthManager.update` under the auth.json file
lock, with the team pin enforced BEFORE persist and personal logins requiring a
nonce-bound id_token. The authorize URL is byte-pinned parameter-by-parameter against
`protocol.rs:349-393` (lead re-read the upstream builder: order, `urlencoding::encode`
semantics, `%20` spaces — note the deliberate contrast with codex's form encoding —
numeric `127.0.0.1` redirect vs codex's `localhost`, `referrer=grok-build` default). All
copies byte-exact. Post-login: catalog credential refresh + background refresh, `/logout`
round-trip clears exactly what the flow wrote. 25 tests after lead fixes.

**Mid-session credential answer, measured at the live seam:** a running OIDC route keeps
serving the pre-login bearer until the first 401 self-heals it
(`refreshAfterUnauthorized` adopts the disk sibling); a `/model` re-pick resolves fresh
immediately; a session running on an API-key credential (static provider) needs a
re-pick or restart. **Lead fix:** two store assertions substring-matched the scope key
against raw file bytes — the auth encoder escapes forward slashes (`http:\/\/…`), so
they could never match; both now parse the JSON and assert on keys.

**Recorded divergences (security-flagged for a human read):** second `/login xai` refused
with a notice (upstream aborts and restarts the prior attempt); no welcome-screen auth
UI or manual paste channel (remote/SSH users whose browser can't reach 127.0.0.1 cannot
complete the flow); external-auth/devbox/device arms not wired (device is opt-in
upstream; browser-open failure keeps waiting, verified upstream and mirrored);
**id_token accepted without JWKS signature validation** — nonce enforced, PKCE binds the
exchange, and upstream's own comment (protocol.rs:164-172) names server-side
re-validation the boundary, but client-side defense-in-depth is weaker than upstream's;
no `/user` enrichment or managed-config post-login sync (no port surfaces); state/nonce
UUIDv4 vs upstream's v7. The slice also caught its own CRLF trap (AGENTS §2) in the
listener's request parser before landing.

### E7 — MCP OAuth (serial gate: exit 0, 4,594 tests, zero issues; 2026-08-08)

Closes roadmap Wave 15 item 4: an HTTP MCP server requiring OAuth works end-to-end from
the running executable — discovery (SEP-985 + SSRF gates) → dynamic client registration
→ PKCE S256 browser consent against a real loopback listener (GET+POST `/callback`, RFC
9207 `iss`, upstream's HTML) → tokens in `$OPENGROK_HOME/mcp_credentials.json` in
upstream's exact rmcp schema (locked 0600 atomic writes, freshness guard against
refresh-token rollback, corrupt-recovery; the byte-identical Rust legacy fixture
round-trips as a test pin) → session connect attaches `Authorization: Bearer` with a
30 s proactive-refresh buffer and one 401 refresh-retry (token-changed disk check per
upstream's same-stale-token guard) → tools land in the advertised set and `/mcps` shows
the connection. **Brief correction from the delegate:** upstream's implementation
delegates to the external rmcp 2.1 crate (`transport/auth.rs`, 5.6k lines); the port
covers the subset upstream exercises. Triggers: `open-grok mcp login <name>` (the port
stand-in for the `x.ai/mcp/auth_trigger` ext method — recorded new-verb divergence) and
connect-time token attach with an auth-required `/mcps` notice; connect NEVER auto-opens
a browser, matching upstream (the "spawns in background" doc comment upstream is stale —
no such spawn exists in its code). 40 tests across four seams; binary smoke on the built
executable proves the login route live.

**Recorded divergences:** discovery validates the final response URL same-origin instead
of hand-following redirects (cross-origin protection preserved); 401 recovery lives in
the transport, no browser escalation on a failed tool call; non-interactive gate and
callback-wait store poll unported (the failure modes they prevent cannot occur here);
403 scope-upgrade, client-credentials flow, revocation, transient-refresh classification
unported. **Lead posture note:** the MCP store's lock acquisition is `try?` (a lock
failure degrades to unlocked-but-atomic writes) where `AuthManager.update` throws — the
freshness guard bounds the worst-case race; aligning the postures is a one-line future
fix. **Remaining for full parity:** live `/mcps` re-probe after `mcp login` in a running
session (tokens apply next session), scope-upgrade on 403, revocation on server removal,
the ext-method surface.

### E8 — swarm runtime: `agent_swarm` + orchestration wait + `/swarm` (serial gate: exit 0, 4,633 tests, zero issues; 2026-08-08)

Closes roadmap Wave 14 item 5. `agent_swarm` runs real cohorts through the live host's
coordinator and child runner: fail-fast validation ladder (byte-identical error copy),
burst-5/ramp-700ms scheduler with the `OPENGROK_/KIMI_` concurrency env grammar,
per-member 2 h timeout, resume slots pinning prior models, slot-ordered
`<agent_swarm_result>` XML byte-for-byte. Registration strips with the task surface
(builder.rs:848-869) plus the tool's own Task requirement; the parent call is
auto-approved at the gate per upstream's `swarm_parent_auto_approve` (each member's own
calls carry the real permission decisions). The orchestration-wait exemption lands at the
controller's send-now sites: a prompt arriving mid-swarm is promoted WITHOUT cancelling
the turn (`prompt_queue.rs:222-233`); Esc/Ctrl+C still cancel unconditionally, matching
upstream's only `orchestration_depth` consumer. Swarm MODE's entire payload — the
`<system-reminder>` injections (entry steering text, exit notice) at the turn loop's
drain point, exclusive-batch refusal, turn-end auto-exit — gives `ui.swarm_mode` and the
`swarm_mode` settings row their first reader. `/swarm [on|off|task]` registers in
upstream's position with the mode-then-prompt ordering. 40+ tests across five seams.

**Lead fixes after delegate handoff:** (1) resume-map JSON source order — upstream's
serde map preserves insertion order for slot assignment (agent_swarm/mod.rs:977-990),
but the port's `JSONValue.object` is a Dictionary and Foundation's decoder hands keys
back unordered, so order died before the handler; a string-aware, nesting-aware raw-JSON
scanner now recovers the `resume_agent_ids` key order from `call.arguments` at dispatch.
(2) The delegate's steer tests pressed Esc after pasting plain text mid-turn — a bare
Esc with no dropdown IS the interrupt, so the harness was cancelling the very turn the
exemption was supposed to protect; the tests now probe MID-TURN with a trailing `/queue`
snapshot (promoted-but-queued under orchestration; drained after a real preempt).
(3) The missing `/swarm` help-text line; the XML-escaped resume-error needle
(`&apos;`); the two composition pins updated for `agent_swarm` (code-mode direct-only
per `code_mode.rs:77`; headless advertised set).

**Recorded divergences:** no rate-limit adaptive scheduler (a 429 fails the member; no
port rate-limit status channel); `reasoning_effort` validated fail-fast and carried but
not applied to child sampling (the task tool's existing gap — same future slice);
resume-only swarms with an unresolvable subagent_type fail fast; member ids UUIDv4;
no per-tab swarm chip or `SwarmModeChanged` channel (single-session); `ui.swarm_mode`
seeds interactive compositions only; `/swarm <task>` whitespace-collapse (the standing
parser divergence); cancellation returns `.cancelled` rather than dropping the future.

### E9 — collaboration quartet + mailboxes (serial gate: exit 0, 4,647 tests, zero issues; 2026-08-08)

Closes roadmap Wave 14 item 6 — the last subagent-stack item. `list_agents`,
`send_message`, `followup_task`, `wait_agent` (upstream ships all four un-renamed at the
pin; `wait_agent` is the caller's MAILBOX read and is distinct from
`wait_commands_or_subagents`, upstream's completion wait — the roadmap's shorthand
implied a rename that does not exist) ride the coordinator's mailboxes: per-recipient
cap 128, parked-waiter hand-off, FIFO drain ≤20, finished-target refusal with the
byte-exact `task(resume_from=…)` hint. Enablement is the task surface's own gate
(upstream ad95b111 is the LOCK'S TEST, not the gate — `builder.rs:848-877` strips the
quartet with task/agent_swarm/workflow and otherwise pushes it even when unlisted);
children keep the quartet while every spawn surface stays stripped ("spawn tools must
go, mailbox collaboration must remain", `task/types.rs:1407-1434`). Child→running-root
`followup_task` rides the E5 interjection seam wrapped in upstream's byte-exact
`<agent_message>` envelope with the untrusted-input trailer; children drain buffers at
sampler-round boundaries. Result text is byte-exact serde pretty rendering, golden-pinned.

**Lead fix — a live §3 catch:** the delegate's `AgentMailboxBackend` conformance made
the protocol extension's no-backend DEFAULTS (empty roster, backendUnavailable) visible
as overloads on the coordinator, and Swift prefers the nonisolated-async extension
overload over an actor's SYNCHRONOUS member at direct call sites — every direct
`listAgents` call silently returned an empty roster, caught by a pre-existing roster
test the slice's own suite never ran. Fixed by making the concrete signature identical
to the requirement (`async`, no body change); the roster test now also pins the WITNESS
path through the existential. Two smaller test repairs: the delivered-status needle
must match the escaped bytes a tool result embeds in a request-body JSON string, and
both composition pins gained the quartet (code-mode direct-only per
`code_mode.rs:83-86`).

**Recorded divergences:** an idle root does not wake on a peer follow-up (no
host-reachable prompt-queue seam; `status: queued`, read on the next `wait_agent` —
upstream starts a synthetic `agent-message-{id}` turn); the delivery hook is async
(Rust's is a sync channel send) with a post-await waiter re-check closing the
reentrancy window; no client-facing `SubagentMessage` notifications; port profiles can
strip individual quartet tools (upstream cannot); the `WaitAgentMessagesOutput.modelText`
in OpenGrokToolTypes still uses `.sortedKeys` (unused by the live path; flagged);
workflow children are not on the mailbox (upstream's would be); follow-up loss window
at child exit shared with upstream.

### E10 — ACP extension router + credential family with live rebind (serial gate: exit 0, 4,657 tests, zero issues; 2026-08-08)

Closes roadmap Wave 15 items 1-2 and the recorded Wave 12 deferral. The ext-method
router serves the full upstream table (`acp_agent.rs:3794-4472`) on BOTH carriers
(stdio and the ws:// serve host, which previously dropped the router entirely): 13
methods routed to real backings — the `open-grok/{provider}/models/apply|refresh|clear`
family for fireworks/deepseek/meta/wafer/opencode-go, codex refresh/clear, kimi
query/clear and `kimi/endpoint/apply` (config swap + refresher rebuild at the new
service's base URL — Kimi key saves ride this method upstream), plus the pre-existing
`x.ai/feedback` — and 76 methods refused fail-closed with upstream's byte-exact
unknown-method error, each pinned by name. **The slice persists no keys** (upstream's
client persists before calling apply); the handler re-reads the store, refreshes or
clears the partition per the usable-credential probe (the SAME trust ladder the broker
fetches with — stored keys released only to the provider's official host, no gate
widened), and REBINDS the running session: the coordinator re-resolves the active
model and swaps the sampler fail-closed (same model/provider by construction — no
history reconcile, no Code Mode invalidation), so an applied key reaches the next
sampling request without restart. A rebind failure surfaces in the response's
`warning` field — the silent case announces itself. The ws:// e2e pins the whole
contract: `Bearer fw-old` → apply → catalog refetch under `fw-new` → next prompt's
sampling request carries `fw-new`.

**Bonus fix (latent footgun, the §2 process-default family):** `LiveModelCatalogStore`
built its `ModelsManager` without `grokHome`, so cache managers resolved against the
PROCESS environment — a hermetic test's codex-cache clear would have deleted the real
user's cache. Now pinned. Boot refreshers also honor configured `[models]
kimi_endpoint` instead of assuming Platform.

**Recorded divergences:** the rebind is a sampler rebuild (upstream's resident session
re-reads stored keys per call and needs none; its spawn-captured subagents get a
provider-scoped cancel the port lacks — a resident child keeps its credential until it
finishes); the `models` payload omits upstream's provider-auth availability filter and
`_meta` capability block (belongs with the ACP session-surface slice); refusals use the
unknown-method copy for methods upstream knows (a probing peer cannot distinguish
unimplemented from nonexistent, but always gets a well-formed fail-closed error);
`x.ai/recap` stays refused despite the E4 backing (the ACP runtime has no notification
path from an ext handler — acking while dropping the summary would be a silent no-op);
`x.ai/mcp/auth_trigger` stays refused (the E7 CLI verb owns that seam). Wave 15 items
3-7 remain, now behind an honest router.

### E11 — ACP notification gateway (serial gate: exit 0, 4,667 tests, zero issues; 2026-08-08)

Closes roadmap Wave 15 item 5 and the two walls prior slices recorded. Inbound ext
notifications reach LIVE state, never mirrors: `x.ai/yolo_mode_changed` applies through
`LiveSessionPermissionMode` (an inbound ENABLE is refused while a yolo pin reason exists
— the pin guard reviewed at the landed line; the sender is the connected ACP peer, the
same trust upstream extends at acp_agent.rs:4486-4553), `x.ai/swarm_mode_changed`
reaches the E8 tracker with both broadcasts, `x.ai/permissions/reset` resets the live
`PermissionHandle`. Outbound: `x.ai/session/prompt_complete` at turn end (all three
field arms, byte-pinned in the stdio wire golden) and the `x.ai/session_notification`
envelope (`{sessionId, update, _meta{eventId, agentTimestampMs}}`) on the same channel
`session/update` rides. The unlocked routes: `x.ai/recap` moves from E10's refused
table to routed — ack `{ok:true}` then the async `SessionRecap`/`SessionRecapUnavailable`
notification off the E4 seam against the live conversation spine — and the mailbox's
`onAgentMessage` observer emits upstream's `SubagentMessage` update (closing E9
divergence 3). Five inbound names with no port surface are ignored silently (named in
the file header — notifications have no error channel; silence matches upstream's
unmatched arm). 9 new test suites over the real ws:// carrier.

**Recorded divergences:** single-stack fan-out (`clientIdentifier` matching vacuous —
one live stack per ACP process); auto-mode uses the heuristic classifier (LLM
side-query still absent); 
broadcasts are not persisted to `updates.jsonl` (a reconnecting client cannot replay);
recap lacks the watermark/idle gate and new-prompt epoch cancel (an `auto:true` recap
runs unconditionally); no `cancelTrigger` on prompt_complete; permissions reset is
in-memory (upstream persists the cleared state). The rest of the outbound
`SessionUpdate` family (RetryState, AutoCompact*, TaskCompleted, SubagentSpawned/…) has
no emitters yet — the delivery channel now exists for their slices.

### E12 — `x.ai/mcp/*` family + session admin over ACP (serial gate: exit 0, 4,685 tests, zero issues; 2026-08-08)

Closes roadmap Wave 15 items 3 and 6 (honest subsets). Newly routed with real backings:
`x.ai/mcp/list` (trust-gated config layers + live connect outcomes + live toolset),
`mcp/call` and `mcp/read_resource` (the session's retained client pool — the same
clients the bridged tools use, upstream's timeout ladder), `mcp/auth_status`,
`mcp/auth_trigger` (the REAL E7 flow, with the token-landed assertion AFTER the flow
returns — "flow returned" is not "token landed"), `mcp/upsert`/`mcp/delete` (real user
`config.toml` writes through the same functions `mcp add` uses, plus live toolset
swap/teardown), and `x.ai/session/rename|delete|fork` on the real store (live-session
rename goes through the history actor — a direct file write would be undone by the next
turn commit; resident-session delete is REFUSED, no teardown seam). Inbound
`x.ai/mcp/sdk_call` and unknown prefix names get upstream's OWN bare `method_not_found`
(mcp.rs:387, byte-mirrored); `mcp/setup`/`toggle`/`toggle_tool` stay refused with the
data-carrying terminal error (no preferences/disabled-list persistence — a toggle that
doesn't survive restart would be "succeeds, does nothing later"). Refusal pin 76→71,
counted mechanically. **Deliberate absence, load-bearing:** initialize `_meta` does NOT
advertise `x.ai/mcp/sdk` — the SDK enables `transport="acp"` on that flag alone, and the
reverse bridge is not implemented; a test pins the absence. **Lead fix:** that pin
called `initialize` twice (the state machine refuses a second handshake); the harness
now captures its own handshake response for meta pins.

**Recorded divergences:** `mcp/list` omits managed connectors/gateway rows; upsert
connects synchronously (handshake failures surface as internal_error where upstream's
background init defers them); auth_trigger's static-header arm keeps the port's copy;
no remote session writeback; fork refuses `newModelId`/`targetPromptIndex`/…
loudly rather than dropping them; fork ids UUIDv4. Remaining refused: the session
info/close/updates/state/import/search family (needs live SessionCommand plumbing,
updates journals, FTS), the `sdk_call` reverse bridge, and the
`servers_updated`/`tools_changed` outbound notifications (no emit sites yet). Wave 15's
open remainder: item 7 (real `x.ai/btw` side-question semantics).

### E13 — real `/btw` side-question (serial gate: exit 0, 4,700 tests, zero issues; 2026-08-08)

Closes roadmap Wave 15 item 7 — Wave 15 is now complete end to end. `/btw` no longer
maps to the interjection buffer (E5's recorded divergence): it runs upstream's
off-conversation side question (`handle_side_question`, `acp_session_impl/recap.rs:70-180`)
— a tool-free one-shot sample on the ACTIVE session route over a conversation snapshot
(reasoning stripped only on the Messages backend, trailing tool-run popped), the
instruction byte-pinned by SHA against upstream, answer painted as the `BtwBlock`
scrollback shape ("/btw {question}\n{answer}"), and a question+answer record appended to
`sessions/<id>/btw_history.jsonl`. It never touches the conversation, queue, or running
turn — the no-mutation contract is pinned mid-turn and idle (next turn's request body is
clean of both question and answer). `x.ai/btw` moves from E10's refused table to a routed
SYNCHRONOUS handler (answer in the ext response, not a notification — a brief correction
the delegate verified: `extensions/feedback.rs:46-93`, refusal pin 71→70).

**Brief corrections, delegate-verified:** the sample is on the active route, not the
recap aux route (recap.rs:81-84,110-112); the ACP arm is synchronous, not recap-shaped
async. **Lead fix — a bug the gate caught:** the JSONL torn-tail heal opened the file
`forWritingAtPath` (write-only) and then READ the last byte to check for a missing
newline — EBADF on every append to an existing file; two history tests failed. Fixed to
`forUpdatingAtPath` (O_RDWR).

**Recorded divergences:** no overload-only retry (no sampling-error classification seam;
`attempts` is honestly always 1); tool-free side call (shared with `/recap`); no side
panel — running state and answer both paint as transcript notes (mid-turn output can
interleave between them); flat internal-error mapping for model failures (typed
rate-limit/auth codes unported); cosmetic JSON key-order/timestamp-precision differences.
The interjection seam itself stays (the collaboration quartet still produces into it);
only `/btw`'s routing changed.

## Wave 17 — Scheduler + chrome readers (2026-08-08, in progress)

### E17 — `OpenGrokScheduler` library (IMPLEMENTED-UNWIRED; serial gate: exit 0, 4,881 tests, zero issues)

The pure scheduler library as a standalone target (Foundation only — imports neither CLI
nor pager, confirmed): interval parsing with upstream's 60 s clamp
(`scheduler/interval.rs:3,44`) and exact human strings, `ScheduledTask` next-fire
(`lastFiredAt ?? createdAt + interval`, `types.rs:281-284`)/expiry (recurring → 7 days)/
`fireImmediately` backdate, `SchedulerState` with the 50-task cap (`actor.rs:26` — the
delegate corrected the brief's `types.rs` citation; `types.rs:234`'s same-valued constant
is the version-clock reservation cap, a different control), and the `ScheduledTaskInfo`
display DTO. Also brought `SlashCommands.swift`'s `/loop` wording to PROVEN byte parity
with upstream (`slash_commands.rs:5-96`) — the delegate compiled both sides and `cmp`'d
the rendered strings byte-identical, locking the Rust line-continuation whitespace
stripping. Golden tests ported from upstream's interval/types/actor/slash-command suites.
`parseInterval` throws rather than returning optional, deliberately, so the runtime slice
inherits upstream's `invalid_arguments(e.to_string())` message instead of inventing one.

**This is LIBRARY ONLY**: no `/loop` command, no `scheduler_*` tool handlers, no
session-actor timer — `/loop` stays SKIP-ABSENT and the `/tasks` Scheduled section stays
unrendered until the runtime + surface slices land. Recorded implemented-unwired per §7.
Design guardrail carried into those slices (from the scheduler research): fires ride a
dedicated sleep-until-due plus the prompt-queue Cron path (upstream's `enqueue_cron_prompt`
→ synthetic turn), NEVER the PagerMotion UI ticker or the mid-turn interjection seam.
**Superseded by E18 below** — the runtime + surface landed and E17's library is now LIVE.

### E18 — scheduler runtime, `/loop`, `/tasks` Scheduled section (LIVE; serial gate: exit 0, 4,910 tests, zero issues)

The E17 library is now reachable end to end in the interactive TUI. `scheduler_create` /
`scheduler_delete` / `scheduler_list` dispatch through the real executor (specs verbatim
from `create.rs:14-121`/`delete.rs:38-42`/`list.rs:41-43`, `recurring` hidden per
`#[schemars(skip)]`), gated three ways: the host exists only when
`interactiveSurfaceAvailable` (the `ask_user_question` precedent — headless/ACP/children
advertise nothing, because a create whose fires can never run is worse than an absent
tool), `requires_expr` is honored (a profile stripping `scheduler_create` drops all
three, `delete.rs:48-56`/`list.rs:45-53`), and dispatch runs the hooks-only PreToolUse
gate (`gateSchedulerTool`, the `gateCollaborationTool` shape — upstream has no scheduler
permission-rule kind; the fired prompt's own tool calls pass the full pipeline like any
typed prompt). Fires ride the dedicated sleep-until-due timer (`LiveSchedulerHost`,
generation-stamped, injected clock, deterministic `fireDue(now:)` — the E17 guardrail
held: never the PagerMotion ticker, never the interjection seam), then the Cron path:
`enqueueCronPrompt` with both upstream de-dup guards (already-queued, already-running;
`background.rs:483-496`) → idle-loop `cronEnqueued` drain → a real turn whose wire text
is `formatScheduledTaskPrompt` framing while the user echo stays the raw prompt, stamped
`scheduler-fired-` and persisted as `.schedulerFired` via the prompt-id prefix
(`PromptOrigin::from_prompt_id`, `session/mod.rs:126-127`). Cron entries never parse as
slash commands and never merge under combine-queued-prompts, in either direction. `/loop`
registers only when the session's advertised toolset carries `scheduler_create`
(`loop_cmd.rs:107-109`), seeds the `provisional-` tasks-pane preview, and injects the
in-session schedule instruction; `/tasks` renders the Scheduled section byte-exact off
the SAME host the tools mutate — including upstream's `{:<9}` nine-char status quirk
(`"  scheduledloop · …"`, no space before the tag; pinned with a test, don't "fix" it).
Executor shutdown cancels the timer before children so a fire cannot land in a torn-down
controller. 24 new tests across six suites (counted from the gate run, not the
delegate's claim of 20), all live-seam or controller-seam: real
dispatch + error catalogue, injected-clock fires (zero real sleeps), `/loop` gate +
instruction pins, byte-exact Scheduled rows, controller Cron semantics (idle drain with
metadata, mid-turn wait, both de-dup guards), and the end-to-end fire → drain → real
shell turn → on-disk `.schedulerFired` persistence.

**Deferred at this slice, deliberately (each cited in-source):** Detached loop-subagent fires and the
`[scheduler] background_loops` config reader (wiring the key now would give it a parse
with no behavioral reader — §3; `/loop` pins `.inSession` and the instruction describes
the runtime the user actually has), the `monitor` tool (rows all render "Task"),
scheduler persistence/durable removal (`durable: true` is stored but dies with the
session — user-facing cost recorded; closed later in E23), and headless/ACP/leader
scheduler surfaces.

**Recorded divergences:** single-process store (no `ScheduledTaskCreated/Fired/Removed`
notification hop — nothing would consume it; a future ACP scheduler adds it); fires wait
for the sink with no 10 s deadline (upstream `actor.rs:224-253`; sink installs before any
task can exist today); sorted-key `Z`-suffixed tool-result JSON (cosmetic); lenient-bool
fallback where upstream errors (more permissive on schema-forbidden inputs); cron
scrollback paints a plain user block (no `RenderBlock::cron_prompt` ↻ styling); `/loop`
echoes the injected instruction, not `/loop {args}` (the `/imagine` precedent);
provisional keys are `provisional-<uuid>` not `provisional-<queue-id>`;
`isIntervalToken` splits the last `Character` where Rust would panic on a multi-byte
final byte (the shared `parseInterval` divergence).

### E19 — `/compact-mode` live (serial gate: exit 0, 4,928 tests, zero issues)

The first chrome reader, landed on the seam the research corrected to: the live
`OpenGrokPagerRender` frame builder, not the typed conversation model. `renderPagerFrame`
consumes a DERIVED `PagerRenderState.compactMode` (upstream reads
`appearance.prompt.compact`, never the user setting; `appearance/config.rs:91-95`) —
compact collapses the status gap (`views/agent.rs:222`), prompt gap
(`agent_view/render.rs:1138-1145`), and bottom/shortcuts gap (`views/agent.rs:256`), and
drops the user prompt's padding rows, `❯ ` prefix, and continuation indent
(`blocks/user.rs:490-494,513-515`); the announcement/turn-status gaps stay unconditional,
as upstream's are. `pagerEffectiveCompact` is a near doc-for-doc port of
`effective_compact` (`views/agent.rs:96-98`) with `AUTO_COMPACT_MAX_ROWS = 20`
(`agent.rs:87`, deliberately above the 16-row hard-degradation gate; 0 rows = "not yet
measured", never forces). `/compact-mode` (name/copy/display-order verbatim,
`compact_mode.rs:16-30`, `slash/commands/mod.rs:108-110`, no aliases) flips the USER
value and persists `[ui] compact_mode` through the settings store, rolling the in-memory
flip back on a failed write so the toggle can never claim a state the file lost; both
toast arms are byte-parity (verified against `setters.rs:1516-1522` and
`save_success_toast`, `ui.rs:89-92`, including the "off (auto-compact active on small
terminal)" arm). Startup hydrates the user value from the effective config before the
first paint; the settings-modal commit live-flips the same variable (`ui.rs:1207`
routing); a confirmed reset re-derives from the `false` default; the settings row is
unhidden as upstream's FIRST Appearance row with `defs.rs:614-629` copy verbatim
(verified at the pin). 18 new tests: derivation pins, paint deltas (padding/prefix/gap
rows, config-at-startup ≡ toggled-on frame), controller registry/dispatch/order pins,
and live-seam persistence + startup + modal-flip + auto-compact-toast in isolated homes.

**Recorded divergences:** upstream's prompt-gap expression also has turn-status-gap and
short-terminal arms with no port seam yet — the port's turn status always keeps its own
gap row (noted in-source at the read site); toasts ride transcript notes (the port-wide
convention, not new here).

### E20 — `/timestamps` live (serial gate: exit 0, 4,948 tests, zero issues)

The second chrome reader, same seam and shape as E19. `PagerMessage.createdAt: Date?`
(upstream `ScrollbackEntry.created_at`, `entry.rs:105`, stamped `Local::now()` at
construction, `entry.rs:198,230`) is stamped on every live producer — `startTurn`
user+assistant, the streaming fallback, the `.interjected` echo — and `nil` paints
nothing, upstream's `let Some(ts)` gate (`entry_renderer.rs:939`); the deliberate `nil`
DEFAULT means a producer that forgets to stamp silently paints no stamp, so the live
stamping is pinned through painted frames by `LiveTimestampsTests`. The renderer ports
the full read-site set (verified at the pin): role gate user/agent only
(`entry_renderer.rs:376-382`; upstream's `Btw` arm has no port counterpart — `/btw`
rides system notes, pre-existing), the 10-column wrap reserve keyed on flag+role and
ignoring `created_at` (`:384-393`), and the right-aligned `theme.gray` short stamp
(`"  %-I:%M %p"` → `"  h:mm a"` POSIX) on the first content line with the
`width > ts_width + 1` guard (`:930-960`). **Resume** sources original instants from the
rewind sidecar (`LiveRewindPoint.createdAt`, semantically upstream's `turn_start_ms`,
`acp/tracker.rs:1380-1385`), keyed by positional prompt index counted over
`startsPromptTurn` — synthetic turn-starters spend a slot without painting, keeping the
numbering aligned with `liveTruncateConversation`. `/timestamps` (copy/order verbatim,
`timestamps.rs:12-23`, before `/toggle-mouse-reporting`) toggles + persists with
rollback-on-failed-write; toast `✓ Timestamps: on|off`, no conditional arm; startup
hydrates `showTimestamps ?? true` (**absent means ON** — `TIMESTAMPS_DEFAULT`,
`appearance/cache.rs:28`); modal commit live-flips; reset re-derives `true`; the row is
unhidden after `screen_mode` with `defs.rs:658-671` copy verbatim (verified). Unlike
compact there is NO derivation — the render value IS the user value
(`setters.rs:1530-1541`). 20 new tests, all fixed-instant.

**Recorded divergences (each in-source):** restored ASSISTANT blocks carry no stamp (the
port persists no per-assistant instant; nil is honest where turn-start or load time would
lie — cost: after `/resume`, stamps show on restored prompts and new blocks, not restored
replies); sidecar-less sessions restore un-stamped; no hover-expanded long format
(`PagerRenderState` carries no mouse position; upstream's pushed sticky headers are
short-only too); span-append overlay skips the stamp for one frame on a streaming-cursor
collision instead of overpainting; `arg_placeholder` "on/off" has no port channel;
`PagerRenderState.showTimestamps` init-defaults `false` (semantic default `true` rides
the live pass-through, pinned).

### E21 — `/timeline` rail live (serial gate: exit 0, 4,980 tests, zero issues)

The last chrome reader; the trio is closed. `PagerTimelineRail.swift` is a near
line-for-line port of `views/timeline.rs` (verified at the pin): `RAIL_WIDTH 2` /
`MIN_TERMINAL_WIDTH 60` / `MIN_TURNS 2` (`:18-25`), `compute_rail` windowing/centering
(`:109-168`), whole-width hit-testing (`:187-204`), and `chevron_target` derived from the
same fields that dim the chevrons so display and action cannot disagree (`:177-183`),
plus the viewport reads from `scrollback/state/timeline.rs:83-137` (active = last prompt
at/above the viewport top; ▲ strictly-above — upstream's stuck-▲ fix; ▼ next-below)
partitioned over the prompt blocks' first painted line indices —
`makeConversationLines` grew into `makeConversationLayout` returning per-block start
lines, the port's `virtual_y`. The rail REPLACES the scrollbar in its gutter
(`agent_view/render.rs:1737-1749`), takes 2 columns out of the wrap width, is forced off
by scrollbar-config-off (`views/agent.rs:364-368`) and by viewports under 3 rows, and is
gated to fullscreen at the frame pass-through (`agent_view/render.rs:1157` — the rail
render path exists only there; the port's inline mode rides the same frame builder, so
without the gate a config-on would paint a rail into the inline strip). THE turn
enumeration is `pagerTimelineTurnBlockIndices`, now consumed by both the rail and
`LiveJumpPicker` — one list, two navigators, no drift (upstream: both read
`ScrollbackState::turns`). Click-to-jump is wired through per-frame geometry published
on `PagerFrameLayout.timelineRail` (replace-wholesale like overlay bounds, so a click
never acts on a stale frame), resolving via `chevron_target` and jumping through the
same `revealBlock` seam `/jump` uses; capturing overlays block the rail; dim-chevron
clicks are consumed without acting. `/timeline` (copy verbatim, between `/timestamps`
and `/toggle-mouse-reporting`) refuses in inline mode BEFORE any flip or persist with
upstream's `ModeSupport::FullscreenOnly` refusal byte-parity (`mode_support.rs:38-57`,
verified), then toggles + persists with rollback; toast `✓ Timeline sidebar: on|off`
(plain arm). Startup hydrates `showTimeline ?? false` (opt-in, `SHOW_TIMELINE_DEFAULT`);
modal commit live-flips; reset re-derives `false`; the row is unhidden after
`show_timestamps` with `defs.rs:672-686` copy verbatim (verified), `hiddenInMinimal:
true`. 32 net-new tests (geometry/viewport/paint, controller pins, live persistence +
startup + modal-flip + click-to-jump in isolated homes).

**Recorded divergences (each in-source):** hover is not ported — no bright
hovered tick/chevron and no tick preview popup (`views/timeline.rs:224-237,255-263,
275-357`); they need the mouse position at paint time, the same missing channel E20
recorded (cost: no pointer feedback or preview; clicks still jump; the row description
keeps upstream's "hover previews a turn" verbatim per parity rules, so it over-promises).
No over-scroll on jump: `revealBlock` clamps to `maximumOffset`, so trailing-turn clicks
scroll to bottom rather than prompt-to-top (pre-existing `/jump` behavior). Click does
not select/focus the prompt entry. `/timeline` registers in both modes and refuses at
dispatch rather than hiding from inline completions (the `/jump`/`/find` precedent).
`is_subagent_view` gate vacuously false (no subagent scrollback view). Legacy-ConHost
glyph fallbacks not ported (the `PagerGlyphs` table's standing policy).

**Chrome readers: complete.** All three Wave-13-hidden rows with readers
(`compact_mode`, `show_timestamps`, `show_timeline`) are now live; the hidden list
retains only `page_flip_on_send`, `simple_mode`, `render_mermaid`, `max_thoughts_width`,
`show_thinking_blocks`, `group_tool_verbs`, `collapsed_edit_blocks`.

### E22 — Detached scheduler fires, `background_loops`, `monitor` (serial gate: exit 0, 5,023 tests, zero issues)

Closes E18's recorded deferrals except persistence. **Detached fires**
(`actor.rs:406-450` selection, `:511-733` mechanism): a due fire on a non-`foreground`
task with `background_loops` resolved on runs as a real background loop-subagent through
the SAME `LiveSubagentHost.spawn` the `spawn_subagent` tool uses (`subagent_type:
"general-purpose"`, framed `format_loop_iteration_prompt` — byte-parity verified at
`reminders/mod.rs:63-83` — and the `loop: … (schedule)` description), so an iteration is
a real child in every observable way (`/tasks`, output/kill/resume). Chain semantics
ported faithfully: probe the previous iteration against the real coordinator
(running/unanswerable → skip with the interval consumed), fresh-restart every 10
iterations with a 600-char summary, `chainResetPending` honored, anchor written BEFORE
dispatch and restored in FULL (including a consumed pending reset) on a failed dispatch,
which falls back to the E18 Cron inject; a failed iteration clears the anchor by
spawned-subagent id. `foreground: true` keeps the Cron path — that is what the flag
means. Fire-mode selection is byte-parity with `actor.rs:414-423` (verified).
**Authorization design, reviewed by the lead:** a fire is not a tool call — no
PreToolUse runs, matching upstream's actor-internal `SubagentEvent::Spawn`; the
authorization surface is the child's own `LiveToolExecutor`, built by the pre-existing
`LiveSubagentHost.runChild` from the parent session's security context/sandbox/
permissions — the same surface a Cron turn's tool calls pass. **`background_loops`**
(`toolset.rs:216-264`): full precedence chain (env `GROK_SCHEDULER_BACKGROUND_LOOPS` >
requirement > user `[scheduler] background_loops` > managed/system-managed > remote
flag > default TRUE) in `Sources/OpenGrokConfig/SchedulerConfiguration.swift`, consumed
by two behavioral readers in the same slice (host fire-mode selection, `/loop`
instruction mode) — the §3 rule E18 cited is satisfied. **`monitor`**
(`monitor/{tool,event,rate_limiter,types}.rs`): upstream corrected the brief's sketch —
it monitors a shell command's stdout lines, not subagent runs; backed by the session's
real process execution with `kind: .monitor`, byte-pinned `<monitor-event>` line
pipeline, token-bucket rate limiter with suppression and 30 s auto-kill (injected
clock), mid-turn delivery via the interjection buffer and idle delivery as a
`monitor-{task}-{uuid}` prompt turn; `/tasks` renders the `is_monitor` arm byte-exact.
43 net-new tests, including the E2E: real `scheduler_create` → deterministic fire → a
real child on the real coordinator with `lastSubagentId` recorded and the child's actual
sampler request ending in the framed iteration prompt.

**Lead ruling — monitor dispatch gate is deliberately STRICTER than upstream.** Upstream
registers `monitor` with `requires_expr: Expr::True`, a generic `Other` permission kind,
and no bash-rule evaluation against its `command` (verified at the pin: `tool.rs:40-42`,
`tool_calls.rs:2402-2407`, and no monitor arm anywhere in the permission mapping). The
port routes monitor dispatch through the full bash permission pipeline
(`gateMonitorCommand`: fail-closed on no pipeline, `prepare(.bash(command))`,
ask-without-prompter denies). Reason: the port's `run_terminal_cmd` and background-task
tools all gate arbitrary commands through this pipeline; an arbitrary-command tool
admitted hooks-only would be a second, weaker door to the same capability — the §5
"next author copies whichever gate they open first" hazard. Cost, recorded: a
`deny Bash(foo:*)` rule also blocks `monitor {command: "foo …"}` where upstream would
run it, and unknown commands under a headless prompter are denied rather than monitored.
Collapsing to upstream-exact is one edit if ever wanted.

**Recorded divergences:** remote-settings tier fed `nil` at the interactive call site
(no startup settings fetch there; the resolver carries the tier); `background_loops`
construction-fixed per session (no mid-session rebuild seam); `LoopUnitActive`
descendant guard vacuous (children cannot nest-spawn); monitor idle wakes ride the pager
queue (visible in the `+n` count; model-facing text and prompt id are parity); mid-turn
monitor events carry the interjection drain's envelope around the already-wrapped body;
monitor advertised interactive-only (no delivery seam elsewhere — the E18 shape);
rate-limit auto-kill stops the pipeline but not the process (upstream's own behavior at
the pin); monitor output files under the port's session folder root; sorted JSON keys
and v4 lowercase ids (shared cosmetics).

**Still deferred at this slice, deliberately:** scheduler persistence / durable removal (`durable:
true` parses and stores but dies with the session — the occurrence journal and
durable-removal barriers are unported); headless/ACP scheduler + monitor surfaces;
`TaskCompleted` auto-wake (pre-existing background-task deferral — a monitor's natural
exit produces no completion wake; visible via `/tasks` and output reads only).
*(The persistence deferral closed in E23 below; the other two stand.)*

### E23 — scheduler persistence, durable-removal barriers, occurrence journal (serial gate: exit 0, 5,041 tests, zero issues)

Closes the last scheduler deferral. **Load-bearing finding, verified by the lead at the
pin (it overrode the brief's sketch):** upstream persists ALL tasks, not only durable
ones — `SchedulerState.tasks` has no serde filter (`types.rs:293-303`) and nothing
filters at save/load (`types/resources.rs:303-366`, `persistence.rs:113-154`); the
`durable` flag's only behavioral readers are the expiry barrier (`actor.rs:311-391`) and
the occurrence journal's one-shot constraint. `durable` buys the REMOVAL BARRIERS —
"persists across sessions" is realized as surviving `--resume` of the same session.
State lives at `$OPENGROK_HOME/sessions/<sessionID>/resources_state.json` in upstream's
exact shape (`{"state": {"grok_build.Scheduler": …}}`, `registry/types.rs:1134-1139`;
the session-id path segment is safe by construction — every id passes
`validateSessionID` `[A-Za-z0-9._-]`/≤128/not-dots, re-verified by the lead). Two write
grades, exactly upstream's (`persistence.rs:297-347`): best-effort temp+rename saves at
every scheduler mutation (a superset of upstream's debounced per-tool-call trigger,
same at-rest content — recorded), and the durable barrier (temp → fsync file → rename →
fsync parent dir, temp cleaned on failure, directory-squatter removed, parent dir never
created by the writer). **Removal barrier** (`actor.rs:837-870,150-179`): a delete
persists durably before acknowledging; while pending, fires are suspended, the timer
parks, and every other mutation throws `RemovalPending` — only retrying the same delete
makes progress, so a crash cannot resurrect a task the user watched disappear.
**Durable expiry** removes → durable save → on failure re-inserts at the same slot and
blocks the id from due-selection and timer computation (`blocked_expiries`).
**Overdue-at-load**: one catch-up fire, never per-missed-interval — load leaves
`lastFiredAt` untouched, the sink install runs `fireDue(now)`, `markFired` re-anchors;
the E18 wiring-grace seam covers loaded tasks as designed. Corrupt/missing/foreign
files load fresh, never crash (every upstream failure arm mapped). **Occurrence
journal** ported whole (`occurrence_journal.rs`: v7-validated ids, quarantine/overflow
caps 50/50/256, prepare/finish/reconcile, byte-exact error strings) with every upstream
test; NO runtime reader was invented — upstream's own consumers are
`#[expect(dead_code)]` at the pin, recorded in the file header. 18 net-new tests
(journal pins; state-file/reload with cadence phase preserved; barrier crash-reload;
corrupt/foreign files) — the hand-off's "30 new" counted re-run E17 suites; the gate's
count is the ledger's.

**Recorded divergences:** no acknowledged-tombstone leg on delete/expiry (upstream's
tombstone cancels replayed pager rows; the port replays no scheduler rows — if a
transcript-replay surface lands, deletes need the tombstone or rows resurrect
visually); save timing mutation-driven vs. debounced per-tool-call (same rest state);
binary barrier outcomes (no Timeout/Cancelled arms — the write is a direct bounded
call); `sessions/<id>/` without upstream's `<encoded-cwd>` level (established port
convention); single-resource file (a round-trip over an upstream file drops resource
keys the port doesn't register — upstream's own behavior for unregistered types);
`SchedulerClock`/reservation machinery unported (stamps a cross-process notification
stream this one-process port lacks; the version VALUES are ported since they live in
the file format); restored-row display stamps use millisecond-spaced load instants.

### E24/R0 — reference re-pin to `.58` (serial gate below; audit + lead-landed pin bump)

The E24 audit enumerated `70002584..650c1db7` (release `.58`): two commits, one
substantive (`f0a5a29f` "Harden provider reasoning and fast routing", 13 files,
+834/−55, entirely provider/reasoning/fast-tier). **Load-bearing audit finding:** the
port had already absorbed roughly half the delta — the `service_tier` wire field and
forwarding, the Kimi/DeepSeek/OpenCodeGo/Wafer/Fireworks strips, the Meta
reasoning-item drop, the Fireworks effort-restore gate, and the
`sampling_config_for_model` effort gating landed in Wave 16/E3/E15 with in-source
citations (`client.rs:1806-1813`, `provider.rs:353/386/411/422`,
`fireworks_models.rs:167-171`, `acp/model_state.rs:199-212`) that only resolve against
the `.58` tree. Staying on `.57` would have meant a ledger whose provider citations
don't resolve; the re-pin makes them honest. E18–E23's cited files (`scheduler/`,
`monitor/`, `views/timeline.rs`, `scrollback/`, `settings/defs.rs`, `slash/commands/`,
`reminders/mod.rs`, `toolset.rs`, `persistence.rs`, `registry/types.rs`) are untouched
by the delta — verified. R0 (this entry, lead-landed): `OPEN_GROK_VERSION` and every
compiled-version site restamped `.58`; `cli-version-and-home.json` recaptured; GCRX
sample restamped by same-length offset-32 substitution with `crash-gcrx-format.json`
provenance updated; `PROVENANCE.json` rewritten with per-family `70002584..650c1db7`
evidence (every family diff verified empty by the lead, including `Cargo.lock` and the
telemetry/tracing surfaces after catching one vacuous pathspec in the first
verification pass); ledger headers and `CRATE_MAP.md` pin updated; E3's "pre-existing"
label on the Fireworks effort divergence corrected in place.

**Queued from the audit (R1–R5):** R1 (S) Fireworks curated reasoning efforts
(`fireworks_models.rs:164-166` at `.58` — closes E3's corrected divergence); R2 (S)
OpenCode Go output-limit drop (`opencode_go_models.rs` `_output` rename); R3 (S)
`ConfigModelOverride` supports=false clearing (`config.rs:4653-4656`); R4 (M) Fireworks
process-global 2-permit pacing gate with permit-held-until-stream-drop semantics; R5
(S) catalog-refresh effort reconciliation — decide (wire a minimal reconcile) or record
the deferral with the `.58` cite. **Not required by the re-pin (recorded):**
`tool_calls.rs` unified-log telemetry enrichment (no unified log in the port) and
`subagent/mod.rs` spawn-refresh reconciliation (children ride the parent sampler;
covered by E10's recorded divergence — the `.58` cite belongs there when R-slices
land).

### R1–R3 — Fireworks efforts, OpenCode Go output drop, override clearing (serial gate: exit 0, 5,049 tests, zero issues)

Three disjoint `.58` behavioral items, each verified against the pin by the lead. **R1:**
every curated Fireworks entry now carries `supportsReasoningEffort = true`, the
Low/Medium/High menu (Medium default, descriptions absent — byte-faithful to
`fireworks_reasoning_efforts()`, `fireworks_models.rs:182-197`), and `.medium` as the
catalog effort (`:164-166`) — closing E3's corrected divergence. The load-bearing note
is in-source: the non-nil catalog effort is what arms the already-live sampler
effort-restore gate, so reverting it silently strips `reasoning_effort` from every
curated Fireworks request while the suite stays green. Proven in both directions on the
live wire (real resolver → real sampler → mock server bytes): curated `glm-5.2` sends
`"reasoning_effort": "medium"`; a genuinely non-curated user-config Fireworks model
sends none (the fail-closed arm of `fireworks_reasoning_requires_explicit_model_support`).
Embedded (pre-refresh) Fireworks defaults stay effort-less, as upstream's own
`config.rs:14155` pin demands. **R2:** the `limit.output → maxCompletionTokens` mapping
is deleted (`opencode_go_models.rs:243-259` assigns none at the pin — models.dev's
1M-scale output caps became oversized request limits); the field stays parsed-but-unused
with upstream's `_output` rename intent in a comment, and both oversized-value nil pins
(1,000,000 / 500,000) are ported. Divergence kept: Swift keeps the name `output` (no
`_`-prefix convention); the nil pins are the guard. **R3:** the override-apply clearing
arm — explicit `supports_reasoning_effort = false` also clears `reasoning_effort` and
the menu (`config.rs:4653-4656`, placement verified exact) — with both upstream tests
ported through the tuning seam plus a port-added pin that an ABSENT flag clears nothing
(the `Bool? == false` spelling invites a `!= true` "simplification" that would flip
absent into clearing; the test is the tripwire). 8 net-new tests.

**Pre-existing gap surfaced by R1, ruled by the lead → R4b:** the pin's
`CURATED_FIREWORKS_MODELS` has 6 entries (`fireworks_models.rs:38-81`); the port's
`FireworksModels.curated` has 4 — `fireworks:kimi-k3` and `fireworks:kimi-k3-fast` are
missing (predates `.58`). Cost today: an authoritative Fireworks refresh replaces the
embedded partition, so post-refresh the port drops the two Kimi variants entirely.
Queued as R4b alongside the pacing gate.

### Wave 18 B9 — personas/agents modal, release-notes viewer, privacy banner (research complete, queued)

Research at the `.58` pin, with three seam corrections and lead rulings:

1. **Release-notes viewer needs no new render seam** — the live `/docs` document
   overlay (`.showDocument` → `PagerTextOverlay`) IS upstream's DocViewer with
   `standalone: true` semantics. The absent half is only the `ChangelogManager` data
   source (`changelog.rs`: CDN `x.ai/cli/changelogs/{VERSION}.external.{md,json}`, 3 s
   timeouts, parse-before-cache, `GROK_CHANGELOG_OFFLINE`), which follows the
   announcements-pipeline precedent including its recorded stricter export-boundary
   gate. **B9-a queued first** (a1 client S, a2 command S). Deferred with it: startup
   prefetch + welcome bullets/menu/CTA (the port's welcome overlay has no menu or info
   slot — Wave 18 B2 territory; cost: first `/release-notes` per session pays the 3 s
   offline timeout).
2. **The agents/personas modal must not land before personas feed the live seam** —
   `LiveSubagentHost` resolves subagent runtime with `personas: [:]`, so persona CRUD
   today would write files no session ever reads (the §3 "Saved, and permanently
   unfindable" class). **Lead ruling: B9-b0 (feed `[subagents.personas]` + persona
   dirs into `resolveRuntimeConfig`, proven through a real subagent's resolved
   instructions) is a hard prerequisite**; then b1 read-only Agents tab (new
   `.agents` overlay case, E14 extensions-modal precedent), b2 toggle/default-agent
   writes, b3 Personas CRUD + detail modal. Deferred: bundled-catalog column (no
   `x.ai/bundle/status` client exists — types only), `EditInEditor` (needs the
   `/transcript` `$PAGER` suspend seam generalized to `$EDITOR`), session-agent-name
   marker (no channel; resolved default shown, recorded).
3. **The privacy banner is frame chrome, not an overlay** — second tenant of the live
   frame builder's announcement-banner slot with upstream's critical-announcement-wins
   rule; clicks ride the E21 per-frame-geometry channel; hover styling is the recorded
   E20/E21 missing-channel divergence. **§4 finding: `[Opt in]` has no working backing**
   — the port has no `PUT /privacy/coding-data-retention` client, and the
   `coding_data_sharing` settings row is a non-persistable auth-metadata viewer, so
   `/privacy` currently deep-links to a row that cannot change anything. **Lead
   rulings:** (a) landing order c1 gate+ack plumbing (dark — rollout defaults false) →
   c2 retention write client (un-lies the existing `/privacy` row, valuable standalone)
   → c3 the banner, which therefore ships with BOTH buttons working — no one-button
   variant; (b) mouse-only interaction ships as upstream has it (§4: no invented
   keyboard affordance), cost recorded: without mouse reporting the banner is
   dismissible only via the settings row. Deferred: welcome tip-slot placement (B2)
   and consent-source telemetry.

Landing order: **B9-a → B9-c → B9-b** (smallest first; c2 standalone value; b gated on
b0). The docs corpus already documents all three surfaces, so each slice reduces
existing over-promising. Remote keys `privacy_notice_rollout`/`privacy_banner_reshow_days`
are parsed with zero readers today; B9-c1 adds their first readers.

### B9-a — `/release-notes` on the ChangelogManager port (serial gate: exit 0, 5,081 tests, zero issues)

`Sources/OpenGrokShellBase/Changelog.swift` (the crate map's home for
`xai-grok-shell-base`, where upstream's `changelog.rs` lives): CDN
`x.ai/cli/changelogs/{VERSION}.external.{md,json}` fetched in parallel with 3 s
timeouts, disk cache `$OPENGROK_HOME/CHANGELOG.{md,json}` with per-call env-home
re-resolution (harness homes win — upstream's `from_env_home`-inside-`fetch`), markdown
write-through, JSON cached ONLY after a successful parse (upstream's poison-guard, why
carried in the comment), CDN-miss fallback to disk at both levels,
`GROK_CHANGELOG_OFFLINE` cache-only mode, tolerant entry decoding, and
`bulletsFromEntries` ported+tested but consumer-less (awaiting the B2 welcome build-out,
marked in-source, advertised nowhere). All FIVE upstream unit tests ported (the brief
said four; the delegate corrected it) with the unreachable-base injectable-URL shape —
no env mutation. `/release-notes` (alias `/changelog`, copy verbatim from
`release_notes.rs:10-25`, verified at the pin; anchored after `/tasks` per
`mod.rs:150`) emits a `.releaseNotes` intent; the renderer fetches and takes both
upstream arms — markdown → the EXISTING `/docs` document overlay (the research's
seam correction: no second viewer), absent → the byte-exact
`No release notes available (offline).` notice. 24 net-new tests: 11 client, 7
controller pins, 6 live-seam (painted seeded-cache content, scroll proof, exact error
copy, and the no-request gate proof with a positive control).

**Recorded divergence (lead-ruled):** the fetch is gated on the xAI export boundary,
fail-closed by construction (`exportPolicy` defaults `.denied`; network requires
allowed-AND-transport) — upstream's changelog fetch is ungated. Cost: a Codex-only
session shows release notes only from a prior xAI session's cache, else the offline
copy. **Deferred with the wave:** startup prefetch + welcome bullets/menu/CTA (B2; cost:
first `/release-notes` per session pays the 3 s timeout when offline). Debugging note
worth keeping (delegate's): the captured sink records the terminal DIFF stream, so a
scroll test's marker must live in columns the replaced rows never painted — a
coincidentally-identical cell emits nothing.

### B9-c1 — privacy banner gate + ack plumbing, DARK (serial gate: exit 0, 5,112 tests, zero issues)

Nothing paints; the rollout flag resolves false at every live seam (the interactive
composition has no remote-settings fetch — pre-existing recorded gap — and the default
is false, `app_view.rs:2025`); env overrides are the only live activation path by
design. `PagerPrivacyBanner.swift`: the gate ported arm-for-arm from
`privacy_banner_should_show` (`app_view.rs:1705-1731`, verified at the pin by the lead)
— minimal/rollout/ZDR/team-non-admin/not-opted-out/auth-trust-access preconditions, and
the reshow window (`:1394-1407`) with the **unparseable-ack-fails-OPEN** arm pinned
(plus the ordering pin that the days-guard precedes the parse, so unparseable+no-window
still never re-shows — upstream's own short-circuit). `[privacy].privacy_banner_acked`
round-trips through a dedicated store (upstream's `update_config` parse-mutate-serialize
shape; deliberately NOT a `PagerSettingsStore` row — registry rows render in the modal,
and the ack has no upstream row, so registering one would be invented UX; ruling
recorded in-source). First readers for `privacy_notice_rollout` /
`privacy_banner_reshow_days` with upstream's ACTUAL env-then-remote-then-default chain —
deliberately not the E22 tier machinery, because upstream gives these keys no
config/managed tiers and inventing them would let a repo layer switch on a consent
upsell. **The auth hop was missing and now exists**: the renderer hydrates gate state
in `begin()` through the same `AuthManager` seam `/login`/`/logout` use, mapping xAI
credentials per `apply_auth_meta` (`app_view.rs:1753-1762`) and non-xAI per
`clear_xai_access_controls` (`:1662-1675` — opt-out FALSE, so Codex-only sessions
cannot be upsold; both arms verified at the pin). 31 net-new tests: the full gate
matrix, ack round-trip + failed-write rollback, env-over-remote pins, and 7 live-seam
tests hydrating from a real credential store in isolated homes.

**Recorded divergences:** rollback on failed ack write (upstream only warns, leaving
memory claiming an ack the disk never recorded — cost: this port re-shows immediately
where upstream hides until next launch); `trustDone` constant true (folder trust is
decided synchronously before the renderer exists; the input stays for a future trust
prompt); `authDone` = credential-present (no `AuthState` machine at this seam; a
non-xAI credential counts Done and is blocked by the cleared opt-out — same observable
result); the reshow overflow arm folds into `Date` saturation. **Deferred:** the
opt-in/opt-out dispatch handlers and inflight guard ride c2/c3 (landing them now would
register actions that lie — §4).

### B9-c2 — coding-data-retention write client; the `/privacy` row un-lied (serial gate: exit 0, 5,132 tests, zero issues)

`LivePrivacyRetentionClient` PUTs `{proxy}/v1/privacy/coding-data-retention` with
upstream's exact wire contract (verified at the pin against `extensions/privacy.rs:
30-94`: single-key `codingDataRetentionOptOut` body, Bearer + `X-XAI-Token-Auth` +
version + client-mode headers, `HTTP request failed: {e}` transport copy, non-2xx
`error`→`message`→`server returned HTTP {status}` fallback, confirmed-equals-requested
echo). The `coding_data_sharing` row is now a real control on upstream's exact order
(`dispatch/status.rs:141-183,424-491`): ZDR/non-admin guards, idempotent skip,
optimistic flip FIRST, server write, success re-anchors to the confirmed value, failure
reverts and toasts the scrubbed error (`pagerScrubErrorForToast`, the `status.rs:186-200`
port), and a write-generation guard drops superseded replies (a superseded failure
neither reverts nor toasts — its rollback predates the newer write). The mirror applies
to the row, the open modal snapshot, AND the B9-c1 gate state in one place, so the row
and `shouldShow` can never disagree; on success the auth.json mirror persists via
`AuthManager.update` — **lead-verified: the port's `update` is a pure persist+swap with
no background enrichment fetch, so it already IS upstream's `save_without_enrichment`
and the stale-ACL overwrite race upstream dodges cannot occur here.** Storage kind
stays `.authMetadata` (upstream's own; the row persists to the server + auth mirror,
never config.toml — pinned that `persistedPath` is nil). The c3 seam is
`setCodingDataSharing(optedIn:) → .refused/.unchanged/.saved/.failed` (`.saved` is the
banner's ack trigger; `.unchanged` must not arm the inflight flag, `status.rs:513-516`).
20 net-new tests: a real-socket PUT asserting method/path/body/header PRESENCE (never
the secret value), all-three-mirrors flip, failure rollback + surfaced error, the
denied-boundary zero-request proof with positive control, the superseded-reply pin via
a hold-first transport, and registry pins.

**Recorded divergences:** the write is export-boundary-gated (fail-closed `.denied`
default + the feedback client's live send-time bail; upstream's is ungated — cost: a
boundary-closed session cannot change the setting from the modal and sees the refusal);
toasts ride transcript notes; best-effort auth-mirror disk write (upstream's own
`let _ =`, cost in-source); message-passing collapsed to one awaitable seam with the
generation guard preserving out-of-order semantics; 10 s timeout (announcements'
number); on-demand hydration before consent guards (evaluating them against a
default-constructed state would let a ZDR team's write through). **Deferred to c3:**
banner paint, opt-in/opt-out handlers, the inflight flag; consent-source telemetry
stays lead-deferred (the seam takes a source parameter when it lands).

### B9-c3 — the privacy banner (serial gate: exit 0, 5,149 tests, zero issues). **The B9-c program is closed.**

`PagerPrivacyBannerRender.swift` ports `views/privacy_banner.rs` whole with byte-parity
copy (titles, description, `[Opt out]`/`[Opt in]`, all three legal variants, both x.ai
legal URLs — lead-verified at the pin) and every paint invariant carried with its test:
title-never-clipped compact fallback, legal line whole-from-widest-variant so both links
stay reachable, **buttons whole-or-not-at-all** (upstream's stake comment carried: a
clipped `[Opt in]` must not leave a click target in the blank margin where a stray
click silently opts the user in), 4-row body cap with ellipsis, exported
height-for-width. Painted as the SECOND TENANT of the frame-chrome announcement slot
(the research's seam correction — no overlay case) with critical-announcement-wins
(`app_view.rs:4859-4863`) and slot ownership per `render.rs:2128-2148` (the evicted
announcement neither paints nor publishes its link span). Gate consumption is the c1
`shouldShow()` on the render-state pass-through; rollout defaults false so nothing
paints out of the box (`GROK_PRIVACY_NOTICE_ROLLOUT=1` is the live activation, matching
upstream's own e2e). Four hit rects publish per-frame on `PagerFrameLayout`
(replace-wholesale, the E21 rail pattern), blocked by capturing overlays AND the
welcome hero so an invisible banner cannot take a consent click. Buttons carry
upstream's exact asymmetry through the c2 seam (`status.rs:491-546`): opt-in arms the
inflight debounce → write → `.saved` acks (with a live-mirror re-check that is
upstream's `if opted_in` — a concurrent opt-out supersedes correctly), `.failed` clears
inflight and the banner stays; opt-out acks locally IMMEDIATELY and fires the
best-effort decline (bypassing the idempotence guard, `:522-546` — a failed decline
toasts but never touches the ack). The deliberately un-branched `ackPrivacyBanner()`
calls are commented: a failed disk write rolls the in-memory ack back inside the seam,
so the repaint re-shows the banner — the failure announces itself on the surface it
concerns. 17 net-new tests incl. the real-listener opt-in PUT, the parked-decline
opt-out, inflight double-click = one request, and all four dark arms.

**Recorded divergences:** no hover styling (the E20/E21 missing channel); mouse-only
(lead ruling — cost: without mouse reporting, dismissal is via the `/privacy` row);
fullscreen-only pass-through (upstream's slot exists only in the fullscreen agent
view); welcome placement deferred to B2 (upstream shows the banner on the welcome
screen first; here the hero overpaints the slot until the first turn, and the router
treats welcome bounds as blocking); Optional rects vs `Rect::default()`
(representation). `set_unless_dropdown` suppression not ported — the port's completions
band cannot geometrically overlap the banner slot, so the click-through hazard it
guards does not exist.

### B9-b0 — personas feed the live seam (serial gate: exit 0, 5,166 tests, zero issues)

The lead-ruled prerequisite for the agents/personas modal. `SubagentPersonaLoader`
(housed in `OpenGrokSubagentResolution`, mirroring `AgentDefinitionDiscovery`'s
conventions) loads the trust-independent base once at session build — inline
`[subagents.personas]` from the trust-gated config document plus
`$OPENGROK_HOME/personas/` and `bundled/personas/` (`agent/config.rs:2255-2263`) —
and both spawn paths (task + swarm) recompute the trusted-project overlay
(`{cwd}/.opengrok/personas/*.toml`) per spawn, feeding the merged map into
`resolveRuntimeConfig` instead of `[:]`. Relative `instructions_file` references
resolve against the PARENT session's cwd, not the task's `cwd` argument
(`handle_request.rs:296-301`, verified at the pin). Malformed persona files skip
without crashing. Resumes inherit the source's persona unconditionally before
resolution (`handle_request.rs:255-258`, verified) with identity validation so a
resume cannot silently swap SOULs; the recorded persona rides child bookkeeping. The
flagship §3 test proves disk-to-wire reachability: a persona `.toml` in an isolated
home lands its instructions on a real spawned child's captured sampler request through
real executor dispatch. 17 net-new tests.

**Delegate-found-and-fixed pre-existing §3 bug, lead-verified at the pin:** the port's
abort arm checked `personaResolutionFatal` before refusing a spawn, but upstream
aborts on ANY `persona_error` (`handle_request.rs:308-315` — "Persona resolution
failed, aborting subagent spawn"); the fatal flag only governs whether the OTHER
runtime fields still resolved. The old arm would have let a named-but-missing persona
spawn silently without its instructions — harmless while the map was `[:]`, load-bearing
the moment this slice fed it. Corrected on both paths.

**Load-bearing enumeration finding (affects b1–b3, lead-verified):** at the pin the
persona-NAME channel is dormant UPSTREAM too — the model-facing `task` input has no
persona field and `TaskTool::run` hardcodes `persona: None` (`task/mod.rs:394`, swarm
likewise `agent_swarm/mod.rs:731`); only internal spawners can name one. The feed is
exact structural parity, and in-source comments warn against "fixing" the tool schema
upstream lacks. Consequence for the modal: b1–b3 are honest immediately for storage,
resolution, and display; a persona alters a live spawn only through the internal
overrides channel until upstream adds a naming surface — the modal ships without
inventing one (§4).

### B9-b1 — the agents/personas modal, read-only (serial gate: exit 0, 5,195 tests, zero issues on rerun; flake note below)

`/config-agents` (alias `/agents`) and `/personas` (copy verbatim, verified at the pin;
registered after `/tutorial` per `mod.rs:150-153`) open a new `.agents` overlay built on
the E14 extensions-modal precedent: both tabs browsable read-only. Agents tab: the five
user-visible builtins in upstream's order (verified `:275-283`), live
`AgentDefinitionDiscovery` deduped Project>User>Bundled>BuiltIn with the
builtin-at-Project-scope rule, a NEW read-only `[subagents.toggle]` reader over a fresh
effective-config load, and the default marker from the full resolution chain
(`resolve_default_agent_name` → the shell's `resolve_agent_definition`, incl. the
strict-harness arms). Personas tab: the b0 loader's EFFECTIVE map — exactly what a
spawn resolves against — with scope tags (plus a `config` tag for inline entries
upstream has no label for), sniffed descriptions, capability tags. `Enter/o` routes
through the existing document overlay pushed OVER the modal (upstream's
viewer-over-modal layering). `i` is search on both tabs (verified `:2147,:2283` — the
editor `i` lives only in b3's detail modal). Dispatch: initial-tab, agent-view only,
mutual exclusivity with the extensions modal in BOTH directions (`transcript.rs:463-464,
500-501`). **Footer honesty:** only the read-only key set is advertised; `t/s/n/d` are
swallowed with tests pinning no-config-write and no notice — the b2/b3 deferral is
recorded at the handler heads. The delegate caught its own click-invention before
hand-off: upstream's mouse explicitly does NOT view on click (`agent_view/modals.rs:
104-108`), so no row click targets are published (click-to-select deferred with the
mouse surface). 29 net-new tests incl. live-seam proof that a real persona file and a
real project agent definition appear painted from the same data the session resolves
with.

**Recorded divergences:** no bundle-catalog column (no `x.ai/bundle/status` client —
the tab lists the effective map instead, which includes inline `[subagents.personas]`
entries upstream's own modal misses; ordering precedence-grouped vs upstream's append
order); project personas listed without a trust gate (upstream's own modal behavior —
resolution stays trust-gated per b0); prompt-extension preview uses the live
`spawn_subagent` tool naming (the port's definitions carry no per-tool kind);
selection-derived scroll (the extensions convention); append/backspace search; the
persona viewer shows raw file text pending b3's detail modal. Deferred (all cited
in-source): `t`/`s` writers (b2), `n`/`d`/create/confirm/detail modal (b3),
`EditInEditor` (b3 + the `$EDITOR` seam), the ` active` session-agent marker (no
channel — the recorded B9 ruling), mouse row handling.

**Suite flake, recorded:** the first gate run of this slice failed ONE unrelated test —
`LiveInterjectionTests` "an interjection drains into the running turn's next sampler
round and persists" — at 15.028 s (its delivery-retry deadline is 15 s), with the
interjection landing before the tool round. It passed in all 14 prior serial gates
tonight and on the immediate rerun; the b1 diff touches no interjection seam. Judged a
load flake of the test's time-boxed delivery loop on a machine nine hours into
continuous builds (the V5 telemetry-flake precedent). If it recurs, the fix is a
deterministic turn-started signal instead of the retry deadline — noted here so the
next red run starts with a diagnosis.

### B9-b2 — Agents-tab mutations: `t` toggle, `s` default (serial gate: exit 0, 5,212 tests, zero issues)

`PagerAgentsConfigStore` ports both writers faithfully (verified at the pin against
`agents_modal.rs:730-778`): `[subagents.toggle]` and `[agent] name` surgery on the USER
config.toml with upstream's `read_config_document_for_edit` guard (missing file →
empty doc; unparseable non-empty → refused untouched), table-creation arms, the clear
arm removing only `name` and leaving the emptied `[agent]` header (upstream's own
`toml_edit` residue), write-even-on-noop-clear, and every error string byte-parity.
Key semantics verified exact at `:2152-2196`: NO per-entry-kind guard (builtins toggle
like file agents; disabled entries can be default), `s` set-vs-clear compares the fresh
EXPLICIT `[agent] name` (so `s` on the resolved-fallback entry sets), both `s` success
messages quote the RE-RESOLVED default after refresh, `t` succeeds silently (the
flipped dot is the feedback), failures land as inline messages with nothing mutated —
and the port has no in-memory mirror to roll back, so modal state always states disk
(pinned by the unparseable-config failure test). Refresh parity: `t` →
in-place list rebuild from disk, collapsed, selection clamped; `s` → default re-resolve
only. Footer gains `t toggle`/`s default` on the Agents tab only. **Item-5 finding:
CLOSED — the toggle was never pixels-only.** The live spawn path already consulted
`[subagents.toggle]` (session-build read into `DefinitionResolutionContext`;
advertisement filter + resolution gate in `OpenGrokSubagentResolution`; upstream clones
the startup-resolved toggle per spawn, so takes-effect-for-new-sessions is parity).
What b2 added is the proof against the WRITER's own output: `LiveAgentsToggleSpawnGateTests`
drives the b2-written file through a real session foundation — a writer-toggled-off
`explore` refuses at real executor dispatch with the config message, and toggling all
three subagent builtins off strips `spawn_subagent` from a new session. 15 net-new
tests (+2 in updated files).

**Recorded divergences:** comments dropped on write (the port-wide config-writer
divergence, now pinned by a test at this surface — a hand-commented config.toml loses
comments on the first `t`/`s` press); `{e}` renders as Swift's error description
(prefix pinned); Ctrl-modified `t`/`s` consumed (b1-inherited); message truncation by
chars matching upstream's `chars().take(w)` rather than the port's display-width
convention. Deferred to b3: `n`/`d`, the create form, delete confirm, the persona
detail modal, `EditInEditor`.

### B9-b3 — personas CRUD, detail modal, EditInEditor (serial gate: exit 0, 5,247 tests, zero issues). **The Wave 18 B9 program is closed.**

`n` create: the inline form state machine (field cycle, scope toggle, `Name is
required` refusal), sanitization + refuse-overwrite + byte-exact template via
`PagerPersonaFileStore`, success refreshing the list with `Created persona '{stem}'`.
`d` delete: the y/n confirm machine over the canonical-path guard — verified faithful
at the pin against `config_path_is_user_or_project` (`agents_modal.rs:651-697`):
canonicalize-must-succeed FAIL-CLOSED (no canonical path = cannot validate = refuse),
any `bundled` component refuses with byte-parity copy, user-personas prefix or any
`.opengrok/personas` ancestor accepts. **The persona detail modal** (`persona_detail.rs`
ported whole): structured fields, browse machine with instructions
expand/collapse/scroll and Esc-collapses-first, INLINE EDITING landed (all three
refusal arms; `save_to_file` with empty-removes-key; fresh re-read at Enter),
close-refreshes-list on every dismissal path. **EditInEditor landed** through the
generalized `/transcript` suspend seam (`$VISUAL`→`$EDITOR`→`vi`, shlex-style parse,
child exit ignored, refresh ALWAYS — proven live by a fake editor that rewrites the
file); delegate verified at the pin that `AgentsModalOutcome::EditInEditor` has no
constructor outside the detail modal (the list-side arm is dead exhaustiveness), so
detail-only is exact parity. Every message string byte-parity, 23 strings enumerated
and pinned. Path-less inline-config personas paint their REAL resolved fields in the
detail (upstream's `from_name_only` paints name-only because its path-less rows are
catalog names; painting inline entries empty when a spawn resolves them non-empty
would be the §3 silent-drop — recorded in-source). ~34 net-new tests; the flagship
closes the b0 loop end to end: real keystrokes → exact-bytes file on disk → real
session foundation → the created persona's instructions inside the `<persona>` block
of a real spawned child's captured sampler request.

**Recorded divergences:** append/backspace text entry (b1's LineEditor simplification;
paste never reaches modal fields — the input router swallows paste while a modal is
up); comments dropped on detail save (port-wide); paint-time instructions-scroll clamp;
template byte-parity scoped to single-line values (all the form can produce), the
unreachable serialization-failure arm not carried; editor-launch failures note
in-transcript where upstream only warns (the transcript-pager precedent); `deletable`
stamped at snapshot time with the guard re-run against live disk at delete. Deferred
(recorded): form mouse paths (the B9 mouse-surface deferral), session-agent `active`
marker, bundle-catalog column.

**Wave 18 B9 is complete**: B9-a `/release-notes` (`b41cf18`); B9-c privacy — gate/ack
(`44a4908`), retention client (`0944f23`), banner (`297f3d8`); B9-b agents/personas —
live-seam feed (`7477e0d`), read-only modal (`d50ade8`), mutations (`4914d60`), CRUD +
detail (this entry). Every surface landed with working backings in dependency order;
the docs corpus's descriptions of all three surfaces are now true.

## Wave 18 B1 — dashboard and tasks surfaces (research + implementation record; CLOSED 2026-08-10)

Research at the pin, with the headline findings and lead rulings:

1. **The dashboard is the multi-agent AppView roster** (`views/dashboard/`, ~26k
   lines: state 11,182 + render 9,022 + peek 2,347 + row 2,039 + layout 1,075 +
   peek_tail 464 + mod 153): rows rebuilt every frame off `app.agents` — the
   in-process map of top-level agent tabs plus their subagents — with grouping,
   filters, pins, peek, attach, dispatch, a location picker, and the worktree
   dialog. THE architectural gap: this port's interactive controller holds ONE
   conversation; `/new`//`/resume` swap the live session in place rather than
   opening tabs, and the runtime stack (shell, tool executor, stores) tracks one
   current session.
2. **`/cd` is dashboard-ONLY** (`cd.rs:38-43`: `dashboard_only`, hidden from
   completion elsewhere; both its arms dispatch dashboard actions — the location
   picker and `DashboardChangeLocation`). It has NO ground before the dashboard
   lands and must not be registered earlier (the §4 rule).
3. **The tasks pane is grounded TODAY**: `views/tasks_pane.rs` (3,538 lines) is
   the interactive Ctrl+G overlay — four groups in fixed order (Workflows,
   Subagents, Tasks, Watchers = monitors + `/loop`, `tasks_pane.rs:178-215`),
   collapsible headers, selection, and the caller affordances in
   `agent_view/panes.rs:312-455`: Enter opens the entry's viewer / toggles a
   header, `x` kills (KillBgTask / KillSubagent / CancelScheduledTask /
   `/workflow stop <name>` — ALL four backed live in this port via the tool
   executor's bg-task store, the subagent host, the scheduler host, and the
   workflow registry, exactly the feeds `presentTasksBlock` already assembles at
   `LiveComposition.swift:10082-10116`), `y` copies a bg task's stdout, Tab
   returns to the prompt. The port's `/tasks` currently prints a static block;
   upstream's command opens the pane.
4. **`dashboard_enabled()`** (`dashboard/mod.rs:88-100`): `GROK_AGENT_DASHBOARD=0`
   env kill-switch over a persisted `[dashboard].enabled` (default true);
   minimal mode refuses `/dashboard` and its session-switch hint points at
   `/resume` instead (`:106-117`).

**Lead rulings:** (a) the program lands as **B1-t (tasks pane, the grounded
slice) → B1-m (the multi-session tab map: retained conversation states with
ACTIVE-ONLY turns) → B1-d (dashboard state/rows/render + `/dashboard` + Ctrl+\
+ peek/attach) → B1-c (`/cd` + location picker + worktree dialog, LAST — they
are dashboard affordances)**; (b) the tab-map divergence is pre-ruled: upstream
agents stream in background tabs via concurrent ACP sessions, but this port's
single runtime stack grounds only idle background tabs — dispatching to a
background tab switches to it first; the cost (no parallel top-level turns in
one process) is recorded when B1-m lands, and the subagent stack remains the
in-process parallelism story; (c) the leader bridge (other processes' sessions
in the roster) is deferred past B1-d with its own entry.

**B1-t enumeration corrections (2026-08-10, before implementation):** (1) the
port's `/tasks` read-only block is ALREADY upstream parity — `tasks.rs:1-7` is
explicit that the command "commits a read-only list; killing/attaching is out
of scope here (use the tasks pane in the full TUI)", so the D3 landing needs
no change and the pane is a separate surface. (2) The pane is a **side pane**,
not a modal: `ActionId::ToggleTasks` = Ctrl+G ("A side pane; toggle off to
reclaim width", `defaults.rs:44-55`), an `AgentPane::Tasks` focus target
coexisting with the composer (`agent_view/input.rs:1152,1230-1231`) — its
defining property is being glanceable WHILE typing. Porting it as a capturing
modal would delete that property; the honest port therefore extends the frame
model with an optional right-pane region (chrome layout width split, a third
focus target beside composer/scrollback, Tab cycling) rather than reusing the
overlay stack. The earlier ruling (c) naming the B9 modal precedent is
SUPERSEDED by this. Live-refresh divergence pre-ruled: upstream rebuilds rows
per frame off actor-free state; the port's feeds are actors, so the pane
refreshes on open, on action, and on a bounded tick while open — staleness
cost recorded when it lands.

**B1 finish-wave research (2026-08-10, three-agent Opus fan-out; reports at
/tmp/b1-reports/{peek,state,actions}.md, consolidated rulings binding):**

1. **CORRECTION — the B1-t "no clipboard channel" divergence was WRONG.** The
   OSC 52 seam exists and is LIVE: `LivePagerClipboard.copy`
   (`LiveScrollbackFocus.swift:386-394`) writes through the renderer sink, with
   two live call sites (the scrollback selection copy and `/copy`//`/export`'s
   deliver). The B1-t entry's divergence (1) is retired by this wave: the
   pane's `y` copy is being wired. What remains true and recorded: OSC 52 is
   the ONLY leg — no native pbcopy leg, no tmux-buffer leg, no
   `last-copy.txt` backup, no CopyDelivery trust classification, so a
   success toast over a terminal that ignores OSC 52 is upstream's
   "Unverified" reported as success.
2. **Dormant rows LAND.** Upstream's non-leader dashboard fills its roster
   from the on-disk session list (`dashboard_local_sessions`, activity
   `Dormant` → `Inactive` rows) — the port's `LiveSessionCatalog.list()` is
   the same feed `/resume` uses, so on-disk sessions joining the roster is
   PARITY, not invention. This grounds the `inactive` state and makes
   `Grouping::Directory` real (per-session cwds). Dormant pins persist as
   `top:<session_id>` keys — a recorded divergence from upstream's
   roster-pins-are-ephemeral rule, correct here because the port's dormant
   ids are local session ids `/resume` accepts.
3. **Slices in flight (disjoint ownership, lead integrates/commits):** peek
   band (selection-follows, no reply row/question mode/subagent peek —
   deferred with reasons in the peek report), dashboard state machinery
   (grouping/filter/pins/reorder/persistence in `[dashboard]` of
   config.toml, closing the recorded `[dashboard].enabled` gap), tasks-pane
   completions (`y` copy, Enter→viewer, `f` filter with `/` search
   deferred — a `/` with hide semantics would teach upstream's `f` meaning
   under upstream's `/` key), and close-row (`x`, lead-implemented).
4. **Deferred with reasons (the actions report, verbatim rulings):**
   dispatch-from-dashboard (requires the multi-agent map; a session-swapping
   "dispatch" would destroy the live conversation); `/cd` + location picker
   (blocked on dispatch — a landed `/cd` writes a value with zero readers,
   the `ui.screen_mode` class; slots between `dashboard` and `theme` when it
   lands); rename rows (needs an inline row editor the overlay layer lacks;
   `/rename` covers the active session); row pins WITHOUT persistence are
   the wrong half — they land WITH the persistence slice; the leader bridge
   (honest NO: no roster wire types, no `x.ai/sessions/changed`, and leader
   interactive builds a different renderer with no overlay stack).

### B1-t — the Ctrl+G tasks pane (serial gate: exit 0, 5,382 tests, 105 runs, zero issues, 2026-08-10)

Lead-implemented, the grounded first slice per the research ruling.

**What's live:** Ctrl+G toggles a full-width tasks band between the chrome and
the transcript — upstream's `ActionId::ToggleTasks` surface
(`defaults.rs:44-55`) in upstream's slot (`views/agent.rs:210-213`,
`Constraint::Length(tasks_height)`), COEXISTING with the composer: unfocused
it stays visible while typing, focused it owns the keys
(`AgentPane::Tasks` routing, `agent_view/input.rs:1152,1230-1231` — closed →
open focused; unfocused → take focus; focused → close). The pane
(`PagerTasksPane.swift` render-side, `LiveTasksPane.swift` live-side) carries
upstream's four groups in fixed order (Workflows · Subagents · Tasks ·
Watchers = monitors + `/loop`, `tasks_pane.rs:178-215`), collapsible headers,
selection preserved by row id across refreshes, the `desired_height` rule
verbatim (hidden under 12 rows; min(8, 15% of the view), `:1168-1190`), and
the caller affordances (`panes.rs:312-455`): Enter//←//→ collapse and expand
headers, `x` kills the selected entry through whichever backing owns it — a
running bg task or monitor via the session execution's owner-scoped
`killTask` (a new `LiveToolExecutor.killBackgroundTask` mirror of
`backgroundTaskSnapshots`), a running subagent via the coordinator's
`cancelSubagent`, a scheduled `/loop` via the scheduler host's `deleteTask`,
a stoppable workflow via `.runCommand("/workflow stop <name>")` — upstream's
own `SendSlashCommandPreservingDraft` shape — and Tab returns focus to the
prompt. Entries share `LivePagerTasksBlock`'s sort orders, labels, and status
vocabulary so the pane and the read-only `/tasks` block can never describe
the same task differently. `/tasks` itself is UNCHANGED — upstream's command
deliberately prints the block (`tasks.rs:1-7`).

**Recorded divergences:** (1) ~~the `y` stdout-copy affordance is NOT wired —
this port has no clipboard channel~~ **RETIRED by B1-w1 (2026-08-10): the
claim was wrong** — the OSC 52 seam exists and was already live
(`LivePagerClipboard.copy`, `LiveScrollbackFocus.swift:386-394`); the pane's
`y` copy now writes through it. (2) Refresh cadence: upstream rebuilds rows
every frame off actor-free state; the port's feeds are actors, so the pane
refreshes on open, on action, and on a 1 s tick while visible — cost: states
up to ~1 s stale, and no per-row spinner animation. (3) Enter on an ENTRY
~~is deferred with the block-viewer surface~~ **landed in B1-w1**: Enter
opens the bg task's output in the block viewer; headers toggle as upstream.
(4) The pane's filter **landed in B1-w1 as `f`** (upstream's Filter mode);
the separate `/` Search stays deferred by the finish-wave ruling — a `/`
with hide semantics would teach upstream's `f` meaning under upstream's `/`
key. (5) Minimal mode refuses the
chord quietly (upstream's Ctrl+G means external editor there; toggling state
nothing paints would be the dead-key class).

12 net-new tests: 6 state (group order + empty-group headers, collapse
toggles, kill mapping incl. the finished-entry refusal, Tab/Esc/Ctrl+G,
refresh selection re-anchor, the desired-height table) + 2 frame (the band
paints between chrome and transcript through the real renderer; a nil pane
changes nothing) + 4 builder (kind→group incl. monitors-join-watchers, kill
actions per kind with the no-copy pin, workflow sort order, block-vocabulary
status).

### B1-m + B1-d (v1) — the session tab registry and the dashboard roster (serial gate: exit 0, 5,391 tests, 105 runs, zero issues, 2026-08-10)

Lead-implemented. Two halves in one slice because the registry alone would be
dead code and the roster alone would have no rows.

**B1-m, the tab registry:** `LiveSessionTab` (sessionID · title · lastActivity)
maintained on the renderer actor at the three session boundaries — begin(),
`.sessionReplaced`, `.sessionResumed` — with the first user prompt adopted as
the roster title (upstream's first-prompt row labels) and activity stamped at
the `appendMessage` choke point. This is the pre-ruled tab divergence made
concrete: upstream's `app.agents` holds full agent tabs streaming in
background; this port's single runtime stack grounds a METADATA roster whose
background tabs are idle by construction, with attach riding `/resume`. Cost
carried from the research ruling: no parallel top-level turns in one process.

**B1-d v1, the roster:** `/dashboard` (aliases `/agents-dashboard`,
`/sessions` — the sessions-modal replacement, `dashboard.rs:34-41`) registered
at upstream's registry position (after `/rename`, `mod.rs:117-118`) with copy
verbatim, plus the two predeclared-unbound chords finally bound to their
now-existing backings: **Ctrl+G → `.toggleTasks`** and **Ctrl+\ →
`.openDashboard`** (both spellings — the raw FS byte included, the Ctrl+C
precedent), forwarded controller→renderer through the `.global` channel like
the permission-mode pair. In the same corrective pass the B1-t renderer-side
Ctrl+G intercept was REMOVED — it bypassed the predeclared controller
channel; one chord table, one seam. The overlay (`LiveDashboardOverlay`)
lists tabs active-first-then-activity with the active row's live state
(running/attached) and the ACTIVE session's subagents as indented child rows
(running-first, non-selectable — peek/attach-to-subagent are deferred
surfaces and a row that dispatches nowhere must not be selectable); Enter on
a session row rides `"/resume <id>"` — the sessions picker's exact dispatch,
so attach can never bypass the resume machinery's refusals. Gates: minimal
refuses with upstream's why-fragment verbatim ("minimal is single-session",
`dashboard.rs:55-59` over `mode_support.rs:47-51`) at the controller;
`GROK_AGENT_DASHBOARD=0` toasts and stays at the renderer
(`dashboard_enabled`, `dashboard/mod.rs:88-95`; the persisted
`[dashboard].enabled` half had no port config section in this v1 slice and was
closed later by B1-s/B1-w2).

**Historical v1 deferrals, superseded in part by the later B1-s/B1-p/B1-w
slices below (the bulk of upstream's ~26k dashboard lines):**
grouping/filters/pins, the peek panel + peek tail, dispatch-from-dashboard,
`DashboardState` persistence, the location picker + `/cd` (B1-c, dashboard-
only), the worktree dialog, rename/close row actions, the leader bridge, and
the session-switch hint banners. This paragraph records the v1 landing state;
the later subsections are authoritative about what subsequently landed and
what remains deferred.

9 net-new tests: 6 controller-seam (copy + aliases + the rename→dashboard
relative pair, dispatch + the `/sessions` alias, the minimal refusal
verbatim, both chords through the `.global` channel incl. the FS-byte
spelling, help text) + 3 roster (ordering + attach ids + active markers,
running state, children under the active row only + non-selectable). The
first gate run FAILED on the pinned `/tasks → /release-notes` relative pair —
the dashboard row was initially inserted there instead of upstream's slot —
and the fix moved it to `/rename`'s side with its own pair pinned: the
E20/E21 relative-order convention catching a real placement error.

### B1-s — the dashboard state machinery + persistence store (batch serial gate: exit 0, 5,526 tests, 105 runs, zero issues, 2026-08-10)

Agent-implemented (b1-state-impl), lead-integrated. The three finish-wave
slices (B1-s, B1-p, B1-w below) were gated as ONE batch: the full serial
suite ran green at the completed batch tree; this slice's own tree is purely
additive (nothing references the new module yet — the wiring is B1-w's).

`PagerDashboardState` is the full value model of `views/dashboard/state.rs` +
`row.rs` at the pin: the row-state vocabulary
(needs-input/working/idle/inactive/completed/failed/blocked with
`allowsDelete`, group priority, and labels), `.state`/`.directory` grouping,
row identity (`session`/`subagent(parent:child:)`/`dormant`), the filter
grammar (`a:<agent>`, `s:<state>` with `s:unknown` falling back to substring,
`#N`, bare substring), pins + manual reorder with the state-confined sort
ladder, section collapse, the two overflow rules (8 visible subagents per
cluster, idle fold ≥2 hidden with the 3600 s freshness window), stale-ref gc,
and component-wise `~` cwd compaction (`Path::strip_prefix` parity — a
`hasPrefix` port would render `/Users/mweinbach` as `~einbach` under a home
of `/Users/mw`). `PagerDashboardStore` persists it as the `[dashboard]` table
of config.toml with upstream's `top:<id>`/`sub:<parent>:<child>` key grammar,
lenient loads, the unparseable-file-preserved guard on write, and the
256-entry/1024-byte caps — closing the recorded `[dashboard].enabled` gap
(the store's `loadEnabled()` returns `Bool?` so the composition can apply
`GROK_AGENT_DASHBOARD=0` OVER the config, pinned lead-side when B1-w lands).

**Recorded divergences (each also commented in place):** the `"… N more"`
placeholder label follows `row.rs:228` over the research report's `"… N"`
transcription slip; `toggleGrouping` drops the section cursor instead of
parking it on upstream's `[+ New Agent]` button (no such button here);
placeholder rows reuse the parent's `lastChangeAt` instead of `now()`
(deterministic, and a child never sorts independently of its cluster); the
writer THROWS `.unparseableConfig` where upstream warns-and-continues (the
composition swallows it — same observable behavior, but testable); the
`pinned` array is key-string-sorted for byte-deterministic files under
Swift's per-process `Set` seeding; key length caps measure UTF-8 bytes
(Rust `str::len`); the `[dashboard.onboarding]` cleanup is omitted (the port
never wrote that key); a non-table `[dashboard]` no-ops the writer and
defaults the loader, both pinned. Directory-grouping note carried from
upstream's `sort_within_directory_groups`: cwd compares BEFORE the pin key,
so pins float within a directory, never globally.

80 net-new tests (57 state + 23 store): the sort ladder, both groupings,
the full filter grammar, overflow/fold boundaries, pin/reorder/gc, cwd
compaction edges, key-grammar round-trips, caps, lenient-load and
preserved-file guards, and the live↔persisted bridge.

### B1-p — the dashboard peek band + the list row-verb table (batch serial gate: exit 0, 5,526 tests, 105 runs, zero issues, 2026-08-10)

Agent-implemented peek (b1-peek-impl), lead-implemented row verbs;
lead-integrated into the shared render files. Render-side only — the
composition wiring is B1-w's; this tree is additive (the new
`PagerListOverlay` members default inert, so an un-wired CLI still compiles
and paints byte-identically, pinned).

**The peek band** is the port of `peek.rs` + `peek_tail.rs` + the
`layout.rs` allocation, selection-follows lifecycle (no open key — the peek
is REBUILT from the selected row on every cursor move, `render.rs:212-283`):
list-first allocation (12-row list floor, 8-row minimum live-tail box, 3/8
max fraction, 28-row live-tail cap), `desiredContentRows` never over-tapping
the tail cap, and the peek-tail densification rules — pin the last user
line, top ellipsis under the pin when truncated, PURE tail below (newest
rows win), a budget of 1 drops the omission marker rather than the content,
and a fresh user send leaves the body EMPTY until the agent streams
(`peek_tail.rs:286-318` — the rule that keeps a fresh send honest).
`PagerListOverlay` gained `peek` (rendered as a band SPLIT from the list
area in `renderCenteredModal`, list floor first) and `updateList(id:_:)` —
the in-place mutation seam whose contract is cursor+filter preservation,
because `push` resets both and would destroy the selection the peek follows.

**The row-verb table** (`rowActions`, C-1's dispatch half): a bound bare key
acts on the SELECTED row before the filter takes the character, dispatching
`<prefix>:<rowID>` through the same `.selected` channel Enter uses — the
workflows-overlay precedent generalized to lists. Guards pinned: never on a
non-selectable selection (a verb on a header/placeholder would dispatch
nowhere — the filter takes the key instead), never with modifiers, unbound
characters still filter. Recorded cost: a bound key is unavailable to
filter typing on that overlay.

**Deferred with reasons (the peek report):** the reply row + question mode
(peek-side input needs a second composer seam), subagent peek (lands with
subagent attach), and the wide-layout side-panel variant (the port's modal
is centered; the band form is the narrow-layout parity).

27 net-new tests (19 peek + 8 overlay-seam): allocation/refusal boundaries
incl. the height-20 list-first refusal, densification rules, the
byte-identical nil-peek pin, band paint placement, updateList
cursor+filter preservation, and the four row-verb dispatch guards.

### B1-w1 — pane completions, peek wiring, and the close verb (batch serial gate: exit 0, 5,526 tests, 105 runs, zero issues, 2026-08-10)

Pane halves agent-implemented (b1-pane-impl + the actions research),
peek cache agent-implemented (b1-peek-impl), close verb lead-implemented;
lead-integrated in `LiveComposition`. Remaining after this slice: B1-w2,
the roster riding B1-s's state machinery (rows/chords/persistence/dormant).

**Tasks-pane completions** (retiring/landing B1-t divergences 1, 3, 4
above): `y` copies the selected bg task's output through the live OSC 52
seam (`LivePagerClipboard.copy` into the renderer sink + flush, noting
"Copied task output — N characters."), gated `copyAction`-nil on empty
output (upstream's guard); Enter on a bg task opens the block viewer
(`.sessionInfo` push titled by the task's first non-empty command line,
splitting on `Character.isNewline` — the AGENTS.md §2 CRLF trap, pinned);
Enter on a workflow opens the workflows overlay pre-focused in detail;
`f` enters upstream's Filter mode (the bar consumes every character;
`filterQuery`/`acceptedFilter` gate all other pane arms EXCEPT Ctrl+G,
which upstream checks first — `panes.rs:318-326` — so the pane can always
be dismissed mid-filter).

**Peek wiring:** the cache (`LiveDashboardPeekCache`) is built ONCE at
`/dashboard` open from the same `LiveSessionCatalog.records()` feed
`/resume` trusts, dropped at overlay dismissal (retaining every session's
items process-long would be a leak with no reader); the selected row's peek
is rebuilt through `updateList` on every consumed key and mouse-scroll —
selection-follows, never toggled. The active row peeks the LIVE
conversation + turn activity; catalog rows peek their persisted tail;
subagent rows refuse (peek-onto-a-subagent lands with subagent attach).

**The close verb (C-1):** `x` on a roster row dispatches
`close:attach:<id>` through B1-p's verb table. The ACTIVE session refuses —
"The attached session can't be deleted from the roster — use /delete." —
because the resident-delete rule (`LiveSessionAdminACPHandlers.swift:38-43`)
owns live-actor teardown. Otherwise first press ARMS (the row's detail
becomes "press x again to delete", rebuilt in place); the port's
press-again-no-timer arm is the recorded divergence from upstream's 2 s
window (`arm_or_delete`, dispatch/dashboard.rs:2125-2140) — a different row
re-arms instead of deleting, upstream's armed-row-still-selected re-check.
The landed second-press block, quoted (destructive path, rule 5):
`armedCloseSessionID = nil; _ = try? sessionCatalog?.delete(sessionID:
target); sessionTabs.removeAll { $0.sessionID == target };
rebuildDashboardRows(); note("Deleting session…")` — with the cursor
clamped to the neighbor row by the in-place rebuild.

**Historical coverage note, retired by the cleanup hardening below:** at the
B1-w1 landing, `LiveComposition` had no deterministic renderer-construction
harness, so the glue was pinned only at its deepest pure seams. The later
`LiveDashboardReachabilityTests` constructs the real live renderer, catalog,
conversation store, overlay stack, terminal sink, and controller input stream;
the composition caveat is therefore closed at the actor/render boundary. This
still is not a shipped-binary PTY/raw-key-decoder proof, which remains a
separate evidence class.

24 net-new tests (9 CLI peek + 2 roster overlay + 9 pane state + 4 pane
builder).

### B1-w2 — the roster rides the state machinery (serial gate: exit 0, 5,536 tests, 105 runs, zero issues, 2026-08-10). **The Wave 18 B1 dashboard program is CLOSED.**

Lead-implemented over B1-s. `LiveDashboardOverlay` now builds through
`PagerDashboardState.rows → lines`: focusable section headers with true
counts and collapse chevrons (Enter/Left/Right toggle; selectable on purpose
— upstream's headers are focusables, and the port's `isHeader` forces
non-selectable), the pinned prefix with its marker, the subagent `… N more`
fold, the idle fold as a selectable toggle row, and DORMANT on-disk catalog
sessions as attachable Inactive rows (the finish-wave ruling made real:
`LiveSessionCatalog.list()` is the same feed `/resume` trusts; live ids are
skipped; untitled rows are labelled by cwd basename). Classification pins:
the ACTIVE session is Awaiting when an approval overlay is pending under
the roster, Working when the turn runs, else Idle; background tabs are IDLE
BY CONSTRUCTION — a fresher background tab still never outranks the active
Working row. `LiveSessionTab` gained `cwd`, which is what makes
`Grouping::Directory` real alongside the dormant rows' persisted cwds.

**Chords** (`handleDashboardChord`, consulted BEFORE the generic overlay
routing while the roster has focus): Ctrl+T pins the selected row, Shift+↑/↓
reorder, Left/Right collapse a focused header, Ctrl+/ (arriving as the raw
0x1F byte; the literal `/` spelling kept — the Ctrl+\ precedent) enters
search mode which live-reparses the `a:`/`s:`/`#N` grammar per keystroke,
Enter confirms KEEPING the filter, Esc/Ctrl+/ cancel clearing it, and Esc
with a confirmed filter clears the filter FIRST instead of dismissing
(`esc_clears_active_filter`, state.rs:7347). In-dashboard Ctrl+G toggles
GROUPING at the `.toggleTasks` arm (the controller owns that chord;
`defaults.rs:997-1017` scopes the dashboard binding over the global one).
The search query paints in the modal title through a new
`PagerOverlayStack.retitle` in-place seam — recorded divergence: upstream
paints a dedicated search-bar row; the port's modal has no spare chrome row,
and a live query the user cannot see would be the invisible-state class.
Cost also recorded: the roster's old fuzzy type-to-filter is OFF
(`isFilterable: false`) — the state grammar owns filtering, and
double-filtering the same keystrokes was the hazard.

**Persistence, quoted (the threading pins the store tests could not
reach):** open runs env-first then config —
`guard environment["GROK_AGENT_DASHBOARD"] != "0" else … ; guard
dashboardStore.loadEnabled() != false else …` — so the env kill-switch
beats `[dashboard].enabled` beats the default; every pin/grouping/reorder
mutation persists via `try? dashboardStore.write(dashboardState.toPersisted(
enabled: dashboardPersistedEnabled))` — the ON-DISK enabled threaded, never
a hardcoded `true`, failures swallowed (upstream warns-only). Open-time:
fresh per-open state (filter/search/collapse/idle-expand are never
persisted), `apply(persisted, resolvingAgainst:)` then `gcStaleRefs`. The
close verb now also gc's the deleted id from pins/reorder and drops the
dormant listing, and the delete's Bool is consumed honestly (a vanished
file notes "Session file was already gone." instead of pretending).

10 net-new tests (9 roster + 1 retitle): headers/ordering, both classifier
pins, dormant rows + live-id skip, directory grouping with `~` compaction,
the `s:` filter view, collapse, pinned float, the idle fold + expand, the
title's search/filter chip, the chord-side id mapping round-trips, and the
initial cursor landing on a session row rather than its header. The old
"no cheap harness" caveat is superseded by the cleanup suite below; the pure
state/overlay tests remain useful as the narrower failure-localization layer.

**Superseded by Wave 19:** the B1 finish-wave deferrals no longer stand. Retained
dispatch/replies, `/cd` + `SetWorkingDir` + Ctrl+L location selection, Ctrl+R
rename, subagent peek and completed/persisted attach, reply plus single/freeform
question handling, Ctrl+W worktree launch, Ctrl+/ search, and the typed leader
bridge are live. Remaining honest boundaries are running-subagent attach (no
durable resumable child record) and dashboard multiselect question resolution
(use the attached session view). The alleged wide side peek is not present in
the pinned Rust layout and is retired rather than implemented.

### B1 cleanup hardening — live renderer reachability (serial gate: exit 0, 5,544 tests, 105 runs, zero issues, 2026-08-10)

The technical caveat recorded in B1-w1/B1-w2 is now fixed at the strongest
deterministic seam available without launching a PTY. `LiveDashboardReachabilityTests`
constructs the production `LiveInteractiveControllerRenderer` with an isolated real
`LiveSessionCatalog`, `LiveConversationStore`, `[dashboard]` store, overlay stack, and
capturing terminal sink. Its six serialized cases prove: controller-entered
`/dashboard` plus env/config gates and dormant hydration; Ctrl+T pin persistence and
the live grouping arm; Ctrl+/ search/confirm/stepped-Esc routing; selection-following
peek paint from the dormant transcript cache; active-row delete refusal plus dormant
arm/delete; and dismissal cleanup of filter/cache/dormant state.

The destructive-path case exposed and fixed a real persistence bug: delete-time
`gcStaleRefs` removed a deleted session's pin/reorder references only in memory.
`handleDashboardClose` now persists immediately after gc, and the regression seeds
real `top:dormant-session` pin/reorder keys, deletes the real session file, and waits
for both keys to disappear from `config.toml`. The test therefore cannot pass through
an unresolvable phantom key or an in-memory-only cleanup.

Evidence boundary: this retires the live-composition reachability caveat at the real
controller/renderer actor and terminal-paint seam. It deliberately does **not** claim
binary/PTY/raw-byte decoder coverage. Controller chord forwarding remains separately
pinned by `PagerDashboardCommandTests`; the isolated real-CLI drive verifies that
`help dashboard` points users to in-pager `/dashboard` while standalone
`open-grok dashboard` continues to fail closed.

| Verification | Result |
|---|---|
| `zsh workflows/swift-safe-verify.zsh build-tests` | exit 0 |
| `zsh workflows/swift-safe-verify.zsh test --no-parallel --filter LiveDashboardReachabilityTests` | exit 0; **6 tests / 1 suite** |
| `... --filter PagerDocsCommandTests` | exit 0; **17 tests / 1 suite** |
| `... --filter PagerDashboardCommandTests` | exit 0; **6 tests / 1 suite** |
| `... --filter OpenGrokExecutableTests` | exit 0; **226 tests / 33 suites** |
| `... --filter LivePagerDocsReachabilityTests` | exit 0; **9 tests / 1 suite** |
| `... --filter SubcommandGrammarTests` | exit 0; **24 tests / 1 suite** |
| `... --filter LiveDashboardOverlayTests` | exit 0; **14 tests / 1 suite** |
| `... --filter LiveDashboardPeek` | exit 0; **9 tests / 3 suites** |
| isolated `verify-open-grok` drive: `help`, `help dashboard`, standalone `dashboard` refusal | helper doctor exit 0; help live; refusal exact and nonzero |
| `zsh workflows/swift-safe-verify.zsh test --no-parallel` | exit 0; **5,544 tests / 105 runs**, zero issues |

### B6 closure — the context-bar hover widget (serial gate: exit 0, 5,395 tests, 105 runs, zero issues, 2026-08-10). **The B6 chrome-reader program is CLOSED.**

Lead-implemented — the last B6 item (timeline rail, timestamps, and
compact_mode landed in earlier waves; the ledger's hidden-rows list was
corrected in the same pass, and the remaining 13 hidden rows stay hidden
honestly, readers still absent).

What's live: hovering the status bar's context segment swaps
`8.5K / 1.0M` for `█████ 50.0%` — the eighth-cell block progress bar plus
`fmt_pct5` — at EXACTLY the default's width, so nothing shifts under the
pointer (`context_bar.rs:182-260`: the default's ≥6-column right-pad is what
makes the invariant hold for degenerate inputs like `0 / 9`; the bar width is
the padded width minus gap+percentage). The urgency gradient colors both
forms so high usage reads without hovering (`:236-238`). Plumbing: the
segment's painted cells publish as `PagerFrameLayout.contextBar` (the
privacy-banner hit-rects pattern), the mouse-move arm flips a hover flag on
the last frame's rect with change-only repaint (a capturing overlay blocks it
like every hover), and `PagerStyledSpan` gained a per-span `background`
override (upstream spans carry their own bg; the bar's unfilled cells are the
first consumer — `paintSpans` honors it over the run background).

**Hardening past upstream, recorded:** upstream's `fmt_pct5` round-formats
99.95–99.99 to `"100.0%"` — six characters through its own `<100` arm, a
latent width-invariant break; the port clamps any over-wide result to the
`MAX %` form, pinned by a test that documents the divergence. Found by the
width-invariant test's 999,999,999/1,000,000,000 row on the first run.
Remaining B6-adjacent deferral: mouse reporting must be ON for hover to
arrive (the port's `/toggle-mouse-reporting` state), which is the existing
mouse stance, not a new gap.

4 net-new tests: the `fmt_pct5` table (upstream's rows + the ≥100 arm + the
hardening pin), the width invariant across degenerate inputs asserted on the
published rect, the in-place hover swap asserted on painted cells, and
no-data-publishes-no-rect.

## Wave 18 B2 — native scrollback, pager-minimal, screen mode, welcome (research complete, queued)

Research at the pin, with the headline corrections and lead rulings:

1. **The roadmap's "six modules" undercounted: `xai-grok-pager-minimal` is NINE modules,
   5,627 lines**, plus an 888-line pager-side read surface (`minimal/api.rs`) and a
   fn-pointer hook seam (`minimal_hook.rs` — the pager cannot depend on minimal; when
   the seam is not installed the minimal branches are inert). The minimal frontend is
   an XL program (M1–M4 below), not one roadmap line.
2. **§4 finding, the `[Opt in]` class:** the port's `screen_mode` settings row is a
   registered, restart-required row writing `ui.screen_mode` — **a key with zero
   readers** (`resolveInteractivePagerMode` consults only flags and TTY-ness); its
   description also names `/minimal`//`/fullscreen`, which are ABSENT from the
   59-command registry, and `/timeline`'s landed refusal copy tells users to "Run
   /fullscreen". Three surfaces advertise a hole.
3. **Screen-mode relaunch is a process-level `exec`, not the suspend seam** (verified:
   `Action::RelaunchInScreenMode` → quit → restore → `execv` with `--resume <sid>` +
   mode flag + consume-once `GROK_SCREEN_MODE`; Windows spawn-and-WAIT). The B3
   dependency is already satisfied by the landed $PAGER/$EDITOR seams — relaunch needs
   neither.
4. **The port has zero terminal-scrollback-injection capability** — its non-fullscreen
   mode is a bottom-anchored ≤12-row repainted strip; no `insert_before` analog exists
   anywhere. Upstream's `insert_before` renders off-screen and scrolls rows into the
   terminal's NATIVE scrollback (main screen, mouse capture OFF in minimal); the
   commit pipeline is print-once with mark-only-after-successful-insert.
5. **Welcome backings:** announcements live; changelog client live but no startup
   prefetch; `bulletsFromEntries` consumer-less (the B9-a marker); the welcome menu
   machinery half-exists (`PagerWelcomeMenuItem` + key handling + painters live, but
   every live push is menu-less — constructed only in tests); no hero info slot; the
   privacy banner's welcome tip slot blocked by the hero (the B9-c3 recorded
   divergence, confirmed at the landed router comment).

**Lead rulings:** (a) the four programs land as **W (welcome) → S1 (screen-mode config
reader) → N (native scrollback layer, implemented-unwired) → M1–M4 (minimal frontend)
→ S2 (`/minimal`//`/fullscreen` + exec relaunch + ModeSupport)** — S2 LAST, because
relaunching into today's degraded strip would register commands whose advertised
behavior their backing doesn't deliver; (b) native scrollback is separable and lands
as a tested terminal-core layer with no consumer (the B9-b0 precedent); (c) S1 trims
the settings-row description's `/minimal`//`/fullscreen` sentence until S2 restores it
(never advertise an absent surface); (d) W1 omits any menu row whose backing the port
lacks (checked per-row at implementation); (e) the inline-counts-as-fullscreen
ModeSupport question is ruled at S2 with the refusal-copy fix. **Deferral-anchor
bookkeeping:** the B9 welcome-menu anchor → W1; changelog prefetch/bullets/CTA →
W2 (+W3 announcement arbitration); privacy-banner welcome slot → W4. §2 traps carried
into N: CRLF segmentation (three prior byte-level bugs), synchronized-update
bracketing, the tmux clear-last artifact, and both upstream bug comments on
`set_viewport_height`.

### B2-W1 — the welcome menu goes live (serial gate: exit 0, 5,255 tests, zero issues)

The live welcome overlay now carries a real menu built per lead ruling (d), every
painted row backed end-to-end: **Resume session** (`ctrl+s`, gated on a session
catalog) → the real `/resume` picker; **Changelog** (click-only) → the cached
`CHANGELOG.md` through the same document viewer `/release-notes` uses — cache-gated
now (upstream paints it from frame one and no-ops until the fetch fills; the port has
no prefetch until W2, and a menu row that no-ops or stalls 3 s on CDN would be the §4
row — cost recorded: first-ever runs show no Changelog row until a fetch seeds the
cache; W2 closes it); **Quit** (`ctrl+q`); the compiled version painted as the hero
badge. **Omitted with citations:** New worktree (the port's only worktree verb refuses
by name — no fork-into-worktree backing), Import Claude settings (no import surface
exists), the gate-menu variant (the port never renders a pre-access welcome; no
`AuthState` model at this seam). **The load-bearing routing decision, lead-verified at
the pin:** upstream's plain-Enter arm (`app_view.rs:4104-4109`) returns `NewSession`
BEFORE any menu dispatch — keyboard Enter can never dispatch a menu row; rows go by
mouse and ctrl-chords only. The port matches: the welcome stays `capturesInput: false`,
Enter/typing fall through to the live composer (pinned both ways, incl. the
pre-existing end-to-end type-and-submit proof), and only welcome-scoped `ctrl+s`/`ctrl+q`
are intercepted. Hover selection is live (the port's any-event mouse tracking carries
`.move`). 8 net-new live-seam tests.

**Recorded divergences:** keyboard `ctrl+q` quits in one press (upstream arms
press-again confirmation via a global registry the port's controller-side `confirm()`
cannot reach from overlay state; the cost is an accidental quit of an EMPTY
pre-first-turn session — upstream's mouse quit is also immediate; a global confirmed
Quit chord is its own slice); the vscode-family `ctrl+d` hint variant omitted (the
port has no multi-marker family detector); the session picker opens as a modal over
the welcome rather than upstream's in-welcome picker (the standing `/resume` shape);
keyboard Up/Down menu nav not live (upstream's is dead behind the plain-Enter arm and
needs an unfocused-prompt state the port lacks — hover/chords/click are the live
paths, as upstream's effectively are).

**E18 test race, lead-diagnosed and fixed in the same gate:** the W1 gate's first run
failed `LiveSchedulerHostFireTests` "a due task fires through the trigger and
re-anchors its cadence" (`fires.count == 0`) — a LATENT race in the E18 test, not a
W1 or production bug: `createTask(fireImmediately: true)` with a sink installed arms a
ZERO-delay timer whose own `fireDue` hop can win the actor against the test's explicit
trigger; both paths are correct production behavior, but the assertion is on the
trigger's return. It won ~20 consecutive gates and lost once. Fixed deterministically:
the task is now due one interval out (the real-time timer sleeps ~300 wall seconds and
cannot race the synchronously-advanced injected clock); `fireImmediately` delivery
keeps its coverage in the no-sink test where no timer arms. This is the second
one-off flake in 20+ gates (the interjection deadline race was the first, still
unfixed-by-design pending recurrence); both diagnosed, neither a product bug.

### B2-W2 — changelog startup prefetch + hero info slot + CTA (serial gate: exit 0, 5,261 tests, zero issues)

**Process incident, recorded:** TWO delegate agents died on this slice — the first
silently ~5 minutes in (partial implementation left on the tree, no tests, no report),
the second by infrastructure ping-timeout mid-audit (no edits). The lead took the slice
in-house: audited every predecessor hunk against the pin, verified the load-bearing
paint/layout claims (`hero_box.rs:30-47` subtitle-hides/`right_col_height` formula,
`render_hero_changelog` `:544-588` header style + " • " bullets + width−4 budget +
`clickable.then_some(area)`, the stacked variant's centered/width≥20/"• " rules
`mod.rs:1544-1600`, `changelog_height = 2 + bullets` collapsed-on-empty `:1745-1752`,
`effective_changelog` all-or-nothing `:203-217`), and wrote the entire missing test set.
**Audit verdict: every predecessor hunk KEPT** — the implementation was faithful and
complete; what was missing was verification.

What's live: the one-shot post-auth prefetch (`event_loop.rs:1811-1816`) spawned from
`begin()` off the render path through the B9-a client (the recorded export-boundary
gate applies — a denied boundary issues zero requests and the welcome honestly has no
bullets); the `ChangelogFetched` store (markdown + `bulletsFromEntries(entries, 3)` —
the B9-a consumer-less marker is now consumed); the hero info slot's changelog arm in
both hero and stacked painters (header/blank/bullets, subtitle hidden while shown, CTA
rect published only when full notes exist — a bullets-only slot paints but is inert);
the Changelog menu row upgraded to upstream's availability rule (in-memory OR disk —
closing W1's recorded first-run gap); in-place welcome refresh on prefetch completion
with selection remapped by row id (inserting the row must not silently move a
highlight); CTA hover brightening on the change-only repaint convention. 6 net-new
live-seam tests (a URL-ROUTED test transport replaces the FIFO mock because the client
fetches md+json in parallel — scripted order would race).

**Lead-ruled divergence (in the kept code, endorsed):** post-prefetch,
`/release-notes` serves the stored in-memory result and does NOT refetch. Upstream's
prefetch comment states the intent ("so … /release-notes uses the cached result",
`event_loop.rs:1811-1812`) but its command mechanically re-runs a fresh CDN fetch
(`release_notes.rs:26`) — a 3 s stall per offline invocation — while its welcome CTA
and menu row already serve the in-memory copy. The port unifies the command on the same
store; the command additionally AWAITS an in-flight prefetch so a racing invocation is
deterministic instead of double-fetching. Cost: a changelog republished to the CDN
mid-session is not picked up that session — bounded to nil in practice because the
artifact is version-keyed and the binary's version cannot change mid-session.

### B2-W3 — the announcement arm + arbitration (serial gate: exit 0, 5,269 tests, zero issues)

**Third delegate infrastructure death today** (ping-timeout mid-implementation, after
the enumeration and most edits; no tests). Lead completed in-house per the W2 protocol:
audited every hunk against the pin — **all kept** — and wrote the two missing test
files. The two load-bearing claims lead-verified at the pin: (1) **the frame-banner
interaction**: upstream's welcome and agent views are mutually exclusive draw arms of
the same match (`app_view.rs:4914` vs `:5158`) and only the AGENT arm sizes/paints the
session banner (`:5221-5241`) — the port's landed gate suppresses the chrome banner
(paint AND the promo OSC 8 link span) while a welcome overlay is up, because the
full-screen welcome overpaints the cells but an armed link over blank cells would be a
click target for a banner not on screen (the B9-c3 rect-clearing precedent); (2) **the
hero slot selection** is upstream's `promo_cta` owner → else `first_session_announcement`
→ else the sticky random `self.announcement` pick (`app_view.rs:4937-4949`) — the port
carries the first two legs (they collapse onto the same projection the chrome banner
paints, so the hero and banner can never disagree) and DELIBERATELY OMITS the third:
its upstream feeder is the ACP settings push (`acp_handler/settings.rs:485-492`), a
seam the port lacks, and inventing a nondeterministic pick would be UX without a
ground. Cost: an info/warning-only feed shows the changelog where upstream would show a
random announcement. What's live: the announcement arm in both hero and stacked
painters (announcement CLAMPS to fit while the changelog stays all-or-nothing — with
an announcement the hero box can never be disabled, `mod.rs:3712-3732`);
click-toggles-expansion with the row published only while `truncated || expanded`
(upstream's click-site gate, so arriving at the dispatch IS the gate); the upgrade CTA
through the ONE shared button painter (`render_cta_button`, `announcements.rs:71-118` —
the chrome banner's promo row now uses the same fn, whole-or-not caption,
ellipsis-truncated label, rect-matches-painted-cells so a click can never land in a
blank margin); the CTA dispatch re-resolving the target through the live slot gate at
click time (`router.rs:1006-1018` — a critical preempting the promo between paint and
click no-ops); expand/hover state preserved across in-place welcome refreshes; a
hide/show that changes the slot swaps the OPEN welcome's arm in place. 8 net-new tests
(4 render-level: suppression, never-both arbitration, W2 fallback regression, CTA
whole-or-not; 4 live-seam: real-pipeline arbitration, empty-feed fallback,
expand round-trip asserted on the published frame HEIGHT, CTA click → captured browser
URL).

**Test-authoring note (the cumulative-sink trap bit the lead too):** the capturing sink
accumulates bytes, so `!contains` on painted text fails on any HONEST earlier frame —
the changelog arm legitimately paints before the announcements land (upstream does the
same until its fetch fills), then swaps in place. Negative assertions belong on the
CURRENT frame's published rows (or in single-frame render tests); the arbitration test
was corrected accordingly during authoring.

### B2-W4 — the privacy banner's welcome tip slot (serial gate: exit 0, 5,271 tests, zero issues). **The B2-W program is closed.**

Lead-implemented directly (three delegate deaths today made in-house the reliable
path; the slice was small over the c3 machinery). While the welcome is up, the banner
no longer paints into the chrome slot (where the hero overpainted it and the router
had to block its armed-invisible rects — the B9-c3 recorded divergence, now closed);
it paints AFTER the overlay pass into the tip slot directly above the composer,
reusing `renderPagerPrivacyBanner` + `pagerPrivacyBannerHeight` whole. Upstream's
tip-slot priority comment is carried with its ABSENT tenants recorded
(`welcome/mod.rs:2112-2137`: pending-update outranks the banner; foreign-resume only
when neither — both Wave 19; the ordering is banner-vs-nothing today, and the comment
pins that those tenants slot ABOVE this arm when they land). **The router rule** is
the slice's load-bearing change: banner rects now route when the hit is `nil` OR the
non-capturing welcome — safe because rects publish ONLY from a visible paint (the
chrome arm with no welcome, or the tip-slot arm painted OVER the welcome), so a rect
that exists is a banner the user can see; the invisible-banner click-through hazard
B9-c3's guard existed for cannot reopen, and capturing overlays still block via the
modal rule. The c3 eviction test moved to current-frame rects semantics (under W4 the
banner LEGITIMATELY paints on the welcome before a critical announcement arrives —
upstream parity — so its cumulative negative hit the W3-documented sink trap); the c3
welcome-blocks test's first arm was re-commented (its chrome-coordinate click now
lands where no banner paints — same assertion, new reason). 2 net-new live tests
(painted-and-clickable on the welcome with the real PUT + ack; capturing overlay still
blocks at the tip rects) plus the two updated c3 arms. One authoring note: this
fixture's `waitForFrame` searches RAW diff capture, so needles must be single words
("SpaceXAI") — the multi-word-needle trap, hit and fixed during authoring.

**The B2-W program is complete**: W1 welcome menu (`cf3dbb3`), W2 changelog prefetch +
info slot (`c2c90ae`), W3 announcement arbitration (`4b34f83`), W4 privacy tip slot
(this entry). All three B9 deferral anchors are absorbed; next per the lead rulings:
S1 (screen-mode config reader), then N (native scrollback layer), then M1–M4, then S2.

### B2-S1 — `[ui] screen_mode` gets its first reader (serial gate: exit 0, 5,276 tests, zero issues)

Lead-implemented. The key had a registered, restart-required settings row WRITING it
and nothing reading it — the §3-class dead key the B2 research found. Now
`resolveInteractivePagerMode` consults it through upstream's exact grammar
(`parse_screen_mode`, `screen_mode_relaunch.rs:316-328`: trimmed, case-insensitive
`minimal` / `fullscreen` / `full`, everything else — including `inline` — rejected so
config can never force Inline), threaded at BOTH launch paths (local composition and
leader launch) from the same effective-`[ui]` read the mode snapshot already used.
Precedence is upstream's: CLI flags beat config (`app/mod.rs:790-855`); the
`GROK_SCREEN_MODE` env override is deliberately NOT read yet — S2's relaunch is the
only thing that sets it, so it lands with S2 — and the legacy-pager.toml / auto-minimal
resolution legs have no port ground (recorded). **Recorded divergence (in-source):** a
configured mode off a TTY degrades to inline instead of throwing — an explicit
`--fullscreen` flag contradicting a pipe is an error worth surfacing (unchanged), but
an ambient config key set weeks ago must not break every piped run. The settings row's
"/minimal or /fullscreen" sentence is trimmed per the ruling (never advertise an
absent surface); S2 restores it verbatim when the commands land. 5 net-new tests
(grammar matrix mirroring `parse_screen_mode_values`, config-drives-default,
CLI-beats-config, off-TTY degrade, row-description pin).

**Flake observed (not S1's):** the first gate run failed once in
`ACPStdioHostTests` "initialize, session/new and prompt round-trip over real
descriptors" (`prompt_complete` notification not yet arrived — a timing race over real
descriptors under serial-suite load). Passed 4/4 in isolation and on the full rerun.
Same family as the V5 telemetry flake; root-cause pass still owed.

### B2-N — `insertBefore`, the native-scrollback injection primitive (serial gate: exit 0, 5,286 tests, zero issues)

**Scope correction on enumeration:** the research line "no `insert_before` analog
exists anywhere" was accurate for `insert_before` SPECIFICALLY — but the surrounding
inline-terminal layer (the `xai-ratatui-inline` analog: double-buffered `Terminal`,
OSC 8 link layer, `emitToScrollback`, `resizePurgeRerender`, `splitIntoLineSegments`,
`withSynchronizedOutput`, `setViewportHeight`) has existed in `OpenGrokTerminalCore`
since cycle 2, with thorough tests. N therefore landed as a gap-close, not a new
target: (1) **`Terminal.insertBefore`** — the port of
`insert_before_no_scrolling_regions` (`xai-ratatui-inline/src/terminal.rs:812-993` at
pin 650c1db7): render into an off-screen buffer, chunked screen-sized draws with
minimal scroll per round, final bottom-alignment scroll, viewport repositioned to sit
directly below the content, and the viewport clear DEFERRED to last — upstream's two
in-source reasons carried verbatim, including "there is a weird bug with tmux where a
full screen clear plus immediate scrolling causes some garbage to go into the
scrollback" (`:986-989`, the research's tmux artifact). Errors propagate, never
swallowed — the print-once commit pipeline (M1) marks an entry committed only after a
successful insert (`commit.rs:225-248`, `:335-337`). (2) **The missing upstream
regression tests**: grow-after-out-of-band-shrink (the stored-height drift bug — the
FIX was already in the cycle-2 port, which judges against `viewportArea.height`; the
pin's in-source comment is `terminal.rs:851-861`, its test `tests.rs:251-300`), the
full-height inline resize family (tracks the terminal both directions, repeatedly —
the alt-screen-unavailable stance), and small-inline-not-forced-full. Lead-verified
against the pin with no drift found: `emitToScrollback`'s byte sequence
(move/clear/content/CRLF-reserve/move/clear/flush — `scrollback.rs:15-73`), the
`diffLarge` u16-truncation-safe analog, and the `setViewportHeight` lockstep
stored-height update. 10 net-new tests: 7 `insertBefore` pins (push-down,
bottom-scroll amounts, tall-insert chunk walk with each row drawn exactly once,
clear-after-draw ORDERING — every draw and scroll precedes the deferred clear, do not
reorder — error propagation, non-inline no-op, full-height viewport) + the
out-of-band drift regression (`tests.rs:251-300`) + 2 full-height/small-inline resize
pins (`terminal.rs:1350-1434`).

**Deliberately not ported, with reasons:** the `scrolling-regions` `insert_before`
variant (upstream's pager builds WITHOUT that feature; its own comment calls the
variant "a separate (unused-by-the-pager) path left as a TODO", `terminal.rs:882-884`);
the minimal-mode commit pipeline (`xai-grok-pager-minimal/src/commit.rs` — frontier
walk, print-once display-mode stamping, capped commits with the `… N more lines`
footer, Ctrl+E re-print) which is the M1 slice's subject and consumes this primitive.
Status: **implemented-unwired** per ruling (b) — a tested terminal-core capability
with no consumer until M1-M4.

**Process incident (recorded so the anomaly is auditable):** the B2-N delegation
spawn REPORTED failure ("timeout waiting for bubble creation" — the day's fourth
delegate-infrastructure fault), so the lead implemented N in-house. The delegate had
in fact LAUNCHED despite the reported failure and worked the same tree in parallel,
building a competing new-target implementation (`Sources/OpenGrokInlineTerminal/`,
tests, `Package.swift` stanzas). It was stood down by interrupt, gave a clean
inventory (no commits, no ledger edits, no builds in flight), and its uncommitted
work was removed — audit copies kept at `/tmp/b2n-delegate-audit/`. Removal reason:
it duplicates the landed gap-close on a NEW target where the layer already lives in
`OpenGrokTerminalCore`; two inline terminals is a divergence with no upstream ground.
Separately, an unattributed commit and a duplicate B2-N ledger section (both
describing this same landed work, accurately) appeared during the same window —
consistent with a duplicated twin of the lead session (the same window produced
doubled system notifications and a doubled commit invocation on W4). The duplicate
section was folded into this one; the accidental lead commit that swept the
delegate's orphan file into history was dropped before push (audit copy kept).
Delegation stays suspended for the rest of this session, and the next session should
start by checking `git log` for unattributed commits.

### B2-M1 — the minimal-mode commit pipeline, pure (serial gate: exit 0, 5,313 tests, 105 runs, zero issues, 2026-08-10)

Lead-implemented (delegation still suspended per the B2-N incident; the next-session
`git log` audit passed clean — history matched the ledger chain and the tree was
clean). New dependency-free library target `Sources/OpenGrokMinimalScrollback/`
mirroring upstream's own design ("deliberately terminal-agnostic and unit-testable:
the actual `insert_before` call is injected as a closure", `commit.rs:4-8`). The
port of `xai-grok-pager-minimal/src/commit.rs` (604 lines) at pin 650c1db7, pure
half only:

- **`isCommittable`** (`commit.rs:92-115`): pending-user-input holds the frontier
  in EVERY turn state; an idle turn commits everything else (a stale `is_running`
  flag must not wedge — the missing-edit/stuck-spinner regression); mid-turn a
  running BgTask lifecycle block commits anyway (the flag is animation-only, and an
  async task can outlive its turn), a running agent message commits once a LATER
  block exists (the tracker provably moved past it), a running TOOL always holds,
  and the LAST entry always stays live.
- **`commitLeadingRun`** (`commit.rs:225-248`), the ONE mutating frontier walk:
  `onCommit` runs first and the entry is marked committed ONLY on `true` — a failed
  emit stops the walk with the cursor holding, for retry (print-once means a
  marked-but-unprinted block silently vanishes forever — upstream's bugbot
  regression, ported at `commit_tests.rs:313-339`).
- **`scanFrontier`** (`commit.rs:188-205`) mirrors the mutating walk through the
  ONE shared `classify` step (`commit.rs:149-169`) — the M3 viewport sizing and
  will-commit gate depend on exact agreement, and one classifier is what makes
  drift impossible.
- **Display-mode policy** (`commit.rs:122-141`): Edit → Expanded (even failed —
  diffs always full, K9; the Edit arm precedes the success check); successful
  Search/Read/ListDir/MemorySearch/IntegrationSearch → Collapsed; other/FAILED
  tools → Truncated (`commit_tests.rs:1016-1061` ported); Thinking → Collapsed iff
  the collapse-thinking toggle; else Expanded.
- **The frontier state** (`MinimalScrollbackState`): per-entry committed flags
  travel with the entry (the id-set is authoritative; the cursor only a
  lower-bound hint, `state/mod.rs:88-100`); remove-below-cursor DECREMENTS the
  cursor (clamping alone strands a shifted uncommitted entry beneath it — the
  `/resume` placeholder regression, `state/mod.rs:726-731`), `removeFrom` clamps,
  `clear` resets, `insertBlockBefore` pulls the cursor back to the insertion point
  (`state/mod.rs:676`) and debug-asserts an uncommitted anchor. The Ctrl+E expand
  ring (`state/mod.rs:1125-1149`: LIFO, stale-skip, bounded 256) rides along for
  its M2/M4 consumers.

27 net-new tests in 3 suites: 19 frontier tests ported from `commit_tests.rs`
(:46-490, every non-renderer test, table values copied not re-derived), 4
state-coherence tests (3 ported from `state/mod.rs:3228-3319`; 1 pins the
otherwise-untested expand ring against its implementation), 4 policy tests
(:996-1088 plus one covering the lookup kinds and failed-Edit arm the upstream
trio leaves implicit).

**Recorded divergences (all bookkeeping-shaped, no behavior change):** (1) the
policy takes `collapseThinking: Bool` instead of upstream's `&AppearanceConfig` —
the appearance struct is renderer territory; cost: M4 must thread the real
`minimal_collapse_thinking` toggle to this parameter, one more seam to wire. (2)
`MinimalBlock`/`MinimalScrollbackEntry` are a reduced stand-in model carrying only
what the pipeline reads (kind, success, flags, text) — upstream runs the pipeline
ON the production `ScrollbackState`; cost: M2 must define and maintain the mapping
from the port's live transcript blocks onto `MinimalToolKind`/`MinimalBlock`, and
a block kind mismapped there silently gets the wrong fold policy (the policy tests
here cannot catch a bridge bug). (3) The upstream `should_panic` committed-anchor
test (`state/mod.rs:3255-3261`) is not ported — the precondition is a debug-only
assert Swift Testing cannot observe in-process; the guarded behavior (cursor
pull-back) is pinned by the ported strand test instead. (4)
`clear_all_pending_user_input`/`has_pending_user_input` and the
`sync_pending_marks` frame hook (`commit.rs:594-600`) are NOT ported yet — their
consumer is the per-frame AgentView mark sync, which is M3/M4 territory; landing
them consumer-less now would be dead API pretending to be a seam.

**Deliberately deferred to M2 (renderer-dependent tests in `commit_tests.rs`):**
`committed_blocks_fit_desired_height` + `collapsed_thinking_commit_fits_desired_height`
(K5 height-exactness), `large_commit_is_capped_with_footer` /
`small_commit_is_not_capped` (§6.15 cap), `committed_block_uses_owning_session_cwd_for_tool_paths`,
`terminal_native_lock_paints_only_native_colors`, `committed_edit_keeps_diff_line_backgrounds`,
`only_thinking_spends_the_accent_column`, `committed_thinking_paints_a_dim_rail_in_column_zero`,
`collapsed_thinking_commit_is_one_advertised_row`, plus the production emit path
(`committed_appearance`, `minimal_renderer`, `insert_committed`/`paint_committed`,
`commit_active`, `expand_pending` — `commit.rs:250-600`). Status:
**implemented-unwired** — a tested library with no importer until M2-M4.

**Reference-clone drift, observed 2026-08-10:** `~/Projects/open-grok` (the path
recorded at the 2026-08-08 re-pin) is gone; `~/Projects/grok-build` EXISTS AGAIN
(recorded gone 2026-08-08) and holds the pin, as does a new
`~/Projects/xai-grok-build-reference`. All M1 reads went through
`git -C ~/Projects/grok-build show 650c1db7:<path>`, which stays correct
regardless of which clone's worktree moves.

### B2-M2 — the committed-block paint path (serial gate: exit 0, 5,325 tests, 105 runs, zero issues, 2026-08-10)

Lead-implemented. `Sources/OpenGrokPagerRender/PagerMinimalCommitRender.swift` —
the renderer-facing half of `commit.rs` at the pin (`committed_appearance`
:263-271, `minimal_renderer` :282-306, `insert_committed` :319-343, `insert_gap`
:348-353, `paint_committed` :361-393), consuming B2-N's `Terminal.insertBefore`
and M1's display-mode stamp.

**The load-bearing architectural difference, endorsed:** upstream must PROVE
`desired_height` equals what `render` paints (its height-fitting test family
exists because the pair can drift). The port's layout is line-based — the same
`appendMessage`/`appendToolCard` call produces both the lines and the height
(`height == lines.count`), so K5 agreement is by construction; the M2 tests pin
the PAINTER (footer, rail, flush-left, containment) instead. This is also why
the paint path lives in `OpenGrokPagerRender` beside the strip's layout
functions rather than in the minimal frontend target: committed blocks and the
M3 live tail must wrap through the SAME functions or a block's height flips as
it crosses the frontier and the prompt jumps (`commit.rs:276-280`). The
`OpenGrokPagerRender → OpenGrokMinimalScrollback` edge is one-way, recorded in
the manifest.

What's live (implemented-unwired until M3/M4): the minimal committed stance
(timestamps off, flush-left with pads zeroed, motion stilled — the
`COMMITTED_TICK` analog — and the accent column reserved ONLY for non-collapsed
reasoning, `commit.rs:289-296`); the display-mode structural mapping (collapsed
reasoning = one header row + the fit-gated dim `(ctrl+e to expand)` affordance,
`thinking.rs:21-50`; expanded reasoning = FULL body dim+italic,
`body_dim_italic` `thinking.rs:52-71`; collapsed tool = header row; truncated
tool = the strip's head/tail preview; expanded tool = whole output — the cap is
the footer's job); the capped insert with the
`… N more lines — /transcript to view` footer (hidden = full − (cap − 1),
`commit.rs:378-391`) whose kept rows are byte-identical to an uncapped commit
because one layout produced both; error PROPAGATION out of `insertCommitted`
(print-once: the walk must leave a failed entry uncommitted); the flat `.reset`
background with line-carried bands (user prompt) kept. Two defaulted escape
hatches were added to the SHARED layout functions (`appendThinking
bodyBudget: Int?` — nil = full body; `toolPreviewRows unbounded:`) — strip
callers keep the defaults, and the full-suite gate pins that strip behavior is
unchanged. Upstream's `minimal_max_commit_rows` default is 2000
(`appearance/config.rs:1446`) — recorded here for M4's config wiring.

12 net-new tests: 9 paint-path (cap footer `commit_tests.rs:709-747`, uncapped
:749-778, K5 containment adapted from :498-538, accent-column rules :853-930,
dim rail :932-994, one-row collapsed header + hint :1090-1140, full-body K9,
tool mode mapping, native background) and 3 live-seam (committed text reaches
the terminal through the real `insertBefore`; the cap bounds what lands and the
footer is the last committed row; a failed backend draw THROWS out of
`insertCommitted`).

**Recorded divergences:** (1) the thinking rail covers BODY rows only — the
port's landed strip stance puts a `◆` bullet on the header where upstream rails
every row; adopting upstream's full-block rail would fork the port's own
thinking look across modes. Cost: one fewer rail cell per committed reasoning
block. (2) The expand hint renders `(ctrl+e to expand)` appended dim to the
header (upstream's exact copy and fit-gate), but the port hard-codes the chord
label exactly as upstream's TODO does (`thinking.rs:17-20`) — a remapped chord
would advertise the wrong key there too. (3) Three upstream tests have NO port
ground, deliberately not ported: `committed_block_uses_owning_session_cwd_for_tool_paths`
(the port's tool-card `input` is preformatted by the live producer; no
cwd-eliding at this layer), `terminal_native_lock_paints_only_native_colors`
(the port has no terminal-native palette lock; color reduction happens at the
encoder, `PagerTerminalRenderer.sixteenColorCode`), and
`committed_edit_keeps_diff_line_backgrounds` (the port's cards render output as
text — no per-line diff backgrounds exist anywhere in the strip; if diff-hunk
rendering ever lands, that test lands with it). (4) `insert_gap` failures are
swallowed as upstream's are (`let _ =`, `commit.rs:352`) — a lost cosmetic
blank row must not strand a block that DID print.

### B2-M3 — the live tail + the overlay host's viewport sizing (serial gate: exit 0, 5,336 tests, 105 runs, zero issues, 2026-08-10)

Lead-implemented. `Sources/OpenGrokPagerRender/PagerMinimalLiveRender.swift` — the
portable core of `live.rs` (`draw_tail` :422-493, `tail_height` :732-750) and
`overlay.rs` (`sync_viewport` :143-191, `will_commit` :199-211, `content_target`
:343-358, `modal_target` :125-132, `app_modal_target` :110-112) at the pin. The
AppView-owned frame composition around them (status row via the turn-status
widget, prompt widget, todo//btw panels, dropdown/modal rendering,
`draw_live`'s layout walk) is M4's frame program; the sizing math takes those
chrome heights as parameters.

What's live (implemented-unwired): **`MinimalTranscript`** — the frontier state
bound to renderable payloads (`PagerConversationItem` keyed by the state's
entry ids), with the classification derivation the pure model needs
(role→block, tool-kind→`MinimalToolKind` with `create` folded into the edit
family, failed/cancelled→error) and a pinned explicit-block override for
BgTask lifecycle cards (the item model cannot express them; without the
override a started task gates on `isRunning` and wedges the frontier);
**`tailHeight`** — the POST-commit tail measured with exactly the M2 committed
constructor (sizing to the post-commit tail before the commit runs is the fix
for upstream's "snaps to top" bug, `live.rs:725-731`); **`drawTail`** —
bottom-anchored, top-clipped, starting at the shared `scanFrontier` stop;
**`willCommit`** with the app-modal hold parameter; **`syncViewport`** with
upstream's two resize paths (pre-commit: area-height-only, keep the top, no
clear/scroll — `insertBefore` owns those; otherwise: `setViewportHeight`,
top-fixed, growing downward, result discarded exactly as upstream discards it
at `overlay.rs:189`); and the three sizing functions with upstream's floors
and ceilings. Constants recorded for M4: `minimal_live_rows` default 10
(`config.rs:1445`), `MINIMAL_APP_MODAL_ROWS` 18.

11 net-new tests: classification mapping + pinned-override + payload sync (3,
port-specific — upstream's state entries ARE its render blocks so it needs no
mapping tests), frontier-mirroring tail height including the
released-agent-message + held-tool interplay, measure/draw row-for-row
agreement (the port's analog of upstream's
`the_animation_tick_never_changes_a_blocks_height` — one constructor on both
sides makes a tick parameter nonexistent rather than merely equal),
bottom-anchor clipping, willCommit + hold, steady-state no-op, the
pre-commit resize (top kept, zero scroll at the screen bottom), the overlay
resize (grows in place, scrolls only on bottom overflow), and the three
sizing tables.

**Recorded divergences / deferrals:** (1)
`tail_height_uses_owning_session_cwd_for_tool_paths` (live.rs:778-816) not
ported — same no-ground as M2's cwd test (tool-card input is preformatted; no
cwd eliding at this layer). (2) The status row
(`render_minimal_status`/`render_idle_hint` with the `/fullscreen to go back`
arms), `render_prompt_info`, `minimal_pending_hint`, the btw-geometry guards,
and `compute_target`'s agent-state reads land with M4 — they are AppView
composition, and several of their surfaces (the `/fullscreen` copy!) are
S2-gated: advertising it before the command exists is exactly what ruling (a)
forbids. (3) `MinimalTranscript.updateItem` on an id removed by rewind is an
honest `false` no-op (upstream mutates through `get_by_id_mut`, same shape).

### B2-M4 — the minimal frontend program, LIVE (serial gate: exit 0, 5,347 tests, 105 runs, zero issues, 2026-08-10)

Lead-implemented. Minimal mode is now **live**: `resolveInteractivePagerMode`'s
`.minimal` (the root `--minimal` flag and S1's `[ui] screen_mode` reader) reaches
the real scrollback-native frontend instead of degrading to the ≤12-row inline
strip. Three pieces:

**`PagerMinimalFrameHost`** (`Sources/OpenGrokPagerRender/`) — the port of
`lib.rs::draw` (:91-108) with upstream's exact frame order: synchronized update
+ size adoption FIRST (a block finalizing on a resize frame would otherwise
print at the stale width and the shrink would hard-wrap the print-once copy
forever, `lib.rs:71-90`), pending-mark + transcript sync once up front, the
welcome card, the POST-commit viewport sizing, the commit pass, the live region
(tail · completions · status · composer). Plus the `welcome.rs` card (:28-143 —
border + title/version/cwd/model/hint; the pending flag clears only after the
insert SUCCEEDS, upstream's bugbot; armed only for a fresh session — a resumed
transcript replays into scrollback instead per `commit.rs:400-406`) and
`MinimalSinkBackend`, the ANSI `TerminalBackend` over the pager sink that lets
B2-N's `Terminal` drive the live byte stream (`appendLines` scrolls with
newlines at the bottom row — the portable scroll that pushes rows into NATIVE
scrollback, which is the mode's entire point; `\e[S` would discard them).

**The composition wiring** (`LiveComposition.swift`) — the actor constructs the
host when the session resolves `.minimal` and routes `renderState`//resize//
restore//suspend//resume through it; `renderer` is never `start()`ed (no alt
screen, no mouse capture — the `guard.rs` stance); the full-screen welcome
overlay is not pushed (the card replaces it, `welcome.rs:3-8`); the mouse
toggle refuses honestly instead of flipping a flag no capture sequence backs.

**Overlay hosting** — overlays paint INSIDE the live viewport through the
shared `renderOverlays` with a viewport-scoped synthetic layout, and the
viewport grows to `appModalTarget` while one is open. This closed a §3-class
hole caught during the slice: a `/resume` picker would have CAPTURED INPUT
while painting nowhere (the invisible-modal "succeeds, does nothing" class) —
now pinned by a visibility test.

11 net-new live-seam tests, all asserted on the BYTES a capturing sink received
(what actually lands on the user's terminal): print-once across repeated draws;
streaming-stays-live then commits once (the diff-flush honest-still-frame
lesson: a mutation reaching the terminal is the live/frozen discriminator, not
repaint counts); the card once + above the first block + absent on resume; no
alt-screen//mouse-capture bytes ever; the permission hold (mutations reach the
terminal while held — a committed block could never change — and resolution
releases exactly one commit); the app-modal commit hold + deferred flush;
failed-write retry; rewind still commits what follows; picker visibility; and
the K6 guard (`guard.rs:13-45`): minimal's sources never name
`resizePurgeRerender`//`emitToScrollback`, `#filePath`-anchored.

**Recorded divergences / deferrals:** (1) the live region keeps the port's
themed painters (`renderComposer`//`renderTurnStatus`//`renderCompletions`,
bgBase-filled rows) rather than upstream's flat terminal-native live stance —
committed scrollback IS flat (`.reset`); cost: the pinned band reads visually
distinct from committed history; reusing the landed painters beats forking flat
variants of all three. (2) Frame coalescing is the renderer's; the host paints
per event (the frontier makes the heavy rows print-once, and still frames
diff to zero bytes); cost: more small writes per second than the coalesced
path under streaming. (3) `turnRunning` is derived from
`state.turnStatus != nil` (the frame model has no explicit turn flag); cost:
a status row shown while idle would briefly hold the last entry live — the
idle-commits relaxation covers the converse. (4) The pending mark targets the
LAST running tool while a permission/question overlay is up (the frame model
does not link prompts to tool entries); cost: a prompt for an EARLIER parallel
tool would hold the wrong entry — single-tool-at-a-time turns make this
unobservable today. (5) Deferred with their upstream modules: the todo panel
(`todo.rs`), `/btw` (`live.rs` btw arms), the below-prompt list panels
(`panel.rs`), plan commit (`plan.rs`), the transcript pump (`full_view.rs`),
the pre-session auth arm (`auth.rs`), the Ctrl+E expand chord + `expand_pending`
driver (the ring and re-print machinery are landed; the chord is an input-seam
slice), rich idle-watcher status arms, and the status row's `/fullscreen to go
back` copy — S2-gated by ruling (a). (6) `PagerConversationUI`'s
`PagerConversationRow` model remains consumer-less (predates this wave;
unchanged). (7) Bottom-sheet prompts size under `appModalTarget` rather than
upstream's `modal_target` tail-reservation math; cost: a very tall held-tool
diff can clip sooner — `drawTail` bottom-anchors what fits.

### B2-S2 — `/minimal`, `/fullscreen`, the exec relaunch (serial gate: exit 0, 5,364 tests, 105 runs, zero issues, 2026-08-10). **The Wave 18 B2 program is CLOSED.**

Lead-implemented, the deliberately-last slice of ruling (a) — everything it
advertises now exists.

**The commands** (`OpenGrokPagerInteractiveController`): `/minimal` and
`/fullscreen` (alias `/full`), registered in upstream's context→model
neighborhood with `screen_mode_switch.rs:36-60` copy verbatim, dispatched at
the controller seam with the ModeSupport gate (`mode_support.rs:30-57`):
AlreadyInMode refusals byte-exact ("You're already in minimal mode."), the
no-session error (`:76-80`), and on acceptance the
`.relaunchInScreenMode(minimal:sessionID:)` event followed by `.quit` — the
port of the router's stash + `Effect::Quit` (`router.rs:199-209`). Added to
`helpText` in the same edit (the D1 registered-but-invisible lesson).

**The relaunch** (`Sources/OpenGrokCLI/LiveScreenModeRelaunch.swift` + the
`waitForExit` hook): after the loop ends and the terminal is restored, the
composition shuts the session stack down and `execv`s the same binary —
argv rebuilt per `build_screen_mode_relaunch_args` (`:85-194`: prior
mode/session/one-shot flags stripped with their values, `=` forms included,
the bare prompt and everything after `--` dropped, kept flags carrying their
value tokens, then `--resume <sid>` + the mode flag), the banner
"Reopening session in … (switch back with …)" on stderr, and the
consume-once `GROK_SCREEN_MODE` env set for the child. On exec failure the
pasteable resume hint prints (`:206-214`). The env override is read AND
REMOVED at startup (`take_screen_mode_env_override`, `:330-354` — children
must never inherit a forced mode) and WINS over CLI flags and config in
`resolveInteractivePagerMode` — a preserved `--no-alt-screen` or an opposite
config key cannot fight the relaunch; off a TTY it degrades to inline like
the S1 config arm. Both launch paths (local + leader) consume it.

**The rulings, recorded:** (1) inline-counts-as-fullscreen is upstream's
line for its inline (the full layout); THIS port's `.inline` is a degraded
≤12-row strip, so the switchers gate on mode IDENTITY — from inline, BOTH
relaunch (upstream would refuse `/fullscreen` as AlreadyInMode there). Cost:
an explicit `--no-alt-screen` user can `/fullscreen` into the alt screen
they opted out of — by name, which is upstream's own env-override rationale
(`screen_mode_relaunch.rs:337-341`). (2) `/timeline`'s gate stays
capability-true (`mode == .fullScreen`): the port's inline render gate keeps
the rail out of the strip (`showTimeline: mode == .fullScreen`), so an
inline toggle would be the dead-key class — and its refusal's `/fullscreen`
remedy is now REAL from both refused modes. (3) The registry rows list in
every mode (no mode-visibility channel on `PagerCommandDefinition` — the
`/timeline` precedent) where upstream hides each in its own mode; the
dispatch refuses honestly instead. (4) The value-taking-flag classification
is hand-maintained (the port's parser is a switch, no clap table to derive
from) and pinned by the argv tests — upstream's drift warning carried as
the test's reason. (5) Windows spawn-and-WAIT exec emulation
(`:249-291`) not ported — macOS/Linux `execv` only, consistent with the
port's standing Windows-IPC gaps.

17 net-new tests: 7 controller-seam (registry copy/order verbatim, both
relaunch directions, both AlreadyInMode refusals, the inline ruling both
ways, no-session, help text) and 10 CLI-side (6 argv-rebuild table rows
ported from `:400-914`'s shapes, consume-once env removal incl. the
unparseable case, env-beats-flags/config + garbage-falls-through +
off-TTY-degrade, the hint and banner strings). The S1 settings-row pin was
updated from asserting the trimmed sentence to asserting the restored one.

**The B2 program is closed. Three-surface re-audit** (the surfaces the B2
research found advertising a hole, quoted from the landed tree):

1. The settings row (`PagerSettingsRegistry.swift:507`): "How Open Grok
   opens next time: Fullscreen (default when unset) or Minimal. Writes
   [ui] screen_mode in config.toml. Restart required. Switch this session
   only with /minimal or /fullscreen." — the key has its reader (S1), the
   mode it names is real (M4), and both named commands are registered and
   dispatch (this slice). Every clause backed.
2. `/timeline`'s refusal (`LiveComposition.swift:9488`): "/timeline isn't
   available in minimal mode (the timeline rail needs the interactive
   scrollback pane). Run /fullscreen to switch this session." —
   `/fullscreen` exists and, from minimal, relaunches. The remedy is
   actionable.
3. `[ui] screen_mode` — written by the settings row, read by
   `resolveInteractivePagerMode` (S1), overridden only by the consume-once
   relaunch env (this slice), and `.minimal` now reaches the real
   scrollback-native frontend (M4). No dead key, no dead value.

**B2 final state:** W1-W4 (welcome program), S1 (config reader), N
(insertBefore), M1 (pure commit pipeline), M2 (paint path), M3 (live tail +
viewport sizing), M4 (the live minimal frontend), S2 (switchers + relaunch).
Deferred remainders at the B2 close, all recorded in their slices: the
todo//btw//panel//plan//full_view//auth minimal modules, the Ctrl+E chord (closed
immediately below), the flat live-region stance, upstream's renderer-dependent
tests with no port ground, and the Windows exec emulation.

### B2 follow-up — `/expand` + the minimal Ctrl+E chord (serial gate: exit 0, 5,370 tests, 105 runs, zero issues, 2026-08-10)

Lead-implemented — the smallest recorded B2 remainder, closed first because the
expand ring was landed machinery with no consumer (the "implemented-unwired"
middle case §7 warns about, one notch from a dead affordance: the committed
collapsed header ADVERTISES "(ctrl+e to expand)" since M2, and until this slice
the chord did nothing).

What's live: `/expand` registered with `expand.rs:19-33` copy verbatim in
upstream's transcript→context neighborhood, dispatched with the
`ModeSupport::MinimalOnly(UseInstead)` refusal byte-exact
(`mode_support.rs:52-56` — outside minimal the fold is a live scrollback
affordance, so the remedy names Tab + →, not the mode switch); the Ctrl+E
chord intercepted in the input pump BEFORE the composer, gated on the
session-fixed minimal mode (`minimal_key_intercept`, `app_view.rs:4750-4777` +
the `:3261` is_minimal gate), riding the same `/expand` command signal so one
dispatch owns the ring; `PagerMinimalFrameHost.expandMostRecentFolded`
(`minimal_expand_last`, `app_view.rs:4697-4712`) popping the ring into a
pending queue drained after the commit pass in upstream's frame order
(`lib.rs:105-106`) — UNCAPPED re-prints (`commit.rs:513-517`: re-capping just
reprints the same footer), held whole under a centered overlay
(`:534-539`), requeued past a failed write, stale ids skipped.

6 net-new tests: 5 controller-seam (registry copy + position, minimal
dispatch, the UseInstead refusal verbatim, Ctrl+E-rides-the-dispatch, and
Ctrl+E-stays-with-the-composer outside minimal — the chord is the editor's
readline end-of-line there, `EditorKeys.swift:37`) and 1 host live-seam (a
collapsed search commit hides its output; expand re-prints EVERY folded row
once; the consumed ring re-prints nothing). Cost carried from upstream: the
composer's Ctrl+E end-of-line is unavailable in minimal (Home/End remain).

### R4 + R4b + R5 — Fireworks pacing gate, curated Kimi entries, reconcile ruling (serial gate: exit 0, 5,057 tests, zero issues). **The `.58` re-pin wave is closed.**

**R4** (`Sources/OpenGrokSampler/FireworksRequestGate.swift` + the client threading):
the process-global 2-permit Fireworks pacing gate, ported from the `.58` delta with
every upstream site enumerated at the pin — only the Chat Completions family acquires
(`client.rs:1878,1937`; `create_response*`/`create_message*`/web-search/compaction
bypass, exactly as upstream leaves them ungated), every non-Fireworks provider bypasses
without touching the gate (`client.rs:70-83`), a permit covers one wire attempt (retry
loops live above the client and re-enter), and on the streaming path the permit lives
exactly as long as the stream — released once by the `AsyncStream` termination handler
on drain, mid-stream cancel, or unconsumed drop (upstream's move-into-the-stream-closure,
`client.rs:2097-2100`), with the pre-stream error path releasing in a `catch` and the
two sites kept safe together by an exactly-once guard plus a `deinit` RAII backstop.
The semaphore is an actor with FIFO direct-handoff (release hands to the head waiter,
so a late arriver can never overtake), four mutually exclusive continuation-resume
sites, an intent registry that makes cancel-after-grant a no-op, a
cancelled-before-suspension marker for the cancel-first ordering, and an over-release
`precondition` (tokio's add-beyond-max panic). A cancelled parked waiter throws
`CancellationError`, consumes no permit, and leaves the queue. Lead-reviewed line by
line: the `enqueueWaiter` re-check for a release interleaving before the continuation
reaches the actor is load-bearing (every `await` entering the continuation is an actor
suspension point). Kept divergences: an internal settable gate on the client as a test
seam (the process global would race parallel suites; production never reassigns),
explicit release + backstop instead of pure RAII, and `postSSE`'s `permit: nil` default
(what keeps Responses/Messages bypassing). Note for future suite triage: the gate is
live process-wide, so tests issuing >2 concurrent Fireworks chat requests serialize on
it. **R4b**: both missing curated entries landed field-for-field from
`fireworks_models.rs:67-80` (verified at the pin, including upstream's own
`fireworks:`-prefixed-key inconsistency on exactly these two), inheriting the R1 effort
menu and E3 fast tier through the shared builder; an all-6 keys-order pin is the
tripwire the iterating tests lacked. 8 net-new tests across gate boundedness (observed
as parked-queue state, no timeout races), live-seam permit-held/released-on-drop through
a real `conversationStream`, bypass, failure-release, cancellation, and the curated
pins.

**R5 — lead ruling: deferral, recorded.** Upstream's `update_catalog` reconcile
(`acp/model_state.rs:151-190` at the pin) re-derives the session effort when a refresh
changes the current model and clears it when the SAME model loses effort support. The
port has no catalog-refresh→live-session reconcile seam at all — the same family as the
E3-recorded resume gap (resume restores neither model nor effort into the live
coordinator). Wiring an effort-only reconcile would be a half-seam (effort reconciles;
model identity, tier, and resume do not) — worse than the honest gap. Cost, stated
precisely: if a mid-session authoritative refresh strips effort support from the
currently selected model, the session's already-built sampling config keeps sending the
now-unsupported effort until the next model switch. Closes with the full model-state
reconcile seam whenever the E3 resume gap is taken up; this ruling adds the `.58` cite
to that record. The two audit-recorded UNPORTED items keep their standing:
`tool_calls.rs` unified-log telemetry enrichment (no unified log; the header/key
sanitization test is the part worth porting if one ever lands) and `subagent/mod.rs`
spawn-refresh reconciliation (children ride the parent sampler — E10's recorded
divergence now carries the `.58` cite `subagent/mod.rs` `reconcile_refreshed_reasoning_effort`).

## Wave 16 — Pager surfaces, first parallel worktree batch (2026-08-08)

**Parallelization incident, recorded for honesty.** This batch was the first attempt to run
implementation slices concurrently. The `best-of-n-runner` subagents did NOT get isolated
git worktrees as the lead assumed — `git worktree list` showed one tree — so three slices
(`/btw`, extensions, diagnostics) wrote the SHARED main tree at once. Their file sets were
disjoint from each other, so they did not corrupt one another, but the lead's `/btw`
commit (`1f3be45`) used `git add -A` and swept up seven in-progress diagnostics draft
files plus one extensions file. That commit stayed green because the extras were inert
(the diagnostics target was not yet in `Package.swift`; the extensions overlay compiled
unreferenced). Recovery: the lead stopped launching concurrent tree-writers, waited for
both slices to finish, and integrated on a quiescent tree with a single authoritative
serial gate. **Correction adopted:** real concurrent implementation needs verified
worktree isolation, which was not present; parallelism is now limited to read-only
research plus a single implementation track until isolation is proven.

### E14 — Extensions modal, read-only (serial gate below)

`/hooks`, `/plugins`, `/marketplace`, `/skills` (verbatim from `plugin.rs:15-106`, display
order after `/vim-mode`) plus Ctrl+L open a new tabbed `.extensions` overlay
(`PagerOverlayContent.extensions`, centered-modal sizing) fed by live snapshots: the hook
loader (`LiveHooksComposition`), skill discovery (`LiveSkills.discover`), the plugin
install registry, and session MCP connections. Read-only by design — NO mutation key is
handled or advertised (upstream's add/remove/toggle/install verbs are deferred, each
cited); Marketplace honestly defers to `open-grok plugin marketplace`; `/mcps` keeps its
existing text overlay in parallel (recorded divergence — upstream folds it into this
modal). 34 tests.

**Lead-fixed during integration (all real bugs the never-run tests exposed):**
(1) a cross-cutting shared-painter footgun — `paintSpans` (OpenGrokPagerRender.swift:1631)
BREAKS the run on the first empty-text span, so a top-level row's empty indent span
blanked the whole line (group headers, skills, plugins all invisible); the extensions
painter now omits the empty indent span. (2) Hook source labels classified the session's
`$OPENGROK_HOME` hooks dir as "Custom: {path}" — macOS `contentsOfDirectory(at:)` returns
symlink-resolved (`/private/var/…`) paths while the session home stayed `/var/…`, so no
prefix matched; `sourceLabel` now canonicalizes both sides (the AGENTS §2 process/path
footgun). (3) A live-fixture capture bug misread as a dropped character — the frame differ
correctly skipped re-emitting a cell the welcome hero had already painted there; the real
screen was always correct, and the live fixture's raw-glyph capture was replaced with a
cursor-addressed screen replay (production rendering untouched; a byte-stream seam test now
guards a genuine drop). **Flagged for a future slice:** `skillSource` carries the same raw
`hasPrefix` pattern (not yet failing).

### E15 — `OpenGrokDiagnostics` library (IMPLEMENTED-UNWIRED)

The pure `/doctor` engine as a standalone target depending only on `OpenGrokShared`
(imports neither CLI nor pager): the report model, `view`, `format_doctor`, the CLI
human/JSON formatters, the `managed_text` block engine, and the fail-closed fix engine
with all five terminal fixes (managed shell/tmux config writes under a
`SafeAbsoluteDirectory` guard — absolute, no `..`/`~`/control chars — SSH-refused,
`O_CREAT|O_EXCL` never-clobber, atomic publish + rollback). Golden byte-equality tests
ported from upstream's `view_tests`, `doctor_format_tests`, `doctor_cmd/tests`,
`fix_tests`, `managed_text/tests`. **This is LIBRARY ONLY: `/doctor` is NOT registered and
the CLIRunner stub still stands** — the command remains SKIP-ABSENT to the user until the
thin wiring slice lands. Recorded implemented-unwired per §7.

**Lead-fixed during integration:** (1) `commonmarkCodeSpan` sized the fence to the longest
backtick-FREE segment instead of the longest run of consecutive backticks (a path with one
backtick produced a 7-backtick fence); rewritten to CommonMark's actual rule. (2) the
managed-text symlink test compared against an under-canonicalized temp root
(`resolvingSymlinksInPath` left `/var/…` where the resolver's `realpath` yields
`/private/var/…`); the test's `TempDir` now uses `realpath`, matching the resolver.
Deferred pending the TUI-probe wave (injectable, `Unavailable` in standalone): XTVERSION
round-trip, kitty flag push, fullscreen evidence, notification/sandbox findings, voice.

### E16 — `/doctor` + `open-grok doctor` wired LIVE (serial gate: exit 0, 4,841 tests, zero issues)

The thin wiring the diagnostics library (E15) was split from — `/doctor` is no longer
SKIP-ABSENT. CLI: `open-grok doctor` prints the real report, `--json` emits versioned
JSON, `doctor fix` lists applicable fixes, and `doctor fix <id> --yes` applies the managed
config write — CONFIRMATION-GATED on `--yes` (verified on the built binary: refusal leaves
an isolated HOME empty; apply writes the block and is byte-idempotent on re-run), with
upstream's post-apply verification failing the command if the write landed but the finding
survives (§3). TUI: `/doctor` (+ aliases terminal-setup/check/info, upstream display order
after `/recap`) paints the report and fix list as system scrollback blocks. **Recorded
divergences:** the TUI report is standalone-evidence only (the library exposes no live
TUI-probe collectors yet — runtime probes surface honestly as Unavailable); the TUI
`fix <id>` arm is an HONEST REFUSAL pointing at `open-grok doctor fix <id> --yes` because
the port's only question seam (`PagerQuestionCoordinator`) is scoped to mid-turn tool
calls, not the idle slash path — no config write without confirmation; `doctor fix --json`
is refused at the route (upstream's clap conflict); no interactive `[y/N]` leg (no stdin
seam on `CLIStreams`, so `--yes` is the sole gate). **Lead fix:** the alias registry pin
compared registration order against the definition's sorted storage — corrected to an
order-independent set comparison (aliases carry no order).

### Verification snapshot (2026-08-08, authoritative serial gate for the batch)

| Command | Outcome |
|---|---|
| `zsh workflows/swift-safe-verify.zsh test --no-parallel` | **Exit 0 — 4,841 tests, zero recorded issues** (E14 + E15 + E16 integrated). E15's diagnostics library is now LIVE via E16. |

**Flake observed and cleared:** `ACPStdioWireGoldenTests` failed once in E16's first serial
gate (`protocolVersion not found`) and passed in isolation and on the clean re-gate — an
order-dependent process-global-ACP-state flake (same family as the recurring telemetry
flake), not a regression; E16 touched no ACP code.

## Wave 14.1 — Same-day fix batch from live use (2026-08-07)

**Scope.** The user drove the freshly built TUI and reported five defects; each was
root-caused before fixing, with per-unit full-suite gates. All units are commits on main
between the Wave 14 record and this section's verification snapshot.

### Verification snapshot (2026-08-07, authoritative serial gate)

| Command | Outcome |
|---|---|
| `zsh workflows/swift-safe-verify.zsh build` / `build-tests` | Exit 0. |
| `SWIFT_SAFE_TIMEOUT_SECONDS=1800 zsh workflows/swift-safe-verify.zsh test --no-parallel` | **Exit 0** — **4,357 tests / 634 suites**, zero recorded issues (~228 s; Wave 14's gate was 4,339 / 629). |
| `zsh workflows/verify-transcript-pager.zsh` | PROOF-OK (re-run by the turn-resilience unit post-fix). |

### Fixes

- **Interactive-surface gate** (commit 2def4c3): closes the Wave 14 review finding — see the
  amended known-limitation row under Wave 14 B4.
- **Slash dropdown on the welcome screen** (commit 0619c0d): typing `/` on a fresh session
  showed no completions; the full-screen welcome hero painted after the completions band.
  Dropdown now paints after overlays — safe because every overlay except the non-capturing
  welcome swallows keys, so no completion state can coexist with one.
- **Enter completes argument-required commands** (commit 2af55c0): port of upstream's
  `is_command_complete` gate (`prompt.rs:186-274`). Command-phase Enter accepts the
  highlighted row, sends complete commands, and completes `/effort`-style commands into the
  argument phase instead of dispatching an unknown prefix. The argument phase keeps Enter as
  plain send (typed arguments pass through as typed; the `/theme tokyonight` pin caught the
  first too-wide version of this change). `requiresArguments` derives from the usage
  grammar's `<placeholder>` markers; the derived set is pinned by name.
- **Turn failures no longer kill the TUI** (commit 1b5dd09): any failed turn used to rethrow
  as `sessionFailed` and unwind the whole run — a codex switch against a failing endpoint
  reliably took the TUI down. Now a `turnFailed` event renders upstream's "Turn failed: …"
  marker (`session_event.rs:172`), sheets resolve as on a cancel, and the queue keeps
  draining (`dispatch/prompt.rs:1399-1402`, `:1622`). PTY repro script kept under
  `scratchpad/`. Not yet ported: upstream's dedicated-modal failure classes (rate limit,
  paywall, credit 403, re-auth, context overflow) all render the generic marker.
- **Mouse pipeline pinned live** (commit db44efa): the "mouse doesn't work" report was
  investigated by instrumenting the real binary in a PTY; every layer (SGR enable, byte
  decode, translate, pump, focused-overlay hit test) verified correct, and two regression
  tests now cover the previously untested byte-chain and painted-bounds seams. The remaining
  truth behind the report: **mouse block selection is a feature gap** — upstream selects
  transcript blocks by click; this port's non-overlay clicks do nothing — and wheel scroll
  has nothing to move on a non-overflowing transcript. The gap belongs to the roadmap's
  pager-surface work.
  *Superseded 2026-08-11 by Local TUI interaction wave for left-click visible-block
  selection + X10 preservation; remaining mouse backlog is listed there.*
- **Codex request parity + boundary ordering** (commit 4167a7f): Responses bodies now send
  upstream's unconditional `store: false` + encrypted-reasoning include
  (`client.rs:2453-2462`, applied before the adapter patch so the DeepSeek/Meta strippers
  still remove them; compaction bodies excluded per their contract) — the best offline
  explanation of the live HTTP 400. The `/model` switch path is unified with the cold start
  three ways: refresh-capable codex OAuth resolver, the guarded credential-header merge
  (a catalog entry can no longer override `Authorization`/account-pinning mid-switch), and
  the endpoint ladder's env-override rung (previously dead on switch — a switched-to model
  reached a different endpoint than a started-on one; the override lookup is one shared
  helper now). Codex `web_search` gets upstream's live-access grant (`provider.rs:594-607`).
  **Hermeticity incident, recorded:** the unit's own parity test ESCAPED to the real ChatGPT
  backend under the first gate run — the dead override rung meant the fixture's mock-server
  env pin was ignored — and the real 401 body is what exposed the divergence. Mock-server
  fixtures must pin every endpoint env var a path can read (`GROK_CODEX_AUTH_BASE_URL`
  included, or an expired-token test's refresh goes live).
  The pre-first-turn "Provider boundary summary could not be persisted" wart was ordering:
  upstream marks the boundary at session open (`persistence.rs:2745-2775`); the port's lazy
  shell session now defers the sync through the runtime adapter and seeds the created record
  from the live `ExportBoundary`, guard untouched. **Open: one live-credential run** (switch
  to a codex model, observe the turn complete) to confirm the server's exact 400 cause; all
  wire pins are mock-server byte assertions plus upstream citations — no codex family exists
  under `ProtocolFixtures/`. Also recorded: remote-compaction-v2 still lacks upstream's
  `parallel_tool_calls`/`store`/`stream`/`include` set (`client.rs:2127-2140`).

### Notes

- `liveFoundationNonZDRControlKeepsOptedInTelemetryReachable` failed in two of six parallel
  runs on process-global `Telemetry.current()` state; it passes in isolation and under the
  serial gate every time. A recurring parallel-order flake, pre-existing, worth a root-cause
  slice of its own (isolate the process-global telemetry handle per test the way the
  worktree fixtures were made parallel-safe this wave).
- The Wave 14 ledger commit was amended locally after its pre-amend form reached origin; the
  divergence was resolved by a merge keeping the amended (superset) side (commit 6e0b9ea).

## Wave 14 — TUI foundation: suspend host, steering honesty, interaction gates (2026-08-07)

**Scope.** A four-explorer audit (upstream slash surface, upstream TUI foundation, port slash
liveness, port TUI internals) refreshed the B-backing map, then four serialized units landed
with per-unit full-suite gates and lead review of every diff. Reference pin unchanged at
`70002584` (audited against the clone at `650c1db7`, the recorded 2-commit drift).

### Verification snapshot (2026-08-07, authoritative serial gate)

| Command | Outcome |
|---|---|
| `zsh workflows/swift-safe-verify.zsh build` | Exit 0. |
| `zsh workflows/swift-safe-verify.zsh build-tests` | Exit 0. |
| `SWIFT_SAFE_TIMEOUT_SECONDS=1800 zsh workflows/swift-safe-verify.zsh test --no-parallel` | **Exit 0** — **4,339 tests / 629 suites**, zero recorded issues (~212 s; Wave 13 baseline was 4,262 / 614). |
| `zsh workflows/swift-safe-verify.zsh build --product open-grok` | Exit 0. |
| `zsh workflows/verify-transcript-pager.zsh` (live PTY proof) | **PROOF-OK** — the real binary, driven by expect(1) in a PTY, suspended into a recording fake `$PAGER` on `/transcript` and the child received a transcript containing the typed prompt; TUI restored and quit cleanly. |

### B3 — TUI suspend/restore host + `/transcript` (commit 0130a34)

- Port of `suspend_for_child` (`event_loop.rs:356-423`) + the `$PAGER` arm of
  `run_pending_suspends` (`event_loop.rs:739-814`). The park primitive lives inside
  `PosixTerminalInput` (the live seam runs a free-running reader; a park without an ack would
  race the pager for keystrokes); the renderer gained re-enterable `suspendToChild`/
  `resumeFromChild` with every paint path (including `scheduledFrameAt`) gated while suspended,
  because the port's motion ticker keeps ticking where upstream's blocked event loop is the
  only painter. Child wait is `terminationHandler` bridged to a continuation (§2 trap).
- Recorded divergences: single-attempt park vs upstream's retry timer; CPR probes skipped
  (absolute-position repaint recovers; cost named for inline mode); launch failures noticed
  rather than discarded (`event_loop.rs:783-786`); temp file `open-grok-transcript-<uuid>.md`.
- **Roadmap correction:** the B3 backing note "shared by in-pager `/login` … screen-mode
  relaunch" overclaims. Upstream `/login` never uses the suspend host (in-TUI OAuth/device
  code), and screen-mode switch is a full-process exec relaunch
  (`screen_mode_relaunch.rs:222-247`), not a suspension. B3's real consumers are `$PAGER`
  (landed) and `$EDITOR` (open, needs the minimal-mode composer seam).

### Steering honesty — `enter_steers`/`combine_queued_prompts` live, send-now semantics (commit 734ea31)

- The two settings rows previously persisted config nothing read (§3's exact failure mode).
  One effective-config read now seeds controller and renderer; settings-modal commits reach
  the controller through an installed snapshot sink.
- `enter_steers` corrected to upstream's cancel-and-send (`defaults.rs:627-660`): Enter
  mid-turn cancels the running turn and runs the draft next (`PromptQueue.enqueueFront`),
  ahead of queued follow-ups. The interjection buffer is `/btw`-only now.
- **Recorded divergence:** the send-now chord is unbindable — Ctrl+Enter is byte-identical to
  Enter in this decoder, Ctrl+I is Tab, Ctrl+O toggles always-approve, Ctrl+L is reserved
  (`defaults.rs:635-651`). Send-now is reachable via `enter_steers` and the empty-composer
  force-send; cost recorded at the chord table.
- The unit's live-seam test exposed a pre-existing preempt race shared with the empty-composer
  force-send: a preempted turn's dying session raced its `.cancelled` into the mailbox and the
  next drained turn adopted it, ending the run and discarding the queue. Session signals now
  carry the owning turn's generation; stale ones are ignored.
- **Ledger correction:** the Wave 13 line "queued prompts / steering … live since Wave 3"
  (L103-104) overclaimed for steering. The queue was live; mid-turn steering was
  next-prompt-buffering until this wave. E5 later closed the remaining true mid-turn
  injection gap with the live `x.ai/interject` buffer/drain seam.

### `/always-approve` (commit 83d1e39)

- Registered on the live permission toggle Ctrl+O already used (`always_approve.rs`); the live
  test asserts through the pipeline (post-toggle, a bash request prepares dispatchable), not
  just the composer chip.

### B4 — `ask_user_question` + question sheet (commit 621fc4a); plan-approval view (this wave)

- `ask_user_question` is live end to end: tool → `PagerQuestionCoordinator` (permission
  coordinator's shape) → bottom-sheet question view → answers formatted byte-identically to
  upstream `format.rs`, cancel sentence verbatim. Advertisement is composition-shaped: the
  coordinator exists only for interactive TTY launches, so headless/ACP/subagent compositions
  never see the tool (upstream's `builder.rs:819-825` gate, expressed structurally). Children
  strip it (recorded divergence from upstream's inherit-gate, `subagent/mod.rs:196-198` — the
  port's child runner has no question surface). Permission sheets outrank questions.
- Recorded divergences: sequential question-i-of-n instead of the tab strip; Esc cancels;
  reduced key grammar; **no answer timeout** — `toolset.ask_user_question.timeout_enabled`
  (PagerSettingsRegistry) is a settings row with no reader as of this wave, and the
  `--no-ask-user` kill-switch (`builder.rs:590-601`) plus `RemoteSettings` ask-user key remain
  unwired. Recorded here rather than hidden because the row predates this wave.
- Plan-approval view (commit 736ce76): `exit_plan_mode` now presents a dedicated bottom sheet
  painting the plan body (or upstream's empty-plan placeholder) with the `a`/`s`/`q` grammar.
  Approve disarms the gate; revise stays armed and returns the feedback in upstream's
  `revise_plan_message` shape; abandon *disables* plan mode with the do-not-retry message
  (`tool_calls.rs:1820-1901`, verified against the reference). `ExitPlanApprovalResult` keeps
  the dedicated view's outcomes apart from the generic-sheet fallback so a generic deny (which
  has always meant "stay in plan mode") can never fold into abandon (which disarms) — the
  fail-open is unrepresentable. Headless/ACP/subagent compositions keep the generic sheet byte
  for byte; teardown resolves as revise-with-no-feedback (stay armed, fail closed). Deferred
  and recorded: upstream's per-line commenting + approve-with-comments (needs soft interject).
- The B4 roadmap backing is now closed except the deferred commenting path.
- **Known limitation (cross-model review finding), fixed same day in Wave 14.1:** the
  coordinator gate probed stdout while the presenter needed stdin, so `open-grok < file`
  advertised `ask_user_question` with no one to answer. The launcher now constructs the
  interactive input+sink first and derives the gate from both (commit 2def4c3); the
  foundation half of the gate is pinned for both values in
  `LiveAskUserQuestionReachabilityTests`.

### Suite-health repairs the wave forced (commit 00f8d99) and infrastructure (commit 827795f)

- Two pre-existing test defects the serial gate never saw: the worktree reachability fixtures
  shared one literal path (missing `\` in an interpolation) and collided under parallel runs;
  the interactive multi-turn parity test inherited the repo checkout as its session cwd, so
  live skill discovery found the committed `.cursor/skills` and injected a "newly discovered
  skills" system item ahead of its asserted request items — it broke the moment a real skill
  landed in the repo (9afdf33). Both fixed at the root (unique paths; explicit `--cwd`).
- `workflows/swift-safe-verify.zsh` now enforces a 900 s wall-clock ceiling per invocation
  (`SWIFT_SAFE_TIMEOUT_SECONDS`, exit 124, TERM→KILL escalation, watchdog detached from the
  caller's pipes) so a wedged build cannot hold the shared lock forever.

## Wave 13 — Parity fleet: subagents live, hooks/plan-mode wired, honesty batch (2026-08-07)

**Scope.** A seven-domain read-only audit swarm (recorded in `PARITY_ROADMAP.md`) mapped the
remaining gap to full Rust parity at pin `70002584`; a 13-agent implementation fleet then
executed the roadmap's cheapest and highest-leverage slices, each in an isolated git worktree
on its own branch with a private build lock and mandatory self-tests, merged serially by the
lead. The recurring finding — libraries built and tested but constructed by nothing — drove
the keystone.

### Verification snapshot (2026-08-07, authoritative serial gate)

| Command | Outcome |
|---|---|
| `zsh workflows/swift-safe-verify.zsh build-tests` | Exit 0. |
| `zsh workflows/swift-safe-verify.zsh test --no-parallel` | **Exit 0** — 102 Swift Testing runs, **4,262 tests / 614 suites**, zero failures (non-`/tmp` checkout). Note: in a `/tmp` worktree one `OpenGrokBuildSupportTests` fixture-validator path-containment test fails on the `/tmp`↔`/private/tmp` symlink; it passes 56/56 in any real checkout, so the gate is run non-`/tmp`. |
| `zsh workflows/swift-safe-verify.zsh build --product open-grok` | Exit 0. |

### Subagent keystone — the model can spawn a subagent end-to-end

- `OpenGrokAgentCoordinator`, `OpenGrokSubagentResolution`, and the task-tool types were fully
  implemented+tested but **constructed by nothing**. Now: one coordinator per root session
  (`LiveSubagentHost`), a shell-parity child runner (own conversation/persistence, parent
  credentials, spawn/collaboration tools stripped, capability clamps, coordinator-owned
  cancel), definition resolution through `OpenGrokSubagentResolution`, and `spawn_subagent`
  advertised/gated upstream-exactly (`subagents_enabled` + non-empty roster; `builder.rs:848-896`).
  `--no-subagents` left the refuse list and is honored as the kill switch. Subagent ids are
  unified into the background-task family (`get_command_or_subagent_output`/`wait`/`kill`).
  Deferred and recorded: `agent_swarm`, the collaboration quartet/mailbox tools, foreground
  await-budget auto-backgrounding, worktree isolation, durable cross-process resume, child
  usage folding, and executor reparenting of a completed child's background tasks.
- A real parity bug the live seam exposed: the resolution module toggle-filtered on the
  *resolution* path, so a disabled subagent type read as "unknown"; upstream filters only the
  advertised roster and lets resolution find the definition for the gate to reject `.disabled`.
  Fixed and pinned.

### Live-seam closures (each was implemented-unwired or dishonest before)

- **Hook events**: the full observe table now fires at the live seam (SessionStart,
  UserPromptSubmit, PostToolUse±Failure, PermissionDenied, StopFailure, Notification,
  Pre/PostCompact, SessionEnd) — fire-and-forget, failures recorded, never on the turn's
  critical path. A new typed `.denied` tool-runtime case keeps PermissionDenied distinct from
  PostToolUseFailure. Subagent hook events deferred (they need a live subagent turn); compaction
  events wired but honestly reported as not reachable from the hermetic canned-sampler seam.
- **Plan mode**: `enter_plan_mode`/`exit_plan_mode` ported and registered on the live tool list
  with the subagent strip rule encoded; the plan tracker and a real `HunkTrackerActor` are now
  passed into the live `makeResources`, so the plan gate arms and hunk attribution records
  after successful writes (and records nothing on a denied edit). Divergence recorded: exit
  approval routes through the generic permission ask sheet until the pager's plan-approval view
  (backing B4) exists — cost named in code.
- **Always-approve / permission-mode toggle**: `Ctrl+O` / Shift+Tab now mutate the live
  permission handle (deny rules still win); the composer shows the active mode.
- **Reasoning-effort / UI at startup**: the live renderer now hydrates `[ui]` theme + vim mode
  from effective config at construction (theme previously hard-defaulted at launch); 16
  Appearance/Mouse/Editor settings rows with no live reader were hidden rather than left lying
  (listed below), matching the `show_tips` precedent.
- **Announcements**: fetch→cache spawns post-readiness (export-boundary + `remote_fetch` gated),
  the first non-hidden announcement renders as a pager banner, and `/announcements hide`
  persists across relaunch. ~~Listing overlay deliberately not registered (banner+hide is the
  shipped scope).~~ *Superseded by Wave 15 E2: the `show` arm landed with upstream's
  usage/description copy; the hide-only scope note no longer applies.* Deliberate stricter
  divergence: the Swift fetch is gated on the xAI export boundary, so a Codex session issues
  no request.
- **Launch auto-update**: a non-blocking check runs after readiness (cadence-cached, gated by
  `--no-auto-update` / `[cli] auto_update` / env kill-switches / debug builds), printing
  upstream's availability notice; never blocks or fails launch.
- **ACP extension router**: the single-handler slot is replaced by a name-indexed + prefix
  router (first-match, `methodNotFound` otherwise); `x.ai/feedback` re-registered through it.
  This is the seam the `open-grok/*/models/apply` and `x.ai/mcp/*` families plug into next.
- **xAI `x_search` replay**: the recorded Wave 12 gap is closed — xAI-dialect Responses input
  now replays `x_search_call` items (byte-parity with `x_search_call_wire_value`), Codex stays
  codex-only, DeepSeek/Meta replay nothing.
- **Honesty batch**: 16 accepted-and-ignored CLI flags now fail closed (`--no-plan`,
  `--no-ask-user`, `--todo-gate`, `--compaction-*`, `--hunk-tracker-mode`, `--storage-mode`,
  `--client-identifier`, `--installer`, `--terminal`, `--fs-read/-write`, `--force-login`,
  `--log-sampling`, `--no-wait-for-background`, `--background-wait-timeout`); memory tools are
  no longer advertised to the model when memory is disabled; background-task tools advertise
  upstream production names (`get_command_or_subagent_output` family) with short names as
  dispatch aliases; plugin marketplace update now rolls back the tree + registry on failure.

### Hidden settings rows (no live reader; un-hide when the backing lands — roadmap B6)

`page_flip_on_send`, `simple_mode`, `render_mermaid`, `max_thoughts_width`,
`show_thinking_blocks`, `group_tool_verbs`, `collapsed_edit_blocks`, `scroll_speed`,
`scroll_mode`, `scroll_lines`, `invert_scroll`, `keep_text_selection`,
`prompt_suggestions`. (`compact_mode`, `show_timestamps`, and `show_timeline` left
this list when their readers landed — rows registered, audited 2026-08-10.)
*2026-08-11 note:* `page_flip_on_send` later gained a live reader (Wave 20 follow-on
batch 2); at that date the **scroll_*** / `invert_scroll` / `keep_text_selection`
mouse-scroll settings remained hidden.
*2026-08-12 note:* `scroll_speed` / `scroll_mode` / `scroll_lines` / `invert_scroll`
left this list when Local remaining-TUI-gap follow-on landed live readers + the
Rust-style scroll-stream normalizer/acceleration.
*2026-08-12 note (sticky-header + transcript text-selection / deep-tui):*
`keep_text_selection` (`flash` | `hold` | `word_select`) left this list when live
readers + linear transcript text drag/multi-click landed. Appearance/Mouse catalog
now exposes scroll_* / `invert_scroll` / `keep_text_selection` (Mouse hidden-row
count updated accordingly). `prompt_suggestions` remains hidden until its backing
lands. Sticky-header **behavior** is default-live without a settings row —
`sticky_headers` config/settings toggle is still absent (recorded under the
sticky/text-selection honest-divergence list, not as a hidden lying row).
*2026-08-12 note (final TUI divergence closure):* `$OPENGROK_HOME/pager.toml
[scrollback.display].sticky_headers` one-shot config is now live (default true,
compact override). No env / no settings row is **upstream parity, not a gap** —
do not add a hidden lying row. Wrong-type parse diagnostic is visible; project
`pager.toml` is not authority. See **Local final TUI divergence closure**.

### Ledger corrections (stale rows every domain audit tripped over)

- The 2026-08-04 crate-inventory table labels Hooks / PluginMarketplace / ComputerHub* /
  WorkspaceClient / Update / WebMediaTools / Memory / Goals as **orphaned**; Waves 8–13 wired
  them. Those rows are superseded by this section and the per-wave records.
- The route-liveness snapshot (~L346) claiming most CLI routes throw unsupported is superseded:
  `mcp`, `sessions`, `worktree`, `workspace`, `plugin`, `update`, `workflow`, `share`, `leader`,
  `serve`, `acp`, `login`/`logout` are live (some partial, noted per wave).
- The Wave-2 "queued prompts / steering still unimplemented" line (~L1122) is superseded (live
  since Wave 3).
- `CRATE_MAP.md` row 83's proposed `OpenGrokWorkflowEngine` target does not exist and should
  not: the Rhai engine landed inside `OpenGrokWorkflow`. The legacy dual `WorkflowHost`/
  `WorkflowEngine` in that target remains a retire-candidate (roadmap Wave 19).

### Still absent / deliberately deferred (the roadmap's remaining waves)

**Corrected 2026-08-10 after the Wave 19 deferred batch** (the prior list had
again gone stale). Native scrollback + the minimal frontend, TUI suspend/restore,
in-pager `/login`, MCP OAuth + credential store/recovery/revoke, the
subagent/collaboration stack, the tasks pane, dashboard dispatch/navigation and
working-directory/rename/worktree/search actions, the typed leader roster bridge,
and the context-bar hover widget are LIVE per their wave records. Remaining B1
limits are attach to a still-running subagent and dashboard-native multiselect
question resolution; the former wide-side-peek item was not in pinned Rust.
Other remaining work: hidden settings rows above that still lack renderer readers;
voice live seam (B7); media overlays (B10); video tools; LSP;
`search_tool`/`use_tool` meta-discovery; foreign-session scan/resume; memory
embeddings + dream; auto-mode LLM permission classifier; Computer Hub MCP adapter
wiring; Code Mode V8 hard-interrupt/module-loader debt; PTY-backed
`run_terminal_cmd`; the local-workspace/chat env+flag family; relocation journal;
antigravity runner; the Wave 19 config/env long tail (`RemoteSettings` authority
allowlist, `GROK_*` env-gate table, `features.*` resolver); signed share
upload/export clients; and the standing platform/evidence gaps (capable-Linux
sandbox proof, Windows named-pipe leader IPC + S2 exec emulation, portable secure
WebSockets, Linux custom-CA installation, and post-change Linux/Windows CI plus
required-check evidence). Packed Git delta resolution, docs-helper startup wiring,
recap remote/automatic policy, MCP OAuth scope-upgrade consent, and Windows COMSPEC
launch semantics also remain. See `PARITY_ROADMAP.md` for the current long-tail list.

## Wave 12 — Meta provider catch-up, re-pin to 70002584, and fundamentals closures (2026-08-06)

**Scope.** Re-pinned the reference from `9ed09e2a` (v0.1.220-open-grok.54) to `70002584` (v0.1.220-open-grok.57): a 3-commit upstream delta adding the Meta API provider (`0f8dc87b` provider, `666b2ceb` login/settings, `70002584` Meta/Wafer stored-key unlock fix). Alongside the delta port, three fundamentals audits (TUI/animations, slash commands + completions, reasoning effort + backends) drove closures of pre-existing implemented-unwired gaps. Six implementation slices ran as a coordinated wave with disjoint ownership; the lead landed the re-pin, version bump, and fixture recapture.

### Verification snapshot (2026-08-06, authoritative serial gate)

| Command | Outcome |
|---|---|
| `zsh workflows/swift-safe-verify.zsh build` | Exit 0. |
| `zsh workflows/swift-safe-verify.zsh build-tests` | Exit 0. |
| `zsh workflows/swift-safe-verify.zsh test --no-parallel` | **Exit 0** — 102 Swift Testing runs, **4,195 tests / 602 suites**, zero failures (2026-08-06, after the wave's regression fixes and the re-pin landed). |
| `zsh workflows/swift-safe-verify.zsh build --product open-grok` | Exit 0 (verified by slice B3-CLI-2). |

### Meta provider — live end-to-end for new sessions

- **Types** (`OpenGrokSamplingTypes`): `ModelProvider.meta` (+ serde aliases `meta_ai`/`meta_api`), `ResponsesDialect.meta`, `ProviderProfile.meta` (responses-only, FunctionEnvelope, native web search, API-key-only, xAI services denied; types.rs:1349-1362). Decoder previously failed closed on `"meta"`; all switch sites were compiler-forced.
- **Models** (`OpenGrokModels`): `MetaModels.swift` ports `meta_models.rs` (curated Muse Spark catalog, `https://api.meta.ai/v1` + `OPENGROK_META_API_BASE_URL`, `META_API_KEY`, trusted-host rule, env-first/stored-on-trusted key selection, `/models` slug intersection, error redaction); `ModelCatalogPartition.meta` threaded through merge chain, `LiveCatalogRefresh`, and `ModelsManager` (fingerprint publish gate).
- **Sampler** (`OpenGrokSampler`): real `MetaProvider` (registry 7→8, between DeepSeek and OpenCodeGo), `patchMetaResponsesRequest` (drops include/prompt_cache_key/prompt_cache_retention/store, reasoning-typed input items, reasoning.summary; effort passes through unchanged, unlike DeepSeek's remap), cache-key nil, metadata no-op, normalizes-events true. Drift tests re-pinned to 8 providers.
- **CLI** (`OpenGrokCLI`/`OpenGrokProviderSession`): env + stored credential resolution for meta, endpoint constants, `--provider meta` (+ aliases), `--model meta:…` cold start proven against the mock server, meta credential fingerprint on the production snapshot.
- **Settings UI**: `meta_api_key` secret row (catalog 89→90) and a real secret-save write path (see below).

### Security-shaped closures (quoted lines live in the slice reports; landed code cited here)

- **Stored-key trusted-host restriction now enforced on the LIVE path.** Upstream's fix commit gates stored Meta/Wafer keys behind `trusted_built_in_session_endpoint` (config.rs:5430-5437). The Swift gate existed but its only live consumer was the auxiliary-model path; `LiveCredentialResolver.resolve` now takes the model's `baseURL` and withholds stored provider keys from untrusted hosts (env keys resolve unconditionally, matching `select_api_key`). Ported the resolver half of `stored_meta_and_wafer_keys_resolve_only_on_trusted_hosts` (config.rs:7409-7458). Note: the Wafer *unlock* half of upstream's fix was already correct here — the port never had that bug.
- **Raw-input replay gating** (`ConversationExtensions.swift` ~454-469): the `.codexRawInput` splice is now dialect-gated fail-closed per upstream `raw_responses_input_replacements` (conversation.rs:1614-1650) — Codex raw items replay only into the Codex dialect; DeepSeek/Meta explicitly replay nothing.
- **Secret-save write path**: the settings modal's secret rows now write/clear through the same provider-scoped store the credential resolver reads (`storeScopedAPIKey`/`clearScopedAPIKey`; upstream `store_provider_api_key`, effects/mod.rs:832-843), then refresh the credential snapshot and spawn a catalog refresh. Reset on a secret row routes to clear (the generic reset path classifies secrets `notPersistable` and would have silently swallowed it).
- **Silent provider fallback killed**: the embedded-corpus provider decode no longer coerces unknown providers to `.xai` via `try?`; unknown providers fail loud, matching upstream serde strictness.

### Fundamentals closures (from the three audits)

- **Reasoning effort now reaches the wire.** Before this wave no effort of any kind reached an outbound live request: the single live `SamplingClient` construction dropped `reasoningEffort`/`reasoningSummary`/`codexMultiAgentV2`/temperature/topP/maxCompletionTokens/contextWindow, and `--reasoning-effort` was parsed, advertised, and consumed by nothing. All are now threaded from the catalog entry through `OpenGrokLiveSamplingConfiguration` into `SamplerConfig`, with live-seam tests asserting the outbound JSON against the mock server. `/model <name> <effort>` grammar, `/effort`, and the composer effort label landed; effort presence in `SamplerConfig` doubles as the Fireworks effort-support gate (client.rs:1806-1813).
- **Request shaping upstream-exact**: base Responses `reasoning` object (always present; `max|ultra → xhigh` clamp; summary "concise"; conversation.rs:3892-3895), Codex keeps the emptied `reasoning` object, Messages projection gains `output_config`/`thinking: adaptive-summarized`/`tool_choice` (conversation.rs:5313-5352), Fireworks/Wafer `reasoning_effort` strips restored, Codex unknown-event swallow tightened to literal `unknown variant` (provider.rs:834-847).
- **Animation clock exists.** `PagerMotion.swift` was a complete, tested port of every upstream animation constant with no clock driving it. A demand-driven wall-clock ticker now runs at the controller seam (30fps/83ms-slow, event_loop.rs:3172-3189 semantics), `PagerFrameClock` coalesces paints at the 16ms min-draw interval, and the accent wave, finish flash, pending-user diamond, welcome shimmer, and background-task spinner are live at their render sites. Turn elapsed time derives from the motion clock; `tokenCount` (estimate) and context-ramp tokens feed the status renderers. The `ui.display_refresh.auto_cadence_enabled` settings row gained its reader (cadence policy); the `show_tips` row was hidden (no tips banner exists — a registered no-op row violates §4).
- **Slash suggestion engine at upstream parity**: nucleo-exact fuzzy scoring with smart case (verified against the rev grok-build pins), MRU recording/boost persisted to `slash-mru.json`, the 6-row cap removed with scrolling, curated bare-`/` order, `/theme` + `/effort` + `/export` argument completion, Esc-close and PageUp/Down paging. The invented `priority` tiebreak was removed (divergence-removal; `/q` cold now offers `queue` first like upstream).
- **New commands with verified backing**: `/resume` (session picker + runtime swap + transcript repaint; `mutatesConversationHistory`), `/usage` (alias `cost`; renders the previously-unreferenced `LiveUsageComposition.report`), `/btw`, `/mcps` (connection results previously computed then discarded are now retained), `/effort`, `/rename` (alias `title`; new stored-title write). Reachability tests dispatch each through the real controller and the live adapter.

### Regressions caught by the serial gate and fixed in-wave

- **Intermittent OpenGrokPagerTests hang** (wedged one full-suite run 18+ minutes): a cancel arriving while `OpenGrokPager.run` was between `.starting` and publishing `activeSession` was silently swallowed, leaving the run awaiting a session stream never told to stop (same hole one layer down in the forwarding frontend). Pre-existing bug exposed by the wave's new tests; both sites now latch and honor the early cancel. Verified with 900 serial contention runs, 0 hangs.
- **/effort usage error painted under the welcome overlay** (real user-facing bug found by a live-seam test): the welcome overlay blanks the whole transcript and was only dismissed at `turnStarted`, so command errors on the welcome screen never reached the terminal. All transcript appends now dismiss welcome through one helper. Cost: a notice on the welcome screen replaces the logo instead of toasting over it like upstream.
- Esc dropdown-close, shimmer rest-color, and the `/resume` deferral-flag pin were fixed by their owning slices.

### Corpus and corpus-consumer fixes

- `DefaultModelsJSON.swift` regenerated **byte-for-byte** against upstream `default_models.json` at `70002584` (13 → 20 models). The old corpus had drifted below even the previous pin (missing `fireworks:kimi-k3`, `fireworks:kimi-k3-fast`, two `deepseek:` entries) and its `web_search` default named a model absent from its own array (`grok-4.20-multi-agent`), so auxiliary web-search routing only worked via the bare-xAI fallback; it now resolves `grok-4.5` through the catalog, which the live session consumes.

### Re-pin mechanics

- `OPEN_GROK_VERSION`, the regeneration script/plugin defaults, `CompiledVersion.generated.swift`, `referencePinnedRelease`, and `referenceRevision` all moved to `.57`/`70002584`. Version-pinned tests updated.
- `ProtocolFixtures/`: all fourteen family diffs across `9ed09e2a..70002584` (including `Cargo.lock`) are empty; the only recaptures are the two release-stamped artifacts (`cli-version-and-home.json`, `crash-gcrx-format.json` + `crash-gcrx-sample.bin` restamped by same-length in-place substitution at offset 32). Every fixture's revision chain advanced; `manifest.json` sizes/hashes regenerated.

### Deliberately not done (recorded, with reasons)

- **Live-session credential rebind** after a settings-modal key save (upstream task_result.rs:1087-1300, effects/mod.rs:3602-3647, the ACP `open-grok/meta/models/apply` extension): new keys apply to new sessions and `/model` switches only; the saved-key notice says so. The whole per-provider rebind pipeline (~220 lines + effects + ACP method family) is absent for *every* provider, not just Meta.
- **`/login`/`/logout` in-pager**: not registered — xAI login blocks on a plaintext stdin read while the TUI owns fd 0 in raw mode, and Codex OAuth prints to stdout mid-flow with no TUI suspend/resume. API-key entry is covered in-TUI by the (now functional) settings secret rows. Registering OAuth rows with no working backing would violate §4.
- **Pager-minimal auth rendering**: upstream's one-line Meta delta to `pager-minimal/src/auth.rs` lands inside a pre-existing gap — the Swift target ports only the run-loop shell, not `auth.rs`/`welcome.rs`. Deferred as a whole.
- **`.idleMonitor` turn indicator**: render side exists; deliberately unproduced — this composition has no idle-watcher feed, and a guessed glyph would claim watchers that don't exist.
- **xAI/Codex halves of `spawn_background_refresh`**: not fired — the CLI catalog store has no live xAI/Codex list transport, so the call would be a refresh-shaped no-op. Meta/DeepSeek/Kimi/Fireworks/OpenCodeGo/Wafer partitions refresh post-readiness (reachability-tested).
- **`/usage` billing arms** (`show`/`manage`): absent with upstream's non-consumer error copy — no billing surface exists in the port.
- **Display-refresh probe**: *Superseded 2026-08-12 by Local remaining-TUI-gap
  follow-on:* macOS CoreGraphics probe feeds auto cadence; Linux honest skip;
  Windows unsupported. (Contemporaneous Wave 12 wording had `probedRefreshHz` nil
  / `probe_skip` default.)
- **Matcher scope**: fzf atom operators (`^ $ ! '`), diacritic folding, and highlight indices not ported (no consumer); ranked sort skips the builtin-over-plugin tiebreak (definitions carry no source tag).

### Pre-existing gaps found by this wave's audits, recorded but NOT fixed here

- **xAI `x_search` replay**: upstream replays `XSearch` history into xAI-dialect Responses requests as `x_search_call` items (conversation.rs:1627-1629, 1978-1997); the Swift builder has never done this — `.xSearch` backend items are captured from streams but never re-sent. Needs its own slice and tests.
- **Stale ledger corrections**: the wave-8 deferral line listing `/rewind` `/jump` `/delete` as unregistered (formerly at line ~621) predates their registration and is superseded by this section. `/recall`, `/flush`, and `/goal` are Swift-only rows with no upstream command-file counterpart (they map onto ported memory/goal features); recorded here as a deliberate divergence pending an upstream-parity decision.
- **Orphaned pager targets**: `OpenGrokPagerModel`/`PagerConversationUI`/`PagerOperationsUI`/`PagerRuntime` remain importer-less from `Sources/` (first recorded 2026-08-04); the animation work consumed `PagerRuntime`'s design but landed the ticker at the controller seam, so the orphan status is unchanged.
- Inline (`--no-alt-screen`) remains a 12-row bottom viewport without native scrollback; interactive `--minimal` still renders as inline; tips banner and `/context` bar renderer consumers remain absent. *2026-08-12:* scrollbar click/drag is live (Local remaining-TUI-gap follow-on); **FPS HUD / `show_fps` remains absent**.
  *Superseded later 2026-08-12 by Local final TUI divergence closure: FPS HUD live via raw `GROK_FPS` nonempty `!= 0` and `/debug fps`; `[animation].show_fps` remains parse-only because the pin also never reads it.*

## Current integration verification snapshot (2026-08-06)

| Command | Outcome |
|---|---|
| `git diff --check` | **Exit 0**. |
| `zsh workflows/swift-safe-verify.zsh build-tests` | **Exit 0**. |
| `zsh workflows/swift-safe-verify.zsh build` | **Exit 0**. |
| `zsh workflows/swift-safe-verify.zsh test --no-parallel` | **Exit 0** — 102 Swift Testing runs, **4,079 tests / 610 suites**, zero failures. |
| `zsh workflows/swift-safe-verify.zsh build --product open-grok` | **Exit 0**. |

The root verifier also fixed and reran the final integration regressions in the
performance profile, live model/provider resume path, persisted sandbox resume
path, and concurrent workflow-shape assertion before the authoritative serial
gate. The remaining Wave 11 limitations require non-macOS runtime or repository
administration evidence; none is represented as locally verified parity.

### Wave 11 audit closure — G002 (2026-08-06)

The managed required-version startup gate is now live on the shipped async
runner path. `CLIRunner.run` evaluates `LiveVersionPolicyGate.refusal` after
parsing and before `application.run`, writes the exact refusal to stderr, and
returns exit code 1 without constructing the application launcher session.
Only `.launch`, `.serve`, and `.leader` session-start families are gated;
management, inspection, and recovery routes remain reachable, matching the
Rust early-return boundary while accounting for Swift's broader async
application routing.

| Command | Outcome |
|---|---|
| `zsh workflows/swift-safe-verify.zsh test --no-parallel --filter OpenGrokExecutableTests` | **Exit 0** — reported **203 tests / 31 suites**, including the new below-floor, above-ceiling, in-range, and management/recovery exemption cases. |
| `zsh workflows/swift-safe-verify.zsh build --product open-grok` | **Exit 0** — shipped product path compiles. |

### Wave 11 audit closure — G005 (2026-08-06)

Skills are now reachable from the live launch composition. Session foundation
discovery uses the resolved `cwd` and environment, reserves every active pager
builtin before building one effective catalog, registers that catalog in the
interactive controller, injects the model-facing `<agent_skills>` listing, and
expands `/skill args` into `<skill_information>` before the sampler turn. ACP
prompt sessions advertise the same builtin-plus-skill rows, including argument
hints and `_meta.scope`/`_meta.path`, and use the same resolved names for slash
dispatch. The existing `workspace.discover_skills` serializer remains a separate
deferred RPC surface because no live workspace request router currently consumes
it; it is not advertised as reachable.

| Command | Outcome |
|---|---|
| `zsh workflows/swift-safe-verify.zsh test --no-parallel --filter LiveSkillsReachabilityTests` | **Exit 0** — reported **3 tests / 1 suite**, zero failures. |

### Wave 11 audit closure — G009 (2026-08-06)

macOS Seatbelt profiles now always allow process-level network access so the
agent can reach its provider/LLM API while sandboxed. `restrictNetwork` remains
the policy input for Linux child-launch isolation; it is no longer translated
into a process-wide macOS `(deny network*)` rule. The regression covers both
resolved flag values and preserves file-write and firmlink-deny assertions.

| Command | Outcome |
|---|---|
| `zsh workflows/swift-safe-verify.zsh test --no-parallel --filter OpenGrokSandboxTests` | **Exit 0** — reported **35 tests / 2 suites**, zero failures. |

### Wave 11 audit closure — G013 (2026-08-06)

Linux sandbox capability reporting is now backend-honest: Landlock detection no
longer advertises an unimplemented backend, and bubblewrap must pass the exact
runtime probe before support is reported. A non-off Linux apply now resolves a
fail-closed deny plan, creates a one-use receipt, and process-replaces the agent
with an absolute bubblewrap path; the inside invocation validates and consumes
that receipt, so a caller-supplied marker cannot claim enforcement. The outer
agent keeps provider network access; the existing child-only `unshare` wrapper
arms only after successful apply. Live foundation bootstrap now runs after cwd
and persisted-session resolution but before sampler, process backend, hooks,
MCP, or tool construction, and passes the resolved security context/decision
into `LiveToolExecutor`. A capable Linux runner still needs the final
filesystem/provider-network/child-network behavioral proof.

| Command | Outcome |
|---|---|
| `zsh workflows/swift-safe-verify.zsh test --no-parallel --filter OpenGrokSandboxTests` | **Exit 0** — reported **37 tests / 2 suites**, zero failures. |
| `zsh workflows/swift-safe-verify.zsh test --no-parallel --filter LiveSandboxCompositionTests` | **Exit 0** — reported **3 tests / 1 suite**, zero failures. |

### Wave 11 audit closure — G035 (2026-08-06)

Linux capability reporting no longer treats a discoverable or probeable
bubblewrap executable as current-process support. Ordinary Linux processes
report `SandboxSupportInfo.isSupported == false` and
`PlatformSandboxEnforcer.detectSupportedMode() == .none` until the bwrap
re-exec returns with the process-owned receipt. The live manager still attempts
that re-exec when bwrap is launchable, then marks the process applied only after
receipt validation; a caller-supplied `__GROK_INSIDE_BWRAP` marker cannot claim
support, mode, or enforcement. Child-network restriction remains gated by the
post-apply state. Linux-host behavioral proof remains open because this macOS
runner cannot execute the bwrap confinement check.

| Command | Outcome |
|---|---|
| `zsh workflows/swift-safe-verify.zsh test --no-parallel --filter OpenGrokSandboxTests` | **Exit 0** — reported **39 tests / 2 suites**, zero failures on macOS; Linux-only capability assertions are compile-guarded for a Linux-capable runner. |

### Wave 11 audit closure — G037 (2026-08-06)

Live Code Mode now resolves an effective tool mode through the
`InProcessCodeModeSession.runtimeCapability` facade before constructing the
model-facing surface. Hosts without JavaScriptCore fall back to direct tools,
so `exec` and `wait` are not advertised before the runtime can start; the
startup seam remains typed and fail-closed with
`JavaScriptRuntimeError.unsupportedPlatform`. The live dependency seam accepts
an explicit capability provider for regression coverage, and ACP shares the
same effective-mode decision through `makeAgentStack`.

The Rust reference embeds V8 (`xai-grok-code-mode`), while the Swift port still
uses JavaScriptCore where available and falls back to direct tools elsewhere.
A portable embedded or out-of-process JavaScript engine remains future parity
work; suppressing the transport is the deliberate current divergence.

| Command | Outcome |
|---|---|
| `zsh workflows/swift-safe-verify.zsh test --no-parallel --filter CodeModeCompositionTests` | **Exit 0** — reported **10 tests / 1 suite**, zero failures on the JavaScriptCore host; includes the injected unavailable-capability control. |
| `zsh workflows/swift-safe-verify.zsh test --no-parallel --filter JavaScriptRuntimeCapabilityTests` | **Exit 0** — reported **1 test / 1 suite**, zero failures on the JavaScriptCore host. |

### Wave 11 audit finding — G043 (2026-08-06) — partial

`OpenGrokExtraCA` now mirrors the upstream opt-in contract: an unset or empty
`OPENGROK_EXTRA_CA_BUNDLE` performs no read, a process-cached loader reads at
most 1 MiB, parses PEM certificate blocks into validated DER, drops malformed
blocks individually, and warns without failing HTTP startup. `HTTPTLSConfiguration`
captures the resolved roots, and every default-created production URLSession
uses them through the shared transport delegate, including the separate Darwin
streaming session and WebSocket/MCP-adjacent construction. Existing default
factories for sampling, auth, MCP, updates, and web/media therefore inherit the
same policy without per-feature helpers.

Darwin installs the accepted DER certificates as additive `SecTrust` anchors
while retaining system roots and requiring successful trust evaluation. Linux
FoundationNetworking has no `URLProtectionSpace.serverTrust` challenge API;
the Linux streaming delegate therefore retains the resolved policy for honest
capability reporting but cannot install custom anchors. G043 is intentionally
not marked closed until a portable Linux TLS backend can apply the same roots
to both buffered and streaming traffic.

| Command | Outcome |
|---|---|
| `zsh workflows/swift-safe-verify.zsh build-tests` | **Exit 0**. |
| `zsh workflows/swift-safe-verify.zsh test --no-parallel --filter OpenGrokExtraCATests` | **Exit 0** — reported **7 tests / 1 suite**, zero failures. |
| `zsh workflows/swift-safe-verify.zsh test --no-parallel --filter OpenGrokHTTPTests` | **Exit 0** — reported **119 tests / 18 suites**, zero failures. |

### Wave 11 audit closure — G047 (2026-08-06)

The shipped version path now resolves the current reference release
`0.1.220-open-grok.54`: the package-root `OPEN_GROK_VERSION` marker is read by
the build plugin after the `GROK_VERSION` override, the manual generator and
checked-in reference fallback use the same `.54` default, and the executable's
`CLIRunner --version` route is asserted for both plain and JSON output. The
`GROK_TEST_VERSION` override behavior remains unchanged.

Every ProtocolFixtures JSON family now names the full `9ed09e2a` revision and
the immediate prior `80dff0a9` revision. The provenance index records the
per-family 80dff0a9..9ed09e2a diff result, the CLI fixture no longer reports the
resolved version drift, the GCRX sample carries `.54`, and the manifest was
regenerated after all bytes and metadata changed. The independent Code Mode
yield-time drift remains recorded.

| Command | Outcome |
|---|---|
| `zsh workflows/swift-safe-verify.zsh test --no-parallel --filter OpenGrokVersionTests` | **Exit 0** — reported **44 tests / 1 suite**, zero failures. |
| `zsh workflows/swift-safe-verify.zsh test --no-parallel --filter OpenGrokCLITests` | **Exit 0** — reported **316 tests / 34 suites**, zero failures. |
| `zsh workflows/swift-safe-verify.zsh test --no-parallel --filter OpenGrokCompatibilityTests` | **Exit 0** — reported **19 tests / 4 suites**, zero failures. |
| `zsh workflows/swift-safe-verify.zsh build --product open-grok` | **Exit 0** — shipped product path compiles. |

### Wave 11 audit closure — G053 (2026-08-06)

The shipped CLI now exposes `release-validate`, and the macOS product smoke
invokes it instead of running raw `--version` and `paths --json` commands. The
route executes the supplied product in a controlled `OPENGROK_HOME`, `HOME`, and
`OPEN_GROK_BIN_DIR`, validates version plus optional short-commit metadata through
`SmokeValidation`, checks resolved-path containment separately from observed-write
isolation, merges checksum findings only when artifact/sidecar pairs are supplied,
renders every finding to stderr, and returns success only after evaluating
`ReleaseValidationReport.passed`. The manifest dependency direction is now
acyclic: `OpenGrokCLI` imports `OpenGrokReleaseValidation`, while the validator
depends only on distribution support.

The Swift workspace still has no installer or artifact-producing release workflow;
`validateIsolatedHome` therefore remains reserved for a future installer smoke
that can collect actual touched paths. The validator pin follows the current
workspace baseline `9ed09e2a…` through `OpenGrokDistributionSupport`.

| Command | Outcome |
|---|---|
| `zsh workflows/swift-safe-verify.zsh test --no-parallel --filter ReleaseValidationCommandTests` | **Exit 0** — reported **4 tests / 1 suite**, zero failures. |
| `zsh workflows/swift-safe-verify.zsh test --no-parallel --filter OpenGrokReleaseValidationTests` | **Exit 0** — reported **37 tests / 6 suites**, zero failures. |
| `zsh workflows/swift-safe-verify.zsh test --no-parallel --filter OpenGrokVersionTests` | **Exit 0** — reported **44 tests / 1 suite**, zero failures. |
| `GROK_COMMIT="$(git rev-parse --short HEAD)" zsh workflows/swift-safe-verify.zsh build --product open-grok` plus the product release-validate smoke | **Exit 0** — stamped version and commit matched; resolved paths stayed inside the temporary root. |

## Historical Luna integration verification snapshot (2026-07-23; superseded)

| Command | Outcome |
|---|---|
| `git diff --check` | **Exit 0**. |
| `zsh workflows/swift-safe-verify.zsh build` | **Exit 0**. |
| `zsh workflows/swift-safe-verify.zsh build-tests` | **Exit 0**. |
| `zsh workflows/swift-safe-verify.zsh test` | **Exit 0** — 100 Swift Testing runs, 1,672 tests, no failures; 100 legacy XCTest runners reported 0 cases. |
| `zsh workflows/swift-safe-verify.zsh build --product open-grok` | **Exit 0**. |
| `open-grok --version`, `help`, and isolated `paths` smokes | **Pass** — version `0.1.220-open-grok.21`; state remained under `/tmp/open-grok-smoke-home`. |

This is retained as a historical checkpoint only. The current green gate and
test totals are recorded in the 2026-08-06 snapshot above.


## Inventory counting method (reproducible)

Counts are mechanical over the current tree (no Package.swift parsing), recomputed **2026-08-06**:

1. **Production source targets** = directories under `Sources/` → **102**.
2. **Test targets** = directories under `Tests/` → **102**.
3. **Bootstrap placeholder production targets** = source directories whose Swift sources total **≤15 non-comment, non-blank lines** (classic empty-module stubs), **excluding** pure C helper targets `COpenGrokZlib`, `COpenGrokSockets`, `OpenGrokPTYC`, and `OpenGrokCrashHandlerC` (real C implementations, not placeholders) → **1**.
4. **Zero-test targets** = test directories with **no** `@Test` and **no** `func test[A-Z_]` in any `.swift` file → **0**.
5. **Non-placeholder production targets** = **102** (the sole ≤15-line target is the executable entry point, not a placeholder). **Test targets with ≥1 test** = **102**.

The only target meeting the ≤15-line rule after excluding C helpers is:

| Target | Non-comment LOC | Character |
|---|---:|---|
| `OpenGrokExecutable` | 15 | **not** a placeholder — thin `main` that hands off to `OpenGrokCLI` |

So the honest figure is **0 real placeholders out of 102** production targets, plus one legitimately small entry point. The previously published **42 / 98** figure is superseded.

No retained test target is empty under the mechanical `@Test`/`func test[A-Z_]` criterion. The Wave 11 compatibility, release-validation, PagerPTY harness, PagerPTY, fuzzing, performance, and security targets all contain executable declarations; the inventory canary below prevents that fact from silently regressing.

Verifier commands used for this recount (read-only; no SwiftPM invoked):

```sh
ls Sources | wc -l
ls Tests | wc -l
for d in Sources/*/; do
  t=$(basename "$d")
  case "$t" in COpenGrokZlib|COpenGrokSockets|OpenGrokPTYC|OpenGrokCrashHandlerC) continue;; esac
  n=$(find "$d" -name '*.swift' -exec cat {} + | grep -v '^[[:space:]]*$' | grep -v '^[[:space:]]*//' | wc -l)
  [ "$n" -le 15 ] && echo "$t $n"
done
for d in Tests/*/; do
  grep -rqE '@Test|func test[A-Z_]' "$d" --include='*.swift' || echo "ZERO: $(basename "$d")"
done
```

## Historical live executable capability snapshot (2026-08-04, superseded)

This section records the tree as it existed on 2026-08-04. Later wave sections
supersede its present-tense reachability claims; do not use it as the current
capability list.

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

**Most non-launch CLI routes refuse.** `login`, `logout`, `sessions`, `mcp`, `plugin`, `workflow`, `doctor`, `serve`, `acp`, `update`, `memory`, `dashboard`, `workspace`, `worktree`, `inspect`, `completions`, `setup`, `wrap`, `export`, and `trace` all parse their arguments correctly and then throw `CLIApplicationError.unsupported`, surfaced as `route '<name>' is not available in the current Swift composition` (`Sources/OpenGrokCLI/OpenGrokApplication.swift:10`). `share` is the deliberate exception: the shipped async runner reaches its live authorization composition, which fails closed before upload because the network clients are not ported. Argument parsing is real; only the handlers listed above remain missing.

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
- `ProtocolFixtures/`: binary OTLP HTTP/gRPC goldens, git loose-object zlib, GCRX crash sample, tracing/storage/hunk/PTY/crash format fixtures + provenance + manifest recaptured at ref `9ed09e2a…`; release-stamped artifacts use `0.1.220-open-grok.54`, and unchanged families carry explicit `80dff0a9..9ed09e2a` evidence.
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
- **Git status:** portable pure-Swift SHA-1; zlib via Compression (Apple) or linked `COpenGrokZlib`/libz **on Apple platforms and Linux only**; pack-only objects are explicit non-parity.
  - **Windows divergence (2026-08-11, deliberate):** `COpenGrokZlib` is not declared on Windows (`Package.swift`, `zlibShimAvailable`) because the Swift Windows SDK ships no `<zlib.h>` and no `z` import library, so declaring the target failed the entire Windows build inside the shim's header. `ObjectStore` selects Compression → `COpenGrokZlib` → a typed `zlib … unavailable on this platform` throw, and dropping the target is what arms that third arm. **Cost: Git loose-object and pack inflation do not work on Windows** — they return the typed unavailable error rather than a result. This is the honest state until a Windows zlib is vendored, and it must not be "fixed" by re-adding the target without one.

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

`xai-workflow` remains mapped to a proposed target; `xai-grok-extra-ca` now has a
real `OpenGrokExtraCA` target and is tracked as an implemented partial because
FoundationNetworking cannot yet install custom roots on Linux.

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

## Wave 10 — 2026-08-06 (leader control, export boundary, sandbox spawn, CI honesty)

Gates: `build-tests` **0**, `build` **0**, `test --no-parallel` **0** —
**3,325 tests / 554 suites, zero failures** across 73 Swift Testing runs — and
`build --product open-grok` **0**. `git diff --check` **0**. The aggregate is
the count reported by this worktree's current SwiftPM discovery; it supersedes
older wave totals rather than being inferred from them.

**ACP leader control is live through the production workspace client.**
The leader advertises `control_v1` and `workspace_exposure`, answers typed
leader/profile/workspace payloads, and owns a start/pause/resume/stop/status
state machine. The CLI's real `LeaderWorkspaceControlChannel` consumes
`control_result`; integration testing found and removed a duplicate length
prefix that previously made registration close immediately. `leaderSession`
now injects resolved socket/lock paths, relay suffix, installed version, the
leader-owned auth provider, permission mediation, and the production Computer
Hub WebSocket exposure connector. Backend-less library callers still answer
status truthfully as `none` and refuse start with a typed error.

### Wave 11 audit closure — G018 (2026-08-06)

The shipped leader composition no longer constructs `ACPLeaderIPCHost` with
default metadata. A single production configuration factory supplies the real
socket and lock paths, `ACPLeaderSocketPaths.suffix(forRelayURL:)`, and
`OpenGrokCLIVersion.installed(environment:)` to both registration and
`get_leader_info`. The connector uses the leader-owned `AuthManager`,
`LivePermissionHubMediator`, and `HubWebSocketConnectionClient`; the latter
performs authenticated hello/identity validation, serialized writes, demuxed
reads, disconnect/reconnect handling, and rejects plaintext `ws://` except for
loopback hosts.

| Command | Outcome |
|---|---|
| `zsh workflows/swift-safe-verify.zsh test --no-parallel --filter LiveLeaderCompositionLiveTests` | **Exit 0** — reported **2 tests / 1 suite**, zero failures; real Unix-socket registration and `get_leader_info` assert paths, suffix, version, and capability advertisement. |
| `zsh workflows/swift-safe-verify.zsh test --no-parallel --filter HubWebSocketConnectionClientTests` | **Exit 0** — reported **3 tests / 1 suite**, zero failures; authenticated loopback handshake, progress/response demux, malformed-frame failure, and remote plaintext rejection. |

### Wave 11 audit closure — G019 (2026-08-06)

The production `workspace` launcher now resolves the feature gate through an
authenticated `GET /v1/settings` when `GROK_WORKSPACE_COMMAND` is absent. The
route uses the configured `EndpointsConfig` proxy URL, existing `AuthManager`
credential/refresh behavior, and an injectable `HTTPTransport`; malformed URLs
or bodies, transport failures, and non-2xx responses remain fail-closed as the
existing unknown-settings refusal. Explicit truthy or falsy environment
overrides bypass the loader entirely. The launcher passes the fetched setting
into the existing leader capability/control path, proving an enabled account
reaches `workspace status` without a real network or socket in tests.

This closes the workspace feature-gate reachability gap only. The separate
Computer Hub backend remains an injected production connector boundary: this
change does not claim that `workspace start` itself establishes a real Hub
session when the leader has no configured exposure backend.

| Command | Outcome |
|---|---|
| `zsh workflows/swift-safe-verify.zsh test --no-parallel --filter WorkspaceGateTests` | **Exit 0** — reported **6 tests / 1 suite**, zero failures. |
| `zsh workflows/swift-safe-verify.zsh test --no-parallel --filter WorkspaceRemoteSettingsLoaderTests` | **Exit 0** — reported **2 tests / 1 suite**, zero failures; configured `/v1/settings` URL, bearer/Accept headers, decoding, and fail-closed malformed/non-2xx cases. |
| `zsh workflows/swift-safe-verify.zsh test --no-parallel --filter LiveWorkspaceLauncherReachabilityTests` | **Exit 0** — reported **8 tests / 1 suite**, zero failures; no-override fetch-to-leader path, override bypass, and unavailable/disabled refusal controls. |

### Wave 11 audit closure — G022 (2026-08-06)

Computer Hub workspace exposure is now constructed on the shipped leader path.
`LiveLeaderComposition.leaderSession` passes a connector-bearing
`ACPLeaderIPCConfiguration` into the real `ACPLeaderIPCHost`; the connector
uses the concrete authenticated `HubWebSocketConnectionClient` and wraps the
hub harness in `LivePermissionHubMediator`. The mediator now receives the
leader workspace's existing `PermissionPipeline` through
`LocalOpenGrokShellWorkspace`, so hub calls cannot silently acquire a second
default gate. The transport rejects non-loopback plaintext `ws://`, performs
hello/identity validation, serializes writes, drains demux waiters on failure,
and owns disconnect/reconnect state. The separately packaged
`OpenGrokComputerHubMCPAdapter` remains intentionally unclaimed as live: no
configured MCP transport is part of the leader exposure path.

| Command | Outcome |
|---|---|
| `zsh workflows/swift-safe-verify.zsh test --no-parallel --filter WorkspaceCapabilityTests` | **Exit 0** — reported **5 tests / 1 suite**, zero failures; production leader configuration retains a connector and `workspace_start` reaches `running`. |
| `zsh workflows/swift-safe-verify.zsh test --no-parallel --filter HubWebSocketConnectionClientTests` | **Exit 0** — reported **3 tests / 1 suite**, zero failures; authenticated loopback handshake, progress/response demux, malformed-frame failure, and remote plaintext rejection. |

### Wave 11 audit closure — G023 (2026-08-06)

The real `LiveLeaderComposition.session` socket test now exercises the
workspace control seam instead of stopping after ACP `initialize`. Over the
production Unix socket it asserts `control_v1` and `workspace_exposure`,
checks `workspace_status` for the live leader PID, sends a valid
`workspace_start` request with a test cwd, and requires the typed
auth-backed connection refusal in the credential-free test environment. A
follow-up status remains `none`, proving the failed start did not fabricate an
exposure. The same test continues to assert `get_leader_info` paths, relay
suffix, and installed version. This closes the live false-green risk without
claiming a successful Hub session in a no-credential test; the production Hub
connector and its separate transport coverage remain tracked under G022.

| Command | Outcome |
|---|---|
| `zsh workflows/swift-safe-verify.zsh test --no-parallel --filter LiveLeaderCompositionLiveTests` | **Exit 0** — reported **2 tests / 1 suite**, zero failures; real-socket registration, metadata, capabilities, status, typed start refusal, and ACP initialize. |
| `zsh workflows/swift-safe-verify.zsh test --no-parallel --filter WorkspaceCapabilityTests` | **Exit 0** — reported **5 tests / 1 suite**, zero failures; in-memory control-plane and production connector tripwires remain green. |
| `zsh workflows/swift-safe-verify.zsh test --no-parallel --filter ACPLeaderIPC` | **Exit 0** — reported **24 tests / 3 suites**, zero failures; registration, routing, control dispatch, workspace lifecycle, and metadata codec coverage. |

### Wave 11 audit closure — G028 (2026-08-06)

Live telemetry bootstrap now resolves the xAI `AuthManager` from the session's
isolated `OPENGROK_HOME` before constructing `LiveToolExecutor`. The policy
decision uses `currentOrExpired().isZDRTeam`, so an expired ZDR credential still
darkens telemetry; user/team identity is taken only from a current xAI auth and
is passed explicitly to `bootstrapFromDisk`. The resulting `LiveTelemetryStatus`
is retained on the executor for a live-seam assertion. Workflow child executors
inherit the same immutable context, so they cannot silently fall back to
`zeroDataRetention == false`; standalone fixtures must pass an explicit empty
context.

| Command | Outcome |
|---|---|
| `zsh workflows/swift-safe-verify.zsh test --no-parallel --filter LiveTelemetryDefaultOffTests` | **Exit 0** — reported **6 tests / 1 suite**, zero failures; stored xAI OIDC ZDR auth darkens product + external OTEL, and the non-ZDR opt-in control remains active through the real session foundation. |

**The xAI export boundary exists and is fail-closed.** One shared monotonic
boundary closes when any provider profile denies xAI services. Share and
feedback policies consult it before export and again at send time; share wire
payloads use a serde-compatible JSON codec. The `share` composition is tested
but deliberately not connected to a successful upload path: persisted session
 new live records now persist and rehydrate the `ever_used_codex` marker; legacy
 records without it remain unverifiable and are refused. No signed-URL/backend
 upload client exists, so the route still proves no transcript bytes leave the
 process.

**Sandbox selection and child spawn now meet.** The parsed CLI `--sandbox`
profile reaches live bootstrap, and the local shell process backend applies the
sandbox launch transform before every spawn. Linux child network denial has a
fail-closed `unshare` user+network-namespace wrapper with a cached host probe.
Linux process-wide sandbox activation is now a receipt-backed bubblewrap
re-exec; capable-Linux behavioral proof remains open. macOS Seatbelt remains
the process-wide live enforcer on Apple hosts.

**CI stopped hiding Linux compiler failures.** Linux workflow commands now run
under Bash with `pipefail`, and the crash C shim defines `_GNU_SOURCE` before
glibc headers so `REG_RIP`/`REG_RBP` are visible. Platform jobs remain
non-blocking while their real gaps are open: Windows' version build plugin still
hardcodes `/bin/sh`, and the latest observed macOS CI run terminated during
BuildSupport rather than producing a trustworthy platform pass.

## Wave 9 — 2026-08-06 (telemetry, Computer Hub, Linux, commands)

Gates: `build-tests` **0**, `test --no-parallel` **0** — **3,858 tests / 574
suites, zero failures**, 193s. Commits `8ce2082` (AGENTS.md + CLAUDE.md),
`e08c962`, `3097f74`, `bcc2405`, `65d8eda`, `a42f591`, `f97653e`.

**Telemetry is live and default-off, in that order.** Wave 8 left it dark because
our `productTelemetryEnabled` defaulted `true` against upstream's `Disabled` and
no `DISABLE_TELEMETRY` opt-out existed. The inversion was fixed and *proven*
before a call site landed: byte-level assertions over the serialized OTLP body
show no prompt text, no `sk-` key, no username, no project name with gates off,
plus an open-gate negative control. The bootstrap deliberately reads from disk
rather than the security context's document — that document carries the project
tier, so a repo's checked-in `.opengrok/config.toml` would otherwise enable
telemetry for everyone who clones it (`projectConfigCannotEnableTelemetry`).

**Computer Hub: the route is live and every dispatch path is gated.** Before this
wave *every* Hub adapter bypassed the permission gate — `admitCall` was transport
only, and the MCP handler called straight into the vendor server. `HubMediation`
now has no default anywhere and is a required constructor argument on four types,
so an ungated surface must be spelled `.unmediated(reason:)` and is greppable.
Denials return `permissionDenied`/-32003, not a custom code, so a model cannot
distinguish a hub denial from a local one and retry around it. Where the port
genuinely cannot represent a workspace status on the wire, the route runs the real
sequence and terminates at upstream's own capability refusal, with
`portDefaultLeaderIsRefused` asserting `workspaceExposure == false` so flipping
that bit without building the control plane fails a test rather than shipping a
lie. The ACPRuntime control plane was the recorded gap; Wave 10 closes the
protocol/client portion while retaining the missing real Hub connector as an
explicit typed refusal.

**Linux:** streaming HTTP implemented rather than stubbed; child network blocking
returns a **typed unsupported error** rather than silently not blocking. The
in-process seccomp shim is deliberately deferred to its own reviewed slice —
`unshare --net` at the spawner may be the better seam (no shim, testable without
root, fails closed at the process boundary). Full seam inventory in
`INTEGRATION-w9-linux.md`.

**Commands:** the five session commands register now that their backing exists;
auto-compaction surfaces as a first-class `Compacting…` turn state; `/context`
carries window occupancy while `/usage` stays reserved for billing as upstream
has it.

**Reachability got its own test.** The workspace launcher clause now has one that
drives the real launcher with parsed argv, plus two controls: one proving the
suite goes **red** if the clause is deleted, and one proving `handles` does not
match too broadly. Without those a reachability test passes for the wrong reason —
the failure this project has now hit three times.

**`AGENTS.md` and `CLAUDE.md` were added** so these lessons are enforced by
documentation rather than by the coordinator noticing.

## Wave 8 — 2026-08-05 (the audit findings, closed)

Wave 8 answered the audit below. Gates: `build-tests` **0**, `test --no-parallel`
**0** — **3,751 tests / 554 suites, zero failures**, 173s. Commits `add82ce`
(security), `c6bde5c` (compaction), `e2fceee` (memory/sessions), `cc31378` (TUI),
`9f0a59c` (CLI/tools/services), plus tri-platform CI in `fdf8b3f`.

**Closed:** shell execution gated (refusal proven *before spawn* by a spy backend
asserting `spawnCount() == 0`); `[permission]` config, `.claude/settings.json`,
and CLI permission flags feeding the rule engine; project-config precedence;
folder trust persisted and gating repo MCP; sandbox with its first non-test
importer; compaction live in the turn loop with Codex Remote V2; background-task
consumer tools; root CLI invocations; the settings modal, six themes, motion, and
scrollback focus; memory, goals, rewind, session search; self-update, crash
handler, skills, SHA-pinned plugins.

**Deliberately not done, with reasons:** telemetry stays dark
(`productTelemetryEnabled` defaults `true` here vs upstream's `Disabled`, and
there is no `DISABLE_TELEMETRY` opt-out — wiring emission first would ship it on
by default; port mode resolution and the opt-out, then call sites). Computer Hub
`workspace` route, share/feedback (must gate upload on the xAI export boundary so
a Codex transcript never reaches xAI), `/resume` `/rewind` `/jump` `/delete`
`/rename` registrations, and 44 slash commands whose backing runtime does not
exist.

**Nine product bugs the wave found, none in the audit.** Five would have shipped
silently: `/remember` wrote correctly to disk, said "Saved", and was permanently
unfindable — twice over, from two independent suppressors in series; SSE block
boundaries matched only `"\n\n"`, so a CRLF stream never found a boundary and the
whole response decoded to nothing; the Codex compaction body encoded
`ConversationItem`'s on-disk form, which no live server speaks; `kill_task`'s gate
returned `nil` (dispatch) where its sibling returned a failure, while being
*reported* as fail-closed; slash commands typed mid-turn were queued as prompts
and sent to the provider verbatim. Also: `/queue` silently stole `/q` from
`/quit` via alphabetical sort; `--minimal` hard-failed without a TTY; `mcp remove`
exited 2 and silently did nothing; a permission-layer merge let a user config
delete an admin's deny rule.

**The port's characteristic failure mode has a name now: "succeeds, does nothing,
says nothing."** A port is where behavior gets dropped while structure survives —
it compiles, types line up, the call returns, the thing quietly doesn't happen. In
none of these was the fix the code that broke; each mechanism did exactly what it
was written to do. What was missing was any path for the silent case to announce
itself. Two practices caught all of them and are now standing guidance: assert
reachability **through the live seam** (what the model is offered, what runs, what
lands on disk — never against composition types, which pass just as happily when
nothing constructs them), and **never `_ =` a status-returning call**.

## Feature-parity audit — 2026-08-05 (six read-only audits, enumerated from the Rust side)

Every prior "gap" list in this document was written from the *port's* perspective
— what a wave set out to build. This audit enumerated the **Rust** surface first,
so features no wave ever claimed could not hide. Full reports:
`AUDIT-{cli,tui,tools,sessions,providers,config}.md` (session scratchpad).
**Headline: subsystem depth is real; breadth and enforcement are not.**

**SECURITY — fix before any other parity work.**

1. **`run_terminal_cmd` bypasses the permission system entirely**
   (`LiveComposition.swift:1977-1988` dispatches straight to `composition.invoke`):
   no permission request, no deny rules, no PreToolUse hooks. The interactive
   permission modal built in wave 2 gates *file writes only*. Arbitrary shell runs
   unprompted — including commands that rewrite the protected config files.
2. **Nothing reads `[permission]` config** (`grep '"permission"' Sources/` → 0
   hits). A user's `deny = ["Bash(rm:*)"]` is silently ignored; the rule engine is
   correct, tested, and has no input.
3. **No sandbox enforcement**: `OpenGrokSandbox` (2,208 lines, real `sandbox_init`)
   has zero importers. Rust applies Seatbelt at startup and at every local exec.
4. **Folder trust is inert** — a hostile repo's `.mcp.json` spawns servers on first
   open (`LiveMCPComposition.connectConfiguredServers` performs no trust check).
5. **Project config is dropped from the live precedence chain**: live loads
   `effectiveConfigBase()`, so any repo `.opengrok/config.toml` (MCP servers, hooks,
   tool config) has no effect. The faithful `AuthorityComposition` has zero callers.

**HARD WALLS — the session cannot proceed past them.**

6. **No compaction path is live.** A session exceeding the context window dies with
   a provider error: no auto-compact, no `/compact`, no truncation fallback. The
   full Codex Remote Compaction V2 protocol exists in `Sources/OpenGrokCompaction`
   (~1,600 lines, unit-tested) with **zero call sites** outside its own module —
   the README's flagship feature, library-only.
7. **Background execution is a dead end.** `run_terminal_cmd` backgrounds (and
   *auto*-backgrounds on a 10s budget) but `get_task_output` / `wait_tasks` /
   `kill_task` do not exist, so the model can never reach the output. Producer
   shipped without consumers.
8. **No `/rewind` or restore-code**, and no file snapshots — a bad agent edit
   outside git is permanent.

**BREADTH — daily-driver surfaces never waved.**

9. **Root CLI invocation forms don't parse**: `open-grok "prompt"`, `-p`, `-c`,
   `-r`, `-m` all fail as `unknown command`; only subcommands were implemented.
   No permission/sandbox flags at all, blocking scripted and CI use.
10. **62 of 71 slash commands missing** (`/compact`, `/resume`, `/usage`, `/copy`,
    `/export`, `/find`, `/theme`, `/context`, …); no settings modal (90 rows, all
    Advanced feature flags); no scrollback focus model (21 dead bindings); themes
    ported but unselectable; plan mode absent.
11. **Session recovery is command-line-only** — no picker, no search, no titles;
    memory and goals are complete libraries reachable by nothing (`update_goal`'s
    prompt text is registered while the tool is not — the model may be told to call
    a tool that does not exist).
12. **Auxiliary services dark**: self-update (users can never upgrade), crash
    handler never installed, skills entirely absent, plugin marketplace parses but
    has no dispatcher case, Computer Hub fully built and unreachable, telemetry/
    voice/announcements/share unwired. `web_search`/`web_fetch` have no registered
    handler, so non-hosted-search providers (Kimi, Fireworks, OpenCode Go, Wafer)
    have no search at all.
13. **One provider-level defect**: Fireworks JSON-Schema normalization is missing
    (`normalize_fireworks_schema`), so loose tool schemas 400 on Fireworks.

Statuses used above distinguish **live** (reachable from the running executable)
from **implemented-unwired** (tested library, no importer) from **absent**. Most
items in 6-12 are unwired rather than absent, which is why the test suite is green
and the feature is missing at the same time — coverage of a library proves nothing
about its reachability.

## Known remaining gaps

1. **No current macOS verifier blocker** as of the last verifier run (2026-07-23): the serialized package, tests, product build, and executable smokes were green. Not re-run since.
2. **Reachability, not placeholders, is the real gap.** The executable is no longer bootstrap-only, but a large tested library surface is orphaned (see the live capability snapshot): Markdown, MCP, hooks, memory, voice, update, execution tools, sandbox, and every pager feature target are imported by nothing on the CLI path.
3. **The live agent streams and can write, but writes are gated off by default.** `run_terminal_cmd` plus the write-capable `.build` file pack (`read_file`, `list_dir`, `grep`, `glob`, `view_image`, `search_replace`, `write`, `apply_patch`) are wired through `PermissionPipeline`, and assistant text is forwarded as deltas. Mutations are refused unless `OPENGROK_ALLOW_WRITES=1` is set, because no interactive permission prompter exists yet — that prompter is the remaining work, not the tools.
4. **Codex is wired.** `resolveSamplingConfiguration` routes through `LiveCredentialResolver`, and account-pinning headers reach both the sampler and `ProviderSession`. Untested against a live Codex account: no end-to-end OAuth run has been performed, only isolated-store unit tests.
5. **`login`/`logout` now run** (including `--all`, `--codex`); the remaining non-launch routes still refuse after parsing.
6. **Few placeholders remain:** **6** true production stubs out of **99** (`OpenGrokCodeMode`, `OpenGrokJavaScriptRuntime`, `OpenGrokMermaid`, `OpenGrokMermaidLayout`, `OpenGrokDistributionSupport`, `OpenGrokPagerPTYHarness`), plus the four empty cross-cutting gate suites.
7. **The port is 202 commits behind upstream** with known data-layer breakage; see "Upstream drift since re-pin baseline".
8. **`ProtocolFixtures/` are stale** relative to the new pin and cannot ground parity claims until recaptured.
9. **Portability gaps remaining:** Windows ConPTY/Credential Manager/LockFileEx; full Linux Secret Service; pack object reading; full tree-sitter not in Package.swift; OTLP gRPC uses collector-shaped TraceService Export requests (path + framing + `grpc-status`) over `HTTPTransport` rather than a dedicated HTTP/2 tonic client—trailers depend on the transport surfacing them.
10. **Package-green ≠ Rust parity:** focused and integrated Swift tests do not prove full source-port behavior.
11. **Native Linux and Windows CI jobs exist but are non-blocking.** Linux now
    reports piped compiler failures honestly; Windows remains blocked by the
    build plugin's `/bin/sh` invocation. Neither platform has earned a green
    support claim.

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
- **Mouse-reporting toggle gate is live** (`[ui] mouse_reporting_toggle` /
  `GROK_MOUSE_REPORTING_TOGGLE`, default off, env > effective TOML / `UiConfig`
  field > default). When off, `/toggle-mouse-reporting` is hidden from the
  dropdown / ACP catalog and returns the upstream unavailable hint on direct
  invoke; scrollback `Ctrl+R` is unbound. When on, scrollback-focused `Ctrl+R`
  and the slash command share the live `setMouseReporting` seam; prompt focus
  does not bind the chord (prompt history stays Up/Down + `/history` — this
  port never had prompt `Ctrl+R` history search). The settings row remains
  restart-required (`ui.mouse_reporting_toggle`); live capture state is
  separate.
- **No sticky mouse-off banner.** Upstream keeps a focus-aware sticky toast
  (`MOUSE_OFF_HINT_SCROLLBACK` / `MOUSE_OFF_HINT_PROMPT` via
  `AgentView::active_toast_message`). This port has no sticky-toast surface for
  mouse-off — `/toggle-mouse-reporting` still appends a system transcript note
  (on/off copy) and restores wire sequences mid-session. Deliberate omission:
  do not invent a banner.
  *Superseded later 2026-08-12 by Local final TUI divergence closure: mouse-off
  sticky toast is live (successful off ⇒ focus-swapped sticky; transient wins;
  on clears + `Mouse reporting on`; idle scroll-clock expiry; rollback/minimal;
  occluder). The invented transcript-note claim is retired. Auth welcome raw-url
  mouse-disable/clear remains an existing auth divergence.*
- Wheel acceleration is not ported — one report is worth `linesPerEvent` lines
  with no rolling-window multiplier. The constants are recorded in
  `INTEGRATION-mouse.md`.
  *Superseded 2026-08-12 by Local remaining-TUI-gap follow-on: full Rust-style
  scroll stream normalizer (80ms stream, 16ms dedicated clock, residual/coast,
  acceleration, remux/terminal profiles) plus live `scroll_*` / `invert_scroll`
  readers.*
- **Legacy X10 mouse reports still leak.** SGR is recovered from
  `.unknown(Data)`, but `TerminalInputDecoder` treats `ESC [ M` as a complete CSI
  and its three coordinate bytes reach the text stream as ghost input. The fix is
  the prefilter described in `INTEGRATION-mouse.md` §2 — run `MouseStreamParser`
  ahead of `TerminalInputDecoder` on the raw byte stream — which needs a change
  inside `OpenGrokTTY`. Mitigated, not fixed, by enabling `?1006h` last.
  *Superseded 2026-08-11 by Local TUI interaction wave: `TerminalInputDecoder`
  preserves full legacy X10 reports (including split reads/releases/wheel).*

**Deferred.**

- **Link clicks.** `PagerRenderResult.links` is published and the click path
  hit-tests overlays only; a click outside an overlay is dropped rather than
  opening a link. The reference also requires mouse-up on the same cell as
  mouse-down, which needs down-cell tracking that does not exist yet. No
  selection, drag, double/triple-click, or hover either.
  *2026-08-11:* visible-block left-click selection is now live (Local TUI
  interaction wave); link click / text drag / multi-click remain absent.
  *2026-08-12:* safe same-cell transcript link open is live (Standard schemes
  only; see Local remaining-TUI-gap follow-on security quotes).
  *2026-08-12 (deep-tui):* linear transcript text drag/multi-click + live
  `keep_text_selection`, sticky headers default-live when `!compact`, and
  native/modifier link-gate alignment are live (see Local sticky-header +
  transcript text-selection follow-on). Still open: table cell/grid→linear
  degradation; sticky header rows not text-drag selectable; composer
  `PromptEditor` drag/multi-click / full `OpenGrokTextArea`; `sticky_headers`
  config/settings toggle.
  *Superseded later 2026-08-12 by Local final TUI divergence closure:* table
  box-grid selection live (fail-closed linear only on malformed/border-start;
  wrapped-fragment leftover remains); sticky-header-not-selectable is pin
  parity; composer `PromptEditor` uses one `OpenGrokTextArea`; `sticky_headers`
  one-shot `pager.toml` config live (no env/no settings row is upstream
  parity). For current leftovers see that section.
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

#### Build-out wave 5 — 2026-08-05 (workflows live, ACP/sessions, Mermaid, debt zero)

Five slices, committed individually (`55ed589`, `77d2d71`, `9fe1c47`,
`241dd40`):

- Workflows execute with **real child subagents** — capability-clamped to the
  parent session's tool policy at surface construction, budget-exhaustion ends
  a run before spawning, journals persist under OPENGROK_HOME, and `/workflows`
  watches live runs.
- `sessions list|show|delete` (async and scoped sync paths) and `open-grok acp`
  stdio work against the built product; the launch stack is factored into
  foundation + agent stack so ACP prompts drive the same turn-driver instance
  as the TUI (identical gating/hooks/MCP; fail-closed writes via absent
  permission presenter). `serve`/`leader` remain unwired pending a WebSocket
  server transport (documented in INTEGRATION-acp.md).
- Mermaid flowcharts and state diagrams render via a deterministic dagre port;
  unsupported families are enumerated and fall back to showing the source.
- Every "known trap" above is closed: JSONValue ambiguity removed;
  restart-required config tracking was a **live bug** (the old path named a
  nonexistent `[features]` table, so `[ui] code_mode` edits never flagged
  restart) — reconciled to upstream's per-setting registry; `mcp add/remove`
  write config (upstream discards comments by design; the port matches);
  the shell-backend flake is deterministic via a test sentinel; the PTY
  harness is real (transport/capture scenarios against the built binary;
  inference scenarios blocked on an env-pointed provider seam, documented).
- New test traps recorded: `--filter` matches TYPE names not display names
  (zero-match still exits 0); under `swiftpm-testing-helper`, Bundle-based
  resource lookup silently skips scenarios while reporting green — anchor to
  compile-time `#filePath`; CRLF-as-one-Character bit a second subsystem
  (VirtualScreen).

Final gates over the committed tree (Swift 6.3.3):

| Command | Exit |
|---|---|
| `swift-safe-verify.zsh test` (default parallel) | **0** — 2889 tests / 429 suites, 26.2s |
| `swift-safe-verify.zsh test --no-parallel` | **0** — 2889 tests / 429 suites, 154.8s |
| `swift-safe-verify.zsh build --product open-grok` | **0** |

Test count 2677 → **2889** (+212). **Zero placeholder targets remain.**
Remaining known gaps: `serve`/`leader` transport; LiveCodeMode's dead
`[features] code_mode` fallback read (flagged to the Code Mode surface);
inference-backed PTY harness scenarios; Linux/Windows CI.

#### Build-out wave 6 — 2026-08-05 (re-pin to 9ed09e2a; serve; providers; harness)

Reference re-pinned `80dff0a9` → **`9ed09e2a`** (upstream HEAD, +14 commits).
Six commits (`4f0cef9`, `25dbcc6`, `8c59511`, `3613187` + hookups):

- `open-grok serve` hosts ACP over a strict RFC 6455 WebSocket server
  (loopback + required secret matching upstream's posture; live-socket tests
  scrape port and secret from the startup banner). Leader/relay client role
  remains documented-unsupported.
- Inference-backed PTY harness scenarios run the built binary against a mock
  server with zero silent skips; the endpoints seam gained its config leg with
  upstream's real precedence (config file > env > compiled default — the
  drift ledger's `ae8bebef` citation for this was wrong and is corrected in
  INTEGRATION-harness.md).
- From the new pin: team-scoped subagent mailboxes (agent_collaboration kind),
  task/agent_swarm/workflow locked as three surfaces, swarm follow-up cancel
  fix, and `_mcp_` hex-encoding for provider-unsafe MCP server names.
- Providers: DeepSeek (+V4 Flash Responses dialect), OpenCode Go (+stream
  tolerance), Wafer AI (dynamic catalog), /fast service-tier surface, OpenAI
  image tools with the Codex-OAuth isolation boundary, always-parseable
  x-grok-client-version.

Final gates (clean scratch, Swift 6.3.3):

| Command | Exit |
|---|---|
| `swift-safe-verify.zsh test` (default parallel) | **0** — 3126 tests / 468 suites, 25.4s |
| `swift-safe-verify.zsh test --no-parallel` | **0** — 3126 tests / 468 suites, 154.4s |
| `swift-safe-verify.zsh build --product open-grok` | **0** |

Test count 2889 → **3126** (+237). Known gaps carried forward: the /model
provider-qualified selector rewrite from 9ed09e2a (assignment crossed the
provider agent's completion); catalog HTTP fetch wiring into ModelsManager
(parsing/cache types done and tested); image_gen/image_edit registry
registration; leader/relay client role; Linux/Windows CI. Operational: the
shared build scratch can be poisoned by interleaved agent builds (symptom:
inexplicable SIGSEGV that passes under a private scratch) — wipe
`.build/workflow-safe` before final gates.

#### Build-out wave 7 — 2026-08-05 (leader, live catalogs, typed /model, image tools)

Four slices plus CI, committed individually (`47be4f7` CI, `0572728`, `51d1dc9`,
`e90932e`, `2d4c913`):

- CI landed: a macOS job running the serial gate + smokes, and a deliberately
  non-blocking Linux job surfacing the compile-gap list on every push.
- Live model catalogs fetch per provider partition with identity/TTL/ETag
  caching, embedded < live < user-override merge order, and enforced partition
  isolation (a Codex refresh cannot touch xAI models or credentials;
  credential fingerprints are computed caller-side so the module never holds
  derivation material).
- Typed `/model <selector>` with upstream's suggest_args completion dropdown;
  unique match switches without the overlay, ambiguity refused. The
  compatibility shim was deleted after its migration window. Two latent
  defects fixed en route: the /model switch path resolving a different
  endpoint than cold start (config leg missing), and eight tests resolving
  `[endpoints]` from the repo checkout via a process-cwd default (parameter
  now required).
- image_gen/image_edit registered with upstream's registration/advertisement
  split: exposure decided from resolved credentials at advertisement time.
- `open-grok leader` connects a local session to a serve endpoint over the
  production WebSocket client (+ Unix-socket IPC leg), reverse requests routed
  locally.

Final gates (Swift 6.3.3):

| Command | Exit |
|---|---|
| `swift-safe-verify.zsh test` (default parallel) | **0** — 3287 tests / 502 suites, 24.7s |
| `swift-safe-verify.zsh test --no-parallel` | **0** — 3287 tests / 502 suites, 198.4s |
| `--filter OpenGrokFileToolsTests` / `OpenGrokToolRegistryTests` | **0** — 32/2 and 70/10 (explicit execution record for the wave-1 pack) |
| `swift-safe-verify.zsh build --product open-grok` | **0** |

Test count 3147 → **3287** (+140). Carried forward: `/model <name> <effort>`
(needs an effort parameter through the switch coordinator);
`opencode_go_enabled_models` config field (four-line filter once ConfigTypes
gains it); tier-restriction capability check (`tierRestricted` wired but
always false); leader relay's remote-infrastructure leg; Linux gap closure
from the CI surface job. Process note: a green `build-tests` is now a handoff
precondition for agents — four shared-tree breaks in one verification window
this wave came from source landing without it.


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
| 48 | `xai-grok-sandbox` | `OpenGrokSandbox` | live (partial) | Process-wide macOS Seatbelt and Linux bubblewrap re-exec are reachable from the live session foundation; Linux capability probing and receipt-backed handoff are covered by focused tests, while capable-Linux behavioral proof remains pending. |
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
| 83 | `xai-workflow` | `OpenGrokWorkflow` | live | Native Rhai workflow engine (`RhaiAST`, `RhaiLexer`, `RhaiParser`, `RhaiInterpreter`, `RhaiEngine`, `RhaiHost`, `RhaiJournal`, `RhaiMeta`, `RhaiRun`, `RhaiLimits`, `RhaiSHA256`). Re-ported natively with 100M op limit, journal recovery, and full test parity. |
| 84 | `xai-grok-extra-ca` | `OpenGrokExtraCA` | live-partial | **Wave 11 G043.** Default-off, process-cached PEM loader with a 1 MiB cap, per-block DER validation, warn-and-continue handling, and central HTTP/WebSocket wiring. Darwin installs additive Security anchors; Linux FoundationNetworking has no `serverTrust` challenge API, so Linux buffered/streaming custom-root support remains blocked. |

Rows 83–84 are appended in discovery order rather than inserted alphabetically, so existing row numbers stay stable across the re-pin.

**Status tally (crate table, 2026-08-04):** **live / live-partial ≈ 14** (reachable from the running executable) · **orphaned ≈ 18** (implemented and tested, imported by nothing on the CLI path) · **target-green / ported ≈ 30** (contract and foundation targets consumed transitively) · **in-progress ≈ 12** · **pending ≈ 6** · **deferred-with-reason = 2** · **not started = 2** (the new upstream crates) · **total 84** Rust crates.

Separate **source-target** inventory: **8 / 99** targets match the ≤15-LOC placeholder rule (**7** genuine placeholders plus the thin `main`), and **12 / 101** test targets have no tests. The former **42 / 98** and **46 / 100** figures are superseded.

Read the tally with care in both directions. The placeholder count fell from 42 to 7 because real implementations landed, but "orphaned ≈ 18" is the offsetting truth: roughly a fifth of the crate map is code that compiles and passes its own tests while contributing nothing to `open-grok` behavior. Neither target-green nor a low placeholder count is executable product parity.

### Wave 11 audit closure — G029 (2026-08-06)

The live session foundation now constructs one shared `ExportBoundary`-backed
`LiveFeedbackComposition`. It persists the complete `FeedbackSubmission` to
session-owned local state before making any upload decision, sends only the
redacted outbound copy, and rechecks the same monotonic boundary immediately
before each HTTP dispatch. The production client uses the configured proxy,
bearer credentials, `/v1/feedback`, and request completion endpoints; missing
feature configuration or credentials remains truthful local-only persistence.

Interactive `/feedback <text>` is registered only when the feature gate and
boundary allow it. The same composition is installed as the production ACP
`x.ai/feedback` extension handler, with ACP session identity aligned to the
session record. `LiveConversationRecord` already persists `ever_used_codex`;
legacy records with a missing marker rehydrate closed and therefore cannot
upload. `FeedbackSubmission` now carries the upstream `authorName` and
`authorEmail` fields, preserving them in the redacted wire copy.

Focused verification (2026-08-06):

| Command | Result |
|---|---|
| `zsh workflows/swift-safe-verify.zsh build --target OpenGrokCLI` | exit 0 |
| `zsh workflows/swift-safe-verify.zsh build --target OpenGrokCLITests` | exit 0 |
| `zsh workflows/swift-safe-verify.zsh test --no-parallel --filter LiveFeedbackCompositionTests` | exit 0; 6 tests, 0 failures |

This closes the feedback live-wiring gap. Signed share upload remains a
separate export client and is still intentionally fail-closed.

### Wave 11 audit closure — G030 (2026-08-06)

The shipped async executable now dispatches parsed `share <SESSION_ID>` through
`LiveShareComposition` before the generic unsupported-command guard. The route
uses the persisted tri-state `ever_used_codex` marker and the resident shared
`ExportBoundary`, so legacy records and provider-boundary crossings remain
unverifiable or denied rather than being treated as clean. A launcher-level
regression drives the real parsed command and asserts the share-specific
authentication refusal; an unrelated utility remains the negative control.

The success path is deliberately not claimed: signed-URL upload, exported-session
serialization, and backend share-link creation are still absent. After all
authorization checks, the live route returns an explicit fail-closed refusal and
the synchronous compatibility runner names the same missing network clients
instead of reporting the stale generic “not implemented” capability.

### Wave 11 audit closure — G031 (2026-08-06)

Forking is now a store-owned coupled artifact operation. The child inherits the
parent transcript, `parentSessionID`, persisted model/provider route, and the
tri-state `ever_used_codex` boundary marker before launch. When the parent has a
rewind sidecar, the flat Swift `<session>.rewind.jsonl` bytes are copied exactly;
the child `LiveSessionServices` coordinator therefore lists and restores the
same points. A sidecar-copy or child-record write failure removes partial child
artifacts, and legacy records with no boundary marker are refused before any
child file is created.

Copying the rewind sidecar is an intentional Swift recovery-safety divergence:
the inspected Rust storage-copy routine preserves summary/model and compaction
artifacts but does not copy its rewind-points file. Swift keeps the extra copy so
forked recovery state cannot silently disappear.

Focused verification (2026-08-06):

| Command | Result |
|---|---|
| `zsh workflows/swift-safe-verify.zsh test --no-parallel --filter liveSessionSandboxResumeDowngradeIsRefused` | exit 0; **1 test / 1 suite**, zero failures after the root integration fix persisted the selected sandbox profile before history construction. |

The G031 fork tests and the formerly failing sandbox-persistence regression are
both covered by the final full serial green gate recorded at the top of this
ledger.

### Wave 11 audit partial — G036 (2026-08-06)

The production transport seam now has a package-local `COpenGrokSockets`
adapter. Outside `Network.framework`, `WebSocketServer` binds the configured
TCP host/port (including ephemeral port 0), accepts raw channels, runs the
existing HTTP upgrade, and `WebSocketNetworkChannel`/`WebSocketDialer` use the
same adapter with bounded connect errors. On Unix, `UnixSocketListener` and
`UnixSocketDialer` now bind/connect `AF_UNIX` through that seam; stale endpoint
removal remains exclusively in `ACPLeaderSocketListener` after lock
acquisition. Apple builds continue to select the existing Network.framework
implementation.

The live WebSocket and leader suites no longer require `Network.framework` on
Unix, so Linux can exercise the shipped serve and leader compositions instead
of silently skipping them. The Rust reference still requires Windows leader
IPC to use path-derived named pipes (not AF_UNIX); that adapter, plus the
Windows-safe leader lock/cleanup strategy, is not claimed in this slice.

Focused verification (2026-08-06, macOS Network.framework path):

| Command | Result |
|---|---|
| `zsh workflows/swift-safe-verify.zsh build --target OpenGrokHTTP` | exit 0 |
| `zsh workflows/swift-safe-verify.zsh test --no-parallel --filter WebSocketDialerLiveTests` | exit 0; 3 tests in 1 suite, 0 failures |
| `zsh workflows/swift-safe-verify.zsh test --no-parallel --filter LiveLeaderCompositionLiveTests` | exit 0; 2 tests in 1 suite, 0 failures |
| `zsh workflows/swift-safe-verify.zsh test --no-parallel --filter ACPServeHostLiveTests` | exit 0; 7 tests in 1 suite, 0 failures |

### Wave 11 audit closure — G038 (2026-08-06)

`PlatformSecretStore.preferredBackend` now reports `.keychain` only on macOS;
Linux and Windows report `.unsupported` until native Secret Service/libsecret
and Credential Manager adapters are actually linked. Linux `makeDefault` remains
unsupported without an explicit root, selects the owner-only file backend only
when `ownerOnlyRoot` is supplied, and throws `ownerOnlyFallbackActive` when the
caller requests fail-closed fallback handling. Windows remains unsupported, and
the public all-throwing `WindowsCredentialManagerStore` placeholder is removed.
The enum values for the future native backends remain reserved but are no longer
advertised as current capabilities.

The live CLI deliberately remains file-backed for Rust parity: xAI credentials
use owner-protected `auth.json`, while Codex credentials use isolated
`codex-auth.json`; this change does not route either path through
`PlatformSecretStore`.

Focused verification (2026-08-06, macOS):

| Command | Result |
|---|---|
| `zsh workflows/swift-safe-verify.zsh test --no-parallel --filter OpenGrokSecretsTests` | exit 0; 27 tests in 1 suite, 0 failures |
| `zsh workflows/swift-safe-verify.zsh test --no-parallel --filter LiveAuthCompositionTests` | exit 0; 13 tests in 1 suite, 0 failures |

Linux and Windows conditional branches still require their respective CI legs
for host-level execution proof; no native vault dependency was added in this
remediation.

### Wave 11 audit closure — G040 (2026-08-06)

Leader locking is now platform-explicit and fail-closed. `ACPLeaderLock.acquire`
keeps the existing nonblocking POSIX `flock`/PID/sync/owner-cleanup behavior on
supported Unix platforms, while the Windows branch throws the typed
`ACPLeaderLockError.unsupportedPlatform` before creating the lock directory,
lock file, PID contents, or socket endpoint. `LiveLeaderComposition` converts
that case into a distinct Windows-unavailable CLI failure, and
`LiveLeaderClient` rethrows it instead of falling through to spawn. This is a
deliberate divergence from upstream: Swift has no Windows named-pipe leader
transport yet, so a `LockFileEx` helper alone would advertise a leader that
cannot accept clients. Full parity still requires a native Windows lock plus
the path-derived named-pipe transport described by the Rust reference.

Focused verification (2026-08-06, macOS):

| Command | Result |
|---|---|
| `zsh workflows/swift-safe-verify.zsh test --no-parallel --filter ACPLeaderLockTests` | exit 0; **3 tests / 1 suite**, 0 failures |
| `zsh workflows/swift-safe-verify.zsh test --no-parallel --filter LiveLeaderCompositionLiveTests` | exit 0; **2 tests / 1 suite**, 0 failures |

The Windows-only lock and live-composition refusal tests are compile-gated and
were not executable on this macOS runner. The portable Swift version generator
removes the prior `/bin/sh` blocker, but a post-change Windows CI run is still
required to report those tests' non-zero count and confirm the injected
`$OPENGROK_HOME` remains artifact-free there.

### Wave 11 audit closure — G048 (2026-08-06)

Local workflow availability now resolves from the effective local authority
document with the pinned Open Grok precedence: `GROK_WORKFLOWS` environment,
`[workflows].enabled`, then default enabled. The remote
`workflows_enabled` field remains wire-compatible but is intentionally ignored;
it is not an authority source for this local kill-switch. The resolver runs with
an explicit session/route working directory and its decision gates the
`workflow` route, `--workflow` launch before sampler construction or script
reading, and interactive workflow registry injection. Disabled sessions receive
no workflow registry, so the `/workflows` dashboard is not exposed.

Focused verification (2026-08-06, macOS):

| Command | Result |
|---|---|
| `zsh workflows/swift-safe-verify.zsh test --no-parallel --filter WorkflowConfigurationTests` | exit 0; **5 tests / 1 suite**, 0 failures |
| `zsh workflows/swift-safe-verify.zsh test --no-parallel --filter LiveWorkflowKillSwitchTests` | exit 0; **2 tests / 1 suite**, 0 failures |

The negative-control launch test confirms `GROK_WORKFLOWS=0` refuses through the
real `CLIRunner.run` → `OpenGrokApplication.live` path, leaves the workflow
manifest absent, and does not invoke the injected sampler factory.

### Wave 11 audit closure — G049 (2026-08-06)

The dedicated `OpenGrokSecurityTests` release target now exercises the shipped
security seams instead of declaring zero tests. The live file-tool executor
rejects a missing leaf beneath an outbound symlink, `SessionFS.writeText`
revalidates after its synchronization boundary and uses no-follow atomic
replacement, and the sandbox resume gate rejects persisted-profile weakening.
Provider selection fails closed when only another provider's store exists, and
credential-owned authorization/account headers cannot be replaced by model
metadata. The isolated-home report remains fail-closed for escaped and legacy
paths. Malicious MCP/hooks/plugins, corruption, updater safety, redaction, and
platform matrix coverage remain separate W11-S5 work.

Focused verification (2026-08-06, macOS):

| Command | Result |
|---|---|
| `zsh workflows/swift-safe-verify.zsh test --no-parallel --filter SecurityReleaseGateTests` | exit 0; **5 tests / 1 suite**, 0 failures |

The full repository suite was intentionally not run; integrated verification
remains owned by the coordinating agent.

## Next action

The work remains executable-integration and platform-proof work, not placeholder
filling. Wave 11 leaves the following ordered priorities.

### Current priorities after Wave 11

1. **Finish capable-Linux sandbox proof.** Run the behavioral filesystem,
   provider-network, and child-network checks on a runner with working
   bubblewrap and unshare namespaces; the process-wide re-exec seam is live.
2. **Expand production workspace exposure proof.** Add a loopback Hub lifecycle
   fixture covering workspace start/pause/resume/stop and permission mediation;
   the shipped connector and leader wiring are now live.
3. **Finish export clients.** The live launcher now stamps and rehydrates the
   `ever_used_codex`/non-xAI boundary and sanitizes provider-opaque history on
   resume, continue, fork, and `/model` changes. Add the signed-URL and backend
   share clients with both pre-send boundary checks intact; legacy records remain
   intentionally unverifiable and fail closed.
4. **Collect honest platform CI evidence.** The Windows `/bin/sh` plugin
   dependency is removed and Linux plus Windows compilation are now blocking
   workflow jobs. Run a disposable PR, repair any newly surfaced platform
   failures, and configure the macOS, Linux, and Windows compile checks as
   required before making a platform-green or release claim.
5. **Continue upstream catch-up and remaining live-route work** without
   weakening explicit refusals or the serialized verifier discipline.

### Historical active build-out wave (completed or superseded)

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

### Wave 11 audit closure — G050 (2026-08-06)

The formerly empty `OpenGrokFuzzingTests` and `OpenGrokPerformanceTests`
targets now execute real Swift Testing suites through the shipped Markdown,
pager, sampler, shell, and memory seams. The fuzz target checks all nine
checked-in `render_all` seeds plus bounded CRLF, truncation, delimiter, and
Unicode-safe chunk mutations in pretty and raw modes. It compares full and
streaming output, validates source/link/code ranges, and maps every render
through `PagerMarkdownRenderer` without empty spans or lost visible content.

The performance target uses a fixed `OPENGROK_PERFORMANCE_PROFILE=macos-15`
profile and reviewed budgets for 1,024 Chat chunks, a 32-document transcript,
128 ordered shell turns, and 48 persisted memory files. It deliberately does
not self-baseline during a run. Swift exposes four applicable renderer modes
(pretty/raw × full/streaming); the Rust fuzz binary also toggles Syntect on/off,
which has no Swift equivalent and is not fabricated here.

Focused verification (2026-08-06, macOS 15 / Apple Swift 6.4):

| Command | Result |
|---|---|
| `zsh workflows/swift-safe-verify.zsh build-tests` | exit 0; all test products compiled |
| `zsh workflows/swift-safe-verify.zsh test --no-parallel --filter MarkdownRenderFuzzingTests` | exit 0; **1 test / 1 suite**, 0 failures |
| `OPENGROK_PERFORMANCE_PROFILE=macos-15 zsh workflows/swift-safe-verify.zsh test --no-parallel --filter PerformanceGateTests` | exit 0; **4 tests / 1 suite**, 0 failures |

The fixed-profile performance run reported medians of **6.59 ms** for 1,024
Chat chunks (8 s budget), **3.30 s** for the large transcript renderer
(8 s), **390.56 ms** for 128 shell turns (20 s), and **43.15 ms** for 48-file
memory reindex/search/reload (8 s). These are measured medians from the clean
macOS-15 run, not self-derived limits. The full repository suite remains owned
by the coordinating agent and was intentionally not run here.

### Wave 11 audit closure — G055 (2026-08-06)

The release-confidence inventory now runs through the already-executed
`OpenGrokCompatibilityTests` target. `ReleaseGateTestInventoryTests` uses a
curated registry of the compatibility, release-validation, PagerPTY harness,
and PagerPTY targets, recursively inspects their Swift sources from a
`#filePath`-anchored package root, and reports the target plus inspected files
when no `@Test` or XCTest-style declaration is found. A synthetic empty-target
negative control proves the scanner detects the silent condition instead of
merely passing against the current tree. The pure `VirtualScreen` coverage now
belongs to `OpenGrokPagerPTYHarnessTests`, while process-backed scenarios remain
in `OpenGrokPagerPTYTests`. The fuzzing, performance, and security targets were
already test-bearing in the current tree and therefore remain declared; no
vacuous targets were removed.

Focused verification (2026-08-06, macOS):

| Command | Result |
|---|---|
| `zsh workflows/swift-safe-verify.zsh test --filter ReleaseGateTestInventoryTests --no-parallel` | exit 0; **2 tests / 1 suite**, 0 failures |
| `zsh workflows/swift-safe-verify.zsh test --filter VirtualScreenTests --no-parallel` | exit 0; **9 tests / 1 suite**, 0 failures |

The mechanical inventory now reports **102 test targets**, **0 zero-test
targets**, and **102 test targets with at least one executable declaration**.

### Wave 11 audit closure — G056 (2026-08-06) — configuration landed, platform evidence pending

The Windows version build plugin no longer invokes `/bin/sh`: SwiftPM now
executes the declared `OpenGrokVersionGenerator` target, which writes
`CompiledVersion.generated.swift` through the portable build-command seam.
Linux is a blocking job and runs the serialized verifier for build, build-tests,
and the serial test gate. Windows is split into a required `Windows (compile)`
job and a separately named `Windows (diagnostic tests)` job; only the latter is
allowed to continue on error. Both Windows jobs provision MSYS2 `zsh` before
invoking the repository verifier, so the required compile check does not rely
on raw SwiftPM commands or a Unix `/bin/sh` path.

No post-change Linux or Windows GitHub Actions run, and no repository branch
protection/ruleset update, is recorded here. The workflow is therefore fail-
closed at the job-conclusion level but is not a release/platform-green claim;
the required-check policy and real PR evidence remain integration-owner work.
