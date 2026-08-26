import Foundation
import OpenGrokACP
import OpenGrokShared
import Testing

@testable import OpenGrokACPRuntime

private actor ACPDurableSessionListHandler: ACPAgentExtensionHandler {
    struct Call: Sendable, Equatable {
        let method: String
        let params: JSONValue
    }

    enum Outcome: Sendable {
        case response(JSONValue)
        case acpFailure(AcpError)
        case runtimeFailure(ACPRuntimeError)
    }

    private let outcome: Outcome
    private(set) var calls: [Call] = []

    init(_ outcome: Outcome) {
        self.outcome = outcome
    }

    func handle(method: String, params: JSONValue) async throws -> JSONValue {
        calls.append(Call(method: method, params: params))
        switch outcome {
        case .response(let result):
            return result
        case .acpFailure(let error):
            throw error
        case .runtimeFailure(let error):
            throw error
        }
    }
}

private enum ACPDurableSessionListFixture {
    #if os(Windows)
    static let workspace = "C:\\workspace\\durable-build"
    static let additional = "C:\\workspace\\additional"
    static let another = "D:\\workspace\\another"
    static let secondaryAbsolute = "\\\\server\\share\\durable-build"
    static let foreignPlatformRelative = "/unix/workspace"
    #else
    static let workspace = "/workspace/durable-build"
    static let additional = "/workspace/additional"
    static let another = "/workspace/another"
    static let secondaryAbsolute = "/another/durable-build"
    static let foreignPlatformRelative = "C:\\windows\\workspace"
    #endif

    static var resident: ACPSessionSnapshot {
        ACPSessionSnapshot(
            sessionId: AcpSessionId("resident-only"),
            cwd: workspace,
            createdAt: "2026-08-25T11:00:00Z",
            updatedAt: "2026-08-25T12:00:00Z"
        )
    }

    static func row(
        id: String = "durable-build",
        cwd: String = workspace,
        title: String = "Persisted build",
        updatedAt: String = "2026-08-25T12:00:00Z",
        metadata: AcpMeta? = ["x.ai/session": .object(["kind": .string("build")])]
    ) -> JSONValue {
        var fields: [String: JSONValue] = [
            "sessionId": .string(id),
            "cwd": .string(cwd),
            "title": .string(title),
            "updatedAt": .string(updatedAt),
        ]
        if let metadata {
            fields["_meta"] = .object(metadata)
        }
        return .object(fields)
    }

    static func envelope(
        rows: [JSONValue],
        cursor: String? = nil,
        metadata: AcpMeta? = nil
    ) -> JSONValue {
        var result: [String: JSONValue] = ["sessions": .array(rows)]
        if let cursor {
            result["nextCursor"] = .string(cursor)
        }
        if let metadata {
            result["_meta"] = .object(metadata)
        }
        return .object(["result": .object(result)])
    }

    static func initialize(_ runtime: ACPAgentRuntime) async throws {
        let response = await runtime.handle(.request(
            id: .number(1),
            method: AgentMethodNames.initialize,
            params: try JSONValue.encode(InitializeRequest(protocolVersion: .v1))
        ))
        guard response.count == 1,
              case .response(.number(1), _?, nil) = response[0]
        else {
            throw ACPRuntimeError.transport("durable session-list fixture did not initialize")
        }
    }

    static func request(
        _ runtime: ACPAgentRuntime,
        method: String = AgentMethodNames.sessionList,
        params: JSONValue = .object([:])
    ) async throws -> ACPMessage {
        let response = await runtime.handle(.request(
            id: .number(2),
            method: method,
            params: params
        ))
        guard response.count == 1, let message = response.first else {
            throw ACPRuntimeError.transport("durable session-list fixture returned no response")
        }
        return message
    }

    static func success(_ message: ACPMessage) throws -> JSONValue {
        guard case .response(.number(2), let result?, nil) = message else {
            throw ACPRuntimeError.transport("durable session-list fixture returned an error")
        }
        return result
    }

    static func failure(_ message: ACPMessage) throws -> AcpError {
        guard case .response(.number(2), nil, let error?) = message else {
            throw ACPRuntimeError.transport("durable session-list fixture unexpectedly succeeded")
        }
        return error
    }
}

@Suite("ACP session/list durable routing and security parity")
struct ACPListSessionsDurableParityTests {
    @Test("the core wire route reaches durable catch-all handlers with exact page and metadata authority")
    func coreSessionListRoutesToDurableCatchAll() async throws {
        let responseMetadata: AcpMeta = [
            "x.ai/facets": .object(["kind": .array([.string("build")])]),
            "x.ai/partial": .object(["conversations": .bool(false)]),
        ]
        let handler = ACPDurableSessionListHandler(.response(
            ACPDurableSessionListFixture.envelope(
                rows: [ACPDurableSessionListFixture.row()],
                cursor: "opaque-next-page==",
                metadata: responseMetadata
            )
        ))
        let runtime = ACPAgentRuntime(extensionHandler: handler)
        try await ACPDurableSessionListFixture.initialize(runtime)

        let request = ListSessionsRequest(
            cwd: ACPDurableSessionListFixture.workspace,
            additionalDirectories: [
                ACPDurableSessionListFixture.additional,
                ACPDurableSessionListFixture.another,
            ],
            cursor: "opaque-request-page==",
            meta: [
                "opaque": .object(["client": .string("preserved")]),
                "x.ai/facetFilters": .object([
                    "kind": .array([.string("chat")]),
                    "provider": .array([.string("xai")]),
                ]),
            ]
        )
        let encoded = try JSONValue.encode(request)
        var params = try #require(encoded.objectValue)
        params["allowRelax"] = .bool(true)
        let message = try await ACPDurableSessionListFixture.request(
            runtime,
            params: .object(params)
        )

        let wire = try ACPDurableSessionListFixture.success(message)
        let response = try wire.decode(ListSessionsResponse.self)
        #expect(response.sessions.count == 1)
        #expect(response.sessions.first?.sessionId.rawValue == "durable-build")
        #expect(response.sessions.first?.cwd == ACPDurableSessionListFixture.workspace)
        #expect(response.sessions.first?.title == "Persisted build")
        #expect(response.sessions.first?.updatedAt == "2026-08-25T12:00:00Z")
        #expect(response.sessions.first?.meta?["x.ai/session"]?["kind"] == .string("build"))
        #expect(response.nextCursor == "opaque-next-page==")
        #expect(response.meta == responseMetadata)
        #expect(wire["nextCursor"] == .string("opaque-next-page=="))

        let calls = await handler.calls
        #expect(calls.count == 1)
        let call = try #require(calls.first)
        #expect(call.method == "x.ai/session/list")
        #expect(call.params["cwd"] == .string(ACPDurableSessionListFixture.workspace))
        #expect(call.params["cursor"] == .string("opaque-request-page=="))
        #expect(call.params["additionalDirectories"] == .array([
            .string(ACPDurableSessionListFixture.additional),
            .string(ACPDurableSessionListFixture.another),
        ]))
        #expect(call.params["allowRelax"] == .bool(false))
        #expect(call.params["_meta"]?["opaque"]?["client"] == .string("preserved"))
        #expect(call.params["_meta"]?["x.ai/facetFilters"]?["kind"]
            == .array([.string("build")]))
        #expect(call.params["_meta"]?["x.ai/facetFilters"]?["provider"]
            == .array([.string("xai")]))
    }

    @Test(
        "missing or malformed facet filters become build-only without erasing other metadata",
        arguments: [false, true]
    )
    func buildFacetAlwaysReplacesNonObjectFilters(_ malformed: Bool) async throws {
        let handler = ACPDurableSessionListHandler(.response(
            ACPDurableSessionListFixture.envelope(rows: [])
        ))
        let runtime = ACPAgentRuntime(extensionHandler: handler)
        try await ACPDurableSessionListFixture.initialize(runtime)
        var metadata: AcpMeta = ["opaque": .bool(true)]
        if malformed {
            metadata["x.ai/facetFilters"] = .string("untrusted")
        }
        let request = ListSessionsRequest(meta: metadata)
        let params = try JSONValue.encode(request)

        let message = try await ACPDurableSessionListFixture.request(
            runtime,
            params: params
        )

        #expect(try ACPDurableSessionListFixture.success(message)["sessions"] == .array([]))
        let calls = await handler.calls
        let call = try #require(calls.first)
        #expect(call.params["_meta"]?["opaque"] == .bool(true))
        #expect(call.params["_meta"]?["x.ai/facetFilters"]
            == .object(["kind": .array([.string("build")])]))
        #expect(call.params["additionalDirectories"] == nil)
    }

    @Test("an explicitly registered durable list handler is reachable without recursion")
    func exactDurableRouteIsUsed() async throws {
        let handler = ACPDurableSessionListHandler(.response(
            ACPDurableSessionListFixture.envelope(rows: [ACPDurableSessionListFixture.row()])
        ))
        let router = ACPExtensionMethodRouter().register(
            exact: "x.ai/session/list",
            handler: handler
        )
        let runtime = ACPAgentRuntime(extensionRouter: router)
        try await ACPDurableSessionListFixture.initialize(runtime)

        let message = try await ACPDurableSessionListFixture.request(runtime)
        let response = try ACPDurableSessionListFixture.success(message)
            .decode(ListSessionsResponse.self)

        #expect(response.sessions.first?.sessionId.rawValue == "durable-build")
        let calls = await handler.calls
        #expect(calls.count == 1)
    }

    @Test("explicit empty durable titles survive while absent optional metadata remains absent")
    func emptyTitlesRemainPresentWhileMissingOptionalFieldsStayAbsent() async throws {
        var fields = try #require(ACPDurableSessionListFixture.row(title: "").objectValue)
        fields.removeValue(forKey: "updatedAt")
        fields.removeValue(forKey: "_meta")
        let handler = ACPDurableSessionListHandler(.response(
            ACPDurableSessionListFixture.envelope(rows: [.object(fields)])
        ))
        let runtime = ACPAgentRuntime(extensionHandler: handler)
        try await ACPDurableSessionListFixture.initialize(runtime)

        let message = try await ACPDurableSessionListFixture.request(runtime)
        let wire = try ACPDurableSessionListFixture.success(message)
        let response = try wire.decode(ListSessionsResponse.self)

        #expect(response.sessions.count == 1)
        #expect(response.sessions.first?.title == "")
        #expect(response.sessions.first?.updatedAt == nil)
        #expect(response.sessions.first?.meta == nil)
        #expect(wire["sessions"]?[0]?["title"] == .string(""))
    }

    @Test("only native-platform absolute working directories survive durable ACP conversion")
    func relativeAndForeignPlatformDirectoriesAreDropped() async throws {
        let handler = ACPDurableSessionListHandler(.response(
            ACPDurableSessionListFixture.envelope(rows: [
                ACPDurableSessionListFixture.row(id: "native", cwd: ACPDurableSessionListFixture.workspace),
                ACPDurableSessionListFixture.row(id: "relative", cwd: "relative/workspace"),
                ACPDurableSessionListFixture.row(id: "traversal", cwd: "../outside"),
                ACPDurableSessionListFixture.row(id: "empty", cwd: ""),
                ACPDurableSessionListFixture.row(
                    id: "foreign",
                    cwd: ACPDurableSessionListFixture.foreignPlatformRelative
                ),
                ACPDurableSessionListFixture.row(
                    id: "secondary",
                    cwd: ACPDurableSessionListFixture.secondaryAbsolute
                ),
            ])
        ))
        let runtime = ACPAgentRuntime(extensionHandler: handler)
        try await ACPDurableSessionListFixture.initialize(runtime)

        let message = try await ACPDurableSessionListFixture.request(runtime)
        let response = try ACPDurableSessionListFixture.success(message)
            .decode(ListSessionsResponse.self)

        #expect(response.sessions.map(\.sessionId.rawValue) == ["native", "secondary"])
    }

    @Test(
        "only an exact unavailable durable method falls back to resident sessions",
        arguments: ["no-router", "empty-router", "exact-acp", "exact-runtime"]
    )
    func absentDurableMethodFallsBackWithoutHidingFailures(_ route: String) async throws {
        let store = InMemoryACPSessionStore(sessions: [ACPDurableSessionListFixture.resident])
        let runtime: ACPAgentRuntime
        switch route {
        case "no-router":
            runtime = ACPAgentRuntime(store: store)
        case "empty-router":
            runtime = ACPAgentRuntime(store: store, extensionRouter: ACPExtensionMethodRouter())
        case "exact-acp":
            let handler = ACPDurableSessionListHandler(.acpFailure(
                ACPExtensionMethodRouter.unknownExtensionMethodError("x.ai/session/list")
            ))
            runtime = ACPAgentRuntime(store: store, extensionHandler: handler)
        default:
            let handler = ACPDurableSessionListHandler(.runtimeFailure(
                .methodNotFound("x.ai/session/list")
            ))
            runtime = ACPAgentRuntime(store: store, extensionHandler: handler)
        }
        try await ACPDurableSessionListFixture.initialize(runtime)

        let message = try await ACPDurableSessionListFixture.request(runtime)
        let response = try ACPDurableSessionListFixture.success(message)
            .decode(ListSessionsResponse.self)

        #expect(response.sessions.map(\.sessionId.rawValue) == ["resident-only"])
        #expect(response.nextCursor == nil)
    }

    @Test(
        "authentication, backend, and mismatched unknown-method errors never fall back",
        arguments: ["authentication", "backend", "invalid", "wrong-method", "wrong-message", "runtime-other"]
    )
    func durableBackendFailuresCannotSilentlyFallBack(_ failure: String) async throws {
        let outcome: ACPDurableSessionListHandler.Outcome
        let expectedCode: AcpErrorCode
        switch failure {
        case "authentication":
            outcome = .acpFailure(.authRequired())
            expectedCode = .authRequired
        case "backend":
            outcome = .acpFailure(.internalError("durable backend failed"))
            expectedCode = .internalError
        case "invalid":
            outcome = .acpFailure(.invalidParams())
            expectedCode = .invalidParams
        case "wrong-method":
            outcome = .acpFailure(
                ACPExtensionMethodRouter.unknownExtensionMethodError("x.ai/session/other")
            )
            expectedCode = .methodNotFound
        case "wrong-message":
            outcome = .acpFailure(AcpError(
                code: .methodNotFound,
                message: "durable backend method is unavailable",
                data: .string("unknown ACP extension method: x.ai/session/list")
            ))
            expectedCode = .methodNotFound
        default:
            outcome = .runtimeFailure(.methodNotFound("x.ai/session/other"))
            expectedCode = .methodNotFound
        }
        let handler = ACPDurableSessionListHandler(outcome)
        let store = InMemoryACPSessionStore(sessions: [ACPDurableSessionListFixture.resident])
        let runtime = ACPAgentRuntime(store: store, extensionHandler: handler)
        try await ACPDurableSessionListFixture.initialize(runtime)

        let message = try await ACPDurableSessionListFixture.request(runtime)
        let error = try ACPDurableSessionListFixture.failure(message)

        #expect(error.code == expectedCode)
        let calls = await handler.calls
        #expect(calls.count == 1)
    }

    @Test(
        "malformed durable envelopes, rows, metadata, and cursors fail closed",
        arguments: [
            "null-envelope", "missing-result", "array-result", "missing-sessions", "object-sessions",
            "null-row", "missing-id", "empty-id", "numeric-id", "missing-cwd", "numeric-cwd",
            "numeric-title", "numeric-updated", "scalar-row-meta", "scalar-response-meta",
            "numeric-cursor",
        ]
    )
    func malformedDurableShapesCannotReturnResidentSessions(_ scenario: String) async throws {
        let payload: JSONValue
        switch scenario {
        case "null-envelope":
            payload = .null
        case "missing-result":
            payload = .object(["sessions": .array([])])
        case "array-result":
            payload = .object(["result": .array([])])
        case "missing-sessions":
            payload = .object(["result": .object([:])])
        case "object-sessions":
            payload = .object(["result": .object(["sessions": .object([:])])])
        case "scalar-response-meta":
            payload = .object(["result": .object([
                "sessions": .array([]),
                "_meta": .bool(false),
            ])])
        case "numeric-cursor":
            payload = .object(["result": .object([
                "sessions": .array([]),
                "nextCursor": .number(.int64(7)),
            ])])
        default:
            var row = try #require(ACPDurableSessionListFixture.row().objectValue)
            switch scenario {
            case "null-row":
                payload = ACPDurableSessionListFixture.envelope(rows: [.null])
                return try await assertMalformedDurableResponse(payload)
            case "missing-id": row.removeValue(forKey: "sessionId")
            case "empty-id": row["sessionId"] = .string("")
            case "numeric-id": row["sessionId"] = .number(.int64(7))
            case "missing-cwd": row.removeValue(forKey: "cwd")
            case "numeric-cwd": row["cwd"] = .number(.int64(7))
            case "numeric-title": row["title"] = .number(.int64(7))
            case "numeric-updated": row["updatedAt"] = .number(.int64(7))
            default: row["_meta"] = .string("private")
            }
            payload = ACPDurableSessionListFixture.envelope(rows: [.object(row)])
        }

        try await assertMalformedDurableResponse(payload)
    }

    @Test("direct x.ai/session/list remains an untouched extension request")
    func directExtensionListDoesNotReenterTheCoreAdapter() async throws {
        let envelope = ACPDurableSessionListFixture.envelope(
            rows: [ACPDurableSessionListFixture.row()],
            cursor: "direct-cursor"
        )
        let handler = ACPDurableSessionListHandler(.response(envelope))
        let runtime = ACPAgentRuntime(extensionHandler: handler)
        try await ACPDurableSessionListFixture.initialize(runtime)
        let parameters: JSONValue = .object(["allowRelax": .bool(true)])

        let message = try await ACPDurableSessionListFixture.request(
            runtime,
            method: "x.ai/session/list",
            params: parameters
        )

        #expect(try ACPDurableSessionListFixture.success(message) == envelope)
        let calls = await handler.calls
        #expect(calls.count == 1)
        #expect(calls.first?.params == parameters)
    }

    private func assertMalformedDurableResponse(_ payload: JSONValue) async throws {
        let handler = ACPDurableSessionListHandler(.response(payload))
        let store = InMemoryACPSessionStore(sessions: [ACPDurableSessionListFixture.resident])
        let runtime = ACPAgentRuntime(store: store, extensionHandler: handler)
        try await ACPDurableSessionListFixture.initialize(runtime)

        let message = try await ACPDurableSessionListFixture.request(runtime)
        let error = try ACPDurableSessionListFixture.failure(message)

        #expect(error.code == .internalError)
        let calls = await handler.calls
        #expect(calls.count == 1)
    }
}
