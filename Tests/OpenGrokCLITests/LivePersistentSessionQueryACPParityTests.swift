import Foundation
import OpenGrokACP
import OpenGrokHTTP
import OpenGrokSamplingTypes
import OpenGrokSessionPersistence
import OpenGrokShared
import OpenGrokShellSessionSupport
import OpenGrokTestSupport
import Testing

@testable import OpenGrokACPRuntime
@testable import OpenGrokCLI

private typealias JSONValue = OpenGrokShared.JSONValue

private actor PersistentQueryNotifications {
    private var messages: [ACPMessage] = []

    func append(_ message: ACPMessage) {
        messages.append(message)
    }

    func snapshot() -> [ACPMessage] {
        messages
    }
}

private struct PersistentQueryFixture {
    let home: URL
    let firstWorkspace: URL
    let secondWorkspace: URL
    let runtime: ACPAgentRuntime
    let notifications: PersistentQueryNotifications

    static func make(withGateway: Bool = true) async throws -> Self {
        let manager = FileManager.default
        let home = manager.temporaryDirectory.appendingPathComponent(
            "opengrok-acp-session-query-\(UUID().uuidString)",
            isDirectory: true
        )
        try manager.createDirectory(
            at: home,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let firstWorkspace = home.appendingPathComponent("first", isDirectory: true)
        let secondWorkspace = home.appendingPathComponent("second", isDirectory: true)
        try manager.createDirectory(at: firstWorkspace, withIntermediateDirectories: true)
        try manager.createDirectory(at: secondWorkspace, withIntermediateDirectories: true)
        let environment = ["HOME": home.path, "OPENGROK_HOME": home.path]
        let gateway = ACPNotificationGateway()
        let admin = withGateway ? LiveSessionAdminACPHandler(
            openGrokHome: home,
            gateway: gateway,
            liveSessionID: nil,
            sessionInfoSnapshot: nil,
            closeLive: nil
        ) : nil
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
            sessionAdmin: admin,
            persistentSessions: LivePersistentSessionACPHandler(openGrokHome: home)
        )
        let runtime = ACPAgentRuntime(extensionRouter: router)
        let notifications = PersistentQueryNotifications()
        await runtime.setNotificationSink { message in
            await notifications.append(message)
        }
        await gateway.attach(runtime)
        let initialized = await runtime.handle(.request(
            id: .string("initialize"),
            method: AgentMethodNames.initialize,
            params: try JSONValue.encode(InitializeRequest(protocolVersion: .v1))
        ))
        guard case .response(_, _, nil) = try #require(initialized.first) else {
            throw ACPTransportError.invalidMessage("persistent query ACP runtime failed to initialize")
        }
        return Self(
            home: home,
            firstWorkspace: firstWorkspace,
            secondWorkspace: secondWorkspace,
            runtime: runtime,
            notifications: notifications
        )
    }

    func seed(
        _ id: String,
        workspace: URL? = nil,
        title: String? = nil,
        content: String? = nil,
        age: TimeInterval = 0
    ) async throws {
        var record = LiveConversationRecord.new(
            sessionID: id,
            workingDirectory: workspace ?? firstWorkspace
        )
        record.title = title
        record.createdAt = Date(timeIntervalSince1970: 1_780_000_000 + age - 60)
        record.updatedAt = Date(timeIntervalSince1970: 1_780_000_000 + age)
        if let content { record.items = [.user(content)] }
        try await LiveConversationStore(openGrokHome: home).save(record)
    }

    func append(
        to id: String,
        workspace: URL? = nil,
        method: String = "session/update",
        tag: String,
        text: String? = nil,
        promptIndex: UInt64? = nil,
        hostTurn: Bool = false,
        rewindTo: UInt64? = nil,
        eventId: String? = nil
    ) throws {
        var update: [String: JSONValue] = ["sessionUpdate": .string(tag)]
        if let text {
            update["content"] = .object(["type": .string("text"), "text": .string(text)])
        }
        var metadata: [String: JSONValue] = [:]
        if let promptIndex { metadata["promptIndex"] = .number(.uint64(promptIndex)) }
        if hostTurn { metadata["hostTurn"] = .bool(true) }
        if !metadata.isEmpty { update["_meta"] = .object(metadata) }
        if let rewindTo { update["target_prompt_index"] = .number(.uint64(rewindTo)) }
        var params: [String: JSONValue] = [
            "sessionId": .string(id),
            "update": .object(update),
        ]
        if let eventId { params["_meta"] = .object(["eventId": .string(eventId)]) }
        let envelope = try SessionUpdateEnvelope(
            timestamp: 1_780_000_000,
            method: method,
            params: .object(params)
        )
        try SessionDocumentStore(grokHome: home).appendUpdate(
            envelope,
            sessionID: id,
            cwd: (workspace ?? firstWorkspace).path
        )
    }

    func call(
        _ method: String,
        params: JSONValue
    ) async throws -> (JSONValue?, AcpError?) {
        let output = await runtime.handle(.request(
            id: .string(UUID().uuidString),
            method: method,
            params: params
        ))
        guard case .response(_, let result, let error) = try #require(output.first) else {
            throw ACPTransportError.invalidMessage("persistent query ACP method returned no response")
        }
        return (result, error)
    }

    func updatesParams(_ id: String, workspace: URL? = nil) -> [String: JSONValue] {
        [
            "sessionId": .string(id),
            "cwd": .string((workspace ?? firstWorkspace).path),
        ]
    }

    func clean() {
        try? FileManager.default.removeItem(at: home)
    }
}

@Suite("ACP durable updates and full-content session search", .serialized)
struct LivePersistentSessionQueryACPParityTests {
    @Test("updates return raw persisted envelopes, prompt boundaries, and the last event ID")
    func updatesExposeCanonicalJournal() async throws {
        let fixture = try await PersistentQueryFixture.make()
        defer { fixture.clean() }
        try await fixture.seed("journal")
        try fixture.append(to: "journal", tag: "user_message_chunk", text: "first", promptIndex: 0)
        try fixture.append(to: "journal", tag: "agent_message_chunk", text: "response", eventId: "journal-2")

        let (response, error) = try await fixture.call(
            "x.ai/session/updates",
            params: .object(fixture.updatesParams("journal"))
        )
        #expect(error == nil)
        #expect(response?["result"] == nil)
        #expect(response?["totalCount"]?.uint64Value == 2)
        #expect(response?["hasMore"]?.boolValue == false)
        #expect(response?["promptStarts"] == .array([.number(.uint64(0))]))
        #expect(response?["lastEventId"]?.stringValue == "journal-2")
        #expect(response?["updates"]?[0]?["method"]?.stringValue == "session/update")
        #expect(response?["updates"]?[0]?["params"]?["update"]?["content"]?["text"]?.stringValue
            == "first")
    }

    @Test("rewind markers discard dead branches while host-turn chunks never create rewind targets")
    func rewindsPreserveOnlyLiveBranch() async throws {
        let fixture = try await PersistentQueryFixture.make()
        defer { fixture.clean() }
        try await fixture.seed("rewound")
        try fixture.append(to: "rewound", tag: "user_message_chunk", text: "keep", promptIndex: 0)
        try fixture.append(to: "rewound", tag: "agent_message_chunk", text: "keep answer")
        try fixture.append(to: "rewound", tag: "user_message_chunk", text: "hidden host", hostTurn: true)
        try fixture.append(to: "rewound", tag: "user_message_chunk", text: "discard", promptIndex: 1)
        try fixture.append(to: "rewound", tag: "agent_message_chunk", text: "discard answer")
        try fixture.append(
            to: "rewound",
            method: "_x.ai/session/update",
            tag: "rewind_marker",
            rewindTo: 1
        )
        try fixture.append(to: "rewound", tag: "user_message_chunk", text: "replacement", promptIndex: 1)
        try fixture.append(to: "rewound", tag: "agent_message_chunk", text: "live answer")

        let (response, error) = try await fixture.call(
            "x.ai/session/updates",
            params: .object(fixture.updatesParams("rewound"))
        )
        #expect(error == nil)
        let updates = try #require(response?["updates"]?.arrayValue)
        let text = updates.compactMap {
            $0["params"]?["update"]?["content"]?["text"]?.stringValue
        }
        #expect(text == ["keep", "keep answer", "hidden host", "replacement", "live answer"])
        #expect(!text.contains("discard"))
        #expect(response?["totalCount"]?.uint64Value == 5)
        #expect(response?["promptStarts"] == .array([
            .number(.uint64(0)),
            .number(.uint64(2)),
        ]))
    }

    @Test("positive and negative offsets and tail-by-turn pagination match upstream")
    func updatesPagination() async throws {
        let fixture = try await PersistentQueryFixture.make()
        defer { fixture.clean() }
        try await fixture.seed("pages")
        for turn in 0..<3 {
            try fixture.append(
                to: "pages", tag: "user_message_chunk", text: "prompt-\(turn)",
                promptIndex: UInt64(turn)
            )
            try fixture.append(to: "pages", tag: "agent_message_chunk", text: "answer-\(turn)")
        }

        var positive = fixture.updatesParams("pages")
        positive["offset"] = .number(.int64(2))
        positive["limit"] = .number(.uint64(2))
        let (first, firstError) = try await fixture.call("x.ai/session/updates", params: .object(positive))
        #expect(firstError == nil)
        #expect(first?["updates"]?.arrayValue?.count == 2)
        #expect(first?["hasMore"]?.boolValue == true)
        #expect(first?["updates"]?[0]?["params"]?["update"]?["content"]?["text"]?.stringValue
            == "prompt-1")

        var negative = fixture.updatesParams("pages")
        negative["offset"] = .number(.int64(-2))
        let (last, lastError) = try await fixture.call("x.ai/session/updates", params: .object(negative))
        #expect(lastError == nil)
        #expect(last?["hasMore"]?.boolValue == false)
        #expect(last?["updates"]?[0]?["params"]?["update"]?["content"]?["text"]?.stringValue
            == "prompt-2")

        var tail = fixture.updatesParams("pages")
        tail["turnIndex"] = .number(.uint64(2))
        let (turns, turnError) = try await fixture.call("x.ai/session/updates", params: .object(tail))
        #expect(turnError == nil)
        #expect(turns?["updates"]?.arrayValue?.count == 4)
        #expect(turns?["hasMore"]?.boolValue == true)
        #expect(turns?["promptStarts"] == .array([
            .number(.uint64(0)), .number(.uint64(2)), .number(.uint64(4)),
        ]))
    }

    @Test("streaming emits real bounded ACP chunk notifications and targets the requesting client")
    func updatesStreamThroughActualACPNotificationSink() async throws {
        let fixture = try await PersistentQueryFixture.make()
        defer { fixture.clean() }
        try await fixture.seed("stream")
        for index in 0..<3 {
            try fixture.append(
                to: "stream", tag: "agent_message_chunk", text: "chunk-\(index)",
                eventId: "stream-\(index)"
            )
        }
        var params = fixture.updatesParams("stream")
        params["stream"] = .bool(true)
        params["chunkSize"] = .number(.uint64(2))
        params["_meta"] = .object(["clientId": .object([
            "instanceId": .string("editor-A"),
            "connId": .string("connection-1"),
        ])])

        let (response, error) = try await fixture.call("x.ai/session/updates", params: .object(params))
        #expect(error == nil)
        #expect(response?["updates"] == nil)
        #expect(response?["chunkCount"]?.uint64Value == 2)
        #expect(response?["totalCount"]?.uint64Value == 3)
        #expect(response?["lastEventId"]?.stringValue == "stream-2")
        let messages = await fixture.notifications.snapshot()
        #expect(messages.count == 2)
        for (index, message) in messages.enumerated() {
            guard case .notification(let method, let notification) = message else {
                Issue.record("stream emitted a non-notification ACP message")
                continue
            }
            #expect(method == "x.ai/session/updates/chunk")
            #expect(notification["sessionId"]?.stringValue == "stream")
            #expect(notification["index"]?.uint64Value == UInt64(index))
            #expect(notification["done"]?.boolValue == (index == 1))
            #expect(notification["_meta"]?["targetClientId"]?["instanceId"]?.stringValue
                == "editor-A")
            #expect(notification["_meta"]?["targetClientId"]?["connId"]?.stringValue
                == "connection-1")
            #expect(notification["updates"]?.arrayValue?.count == (index == 0 ? 2 : 1))
        }
    }

    @Test("streaming fails closed when no session-owned ACP notification gateway exists")
    func updatesStreamingWithoutGatewayFailsClosed() async throws {
        let fixture = try await PersistentQueryFixture.make(withGateway: false)
        defer { fixture.clean() }
        try await fixture.seed("unattached")
        var params = fixture.updatesParams("unattached")
        params["stream"] = .bool(true)

        let (response, error) = try await fixture.call("x.ai/session/updates", params: .object(params))
        #expect(response == nil)
        #expect(error?.code == .invalidRequest)
        #expect(error?.data?.stringValue?.contains("gateway") == true)
    }

    @Test("update replay never crosses workspace boundaries or follows a symlinked journal")
    func updatesRejectWorkspaceAndJournalEscape() async throws {
        let fixture = try await PersistentQueryFixture.make()
        defer { fixture.clean() }
        try await fixture.seed("private", workspace: fixture.firstWorkspace)
        try fixture.append(to: "private", tag: "agent_message_chunk", text: "secret")

        let (wrongWorkspace, wrongError) = try await fixture.call(
            "x.ai/session/updates",
            params: .object(fixture.updatesParams("private", workspace: fixture.secondWorkspace))
        )
        #expect(wrongError == nil)
        #expect(wrongWorkspace?["updates"] == .array([]))

        #if !os(Windows)
        let store = SessionDocumentStore(grokHome: fixture.home)
        let journal = try store.sessionDirectory(sessionID: "private", cwd: fixture.firstWorkspace.path)
            .appendingPathComponent(SessionDocumentStore.updatesFileName)
        let outside = fixture.home.appendingPathComponent("stolen.jsonl")
        try Data("{\"secret\":true}\n".utf8).write(to: outside)
        try FileManager.default.removeItem(at: journal)
        try FileManager.default.createSymbolicLink(at: journal, withDestinationURL: outside)

        let (escaped, escapeError) = try await fixture.call(
            "x.ai/session/updates",
            params: .object(fixture.updatesParams("private"))
        )
        #expect(escaped == nil)
        #expect(escapeError?.code == .internalError)
        #endif
    }

    @Test("workspace casing follows the native filesystem without crossing session roots")
    func workspaceMatchingFollowsPlatformCaseSensitivity() async throws {
        let fixture = try await PersistentQueryFixture.make()
        defer { fixture.clean() }
        try await fixture.seed(
            "case-sensitive-workspace",
            workspace: fixture.firstWorkspace,
            title: "Case-preserving session",
            content: "platform-owned conversation"
        )
        try fixture.append(
            to: "case-sensitive-workspace",
            tag: "agent_message_chunk",
            text: "platform-owned conversation"
        )

        let alternateCasing = fixture.firstWorkspace.path.uppercased()
        #expect(alternateCasing != fixture.firstWorkspace.path)

        let (updates, updateError) = try await fixture.call(
            "x.ai/session/updates",
            params: .object([
                "sessionId": .string("case-sensitive-workspace"),
                "cwd": .string(alternateCasing),
            ])
        )
        let (search, searchError) = try await fixture.call(
            "x.ai/session/search",
            params: .object([
                "query": .string("platform-owned"),
                "cwd": .string(alternateCasing),
            ])
        )
        #expect(updateError == nil)
        #expect(searchError == nil)

        #if os(Windows)
        #expect(updates?["totalCount"]?.uint64Value == 1)
        #expect(search?["result"]?["results"]?[0]?["sessionId"]?.stringValue
            == "case-sensitive-workspace")
        #else
        #expect(updates?["updates"] == .array([]))
        #expect(search?["result"]?["results"] == .array([]))
        #endif
    }

    @Test("search ranks real transcript content and reports upstream camelCase fields")
    func searchRanksPersistedConversationContent() async throws {
        let fixture = try await PersistentQueryFixture.make()
        defer { fixture.clean() }
        try await fixture.seed("title-hit", title: "Nebula architecture", content: "unrelated", age: 0)
        try await fixture.seed("content-hit", title: "Other topic", content: "We deployed the nebula cluster", age: 10)
        try await fixture.seed("miss", title: "Another topic", content: "nothing relevant")

        let (response, error) = try await fixture.call(
            "x.ai/session/search",
            params: .object(["query": .string("nebula")])
        )
        #expect(error == nil)
        let payload = try #require(response?["result"])
        #expect(payload["totalEstimate"]?.uint64Value == 2)
        #expect(payload["nextOffset"] == .null)
        #expect(payload["bootstrapping"]?.boolValue == false)
        let hits = try #require(payload["results"]?.arrayValue)
        #expect(hits.map { $0["sessionId"]?.stringValue } == ["title-hit", "content-hit"])
        #expect(hits[0]["matchedFields"] == .array([.string("title")]))
        #expect(hits[1]["matchedFields"] == .array([.string("content")]))
        #expect(hits[0]["snippet"] == nil)
        #expect(hits[0]["cwd"]?.stringValue == fixture.firstWorkspace.path)
        #expect(hits[0]["updatedAt"]?.stringValue?.contains("T") == true)
        #expect((hits[0]["score"]?.doubleValue ?? 0) > (hits[1]["score"]?.doubleValue ?? 0))
    }

    @Test("search includes content snippets only when explicitly requested")
    func searchContentSnippetIsOptIn() async throws {
        let fixture = try await PersistentQueryFixture.make()
        defer { fixture.clean() }
        try await fixture.seed("snippet", title: "Other", content: "needle appears in a private transcript")

        let (response, error) = try await fixture.call(
            "x.ai/session/search",
            params: .object([
                "query": .string("needle"),
                "includeContent": .bool(true),
            ])
        )
        #expect(error == nil)
        #expect(response?["result"]?["results"]?[0]?["snippet"]?.stringValue?.contains("needle")
            == true)
    }

    @Test("workspace filtering and offset pagination report exact totals and next offsets")
    func searchWorkspaceAndPagination() async throws {
        let fixture = try await PersistentQueryFixture.make()
        defer { fixture.clean() }
        try await fixture.seed("first-old", title: "deploy service", content: "deploy", age: 0)
        try await fixture.seed("first-new", title: "deploy worker", content: "deploy", age: 10)
        try await fixture.seed(
            "second-secret", workspace: fixture.secondWorkspace,
            title: "deploy secret", content: "deploy", age: 20
        )

        var params: [String: JSONValue] = [
            "query": .string("deploy"),
            "cwd": .string(fixture.firstWorkspace.path),
            "limit": .number(.uint64(1)),
        ]
        let (first, firstError) = try await fixture.call("x.ai/session/search", params: .object(params))
        #expect(firstError == nil)
        #expect(first?["result"]?["results"]?[0]?["sessionId"]?.stringValue == "first-new")
        #expect(first?["result"]?["totalEstimate"]?.uint64Value == 2)
        #expect(first?["result"]?["nextOffset"]?.uint64Value == 1)

        params["offset"] = .number(.uint64(1))
        let (second, secondError) = try await fixture.call("x.ai/session/search", params: .object(params))
        #expect(secondError == nil)
        #expect(second?["result"]?["results"]?[0]?["sessionId"]?.stringValue == "first-old")
        #expect(second?["result"]?["nextOffset"] == .null)
    }

    @Test("session-id-shaped searches use Rust's dedicated ID match and matchedFields value")
    func searchFindsSessionIDsOutsideTranscriptIndex() async throws {
        let fixture = try await PersistentQueryFixture.make()
        defer { fixture.clean() }
        try await fixture.seed("deadbeef-1234", title: "Unrelated", content: "nothing indexed")

        let (response, error) = try await fixture.call(
            "x.ai/session/search",
            params: .object([
                "query": .string("DEADBEEF"),
                "includeContent": .bool(true),
            ])
        )
        #expect(error == nil)
        let hit = try #require(response?["result"]?["results"]?[0])
        #expect(hit["sessionId"]?.stringValue == "deadbeef-1234")
        #expect(hit["matchedFields"] == .array([.string("session_id")]))
        #expect(hit["snippet"] == nil)
    }

    @Test("malformed parameters, relative workspaces, and excessive offsets fail closed")
    func queryRequestsValidateUntrustedWireParameters() async throws {
        let fixture = try await PersistentQueryFixture.make()
        defer { fixture.clean() }
        let failures: [(String, JSONValue)] = [
            ("x.ai/session/updates", .object([:])),
            ("x.ai/session/updates", .object([
                "sessionId": .string("../../secret"),
                "cwd": .string(fixture.firstWorkspace.path),
            ])),
            ("x.ai/session/updates", .object([
                "sessionId": .string("safe"),
                "cwd": .string("relative"),
            ])),
            ("x.ai/session/updates", .object([
                "sessionId": .string("safe"),
                "cwd": .string(fixture.firstWorkspace.path),
                "_meta": .object(["clientId": .string("spoofed")]),
            ])),
            ("x.ai/session/search", .object([:])),
            ("x.ai/session/search", .object([
                "query": .string("anything"),
                "cwd": .string("relative"),
            ])),
            ("x.ai/session/search", .object([
                "query": .string("anything"),
                "offset": .number(.uint64(100_001)),
            ])),
            ("x.ai/session/search", .object([
                "query": .string("anything"),
                "limit": .number(.int64(-1)),
            ])),
        ]
        for (method, params) in failures {
            let (response, error) = try await fixture.call(method, params: params)
            #expect(response == nil, "\(method) accepted \(params)")
            #expect(error?.code == .invalidParams, "\(method) accepted \(params)")
        }
    }

    @Test("independent ACP homes never reveal another connection's searchable history")
    func searchHomesRemainIsolated() async throws {
        let first = try await PersistentQueryFixture.make()
        defer { first.clean() }
        let second = try await PersistentQueryFixture.make()
        defer { second.clean() }
        try await first.seed("private-first", title: "Top secret", content: "connection token")
        try await second.seed("private-second", title: "Top secret", content: "connection token")

        let (firstResponse, firstError) = try await first.call(
            "x.ai/session/search", params: .object(["query": .string("secret")])
        )
        let (secondResponse, secondError) = try await second.call(
            "x.ai/session/search", params: .object(["query": .string("secret")])
        )
        #expect(firstError == nil)
        #expect(secondError == nil)
        #expect(firstResponse?["result"]?["results"]?[0]?["sessionId"]?.stringValue
            == "private-first")
        #expect(secondResponse?["result"]?["results"]?[0]?["sessionId"]?.stringValue
            == "private-second")
    }
}
