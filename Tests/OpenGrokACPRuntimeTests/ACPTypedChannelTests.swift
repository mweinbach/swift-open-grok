import Foundation
import OpenGrokACP
import OpenGrokShared
import Testing
@testable import OpenGrokACPRuntime

private actor ACPTypedPromptStartSignal {
    private var started = false
    private var waiter: CheckedContinuation<Void, Never>?

    func signal() {
        started = true
        let continuation = waiter
        waiter = nil
        continuation?.resume()
    }

    func wait() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            if started {
                continuation.resume()
            } else {
                waiter = continuation
            }
        }
    }
}

private struct ACPTypedBlockingPromptDriver: ACPPromptDriver {
    let started: ACPTypedPromptStartSignal

    func run(
        context: ACPPromptContext,
        emit: @escaping @Sendable (SessionNotification, ACPNotificationDisposition) async -> Void
    ) async throws -> PromptResponse {
        await started.signal()
        try await Task.sleep(for: .seconds(60))
        return PromptResponse(stopReason: .endTurn)
    }

    func cancel(sessionId: AcpSessionId) async {}
}

@Suite("ACP typed in-process channel parity")
struct ACPTypedChannelTests {
    @Test("reverse permission responses reach their JSON-RPC request broker", .timeLimit(.minutes(1)))
    func reversePermissionResponseCompletes() async throws {
        let runtime = ACPAgentRuntime()
        let (client, agent) = acpChannels()
        let serving = Task { await runtime.serve(agent) }
        defer {
            client.close()
            agent.close()
            serving.cancel()
        }

        guard case .success = await acpSendInitialize(
            InitializeRequest(protocolVersion: .v1),
            on: client
        ) else {
            Issue.record("typed channel failed to initialize")
            return
        }

        let permission = RequestPermissionRequest(
            sessionId: AcpSessionId("session-1"),
            toolCall: ToolCallUpdate(toolCallId: ToolCallId("tool-1")),
            options: [
                PermissionOption(
                    optionId: PermissionOptionId("allow-once"),
                    name: "Allow once",
                    kind: .allowOnce
                )
            ]
        )
        let waiting = Task {
            try await runtime.requestClient(
                method: ClientMethodNames.sessionRequestPermission,
                params: try JSONValue.encode(permission)
            )
        }

        var messages = client.messages.makeAsyncIterator()
        guard let message = await messages.next(),
              case .requestPermission(let args) = message else {
            Issue.record("client never received the typed permission request")
            return
        }
        #expect(args.request.sessionId == AcpSessionId("session-1"))
        #expect(args.respond(.success(RequestPermissionResponse(
            outcome: .selected(SelectedPermissionOutcome(optionId: PermissionOptionId("allow-once")))
        ))))

        let response = try await waiting.value
        let decoded = try response.decode(RequestPermissionResponse.self)
        #expect(decoded.outcome == .selected(
            SelectedPermissionOutcome(optionId: PermissionOptionId("allow-once"))
        ))
    }

    @Test("typed session/cancel interrupts a prompt already executing", .timeLimit(.minutes(1)))
    func typedCancellationInterruptsPrompt() async throws {
        let started = ACPTypedPromptStartSignal()
        let runtime = ACPAgentRuntime(
            promptDriver: ACPTypedBlockingPromptDriver(started: started),
            makeSessionId: { "session-1" }
        )
        let (client, agent) = acpChannels()
        let serving = Task { await runtime.serve(agent) }
        defer {
            client.close()
            agent.close()
            serving.cancel()
        }

        guard case .success = await acpSendInitialize(
            InitializeRequest(protocolVersion: .v1),
            on: client
        ) else {
            Issue.record("typed channel failed to initialize")
            return
        }

        let creation = AcpArgs(request: NewSessionRequest(cwd: "/tmp"))
        #expect(client.send(.newSession(creation)))
        guard case .success(let session) = await creation.response.awaitResponse() else {
            Issue.record("typed channel failed to create its session")
            return
        }

        let prompt = AcpArgs(request: PromptRequest(
            sessionId: session.sessionId,
            prompt: [.text("wait for cancellation")]
        ))
        #expect(client.send(.prompt(prompt)))
        await started.wait()

        let cancellation = AcpArgs(request: CancelNotification(sessionId: session.sessionId))
        #expect(client.send(.cancel(cancellation)))
        guard case .success = await cancellation.response.awaitResponse() else {
            Issue.record("typed channel never processed its cancellation")
            return
        }

        guard case .success(let response) = await prompt.response.awaitResponse() else {
            Issue.record("cancelled prompt did not receive a response")
            return
        }
        #expect(response.stopReason == .cancelled)
    }
}
