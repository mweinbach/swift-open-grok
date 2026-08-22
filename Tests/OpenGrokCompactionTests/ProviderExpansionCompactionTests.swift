import OpenGrokCompaction
import OpenGrokSamplingTypes
import Testing

@Suite("Expanded-provider compaction isolation")
struct ProviderExpansionCompactionTests {
    @Test(
        "expanded providers cannot route conversation history to Codex compaction",
        arguments: [ModelProvider.runinfra, .gemini, .openRouter]
    )
    func expandedProvidersAlwaysCompactLocally(_ provider: ModelProvider) {
        #expect(CompactionStrategy.forProvider(provider) == .local)
        #expect(CompactionStrategy.forProvider(provider, remoteV2Enabled: true) == .local)
        #expect(CompactionStrategy.forProvider(provider, remoteV2Enabled: false) == .local)
    }
}
