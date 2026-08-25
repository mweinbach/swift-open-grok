import Foundation
import OpenGrokHTTP
import Testing

@testable import OpenGrokWebMediaTools

@Suite("Web search authoritative domain policy")
struct WebSearchDomainPolicyParityTests {
    private func requestFilters(
        policy: WebSearchFilter,
        requested: [String]?
    ) async throws -> [String: Any] {
        let transport = MockHTTPTransport(responses: [
            MockHTTPTransport.ScriptedResponse(
                metadata: HTTPResponseMetadata(statusCode: 200),
                body: Data(#"{"output_text":"result","output":[]}"#.utf8)
            ),
        ])
        let client = try WebSearchClient(
            configuration: .enabled(
                apiKey: "private-search-token",
                baseURL: "https://search.example/v1",
                model: "grok-search"
            ),
            transport: transport,
            filter: policy
        )
        _ = try await client.search(query: "query", allowedDomains: requested)
        let sent = try #require(transport.recordedRequests.first?.body)
        let document = try #require(JSONSerialization.jsonObject(with: sent) as? [String: Any])
        let tool = try #require((document["tools"] as? [[String: Any]])?.first)
        #expect(tool["type"] as? String == "web_search")
        return try #require(tool["filters"] as? [String: Any])
    }

    @Test("managed allowed domains override model-supplied domains")
    func configuredAllowlistWins() async throws {
        let filters = try await requestFilters(
            policy: WebSearchFilter(allowedDomains: ["trusted.example"]),
            requested: ["untrusted.example"]
        )

        #expect(filters["allowed_domains"] as? [String] == ["trusted.example"])
        #expect(filters["excluded_domains"] == nil)
    }

    @Test("managed blocked domains cannot be bypassed by model allowlists")
    func configuredBlocklistWins() async throws {
        let filters = try await requestFilters(
            policy: WebSearchFilter(excludedDomains: ["private.example"]),
            requested: ["private.example"]
        )

        #expect(filters["excluded_domains"] as? [String] == ["private.example"])
        #expect(filters["allowed_domains"] == nil)
    }

    @Test("model allowlists survive when no administrative policy exists")
    func modelFilterWithoutPolicy() async throws {
        let filters = try await requestFilters(
            policy: WebSearchFilter(),
            requested: ["docs.example"]
        )

        #expect(filters["allowed_domains"] as? [String] == ["docs.example"])
    }
}
