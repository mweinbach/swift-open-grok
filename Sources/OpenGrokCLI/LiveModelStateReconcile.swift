// LiveModelStateReconcile.swift
//
// Pure reconcile logic for model state after a catalog refresh or session
// resume. Port of `ModelState::update_catalog` (pager acp/model_state.rs:
// 155-192 at 650c1db7).
//
// The reconcile decides what happens to the session's reasoning effort and
// service tier when the catalog changes underneath a running session:
//
//  * Model UNCHANGED in catalog → effort and tier are PRESERVED.
//    A catalog broadcast carries each model's static default, not the user's
//    per-session override; clobbering the session value would silently revert
//    `/model grok-4.5 low` back to `high` on every background refresh.
//
//  * Model UNCHANGED but catalog entry LOST effort support → effort CLEARED.
//    A provider upgrade that removes effort support means the effort would 400
//    on the next request; clearing it prevents that without resetting the whole
//    session.
//
//  * Model CHANGED (selected model gone, fell back) → effort RE-DERIVED from
//    the new model's catalog default; tier CLEARED if the new model does not
//    advertise it.
//
// The function is pure: no actor isolation, no side effects, deterministic
// from its inputs. The caller (LiveComposition, via the lead's integration
// diff) decides whether to rebuild the sampler based on the returned
// `samplerNeedsRebuild` flag.

import OpenGrokModels
import OpenGrokSamplingTypes

// MARK: - Input / Output

/// Snapshot of session model state before reconcile.
struct LiveModelReconcileInput: Sendable, Equatable {
    /// Catalog key of the model the session is currently on.
    var currentModelID: String?
    /// The session's active reasoning effort (user-set or catalog-derived).
    var reasoningEffort: ReasoningEffort?
    /// The session's active service tier (`/fast`); nil = standard routing.
    var serviceTier: String?
}

/// What the catalog refresh or resume provided.
struct LiveModelReconcileCatalog: Sendable {
    /// The refreshed catalog entries (picker-visible models).
    var entries: [LiveModelPickerEntry]
    /// The fallback model id the broadcast named (server's current selection,
    /// or the `[models] default` on resume). Applied only when the session's
    /// model is no longer in the catalog.
    var fallbackModelID: String?
}

/// Result of the reconcile: the new effective session state.
struct LiveModelReconcileResult: Sendable, Equatable {
    var currentModelID: String?
    var reasoningEffort: ReasoningEffort?
    var serviceTier: String?
    /// Whether the effective (model, effort, tier) tuple changed, meaning the
    /// caller must rebuild the sampler. When false, the catalog refresh touched
    /// only the available-model list and the live session needs no mutation.
    var samplerNeedsRebuild: Bool
}

// MARK: - Pure reconcile

/// Port of `ModelState::update_catalog` (pager acp/model_state.rs:155-192).
///
/// Decides what happens to the session's reasoning effort and service tier
/// when the catalog changes. The three cases — preserve, re-derive, clear —
/// map one-to-one to the Rust branches.
///
/// Pure, deterministic, no side effects.
func reconcileModelState(
    previous: LiveModelReconcileInput,
    catalog: LiveModelReconcileCatalog
) -> LiveModelReconcileResult {
    let previousModelID = previous.currentModelID

    // Step 1: Resolve current model id against the refreshed catalog.
    // (model_state.rs:159-165)
    let resolvedModelID: String?
    if let currentID = previous.currentModelID,
       catalog.entries.contains(where: { $0.id == currentID }) {
        resolvedModelID = currentID
    } else {
        resolvedModelID = catalog.fallbackModelID
    }

    // Step 2: Reconcile effort and tier based on whether the model changed.
    let resolvedEffort: ReasoningEffort?
    let resolvedTier: String?

    if resolvedModelID != previousModelID {
        // Model CHANGED — re-derive effort from the new entry's catalog
        // default (model_state.rs:170-171).
        let newEntry = resolvedModelID.flatMap { id in
            catalog.entries.first { $0.id == id }
        }
        resolvedEffort = reasoningEffortForEntry(newEntry, requested: nil)

        // Drop tier when the new model cannot run it (model_state.rs:173-177).
        if let tier = previous.serviceTier,
           let entry = newEntry,
           !entry.serviceTiers.contains(where: { $0.id == tier }) {
            resolvedTier = nil
        } else if newEntry == nil {
            resolvedTier = nil
        } else {
            resolvedTier = previous.serviceTier
        }
    } else {
        // Model UNCHANGED — preserve the user's effort UNLESS the model lost
        // support (model_state.rs:178-188).
        let currentEntry = resolvedModelID.flatMap { id in
            catalog.entries.first { $0.id == id }
        }
        if let entry = currentEntry, entry.supportsReasoningEffort {
            resolvedEffort = previous.reasoningEffort
        } else {
            resolvedEffort = nil
        }
        resolvedTier = previous.serviceTier
    }

    let needsRebuild = resolvedModelID != previousModelID
        || resolvedEffort != previous.reasoningEffort
        || resolvedTier != previous.serviceTier

    return LiveModelReconcileResult(
        currentModelID: resolvedModelID,
        reasoningEffort: resolvedEffort,
        serviceTier: resolvedTier,
        samplerNeedsRebuild: needsRebuild
    )
}

// MARK: - Live apply

/// Run `reconcileModelState` against the live catalog + switch coordinator
/// and rebuild the sampler when the effective tuple changed.
///
/// Shared by the post-readiness background refresh (makeAgentStack) and the
/// credential-change refresh sites on the interactive renderer. Returns the
/// reconcile result even when no rebuild was needed, so callers can sync UI
/// labels; returns `nil` only when the active catalog id cannot be resolved
/// into a reconcile input (no session model yet).
@discardableResult
func applyLiveModelCatalogReconcile(
    catalogStore: LiveModelCatalogStore,
    modelSwitch: LiveModelSwitchCoordinator
) async -> LiveModelReconcileResult? {
    let snapshot = await modelSwitch.snapshot()
    let catalogID = catalogStore.entryForWireModel(
        snapshot.modelID,
        provider: snapshot.provider
    )?.id ?? snapshot.modelID
    let previous = LiveModelReconcileInput(
        currentModelID: catalogID.isEmpty ? nil : catalogID,
        reasoningEffort: snapshot.configuration.reasoningEffort,
        serviceTier: snapshot.configuration.serviceTier
    )
    let catalog = LiveModelReconcileCatalog(
        entries: catalogStore.pickerEntries(),
        fallbackModelID: {
            let fallback = catalogStore.currentModelID()
            return fallback.isEmpty ? nil : fallback
        }()
    )
    let result = reconcileModelState(previous: previous, catalog: catalog)
    guard result.samplerNeedsRebuild, let modelID = result.currentModelID else {
        return result
    }
    let outcome = await modelSwitch.applyReconciled(
        modelID: modelID,
        effort: result.reasoningEffort,
        serviceTier: result.serviceTier
    )
    if case .switched(let summary) = outcome {
        catalogStore.noteModelSwitch(
            catalogID: summary.requestedID,
            effort: summary.reasoningEffort
        )
    }
    return result
}

// MARK: - Effort derivation

/// Port of `reasoning_effort_for_model` (pager acp/model_state.rs:14-23).
///
/// Returns the requested override when the model supports effort, else the
/// entry's catalog default, else nil.
func reasoningEffortForEntry(
    _ entry: LiveModelPickerEntry?,
    requested: ReasoningEffort?
) -> ReasoningEffort? {
    guard let entry else { return nil }
    guard entry.supportsReasoningEffort else { return nil }
    if let requested { return requested }
    // The scalar catalog default (`ModelInfo.reasoningEffort`) — this is what
    // upstream's `parse_reasoning_effort_meta` reads from the ACP meta object.
    if let scalar = entry.defaultReasoningEffort { return scalar }
    // Fall back to the menu's declared default, then the first menu value.
    if let defaultOption = entry.reasoningEfforts.first(where: { $0.isDefault }) {
        return defaultOption.value
    }
    return entry.reasoningEfforts.first?.value
}
