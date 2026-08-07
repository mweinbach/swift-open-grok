// Live-seam coverage: extension methods registered through
// `ACPExtensionMethodRouter` round-trip over the stdio ACP host the same way
// the live composition wires them (`LiveComposition.swift`).

import Foundation
import OpenGrokACP
import OpenGrokACPRuntime
import OpenGrokCLIChatProxyTypes
import OpenGrokShared
import OpenGrokShellSessionSupport
import Testing

@testable import OpenGrokCLI

private final class RecordingFeedbackStore: LiveFeedbackStore, @unchecked Sendable {
    private let lock = NSLock()
    private var submissions: [FeedbackSubmission] = []

    func persist(_ submission: FeedbackSubmission) async throws {
        record(submission)
    }

    private func record(_ submission: FeedbackSubmission) {
        lock.lock()
        submissions.append(submission)
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return submissions.count
    }
}

private final class StdioPipeHarness: @unchecked Sendable {
    let agentIO: ACPStandardIO
    let clientTransport: ACPStdioTransport
    private let descriptors: [Int32]

    init() throws {
        var toAgent: [Int32] = [0, 0]
        var fromAgent: [Int32] = [0, 0]
        guard pipe(&toAgent) == 0, pipe(&fromAgent) == 0 else {
            throw ACPTransportError.closed
        }
        descriptors = [toAgent[0], toAgent[1], fromAgent[0], fromAgent[1]]
        agentIO = ACPStandardIO(input: toAgent[0], output: fromAgent[1])
        clientTransport = ACPStdioTransport(
            io: ACPStandardIO(input: fromAgent[0], output: toAgent[1])
        )
    }

    func dispose() {
        for descriptor in descriptors { close(descriptor) }
    }
}

private struct NoopPromptDriver: ACPPromptDriver {
    func run(
        context: ACPPromptContext,
        emit: @escaping @Sendable (SessionNotification, ACPNotificationDisposition) async -> Void
    ) async throws -> PromptResponse {
        PromptResponse(stopReason: .endTurn)
    }

    func cancel(sessionId: AcpSessionId) async {}
}

@Suite("ACP extension methods over stdio")
struct ACPExtensionMethodStdioTests {
    @Test("x.ai/feedback round-trips through the stdio host")
    func feedbackRoundTrip() async throws {
        let store = RecordingFeedbackStore()
        let composition = LiveFeedbackComposition(
            sessionID: "stdio-feedback",
            boundary: ExportBoundary(),
            feedbackEnabled: false,
            store: store,
            client: nil
        )
        let router = ACPExtensionMethodRouter()
            .register(
                exact: LiveFeedbackACPHandler.method,
                handler: LiveFeedbackACPHandler(composition: composition)
            )

        let harness = try StdioPipeHarness()
        defer { harness.dispose() }
        let runtime = ACPAgentRuntime(
            promptDriver: NoopPromptDriver(),
            extensionRouter: router
        )
        let host = ACPStdioHost(
            runtime: runtime,
            transport: ACPStdioTransport(io: harness.agentIO)
        )
        let served = Task { await host.run() }
        defer { served.cancel() }

        try await harness.clientTransport.send(.request(
            id: .number(1),
            method: AgentMethodNames.initialize,
            params: .object(["protocolVersion": .number(.int64(1))])
        ))
        _ = try await harness.clientTransport.receive()

        var submission = FeedbackSubmission.withContent(
            sessionId: "",
            clientType: .tui,
            content: .text("stdio feedback")
        )
        submission.authorName = "Tester"
        let params = try JSONValue.encode(submission)

        try await harness.clientTransport.send(.request(
            id: .number(2),
            method: LiveFeedbackACPHandler.method,
            params: params
        ))
        let response = try await harness.clientTransport.receive()
        guard case .response(.number(2), let result, nil) = response, let result else {
            Issue.record("expected feedback response, got \(response)")
            return
        }
        #expect(result["status"]?.stringValue == "persisted_local_only")
        #expect(result["persisted"]?.boolValue == true)
        #expect(result["uploaded"]?.boolValue == false)
        #expect(store.count == 1)

        await host.shutdown()
    }

    @Test("unregistered extension methods return methodNotFound over stdio")
    func unknownExtensionMethod() async throws {
        let router = ACPExtensionMethodRouter()
            .register(
                exact: LiveFeedbackACPHandler.method,
                handler: LiveFeedbackACPHandler(
                    composition: LiveFeedbackComposition(
                        sessionID: "unused",
                        boundary: ExportBoundary(),
                        feedbackEnabled: false,
                        store: RecordingFeedbackStore(),
                        client: nil
                    )
                )
            )

        let harness = try StdioPipeHarness()
        defer { harness.dispose() }
        let runtime = ACPAgentRuntime(
            promptDriver: NoopPromptDriver(),
            extensionRouter: router
        )
        let host = ACPStdioHost(
            runtime: runtime,
            transport: ACPStdioTransport(io: harness.agentIO)
        )
        let served = Task { await host.run() }
        defer { served.cancel() }

        try await harness.clientTransport.send(.request(
            id: .number(1),
            method: AgentMethodNames.initialize,
            params: .object(["protocolVersion": .number(.int64(1))])
        ))
        _ = try await harness.clientTransport.receive()

        try await harness.clientTransport.send(.request(
            id: .number(2),
            method: "x.ai/mcp/list",
            params: .object([:])
        ))
        let response = try await harness.clientTransport.receive()
        guard case .response(.number(2), nil, let error) = response else {
            Issue.record("expected error response, got \(response)")
            return
        }
        #expect(error?.code == .methodNotFound)
        #expect(error?.message == "Method not found: x.ai/mcp/list")

        await host.shutdown()
    }
}
