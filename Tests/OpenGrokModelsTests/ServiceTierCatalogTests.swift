// ServiceTierCatalogTests.swift
//
// Service-tier metadata through the catalog: the wire parse that feeds
// `/fast` its "does the current model support Fast, and under which id"
// answer. Pins the Codex `service_tiers` / legacy `additional_speed_tiers`
// parse (upstream codex_models.rs:664-704), the curated Fireworks fast tier
// (fireworks_models.rs:167-171), the donor merge (config.rs:3616-3618), and
// the `ModelInfo` round-trip so a cached catalog cannot silently drop tiers.

import Foundation
import Testing
@testable import OpenGrokModels
import OpenGrokSamplingTypes

@Suite("Service tiers in the model catalog")
struct ServiceTierCatalogTests {
    @Test("a Codex service_tiers entry parses into the catalog with its fast id")
    func codexServiceTiersParse() throws {
        let json = """
        {
          "models": [
            {
              "slug": "gpt-5.6-sol",
              "display_name": "GPT-5.6 Sol",
              "visibility": "list",
              "priority": 1,
              "service_tiers": [
                {"id": "priority", "name": "Fast", "description": "Fastest inference"},
                {"id": "flex", "name": "", "description": "  "},
                {"id": "   "}
              ],
              "default_service_tier": "priority"
            }
          ]
        }
        """.data(using: .utf8)!

        let parsed = try parseCodexModelsResponse(json)
        try #require(parsed.count == 1)
        let info = parsed[0].entry.info
        // Blank ids drop; a blank name defaults to the id; a blank
        // description becomes nil (codex_models.rs:667-686).
        #expect(info.serviceTiers == [
            ModelServiceTier(id: "priority", name: "Fast", description: "Fastest inference"),
            ModelServiceTier(id: "flex", name: "flex", description: nil),
        ])
        #expect(info.supportsFastServiceTier)
        #expect(info.fastServiceTierID == "priority")
    }

    @Test("legacy additional_speed_tiers advertise Fast without a full entry")
    func codexLegacySpeedTiersSynthesizeFast() throws {
        let json = """
        {
          "models": [
            {
              "slug": "gpt-legacy",
              "display_name": "Legacy",
              "visibility": "list",
              "priority": 1,
              "additional_speed_tiers": ["FAST"]
            }
          ]
        }
        """.data(using: .utf8)!

        let parsed = try parseCodexModelsResponse(json)
        try #require(parsed.count == 1)
        // The synthesized tier and its copy, verbatim (codex_models.rs:694-700).
        #expect(parsed[0].entry.info.serviceTiers == [ModelServiceTier(
            id: "priority",
            name: "Fast",
            description: "Fastest inference with increased plan usage"
        )])
        #expect(parsed[0].entry.info.fastServiceTierID == "priority")
    }

    @Test("a model without service tiers does not support Fast")
    func modelWithoutTiersDoesNotSupportFast() throws {
        let json = """
        {
          "models": [
            {"slug": "gpt-plain", "display_name": "Plain", "visibility": "list", "priority": 1}
          ]
        }
        """.data(using: .utf8)!

        let parsed = try parseCodexModelsResponse(json)
        try #require(parsed.count == 1)
        #expect(parsed[0].entry.info.serviceTiers.isEmpty)
        #expect(!parsed[0].entry.info.supportsFastServiceTier)
        #expect(parsed[0].entry.info.fastServiceTierID == nil)

        // The embedded xAI default has no tiers either — `/fast` on grok-4.5
        // must refuse, not silently send a tier.
        let catalog = resolveModelCatalog(input: .default)
        let grok = try #require(catalog["grok-4.5"])
        #expect(!grok.info.supportsFastServiceTier)
    }

    @Test("curated Fireworks models advertise the Fast / priority tier")
    func fireworksCuratedFastTier() {
        // fireworks_models.rs:167-171: every curated entry carries the tier.
        let catalog = FireworksModels.curatedCatalog(baseURL: "https://api.fireworks.ai/inference/v1")
        for (key, entry) in catalog.pairs() {
            #expect(entry.info.fastServiceTierID == "priority", "curated \(key) must advertise Fast")
            #expect(entry.info.serviceTiers == [ModelServiceTier(
                id: "priority",
                name: "Fast",
                description: "Fireworks priority processing"
            )], "curated \(key) tier copy must match upstream")
        }
    }

    @Test("the remote-partition merge inherits donor service tiers")
    func donorMergeInheritsServiceTiers() throws {
        // config.rs:3616-3618: a remote entry that omits tiers inherits the
        // same-key same-provider donor's menu — without this, a live catalog
        // refresh silently un-advertises Fast on every curated model.
        let fireworks = FireworksModels.curatedCatalog(
            baseURL: "https://api.fireworks.ai/inference/v1"
        )
        var bare = fireworks
        for (key, var entry) in bare.pairs() {
            entry.info.serviceTiers = []
            bare[key] = entry
        }
        var resolved = OrderedModelMap()
        mergeRemoteProviderPartition(
            resolved: &resolved,
            defaults: fireworks,
            remote: bare,
            provider: .fireworks,
            authoritative: true
        )
        let merged = try #require(resolved["glm-5.2"])
        #expect(merged.info.fastServiceTierID == "priority")
    }

    @Test("ModelInfo round-trips service tiers through its JSON encoding")
    func modelInfoServiceTierRoundTrip() throws {
        var info = ModelInfo(model: "tiered-model")
        info.serviceTiers = [ModelServiceTier(id: "priority", name: "Fast")]
        let decoded = try JSONDecoder().decode(
            ModelInfo.self,
            from: try JSONEncoder().encode(info)
        )
        #expect(decoded.serviceTiers == info.serviceTiers)

        // Absence decodes to empty, and empty is not serialized at all — the
        // upstream `skip_serializing_if = "Vec::is_empty"` contract
        // (config.rs:4770-4772).
        let plain = ModelInfo(model: "plain-model")
        let encoded = try JSONEncoder().encode(plain)
        let object = try #require(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        #expect(object["service_tiers"] == nil)
        let decodedPlain = try JSONDecoder().decode(ModelInfo.self, from: encoded)
        #expect(decodedPlain.serviceTiers.isEmpty)
    }
}
