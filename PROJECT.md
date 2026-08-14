# Project: Swift Open Grok Core Parity Porting

## Architecture
- **Language & Runtime**: Swift 6, strict concurrency (`Sendable`, actor isolation, non-blocking asynchronous I/O).
- **Core Subsystems**:
  - `OpenGrokShell` / `OpenGrokSessionRuntime` / `OpenGrokCLI`: Turn loop, agentic sampling, tool dispatch, session actors.
  - `OpenGrokACP` / `OpenGrokACPRuntime`: Stdio, WebSocket Serve, WebSocket Relay, Leader IPC, reverse-RPC protocols.
  - `OpenGrokCompaction` / `OpenGrokSessionPersistence`: Single-pass and two-pass context compaction, Codex Remote V2, checkpoint persistence, cross-compaction rewind.
  - `OpenGrokWorkspace` / `OpenGrokSandbox` / `OpenGrokFastWorktree` / `OpenGrokHunkTracker`: 7-stage permission pipeline, folder trust, platform sandboxing, CoW worktree cloning, explicit agent hunk attribution.
  - `OpenGrokAgentCoordinator` / `OpenGrokAgentControlTools`: Subagent coordinator, swarm detach/rejoin (`SwarmRegistry`, `swarm_wait`), flat-team mailboxes (`list_agents`, `send_message`, `followup_task`, `wait_agent`).

## Feature Inventory
| # | Feature | Description | Milestone | Source |
|---|---------|-------------|-----------|--------|
| 1 | Compaction Checkpoint Persistence | `CompactionCheckpointFile` (`compaction_checkpoints/<id>.json`), event emission in `updates.jsonl` | M1 | Survey (Explorer 3) |
| 2 | Cross-Compaction Rewind Replay | Replay prompt history across compaction boundaries using saved checkpoints | M1 | Survey (Explorer 3) |
| 3 | Two-Pass Prefire Background Compaction | Background pass-1 at lead threshold (95% prefix -> `NOTE1` cache with fingerprint hash) | M2 | Survey (Explorer 3) |
| 4 | Two-Pass Pass-2 Assembly & Invalidation | Combine `NOTE1` with verbatim tail, invalidate on prefix edits | M2 | Survey (Explorer 3) |
| 5 | StructuredOutput Synthetic Tool Loop | Intercept `StructuredOutput` tool calls with 3x validation retry for non-native backends | M3 | Survey (Explorer 1) |
| 6 | Monotonic Export Boundary ACP Enforcement | Wire `ever_used_codex` export gating across all session routes | M3 | Survey (Explorer 3) |
| 7 | Full E2E Serial Verification & Ledger Sync | Pass 100% test suite via `swift-safe-verify.zsh test --no-parallel`, zero regressions, update `PORT_STATUS.md` | M4 | Original Request |

## Milestones
| # | Name | Scope | Dependencies | Status |
|---|------|-------|-------------|--------|
| 1 | M1: Compaction Checkpoints & Rewind | Implement `CompactionCheckpoint.swift`, persist checkpoints, integrate into `LiveCompactionCoordinator`, implement checkpoint rewind in `LiveConversationStore` | none | DONE |
| 2 | M2: Two-Pass Prefire Compaction | Implement `TwoPassCompaction.swift` (`AsyncCompactionCache`, `splitConversationForTwoPass`, `fingerprintPrefix`), wire into `LiveCompactionCoordinator` | M1 | DONE |
| 3 | M3: StructuredOutput & Export Boundary | Implement `StructuredOutput` synthetic tool loop in `LiveConversationStore`, audit and enforce `ever_used_codex` across ACP session routes | M1 | DONE |
| 4 | M4: Final E2E Suite & Green Gate | Full serial suite verification (`test --no-parallel`), adversarial testing, `PORT_STATUS.md` update | M1, M2, M3 | DONE |

## Interface Contracts
### `OpenGrokSessionPersistence` ↔ `OpenGrokCompaction` / `LiveCompactionCoordinator`
- `persistCompactionCheckpoint(sessionDir: URL, checkpointId: String, promptIndex: Int, compactedHistory: [ConversationItem], originalUserInfo: String?) throws -> CompactionCheckpointInfo`
- `loadCompactionCheckpoint(sessionDir: URL, checkpointId: String) throws -> CompactionCheckpointFile`
- `listCompactionCheckpoints(sessionDir: URL) throws -> [CompactionCheckpointInfo]`

### `OpenGrokCompaction` ↔ `LiveCompactionCoordinator`
- `shouldPrefireTwoPass(budget: CompactionBudget, currentTokens: Int, leadPercent: Double) -> Bool`
- `splitConversationForTwoPass(_ items: [ConversationItem], splitFraction: Double) -> (prefix: [ConversationItem], tail: [ConversationItem], splitIndex: Int)`
- `fingerprintPrefix(_ items: [ConversationItem]) -> UInt64`
- `assembleTwoPassSummary(note1: String, tail: [ConversationItem], summaryPrompt: String) -> String`

### `LiveConversationStore` ↔ `LiveCompaction` (Rewind Replay)
- `replayWithCompactionCheckpoints(sessionDir: URL, targetPromptIndex: Int, updates: [SessionUpdate]) throws -> [ConversationItem]`

## Code Layout
- `Sources/OpenGrokSessionPersistence/CompactionCheckpoint.swift` (New file, ~220 LOC)
- `Sources/OpenGrokCompaction/TwoPassCompaction.swift` (New file, ~320 LOC)
- `Sources/OpenGrokCLI/LiveCompaction.swift` (Modify, hook checkpoint persistence & two-pass prefire)
- `Sources/OpenGrokCLI/LiveConversationStore.swift` (Modify, hook checkpoint rewind replay & structured output synthetic loop)
- `Tests/OpenGrokCompactionTests/CompactionCheckpointTests.swift` (New test suite)
- `Tests/OpenGrokCompactionTests/TwoPassCompactionTests.swift` (New test suite)
- `Tests/OpenGrokCLITests/LiveConversationStructuredOutputTests.swift` (New test suite)
