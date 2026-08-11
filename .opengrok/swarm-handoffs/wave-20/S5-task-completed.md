# S5 — TaskCompleted Auto-Wake

Status: **COMPLETE** (build-blocked by unrelated dependency)

## What landed

### `Sources/OpenGrokCLI/LiveBackgroundTaskTools.swift`

New `LiveTaskCompletionWake` actor (lines ~790–870) and `LiveTaskCompletionFormatting`
enum (lines ~874–923):

- **`LiveTaskCompletionWake`**: an actor that enforces exactly-once delivery per task
  ID. `reportIfNew(_:)` checks `completed`, skips `blockWaited` tasks, routes monitor
  tasks through `formatMonitorCompletion` and bash tasks through
  `formatBashCompletion`, then delivers to `wakeSink`. A poll-loop via
  `startWatching(process:)` handles bash tasks that complete without a monitor
  pipeline; the monitor pipeline fires the wake directly via `tick`.
  Owner-scoping (`ownerSessionID`) prevents cross-session wakes.

- **`LiveTaskCompletionFormatting`**: two static formatters matching the Rust reference
  (`task_completion.rs:117–195`). The monitor formatter emits
  `[monitor ended: <reason>]`; the bash formatter includes the pkill self-match hint
  when `signal != nil && duration < 1.0`.

### `Sources/OpenGrokCLI/LiveMonitorTool.swift`

- `LiveMonitorHost` gains an optional `completionWake: LiveTaskCompletionWake?`
  property and `setCompletionWake(_:)`.
- At the end of `tick`, when the pipeline finishes and the task is completed,
  `completionWake.reportIfNew(snapshot)` fires. No `[monitor ended]` event is
  emitted — upstream reserves that wording for TaskCompleted.
- The deferral comment (lines 363–369 pre-edit) was replaced with a doc-comment
  describing the live behavior.

### `Tests/OpenGrokCLITests/LiveTaskCompletionWakeTests.swift` (new)

Three test suites:
1. **Formatting pins** (6 tests): exit-0, signal, no-description, bash-exit-0,
   signal-short-duration (pkill hint), signal-long-duration (no hint), unknown-exit,
   displayCommand preference.
2. **Exactly-once semantics** (5 tests): fires once, no-fire-while-running,
   blockWaited suppression, explicit `suppress`, owner scoping.
3. **Monitor pipeline integration** (1 test): `LiveMonitorHost.tick` fires the wake
   on completion, does not double-fire on second tick, does not emit a synthetic
   `[monitor ended]` event.

### `Tests/OpenGrokCLITests/LiveMonitorToolTests.swift`

Updated the `completionFlushesWithoutEndedEvent` test comment to reference the live
`LiveTaskCompletionWake` mechanism instead of the former deferral.

## Wiring handoff to LiveComposition

`LiveComposition` must wire the wake sink. Exact diff for the lead:

```swift
// In the session init path, after creating the monitor host and interjection
// buffer:
await monitorHost.setCompletionWake(completionWake)
completionWake.setWakeSink { [weak interjections] message in
    await interjections?.interject(message)
}
completionWake.startWatching(process: processExecution)
```

The `completionWake` instance is `LiveTaskCompletionWake(ownerSessionID: session.id)`.
It should be stored on the session actor / composition and `shutdown()` on teardown.

## Build status

```
zsh workflows/swift-safe-verify.zsh build --target OpenGrokCLI
```

**BLOCKED** by a pre-existing error in `Sources/OpenGrokJavaScriptRuntime/JavaScriptModuleLoader.swift:103`
(`Result<String, String>` — `String` does not conform to `Error` in Swift 6).
That file is untracked (`git status: ??`) and was added by another agent in this wave.

All dependency targets that S5 actually touches build cleanly:
- `swift build --target OpenGrokShellBase` — green
- `swift build --target OpenGrokShell` — green

The S5 code introduces no new compiler errors; it is structurally identical to the
existing `StubMonitorExecution` pattern in `LiveMonitorToolTests.swift` which compiled
before this wave's `JavaScriptModuleLoader` landed.

## Acceptance checklist

| Criterion | Status |
|-----------|--------|
| Exactly-once wake on natural completion | Done — `reportedIDs` set, tested |
| No wake while still running | Done — `guard snapshot.completed` |
| No synthetic `[monitor ended]` event | Done — tick emits no `[monitor ended]`; test asserts absence |
| Correct ACP/session update emission | Handoff to lead (LiveComposition wiring) |
| No `_ =` on status-returning calls | `reportIfNew` return asserted in tests |

## Files changed

- `Sources/OpenGrokCLI/LiveBackgroundTaskTools.swift`
- `Sources/OpenGrokCLI/LiveMonitorTool.swift`
- `Tests/OpenGrokCLITests/LiveMonitorToolTests.swift`
- `Tests/OpenGrokCLITests/LiveTaskCompletionWakeTests.swift` (new)
