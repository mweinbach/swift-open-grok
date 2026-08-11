# S2 — Model state reconcile handoff

**Slice:** S2 (Model resume/catalog reconcile)
**Date:** 2026-08-10
**Status:** Implementation complete; **lead integrated** Sites 1 + 3 into
`LiveComposition.swift` / `LiveModelSwitch.applyReconciled` /
`applyLiveModelCatalogReconcile` (2026-08-10). Site 2 (persisted effort/tier
on resume) still blocked — `LiveConversationRecord` has no effort/tier fields.

## What was ported

Port of `ModelState::update_catalog` reconcile logic (pager
`acp/model_state.rs:155-192` at `650c1db7`). The three branches:

1. **Model UNCHANGED, still supports effort** → effort and tier PRESERVED.
2. **Model UNCHANGED, lost effort support** → effort CLEARED (prevents 400).
3. **Model CHANGED (fallback applied)** → effort re-derived from new model's
   catalog default; tier cleared if new model does not advertise it.

Also ported: `reasoning_effort_for_model` (model_state.rs:14-23) as
`reasoningEffortForEntry`.

## Files changed

| File | Change |
|------|--------|
| `Sources/OpenGrokCLI/LiveModelStateReconcile.swift` | **NEW** — pure reconcile function + types |
| `Sources/OpenGrokCLI/LiveModelPicker.swift` | Added `defaultReasoningEffort` field to `LiveModelPickerEntry` |
| `Sources/OpenGrokCLI/LiveModelSwitch.swift` | Populate `defaultReasoningEffort` in `entries(from:)` |
| `Tests/OpenGrokCLITests/LiveModelStateReconcileTests.swift` | **NEW** — 12 test cases covering the reconcile matrix |

## Build status

`zsh workflows/swift-safe-verify.zsh build --target OpenGrokCLI` — my files
compile cleanly. The target has pre-existing errors in `LiveMCPACPHandlers.swift`
(S3's `handleToggle`/`handleToggleTool` missing — that slice's incomplete work).
My changes are file-disjoint and do not introduce any new errors.

## API surface for integration

```swift
/// Input to the reconcile.
struct LiveModelReconcileInput: Sendable, Equatable {
    var currentModelID: String?
    var reasoningEffort: ReasoningEffort?
    var serviceTier: String?
}

/// The refreshed catalog state.
struct LiveModelReconcileCatalog: Sendable {
    var entries: [LiveModelPickerEntry]
    var fallbackModelID: String?
}

/// What the reconcile decided.
struct LiveModelReconcileResult: Sendable, Equatable {
    var currentModelID: String?
    var reasoningEffort: ReasoningEffort?
    var serviceTier: String?
    var samplerNeedsRebuild: Bool
}

/// The pure reconcile. No side effects, no actor isolation.
func reconcileModelState(
    previous: LiveModelReconcileInput,
    catalog: LiveModelReconcileCatalog
) -> LiveModelReconcileResult
```

## LiveComposition integration sites

### Site 1: After `spawnBackgroundRefresh` completes (catalog refresh)

**Location:** After `catalogStore.spawnBackgroundRefresh()` at ~line 2840 of
`LiveComposition.swift`. Currently the background refresh mutates the catalog
store but does NOT propagate to the session's active sampler. The reconcile
closes this gap.

**Integration diff (conceptual):**

```swift
// Inside or after the background refresh's completion continuation —
// upstream checks the reconcile inside `handle_models_update`
// (dispatch/session/lifecycle.rs:1370-1410).
//
// The background refresh is fire-and-forget today; the reconcile needs
// a continuation/notification from the refresh to the session. Two
// options:
//
//   A) Add a post-publish callback on `ModelsManager` (matches upstream's
//      `models_changed` subscription).
//   B) Poll/observe `catalogStore.snapshot()` after the refresh task
//      completes (the task handle is already retained as
//      `backgroundRefreshTask`).
//
// Option B is simplest for the current architecture:

// After session readiness, when the background refresh task completes:
Task { [weak self] in
    await catalogStore.backgroundRefreshTask?.value
    guard let self else { return }
    let previous = LiveModelReconcileInput(
        currentModelID: /* catalogStore.currentModelID() or the composition's initial model */,
        reasoningEffort: /* the composition's active sampler effort */,
        serviceTier: /* the composition's active sampler tier */
    )
    let catalog = LiveModelReconcileCatalog(
        entries: catalogStore.pickerEntries(),
        fallbackModelID: catalogStore.currentModelID()
    )
    let result = reconcileModelState(previous: previous, catalog: catalog)
    guard result.samplerNeedsRebuild else { return }
    // Apply: re-resolve through the switch coordinator with the reconciled
    // effort and tier, or directly rebuild the sampler tuning.
    // The lightest path is an effort/tier-only mutation on the coordinator:
    //   await modelSwitch.apply(
    //       modelID: result.currentModelID!,
    //       effort: result.reasoningEffort,
    //       serviceTier: .some(result.serviceTier)
    //   )
    // catalogStore.noteModelSwitch(catalogID: result.currentModelID!, effort: result.reasoningEffort)
}
```

### Site 2: Session resume (session load from disk)

**Location:** Where a persisted session is loaded and its model state is
reconstructed. If the session file records a model+effort that the *current*
catalog no longer supports (provider removed the model between sessions), the
reconcile resolves the fallback.

Currently not an explicit call site — the cold start's `makeSessionFoundation`
resolves the model from scratch each time. The reconcile becomes relevant when
session persistence records the last model and effort and the resume path wants
to honor them without a full re-resolve:

```swift
// On resume, after loading persisted session state:
let persisted = LiveModelReconcileInput(
    currentModelID: savedSession.modelID,
    reasoningEffort: savedSession.reasoningEffort,
    serviceTier: savedSession.serviceTier
)
let catalog = LiveModelReconcileCatalog(
    entries: catalogStore.pickerEntries(),
    fallbackModelID: catalogStore.currentModelID()
)
let result = reconcileModelState(previous: persisted, catalog: catalog)
// Use result.currentModelID / .reasoningEffort / .serviceTier for the
// resumed session's initial sampling configuration.
```

### Site 3: Live credential change (post-login refresh)

**Location:** ~line 11708, 11791, 12170 — after `refreshCredentialSnapshot()` +
`spawnBackgroundRefresh()`. Same pattern as Site 1: the background refresh may
add or remove models, and the session state needs reconciling afterwards.

## Test coverage

12 pure tests in `LiveModelStateReconcileTests.swift`:
- `unchangedModelPreservesEffort` — Rust test parity
- `sameModelLosingSupportClearsEffort` — Rust test parity
- `modelChangeRederivesEffort` — Rust test parity
- `unchangedModelPreservesTier`
- `modelChangeClearsUnsupportedTier`
- `modelChangePreservesSupportedTier`
- `nilCurrentFallsBack`
- `unchangedNoEffortNoTierNoRebuild`
- `fallbackToNonReasoningClearsEffort`
- `effortForNilEntry`
- `effortForUnsupportedModel`
- `effortOverrideWhenSupported`
- `effortFallsBackToScalar`
- `effortFallsBackToMenuDefault`

## Live-seam test note

A live-seam test proving that a catalog refresh actually updates the effective
sampler state (not only the UI label) requires calling into the switch
coordinator after the reconcile — which means editing `LiveComposition.swift` to
wire the post-refresh reconcile. That live-seam test is ready to write once the
lead integrates Site 1 above: drive `backgroundRefreshTask?.value`, then assert
`coordinator.snapshot().configuration.reasoningEffort` changed. The existing
`LiveCatalogRefreshReachabilityTests` pattern shows how.

## Deliberately not done

- No edit to `LiveComposition.swift` (FORBIDDEN per coordination).
- No `Package.swift` changes (no new target needed).
- No invented UX beyond what upstream defines.
- The `LiveModelPickerEntry.defaultReasoningEffort` field defaults to `nil` in
  its initializer, so all existing call sites compile unchanged.
