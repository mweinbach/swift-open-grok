import Foundation
import Testing
import OpenGrokACP
@testable import OpenGrokACPRuntime
import OpenGrokShared

@Suite("ACP message and transport behavior")
struct ACPMessageTests {
    @Test("JSON-RPC requests and notifications preserve ids and wrapped methods")
    func messageRoundTrip() throws {
        let request = ACPMessage.request(
            id: .string("7"),
            method: AgentMethodNames.sessionPrompt,
            params: .object(["sessionId": .string("s1")])
        )
        let decoded = try ACPMessage(data: request.encodedData())
        #expect(decoded == request)

        let notification = ACPMessage.notification(method: "_x.ai/session/update", params: .object([
            "method": .string(ClientMethodNames.sessionUpdate),
            "params": .object([:])
        ]))
        let route = ACPMethodRoute.normalize(method: notification.method!, params: notification.params!)
        #expect(route.wasWrapped)
        #expect(route.method == ClientMethodNames.sessionUpdate)
    }

    @Test("in-process transport closes pending receives deterministically")
    func inProcessTransport() async throws {
        let pair = InProcessACPTransport.makePair()
        let message = ACPMessage.notification(method: "test", params: .object([:]))
        try await pair.client.send(message)
        #expect(try await pair.agent.receive() == message)
        await pair.client.close()
        do {
            _ = try await pair.agent.receive()
            Issue.record("expected closed transport")
        } catch let error as ACPTransportError {
            #expect(error == .closed)
        }
    }

    @Test("stdio transport rejects blank JSON-RPC lines")
    func blankStdioLine() async throws {
        let io = ClosureACPLineIO(
            readLine: { "   " },
            writeLine: { _ in }
        )
        do {
            _ = try await ACPStdioTransport(io: io).receive()
            Issue.record("expected blank line failure")
        } catch let error as ACPTransportError {
            #expect(error == .invalidLine)
        }
    }
}

@Suite("ACP runtime lifecycle and protocol errors")
struct ACPRuntimeTests {
    private struct BlockingPromptDriver: ACPPromptDriver {
        func run(
            context: ACPPromptContext,
            emit: @escaping @Sendable (SessionNotification, ACPNotificationDisposition) async -> Void
        ) async throws -> PromptResponse {
            try await Task.sleep(for: .seconds(60))
            return PromptResponse(stopReason: .endTurn)
        }

        func cancel(sessionId: AcpSessionId) async {}
    }

    @Test("initialize, session creation, prompt, and mode routing are deterministic")
    func lifecycle() async throws {
        let mode = SessionModeState(
            currentModeId: SessionModeId("default"),
            availableModes: [SessionMode(id: SessionModeId("default"), name: "Default")]
        )
        let runtime = ACPAgentRuntime(
            configuration: ACPAgentConfiguration(modes: mode),
            makeSessionId: { "session-1" },
            timestamp: { "fixed-time" }
        )
        let initialize = ACPMessage.request(
            id: .number(1),
            method: AgentMethodNames.initialize,
            params: try JSONValue.encode(InitializeRequest(protocolVersion: .v1))
        )
        let initOutput = await runtime.handle(initialize)
        guard case .response(_, let result, nil) = initOutput[0], let result else {
            Issue.record("expected initialize result")
            return
        }
        let initializeResponse = try result.decode(InitializeResponse.self)
        #expect(initializeResponse.protocolVersion == ProtocolVersion.v1)

        let newOutput = await runtime.handle(.request(
            id: .number(2),
            method: AgentMethodNames.sessionNew,
            params: try JSONValue.encode(NewSessionRequest(cwd: "/tmp"))
        ))
        guard case .response(_, let sessionJSON, nil) = newOutput.last, let sessionJSON else {
            Issue.record("expected session result")
            return
        }
        let session = try sessionJSON.decode(NewSessionResponse.self)
        #expect(session.sessionId.rawValue == "session-1")

        let promptOutput = await runtime.handle(.request(
            id: .number(3),
            method: AgentMethodNames.sessionPrompt,
            params: try JSONValue.encode(PromptRequest(
                sessionId: session.sessionId,
                prompt: [.text("hello")],
                messageId: "prompt-1"
            ))
        ))
        guard case .response(_, let promptJSON, nil) = promptOutput.last, let promptJSON else {
            Issue.record("expected prompt result")
            return
        }
        let promptResponse = try promptJSON.decode(PromptResponse.self)
        #expect(promptResponse.stopReason == .endTurn)

        let modeOutput = await runtime.handle(.request(
            id: .number(4),
            method: AgentMethodNames.sessionSetModeCamel,
            params: try JSONValue.encode(SetSessionModeRequest(
                sessionId: session.sessionId,
                modeId: SessionModeId("default")
            ))
        ))
        #expect(modeOutput.last?.id == .number(4))
        #expect(await runtime.pollNotifications().contains {
            $0.method == ClientMethodNames.sessionUpdate
        })
    }

    @Test("auth and protocol errors map to stable ACP codes")
    func deterministicErrors() async throws {
        let runtime = ACPAgentRuntime(configuration: ACPAgentConfiguration(requireAuthentication: true))
        let badInit = await runtime.handle(.request(
            id: .number(1),
            method: AgentMethodNames.initialize,
            params: try JSONValue.encode(InitializeRequest(protocolVersion: ProtocolVersion(2)))
        ))
        guard case .response(_, nil, let error) = badInit[0] else {
            Issue.record("expected protocol error")
            return
        }
        #expect(error?.code == .invalidRequest)

        _ = await runtime.handle(.request(
            id: .number(2),
            method: AgentMethodNames.initialize,
            params: try JSONValue.encode(InitializeRequest(protocolVersion: .v1))
        ))
        let unauthenticated = await runtime.handle(.request(
            id: .number(3),
            method: AgentMethodNames.sessionNew,
            params: try JSONValue.encode(NewSessionRequest(cwd: "/tmp"))
        ))
        guard case .response(_, nil, let authError) = unauthenticated[0] else {
            Issue.record("expected auth error")
            return
        }
        #expect(authError?.code == .authRequired)
    }

    @Test("reusing a request id produces a deterministic protocol error")
    func duplicateRequestID() async throws {
        let runtime = ACPAgentRuntime()
        let request = ACPMessage.request(
            id: .number(1),
            method: AgentMethodNames.initialize,
            params: try JSONValue.encode(InitializeRequest(protocolVersion: .v1))
        )
        _ = await runtime.handle(request)
        let duplicate = await runtime.handle(request)
        guard case .response(_, nil, let error) = duplicate[0] else {
            Issue.record("expected duplicate request error")
            return
        }
        #expect(error?.code == .internalError)
        #expect(error?.message == "duplicate request id: 1")
    }

    @Test("session cancel stops an in-flight prompt and returns cancelled")
    func cancellation() async throws {
        let runtime = ACPAgentRuntime(promptDriver: BlockingPromptDriver(), makeSessionId: { "session-1" })
        _ = await runtime.handle(.request(
            id: .number(1),
            method: AgentMethodNames.initialize,
            params: try JSONValue.encode(InitializeRequest(protocolVersion: .v1))
        ))
        let sessionOutput = await runtime.handle(.request(
            id: .number(2),
            method: AgentMethodNames.sessionNew,
            params: try JSONValue.encode(NewSessionRequest(cwd: "/tmp"))
        ))
        guard case .response(_, let sessionJSON, nil) = sessionOutput.last,
              let sessionJSON else {
            Issue.record("expected session result")
            return
        }
        let session = try sessionJSON.decode(NewSessionResponse.self)
        let promptTask = Task {
            await runtime.handle(.request(
                id: .number(3),
                method: AgentMethodNames.sessionPrompt,
                params: try JSONValue.encode(PromptRequest(
                    sessionId: session.sessionId,
                    prompt: [.text("wait")]
                ))
            ))
        }
        try await Task.sleep(for: .milliseconds(10))
        _ = await runtime.handle(.request(
            id: .number(4),
            method: AgentMethodNames.sessionCancel,
            params: try JSONValue.encode(CancelNotification(sessionId: session.sessionId))
        ))
        let promptOutput = try await promptTask.value
        guard case .response(_, let promptJSON, nil) = promptOutput.last,
              let promptJSON else {
            Issue.record("expected cancelled prompt result")
            return
        }
        let promptResponse = try promptJSON.decode(PromptResponse.self)
        #expect(promptResponse.stopReason == .cancelled)
    }
}

@Suite("ACP reverse requests and leader routing")
struct ACPRoutingTests {
    @Test("reverse request correlation completes once")
    func reverseRequest() async throws {
        let broker = ACPReverseRequestBroker()
        let waiter = Task {
            try await broker.request(method: "session/request_permission", params: .object([:])) { message in
                guard case .request(let id, _, _) = message else { return }
                _ = await broker.resolve(.response(
                    id: id,
                    result: .object(["ok": .bool(true)]),
                    error: nil
                ))
            }
        }
        #expect(try await waiter.value == .object(["ok": .bool(true)]))
        #expect(await broker.pendingCount() == 0)
    }

    @Test("leader router broadcasts updates and keeps one driver")
    func leaderRouter() async throws {
        let router = ACPLeaderRouter()
        try await router.register(clientID: "b") { _ in }
        try await router.register(clientID: "a") { _ in }
        try await router.claim(sessionID: AcpSessionId("s"), clientID: "b", role: .driver)
        try await router.claim(sessionID: AcpSessionId("s"), clientID: "a", role: .subscriber)
        let message = ACPMessage.notification(
            method: ClientMethodNames.sessionUpdate,
            params: .object(["sessionId": .string("s")])
        )
        #expect(await router.recipients(for: message, from: "b") == ["a", "b"])
        let prompt = ACPMessage.request(
            id: .number(1),
            method: AgentMethodNames.sessionPrompt,
            params: .object(["sessionId": .string("s")])
        )
        #expect(await router.recipients(for: prompt, from: "a") == ["b"])
    }
}
