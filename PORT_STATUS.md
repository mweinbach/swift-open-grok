# Swift Open Grok Port Status

**As of:** 2026-07-21  
**Overall state:** Planning complete; Wave 0 integration-ready. All seven Sol-reported integration defects fixed: (1) `OpenGrokTestSupport → OpenGrokTestUtilities` dependency edge declared; (2) UDS frame-length byte-order double-conversion fixed + `severMidFrame` now triggers shared shutdown; (3) `EnvGuard` dispose/deinit double-restore fixed + global serialization lock; (4) CountingServer BSD double-body write fixed; (5) `OpenGrokShared → OpenGrokCLIChatProxyTypes` dependency edge declared + `FeedbackTerminalInfo` re-exported; (6) ProtoBuilder multi-proto descriptor set fixed (per-file dep scans separated from one all-input compilation) + contract formally narrowed; (7) GROK_VERSION build-time injection via `OpenGrokVersionBuildPlugin` build-tool plugin. Clean `swift build --build-tests` is green with zero unhandled-file warnings. All Wave 0 test suites pass (BuildSupport 48, TestSupport 52, TestUtilities 26, Paths 32, Environment 21, Version 43, Shared 82, CLIChatProxyTypes 99 = 403 total).  
**Destination was empty at baseline:** yes; it was not yet a Git repository.  
**Reference cleanliness:** `/tmp/open-grok-reference` was on `main...origin/main` with no local changes.  
**Swift toolchain used:** Apple Swift 6.4 (`swift-tools-version: 6.1`, `swiftLanguageModes: [.v6]`).

## Completed bootstrap integration (W0-S1)

- [x] Created `Package.swift` predeclaring all 94 library targets, the `OpenGrokExecutable` executable target, 100 test targets (94 per-library + 6 standalone), and the `OpenGrokProtoBuildPlugin` command plugin, with the full dependency graph (later waves → earlier waves only; acyclic; same-wave siblings independent). Later parallel slices never edit `Package.swift`.
- [x] Generated compilable placeholder sources for every predeclared target via `scripts/bootstrap-stubs.sh` so the whole package builds before implementation lands.
- [x] Implemented `OpenGrokBuildSupport`: Open Grok branding constants, a dependency-free pure-Swift SHA-256 (NIST-vector-verified), generated-protocol fixture manifest + validator, and the full `xai-proto-build` parity port. The `DefaultProtoCompiler` faithfully mirrors the Rust `find_protoc::find_protoc` 3-step search order (`$PROTOC` → `bin/protoc` parent walk → `$PATH` lookup), the `check_protoc_good` `--version` validation, the `find_protoc_include_dir` `../include` heuristic, the `is_github_actions()` strict-environment hard error (presence of `GITHUB_ACTIONS` is strict regardless of value — `true`, `false`, `0`, or empty string all count, matching `env::var_os("GITHUB_ACTIONS").is_some()`), and the `compile_protos` absolute-path rejection. The `ProtoBuilder` mirrors `XaiProtoBuilder` (`configure()` → chained builder knobs → `compileProtos`), invoking `protoc` directly to emit a deterministic `FileDescriptorSet` (binary or JSON) with the same include resolution, absolute-path rejection, `--dependency_out` dependency tracking, and well-known-types `/include/google/protobuf/` filter as the reference. Builder knobs `bytes`, `externPath`, `fileDescriptorSetPath`, `genPbjson`, `pbjsonIgnoreUnknownFields`, `pbjsonPreserveProtoFieldNames`, `generateDefaultStubs`, `typeAttribute`, `fieldAttribute`, `descriptorFormat`, and `emitDependencies` mirror the Rust crate's configuration surface. The `FixtureValidator` enforces path containment: every manifest entry must be a normalized relative path rooted exactly under `ProtocolFixtures`, with absolute paths, `..` traversal components, Windows drive forms, and symlink escapes rejected before any file is hashed. Injectable `workingDirectory`/`pathLookup`/`validateCandidates` seams keep discovery tests deterministic and host-independent.
- [x] Implemented the read-only, sandboxed `OpenGrokProtoBuildPlugin` command (`swift package ogrok-validate-protocols`) and the deterministic `scripts/regenerate-protocol-manifest.sh` helper; validated `ProtocolFixtures/manifest.json` freshness.
- [x] Implemented the bootstrap `OpenGrokCLI` (`version`/`help`/`paths`, `OPENGROK_HOME` resolution with `~/.opengrok` fallback, never `~/.grok`, deterministic exit codes, injectable streams) and the `open-grok` executable product.
- [x] Established platform-protocol scaffolds with `#if os` seams and typed `unsupported` errors: terminal core, TTY/raw-mode, PTY/process/signals, filesystem watchers, secrets, sandbox, system power, crash handler, and clipboard.
- [x] Added root legal/infra: `README.md`, `LICENSE` (Apache-2.0), `NOTICE`, `THIRD-PARTY-NOTICES`, and `scripts/` helpers.
- [x] Verified on 2026-07-20: `scripts/verify-bootstrap.sh` passes all 5 stages — `swift package describe`, `swift build`, `swift package ogrok-validate-protocols`, `open-grok --version` (`Open Grok 0.1.220-open-grok.21`), and the bootstrap test suites (OpenGrokBuildSupport / OpenGrokCLI / platform scaffolds). The prior W0-S2 compilation blocker (`OpenGrokTestSupportTests` could not see `OpenGrokTestUtilities`) is resolved: W0-S1 added the intra-slice test-target edge `OpenGrokTestSupportTests → OpenGrokTestUtilities` in `Package.swift` and completed the missing `import OpenGrokTestUtilities` in the W0-S2 test file. All 100 test targets now compile; `swift build --build-tests` is green.
- [x] Re-verified on 2026-07-20 (W0-S1 acceptance sweep): `swift package describe` succeeds (94 library + 1 executable + 6 standalone = 101 planned targets, 100 test targets, 1 plugin); `swift build --target OpenGrokBuildSupport` is green; `OpenGrokBuildSupportTests` passes 24/24; `swift package ogrok-validate-protocols` returns exit 0 on fresh fixtures and exit 1 on a deliberately stale manifest (proving the "fails when checked-in generated output is stale" acceptance); CRATE_MAP.md enumerates all 82 mapped crates; root `LICENSE`/`NOTICE`/`THIRD-PARTY-NOTICES` enhanced to retain full derived-source provenance — Codex source revision `2be648ba4a6c159a3d80b1c07e7323cbd5efef8f` (https://github.com/openai/codex), mermaid-to-svg MIT copyright (Denver Technologies, Inc.), dagre_rust (Apache-2.0, Copyright 2023 Ameer Hamza, v0.0.5), graphlib_rust (Apache-2.0, v0.0.2), ordered_hashmap (Apache-2.0, v0.0.3), mermaid.js/dagre.js/graphlib.js MIT ancestry, and Roboto (Apache-2.0, Copyright 2011 Google Inc.) with the corrected reference path `crates/codegen/xai-grok-mermaid/assets/Roboto-LICENSE.txt`. Transitive-package inventory remains W11-S5-generated; the Swift package currently declares zero external dependencies.
- [x] Remediated on 2026-07-20 (reviewer findings): (1) HIGH — implemented `ProtoBuilder` as a functional parity port of Rust `XaiProtoBuilder` (`configure()` → builder knobs → `compileProtos`), invoking `protoc` directly to emit a deterministic `FileDescriptorSet` (binary/JSON) with include resolution, absolute-path rejection, `--dependency_out` dependency tracking, and the well-known-types `/include/google/protobuf/` filter, mirroring `compile_protos` + `emit_rerun_if_changed`; new `ProtoCompilationOutput`, `ProtoDescriptorFormat`, `ProtoBuildError.dependencyNotFound`/`.dependencyOutputMalformed`, and `ProtoCompiler.isStrictEnvironment` protocol requirement with Rust-parity default. (2) HIGH — `OpenGrokProtoBuildPlugin` now throws `CLIError.manifestMissing` and exits nonzero when `ProtocolFixtures/manifest.json` is absent. (3) MEDIUM — both `FixtureValidator` and the plugin enforce path containment: manifest entries must be normalized relative paths rooted under `ProtocolFixtures`; absolute paths, `..` traversal, Windows drive forms, and symlink escapes (resolved-path check) are rejected before any file is hashed; new `FixturePathError` and `FixtureValidationIssue.pathEscape` types. (4) MEDIUM — `isStrictEnvironment` now matches Rust `env::var_os("GITHUB_ACTIONS").is_some()`: any key presence is strict (`true`/`false`/`0`/empty all count); the divergent test was updated. `OpenGrokBuildSupportTests` now passes 48/48 (24 original + 24 new tests covering `ProtoBuilder` API, dependency parsing, path containment, symlink escapes, and strict-environment parity).
- [x] Integrated on 2026-07-21 (Sol integration findings — all 7 defects fixed): **(1) CRITICAL** — `Package.swift` now declares `OpenGrokTestUtilities` as a direct dependency of `OpenGrokTestSupport`. The previous manifest declared both W0-S2 libraries with no edge, but `AcpClient.swift`, `EnvGuard.swift`, `Headless.swift`, `Leader.swift`, and `MockServer.swift` import `OpenGrokTestUtilities` — a clean `swift build --build-tests` failed with `unable to resolve module dependency: 'OpenGrokTestUtilities'`. The edge is now explicit. **(2) HIGH** — `UdsProxy` frame-length decode fixed: the previous expression `UInt32(bigEndian: UInt32(lenPrefix[0]) << 24 | ...)` applied a double byte-order conversion — the inner shift already produced the correct native integer, and `UInt32(bigEndian:)` re-interpreted it as big-endian, swapping bytes a second time on little-endian hosts. For `[0,0,0,3]` this evaluated to 50,331,648 instead of 3, causing the proxy to block reading a nonexistent body and the test to time out. The single-shift decode `UInt32(lenPrefix[0]) << 24 | ...` is now used. `severMidFrame` now triggers `handle.severNow()` to cancel the shared scope and shutdown both FDs, so both pumps and both socket directions terminate. `pumpConnection`'s `Thread.isExecuting` poll (racy: `isExecuting` is false before the thread starts running, so the wait loop could exit and close FDs before pumps ran) replaced with a `DispatchSemaphore` that blocks until each pump signals completion. **(3) HIGH** — `EnvGuard` dispose/deinit double-restore fixed: a `disposed` flag ensures restore-and-release happens exactly once. The per-key lock coordinator replaced with a single global lock — the environment is process-global, so the Rust `#[serial]` contract requires globally serial access, not per-key serialization. **(4) MEDIUM** — `CountingServer` BSD (non-Network) path no longer writes the JSON body twice: the response string already ends in `{}`, and the previous code wrote a separate `{}` body, leaving two extra bytes on the keep-alive connection. A `writeAll` helper with a partial-write retry loop ensures the complete response is written exactly once. **(5) MEDIUM** — `Package.swift` now declares `OpenGrokShared → OpenGrokCLIChatProxyTypes` (matching the Rust `xai-grok-shared` → `prod-mc-cli-chat-proxy-types` dependency), and `OpenGrokShared` re-exports `FeedbackTerminalInfo` via a public typealias. A downstream compile test (`ProxyReExportTests`) verifies the type is accessible from `OpenGrokShared` without importing `OpenGrokCLIChatProxyTypes`. **(6) HIGH** — `ProtoBuilder.compileProtos` now separates per-file dependency scans from one all-input compilation invocation: `scanDependencies` runs one per-file `protoc --dependency_out=/dev/stdout --descriptor_set_out=/dev/null` invocation per proto (for dependency tracking only), then `emitDescriptorSet` runs ONE all-input `protoc --descriptor_set_out=<url>` invocation with ALL protos on the command line (so a multi-proto input produces a descriptor set containing ALL root files, not just the last one). `genPbjson()` now switches `descriptorFormat` to `.json` (the Swift-native equivalent of `pbjson_build`). The builder contract is formally narrowed: `bytes`, `externPaths`, `typeAttributes`, `fieldAttributes`, `generateDefaultStubs`, `ignoreUnknownFields`, and `preserveProtoFieldNames` are documented as informational-only (recorded for downstream consumers; `protoc` does not interpret them; they control `tonic_prost_build`/`pbjson_build` code generation in Rust, which has no Swift equivalent). **(7) HIGH** — GROK_VERSION build-time injection: `OpenGrokVersionBuildPlugin` build-tool plugin generates `CompiledVersion.generated.swift` from the `GROK_VERSION` environment variable at build time (resolution: `GROK_VERSION` env → `OPEN_GROK_VERSION` file → default `0.1.220-open-grok.21`). The plugin is declared in `Package.swift` with `capability: .buildTool()` and attached to the `OpenGrokVersion` target via `plugins: [.plugin(name: "OpenGrokVersionBuildPlugin")]`. The checked-in `CompiledVersion.generated.swift` and `regenerate-compiled-version.sh` are excluded from the target (eliminating the "unhandled source file" warning). Verified: `GROK_VERSION=9.9.9-integration-review swift build --target OpenGrokVersion` produces `version: "9.9.9-integration-review"`; default build produces `version: "0.1.220-open-grok.21"`. **Remaining W10-S2 issue:** `OpenGrokCLI` still uses its own hard-coded `OpenGrokCLIVersion` constant instead of `OpenGrokVersion`; this is a future-wave (W10-S2) fix outside Wave 0 scope. Clean `swift build --build-tests` is green; all Wave 0 test suites pass (403 tests total).

## Completed planning work

- [x] Read root instructions and architecture/runtime subsystem documents.
- [x] Inventoried all Cargo manifests, source trees, tests, CLI surfaces, user-guide behavior, and license/notice files.
- [x] Confirmed 81 root workspace members plus the standalone markdown fuzz crate: 82 mapped crates.
- [x] Defined a Swift 6.1 protocol/actor/platform strategy.
- [x] Defined 12 dependency waves with 2-6 conflict-free slices per wave.
- [x] Assigned unique Swift target and source/test path ownership.
- [x] Defined global and per-slice acceptance checks.
- [x] Wrote `PORT_PLAN.md`, `CRATE_MAP.md`, and this tracker.

## Implementation status by wave

| Wave | Goal | Status | Entry condition |
|---|---|---|---|
| 0 | Bootstrap, branding, and shared foundations | Integration-ready: all 7 Sol-reported defects fixed; clean `swift build --build-tests` green; 403 Wave 0 tests pass | Planning artifacts accepted |
| 1 | Protocols, domain models, and configuration | Not started | All Wave 0 required slices integrated and green |
| 2 | Cross-platform infrastructure and terminal core | Not started | All Wave 1 required slices integrated and green |
| 3 | Authentication, models, providers, and streaming | Not started | All Wave 2 required slices integrated and green |
| 4 | Workspace, permissions, sandbox, worktrees, and Computer Hub | Not started | All Wave 3 required slices integrated and green |
| 5 | Tools, MCP, extensions, and auxiliary product services | Not started | All Wave 4 required slices integrated and green |
| 6 | Code Mode, compaction, memory, goals, and shell support | Not started | All Wave 5 required slices integrated and green |
| 7 | Session actor, persistence, provider policy, coordination, and ACP | Not started | All Wave 6 required slices integrated and green |
| 8 | Markdown, Mermaid, rendering, pager model, and shell composition | Not started | All Wave 7 required slices integrated and green |
| 9 | TUI feature slices and minimal frontend | Not started | All Wave 8 required slices integrated and green |
| 10 | Product pager and CLI surfaces | Not started | All Wave 9 required slices integrated and green |
| 11 | Distribution, differential verification, and release gates | Not started | All Wave 10 required slices integrated and green |

## Slice status legend

- **Not started:** no target implementation is integrated.
- **In progress:** owner is editing only assigned source/test paths.
- **Target green:** target-scoped build/tests pass, but Package.swift/wave integration may be pending.
- **Integrated:** bootstrap owner added target edges and wave integration tests pass.
- **Blocked:** a concrete missing contract/platform dependency is recorded with an owner; never use a silent stub for security or persistence behavior.
- **Complete:** acceptance checks and required differential/E2E gates pass.

## Ownership rules

- `W0-S1` alone may edit `Package.swift`, `PORT_PLAN.md`, `CRATE_MAP.md`, `PORT_STATUS.md`, and root legal aggregation.
- Every other slice owns exactly the paths listed in `PORT_PLAN.md`; no two slices share a `Sources/<Target>/` or `Tests/<Target>Tests/` path.
- Same-wave slices use earlier-wave protocols and test fakes. They do not create imports on same-wave concrete targets.
- Status changes must name the slice ID, target-scoped checks, integrated checks, and any known parity divergence.

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

## Known high-risk areas to resolve early

1. Uniform JavaScript runtime packaging for Code Mode across macOS/Linux/Windows while preserving persistent-cell and cancellation semantics.
2. SwiftPM-compatible SQLite, syntax grammar, PTY/ConPTY, sandbox, filesystem watch, and secure-store adapters with acceptable licenses.
3. Exact Rust persisted-session/config fixture migration, especially opaque Codex history, compaction carriers, unknown fields, and export-boundary markers.
4. Terminal Unicode width/inline restoration parity and deterministic PTY snapshots across terminal implementations.
5. Provider stream compatibility and account-atomic Codex OAuth headers under retries, model switches, and logout races.
6. Windows sandbox/update/process semantics where the OS offers different primitives; unsupported paths must be explicit and tested.

## Next action

Wave 0 is integration-ready: all 7 Sol-reported defects are fixed, `swift build --build-tests` is green, and all 403 Wave 0 tests pass. `Package.swift` now declares the `OpenGrokTestSupport → OpenGrokTestUtilities` and `OpenGrokShared → OpenGrokCLIChatProxyTypes` edges, the `OpenGrokVersionBuildPlugin` build-tool plugin injects `GROK_VERSION` at build time, and `ProtoBuilder` separates per-file dependency scans from one all-input descriptor-set compilation. The remaining W10-S2 `OpenGrokCLI` version bypass is a future-wave issue. Wave 1 may now begin.

## Known verification blockers

All Sol-reported Wave 0 integration defects are **resolved** as of 2026-07-21. Clean `swift build --build-tests` is green with zero unhandled-file warnings. All Wave 0 test suites pass: BuildSupport 48, TestSupport 52, TestUtilities 26, Paths 32, Environment 21, Version 43, Shared 82, CLIChatProxyTypes 99 (403 total).

**Remaining future-wave issue (not a Wave 0 blocker):**
- **W10-S2 `OpenGrokCLI`** — `OpenGrokCLI/Version.swift` still uses its own hard-coded `OpenGrokCLIVersion` constant instead of importing `OpenGrokVersion`. The `OpenGrokVersion` target now properly injects `GROK_VERSION` at build time via the `OpenGrokVersionBuildPlugin` build-tool plugin, but the bootstrap `OpenGrokCLI` (W0-S1-implemented, W10-S2-owned) does not consume it. When W10-S2 replaces the bootstrap CLI, it must import `OpenGrokVersion` and remove `OpenGrokCLIVersion`. This is outside Wave 0 scope.

## Per-crate port status (all 82 Rust crates accounted for)

Status legend: **pending** (bootstrap placeholder stub only) · **in-progress** (real implementation started; scaffold or partial; tests may fail) · **ported** (implementation complete and target-scoped tests green for current scope) · **deferred-with-reason** (intentionally no standalone target; absorbed with documented rationale).

| # | Rust crate | Swift target(s) | Status | Notes |
|---:|---|---|---|---|
| 1 | `dagre_rust` | `OpenGrokMermaidLayout` | pending | W8-S2 stub. |
| 2 | `graphlib_rust` | `OpenGrokMermaidLayout` | pending | W8-S2 stub. |
| 3 | `mermaid-to-svg` | `OpenGrokMermaidLayout`, `OpenGrokMermaid` | pending | W8-S2 stub. |
| 4 | `ordered_hashmap` | `OpenGrokMermaidLayout` | pending | W8-S2 stub. |
| 5 | `prod-mc-cli-chat-proxy-types` | `OpenGrokCLIChatProxyTypes` | ported | W0-S4 implemented; 99 tests green; `OpenGrokShared` now depends on this target and re-exports `FeedbackTerminalInfo`. |
| 6 | `ptyctl` | `OpenGrokPTY` | in-progress | W0-S1 platform scaffold green; full port W2-S4. |
| 7 | `ptyctl-cli` | `OpenGrokPTYCLI` | pending | W2-S4 stub. |
| 8 | `xai-acp-lib` | `OpenGrokACP` | pending | W1-S2 stub. |
| 9 | `xai-agent-lifecycle` | `OpenGrokAgentLifecycle` | pending | W1-S2 stub. |
| 10 | `xai-chat-state` | `OpenGrokChatState` | pending | W1-S3 stub. |
| 11 | `xai-circuit-breaker` | `OpenGrokCircuitBreaker` | pending | W2-S1 stub. |
| 12 | `xai-codebase-graph` | `OpenGrokCodebaseGraph` | pending | W2-S3 stub. |
| 13 | `xai-computer-hub-core` | `OpenGrokComputerHubCore` | pending | W4-S4 stub. |
| 14 | `xai-computer-hub-mcp-adapter` | `OpenGrokComputerHubMCPAdapter` | pending | W5-S4 stub. |
| 15 | `xai-computer-hub-sdk` | `OpenGrokComputerHubSDK` | pending | W4-S4 stub. |
| 16 | `xai-crash-handler` | `OpenGrokCrashHandler` | in-progress | W0-S1 platform scaffold green; full port W2-S4. |
| 17 | `xai-fast-worktree` | `OpenGrokFastWorktree` | pending | W4-S2 stub. |
| 18 | `xai-file-utils` | `OpenGrokFileUtils` | pending | W2-S2 stub. |
| 19 | `xai-fsnotify` | `OpenGrokFSNotify` | in-progress | W0-S1 platform scaffold green; full port W2-S3. |
| 20 | `xai-gix-status` | `OpenGrokGitStatus` | pending | W2-S3 stub. |
| 21 | `xai-grok-agent` | `OpenGrokAgentDefinitions` | pending | W5-S6 stub. |
| 22 | `xai-grok-announcements` | `OpenGrokAnnouncements` | pending | W5-S6 stub. |
| 23 | `xai-grok-auth` | `OpenGrokAuth` | pending | W3-S1 stub. |
| 24 | `xai-grok-code-mode` | `OpenGrokCodeMode`, `OpenGrokJavaScriptRuntime` | pending | W6-S1 stub. |
| 25 | `xai-grok-code-mode-protocol` | `OpenGrokCodeModeProtocol` | pending | W1-S4 stub. |
| 26 | `xai-grok-compaction` | `OpenGrokCompaction` | pending | W6-S2 stub. |
| 27 | `xai-grok-config` | `OpenGrokConfig` | pending | W1-S5 stub. |
| 28 | `xai-grok-config-types` | `OpenGrokConfigTypes` | pending | W1-S5 stub. |
| 29 | `xai-grok-env` | `OpenGrokEnvironment` | ported | W0-S3 implemented; 15 tests green. |
| 30 | `xai-grok-hooks` | `OpenGrokHooks` | pending | W5-S5 stub. |
| 31 | `xai-grok-http` | `OpenGrokHTTP` | pending | W2-S1 stub. |
| 32 | `xai-grok-markdown` | `OpenGrokMarkdown` | pending | W8-S1 stub. |
| 33 | `xai-grok-markdown-core` | `OpenGrokMarkdownCore` | pending | W8-S1 stub. |
| 34 | `xai-grok-markdown-fuzz` | `OpenGrokFuzzingTests` | pending | W11-S4 stub. |
| 35 | `xai-grok-mcp` | `OpenGrokMCP` | pending | W5-S4 stub. |
| 36 | `xai-grok-memory` | `OpenGrokMemory` | pending | W6-S3 stub. |
| 37 | `xai-grok-mermaid` | `OpenGrokMermaid` | pending | W8-S2 stub. |
| 38 | `xai-grok-models` | `OpenGrokModels` | pending | W3-S2 stub. |
| 39 | `xai-grok-pager` | `OpenGrokPagerModel`/`Runtime`/`ConversationUI`/`CommandUI`/`OperationsUI`/`Pager` | pending | W8-S4/W9/W10 stubs. |
| 40 | `xai-grok-pager-bin` | `OpenGrokCLI`, `OpenGrokExecutable`, `OpenGrokDistributionSupport` | in-progress | W0-S1 bootstrap CLI/executable green (`--version`/`help`/`paths`); full parser + distribution W10-S2/W11-S1. |
| 41 | `xai-grok-pager-minimal` | `OpenGrokPagerMinimal` | pending | W9-S5 stub. |
| 42 | `xai-grok-pager-pty-harness` | `OpenGrokPagerPTYHarness`, `OpenGrokPagerPTYTests` | pending | W11-S3 stub. |
| 43 | `xai-grok-pager-render` | `OpenGrokPagerRender` | pending | W8-S3 stub. |
| 44 | `xai-grok-paths` | `OpenGrokPaths` | ported | W0-S3 implemented; 32 tests green. |
| 45 | `xai-grok-plugin-marketplace` | `OpenGrokPluginMarketplace` | pending | W5-S5 stub. |
| 46 | `xai-grok-sampler` | `OpenGrokSampler` | pending | W3-S3 stub. |
| 47 | `xai-grok-sampling-types` | `OpenGrokSamplingTypes` | pending | W1-S3 stub. |
| 48 | `xai-grok-sandbox` | `OpenGrokSandbox` | in-progress | W0-S1 platform scaffold green; full port W4-S1. |
| 49 | `xai-grok-secrets` | `OpenGrokSecrets` | in-progress | W0-S1 platform scaffold green; full port W2-S2. |
| 50 | `xai-grok-shared` | `OpenGrokShared` | ported | W0-S4 implemented; 82 tests green; depends on `OpenGrokCLIChatProxyTypes` and re-exports `FeedbackTerminalInfo` (Rust parity). |
| 51 | `xai-grok-shell` | `OpenGrokGoalState`/`SessionRuntime`/`SessionPersistence`/`ProviderSession`/`AgentCoordinator`/`ACPRuntime`/`Shell` | pending | W6-S3/W7/W8-S5 stubs. |
| 52 | `xai-grok-shell-base` | `OpenGrokShellBase` | pending | W6-S4 stub. |
| 53 | `xai-grok-shell-session-support` | `OpenGrokShellSessionSupport` | pending | W6-S4 stub. |
| 54 | `xai-grok-subagent-resolution` | `OpenGrokSubagentResolution` | pending | W6-S5 stub. |
| 55 | `xai-grok-telemetry` | `OpenGrokTelemetry` | pending | W2-S1 stub. |
| 56 | `xai-grok-test-support` | `OpenGrokTestSupport` | ported | W0-S2 implemented; 52 tests green; UDS byte-order, EnvGuard double-restore, CountingServer double-body, and pump thread sync all fixed; depends on `OpenGrokTestUtilities` (declared in Package.swift). |
| 57 | `xai-grok-tools` | `OpenGrokToolRegistry`/`FileTools`/`ExecutionTools`/`WebMediaTools`/`AgentControlTools` | pending | W5 stubs. |
| 58 | `xai-grok-tools-api` | `OpenGrokToolsAPI` | pending | W1-S1 stub. |
| 59 | `xai-grok-update` | `OpenGrokUpdate` | pending | W5-S6 stub. |
| 60 | `xai-grok-version` | `OpenGrokVersion` | ported | W0-S3 implemented; 31 tests green. |
| 61 | `xai-grok-voice` | `OpenGrokVoice` | pending | W5-S6 stub. |
| 62 | `xai-grok-workspace` | `OpenGrokWorkspace` | pending | W4-S3 stub. |
| 63 | `xai-grok-workspace-client` | `OpenGrokWorkspaceClient` | pending | W4-S4 stub. |
| 64 | `xai-grok-workspace-types` | `OpenGrokWorkspaceTypes` | pending | W1-S4 stub. |
| 65 | `xai-hooks-plugins-types` | `OpenGrokHooksPluginTypes` | pending | W1-S4 stub. |
| 66 | `xai-hunk-tracker` | `OpenGrokHunkTracker` | pending | W2-S3 stub. |
| 67 | `xai-interjection-core` | `OpenGrokInterjection` | pending | W1-S2 stub. |
| 68 | `xai-mixpanel` | `OpenGrokTelemetry` | deferred-with-reason | Mixpanel-compatible events absorbed into `OpenGrokTelemetry`; no standalone target. |
| 69 | `xai-prompt-queue` | `OpenGrokPromptQueue` | pending | W1-S2 stub. |
| 70 | `xai-proto-build` | `OpenGrokBuildSupport`, `OpenGrokProtoBuildPlugin` | ported | W0-S1 implemented; 48 tests green; `ProtoBuilder` provides functional `compile_protos` parity (descriptor-set emission with per-file dep scans separated from one all-input compilation, dependency tracking, include resolution); contract formally narrowed for informational-only builder knobs; path containment enforced in both validator and plugin. |
| 71 | `xai-ratatui-inline` | `OpenGrokTerminalCore` | in-progress | W0-S1 platform scaffold green; full port W2-S5. |
| 72 | `xai-ratatui-textarea` | `OpenGrokTextArea` | pending | W2-S5 stub. |
| 73 | `xai-sqlite-journal` | `OpenGrokSQLiteJournal` | pending | W2-S2 stub. |
| 74 | `xai-system-power` | `OpenGrokSystemPower` | in-progress | W0-S1 platform scaffold green; full port W2-S4. |
| 75 | `xai-test-utils` | `OpenGrokTestUtilities` | ported | W0-S2 implemented; 17 tests green. |
| 76 | `xai-token-estimation` | `OpenGrokTokenEstimation` | pending | W1-S3 stub. |
| 77 | `xai-tool-protocol` | `OpenGrokToolProtocol` | pending | W1-S1 stub. |
| 78 | `xai-tool-runtime` | `OpenGrokToolRuntime` | pending | W1-S1 stub. |
| 79 | `xai-tool-types` | `OpenGrokToolTypes` | pending | W1-S1 stub. |
| 80 | `xai-tracing` | `OpenGrokTracing` | pending | W2-S1 stub. |
| 81 | `xai-tracing-macros` | `OpenGrokTracing` | deferred-with-reason | Rust tracing macros absorbed into ordinary Swift APIs in `OpenGrokTracing`; no macro target. |
| 82 | `xai-tty-utils` | `OpenGrokTTY` | in-progress | W0-S1 platform scaffold green; full port W2-S4. |

**Status tally:** ported = 8 crates (`xai-proto-build`, `xai-grok-paths`, `xai-grok-env`, `xai-grok-version`, `xai-test-utils`, `xai-grok-shared`, `prod-mc-cli-chat-proxy-types`, `xai-grok-test-support`) · in-progress = 9 crates (W0-S1 scaffolds + bootstrap CLI) · deferred-with-reason = 2 crates (`xai-tracing-macros`, `xai-mixpanel`) · pending = 63 crates (bootstrap stubs awaiting their owning wave). Total = 82.
