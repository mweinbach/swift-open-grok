import Foundation
import OpenGrokAuth
import OpenGrokConfig
import OpenGrokHTTP
import OpenGrokSamplingTypes
import OpenGrokSessionPersistence
import OpenGrokShared
import OpenGrokShellSessionSupport
import OpenGrokVersion
import Testing

@testable import OpenGrokCLI

private struct SessionWritebackClientFixture {
    let root: URL
    let home: URL
    let workspace: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "opengrok-session-writeback-\(UUID().uuidString)",
            isDirectory: true
        )
        home = root.appendingPathComponent("home", isDirectory: true)
        workspace = root.appendingPathComponent("workspace", isDirectory: true)
        #if os(Windows)
        try OpenGrokConfig.createDirAllOwnerOnly(root, stateRoot: root)
        try OpenGrokConfig.createDirAllOwnerOnly(home, stateRoot: home)
        try OpenGrokConfig.createDirAllOwnerOnly(workspace, stateRoot: root)
        #else
        for directory in [root, home, workspace] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        #endif
    }

    var environment: [String: String] {
        [
            "HOME": root.path,
            "OPENGROK_HOME": home.path,
            "PWD": workspace.path,
        ]
    }

    func account(
        key: String = "first-party-writeback-token",
        userID: String = "writeback-user",
        mode: AuthMode = .oidc,
        issuer: String? = "https://auth.x.ai",
        refreshToken: String? = "first-party-refresh-token",
        blockedReasons: [String] = [],
        optedOut: Bool = false,
        teamID: String? = "writeback-team"
    ) -> GrokAuth {
        GrokAuth(
            key: key,
            authMode: mode,
            userID: userID,
            email: "writeback@example.com",
            principalID: "writeback-principal",
            teamID: teamID,
            organizationID: "writeback-organization",
            teamBlockedReasons: blockedReasons,
            codingDataRetentionOptOut: optedOut,
            refreshToken: refreshToken,
            expiresAt: Date().addingTimeInterval(3_600),
            oidcIssuer: issuer,
            oidcClientID: "writeback-client"
        )
    }

    func manager(_ account: GrokAuth? = nil) async throws -> AuthManager {
        let manager = AuthManager(
            grokHome: home,
            config: liveManagedAuthenticationConfiguration(environment: environment),
            environment: environment
        )
        if let account {
            try await manager.loginWithSession(account)
        }
        return manager
    }

    @discardableResult
    func seed(
        sessionID: String = "writeback-session",
        provider: ModelProvider? = .xai,
        everUsedNonXAI: Bool? = false,
        items: [ConversationItem] = [.user("private user prompt")],
        transportCallIDs: [String]? = nil
    ) async throws -> LiveConversationRecord {
        var record = LiveConversationRecord.new(sessionID: sessionID, workingDirectory: workspace)
        record.currentModelID = "grok-code-fast-1"
        record.currentProvider = provider
        record.everUsedNonXAI = everUsedNonXAI
        record.items = items
        record.codeModeTransportCallIDs = transportCallIDs
        try await LiveConversationStore(openGrokHome: home).save(record)
        return record
    }

    func metadata(sessionID: String = "writeback-session") throws -> LiveSessionWritebackMetadata {
        let state = try #require(
            try SessionDocumentStore(grokHome: home).load(sessionID: sessionID)
        )
        return LiveSessionWritebackMetadata(summary: state.summary)
    }

    func updates(sessionID: String = "writeback-session") throws -> [SessionUpdateEnvelope] {
        let state = try #require(
            try SessionDocumentStore(grokHome: home).load(sessionID: sessionID)
        )
        return state.updates
    }

    func client(
        transport: MockHTTPTransport,
        manager: AuthManager,
        boundary: ExportBoundary = ExportBoundary(),
        overrides: [String: String] = [:],
        clientIdentifier: String? = nil,
        clientMode: String = "interactive"
    ) throws -> LiveSessionWritebackClient {
        var resolvedEnvironment = environment
        resolvedEnvironment.merge(overrides) { _, override in override }
        return try LiveSessionWritebackClient(
            home: home,
            environment: resolvedEnvironment,
            authManager: manager,
            exportBoundary: boundary,
            transport: transport,
            clientIdentifier: clientIdentifier,
            clientMode: clientMode
        )
    }

    func response(
        status: Int = 200,
        body: String = "{}",
        url: URL? = nil
    ) -> MockHTTPTransport.ScriptedResponse {
        MockHTTPTransport.ScriptedResponse(
            metadata: HTTPResponseMetadata(statusCode: status, url: url),
            body: Data(body.utf8)
        )
    }

    func body(_ request: HTTPRequest) throws -> [String: Any] {
        let data = try #require(request.body)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite("first-party remote session writeback HTTP parity", .serialized)
struct LiveSessionWritebackClientParityTests {
    @Test("POST serializes persisted ACP JSON-RPC envelopes, never conversation items")
    func savesExactACPWire() async throws {
        let fixture = try SessionWritebackClientFixture()
        defer { fixture.cleanup() }
        let manager = try await fixture.manager(fixture.account())
        try await fixture.seed()
        let transport = MockHTTPTransport(responses: [fixture.response()])
        let client = try fixture.client(transport: transport, manager: manager)

        try await client.saveSessionData(
            sessionID: "writeback-session",
            updates: fixture.updates(),
            metadata: fixture.metadata()
        )

        let request = try #require(transport.recordedRequests.first)
        #expect(request.method == .post)
        #expect(request.url.absoluteString == "https://code.grok.com/sessions/writeback-session/data")
        #expect(request.idempotency == .nonIdempotent)
        let object = try fixture.body(request)
        let messages = try #require(object["messages"] as? [[String: Any]])
        let content = try #require(messages.first?["content"] as? String)
        let wrapper = try #require(
            try JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any]
        )
        #expect(wrapper["method"] as? String == "session/update")
        #expect(wrapper["timestamp"] == nil)
        let parameters = try #require(wrapper["params"] as? [String: Any])
        #expect(parameters["sessionId"] as? String == "writeback-session")
        let update = try #require(parameters["update"] as? [String: Any])
        #expect(update["sessionUpdate"] as? String == "user_message_chunk")
    }

    @Test("metadata retains all upstream snake_case session fields")
    func serializesCompleteMetadata() async throws {
        let metadata = LiveSessionWritebackMetadata(
            cwd: "/private/workspace",
            title: "A title",
            titleIsManual: true,
            modelID: "grok-4.6",
            createdAt: "2026-08-25T12:00:00Z",
            updatedAt: "2026-08-25T12:01:00Z",
            totalMessages: 7,
            parentSessionID: "parent",
            sessionKind: "subagent",
            subagentType: "explore",
            subagentPersona: "persona",
            subagentRole: "role",
            forkContextSource: "resumed",
            subagentDepth: 1
        )
        let object = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(metadata)) as? [String: Any]
        )
        #expect(object["title"] as? String == "A title")
        #expect(object["title_is_manual"] as? Bool == true)
        #expect(object["model_id"] as? String == "grok-4.6")
        #expect(object["created_at"] as? String == "2026-08-25T12:00:00Z")
        #expect(object["updated_at"] as? String == "2026-08-25T12:01:00Z")
        #expect(object["total_messages"] as? Int == 7)
        #expect(object["parent_session_id"] as? String == "parent")
        #expect(object["session_kind"] as? String == "subagent")
        #expect(object["subagent_type"] as? String == "explore")
        #expect(object["subagent_persona"] as? String == "persona")
        #expect(object["subagent_role"] as? String == "role")
        #expect(object["fork_context_source"] as? String == "resumed")
        #expect(object["subagent_depth"] as? Int == 1)
    }

    @Test("PUT upserts the active session with full metadata and agent identity")
    func upsertsExactSessionWire() async throws {
        let fixture = try SessionWritebackClientFixture()
        defer { fixture.cleanup() }
        let manager = try await fixture.manager(fixture.account())
        try await fixture.seed()
        let transport = MockHTTPTransport(responses: [fixture.response()])
        let client = try fixture.client(transport: transport, manager: manager)

        try await client.upsertSession(
            sessionID: "writeback-session",
            metadata: fixture.metadata(),
            agentID: "agent-123"
        )

        let request = try #require(transport.recordedRequests.first)
        #expect(request.method == .put)
        #expect(request.url.absoluteString == "https://code.grok.com/sessions/writeback-session")
        let object = try fixture.body(request)
        #expect(object["agentId"] as? String == "agent-123")
        let session = try #require(object["session"] as? [String: Any])
        #expect(session["cwd"] as? String == fixture.workspace.path)
        #expect(session["status"] as? String == "active")
        let metadata = try #require(session["metadata"] as? [String: Any])
        #expect(metadata["model_id"] as? String == "grok-code-fast-1")
    }

    @Test("every backend request includes first-party auth and client identity headers")
    func forwardsAccountAndClientHeaders() async throws {
        let fixture = try SessionWritebackClientFixture()
        defer { fixture.cleanup() }
        let manager = try await fixture.manager(fixture.account())
        try await fixture.seed()
        let transport = MockHTTPTransport(responses: [fixture.response()])
        let client = try fixture.client(
            transport: transport,
            manager: manager,
            clientIdentifier: "desktop-private",
            clientMode: "headless"
        )

        try await client.upsertSession(
            sessionID: "writeback-session",
            metadata: fixture.metadata(),
            agentID: "agent-123"
        )

        let request = try #require(transport.recordedRequests.first)
        #expect(request.headers["Authorization"] == "Bearer first-party-writeback-token")
        #expect(request.headers["X-XAI-Token-Auth"]?.isEmpty == false)
        #expect(request.headers["x-userid"] == "writeback-user")
        #expect(request.headers["x-email"] == "writeback@example.com")
        #expect(request.headers["x-grok-client-identifier"] == "desktop-private")
        #expect(request.headers["x-grok-client-mode"] == "headless")
        #expect(request.headers["x-grok-client-version"] == OpenGrokVersion.compiledVersion)
    }

    @Test("OIDC without a refresh token is never an export credential")
    func rejectsOIDCWithoutRefreshToken() async throws {
        try await rejectsAccount(
            { $0.account(refreshToken: nil) },
            expected: .unauthorized
        )
    }

    @Test("API keys cannot authorize private remote session storage")
    func rejectsAPIKeys() async throws {
        try await rejectsAccount(
            { $0.account(mode: .apiKey, issuer: nil) },
            expected: .unauthorized
        )
    }

    @Test("web-login credentials cannot authorize first-party session storage")
    func rejectsWebLogin() async throws {
        try await rejectsAccount(
            { $0.account(mode: .webLogin, issuer: nil) },
            expected: .unauthorized
        )
    }

    @Test("another provider's OIDC issuer cannot export sessions")
    func rejectsForeignIssuer() async throws {
        try await rejectsAccount(
            { $0.account(issuer: "https://auth.openai.com") },
            expected: .unauthorized
        )
    }

    @Test("valid first-party external account credentials may sync")
    func acceptsFirstPartyExternalAccount() async throws {
        let fixture = try SessionWritebackClientFixture()
        defer { fixture.cleanup() }
        let manager = try await fixture.manager(
            fixture.account(mode: .external, refreshToken: nil)
        )
        try await fixture.seed()
        let transport = MockHTTPTransport(responses: [fixture.response()])
        let client = try fixture.client(transport: transport, manager: manager)

        try await client.upsertSession(
            sessionID: "writeback-session",
            metadata: fixture.metadata(),
            agentID: "agent-123"
        )
        #expect(transport.recordedRequests.count == 1)
    }

    @Test("zero-data-retention teams never issue backend session requests")
    func rejectsZeroDataRetention() async throws {
        try await rejectsAccount(
            { $0.account(blockedReasons: ["BLOCKED_REASON_NO_LOGS"]) },
            expected: .zeroDataRetention
        )
    }

    @Test("coding-data opt-out does not disable Rust session writeback")
    func allowsCodingDataOptOut() async throws {
        let fixture = try SessionWritebackClientFixture()
        defer { fixture.cleanup() }
        let manager = try await fixture.manager(fixture.account(optedOut: true))
        try await fixture.seed()
        let transport = MockHTTPTransport(responses: [fixture.response()])
        let client = try fixture.client(transport: transport, manager: manager)

        try await client.upsertSession(
            sessionID: "writeback-session",
            metadata: fixture.metadata(),
            agentID: "agent-123"
        )
        #expect(transport.recordedRequests.count == 1)
    }

    @Test("a legacy record with no durable export marker fails closed")
    func rejectsMissingDurableBoundary() async throws {
        try await rejectsSession(everUsedNonXAI: nil)
    }

    @Test("a durable provider crossing permanently blocks remote export")
    func rejectsClosedDurableBoundary() async throws {
        try await rejectsSession(everUsedNonXAI: true)
    }

    @Test("the resident shared provider boundary is checked before the request")
    func rejectsClosedLiveBoundary() async throws {
        let fixture = try SessionWritebackClientFixture()
        defer { fixture.cleanup() }
        let manager = try await fixture.manager(fixture.account())
        try await fixture.seed()
        let boundary = ExportBoundary(everUsedNonXAI: true)
        let transport = MockHTTPTransport(responses: [fixture.response()])
        let client = try fixture.client(transport: transport, manager: manager, boundary: boundary)

        await #expect(throws: LiveSessionWritebackClientError.providerBoundaryClosed) {
            try await client.upsertSession(
                sessionID: "writeback-session",
                metadata: fixture.metadata(),
                agentID: "agent-123"
            )
        }
        #expect(transport.recordedRequests.isEmpty)
    }

    @Test("a non-xAI active provider cannot export even with a stale clean marker")
    func rejectsNonXAIRoute() async throws {
        let fixture = try SessionWritebackClientFixture()
        defer { fixture.cleanup() }
        let manager = try await fixture.manager(fixture.account())
        try await fixture.seed(provider: .codex, everUsedNonXAI: false)
        let transport = MockHTTPTransport(responses: [fixture.response()])
        let client = try fixture.client(transport: transport, manager: manager)

        await #expect(throws: LiveSessionWritebackClientError.providerBoundaryClosed) {
            try await client.upsertSession(
                sessionID: "writeback-session",
                metadata: fixture.metadata(),
                agentID: "agent-123"
            )
        }
        #expect(transport.recordedRequests.isEmpty)
    }

    @Test("Code Mode transport secrets are absent while same-name plugin calls survive")
    func stripsExactCodeModeTransportIDs() async throws {
        let fixture = try SessionWritebackClientFixture()
        defer { fixture.cleanup() }
        let manager = try await fixture.manager(fixture.account())
        try await fixture.seed(
            items: [
                .user("inspect safely"),
                .assistant(AssistantItem(content: "visible assistant", toolCalls: [
                    ToolCall(id: "transport-exec", name: "exec", arguments: #"{"source":"SECRET_JAVASCRIPT"}"#),
                    ToolCall(id: "plugin-exec", name: "exec", arguments: #"{"command":"visible plugin"}"#),
                    ToolCall(id: "nested-read", name: "read_file", arguments: #"{"path":"visible.swift"}"#),
                ])),
                .toolResult(ToolResultItem(toolCallId: "transport-exec", content: "SECRET_RESULT")),
                .toolResult(ToolResultItem(toolCallId: "plugin-exec", content: "visible plugin result")),
                .toolResult(ToolResultItem(toolCallId: "nested-read", content: "visible nested result")),
            ],
            transportCallIDs: ["transport-exec"]
        )
        let transport = MockHTTPTransport(responses: [fixture.response()])
        let client = try fixture.client(transport: transport, manager: manager)

        try await client.saveSessionData(
            sessionID: "writeback-session",
            updates: fixture.updates(),
            metadata: fixture.metadata()
        )

        let request = try #require(transport.recordedRequests.first)
        let body = String(decoding: try #require(request.body), as: UTF8.self)
        #expect(!body.contains("SECRET_JAVASCRIPT"))
        #expect(!body.contains("SECRET_RESULT"))
        #expect(!body.contains("transport-exec"))
        #expect(body.contains("plugin-exec"))
        #expect(body.contains("visible plugin"))
        #expect(body.contains("nested-read"))
    }

    @Test("a callback envelope targeting another session is rejected before sending")
    func rejectsCrossSessionEnvelope() async throws {
        let fixture = try SessionWritebackClientFixture()
        defer { fixture.cleanup() }
        let manager = try await fixture.manager(fixture.account())
        try await fixture.seed()
        let transport = MockHTTPTransport(responses: [fixture.response()])
        let client = try fixture.client(transport: transport, manager: manager)
        let foreign = try SessionUpdateEnvelope(
            method: "session/update",
            params: .object([
                "sessionId": .string("different-session"),
                "update": .object(["sessionUpdate": .string("agent_message_chunk")]),
            ])
        )

        await #expect(throws: LiveSessionWritebackClientError.invalidEnvelope) {
            try await client.saveSessionData(
                sessionID: "writeback-session",
                updates: [foreign],
                metadata: fixture.metadata()
            )
        }
        #expect(transport.recordedRequests.isEmpty)
    }

    @Test("notification timestamps use ACP metadata, never local journal timestamps")
    func extractsNotificationMetadataTimestamp() async throws {
        let fixture = try SessionWritebackClientFixture()
        defer { fixture.cleanup() }
        let manager = try await fixture.manager(fixture.account())
        try await fixture.seed()
        let transport = MockHTTPTransport(responses: [fixture.response()])
        let client = try fixture.client(transport: transport, manager: manager)
        let notification = try SessionUpdateEnvelope(
            timestamp: 123_456,
            method: "session/update",
            params: .object([
                "sessionId": .string("writeback-session"),
                "update": .object(["sessionUpdate": .string("agent_message_chunk")]),
                "_meta": .object(["timestamp": .string("2026-08-25T12:00:00Z")]),
            ])
        )

        try await client.saveSessionData(
            sessionID: "writeback-session",
            updates: [notification],
            metadata: fixture.metadata()
        )

        let object = try fixture.body(try #require(transport.recordedRequests.first))
        let messages = try #require(object["messages"] as? [[String: Any]])
        #expect(messages.first?["timestamp"] as? String == "2026-08-25T12:00:00Z")
        let content = try #require(messages.first?["content"] as? String)
        #expect(!content.contains("123456"))
    }

    @Test("same-account durable token rotation is adopted between requests")
    func adoptsRotatedDurableToken() async throws {
        let fixture = try SessionWritebackClientFixture()
        defer { fixture.cleanup() }
        let manager = try await fixture.manager(fixture.account())
        try await fixture.seed()
        let transport = MockHTTPTransport(responses: [fixture.response(), fixture.response()])
        let client = try fixture.client(transport: transport, manager: manager)
        try await client.saveSessionData(
            sessionID: "writeback-session",
            updates: fixture.updates(),
            metadata: fixture.metadata()
        )

        let sibling = try await fixture.manager()
        try await sibling.loginWithSession(fixture.account(key: "rotated-private-bearer"))
        try await client.upsertSession(
            sessionID: "writeback-session",
            metadata: fixture.metadata(),
            agentID: "agent-123"
        )

        #expect(transport.recordedRequests.count == 2)
        #expect(transport.recordedRequests[0].headers["Authorization"] == "Bearer first-party-writeback-token")
        #expect(transport.recordedRequests[1].headers["Authorization"] == "Bearer rotated-private-bearer")
    }

    @Test("switching accounts between flush and upsert permanently closes export")
    func rejectsAccountSwitchBetweenRequests() async throws {
        let fixture = try SessionWritebackClientFixture()
        defer { fixture.cleanup() }
        let manager = try await fixture.manager(fixture.account())
        try await fixture.seed()
        let boundary = ExportBoundary()
        let transport = MockHTTPTransport(responses: [fixture.response(), fixture.response()])
        let client = try fixture.client(transport: transport, manager: manager, boundary: boundary)
        try await client.saveSessionData(
            sessionID: "writeback-session",
            updates: fixture.updates(),
            metadata: fixture.metadata()
        )

        let sibling = try await fixture.manager()
        try await sibling.loginWithSession(fixture.account(userID: "different-user"))
        await #expect(throws: LiveSessionWritebackClientError.accountChanged) {
            try await client.upsertSession(
                sessionID: "writeback-session",
                metadata: fixture.metadata(),
                agentID: "agent-123"
            )
        }
        #expect(transport.recordedRequests.count == 1)
        #expect(!boundary.allowsXaiExport)
    }

    @Test("logout between flush and upsert prevents any stale cached bearer reuse")
    func rejectsLogoutBetweenRequests() async throws {
        let fixture = try SessionWritebackClientFixture()
        defer { fixture.cleanup() }
        let manager = try await fixture.manager(fixture.account())
        try await fixture.seed()
        let transport = MockHTTPTransport(responses: [fixture.response(), fixture.response()])
        let client = try fixture.client(transport: transport, manager: manager)
        try await client.saveSessionData(
            sessionID: "writeback-session",
            updates: fixture.updates(),
            metadata: fixture.metadata()
        )

        let sibling = try await fixture.manager()
        let outcome = try await sibling.clear()
        #expect(outcome.wasLoggedIn)
        await #expect(throws: LiveSessionWritebackClientError.unauthorized) {
            try await client.upsertSession(
                sessionID: "writeback-session",
                metadata: fixture.metadata(),
                agentID: "agent-123"
            )
        }
        #expect(transport.recordedRequests.count == 1)
    }

    @Test("a 401 PUT retries once after a genuinely refreshed first-party bearer")
    func retriesIdempotentUnauthorizedRequestOnce() async throws {
        let fixture = try SessionWritebackClientFixture()
        defer { fixture.cleanup() }
        let original = fixture.account()
        let manager = try await fixture.manager(original)
        var refreshed = original
        refreshed.key = "refreshed-private-bearer"
        let refresher = MockTokenRefresher(outcome: .success(refreshed))
        await manager.configureRefresher(refresher)
        try await fixture.seed()
        let transport = MockHTTPTransport(responses: [
            fixture.response(status: 401),
            fixture.response(),
        ])
        let client = try fixture.client(transport: transport, manager: manager)

        try await client.upsertSession(
            sessionID: "writeback-session",
            metadata: fixture.metadata(),
            agentID: "agent-123"
        )

        #expect(transport.recordedRequests.count == 2)
        #expect(transport.recordedRequests[1].headers["Authorization"] == "Bearer refreshed-private-bearer")
        #expect(refresher.callCountBox.count == 1)
    }

    @Test("a rejected non-idempotent POST never replays private ACP data")
    func doesNotRetryUnauthorizedPost() async throws {
        let fixture = try SessionWritebackClientFixture()
        defer { fixture.cleanup() }
        let original = fixture.account()
        let manager = try await fixture.manager(original)
        var refreshed = original
        refreshed.key = "must-never-be-requested"
        let refresher = MockTokenRefresher(outcome: .success(refreshed))
        await manager.configureRefresher(refresher)
        try await fixture.seed()
        let transport = MockHTTPTransport(responses: [
            fixture.response(status: 401),
            fixture.response(),
        ])
        let client = try fixture.client(transport: transport, manager: manager)

        await #expect(throws: LiveSessionWritebackClientError.requestFailed(status: 401, body: "{}")) {
            try await client.saveSessionData(
                sessionID: "writeback-session",
                updates: fixture.updates(),
                metadata: fixture.metadata()
            )
        }
        #expect(transport.recordedRequests.count == 1)
        #expect(refresher.callCountBox.count == 0)
    }

    @Test("remote session load validates its returned identity")
    func loadsRemoteSession() async throws {
        let fixture = try SessionWritebackClientFixture()
        defer { fixture.cleanup() }
        let manager = try await fixture.manager(fixture.account())
        let response = #"{"messages":[{"id":"msg-1","content":"{}"}],"session":{"sessionId":"remote-only","cwd":"/workspace","title":"Remote"}}"#
        let transport = MockHTTPTransport(responses: [fixture.response(body: response)])
        let client = try fixture.client(transport: transport, manager: manager)

        let loaded = try #require(try await client.loadSessionData(sessionID: "remote-only"))
        #expect(loaded.session?.sessionID == "remote-only")
        #expect(loaded.session?.cwd == "/workspace")
        #expect(loaded.messages?.first?.id == "msg-1")
        #expect(transport.recordedRequests.first?.method == .get)
    }

    @Test("a missing remote session and already-deleted copy remain idempotent")
    func treatsNotFoundAsAbsence() async throws {
        let fixture = try SessionWritebackClientFixture()
        defer { fixture.cleanup() }
        let manager = try await fixture.manager(fixture.account())
        let transport = MockHTTPTransport(responses: [
            fixture.response(status: 404),
            fixture.response(status: 404),
        ])
        let client = try fixture.client(transport: transport, manager: manager)

        #expect(try await client.loadSessionData(sessionID: "remote-only") == nil)
        #expect(try await client.deleteSessionData(sessionID: "remote-only") == false)
        #expect(transport.recordedRequests.map(\.method) == [.get, .delete])
    }

    @Test("remote deletion remains possible after the local provider boundary closes")
    func deletionDoesNotRequireExportBoundary() async throws {
        let fixture = try SessionWritebackClientFixture()
        defer { fixture.cleanup() }
        let manager = try await fixture.manager(fixture.account())
        let boundary = ExportBoundary(everUsedNonXAI: true)
        let transport = MockHTTPTransport(responses: [fixture.response()])
        let client = try fixture.client(transport: transport, manager: manager, boundary: boundary)

        #expect(try await client.deleteSessionData(sessionID: "remote-only") == true)
        #expect(transport.recordedRequests.count == 1)
    }

    @Test("cross-session remote load responses are refused")
    func rejectsMismatchedRemoteIdentity() async throws {
        let fixture = try SessionWritebackClientFixture()
        defer { fixture.cleanup() }
        let manager = try await fixture.manager(fixture.account())
        let response = #"{"session":{"sessionId":"different-remote"}}"#
        let transport = MockHTTPTransport(responses: [fixture.response(body: response)])
        let client = try fixture.client(transport: transport, manager: manager)

        await #expect(throws: LiveSessionWritebackClientError.invalidResponse) {
            _ = try await client.loadSessionData(sessionID: "requested-remote")
        }
    }

    @Test("foreign and cleartext backend origins are rejected before any request")
    func rejectsForeignBackends() async throws {
        let fixture = try SessionWritebackClientFixture()
        defer { fixture.cleanup() }
        let manager = try await fixture.manager(fixture.account())
        let invalid = [
            "https://steal.example",
            "http://code.grok.com",
            "https://code.grok.com@steal.example",
            "https://code.grok.com/private",
            "https://code.grok.com?destination=private",
            "http://localhost:8080",
        ]
        for endpoint in invalid {
            let transport = MockHTTPTransport()
            #expect(throws: LiveSessionWritebackClientError.invalidEndpoint) {
                _ = try fixture.client(
                    transport: transport,
                    manager: manager,
                    overrides: ["GROK_CODE_BACKEND_URL": endpoint]
                )
            }
            #expect(transport.recordedRequests.isEmpty)
        }
    }

    @Test("an explicitly configured literal loopback backend is the sole HTTP test seam")
    func permitsExplicitLiteralLoopback() async throws {
        let fixture = try SessionWritebackClientFixture()
        defer { fixture.cleanup() }
        let manager = try await fixture.manager(fixture.account())
        let transport = MockHTTPTransport(responses: [fixture.response()])
        let client = try fixture.client(
            transport: transport,
            manager: manager,
            overrides: ["GROK_CODE_BACKEND_URL": "http://127.0.0.1:41823"]
        )

        #expect(try await client.deleteSessionData(sessionID: "loopback-session"))
        #expect(
            transport.recordedRequests.first?.url.absoluteString
                == "http://127.0.0.1:41823/sessions/loopback-session/data"
        )
    }

    @Test("HTTP redirects and a changed final URL are never accepted")
    func rejectsRedirectsAndOriginChanges() async throws {
        let fixture = try SessionWritebackClientFixture()
        defer { fixture.cleanup() }
        let manager = try await fixture.manager(fixture.account())
        let cases = [
            fixture.response(status: 307),
            fixture.response(url: URL(string: "https://steal.example/sessions/remote/data")),
        ]
        for scripted in cases {
            let transport = MockHTTPTransport(responses: [scripted])
            let client = try fixture.client(transport: transport, manager: manager)
            await #expect(throws: LiveSessionWritebackClientError.redirectRejected) {
                _ = try await client.deleteSessionData(sessionID: "remote")
            }
        }
    }

    @Test("path traversal is rejected before authentication or network I/O")
    func rejectsInvalidSessionID() async throws {
        let fixture = try SessionWritebackClientFixture()
        defer { fixture.cleanup() }
        let manager = try await fixture.manager(fixture.account())
        let transport = MockHTTPTransport()
        let client = try fixture.client(transport: transport, manager: manager)

        await #expect(throws: LiveSessionWritebackClientError.invalidSessionID) {
            _ = try await client.deleteSessionData(sessionID: "../../private")
        }
        #expect(transport.recordedRequests.isEmpty)
    }

    private func rejectsAccount(
        _ makeAccount: (SessionWritebackClientFixture) -> GrokAuth,
        expected: LiveSessionWritebackClientError
    ) async throws {
        let fixture = try SessionWritebackClientFixture()
        defer { fixture.cleanup() }
        let manager = try await fixture.manager(makeAccount(fixture))
        try await fixture.seed()
        let transport = MockHTTPTransport(responses: [fixture.response()])
        let client = try fixture.client(transport: transport, manager: manager)

        await #expect(throws: expected) {
            try await client.upsertSession(
                sessionID: "writeback-session",
                metadata: fixture.metadata(),
                agentID: "agent-123"
            )
        }
        #expect(transport.recordedRequests.isEmpty)
    }

    private func rejectsSession(everUsedNonXAI: Bool?) async throws {
        let fixture = try SessionWritebackClientFixture()
        defer { fixture.cleanup() }
        let manager = try await fixture.manager(fixture.account())
        try await fixture.seed(everUsedNonXAI: everUsedNonXAI)
        let transport = MockHTTPTransport(responses: [fixture.response()])
        let client = try fixture.client(transport: transport, manager: manager)

        await #expect(throws: LiveSessionWritebackClientError.providerBoundaryClosed) {
            try await client.upsertSession(
                sessionID: "writeback-session",
                metadata: fixture.metadata(),
                agentID: "agent-123"
            )
        }
        #expect(transport.recordedRequests.isEmpty)
    }
}
