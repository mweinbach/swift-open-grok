import Foundation
import OpenGrokACP
import OpenGrokShared
import Testing

@Suite("ACP session/resume required workspace and collection wire parity")
struct ACPResumeWireParityTests {
    @Test("resume encodes its required working directory and omits empty server and root lists")
    func requiredWorkingDirectoryAndEmptyCollections() throws {
        let request = ResumeSessionRequest(
            sessionId: AcpSessionId("resume-owned"),
            cwd: "/workspace/project"
        )

        let encoded = try JSONValue.encode(request)

        #expect(encoded == .object([
            "sessionId": .string("resume-owned"),
            "cwd": .string("/workspace/project"),
        ]))
        #expect(encoded["additionalDirectories"] == nil)
        #expect(encoded["mcpServers"] == nil)
        #expect(request.methodName == AgentMethodNames.sessionResume)
        #expect(try encoded.decode(ResumeSessionRequest.self) == request)
    }

    @Test("omitted optional collection fields decode as empty")
    func omittedCollectionsDecodeToEmptyDefaults() throws {
        let request = try JSONValue.object([
            "sessionId": .string("resume-owned"),
            "cwd": .string("/workspace/project"),
        ]).decode(ResumeSessionRequest.self)

        #expect(request.cwd == "/workspace/project")
        #expect(request.additionalDirectories.isEmpty)
        #expect(request.mcpServers.isEmpty)
        #expect(request.meta == nil)
    }

    @Test("explicit empty MCP and root arrays decode normally but are omitted on re-encoding")
    func explicitlyEmptyCollectionsRemainOmitted() throws {
        let request = try JSONValue.object([
            "sessionId": .string("resume-owned"),
            "cwd": .string("/workspace/project"),
            "additionalDirectories": .array([]),
            "mcpServers": .array([]),
        ]).decode(ResumeSessionRequest.self)

        #expect(request.additionalDirectories.isEmpty)
        #expect(request.mcpServers.isEmpty)
        #expect(try JSONValue.encode(request) == .object([
            "sessionId": .string("resume-owned"),
            "cwd": .string("/workspace/project"),
        ]))
    }

    @Test("resume round-trips ordered roots, ordered MCP servers, and opaque metadata")
    func nonemptyCollectionsPreserveOrderAndMetadata() throws {
        let servers: [McpServer] = [
            .stdio(McpServerStdio(
                name: "second-server",
                command: "/bin/second",
                args: ["--stdio"]
            )),
            .http(McpServerHttp(
                name: "first-server",
                url: "https://mcp.example.invalid/rpc"
            )),
        ]
        let metadata: AcpMeta = [
            "x.ai/leaderClientId": .number(.int64(42)),
            "opaque": .object(["nested": .bool(false)]),
        ]
        let request = ResumeSessionRequest(
            sessionId: AcpSessionId("resume-owned"),
            cwd: "/workspace/project",
            additionalDirectories: ["/workspace/second", "/workspace/first"],
            mcpServers: servers,
            meta: metadata
        )

        let encoded = try JSONValue.encode(request)

        #expect(encoded["cwd"] == .string("/workspace/project"))
        #expect(encoded["additionalDirectories"] == .array([
            .string("/workspace/second"),
            .string("/workspace/first"),
        ]))
        #expect(encoded["mcpServers"]?[0]?["name"] == .string("second-server"))
        #expect(encoded["mcpServers"]?[1]?["name"] == .string("first-server"))
        #expect(encoded["_meta"] == .object(metadata))
        #expect(encoded["additional_directories"] == nil)
        #expect(encoded["mcp_servers"] == nil)
        #expect(try encoded.decode(ResumeSessionRequest.self) == request)
    }

    @Test("missing working directories fail both typed decoding and agent dispatch")
    func missingWorkingDirectoryFailsClosed() throws {
        let params: JSONValue = .object(["sessionId": .string("resume-owned")])

        #expect(throws: (any Error).self) {
            try params.decode(ResumeSessionRequest.self)
        }

        let decoded = decodeAcpAgentMessage(
            method: AgentMethodNames.sessionResume,
            params: params
        )
        guard case .failure(.invalidParams(let method, _)) = decoded else {
            Issue.record("session/resume unexpectedly accepted a missing working directory")
            return
        }
        #expect(method == AgentMethodNames.sessionResume)
    }

    @Test(
        "null and non-string working directories fail closed",
        arguments: ["null", "boolean", "number", "array", "object"]
    )
    func malformedWorkingDirectoryFailsClosed(_ shape: String) {
        let value: JSONValue
        switch shape {
        case "null":
            value = .null
        case "boolean":
            value = .bool(true)
        case "number":
            value = .number(.int64(7))
        case "array":
            value = .array([.string("/workspace/project")])
        default:
            value = .object(["path": .string("/workspace/project")])
        }

        #expect(throws: (any Error).self) {
            try JSONValue.object([
                "sessionId": .string("resume-owned"),
                "cwd": value,
            ]).decode(ResumeSessionRequest.self)
        }
    }

    @Test(
        "malformed roots, MCP server declarations, and metadata fail decoding",
        arguments: ["additionalDirectories", "mcpServers", "_meta"]
    )
    func malformedOptionalFieldsFailClosed(_ field: String) {
        let invalid: JSONValue
        switch field {
        case "additionalDirectories":
            invalid = .array([.string("/workspace/ok"), .bool(false)])
        case "mcpServers":
            invalid = .array([.bool(true)])
        default:
            invalid = .array([])
        }

        #expect(throws: (any Error).self) {
            try JSONValue.object([
                "sessionId": .string("resume-owned"),
                "cwd": .string("/workspace/project"),
                field: invalid,
            ]).decode(ResumeSessionRequest.self)
        }
    }

    @Test("typed agent dispatch preserves the authenticated request working directory")
    func typedDispatchPreservesWorkingDirectory() throws {
        let params: JSONValue = .object([
            "sessionId": .string("resume-owned"),
            "cwd": .string("/workspace/project"),
        ])
        let decoded = decodeAcpAgentMessage(
            method: AgentMethodNames.sessionResume,
            params: params
        )

        guard case .success(.resumeSession(let arguments)) = decoded else {
            Issue.record("session/resume did not decode as its typed ACP request")
            return
        }
        #expect(arguments.request.sessionId.rawValue == "resume-owned")
        #expect(arguments.request.cwd == "/workspace/project")
        #expect(arguments.request.mcpServers.isEmpty)
    }
}
