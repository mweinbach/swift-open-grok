import OpenGrokModels
import Testing

@Suite("Streamed tool-call catalog override isolation")
struct StreamToolCallsCatalogInheritanceParityTests {
    @Test("Global models preference never becomes an explicit per-model override")
    func globalPreferenceDoesNotFreezeModelOverride() throws {
        let baseline = resolveModelCatalog(input: CatalogResolutionInput())
        let unaffected = try #require(baseline.pairs().first {
            $0.1.info.streamToolCalls == nil
        })
        let configured = resolveModelCatalog(input: CatalogResolutionInput(
            models: ModelsSectionConfig(streamToolCalls: false)
        ))

        #expect(configured[unaffected.0]?.info.streamToolCalls == nil)
    }
}
