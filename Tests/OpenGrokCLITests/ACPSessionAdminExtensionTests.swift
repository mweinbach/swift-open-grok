// ACPSessionAdminExtensionTests.swift
//
// The routed session-admin trio — `x.ai/session/rename` / `delete` / `fork`
// (Wave 15 item 6) — asserted against the REAL conversation store files
// (AGENTS.md §3): every assertion re-reads `$OPENGROK_HOME/sessions/*.json`
// after the call, never the handler's word for it. The live-session rename
// is proven where it matters: the title must SURVIVE a subsequent turn
// commit through the live history actor, which is exactly the write that
// clobbers a naive store-side rename. One leg runs over the real ws://
// carrier.

import Foundation
import OpenGrokACP
import OpenGrokHTTP
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokTestSupport
import Testing

@testable import OpenGrokACPRuntime
@testable import OpenGrokCLI

private typealias JSONValue = OpenGrokShared.JSONValue

// MARK: - Harness

private func makeHome() throws -> URL {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("opengrok-acp-sessadmin-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    return home
}

/// Seed one persisted session the way the launch path persists them: a real
/// record written through the real store.
@discardableResult
private func seedSession(
    home: URL,
    id: String,
    cwd: URL,
    items: [ConversationItem] = [],
    title: String? = nil
) async throws -> LiveConversationRecord {
    let store = LiveConversationStore(openGrokHome: home)
    var record = LiveConversationRecord.new(sessionID: id, workingDirectory: cwd)
    record.items = items
    record.title = title
    try await store.save(record)
    return record
}

private func readRecord(home: URL, id: String) throws -> LiveConversationRecord {
    let url = home.appendingPathComponent("sessions/\(id).json")
    return try JSONDecoder().decode(
        LiveConversationRecord.self,
        from: try Data(contentsOf: url)
    )
}

private struct SessionAdminHarness {
    let home: URL
    let runtime: ACPAgentRuntime
    let gateway: ACPNotificationGateway

    static func start(
        home explicitHome: URL? = nil,
        liveSessionID: String? = nil,
        renameLive: (@Sendable (String) async throws -> Void)? = nil
    ) async throws -> SessionAdminHarness {
        let home = try explicitHome ?? makeHome()
        let environment = ["OPENGROK_HOME": home.path, "HOME": home.path]
        let gateway = ACPNotificationGateway()
        let handler = LiveSessionAdminACPHandler(
            openGrokHome: home,
            gateway: gateway,
            liveSessionID: liveSessionID,
            renameLive: renameLive
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
            sessionAdmin: handler
        )
        let runtime = ACPAgentRuntime(extensionRouter: router)
        await gateway.attach(runtime)
        let output = await runtime.handle(.request(
            id: .string("init"),
            method: AgentMethodNames.initialize,
            params: try JSONValue.encode(InitializeRequest(protocolVersion: .v1))
        ))
        guard case .response(_, _, nil) = output[0] else {
            throw ACPTransportError.invalidMessage("initialize failed: \(output)")
        }
        return SessionAdminHarness(home: home, runtime: runtime, gateway: gateway)
    }

    func call(
        _ method: String,
        id: String,
        params: JSONValue = .object([:])
    ) async -> (result: JSONValue?, error: AcpError?) {
        let output = await runtime.handle(.request(
            id: .string(id),
            method: method,
            params: params
        ))
        guard case .response(_, let result, let error) = output[0] else {
            return (nil, AcpError.internalError("no response for \(method)"))
        }
        return (result, error)
    }

    func shutdown() {
        try? FileManager.default.removeItem(at: home)
    }
}

// MARK: - rename

@Suite("ACP session admin", .serialized)
struct ACPSessionAdminExtensionTests {
    @Test("rename writes the stored title, answers raw success, and broadcasts SessionSummaryGenerated")
    func renameStoredSession() async throws {
        let harness = try await SessionAdminHarness.start()
        defer { harness.shutdown() }
        try await seedSession(
            home: harness.home, id: "stored-1", cwd: harness.home,
            items: [.user("first prompt")]
        )

        let (result, error) = await harness.call(
            "x.ai/session/rename",
            id: "r1",
            params: .object([
                "sessionId": .string("stored-1"),
                "title": .string("  Renamed over ACP  "),
            ])
        )
        #expect(error == nil)
        // RAW `{"success": true}` — to_raw_response, no result envelope
        // (session_admin.rs:199, extensions/mod.rs:69-73).
        #expect(result == .object(["success": .bool(true)]))
        #expect(result?["result"] == nil)

        // The landed file carries the trimmed title.
        let record = try readRecord(home: harness.home, id: "stored-1")
        #expect(record.title == "Renamed over ACP")

        // The SessionSummaryGenerated broadcast rode the gateway.
        let notifications = await harness.runtime.pollNotifications()
        let summary = notifications.first {
            $0.method == "x.ai/session_notification"
                && $0.params?["update"]?["sessionUpdate"]?.stringValue
                    == "session_summary_generated"
        }
        let update = try #require(summary?.params)
        #expect(update["sessionId"]?.stringValue == "stored-1")
        #expect(update["update"]?["session_summary"]?.stringValue == "Renamed over ACP")
    }

    @Test("rename refusal arms carry upstream's copy byte-exact")
    func renameRefusals() async throws {
        let harness = try await SessionAdminHarness.start()
        defer { harness.shutdown() }
        try await seedSession(home: harness.home, id: "stored-2", cwd: harness.home)

        // Blank title (session_admin.rs:93-98).
        let (_, blank) = await harness.call(
            "x.ai/session/rename",
            id: "rr1",
            params: .object(["sessionId": .string("stored-2"), "title": .string("   ")])
        )
        #expect(blank?.code == .invalidRequest)
        #expect(blank?.data == .string("title must not be blank"))

        // Chat kind: the conversations lane does not exist in this port
        // (session_admin.rs:228-231).
        let (_, chat) = await harness.call(
            "x.ai/session/rename",
            id: "rr2",
            params: .object([
                "sessionId": .string("stored-2"),
                "title": .string("t"),
                "kind": .string("chat"),
            ])
        )
        #expect(chat?.code == .invalidRequest)
        #expect(chat?.data == .string(
            "chat session rename requires the conversations lane (OIDC + chat feature)"
        ))

        // Unknown session (session_admin.rs:111-116).
        let (_, missing) = await harness.call(
            "x.ai/session/rename",
            id: "rr3",
            params: .object(["sessionId": .string("ghost"), "title": .string("t")])
        )
        #expect(missing?.code == .invalidRequest)
        #expect(missing?.data == .string("session not found: ghost"))

        // A cwd scope that does not match the record is "not found" —
        // upstream's list_summaries(cwd) lookup.
        let (_, scoped) = await harness.call(
            "x.ai/session/rename",
            id: "rr4",
            params: .object([
                "sessionId": .string("stored-2"),
                "title": .string("t"),
                "cwd": .string("/nonexistent/elsewhere"),
            ])
        )
        #expect(scoped?.code == .invalidRequest)
        #expect(scoped?.data == .string("session not found: stored-2"))
    }

    @Test("renaming the resident session goes through the live history actor and survives the next turn commit")
    func renameLiveSessionSurvivesCommit() async throws {
        let home = try makeHome()
        // The live spine — the SAME store directory the handler reads, the
        // same actor the turn driver commits through.
        let store = LiveConversationStore(openGrokHome: home)
        var record = LiveConversationRecord.new(sessionID: "live-1", workingDirectory: home)
        record.items = [.user("hello")]
        try await store.save(record)
        let history = LiveConversationHistory(record: record, store: store)

        let harness = try await SessionAdminHarness.start(
            home: home,
            liveSessionID: "live-1",
            renameLive: { title in try await history.rename(title: title) }
        )
        defer { harness.shutdown() }

        let (result, error) = await harness.call(
            "x.ai/session/rename",
            id: "rl1",
            params: .object([
                "sessionId": .string("live-1"),
                "title": .string("Live title"),
            ])
        )
        #expect(error == nil)
        #expect(result == .object(["success": .bool(true)]))

        // The load-bearing assertion: a subsequent turn commit through the
        // live history actor must NOT clobber the title — which it would if
        // the rename had gone around the actor (the store-write footgun the
        // handler's live branch exists to avoid).
        try await history.commit(
            sessionID: "live-1",
            items: [.user("hello"), .user("second prompt")]
        )
        let after = try readRecord(home: home, id: "live-1")
        #expect(after.title == "Live title")
        #expect(after.items.count == 2)
    }

    // MARK: delete

    @Test("delete removes the session file and rewind sidecar; a second delete stays idempotent-success")
    func deleteSession() async throws {
        let harness = try await SessionAdminHarness.start()
        defer { harness.shutdown() }
        try await seedSession(home: harness.home, id: "doomed", cwd: harness.home)
        // A rewind sidecar holding verbatim user file copies must go with
        // the session (the sessions-CLI delete contract).
        let rewindURL = LiveRewindStore.rewindFileURL(
            openGrokHome: harness.home, sessionID: "doomed")
        try FileManager.default.createDirectory(
            at: rewindURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("rewind".utf8).write(to: rewindURL)

        let (result, error) = await harness.call(
            "x.ai/session/delete",
            id: "d1",
            params: .object(["sessionId": .string("doomed")])
        )
        #expect(error == nil)
        #expect(result == .object(["success": .bool(true)]))
        let sessionPath = harness.home.appendingPathComponent("sessions/doomed.json")
        #expect(!FileManager.default.fileExists(atPath: sessionPath.path))
        #expect(!FileManager.default.fileExists(atPath: rewindURL.path))

        // Idempotent: a missing session still succeeds
        // (persistence.rs:3216-3218, 3260-3265).
        let (again, againError) = await harness.call(
            "x.ai/session/delete",
            id: "d2",
            params: .object(["sessionId": .string("doomed")])
        )
        #expect(againError == nil)
        #expect(again == .object(["success": .bool(true)]))
    }

    @Test("delete refuses the resident session and the chat kind")
    func deleteRefusals() async throws {
        let harness = try await SessionAdminHarness.start(liveSessionID: "resident")
        defer { harness.shutdown() }
        try await seedSession(home: harness.home, id: "resident", cwd: harness.home)

        // The resident session cannot be deleted out from under the live
        // spine — recorded divergence 2 (no teardown seam; the file would
        // resurrect at the next commit).
        let (_, live) = await harness.call(
            "x.ai/session/delete",
            id: "dr1",
            params: .object(["sessionId": .string("resident")])
        )
        #expect(live?.code == .internalError)
        #expect(live?.data?.stringValue?.contains("currently serving") == true)
        #expect(FileManager.default.fileExists(
            atPath: harness.home.appendingPathComponent("sessions/resident.json").path))

        // Chat kind (session_admin.rs:323-326).
        let (_, chat) = await harness.call(
            "x.ai/session/delete",
            id: "dr2",
            params: .object(["sessionId": .string("other"), "kind": .string("chat")])
        )
        #expect(chat?.code == .invalidRequest)
        #expect(chat?.data == .string(
            "chat session delete requires the conversations lane (OIDC + chat feature)"
        ))
    }

    // MARK: fork

    @Test("fork copies the transcript under a new id with parent tracking and answers the raw camelCase response")
    func forkSession() async throws {
        let harness = try await SessionAdminHarness.start()
        defer { harness.shutdown() }
        try await seedSession(
            home: harness.home, id: "parent-1", cwd: harness.home,
            items: [.user("one"), .user("two")]
        )
        let newCwd = harness.home.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: newCwd, withIntermediateDirectories: true)

        let (result, error) = await harness.call(
            "x.ai/session/fork",
            id: "f1",
            params: .object([
                "sourceSessionId": .string("parent-1"),
                "sourceCwd": .string(harness.home.path),
                "newCwd": .string(newCwd.path),
                "newSessionId": .string("child-1"),
            ])
        )
        #expect(error == nil)
        // RAW ForkSessionResponse (fork.rs:40-54): camelCase, no envelope.
        #expect(result?["newSessionId"]?.stringValue == "child-1")
        #expect(result?["chatMessagesCopied"]?.int64Value == 2)
        #expect(result?["updatesCopied"]?.int64Value == 0)
        #expect(result?["planStateCopied"]?.boolValue == false)
        #expect(result?["newCwd"]?.stringValue == newCwd.path)
        #expect(result?["parentSessionId"]?.stringValue == "parent-1")
        #expect(result?["newModelId"] == nil)
        #expect(result?["result"] == nil)

        // The landed child file: parent tracking + copied transcript.
        let child = try readRecord(home: harness.home, id: "child-1")
        #expect(child.parentSessionID == "parent-1")
        #expect(child.items.count == 2)
        #expect(URL(fileURLWithPath: child.workingDirectory).standardizedFileURL.path
            == newCwd.standardizedFileURL.path)
    }

    @Test("fork refuses unknown sources, mismatched source cwds, and the option arms this store cannot honor")
    func forkRefusals() async throws {
        let harness = try await SessionAdminHarness.start()
        defer { harness.shutdown() }
        try await seedSession(home: harness.home, id: "parent-2", cwd: harness.home)

        let (_, missing) = await harness.call(
            "x.ai/session/fork",
            id: "fr1",
            params: .object([
                "sourceSessionId": .string("ghost"),
                "sourceCwd": .string(harness.home.path),
                "newCwd": .string(harness.home.path),
            ])
        )
        #expect(missing?.code == .internalError)
        #expect(missing?.data == .string("session not found: ghost"))

        let (_, scoped) = await harness.call(
            "x.ai/session/fork",
            id: "fr2",
            params: .object([
                "sourceSessionId": .string("parent-2"),
                "sourceCwd": .string("/nonexistent/elsewhere"),
                "newCwd": .string(harness.home.path),
            ])
        )
        #expect(scoped?.code == .internalError)
        #expect(scoped?.data == .string("session not found: parent-2"))

        // Recorded divergence 3: the unsupported option arms fail loud
        // rather than silently dropping their payloads.
        let (_, unsupported) = await harness.call(
            "x.ai/session/fork",
            id: "fr3",
            params: .object([
                "sourceSessionId": .string("parent-2"),
                "sourceCwd": .string(harness.home.path),
                "newCwd": .string(harness.home.path),
                "targetPromptIndex": .number(.int64(1)),
            ])
        )
        #expect(unsupported?.code == .internalError)
        #expect(unsupported?.data?.stringValue?.contains("targetPromptIndex") == true)
    }
}

// MARK: - ws:// carrier

private func wsConnect(
    to endpoint: ACPServeEndpoint,
    secret: String
) async throws -> ACPWebSocketConnectionTransport {
    let channel = try await WebSocketNetworkChannel.connect(
        host: endpoint.host,
        port: endpoint.port
    )
    let connection = try await WebSocketClientUpgrade.connect(
        channel: channel,
        host: endpoint.address,
        target: endpoint.path + "?server-key=\(secret)"
    )
    return ACPWebSocketConnectionTransport(connection: connection)
}

private func wsDrain(
    _ transport: ACPWebSocketConnectionTransport,
    limit: Int = 40,
    until match: (ACPMessage) -> Bool
) async throws -> ACPMessage {
    for _ in 0..<limit {
        let message = try await transport.receive()
        if match(message) { return message }
    }
    throw ACPTransportError.closed
}

@Suite("ACP session admin over ws://", .serialized)
struct ACPSessionAdminServeTests {
    @Test("rename lands on the real store file over the WebSocket carrier and broadcasts the title")
    func renameOverWS() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let environment = ["OPENGROK_HOME": home.path, "HOME": home.path]
        try await seedSession(home: home, id: "ws-session", cwd: home)

        let gateway = ACPNotificationGateway()
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
            sessionAdmin: LiveSessionAdminACPHandler(openGrokHome: home, gateway: gateway)
        )
        let sessionStore = InMemoryACPSessionStore()
        let host = ACPServeHost(
            configuration: ACPServeConfiguration(
                host: "127.0.0.1",
                port: 0,
                secret: "admin-secret",
                keepAliveInterval: nil
            ),
            makeRuntime: {
                let runtime = ACPAgentRuntime(store: sessionStore, extensionRouter: router)
                await gateway.attach(runtime)
                return runtime
            }
        )
        let endpoint = try await host.start()
        let served = Task { await host.run() }
        defer {
            served.cancel()
            Task { await host.stop() }
        }

        let client = try await wsConnect(to: endpoint, secret: "admin-secret")
        try await client.send(.request(
            id: .number(1),
            method: AgentMethodNames.initialize,
            params: .object([
                "protocolVersion": .number(.int64(1)),
                "clientCapabilities": .object([:]),
            ])
        ))
        _ = try await wsDrain(client) { $0.id == .number(1) }

        try await client.send(.request(
            id: .number(2),
            method: "x.ai/session/rename",
            params: .object([
                "sessionId": .string("ws-session"),
                "title": .string("Renamed over ws"),
            ])
        ))
        // The broadcast and the response both ride the socket; drain to the
        // response and remember whether the notification passed by.
        var sawSummary = false
        let renamed = try await wsDrain(client) { message in
            if message.method == "x.ai/session_notification",
               message.params?["update"]?["sessionUpdate"]?.stringValue
                   == "session_summary_generated" {
                sawSummary = true
            }
            return message.id == .number(2)
        }
        guard case .response(_, let result?, nil) = renamed else {
            Issue.record("rename failed over ws: \(renamed)")
            return
        }
        #expect(result == .object(["success": .bool(true)]))
        #expect(sawSummary, "the SessionSummaryGenerated broadcast must ride the same socket")

        let record = try readRecord(home: home, id: "ws-session")
        #expect(record.title == "Renamed over ws")

        await client.close()
    }
}
