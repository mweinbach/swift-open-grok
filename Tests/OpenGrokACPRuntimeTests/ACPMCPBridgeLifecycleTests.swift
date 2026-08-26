import Foundation
import OpenGrokACP
import OpenGrokShared
import Testing
@testable import OpenGrokACPRuntime

private actor ACPSDKLifecycleLog {
    struct Opened: Sendable, Equatable {
        var sessionID: String
        var metadata: AcpMeta?
    }

    private var opened: [Opened] = []
    private var closed: [String] = []

    func open(_ sessionID: AcpSessionId, metadata: AcpMeta?) {
        opened.append(Opened(sessionID: sessionID.rawValue, metadata: metadata))
    }

    func close(_ sessionID: AcpSessionId) {
        closed.append(sessionID.rawValue)
    }

    func openings() -> [Opened] { opened }
    func closures() -> [String] { closed }
}

enum ACPSDKAttachFailure: String, CaseIterable, Sendable {
    case openHook
    case storeUpdate
}

private actor ACPSDKAttachFault {
    private var failure: ACPSDKAttachFailure?

    init(_ failure: ACPSDKAttachFailure) {
        self.failure = failure
    }

    func check(_ stage: ACPSDKAttachFailure) throws {
        guard failure == stage else { return }
        failure = nil
        throw ACPRuntimeError.transport("fixture \(stage.rawValue) failed")
    }
}

private actor ACPSDKAttachStore: ACPSessionStore {
    private let storage: InMemoryACPSessionStore
    private let fault: ACPSDKAttachFault

    init(session: ACPSessionSnapshot, fault: ACPSDKAttachFault) {
        storage = InMemoryACPSessionStore(sessions: [session])
        self.fault = fault
    }

    func create(_ session: ACPSessionSnapshot) async throws {
        try await storage.create(session)
    }

    func read(_ sessionID: AcpSessionId) async throws -> ACPSessionSnapshot? {
        await storage.read(sessionID)
    }

    func update(_ session: ACPSessionSnapshot) async throws {
        try await fault.check(.storeUpdate)
        try await storage.update(session)
    }

    func list(cwd: String?) async throws -> [ACPSessionSnapshot] {
        await storage.list(cwd: cwd)
    }
}

@Suite("ACP client-provided MCP bridge lifecycle")
struct ACPMCPBridgeLifecycleTests {
    private func initialize(_ runtime: ACPAgentRuntime) async throws -> InitializeResponse {
        let output = await runtime.handle(.request(
            id: .number(1),
            method: AgentMethodNames.initialize,
            params: try JSONValue.encode(InitializeRequest(protocolVersion: .v1))
        ))
        guard case .response(_, let result?, nil)? = output.last else {
            throw ACPRuntimeError.transport("initialize did not produce a successful response")
        }
        return try result.decode(InitializeResponse.self)
    }

    private func requireSuccess(_ output: [ACPMessage]) throws {
        guard case .response(_, _?, nil)? = output.last else {
            throw ACPRuntimeError.transport("expected a successful ACP response: \(output)")
        }
    }

    private func metadataFreeAttachParams(method: String, sessionID: AcpSessionId) throws -> JSONValue {
        let cwd = FileManager.default.temporaryDirectory.path
        if method == AgentMethodNames.sessionLoad {
            return try JSONValue.encode(LoadSessionRequest(sessionId: sessionID, cwd: cwd))
        }
        return try JSONValue.encode(ResumeSessionRequest(sessionId: sessionID, cwd: cwd))
    }

    @Test("SDK capability is truthful and preserves unrelated initialize metadata")
    func capabilityRequiresHookAndConnectedReverseSender() async throws {
        let configuration = ACPAgentConfiguration(meta: [
            "preserved": .string("present"),
            "x.ai/mcp/sdk": .bool(true),
        ])

        let noHook = ACPAgentRuntime(configuration: configuration)
        await noHook.setReverseSender { _ in }
        let noHookResponse = try await initialize(noHook)
        #expect(noHookResponse.meta?["preserved"] == .string("present"))
        #expect(noHookResponse.meta?["x.ai/mcp/sdk"] == nil)

        let noSender = ACPAgentRuntime(
            configuration: configuration,
            onSessionOpened: { _, _ in }
        )
        let noSenderResponse = try await initialize(noSender)
        #expect(noSenderResponse.meta?["preserved"] == .string("present"))
        #expect(noSenderResponse.meta?["x.ai/mcp/sdk"] == nil)

        let connected = ACPAgentRuntime(
            configuration: configuration,
            onSessionOpened: { _, _ in }
        )
        await connected.setReverseSender { _ in }
        let connectedResponse = try await initialize(connected)
        #expect(connectedResponse.meta?["preserved"] == .string("present"))
        #expect(connectedResponse.meta?["x.ai/mcp/sdk"] == .bool(true))
    }

    @Test("session metadata reaches the scoped bridge and close tears it down exactly once")
    func sessionOpenAndCloseCallbacks() async throws {
        let log = ACPSDKLifecycleLog()
        let runtime = ACPAgentRuntime(
            onSessionOpened: { sessionID, metadata in
                await log.open(sessionID, metadata: metadata)
            },
            onSessionClosed: { sessionID in
                await log.close(sessionID)
            },
            makeSessionId: { "session-sdk" }
        )
        await runtime.setReverseSender { _ in }
        let initializeResponse = try await initialize(runtime)
        #expect(initializeResponse.meta?["x.ai/mcp/sdk"] == .bool(true))

        let metadata: AcpMeta = [
            "x.ai/mcp/servers": .array([
                .object(["name": .string("tools"), "serverId": .string("srv_0")]),
            ]),
        ]
        let opened = await runtime.handle(.request(
            id: .number(2),
            method: AgentMethodNames.sessionNew,
            params: try JSONValue.encode(NewSessionRequest(cwd: "/tmp", meta: metadata))
        ))
        guard case .response(_, let value?, nil)? = opened.last else {
            Issue.record("session/new did not succeed")
            return
        }
        let session = try value.decode(NewSessionResponse.self)
        #expect(session.sessionId.rawValue == "session-sdk")
        #expect(await log.openings() == [
            ACPSDKLifecycleLog.Opened(sessionID: "session-sdk", metadata: metadata),
        ])

        let closeResponse = await runtime.handle(.request(
            id: .number(3),
            method: AgentMethodNames.sessionClose,
            params: try JSONValue.encode(CloseSessionRequest(sessionId: session.sessionId))
        ))
        guard case .response(_, .some, nil)? = closeResponse.last else {
            Issue.record("session/close did not succeed")
            return
        }
        #expect(await log.closures() == ["session-sdk"])

        await runtime.close()
        #expect(await log.closures() == ["session-sdk"])
    }

    @Test("failed bridge initialization leaves no persisted or authorized session")
    func failedOpenRollsBackSessionCreation() async throws {
        let log = ACPSDKLifecycleLog()
        let store = InMemoryACPSessionStore()
        let runtime = ACPAgentRuntime(
            store: store,
            onSessionOpened: { sessionID, metadata in
                await log.open(sessionID, metadata: metadata)
                throw ACPRuntimeError.transport("client rejected MCP server")
            },
            onSessionClosed: { sessionID in
                await log.close(sessionID)
            },
            makeSessionId: { "rejected-session" }
        )
        await runtime.setReverseSender { _ in }
        let response = try await initialize(runtime)
        #expect(response.meta?["x.ai/mcp/sdk"] == .bool(true))

        let opened = await runtime.handle(.request(
            id: .number(2),
            method: AgentMethodNames.sessionNew,
            params: try JSONValue.encode(NewSessionRequest(cwd: "/tmp"))
        ))
        guard case .response(_, nil, let failure?)? = opened.last else {
            Issue.record("rejected bridge unexpectedly created a session")
            return
        }
        #expect(failure.message.contains("client rejected MCP server"))
        #expect(try await store.list(cwd: nil).isEmpty)
        #expect(await log.closures() == ["rejected-session"])
    }

    @Test(
        "metadata-free load and resume restore cold or closed lifecycle without reopening an active bridge",
        arguments: [AgentMethodNames.sessionLoad, AgentMethodNames.sessionResume], [false, true]
    )
    func metadataFreeAttachRestoresLifecycle(method: String, closeExisting: Bool) async throws {
        let sessionID = AcpSessionId("metadata-free-session")
        let log = ACPSDKLifecycleLog()
        let store = InMemoryACPSessionStore()
        let gateway = ACPNotificationGateway()
        let runtime = ACPAgentRuntime(
            store: store,
            onSessionOpened: { sessionID, metadata in
                await log.open(sessionID, metadata: metadata)
            },
            onSessionClosed: { sessionID in
                await log.close(sessionID)
            },
            makeSessionId: { sessionID.rawValue }
        )
        await gateway.attach(runtime)
        await runtime.setReverseSender { _ in }
        let response = try await initialize(runtime)
        #expect(response.meta?["x.ai/mcp/sdk"] == .bool(true))

        if closeExisting {
            try requireSuccess(await runtime.handle(.request(
                id: .number(2),
                method: AgentMethodNames.sessionNew,
                params: try JSONValue.encode(NewSessionRequest(cwd: FileManager.default.temporaryDirectory.path))
            )))
            #expect(await gateway.ownsSession(sessionID))
            try requireSuccess(await runtime.handle(.request(
                id: .number(3),
                method: AgentMethodNames.sessionClose,
                params: try JSONValue.encode(CloseSessionRequest(sessionId: sessionID))
            )))
        } else {
            // A new serve connection can inherit an open stored snapshot without
            // any local lifecycle. Its persisted closed flag is not sufficient.
            try await store.create(ACPSessionSnapshot(
                sessionId: sessionID,
                cwd: FileManager.default.temporaryDirectory.path,
                createdAt: "created",
                updatedAt: "updated"
            ))
        }
        #expect(await gateway.ownsSession(sessionID) == false)

        let params = try metadataFreeAttachParams(method: method, sessionID: sessionID)
        #expect(params["_meta"] == nil)
        try requireSuccess(await runtime.handle(.request(id: .number(4), method: method, params: params)))
        #expect(await gateway.ownsSession(sessionID))
        #expect(await gateway.ownsConnectedSession(sessionID))
        #expect(await store.read(sessionID)?.closed == false)
        let openings = Array(
            repeating: ACPSDKLifecycleLog.Opened(sessionID: sessionID.rawValue, metadata: nil),
            count: closeExisting ? 2 : 1
        )
        #expect(await log.openings() == openings)

        try requireSuccess(await runtime.handle(.request(id: .number(5), method: method, params: params)))
        #expect(await log.openings() == openings)
        #expect(await gateway.ownsSession(sessionID))
        await runtime.close()
        #expect(await log.closures() == Array(repeating: sessionID.rawValue, count: closeExisting ? 2 : 1))
    }

    @Test(
        "failed metadata-free attach tears down the new lifecycle and permits a clean retry",
        arguments: [AgentMethodNames.sessionLoad, AgentMethodNames.sessionResume], ACPSDKAttachFailure.allCases
    )
    func metadataFreeAttachFailureRollsBackLifecycle(method: String, failure: ACPSDKAttachFailure) async throws {
        let sessionID = AcpSessionId("failed-metadata-free-session")
        let original = ACPSessionSnapshot(
            sessionId: sessionID,
            cwd: FileManager.default.temporaryDirectory.path,
            closed: true,
            createdAt: "created",
            updatedAt: "updated"
        )
        let fault = ACPSDKAttachFault(failure)
        let store = ACPSDKAttachStore(session: original, fault: fault)
        let log = ACPSDKLifecycleLog()
        let runtime = ACPAgentRuntime(
            store: store,
            onSessionOpened: { sessionID, metadata in
                await log.open(sessionID, metadata: metadata)
                try await fault.check(.openHook)
            },
            onSessionClosed: { sessionID in
                await log.close(sessionID)
            }
        )
        let initialized = try await initialize(runtime)
        #expect(initialized.protocolVersion == .v1)
        let params = try metadataFreeAttachParams(method: method, sessionID: sessionID)
        #expect(params["_meta"] == nil)
        let rejected = await runtime.handle(.request(id: .number(2), method: method, params: params))
        guard case .response(_, nil, let error?)? = rejected.last else {
            Issue.record("the failing lifecycle unexpectedly attached: \(rejected)")
            await runtime.close()
            return
        }
        #expect(error.message.contains("fixture \(failure.rawValue) failed"))
        #expect(try await store.read(sessionID) == original)
        #expect(await runtime.ownsSession(sessionID) == false)
        #expect(await log.closures() == [sessionID.rawValue])

        try requireSuccess(await runtime.handle(.request(id: .number(3), method: method, params: params)))
        #expect(await runtime.ownsSession(sessionID))
        #expect(try await store.read(sessionID)?.closed == false)
        #expect(await log.openings() == Array(
            repeating: ACPSDKLifecycleLog.Opened(sessionID: sessionID.rawValue, metadata: nil), count: 2
        ))
        await runtime.close()
        #expect(await log.closures() == [sessionID.rawValue, sessionID.rawValue])
    }

    @Test("runtime teardown closes every active bridge session")
    func runtimeCloseCleansUpSessions() async throws {
        let log = ACPSDKLifecycleLog()
        let runtime = ACPAgentRuntime(
            onSessionOpened: { sessionID, metadata in
                await log.open(sessionID, metadata: metadata)
            },
            onSessionClosed: { sessionID in
                await log.close(sessionID)
            },
            makeSessionId: { "active-session" }
        )
        await runtime.setReverseSender { _ in }
        let response = try await initialize(runtime)
        #expect(response.meta?["x.ai/mcp/sdk"] == .bool(true))
        let opened = await runtime.handle(.request(
            id: .number(2),
            method: AgentMethodNames.sessionNew,
            params: try JSONValue.encode(NewSessionRequest(cwd: "/tmp"))
        ))
        guard case .response(_, .some, nil)? = opened.last else {
            Issue.record("session creation did not succeed")
            return
        }

        await runtime.close()
        #expect(await log.closures() == ["active-session"])
    }

    @Test("gateway fails closed until an actual runtime and reverse sender exist")
    func gatewayReverseRequester() async throws {
        let gateway = ACPNotificationGateway()
        #expect(await gateway.hasConnectedRuntime() == false)

        do {
            let response = try await gateway.requestClient(method: "x.ai/mcp/sdk_call", params: .object([:]))
            Issue.record("unattached gateway unexpectedly returned \(response)")
        } catch let error as ACPRuntimeError {
            #expect(error == .transport("no ACP runtime is attached"))
        }

        let runtime = ACPAgentRuntime()
        await gateway.attach(runtime)
        #expect(await gateway.hasConnectedRuntime() == false)
        await runtime.setReverseSender { [weak runtime] message in
            guard let runtime else {
                throw ACPRuntimeError.transport("test runtime disappeared")
            }
            guard case .request(let id, let method, let params) = message else {
                throw ACPRuntimeError.invalidParams("expected reverse request")
            }
            guard method == "x.ai/mcp/sdk_call",
                  params["serverId"] == .string("srv_0"),
                  params["sessionId"] == nil else {
                throw ACPRuntimeError.invalidParams("unexpected reverse MCP wire envelope")
            }
            let handled = await runtime.handle(.response(
                id: id,
                result: .object(["accepted": .bool(true)]),
                error: nil
            ))
            guard handled.isEmpty else {
                throw ACPRuntimeError.transport("reverse response unexpectedly generated output")
            }
        }
        #expect(await gateway.hasConnectedRuntime() == true)

        let result = try await gateway.requestClient(
            method: "x.ai/mcp/sdk_call",
            params: .object(["serverId": .string("srv_0"), "message": .object([:])])
        )
        #expect(result == .object(["accepted": .bool(true)]))
    }

    @Test("bound reverse requesters never follow a gateway to another connected client")
    func boundRequesterRejectsCrossClientRetargeting() async throws {
        let gateway = ACPNotificationGateway()
        let original = ACPAgentRuntime()
        await original.setReverseSender { [weak original] message in
            guard let original,
                  case .request(let id, _, _) = message else {
                throw ACPRuntimeError.transport("original client disconnected")
            }
            let handled = await original.handle(.response(
                id: id,
                result: .string("original-client"),
                error: nil
            ))
            guard handled.isEmpty else {
                throw ACPRuntimeError.transport("original client emitted an unexpected response")
            }
        }
        await gateway.attach(original)
        let requester = try await gateway.connectedReverseRequester()

        let replacement = ACPAgentRuntime()
        await replacement.setReverseSender { [weak replacement] message in
            guard let replacement,
                  case .request(let id, _, _) = message else {
                throw ACPRuntimeError.transport("replacement client disconnected")
            }
            let handled = await replacement.handle(.response(
                id: id,
                result: .string("replacement-client"),
                error: nil
            ))
            guard handled.isEmpty else {
                throw ACPRuntimeError.transport("replacement client emitted an unexpected response")
            }
        }
        await gateway.attach(replacement)

        let payload: JSONValue = .object([
            "serverId": .string("srv_0"),
            "message": .object(["id": .number(.int64(1))]),
        ])
        let ownedResult = try await requester("x.ai/mcp/sdk_call", payload)
        #expect(ownedResult == .string("original-client"))

        let replacementResult = try await gateway.requestClient(
            method: "x.ai/mcp/sdk_call",
            params: payload
        )
        #expect(replacementResult == .string("replacement-client"))

        await original.close()
        do {
            let result = try await requester("x.ai/mcp/sdk_call", payload)
            Issue.record("disconnected original client unexpectedly returned \(result)")
        } catch let error as ACPRuntimeError {
            #expect(error == .transport("the owning ACP client has disconnected"))
        }
    }
}
