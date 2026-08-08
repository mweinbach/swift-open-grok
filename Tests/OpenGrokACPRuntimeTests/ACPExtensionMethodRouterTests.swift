import Foundation
import OpenGrokACP
import OpenGrokShared
import Testing

@testable import OpenGrokACPRuntime

private struct StubExtensionHandler: ACPAgentExtensionHandler, Sendable {
    let token: String
    let result: JSONValue

    func handle(method: String, params: JSONValue) async throws -> JSONValue {
        .object([
            "token": .string(token),
            "method": .string(method),
            "echo": params,
        ])
    }
}

@Suite("ACP extension method router")
struct ACPExtensionMethodRouterTests {
    @Test("exact registration dispatches to the matching handler")
    func exactMatch() async throws {
        let router = ACPExtensionMethodRouter()
            .register(exact: "x.ai/feedback", handler: StubExtensionHandler(token: "feedback", result: .null))
            .register(exact: "x.ai/other", handler: StubExtensionHandler(token: "other", result: .null))

        let result = try await router.dispatch(
            method: "x.ai/feedback",
            params: .object(["rating": .number(.int64(5))])
        )

        #expect(result["token"]?.stringValue == "feedback")
        #expect(result["method"]?.stringValue == "x.ai/feedback")
        #expect(result["echo"]?["rating"]?.int64Value == 5)
    }

    @Test("prefix registration dispatches the first matching family")
    func prefixMatch() async throws {
        let router = ACPExtensionMethodRouter()
            .register(prefix: "open-grok/", handler: StubExtensionHandler(token: "open-grok", result: .null))
            .register(prefix: "x.ai/mcp/", handler: StubExtensionHandler(token: "mcp", result: .null))

        let models = try await router.dispatch(method: "open-grok/codex/models/refresh", params: .null)
        let mcp = try await router.dispatch(method: "x.ai/mcp/list", params: .null)

        #expect(models["token"]?.stringValue == "open-grok")
        #expect(mcp["token"]?.stringValue == "mcp")
    }

    @Test("first-match wins when exact and prefix both qualify")
    func firstMatchWins() async throws {
        let router = ACPExtensionMethodRouter()
            .register(exact: "open-grok/special", handler: StubExtensionHandler(token: "exact", result: .null))
            .register(prefix: "open-grok/", handler: StubExtensionHandler(token: "prefix", result: .null))

        let result = try await router.dispatch(method: "open-grok/special", params: .null)
        #expect(result["token"]?.stringValue == "exact")
    }

    @Test("unknown methods surface upstream's terminal ext error through the runtime")
    func unknownMethod() async throws {
        let router = ACPExtensionMethodRouter()
            .register(exact: "x.ai/feedback", handler: StubExtensionHandler(token: "feedback", result: .null))
        let runtime = ACPAgentRuntime(extensionRouter: router)

        _ = await runtime.handle(.request(
            id: .number(1),
            method: AgentMethodNames.initialize,
            params: try JSONValue.encode(InitializeRequest(protocolVersion: .v1))
        ))

        let output = await runtime.handle(.request(
            id: .number(2),
            method: "x.ai/unregistered",
            params: .object([:])
        ))

        guard case .response(_, nil, let error) = output[0] else {
            Issue.record("expected protocol error")
            return
        }
        // Byte-exact upstream terminal arm (acp_agent.rs:4467-4471): the
        // standard "Method not found" message with the specifics in `data`,
        // NOT the runtime's method-in-message spelling.
        #expect(error?.code == .methodNotFound)
        #expect(error?.message == "Method not found")
        #expect(error?.data == .string("unknown ACP extension method: x.ai/unregistered"))
    }

    @Test("empty router leaves extension methods unhandled")
    func emptyRouter() async throws {
        let runtime = ACPAgentRuntime(extensionRouter: ACPExtensionMethodRouter())

        _ = await runtime.handle(.request(
            id: .number(1),
            method: AgentMethodNames.initialize,
            params: try JSONValue.encode(InitializeRequest(protocolVersion: .v1))
        ))

        let output = await runtime.handle(.request(
            id: .number(2),
            method: "x.ai/anything",
            params: .object([:])
        ))

        guard case .response(_, nil, let error) = output[0] else {
            Issue.record("expected protocol error")
            return
        }
        #expect(error?.code == .methodNotFound)
    }
}
