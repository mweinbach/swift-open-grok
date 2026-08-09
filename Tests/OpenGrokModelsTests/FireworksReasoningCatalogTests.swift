// FireworksReasoningCatalogTests.swift
//
// The `.58` re-pin's Fireworks reasoning assignment: every curated entry
// carries `supports_reasoning_effort = true` with the Low/Medium/High menu
// defaulting Medium (fireworks_models.rs:164-166), built by
// `fireworks_reasoning_efforts()` (fireworks_models.rs:182-197). The EMBEDDED
// Fireworks defaults deliberately stay effort-less at the same pin
// (config.rs:14155) — the menu arrives only through the provider-catalog
// refresh, which is why the wire proof lives in
// LiveFireworksEffortWireTests, not here.

import Foundation
import Testing
@testable import OpenGrokModels
import OpenGrokSamplingTypes

@Suite("Fireworks curated reasoning efforts")
struct FireworksReasoningCatalogTests {
    /// Provenance: Rust `curated_entries_are_chat_only_with_provider_owned_credentials`
    /// (fireworks_models.rs:385-424), whose `.58` update flipped the reasoning
    /// assertions to supports/Medium/three-level menu (…:402-416) and pinned
    /// the Fast tier alongside (…:417-418).
    @Test("every curated entry offers Low/Medium/High defaulting Medium")
    func curatedEntriesCarryTheEffortMenu() throws {
        let catalog = FireworksModels.curatedCatalog(
            baseURL: FireworksModels.apiBaseURLDefault
        )
        #expect(catalog.count == FireworksModels.curated.count)
        for curated in FireworksModels.curated {
            let entry = try #require(
                catalog[curated.key],
                "curated Fireworks entry \(curated.key)"
            )
            #expect(entry.info.provider == .fireworks)
            #expect(entry.info.apiBackend == .chatCompletions)
            #expect(entry.info.toolMode == .direct)
            #expect(entry.info.model == curated.slug)
            #expect(entry.info.name == curated.name)
            #expect(entry.info.contextWindow == curated.fallbackContextWindow)
            #expect(entry.info.supportsReasoningEffort)
            #expect(entry.info.reasoningEffort == .medium)
            #expect(
                entry.info.reasoningEfforts.map(\.value) == [.low, .medium, .high],
                "curated \(curated.key) must offer the three-level menu"
            )
            #expect(entry.info.serviceTiers.count == 1)
            #expect(entry.info.serviceTiers[0].isFast)
            #expect(entry.envKey?.primary == FireworksModels.apiKeyEnv)
        }
    }

    /// The pin's `CURATED_FIREWORKS_MODELS` is `[CuratedFireworksModel; 6]`
    /// (fireworks_models.rs:38-81) — the two Kimi K3 variants (…:67-80) were
    /// missing from the port until R4b. The count and order are pinned
    /// explicitly because every other assertion here iterates
    /// `FireworksModels.curated` and would stay green with entries silently
    /// dropped: an authoritative refresh REPLACES the embedded partition, so
    /// a missing curated entry deletes that model from the post-refresh
    /// catalog entirely.
    @Test("the curated partition is exactly upstream's six entries, in order")
    func curatedPartitionIsComplete() {
        #expect(FireworksModels.curated.map(\.key) == [
            "glm-5.2",
            "glm-5.2-fast",
            "deepseek-v4-pro",
            "kimi-k2.7-code",
            "fireworks:kimi-k3",
            "fireworks:kimi-k3-fast",
        ])

        let kimiK3 = FireworksModels.curated[4]
        #expect(kimiK3.slug == "accounts/fireworks/models/kimi-k3")
        #expect(kimiK3.name == "Kimi K3")
        #expect(kimiK3.description == "Moonshot's Kimi K3 flagship model on Fireworks AI")
        #expect(kimiK3.fallbackContextWindow == 1_040_000)

        let kimiK3Fast = FireworksModels.curated[5]
        #expect(kimiK3Fast.slug == "accounts/fireworks/routers/kimi-k3-fast")
        #expect(kimiK3Fast.name == "Kimi K3 Fast")
        #expect(kimiK3Fast.description == "Kimi K3 on Fireworks AI's low-latency router")
        #expect(kimiK3Fast.fallbackContextWindow == 1_040_000)
    }

    /// Provenance: Rust
    /// `fast_variants_use_distinct_fireworks_router_paths_with_priority_tier`
    /// (fireworks_models.rs:427-448) — the `-fast` keys route through
    /// Fireworks' `routers/` paths, not the base `models/` paths, and still
    /// carry the priority tier.
    @Test("fast variants use distinct router paths with the priority tier")
    func fastVariantsUseRouterPaths() throws {
        let entries = FireworksModels.curatedCatalog(
            baseURL: FireworksModels.apiBaseURLDefault
        )
        #expect(
            try #require(entries["glm-5.2-fast"]).info.model
                == "accounts/fireworks/routers/glm-5p2-fast"
        )
        #expect(
            try #require(entries["fireworks:kimi-k3"]).info.model
                == "accounts/fireworks/models/kimi-k3"
        )
        #expect(
            try #require(entries["fireworks:kimi-k3-fast"]).info.model
                == "accounts/fireworks/routers/kimi-k3-fast"
        )
        #expect(try #require(entries["glm-5.2-fast"]).info.serviceTiers[0].isFast)
        #expect(try #require(entries["fireworks:kimi-k3-fast"]).info.serviceTiers[0].isFast)
    }

    /// The menu itself (`fireworks_reasoning_efforts()`,
    /// fireworks_models.rs:182-197): ids are the canonical lowercase levels
    /// (`value.as_str()`), labels the capitalized display names, descriptions
    /// absent, and exactly one default — Medium.
    @Test("the shared menu has one default and it is Medium")
    func menuShape() {
        let efforts = FireworksModels.reasoningEfforts
        #expect(efforts.map(\.id) == ["low", "medium", "high"])
        #expect(efforts.map(\.label) == ["Low", "Medium", "High"])
        #expect(efforts.allSatisfy { $0.description == nil })
        let defaults = efforts.filter(\.isDefault)
        #expect(defaults.count == 1)
        #expect(defaults.first?.value == .medium)
    }

    /// The `.58` delta did NOT touch the embedded defaults: at the pin,
    /// `embedded_fireworks_models_are_curated_chat_only_with_provider_owned_credentials`
    /// still asserts `!supports_reasoning_effort` on every embedded Fireworks
    /// entry (config.rs:14130-14160, the flag at :14155). Flipping the
    /// embedded corpus too would advertise an `/effort` menu before any
    /// provider catalog confirmed the account can use it.
    @Test("embedded Fireworks defaults still declare no effort support")
    func embeddedDefaultsStayEffortless() throws {
        let defaults = defaultModelEntries()
        for key in [
            "glm-5.2", "glm-5.2-fast", "deepseek-v4-pro", "kimi-k2.7-code",
            "fireworks:kimi-k3", "fireworks:kimi-k3-fast",
        ] {
            let entry = try #require(defaults[key], "embedded Fireworks entry \(key)")
            #expect(entry.info.provider == .fireworks)
            #expect(
                !entry.info.supportsReasoningEffort,
                "\(key): the embedded default must not advertise effort support"
            )
            #expect(entry.info.reasoningEfforts.isEmpty)
        }
    }
}
