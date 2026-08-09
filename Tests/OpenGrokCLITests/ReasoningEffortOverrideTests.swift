// ReasoningEffortOverrideTests.swift
//
// `ConfigModelOverride`'s reasoning-effort arms, asserted through to the
// sampler-facing tuning seam. Ports the two `.58` tests
// `reasoning_effort_override_supported_values_reach_sampler`
// (config.rs:8936-8974) and
// `reasoning_effort_override_false_clears_conflicting_values`
// (config.rs:8976-9024) over the port's `sampling_config_for_model` analog:
// `OpenGrokLiveSamplingTuning(entry:)`, whose supports-gate is the ported
// config.rs:6092-6096 arm. The clearing arm (config.rs:4653-4656) is what
// keeps a user's explicit `supports_reasoning_effort = false` from being
// silently re-armed by `deriveReasoningEffortFields`, which catalog
// resolution runs over every entry.

import Foundation
import Testing
import OpenGrokModels
import OpenGrokSamplingTypes
@testable import OpenGrokCLI

/// Mirror of upstream's `test_model_entry` helper (config.rs:7690-7733)
/// reduced to the fields these tests read: a plain entry with no reasoning
/// support declared.
private func testModelEntry(model: String, baseURL: String) -> ModelEntry {
    var entry = ModelEntry.fallback(slug: model, endpoints: .default)
    entry.info.model = model
    entry.info.baseURL = baseURL
    entry.info.contextWindow = 200_000
    entry.info.supportedInApi = true
    return entry
}

@Suite("ConfigModelOverride reasoning-effort arms")
struct ReasoningEffortOverrideTests {
    /// Provenance: Rust `reasoning_effort_override_supported_values_reach_sampler`
    /// (config.rs:8936-8974): an override that declares support and sets a
    /// value lands on the entry AND reaches the sampler config.
    @Test("supported override values reach the sampler")
    func supportedValuesReachSampler() {
        let base = testModelEntry(
            model: "reasoning-model",
            baseURL: "https://api.example.com/v1"
        )
        let model = ConfigModelOverride(
            reasoningEffort: .high,
            supportsReasoningEffort: true,
            reasoningEfforts: [ReasoningEffortOption(
                id: "high",
                value: .high,
                label: "High",
                description: nil,
                isDefault: true
            )]
        ).apply(key: "reasoning-model", base: base, endpoints: .default)

        #expect(model.info.supportsReasoningEffort)
        #expect(model.info.reasoningEffort == .high)
        #expect(model.info.reasoningEfforts.count == 1)

        let tuning = OpenGrokLiveSamplingTuning(entry: model)
        #expect(tuning.reasoningEffort == .high)
    }

    /// Provenance: Rust `reasoning_effort_override_false_clears_conflicting_values`
    /// (config.rs:8976-9024) over the clearing arm (config.rs:4653-4656): an
    /// explicit `supports_reasoning_effort = false` wipes the base's values
    /// AND the same override's own conflicting `reasoning_effort` /
    /// `reasoning_efforts`, and the wipe survives
    /// `deriveReasoningEffortFields` — nothing reaches the sampler.
    @Test("explicit supports=false clears conflicting values before the sampler")
    func explicitFalseClearsConflictingValues() {
        var base = testModelEntry(
            model: "plain-model",
            baseURL: "https://api.example.com/v1"
        )
        base.info.supportsReasoningEffort = true
        base.info.reasoningEffort = .low
        base.info.reasoningEfforts = [ReasoningEffortOption(
            id: "low",
            value: .low,
            label: "Low",
            description: nil,
            isDefault: true
        )]

        var model = ConfigModelOverride(
            reasoningEffort: .high,
            supportsReasoningEffort: false,
            reasoningEfforts: [ReasoningEffortOption(
                id: "high",
                value: .high,
                label: "High",
                description: nil,
                isDefault: true
            )]
        ).apply(key: "plain-model", base: base, endpoints: .default)
        // Catalog resolution runs this over every entry; upstream's test
        // calls it explicitly because a non-empty menu would re-arm support.
        model.info.deriveReasoningEffortFields()

        #expect(!model.info.supportsReasoningEffort)
        #expect(model.info.reasoningEffort == nil)
        #expect(model.info.reasoningEfforts.isEmpty)

        let tuning = OpenGrokLiveSamplingTuning(entry: model)
        #expect(tuning.reasoningEffort == nil)
    }

    /// The other half of the `Some(false)` comparison: an ABSENT
    /// `supports_reasoning_effort` must not clear anything — only the
    /// explicit false does (config.rs:4653 matches `Some(false)`, never
    /// `None`). Port-added guard: in Swift the arm reads
    /// `supportsReasoningEffort == false` on an Optional, and a future
    /// "simplification" to `!= true` would silently flip absent into
    /// clearing.
    @Test("an absent supports flag does not clear inherited values")
    func absentFlagPreservesInheritedValues() {
        var base = testModelEntry(
            model: "inherit-model",
            baseURL: "https://api.example.com/v1"
        )
        base.info.supportsReasoningEffort = true
        base.info.reasoningEffort = .low
        base.info.reasoningEfforts = [ReasoningEffortOption(
            id: "low",
            value: .low,
            label: "Low",
            description: nil,
            isDefault: true
        )]

        // An unrelated override — supportsReasoningEffort stays absent.
        let model = ConfigModelOverride(name: "Renamed")
            .apply(key: "inherit-model", base: base, endpoints: .default)

        #expect(model.info.supportsReasoningEffort)
        #expect(model.info.reasoningEffort == .low)
        #expect(model.info.reasoningEfforts.count == 1)

        let tuning = OpenGrokLiveSamplingTuning(entry: model)
        #expect(tuning.reasoningEffort == .low)
    }
}
