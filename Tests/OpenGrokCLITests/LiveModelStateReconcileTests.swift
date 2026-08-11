// LiveModelStateReconcileTests.swift
//
// Pure reconcile matrix: the three Rust test cases from
// `acp/model_state.rs:550-617` (at 650c1db7) — unchanged model preserves
// effort, same model losing support clears effort, and model-change rederives
// effort — plus the parallel tier reconcile rules.

import Foundation
import Testing
import OpenGrokSamplingTypes
@testable import OpenGrokCLI

// MARK: - Fixtures

private func reasoningEntry(
    id: String,
    defaultEffort: ReasoningEffort = .high,
    efforts: [ReasoningEffort] = [.high, .medium, .low],
    serviceTiers: [ModelServiceTier] = []
) -> LiveModelPickerEntry {
    LiveModelPickerEntry(
        id: id,
        providerID: "xai",
        name: id,
        supportsReasoningEffort: true,
        defaultReasoningEffort: defaultEffort,
        reasoningEfforts: efforts.map { level in
            ReasoningEffortOption(
                id: level.asString,
                value: level,
                label: level.asString,
                description: nil,
                isDefault: level == defaultEffort
            )
        },
        serviceTiers: serviceTiers
    )
}

private func plainEntry(
    id: String,
    serviceTiers: [ModelServiceTier] = []
) -> LiveModelPickerEntry {
    LiveModelPickerEntry(
        id: id,
        providerID: "fireworks",
        name: id,
        supportsReasoningEffort: false,
        serviceTiers: serviceTiers
    )
}

private let fastTier = ModelServiceTier(id: "priority", name: "Fast")

// MARK: - Tests

@Suite("Model state reconcile")
struct LiveModelStateReconcileTests {

    // MARK: Effort preservation

    /// Port of `update_catalog_preserves_user_effort_when_model_unchanged`
    /// (acp/model_state.rs:550-572). A catalog refresh that carries the same
    /// model must not clobber a user-set per-session effort.
    @Test("unchanged model preserves user-set effort")
    func unchangedModelPreservesEffort() {
        let entry = reasoningEntry(id: "grok-build", defaultEffort: .high)
        let previous = LiveModelReconcileInput(
            currentModelID: "grok-build",
            reasoningEffort: .xhigh,
            serviceTier: nil
        )
        let catalog = LiveModelReconcileCatalog(
            entries: [entry],
            fallbackModelID: "grok-build"
        )

        let result = reconcileModelState(previous: previous, catalog: catalog)

        #expect(result.currentModelID == "grok-build")
        #expect(result.reasoningEffort == .xhigh)
        #expect(!result.samplerNeedsRebuild)
    }

    /// Port of `update_catalog_clears_user_effort_when_same_model_loses_support`
    /// (acp/model_state.rs:574-600). A provider upgrade that removes effort
    /// support means the effort would 400 on the next request.
    @Test("same model losing effort support clears effort")
    func sameModelLosingSupportClearsEffort() {
        let previous = LiveModelReconcileInput(
            currentModelID: "shared-model",
            reasoningEffort: .xhigh,
            serviceTier: nil
        )
        let noEffortEntry = plainEntry(id: "shared-model")
        let catalog = LiveModelReconcileCatalog(
            entries: [noEffortEntry],
            fallbackModelID: "shared-model"
        )

        let result = reconcileModelState(previous: previous, catalog: catalog)

        #expect(result.currentModelID == "shared-model")
        #expect(result.reasoningEffort == nil)
        #expect(result.samplerNeedsRebuild)
    }

    /// Port of `update_catalog_rederives_effort_when_current_model_changes`
    /// (acp/model_state.rs:602-617). When the selected model is gone from the
    /// catalog, the fallback model's default effort is applied.
    @Test("model change rederives effort from new model's catalog default")
    func modelChangeRederivesEffort() {
        let previous = LiveModelReconcileInput(
            currentModelID: "model-a",
            reasoningEffort: .xhigh,
            serviceTier: nil
        )
        let entryB = reasoningEntry(id: "model-b", defaultEffort: .low)
        let catalog = LiveModelReconcileCatalog(
            entries: [entryB],
            fallbackModelID: "model-b"
        )

        let result = reconcileModelState(previous: previous, catalog: catalog)

        #expect(result.currentModelID == "model-b")
        #expect(result.reasoningEffort == .low)
        #expect(result.samplerNeedsRebuild)
    }

    // MARK: Service tier reconcile

    /// Unchanged model preserves a tier it still advertises.
    @Test("unchanged model preserves supported service tier")
    func unchangedModelPreservesTier() {
        let entry = reasoningEntry(
            id: "fast-model",
            defaultEffort: .high,
            serviceTiers: [fastTier]
        )
        let previous = LiveModelReconcileInput(
            currentModelID: "fast-model",
            reasoningEffort: .high,
            serviceTier: "priority"
        )
        let catalog = LiveModelReconcileCatalog(
            entries: [entry],
            fallbackModelID: "fast-model"
        )

        let result = reconcileModelState(previous: previous, catalog: catalog)

        #expect(result.serviceTier == "priority")
        #expect(!result.samplerNeedsRebuild)
    }

    /// Model change to one that does NOT advertise the current tier clears it
    /// (model_state.rs:173-177).
    @Test("model change clears tier when new model does not support it")
    func modelChangeClearsUnsupportedTier() {
        let previous = LiveModelReconcileInput(
            currentModelID: "model-fast",
            reasoningEffort: .high,
            serviceTier: "priority"
        )
        let noTierEntry = reasoningEntry(id: "model-notier", defaultEffort: .medium)
        let catalog = LiveModelReconcileCatalog(
            entries: [noTierEntry],
            fallbackModelID: "model-notier"
        )

        let result = reconcileModelState(previous: previous, catalog: catalog)

        #expect(result.currentModelID == "model-notier")
        #expect(result.serviceTier == nil)
        #expect(result.samplerNeedsRebuild)
    }

    /// Model change to one that DOES advertise the current tier preserves it.
    @Test("model change preserves tier when new model still supports it")
    func modelChangePreservesSupportedTier() {
        let previous = LiveModelReconcileInput(
            currentModelID: "old-model",
            reasoningEffort: .high,
            serviceTier: "priority"
        )
        let newEntry = reasoningEntry(
            id: "new-model",
            defaultEffort: .medium,
            serviceTiers: [fastTier]
        )
        let catalog = LiveModelReconcileCatalog(
            entries: [newEntry],
            fallbackModelID: "new-model"
        )

        let result = reconcileModelState(previous: previous, catalog: catalog)

        #expect(result.currentModelID == "new-model")
        #expect(result.serviceTier == "priority")
        #expect(result.samplerNeedsRebuild)
    }

    // MARK: Fallback / nil states

    /// No current model; fallback applies and its default effort is derived.
    @Test("nil current model falls back and derives effort")
    func nilCurrentFallsBack() {
        let previous = LiveModelReconcileInput(
            currentModelID: nil,
            reasoningEffort: nil,
            serviceTier: nil
        )
        let entry = reasoningEntry(id: "default-model", defaultEffort: .medium)
        let catalog = LiveModelReconcileCatalog(
            entries: [entry],
            fallbackModelID: "default-model"
        )

        let result = reconcileModelState(previous: previous, catalog: catalog)

        #expect(result.currentModelID == "default-model")
        #expect(result.reasoningEffort == .medium)
        #expect(result.samplerNeedsRebuild)
    }

    /// Current model still in catalog, no effort, no tier → no rebuild needed.
    @Test("unchanged model with no effort or tier needs no rebuild")
    func unchangedNoEffortNoTierNoRebuild() {
        let entry = plainEntry(id: "plain-model")
        let previous = LiveModelReconcileInput(
            currentModelID: "plain-model",
            reasoningEffort: nil,
            serviceTier: nil
        )
        let catalog = LiveModelReconcileCatalog(
            entries: [entry],
            fallbackModelID: "plain-model"
        )

        let result = reconcileModelState(previous: previous, catalog: catalog)

        #expect(result.currentModelID == "plain-model")
        #expect(result.reasoningEffort == nil)
        #expect(result.serviceTier == nil)
        #expect(!result.samplerNeedsRebuild)
    }

    /// Fallback to a non-reasoning model clears effort.
    @Test("fallback to non-reasoning model yields nil effort")
    func fallbackToNonReasoningClearsEffort() {
        let previous = LiveModelReconcileInput(
            currentModelID: "gone-model",
            reasoningEffort: .high,
            serviceTier: nil
        )
        let entry = plainEntry(id: "plain-fallback")
        let catalog = LiveModelReconcileCatalog(
            entries: [entry],
            fallbackModelID: "plain-fallback"
        )

        let result = reconcileModelState(previous: previous, catalog: catalog)

        #expect(result.currentModelID == "plain-fallback")
        #expect(result.reasoningEffort == nil)
        #expect(result.samplerNeedsRebuild)
    }

    // MARK: reasoningEffortForEntry

    @Test("reasoningEffortForEntry returns nil for nil entry")
    func effortForNilEntry() {
        #expect(reasoningEffortForEntry(nil, requested: .high) == nil)
    }

    @Test("reasoningEffortForEntry returns nil for unsupported model")
    func effortForUnsupportedModel() {
        let entry = plainEntry(id: "plain")
        #expect(reasoningEffortForEntry(entry, requested: .high) == nil)
    }

    @Test("reasoningEffortForEntry returns override when supported")
    func effortOverrideWhenSupported() {
        let entry = reasoningEntry(id: "r", defaultEffort: .high)
        #expect(reasoningEffortForEntry(entry, requested: .low) == .low)
    }

    @Test("reasoningEffortForEntry falls back to scalar default")
    func effortFallsBackToScalar() {
        let entry = LiveModelPickerEntry(
            id: "scalar-only",
            providerID: "xai",
            name: "Scalar Only",
            supportsReasoningEffort: true,
            defaultReasoningEffort: .medium,
            reasoningEfforts: []
        )
        #expect(reasoningEffortForEntry(entry, requested: nil) == .medium)
    }

    @Test("reasoningEffortForEntry falls back to menu default")
    func effortFallsBackToMenuDefault() {
        let entry = LiveModelPickerEntry(
            id: "menu-only",
            providerID: "xai",
            name: "Menu Only",
            supportsReasoningEffort: true,
            defaultReasoningEffort: nil,
            reasoningEfforts: [
                ReasoningEffortOption(
                    id: "low", value: .low, label: "Low",
                    description: nil, isDefault: true
                ),
            ]
        )
        #expect(reasoningEffortForEntry(entry, requested: nil) == .low)
    }
}
