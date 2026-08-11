// ACPShareSessionExtensionTests.swift
//
// `x.ai/share_session` through the live ACP router: RAW `{"share_url":…}`
// when authorized (share.rs:145-146 `to_raw_response`), and `auth_required`
// with upstream's refusal string when unauthenticated (share.rs:35).

import Foundation
import OpenGrokACP
import OpenGrokAuth
import OpenGrokConfigTypes
import OpenGrokHTTP
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokShellSessionSupport
import OpenGrokTestSupport
import Testing

@testable import OpenGrokACPRuntime
@testable import OpenGrokCLI

private typealias JSONValue = OpenGrokShared.JSONValue

// MARK: - Mocks

private final class MockShareBackendClient: ShareBackendClient, @unchecked Sendable {
    let url: String
    init(url: String) { self.url = url }

    func shareSession(
        sessionID: String,
        items: [ConversationItem],
        title: String?,
        cwd: String
    ) async throws -> String {
        url
    }
}

private final class MockShareSignedUploadClient: ShareSignedUploadClient, @unchecked Sendable {
    func uploadShareData(
        sessionID: String,
        items: [ConversationItem],
        boundary: ExportBoundary?
    ) async {}
}

// MARK: - Harness

private func makeHome() throws -> URL {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("opengrok-acp-share-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    return home
}

private func xaiAuth() -> GrokAuth {
    GrokAuth(
        key: "test-key",
        authMode: .oidc,
        userID: "user-1",
        teamBlockedReasons: [],
        codingDataRetentionOptOut: false,
        oidcIssuer: "https://auth.x.ai"
    )
}

private func inlineAuth(_ auth: GrokAuth) throws -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .custom { date, enc in
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var container = enc.singleValueContainer()
        try container.encode(formatter.string(from: date))
    }
    return String(decoding: try encoder.encode(auth), as: UTF8.self)
}

private func sharingSettings(_ enabled: Bool) throws -> RemoteSettings {
    try JSONDecoder().decode(
        RemoteSettings.self,
        from: Data(#"{"sharing_enabled": \#(enabled)}"#.utf8)
    )
}

@discardableResult
private func seedSession(
    home: URL,
    id: String,
    items: [ConversationItem]
) async throws -> LiveConversationRecord {
    var record = LiveConversationRecord.new(
        sessionID: id,
        workingDirectory: URL(fileURLWithPath: "/tmp/project")
    )
    record.items = items
    record.everUsedNonXAI = false
    try await LiveConversationStore(openGrokHome: home).save(record)
    return record
}

private struct ShareACPHarness {
    let home: URL
    let runtime: ACPAgentRuntime

    static func start(
        authenticated: Bool,
        sharingEnabled: Bool = true,
        backendURL: String = "https://grok.com/build/share/test-link"
    ) async throws -> ShareACPHarness {
        let home = try makeHome()
        var environment = ["OPENGROK_HOME": home.path, "HOME": home.path]
        if authenticated {
            environment["OPENGROK_AUTH"] = try inlineAuth(xaiAuth())
        }
        let settings = try sharingSettings(sharingEnabled)
        let routeDependencies = LiveShareRouteDependencies(
            loadRemoteSettings: { _ in settings },
            makeSignedUploadClient: { _, _ in nil },
            makeBackendClient: { _, _ in nil }
        )
        let handler = LiveShareACPHandler(
            environment: environment,
            liveBoundaries: nil,
            routeDependencies: routeDependencies,
            signedUploadClient: MockShareSignedUploadClient(),
            backendClient: MockShareBackendClient(url: backendURL)
        )
        let router = LiveACPExtensionRouter.build(
            feedback: nil,
            models: LiveModelsACPHandler(
                catalogStore: LiveModelCatalogStore(
                    input: .default,
                    environment: environment,
                    openGrokHome: home,
                    transport: MockHTTPTransport(responses: [])
                ),
                modelSwitch: nil
            ),
            share: handler
        )
        let runtime = ACPAgentRuntime(extensionRouter: router)
        let output = await runtime.handle(.request(
            id: .string("init"),
            method: AgentMethodNames.initialize,
            params: try JSONValue.encode(InitializeRequest(protocolVersion: .v1))
        ))
        guard case .response(_, _, nil) = output[0] else {
            throw ACPTransportError.invalidMessage("initialize failed: \(output)")
        }
        return ShareACPHarness(home: home, runtime: runtime)
    }

    func call(
        params: JSONValue,
        id: String = "share-1"
    ) async -> (result: JSONValue?, error: AcpError?) {
        let output = await runtime.handle(.request(
            id: .string(id),
            method: LiveShareACPHandler.method,
            params: params
        ))
        guard case .response(_, let result, let error) = output[0] else {
            return (nil, AcpError.internalError("no response"))
        }
        return (result, error)
    }

    func shutdown() {
        try? FileManager.default.removeItem(at: home)
    }
}

// MARK: - Tests

@Suite("ACP share_session", .serialized)
struct ACPShareSessionExtensionTests {
    @Test("authorized share returns raw share_url without ExtMethodResult envelope")
    func authorizedShareReturnsURL() async throws {
        let harness = try await ShareACPHarness.start(authenticated: true)
        defer { harness.shutdown() }
        try await seedSession(
            home: harness.home,
            id: "sess-share-1",
            items: [.user("hello")]
        )

        let (result, error) = await harness.call(params: .object([
            "session_id": .string("sess-share-1"),
        ]))
        #expect(error == nil)
        // RAW ShareSessionResponse — to_raw_response, no result envelope
        // (share.rs:145-146, extensions/mod.rs:69-73).
        #expect(result == .object([
            "share_url": .string("https://grok.com/build/share/test-link"),
        ]))
        #expect(result?["result"] == nil)
    }

    @Test("unauthenticated share refuses with auth_required and upstream copy")
    func unauthenticatedRefusesAuthRequired() async throws {
        let harness = try await ShareACPHarness.start(authenticated: false)
        defer { harness.shutdown() }
        try await seedSession(
            home: harness.home,
            id: "sess-share-2",
            items: [.user("hello")]
        )

        let (result, error) = await harness.call(params: .object([
            "session_id": .string("sess-share-2"),
        ]))
        #expect(result == nil)
        #expect(error?.code == .authRequired)
        #expect(error?.data == .string("Authentication required to share session"))
    }

    @Test("camelCase sessionId is accepted alongside snake_case session_id")
    func acceptsCamelCaseSessionId() async throws {
        let harness = try await ShareACPHarness.start(authenticated: true)
        defer { harness.shutdown() }
        try await seedSession(
            home: harness.home,
            id: "sess-share-3",
            items: [.user("hello")]
        )

        let (result, error) = await harness.call(params: .object([
            "sessionId": .string("sess-share-3"),
        ]))
        #expect(error == nil)
        #expect(result?["share_url"]?.stringValue == "https://grok.com/build/share/test-link")
    }
}
