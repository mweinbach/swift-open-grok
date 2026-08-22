import Testing
@testable import OpenGrokSamplingTypes

@Suite("Expanded-provider hosted tool isolation")
struct ProviderExpansionHostedToolSecurityTests {
    @Test(
        "expanded providers never serialize first-party hosted search capabilities",
        arguments: [ModelProvider.runinfra, .gemini, .openRouter]
    )
    func expandedProvidersRejectHostedTools(_ provider: ModelProvider) {
        let offered: [HostedTool] = [.xSearch, .webSearch(allowedDomains: ["example.com"])]

        #expect(hostedToolsForProvider(hostedTools: offered, provider: provider).isEmpty)
        #expect(provider.profile.hostedTools(offered).isEmpty)
    }
}
