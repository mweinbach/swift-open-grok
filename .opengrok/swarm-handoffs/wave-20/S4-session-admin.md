# S4 — Session info/state/close handoff

Date: 2026-08-10
Slice: S4 (Session info/state/close)
Agent: Wave 20 Batch 1 S4 workhorse

## Summary

Implemented `x.ai/session/info`, `x.ai/session/state`, and `x.ai/session/close` in the existing `LiveSessionAdminACPHandler`. All other session methods (`updates`, `import`, `load_history`, `search`, `repair`, `usage`) remain refused with the router's terminal unknown-method error.

## Files changed

| File | Action |
|------|--------|
| `Sources/OpenGrokCLI/LiveSessionAdminACPHandlers.swift` | Extended with info/state/close |
| `Tests/OpenGrokCLITests/ACPSessionInfoStateCloseTests.swift` | New test file |

## Build verification

First build (cached intermediates from other agents' successful run):
```
Build complete! (17.53 sec)
```

Subsequent builds fail on **pre-existing errors in other agents' files**:
- `LiveMCPACPHandlers.swift:877` — S3's `disabledTools: Set()` extra argument
- `JavaScriptModuleLoader.swift:103` — another agent's `String` doesn't conform to `Error`

Neither error is in S4's owned files.

## Wiring diffs for lead

The handler's `init` now takes two additional optional closures. The existing call site in `LiveComposition.swift:3079-3084` must be updated:

```swift
// LiveComposition.swift ~line 3079 — add sessionInfoSnapshot and closeLive
let sessionAdmin = LiveSessionAdminACPHandler(
    openGrokHome: foundation.openGrokHome,
    gateway: gateway,
    liveSessionID: foundation.sessionID,
    renameLive: { title in try await history.rename(title: title) },
    sessionInfoSnapshot: {
        // Build from the live composition state:
        let snapshot = await history.snapshot()
        let route = await modelSwitch.snapshot()
        return LiveSessionInfoSnapshot(
            modelID: route.modelID,
            modelDisplayName: route.displayName,
            resolvedModelID: route.resolvedModelID,
            cwd: snapshot.workingDirectory,
            conversationID: foundation.sessionID,
            turns: snapshot.items.filter { $0.isUserTurn }.count,
            turnIndex: snapshot.items.count,
            context: LiveSessionContextInfo(
                maxContextTokens: route.contextWindow ?? 0,
                currentTokens: 0  // no live token counter yet
            )
        )
    },
    closeLive: {
        // Graceful close: cancel the prompt task and mark teardown.
        // The exact mechanism depends on the composition's teardown seam.
        // If no live teardown exists yet, return .closed and let the
        // process exit handle cleanup.
        return .closed
    }
)
```

**Notes for the lead:**
- The `sessionInfoSnapshot` closure needs access to `history` (for item count) and `modelSwitch` (for model metadata). Both are already in scope at that call site.
- The `closeLive` closure needs whatever teardown the composition supports. If the composition has no graceful-close seam yet, returning `.closed` is honest (the process will exit). If a teardown seam exists (like the one `LiveDashboardOverlay.handleDashboardClose` mentions), wire it.
- The `LiveModelSwitchCoordinator.snapshot()` may need a `displayName` and `contextWindow` field if not already present — check the existing API. If absent, pass `nil` for those fields; the info payload omits nil fields cleanly.

## LiveACPExtensionMethods.swift comment update (optional)

The file header at line 43-45 says `info`/`close` are refused. That should be updated to reflect they're now routed. The relevant text:

```
// the rest of `x.ai/session*`
// admin/state/search/usage/repair (:4115-4155 — the item 6 remainder:
// info/close/updates/state/import/load_history/search/repair/usage need
// live-session command plumbing, updates journals or the FTS index;
```

Should become:

```
// the rest of `x.ai/session*`
// search/usage/repair (:4115-4155 — the item 6 remainder:
// updates/import/load_history/search/repair/usage need updates journals
// or the FTS index; info/state/close are now routed (Wave 20 S4);
```

## New types exported from OpenGrokCLI

- `LiveSessionInfoSnapshot` — snapshot data for info payload
- `LiveSessionContextInfo` — context metadata sub-struct
- `LiveSessionCloseOutcome` — enum with `.closed`/`.notResident`/`.superseded`

All are `Sendable` and internal to `OpenGrokCLI`.

## Test coverage

| Test | What it proves |
|------|----------------|
| `infoReturnsResidentData` | Full payload shape with all fields |
| `infoNonResidentReturnsEmpty` | Non-matching sessionId → `{}` |
| `infoDefaultsToResident` | Omitted sessionId defaults to resident |
| `infoNoLiveSession` | No live spine → `{}` |
| `stateReturnsMetadata` | Summary column from persisted record |
| `stateSessionNotFound` | Missing session → invalid_params error |
| `stateCwdMismatch` | Wrong cwd → "session not found" |
| `stateMissingParams` | Missing sessionId/cwd → invalid_params |
| `stateOmitsAbsentFields` | Optional fields absent from record are omitted |
| `closeResidentSession` | Closure called, `closed` outcome |
| `closeIdempotent` | Second close → `notResident` |
| `closeNonResident` | Non-matching id → `notResident` |
| `closeNoLiveSession` | No spine → `notResident` |
| `closeMissingParam` | No sessionId → invalid_params |
| `outOfScopeMethodsRefused` | updates/import/load_history/search/repair/usage → method_not_found |

## Recorded divergences (added to file header)

7. `info` omits `modelFingerprint`, `showModelFingerprint`, `apiBackend`, `context.autoCompactThresholdPercent`
8. `state` returns `summary` only (no per-column plan/planMode/signals/goal/announcement files)
9. `close` is resident-only; `superseded` cannot occur (no multi-attach)
