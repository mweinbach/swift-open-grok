import Foundation
import Testing
import OpenGrokModels
import OpenGrokSamplingTypes
import OpenGrokShared

@Suite("Pinned default-model catalog parity")
struct DefaultModelsPinnedParityTests {
    private static let pinnedSHA256 =
        "93c4f8eb7919000f2a6df1342169b4d5df6b90e1b6fc29516ac9cce1a28921c7"

    @Test("embedded catalog and fixture match the pinned Rust bytes")
    func embeddedCatalogAndFixtureMatchPinnedRustBytes() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/default_models.json")
        let fixtureBytes = try Data(contentsOf: fixtureURL)
        let embeddedBytes = Data(DEFAULT_MODELS_JSON.utf8)

        #expect(fixtureBytes.count == 15_560)
        #expect(fixtureBytes.last == 0x0A)
        #expect(OpenGrokShared.SHA256.hexDigest(fixtureBytes) == Self.pinnedSHA256)
        #expect(embeddedBytes == fixtureBytes)
        #expect(OpenGrokShared.SHA256.hexDigest(embeddedBytes) == Self.pinnedSHA256)
    }

    @Test("all pinned defaults resolve to Grok 4.6 while Grok 4.5 remains available")
    func pinnedDefaultsAndLegacyModelMatchRustCatalog() throws {
        let embedded = try parseEmbeddedDefaultModels(DEFAULT_MODELS_JSON)

        #expect(embedded.models.count == 21)
        #expect(embedded.default == "grok-4.6")
        #expect(embedded.webSearch == "grok-4.6")
        #expect(embedded.imageDescription == "grok-4.6")
        #expect(embedded.sessionSummary == "grok-4.6")
        #expect(embedded.models.prefix(2).map(\.model) == ["grok-4.6", "grok-4.5"])

        #expect(defaultModel() == "grok-4.6")
        #expect(defaultWebSearchModel() == "grok-4.6")
        #expect(defaultImageDescriptionModel() == "grok-4.6")
        #expect(defaultSessionSummaryModel() == "grok-4.6")
        #expect(defaultModel(for: .webSearch) == "grok-4.6")
        #expect(defaultModel(for: .imageDescription) == "grok-4.6")
        #expect(defaultModel(for: .sessionSummary) == "grok-4.6")
    }

    @Test("production model manager selects the pinned Grok 4.6 catalog entry")
    func productionModelManagerSelectsPinnedDefault() throws {
        let manager = ModelsManager()
        let catalog = manager.catalogSnapshot()
        let current = manager.currentModel()
        let currentEntry = try #require(current.entry)
        let legacyEntry = try #require(catalog["grok-4.5"])

        #expect(current.id == "grok-4.6")
        #expect(currentEntry.info.model == "grok-4.6")
        #expect(currentEntry.info.provider == .xai)
        #expect(currentEntry.info.contextWindow == 500_000)
        #expect(currentEntry.info.supportsBackendSearch)
        #expect(currentEntry.info.reasoningEffort == .high)
        #expect(currentEntry.info.reasoningEfforts.map(\.value) == [.xhigh, .high, .medium, .low])
        #expect(legacyEntry.info.model == "grok-4.5")
        #expect(!legacyEntry.info.supportsBackendSearch)
    }

    @Test("the pinned Sol entry preserves its forked subagent-context default")
    func pinnedSolPreservesForkedSubagentContextDefault() throws {
        let sol = try #require(defaultModelEntries()["gpt-5.6-sol"])

        #expect(sol.info.subagentContextDefault == .fork)
    }
}
