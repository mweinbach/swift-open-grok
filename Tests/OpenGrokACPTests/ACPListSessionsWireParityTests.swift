import Foundation
import OpenGrokACP
import OpenGrokShared
import Testing

@Suite("ACP session/list pagination and metadata wire parity")
struct ACPListSessionsWireParityTests {
    @Test("empty list requests preserve upstream defaults and omit empty additional roots")
    func emptyRequestOmitsOptionalFields() throws {
        let request = try JSONValue.object([:]).decode(ListSessionsRequest.self)

        #expect(request.cwd == nil)
        #expect(request.cursor == nil)
        #expect(request.additionalDirectories.isEmpty)
        #expect(request.meta == nil)
        #expect(request.methodName == AgentMethodNames.sessionList)
        #expect(try JSONValue.encode(request) == .object([:]))
    }

    @Test("list requests retain ordered roots, opaque cursors, cwd, and opaque metadata")
    func populatedRequestRoundTripsExactCamelCaseWire() throws {
        let metadata: AcpMeta = [
            "x.ai/facetFilters": .object([
                "kind": .array([.string("chat")]),
                "provider": .array([.string("xai")]),
            ]),
            "opaque": .object(["page": .number(.int64(3))]),
        ]
        let request = ListSessionsRequest(
            cwd: "/workspace/main",
            additionalDirectories: ["/workspace/second", "/workspace/first"],
            cursor: "opaque/page+1==",
            meta: metadata
        )

        let encoded = try JSONValue.encode(request)

        #expect(encoded["cwd"] == .string("/workspace/main"))
        #expect(encoded["additionalDirectories"] == .array([
            .string("/workspace/second"),
            .string("/workspace/first"),
        ]))
        #expect(encoded["cursor"] == .string("opaque/page+1=="))
        #expect(encoded["_meta"] == .object(metadata))
        #expect(encoded["additional_directories"] == nil)
        #expect(try encoded.decode(ListSessionsRequest.self) == request)
    }

    @Test("explicitly empty additional roots decode to the upstream default and stay omitted")
    func explicitlyEmptyAdditionalRootsAreOmittedWhenEncoded() throws {
        let request = try JSONValue.object([
            "additionalDirectories": .array([]),
            "cursor": .string("page-two"),
        ]).decode(ListSessionsRequest.self)

        #expect(request.additionalDirectories.isEmpty)
        #expect(request.cursor == "page-two")
        let encoded = try JSONValue.encode(request)
        #expect(encoded["additionalDirectories"] == nil)
        #expect(encoded["cursor"] == .string("page-two"))
    }

    @Test(
        "malformed list request cursors, workspace roots, and metadata fail decoding",
        arguments: ["cwd", "cursor", "additionalDirectories", "_meta"]
    )
    func malformedRequestFieldsFailClosed(_ field: String) throws {
        let malformed: JSONValue
        switch field {
        case "additionalDirectories":
            malformed = .array([.string("/workspace"), .bool(true)])
        case "_meta":
            malformed = .array([])
        default:
            malformed = .number(.int64(7))
        }

        #expect(throws: (any Error).self) {
            try JSONValue.object([field: malformed]).decode(ListSessionsRequest.self)
        }
    }

    @Test("list responses preserve opaque nextCursor and both response and row metadata")
    func pagedResponseRoundTripsExactCamelCaseWire() throws {
        let session = AcpSessionInfo(
            sessionId: AcpSessionId("durable-build"),
            cwd: "/workspace/main",
            title: "Durable build",
            updatedAt: "2026-08-25T12:00:00Z",
            meta: ["x.ai/session": .object(["kind": .string("build")])]
        )
        let response = ListSessionsResponse(
            sessions: [session],
            nextCursor: "opaque-next/page==",
            meta: ["x.ai/partial": .object(["conversations": .bool(false)])]
        )

        let encoded = try JSONValue.encode(response)

        #expect(encoded["nextCursor"] == .string("opaque-next/page=="))
        #expect(encoded["next_cursor"] == nil)
        #expect(encoded["_meta"]?["x.ai/partial"]?["conversations"] == .bool(false))
        #expect(encoded["sessions"]?[0]?["_meta"]?["x.ai/session"]?["kind"] == .string("build"))
        #expect(try encoded.decode(ListSessionsResponse.self) == response)
    }

    @Test("the last response page omits nextCursor and absent metadata")
    func finalResponseOmitsAbsentOptionalFields() throws {
        let response = try JSONValue.object(["sessions": .array([])]).decode(ListSessionsResponse.self)

        #expect(response.sessions.isEmpty)
        #expect(response.nextCursor == nil)
        #expect(response.meta == nil)
        #expect(try JSONValue.encode(response) == .object(["sessions": .array([])]))
    }

    @Test("malformed nextCursor responses cannot silently erase pagination")
    func malformedResponseCursorFailsClosed() {
        #expect(throws: (any Error).self) {
            try JSONValue.object([
                "sessions": .array([]),
                "nextCursor": .number(.int64(1)),
            ]).decode(ListSessionsResponse.self)
        }
    }
}
