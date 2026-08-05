// LiveACPCompositionTests.swift
//
// The `acp` CLI route driven in-process: the composition builds the same
// runtime the production path builds, but over an in-memory transport pair so
// a test can play the client. Also pins the `serve`/`leader` refusals, which
// are load-bearing — they are the contract that this build does not pretend to
// have a server.

import Foundation
import OpenGrokACP
import OpenGrokACPRuntime
import OpenGrokShared
import Testing

@testable import OpenGrokCLI

/// Answers every prompt with one chunk and an end-of-turn.
private struct StubPromptDriver: ACPPromptDriver {
    let reply: String

    func run(
        context: ACPPromptContext,
        emit: @escaping @Sendable (SessionNotification, ACPNotificationDisposition) async -> Void
    ) async throws -> PromptResponse {
        await emit(
            SessionNotification(
                sessionId: context.session.sessionId,
                update: .agentMessageChunk(ContentChunk(content: .text(TextContent(text: reply))))
            ),
            .durable
        )
        return PromptResponse(stopReason: .endTurn)
    }

    func cancel(sessionId: AcpSessionId) async {}
}

private func acpContext(cwd: URL) -> (CLIApplicationContext, BufferedStream, BufferedStream) {
    let (streams, out, err) = CLIStreams.buffered()
    let context = CLIApplicationContext(
        environment: ["OPENGROK_HOME": cwd.appendingPathComponent(".opengrok").path, "HOME": cwd.path],
        streams: streams,
        control: .never
    )
    return (context, out, err)
}

private func launchOptions(cwd: URL) -> CLIExecutionOptions {
    var common = CLICommonOptions()
    common.cwd = cwd.path
    return CLIExecutionOptions(mode: .acp, common: common)
}

@Suite("Live ACP composition")
struct LiveACPCompositionTests {

    @Test("the route claims acp launches, serve and leader")
    func handlesRoutes() {
        var common = CLICommonOptions()
        common.cwd = nil
        #expect(LiveACPComposition.handles(.launch(CLIExecutionOptions(mode: .acp, common: common))))
        #expect(LiveACPComposition.handles(.serve(CLIServeOptions())))
        #expect(LiveACPComposition.handles(.leader(CLILeaderOptions())))
        #expect(
            !LiveACPComposition.handles(
                .launch(CLIExecutionOptions(mode: .interactive, common: common))
            )
        )
    }

    @Test("initialize, session/new and prompt round-trip through the route")
    func stdioRoundTrip() async throws {
        let cwd = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-acp-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cwd) }

        let (context, _, _) = acpContext(cwd: cwd)
        let pair = InProcessACPTransport.makePair()
        let session = try await LiveACPComposition.stdioSession(
            options: launchOptions(cwd: cwd),
            context: context,
            services: LiveACPServices { _ in
                LiveACPPromptDriver(driver: StubPromptDriver(reply: "hi from the agent"))
            },
            transport: pair.agent
        )
        let served = Task { try await session.waitForExit() }
        defer { served.cancel() }

        try await pair.client.send(
            .request(
                id: .number(1),
                method: AgentMethodNames.initialize,
                params: .object([
                    "protocolVersion": .number(.int64(1)),
                    "clientCapabilities": .object([:]),
                ])
            )
        )
        guard case .response(_, let initializeResult, let initializeError) = try await pair.client.receive()
        else {
            Issue.record("expected an initialize response")
            return
        }
        #expect(initializeError == nil)
        // Decode rather than compare raw JSON: the number arrives as a double
        // through `JSONValue`, so `.number(.int64(1))` would not match.
        let capabilities = try #require(initializeResult).decode(InitializeResponse.self)
        #expect(capabilities.protocolVersion == .v1)

        try await pair.client.send(
            .request(
                id: .number(2),
                method: AgentMethodNames.sessionNew,
                params: .object(["cwd": .string(cwd.standardizedFileURL.path), "mcpServers": .array([])])
            )
        )
        guard case .response(_, let newResult, let newError) = try await pair.client.receive(),
              case .string(let sessionId)? = newResult?["sessionId"]
        else {
            Issue.record("expected a session/new response carrying a sessionId")
            return
        }
        #expect(newError == nil)

        try await pair.client.send(
            .request(
                id: .number(3),
                method: AgentMethodNames.sessionPrompt,
                params: .object([
                    "sessionId": .string(sessionId),
                    "prompt": .array([.object(["type": .string("text"), "text": .string("hello")])]),
                ])
            )
        )

        var agentChunks: [String] = []
        var stopReason: JSONValue?
        for _ in 0..<20 {
            let message = try await pair.client.receive()
            if case .response(.number(3), let result, let error) = message {
                #expect(error == nil)
                stopReason = result?["stopReason"]
                break
            }
            if message.method == ClientMethodNames.sessionUpdate,
               case .object(let params)? = message.params,
               case .object(let update)? = params["update"],
               case .string("agent_message_chunk")? = update["sessionUpdate"],
               case .object(let content)? = update["content"],
               case .string(let text)? = content["text"] {
                agentChunks.append(text)
            }
        }
        #expect(stopReason == .string("end_turn"))
        #expect(agentChunks == ["hi from the agent"])

        await session.shutdown()
    }

    @Test("the default services refuse instead of answering an empty turn")
    func defaultServicesRefuse() async throws {
        let cwd = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-acp-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cwd) }
        let (context, _, _) = acpContext(cwd: cwd)

        await #expect(throws: CLIApplicationError.self) {
            _ = try await LiveACPComposition.stdioSession(
                options: launchOptions(cwd: cwd),
                context: context,
                transport: InProcessACPTransport.makePair().agent
            )
        }
    }

    @Test("a missing working directory is rejected before any transport is opened")
    func rejectsMissingWorkingDirectory() async throws {
        var common = CLICommonOptions()
        common.cwd = "/definitely/not/here-\(UUID().uuidString)"
        let (context, _, _) = acpContext(cwd: FileManager.default.temporaryDirectory)

        await #expect(throws: CLIApplicationError.self) {
            _ = try await LiveACPComposition.stdioSession(
                options: CLIExecutionOptions(mode: .acp, common: common),
                context: context,
                services: LiveACPServices { _ in
                    LiveACPPromptDriver(driver: StubPromptDriver(reply: "unused"))
                },
                transport: InProcessACPTransport.makePair().agent
            )
        }
    }

    // MARK: serve / leader

    @Test("serve names the missing WebSocket server transport")
    func serveRefusalIsSpecific() {
        let error = LiveACPComposition.serveUnsupported(CLIServeOptions(bind: "127.0.0.1:2419"))
        guard case .failed(let message) = error else {
            Issue.record("expected a failure with a message")
            return
        }
        #expect(message.contains("WebSocket server transport"))
        #expect(message.contains("ws://127.0.0.1:2419/ws"))
        // It must point somewhere useful, not just say no.
        #expect(message.contains("open-grok acp"))
    }

    @Test("leader names the missing IPC framing")
    func leaderRefusalIsSpecific() {
        let error = LiveACPComposition.leaderUnsupported(CLILeaderOptions())
        guard case .failed(let message) = error else {
            Issue.record("expected a failure with a message")
            return
        }
        #expect(message.contains("leader IPC transport"))
        #expect(message.contains("leader.sock"))
        #expect(message.contains("open-grok acp"))
    }

    @Test("serve and leader refuse through the route entry point")
    func routeRefusesServeAndLeader() async throws {
        let (context, _, _) = acpContext(cwd: FileManager.default.temporaryDirectory)
        await #expect(throws: CLIApplicationError.self) {
            _ = try await LiveACPComposition.session(for: .serve(CLIServeOptions()), context: context)
        }
        await #expect(throws: CLIApplicationError.self) {
            _ = try await LiveACPComposition.session(for: .leader(CLILeaderOptions()), context: context)
        }
    }
}
