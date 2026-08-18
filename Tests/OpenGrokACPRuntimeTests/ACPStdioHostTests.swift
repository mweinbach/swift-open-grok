// ACPStdioHostTests.swift
//
// End-to-end coverage for `agent stdio`: a real `ACPAgentRuntime` served over
// real file descriptors, driven by a client that speaks the same
// newline-delimited JSON-RPC framing. The two ends are joined by `pipe(2)`, so
// `ACPStandardIO`'s reader thread, line splitting and writer are all exercised
// rather than stubbed.

import Foundation
import OpenGrokACP
import OpenGrokShared
import Testing

@testable import OpenGrokACPRuntime

// MARK: - Harness

/// A bidirectional pipe pair wired as agent-stdio and a client facing it.
private final class StdioPipeHarness: @unchecked Sendable {
    let agentIO: ACPStandardIO
    let clientTransport: ACPStdioTransport
    private let toAgent: Pipe
    private let fromAgent: Pipe

    init() throws {
        let toAgent = Pipe()
        let fromAgent = Pipe()
        self.toAgent = toAgent
        self.fromAgent = fromAgent
        agentIO = ACPStandardIO(
            input: toAgent.fileHandleForReading,
            output: fromAgent.fileHandleForWriting
        )
        clientTransport = ACPStdioTransport(
            io: ACPStandardIO(
                input: fromAgent.fileHandleForReading,
                output: toAgent.fileHandleForWriting
            )
        )
    }

    /// Close the agent's stdin write end so the agent sees EOF.
    func closeAgentInput() { try? toAgent.fileHandleForWriting.close() }

    /// Push raw bytes at the agent's stdin, bypassing `ACPStdioTransport`, so
    /// a test can spell out exactly what lands on the wire.
    func writeRaw(_ text: String) {
        try? toAgent.fileHandleForWriting.write(contentsOf: Data(text.utf8))
    }

    func dispose() {
        for handle in [
            toAgent.fileHandleForReading,
            toAgent.fileHandleForWriting,
            fromAgent.fileHandleForReading,
            fromAgent.fileHandleForWriting,
        ] {
            try? handle.close()
        }
    }
}

/// A prompt driver that emits one chunk and then parks until cancelled.
///
/// The park is what makes the cancel test meaningful: the prompt is still
/// in flight when `session/cancel` arrives, so a serve loop that only reads
/// the next frame after finishing the current one would deadlock the test.
private final class ParkingPromptDriver: ACPPromptDriver, @unchecked Sendable {
    private let lock = NSLock()
    private var cancelledSessions: [AcpSessionId] = []
    private let chunks: [String]

    init(chunks: [String] = ["thinking", " done"]) {
        self.chunks = chunks
    }

    var cancelled: [AcpSessionId] {
        lock.lock()
        defer { lock.unlock() }
        return cancelledSessions
    }

    func run(
        context: ACPPromptContext,
        emit: @escaping @Sendable (SessionNotification, ACPNotificationDisposition) async -> Void
    ) async throws -> PromptResponse {
        for chunk in chunks {
            await emit(
                SessionNotification(
                    sessionId: context.session.sessionId,
                    update: .agentMessageChunk(
                        ContentChunk(content: .text(TextContent(text: chunk)))
                    )
                ),
                .durable
            )
        }
        // Park. Cancellation surfaces as `CancellationError`, which the runtime
        // maps to `stopReason: cancelled`.
        while true {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func cancel(sessionId: AcpSessionId) async {
        // `NSLock.lock()` is unavailable directly from an async context, so
        // the critical section lives in a synchronous helper.
        record(sessionId)
    }

    private func record(_ sessionId: AcpSessionId) {
        lock.lock()
        cancelledSessions.append(sessionId)
        lock.unlock()
    }
}

/// A driver that answers immediately, for the non-cancel paths.
private struct EchoPromptDriver: ACPPromptDriver {
    func run(
        context: ACPPromptContext,
        emit: @escaping @Sendable (SessionNotification, ACPNotificationDisposition) async -> Void
    ) async throws -> PromptResponse {
        await emit(
            SessionNotification(
                sessionId: context.session.sessionId,
                update: .agentMessageChunk(ContentChunk(content: .text(TextContent(text: "ack"))))
            ),
            .durable
        )
        return PromptResponse(stopReason: .endTurn)
    }

    func cancel(sessionId: AcpSessionId) async {}
}

private func initializeRequest(id: Int64) -> ACPMessage {
    .request(
        id: .number(id),
        method: AgentMethodNames.initialize,
        params: .object([
            "protocolVersion": .number(.int64(1)),
            "clientCapabilities": .object([:]),
        ])
    )
}

private func newSessionRequest(id: Int64, cwd: String) -> ACPMessage {
    .request(
        id: .number(id),
        method: AgentMethodNames.sessionNew,
        params: .object([
            "cwd": .string(cwd),
            "mcpServers": .array([]),
        ])
    )
}

private func promptRequest(id: Int64, sessionId: String, text: String) -> ACPMessage {
    .request(
        id: .number(id),
        method: AgentMethodNames.sessionPrompt,
        params: .object([
            "sessionId": .string(sessionId),
            "prompt": .array([.object(["type": .string("text"), "text": .string(text)])]),
        ])
    )
}

/// Read frames until one satisfies `match`, collecting everything skipped.
///
/// Notifications and responses interleave on the wire, so a test that wants
/// "the response to id 3" must not assume it is the next frame.
private func drain(
    _ transport: ACPStdioTransport,
    limit: Int = 40,
    until match: (ACPMessage) -> Bool
) async throws -> (matched: ACPMessage, seen: [ACPMessage]) {
    var seen: [ACPMessage] = []
    for _ in 0..<limit {
        let message = try await transport.receive()
        if match(message) { return (message, seen) }
        seen.append(message)
    }
    throw ACPTransportError.closed
}

private func sessionID(from response: ACPMessage) throws -> String {
    guard case .response(_, let result, _) = response,
          case .object(let object)? = result,
          case .string(let id)? = object["sessionId"]
    else {
        throw ACPTransportError.invalidMessage("no sessionId in \(response)")
    }
    return id
}

// MARK: - Tests

@Suite("ACP stdio host")
struct ACPStdioHostTests {

    @Test("initialize, session/new and prompt round-trip over real descriptors")
    func stdioRoundTrip() async throws {
        let harness = try StdioPipeHarness()
        defer { harness.dispose() }
        let runtime = ACPAgentRuntime(promptDriver: EchoPromptDriver())
        let host = ACPStdioHost(
            runtime: runtime,
            transport: ACPStdioTransport(io: harness.agentIO)
        )
        let served = Task { await host.run() }
        defer { served.cancel() }

        try await harness.clientTransport.send(initializeRequest(id: 1))
        let initialized = try await harness.clientTransport.receive()
        guard case .response(let initializeID, let initializeResult, let initializeError) = initialized else {
            Issue.record("expected an initialize response, got \(initialized)")
            return
        }
        #expect(initializeID == .number(1))
        #expect(initializeError == nil)
        // Decode rather than compare raw JSON: the number arrives as a double
        // through `JSONValue`, so `.number(.int64(1))` would not match.
        let capabilities = try #require(initializeResult).decode(InitializeResponse.self)
        #expect(capabilities.protocolVersion == .v1)

        let cwd = FileManager.default.temporaryDirectory.standardizedFileURL.path
        try await harness.clientTransport.send(newSessionRequest(id: 2, cwd: cwd))
        let created = try await harness.clientTransport.receive()
        let session = try sessionID(from: created)
        #expect(!session.isEmpty)

        try await harness.clientTransport.send(
            promptRequest(id: 3, sessionId: session, text: "hello")
        )
        let (response, notifications) = try await drain(harness.clientTransport) { message in
            if case .response(.number(3), _, _) = message { return true }
            return false
        }
        guard case .response(_, let result, let error) = response else {
            Issue.record("expected a prompt response, got \(response)")
            return
        }
        #expect(error == nil)
        #expect(result?["stopReason"] == .string("end_turn"))

        // The user's own turn is echoed back as a durable chunk before the
        // agent's, so both must appear — plus the turn-end broadcast
        // (`x.ai/session/prompt_complete`, acp_agent.rs:2952-2986), which
        // rides the same channel and fires before the prompt response.
        let methods = notifications.compactMap(\.self.method)
        #expect(methods.filter { $0 == ClientMethodNames.sessionUpdate }.count >= 2)
        #expect(methods.contains("x.ai/session/prompt_complete"))
        #expect(methods.allSatisfy {
            $0 == ClientMethodNames.sessionUpdate || $0 == "x.ai/session/prompt_complete"
        })

        await host.shutdown()
    }

    @Test("session/cancel interrupts a prompt that is still running")
    func cancelInterruptsInFlightPrompt() async throws {
        let harness = try StdioPipeHarness()
        defer { harness.dispose() }
        let driver = ParkingPromptDriver()
        let runtime = ACPAgentRuntime(promptDriver: driver)
        let host = ACPStdioHost(
            runtime: runtime,
            transport: ACPStdioTransport(io: harness.agentIO)
        )
        let served = Task { await host.run() }
        defer { served.cancel() }

        try await harness.clientTransport.send(initializeRequest(id: 1))
        _ = try await harness.clientTransport.receive()
        let cwd = FileManager.default.temporaryDirectory.standardizedFileURL.path
        try await harness.clientTransport.send(newSessionRequest(id: 2, cwd: cwd))
        let session = try sessionID(from: try await harness.clientTransport.receive())

        try await harness.clientTransport.send(
            promptRequest(id: 3, sessionId: session, text: "long task")
        )

        // Wait for the driver's own chunk so the prompt is provably in flight,
        // then cancel. `agentMessageChunk` only comes from the driver; the
        // echoed user turn is a `userMessageChunk`.
        let (_, _) = try await drain(harness.clientTransport) { message in
            guard message.method == ClientMethodNames.sessionUpdate,
                  case .object(let params)? = message.params,
                  case .object(let update)? = params["update"],
                  case .string("agent_message_chunk")? = update["sessionUpdate"]
            else { return false }
            return true
        }

        try await harness.clientTransport.send(
            .notification(
                method: AgentMethodNames.sessionCancel,
                params: .object(["sessionId": .string(session)])
            )
        )

        let (response, _) = try await drain(harness.clientTransport) { message in
            if case .response(.number(3), _, _) = message { return true }
            return false
        }
        guard case .response(_, let result, let error) = response else {
            Issue.record("expected a prompt response, got \(response)")
            return
        }
        #expect(error == nil)
        #expect(result?["stopReason"] == .string("cancelled"))
        #expect(driver.cancelled == [AcpSessionId(session)])

        await host.shutdown()
    }

    @Test("the serve loop ends when stdin reaches EOF")
    func servingStopsAtEOF() async throws {
        let harness = try StdioPipeHarness()
        defer { harness.dispose() }
        let runtime = ACPAgentRuntime(promptDriver: EchoPromptDriver())
        let host = ACPStdioHost(
            runtime: runtime,
            transport: ACPStdioTransport(io: harness.agentIO)
        )
        let served = Task { await host.run() }

        try await harness.clientTransport.send(initializeRequest(id: 1))
        _ = try await harness.clientTransport.receive()
        harness.closeAgentInput()

        // If EOF did not end the loop this would hang, which the suite's
        // watchdog would report as a timeout rather than a pass.
        await served.value
        #expect(await runtime.connectionState() == .closed)
    }

    @Test("blank and CRLF-terminated lines do not break framing")
    func toleratesBlankAndCRLFLines() async throws {
        let harness = try StdioPipeHarness()
        defer { harness.dispose() }
        let runtime = ACPAgentRuntime(promptDriver: EchoPromptDriver())
        let host = ACPStdioHost(
            runtime: runtime,
            transport: ACPStdioTransport(io: harness.agentIO)
        )
        let served = Task { await host.run() }
        defer { served.cancel() }

        // A blank line, then a CRLF-terminated frame: the shape a generous
        // client emits. Neither may disturb framing — a stray newline used to
        // reach `ACPStdioTransport.receive()` and raise `.invalidLine`, which
        // would tear the session down.
        let frame = String(decoding: try initializeRequest(id: 9).encodedData(), as: UTF8.self)
        harness.writeRaw("\n   \n\(frame)\r\n")

        let (response, _) = try await drain(harness.clientTransport) { message in
            if case .response(.number(9), _, _) = message { return true }
            return false
        }
        guard case .response(_, _, let error) = response else {
            Issue.record("expected an initialize response, got \(response)")
            return
        }
        #expect(error == nil)

        await host.shutdown()
    }
}
