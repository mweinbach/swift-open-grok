# E2E Test Infra: Swift Open Grok Core Parity

## Test Philosophy
- **Opaque-Box & Requirement-Driven**: Derived strictly from `ORIGINAL_REQUEST.md` and user-facing CLI/ACP/session contracts without internal implementation coupling.
- **100% Swift Testing**: All tests written using Swift Testing (`import Testing`, `@Suite`, `@Test`, `#expect`, `try #require`). Zero legacy `XCTest`.
- **Strict Concurrency & Hermetic Isolation**: Isolated `$OPENGROK_HOME`, `HermeticEnv`, `MockInferenceServer` on `127.0.0.1:0`, private scratch paths.
- **Authoritative Green Gate**: Validated serially via `zsh workflows/swift-safe-verify.zsh test --no-parallel` with ceiling timeouts.

## Feature Inventory & Test Coverage Matrix

| # | Feature | Target Test File | Tier 1 (Count) | Tier 2 (Count) | Tier 3 (Pairwise) | Tier 4 (Scenario) |
|---|---------|------------------|:--------------:|:--------------:|:-----------------:|:-----------------:|
| 1 | Compaction Checkpoint Persistence | `Tests/OpenGrokCompactionTests/CompactionCheckpointTests.swift` | 5 | 5 | ✓ | ✓ |
| 2 | Cross-Compaction Rewind Replay | `Tests/OpenGrokCLITests/LiveCompactionRewindReplayTests.swift` | 5 | 5 | ✓ | ✓ |
| 3 | Two-Pass Prefire Background Compaction | `Tests/OpenGrokCompactionTests/TwoPassPrefireCompactionTests.swift` | 5 | 5 | ✓ | ✓ |
| 4 | Two-Pass Assembly & Invalidation | `Tests/OpenGrokCompactionTests/TwoPassAssemblyInvalidationTests.swift` | 5 | 5 | ✓ | ✓ |
| 5 | StructuredOutput Synthetic Tool Loop | `Tests/OpenGrokCLITests/LiveConversationStructuredOutputTests.swift` | 5 | 5 | ✓ | ✓ |
| 6 | Monotonic Export Boundary (`ever_used_codex`) | `Tests/OpenGrokCLITests/ExportBoundaryE2ETests.swift` | 5 | 5 | ✓ | ✓ |
| 7 | Full Serial Verification & CLI Parity Ledger | `Tests/OpenGrokCLITests/CLIRunnerE2ETests.swift` & `Tests/OpenGrokCompatibilityTests/` | 5 | 5 | ✓ | ✓ |
| **Total** | | | **35** | **35** | **7** | **5** | **82+ Cases** |

## Test Architecture & Tier Definitions

### Tier 1: Feature Coverage (≥5 per feature)
- Happy-path and contract verification of each feature in isolation.
- Structured JSON schemas, serialization roundtrips, atomic writes, system reminders, token calculations, CLI subcommands.

### Tier 2: Boundary & Corner Cases (≥5 per feature)
- Extreme and error conditions: empty transcripts, context overflow, 3x JSON schema retry exhaustion, missing/corrupt checkpoint files, rapid consecutive rewinds, concurrent provider switches, stream separation.

### Tier 3: Cross-Feature Interactions
- Interaction of multiple features:
  - Checkpoint Persistence + Cross-Compaction Rewind + Sticky Export Boundary (`ever_used_codex`)
  - Two-Pass Prefire + User Interjection + Invalidation
  - Compaction Checkpoints + Swarm Subagent Fork
  - Two-Pass Assembly + Code Mode Persistent V8 Cell
  - StructuredOutput Synthetic Tool Loop + Auto-Compaction
  - Monotonic Export Boundary + Mid-Share Race Condition
  - CLI Headless Mode + Model Switch + Provider Isolation

### Tier 4: Real-World Application Scenarios
- Realistic end-to-end workflows:
  - Multi-hour developer session simulation with 45 turns, 3 compactions, 2 rewinds, and tool calls.
  - Crash recovery after compaction checkpoint persistence and session resume.
  - High-frequency prefire hit-rate benchmark simulation.
  - Headless structured JSON extraction workflow with Messages API mock.
  - Full CLI lifecycle in an isolated environment (doctor -> paths -> models -> headless -> sessions -> export boundary check).

## Test Runner & Verification
- Build tests: `zsh workflows/swift-safe-verify.zsh build-tests`
- Full serial verification: `zsh workflows/swift-safe-verify.zsh test --no-parallel`
- Product build: `zsh workflows/swift-safe-verify.zsh build --product open-grok`
