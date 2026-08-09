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
