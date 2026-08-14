# TEST_READY: Swift Open Grok Parity Verification

**Status:** READY & VERIFIED (100% Green Gate)  
**Date:** 2026-08-14  
**Reference Pin:** `650c1db7c2e73c59cec88bf3c6359751d6cef1bd` (`v0.1.220-open-grok.58`) / Forward Sync `b849ec76` (`v1.0.0-open-grok.62`)  
**Swift Toolchain:** Apple Swift 6.4 (Swift 6 strict concurrency, `swift-tools-version: 6.1`)

---

## 1. Test Execution Commands

All builds and test invocations MUST be executed via the safe serializing workflow wrapper:

### Test Build Command
```sh
zsh workflows/swift-safe-verify.zsh build-tests
```
- **Exit Code:** `0`
- **Elapsed Duration:** 8.38s

### Authoritative Serial Test Gate
```sh
zsh workflows/swift-safe-verify.zsh test --no-parallel
```
- **Exit Code:** `0`
- **Test Metrics:** **6,778 tests in 1,048 suites passed**
- **Issues / Failures:** **0**
- **Elapsed Duration:** 285.72s (Execution), 4m 53s (Wall clock)

### Product Executable Build
```sh
zsh workflows/swift-safe-verify.zsh build --product open-grok
```
- **Exit Code:** `0`
- **Elapsed Duration:** 6.24s

---

## 2. Test Coverage Summary Matrix

The test architecture is structured into 4 comprehensive tiers ensuring unit isolation, boundary resilience, multi-feature pairwise interactions, and full end-to-end application lifecycle workflows.

| # | Feature Domain | Primary Test Suite File | Tier 1 (Unit & Happy Path) | Tier 2 (Boundary & Errors) | Tier 3 (Cross-Feature) | Tier 4 (Real-World Scenarios) | Total Dedicated Tests |
|---|----------------|-------------------------|:--------------------------:|:--------------------------:|:----------------------:|:-----------------------------:|:---------------------:|
| 1 | **Compaction Checkpoint Persistence** | `Tests/OpenGrokCompactionTests/CompactionCheckpointTests.swift` | 5 | 5 | ✓ (T3-Case 1,3) | ✓ (T4-Scen 1,2) | 10+ |
| 2 | **Cross-Compaction Rewind Replay** | `Tests/OpenGrokCLITests/LiveCompactionRewindReplayTests.swift` | 6 | 6 | ✓ (T3-Case 1) | ✓ (T4-Scen 1,2) | 12+ |
| 3 | **Two-Pass Prefire Background Compaction** | `Tests/OpenGrokCompactionTests/TwoPassPrefireCompactionTests.swift` | 6 | 6 | ✓ (T3-Case 2) | ✓ (T4-Scen 3) | 12+ |
| 4 | **Two-Pass Assembly & Invalidation** | `Tests/OpenGrokCompactionTests/TwoPassAssemblyInvalidationTests.swift` | 6 | 6 | ✓ (T3-Case 2,4) | ✓ (T4-Scen 3) | 12+ |
| 5 | **StructuredOutput Synthetic Tool Loop** | `Tests/OpenGrokCLITests/LiveConversationStructuredOutputTests.swift` | 6 | 5 | ✓ (T3-Case 5) | ✓ (T4-Scen 4) | 11+ |
| 6 | **Monotonic Export Boundary (`ever_used_codex`)** | `Tests/OpenGrokCLITests/ExportBoundaryE2ETests.swift` | 5 | 7 | ✓ (T3-Case 1,6) | ✓ (T4-Scen 5) | 12+ |
| 7 | **Full Serial Verification & CLI Parity Ledger** | `Tests/OpenGrokCLITests/CLIRunnerE2ETests.swift` & `OpenGrokCompatibilityTests` | 6 | 6 | ✓ (T3-Case 7) | ✓ (T4-Scen 5) | 12+ |
| **Sum** | **Core Feature Slices** | **All Modules** | **40** | **41** | **7** | **5** | **93 Dedicated Cases** |

---

## 3. Comprehensive Feature Checklist

### Feature 1: Compaction Checkpoint Persistence
- [x] `CompactionCheckpointFile` and `CompactionCheckpointInfo` JSON round-trip serialization with sorted keys.
- [x] Forward schema version validation (`schemaVersion <= 1`) failing closed on unsupported versions.
- [x] Atomic on-disk persistence under `compaction_checkpoints/<checkpoint-id>.json`.
- [x] Checkpoint listing, loading, and directory copying (`copyCheckpoints(from:to:)`) for session forking.
- [x] History sanitization removing orphaned tool result/output items before serialization.
- [x] Reduction ratio guard (`compactionMeetsReductionGuard`) ensuring token decrease.

### Feature 2: Cross-Compaction Rewind Replay
- [x] Replay to post-compaction prompt targets reconstructing conversation from checkpoint base + post-compaction turns.
- [x] Replay across compaction boundaries to pre-compaction prompt targets dropping compaction summary and rebuilding raw prompt turns.
- [x] Preservation and restoration of `originalUserInfo` across rewind points.
- [x] Multi-generation sequential rewinds across multiple intermediate checkpoints (`ckpt-1` -> `ckpt-2` -> `ckpt-3`).
- [x] Coordination with `LiveRewindCoordinator` for workspace file snapshot capture and rollback.
- [x] Handling missing/corrupted checkpoint files with typed `CompactionCheckpointError`.
- [x] RewindMarker timeline branching support in `replayToPrompt`.

### Feature 3: Two-Pass Prefire Background Compaction
- [x] Prefire threshold calculation with lead percentage (`leadPercent = 10%`, threshold = 85%) and provider guard (skipping Codex server-side compaction).
- [x] 95% token weight split computation (`splitConversationForTwoPass`) maintaining non-empty tail.
- [x] Tool boundary snapping ensuring tool calls and corresponding tool results / custom outputs remain unsplit across prefix/tail boundaries.
- [x] 5-section Pass 1 prompt formatting (`buildTwoPassCompactionPrompt`, `buildTwoPassPass1History`).
- [x] `NOTE₁` extraction preferring `<summary>` tag content with 12,000 character capping.
- [x] In-flight concurrency protection via `PrefireState` (`tryBegin()` / `finish()`).
- [x] `AsyncCompactionCache` storage with 64-bit FNV-1a prefix fingerprinting.

### Feature 4: Two-Pass Assembly & Invalidation
- [x] Pass 2 4-part history assembly (`buildTwoPassPass2History`: System + Carrier Turn with `NOTE₁` + Verbatim Tail + Special Instruction Turn).
- [x] Cache validation matching prefix token length, model slug, and prefix hash.
- [x] Single-use cache consumption semantics via `prefireState.take()`.
- [x] In-flight Pass 1 task await before Pass 2 execution.
- [x] Multi-dimensional cache invalidation (prefix content edits, model switches, rewind truncations) triggering safe single-pass fallback.
- [x] Degenerate/empty Pass 1 summary fallback to standard single-pass compaction without throwing.

### Feature 5: StructuredOutput Synthetic Tool Loop
- [x] `JSONSchemaValidator` validating primitive types, objects, arrays, required fields, additional properties, enums, and numerical ranges (`minimum`, `maximum`).
- [x] Mode negotiation: native JSON schema for Chat Completions vs synthetic `StructuredOutput` tool injection for Messages / Responses backends.
- [x] Automatic suppression of `StructuredOutput` tool injection under Code Mode Only.
- [x] Co-emitted tool call filtering: stripping `StructuredOutput` and returning refusal message when emitted alongside execution tools.
- [x] In-turn validation retry loop with up to 3 retries appending schema error feedback to tool results.
- [x] Hard exhaustion failure on 4th invalid attempt terminating turn cleanly.

### Feature 6: Monotonic Export Boundary (`ever_used_codex`)
- [x] Fresh sessions start with export boundary OPEN (`allowsXaiExport == true`, `everUsedNonXAI == false`).
- [x] Observation of any non-xAI provider (Codex, Kimi, Fireworks, DeepSeek, Wafer, Z AI, OpenCode Go) closes the boundary immediately.
- [x] Monotonicity invariant: once closed, the boundary NEVER reopens, even if subsequent turns observe xAI models.
- [x] Disk persistence roundtrip: `"ever_used_codex": true` written to session JSON and restored upon load.
- [x] `ShareExportGate` export refusal with `ShareRefusal.nonXaiProviderBoundary`.
- [x] Mid-share race protection: `authorizePostExport` throws `boundaryCrossedDuringShare` if provider switches while export is in-flight.
- [x] Rejection priority: closed export boundary check outranks empty transcript checks.
- [x] Subagent boundary inheritance: subagents executing non-xAI models mutate and close parent's shared export boundary.

### Feature 7: Full Serial Verification & CLI Parity Ledger
- [x] Deterministic CLI exit codes (0 = success, 1 = failure, 2 = usage error, 3 = unsupported sync route, 130 = cancelled).
- [x] Stream separation: pure JSON output on stdout; diagnostics, warnings, and logs on stderr.
- [x] Hermetic `$OPENGROK_HOME` isolation: custom home paths strictly honored without modifying real user state.
- [x] Core CLI subcommands verified: `version`, `paths`, `help`, `models`, `completions`, `doctor`, `sessions`.
- [x] Upstream parity ledger sync in `PORT_STATUS.md` validated against protocol fixtures and reference pins.

---

## 4. Verification Gate Attestation

- **Workspace Test Targets:** 100% Compiling and Linking.
- **Suite Execution:** Full Serial Swift Testing Gate (`workflows/swift-safe-verify.zsh test --no-parallel`).
- **Pass Rate:** **100% (6,778 / 6,778 tests passing across 1,048 suites)**.
- **Regressions:** **0**.
- **Executable Product:** `open-grok` builds and links cleanly.
