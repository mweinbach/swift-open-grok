import Testing
import OpenGrokConfig
@testable import OpenGrokModels

@Suite("Configured model providers")
struct ConfiguredModelCatalogTests {
    @Test("model overrides inherit gateway defaults and named auth")
    func providerDefaultsReachResolvedEntry() throws {
        let document = try parseTOML("""
        [auth_provider.corp]
        command = "corp-token"

        [model_providers.gateway]
        base_url = "https://gateway.example/v1"
        api_backend = "chat_completions"
        auth_provider = "corp"
        context_window = 321000
        query_params = { tenant = "acme" }
        extra_headers = { X-Corp = "yes" }

        [model.enterprise]
        model = "enterprise-v1"
        model_provider = "gateway"
        """)

        let configured = parseConfiguredModelCatalog(from: document)
        #expect(configured.modelOverrides.count == 1)
        let override = configured.modelOverrides[0].1
        #expect(override.baseURL == "https://gateway.example/v1")
        #expect(override.apiBackend == .chatCompletions)
        #expect(override.contextWindow == 321000)
        #expect(override.authProvider == "corp")
        #expect(override.queryParams.count == 1)
        #expect(override.queryParams.first?.0 == "tenant")
        #expect(override.queryParams.first?.1 == "acme")

        let catalog = resolveModelCatalog(input: CatalogResolutionInput(configModels: configured.modelOverrides))
        let entry = try #require(catalog["enterprise"])
        #expect(entry.info.baseURL == "https://gateway.example/v1")
        #expect(entry.info.apiBackend == .chatCompletions)
        #expect(entry.info.contextWindow == 321000)
        #expect(entry.authProvider == "corp")
        #expect(entry.queryParams["tenant"] == "acme")
    }
}
