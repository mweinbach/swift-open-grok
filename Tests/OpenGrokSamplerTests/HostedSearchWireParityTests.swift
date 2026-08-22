import OpenGrokSamplingTypes
import OpenGrokShared
import Testing
@testable import OpenGrokSampler

private func hostedSearchParityWireBody(
    provider: ModelProvider,
    functionTools: [ToolSpec] = [],
    hostedTools: [HostedTool]
) -> JSONValue {
    projectResponsesRequestBody(
        ConversationRequest(
            items: [.user("search for the answer")],
            tools: functionTools,
            hostedTools: hostedTools
        ),
        model: "provider-test-model",
        policy: ResponsesRequestPolicy(),
        adapter: providerAdapter(provider),
        applyResponseDefaults: true
    )
}

@Suite("Provider-hosted search production wire parity")
struct HostedSearchWireParityTests {
    @Test("xAI emits native web and X search once and displaces colliding client functions")
    func xaiNativeDescriptorsDisplaceCollidingFunctions() {
        let web = HostedTool.webSearch(allowedDomains: nil)
        let body = hostedSearchParityWireBody(
            provider: .xai,
            functionTools: [
                ToolSpec(name: "web_search", description: nil, parameters: .object([:])),
                ToolSpec(name: "x_search", description: nil, parameters: .object([:])),
                ToolSpec(name: "read_file", description: nil, parameters: .object([:])),
            ],
            hostedTools: [web, web, .xSearch, .xSearch]
        )
        let tools = body["tools"]?.arrayValue ?? []
        #expect(tools.filter { $0["type"]?.stringValue == "web_search" }.count == 1)
        #expect(tools.filter { $0["type"]?.stringValue == "x_search" }.count == 1)
        #expect(tools.filter { $0["type"]?.stringValue == "function" }
            .compactMap { $0["name"]?.stringValue } == ["read_file"])
    }

    @Test("Codex hosted web remains native, enables live access and never receives xAI X search")
    func codexNativeWebSearchHasTheCorrectWireShape() {
        let body = hostedSearchParityWireBody(
            provider: .codex,
            hostedTools: [.webSearch(allowedDomains: nil), .xSearch]
        )
        let tools = body["tools"]?.arrayValue ?? []
        #expect(tools.count == 1)
        #expect(tools.first?["type"]?.stringValue == "web_search")
        #expect(tools.first?["external_web_access"]?.boolValue == true)
    }

    @Test("DeepSeek Responses and Meta accept web search but never xAI-only search",
          arguments: [ModelProvider.deepseek, .meta])
    func openAICompatibleProvidersNeverReceiveXSearch(_ provider: ModelProvider) {
        let body = hostedSearchParityWireBody(
            provider: provider,
            hostedTools: [.webSearch(allowedDomains: nil), .xSearch]
        )
        #expect(body["tools"]?.arrayValue?.compactMap { $0["type"]?.stringValue }
            == ["web_search"])
        #expect(body["include"] == nil)
    }

    @Test("native search is absent on providers without a hosted-tool dialect")
    func unsupportedProviderDoesNotReceiveHostedDescriptors() {
        let body = hostedSearchParityWireBody(
            provider: .kimi,
            hostedTools: [.webSearch(allowedDomains: nil), .xSearch]
        )
        #expect(body["tools"] == nil)
    }

    @Test("hosted web requests source citations before encrypted reasoning")
    func hostedSearchCitationIncludePrecedesReasoning() {
        let body = hostedSearchParityWireBody(
            provider: .codex,
            hostedTools: [.webSearch(allowedDomains: nil)]
        )
        #expect(body["include"] == .array([
            .string("web_search_call.action.sources"),
            .string("reasoning.encrypted_content"),
        ]))
    }

    @Test("without native web the source citation include is absent")
    func xSearchAloneDoesNotRequestWebCitations() {
        let body = hostedSearchParityWireBody(provider: .xai, hostedTools: [.xSearch])
        #expect(body["include"] == .array([.string("reasoning.encrypted_content")]))
    }

    @Test("authorized domain allowlists reach the actual Responses request")
    func domainAllowlistReachesProductionWire() {
        let body = hostedSearchParityWireBody(
            provider: .codex,
            hostedTools: [.webSearch(allowedDomains: ["docs.x.ai", "arxiv.org"])]
        )
        let tool = body["tools"]?.arrayValue?.first
        #expect(tool?["filters"]?["allowed_domains"] == .array([
            .string("docs.x.ai"), .string("arxiv.org"),
        ]))
    }

    @Test("a disabled native search declaration cannot reach the wire")
    func disabledHostedSearchIsDropped() {
        let disabled = HostedTool.webSearch(
            mode: .disabled,
            allowedDomains: nil,
            userLocation: nil,
            searchContextSize: nil,
            searchContentTypes: nil
        )
        #expect(hostedSearchParityWireBody(provider: .xai, hostedTools: [disabled])["tools"] == nil)
    }

    @Test("hosted custom exec and web coexist without a duplicate function named exec")
    func nativeCustomAndWebSearchCoexist() {
        let exec = HostedTool.clientCustom(CustomToolSpec(
            name: "exec",
            description: "run code",
            format: .grammar
        ))
        let body = hostedSearchParityWireBody(
            provider: .codex,
            functionTools: [
                ToolSpec(name: "exec", description: nil, parameters: .object([:])),
                ToolSpec(name: "read_file", description: nil, parameters: .object([:])),
            ],
            hostedTools: [exec, exec, .webSearch(allowedDomains: nil)]
        )
        let tools = body["tools"]?.arrayValue ?? []
        #expect(tools.filter { $0["name"]?.stringValue == "exec" }.count == 1)
        #expect(tools.first { $0["name"]?.stringValue == "exec" }?["type"]?.stringValue == "custom")
        #expect(tools.contains { $0["type"]?.stringValue == "web_search" })
        #expect(tools.contains { $0["name"]?.stringValue == "read_file" })
    }

    @Test("the web source include remains first even when a caller supplied it twice")
    func sourceIncludeIsStableAndDeduplicated() {
        var body: JSONValue = .object([
            "tools": .array([.object(["type": .string("web_search")])]),
            "include": .array([
                .string("reasoning.encrypted_content"),
                .string("web_search_call.action.sources"),
                .string("web_search_call.action.sources"),
            ]),
        ])
        providerAdapter(.xai).patchResponsesRequest(&body, policy: ResponsesRequestPolicy())
        #expect(body["include"] == .array([
            .string("web_search_call.action.sources"),
            .string("reasoning.encrypted_content"),
        ]))
    }
}
