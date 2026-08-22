import Foundation
import OpenGrokShared
import OpenGrokShellBase
import OpenGrokShellSessionSupport
import Testing
@testable import OpenGrokShell

@Suite("Native Messages shell lifecycle bridge")
struct NativeMessagesLifecycleBridgeTests {
    @Test("provider starts, thinking signatures, and text preserve stream order")
    func preservesProviderLifecycleOrder() async throws {
        let updates = NativeMessagesShellUpdates()
        let provider = NativeMessagesShellProvider(sessionID: "session-native")
        let driver = ProviderSessionTurnDriver(sampler: NativeMessagesShellSampler())

        let result = try await driver.submit(
            providerSession: provider,
            request: OpenGrokShellTurnRequest(
                promptID: "prompt-native",
                text: "think carefully",
                turnID: "turn-native"
            )
        ) { update in
            await updates.append(update)
        }

        #expect(await updates.values == [
            .responseStarted(
                messageID: "msg_provider_1",
                model: "claude-sonnet-4-5",
                inputTokens: 7,
                cacheReadInputTokens: 11,
                cacheCreationInputTokens: 13
            ),
            .reasoning("private thought"),
            .reasoningCompleted(signature: "encrypted-signature"),
            .assistantText("answer"),
        ])
        #expect(result.messageID == "msg_provider_1")
        #expect(result.stopReason == "stop")
        #expect(result.rawStopReason == "stop_sequence")
        #expect(result.stopSequence == "\n\nHuman:")
        #expect(result.inputTokens == 7)
        #expect(result.outputTokens == 17)
        #expect(result.cacheReadInputTokens == 11)
        #expect(result.cacheCreationInputTokens == 13)
        #expect(await provider.finishedTurns == ["turn-native"])
    }

    @Test("cancelled turns keep provider message and metering metadata")
    func preservesCancelledProviderMetadata() async throws {
        let provider = NativeMessagesShellProvider(sessionID: "session-cancelled")
        let driver = ProviderSessionTurnDriver(
            sampler: NativeMessagesShellSampler(cancelled: true)
        )

        let result = try await driver.submit(
            providerSession: provider,
            request: OpenGrokShellTurnRequest(text: "stop", turnID: "turn-cancelled")
        ) { _ in }

        #expect(result.cancelled)
        #expect(result.messageID == "msg_provider_1")
        #expect(result.rawStopReason == "stop_sequence")
        #expect(result.stopSequence == "\n\nHuman:")
        #expect(result.inputTokens == 7)
        #expect(result.outputTokens == 17)
        #expect(result.cacheReadInputTokens == 11)
        #expect(result.cacheCreationInputTokens == 13)
        #expect(await provider.cancelledTurns == ["turn-cancelled"])
    }

    @Test("legacy shell results retain backwards-compatible defaults")
    func retainsLegacyResultDefaults() {
        let sample = OpenGrokShellSamplingResult(output: "legacy")
        let result = OpenGrokShellTurnResult(
            sessionID: SessionID("session-legacy"),
            turnID: "turn-legacy",
            output: "legacy"
        )

        #expect(sample.messageID == nil)
        #expect(sample.rawStopReason == nil)
        #expect(sample.stopSequence == nil)
        #expect(sample.inputTokens == 0)
        #expect(sample.outputTokens == 0)
        #expect(sample.cacheReadInputTokens == 0)
        #expect(sample.cacheCreationInputTokens == 0)
        #expect(result.messageID == nil)
        #expect(result.rawStopReason == nil)
        #expect(result.stopSequence == nil)
        #expect(result.inputTokens == 0)
        #expect(result.outputTokens == 0)
        #expect(result.cacheReadInputTokens == 0)
        #expect(result.cacheCreationInputTokens == 0)
    }

    @Test(
        "peer and team messages stay synthetic and hidden in durable shell history",
        arguments: ["peer-message-mail-1", "agent-message-mail-2"]
    )
    func syntheticAgentTurnsCannotImpersonateUser(promptID: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "opengrok-native-peer-\(UUID().uuidString)",
            isDirectory: true
        )
        let home = root.appendingPathComponent("home", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = SessionID("session-agent-origin")
        let provider = NativeMessagesShellProvider(sessionID: sessionID.rawValue)
        let shell = OpenGrokShell(configuration: OpenGrokShellConfiguration(
            openGrokHome: home,
            processBackend: NativeMessagesShellProcessBackend(),
            providerFactory: NativeMessagesShellProviderFactory(provider: provider),
            turnDriver: ProviderSessionTurnDriver(sampler: NativeMessagesShellSampler())
        ))
        _ = try await shell.start()
        _ = try await shell.createSession(OpenGrokShellSessionRequest(
            sessionID: sessionID,
            cwd: root
        ))

        let handle = try await shell.submitTurn(
            sessionID: sessionID,
            request: OpenGrokShellTurnRequest(
                promptID: promptID,
                text: "untrusted peer message",
                turnID: "turn-agent-origin"
            )
        )
        _ = try await shell.waitForTurn(handle, timeout: ShellDuration(timeInterval: 2))

        let state = try #require(try await SessionStateStore(root: home).load(sessionID: sessionID))
        let peerHistory = try #require(state.chatHistory.first)
        #expect(peerHistory["type"] == .string("user"))
        #expect(peerHistory["synthetic_reason"] == .string("agent_message"))
        #expect(state.summary.chatMessageCount == 2)

        let peerUpdate = try #require(state.updates.first)
        let body = try #require(peerUpdate.params["update"])
        #expect(body["sessionUpdate"] == .string("user_message_chunk"))
        #expect(body["_meta"]?["hideFromScrollback"] == .bool(true))
        #expect(body["content"]?["_meta"] == nil)
        #expect(!state.transcript.entries.contains { entry in
            if case .userTextChunk = entry.event { return true }
            return false
        })

        _ = await shell.shutdown(timeout: ShellDuration(timeInterval: 1))
    }
}

private actor NativeMessagesShellUpdates {
    private(set) var values: [OpenGrokShellTurnUpdateKind] = []

    func append(_ update: OpenGrokShellTurnUpdateKind) {
        values.append(update)
    }
}

private struct NativeMessagesShellSampler: OpenGrokShellSamplingDriver {
    var cancelled = false

    func sample(
        context: OpenGrokShellProviderTurnContext,
        request: OpenGrokShellTurnRequest,
        emit: @escaping @Sendable (OpenGrokShellTurnUpdateKind) async -> Void
    ) async throws -> OpenGrokShellSamplingResult {
        await emit(.responseStarted(
            messageID: "msg_provider_1",
            model: "claude-sonnet-4-5",
            inputTokens: 7,
            cacheReadInputTokens: 11,
            cacheCreationInputTokens: 13
        ))
        await emit(.reasoning("private thought"))
        await emit(.reasoningCompleted(signature: "encrypted-signature"))
        await emit(.assistantText("answer"))

        return OpenGrokShellSamplingResult(
            output: "answer",
            stopReason: "stop",
            cancelled: cancelled,
            messageID: "msg_provider_1",
            rawStopReason: "stop_sequence",
            stopSequence: "\n\nHuman:",
            inputTokens: 7,
            outputTokens: 17,
            cacheReadInputTokens: 11,
            cacheCreationInputTokens: 13
        )
    }
}

private actor NativeMessagesShellProvider: OpenGrokShellProviderSession {
    let sessionID: String
    private(set) var finishedTurns: [String] = []
    private(set) var cancelledTurns: [String] = []

    init(sessionID: String) {
        self.sessionID = sessionID
    }

    func snapshot() async -> OpenGrokShellProviderSessionSnapshot {
        OpenGrokShellProviderSessionSnapshot(
            sessionID: sessionID,
            modelID: "claude-sonnet-4-5",
            provider: "messages",
            generation: 0
        )
    }

    func beginTurn(turnID: String) async throws -> OpenGrokShellProviderTurnContext {
        OpenGrokShellProviderTurnContext(
            sessionID: sessionID,
            turnID: turnID,
            modelID: "claude-sonnet-4-5",
            attempt: 0
        )
    }

    func finishTurn(turnID: String) async throws {
        finishedTurns.append(turnID)
    }

    func failTurn(turnID: String) async {}

    func cancelTurn(turnID: String) async throws {
        cancelledTurns.append(turnID)
    }
}

private struct NativeMessagesShellProviderFactory: OpenGrokShellProviderFactory {
    let provider: NativeMessagesShellProvider

    func makeSession(
        for request: OpenGrokShellSessionRequest
    ) throws -> any OpenGrokShellProviderSession {
        provider
    }
}

private actor NativeMessagesShellProcessBackend: ShellProcessBackend {
    func run(_ request: ShellCommandRequest) async throws -> ShellCommandResult {
        throw ShellError.unsupported(capability: .processExecution, platform: "test")
    }

    func runBackground(_ request: ShellCommandRequest) async throws -> ShellBackgroundHandle {
        throw ShellError.unsupported(capability: .processExecution, platform: "test")
    }

    func getTask(_ taskID: String) async -> ShellTaskSnapshot? { nil }
    func killTask(_ taskID: String) async -> ShellKillOutcome { .notFound }
    func killForegroundCommands() async {}
    func killForegroundCommands(ownerSessionID: String) async {}
    func killAllBackgroundTasks() async {}
    func killAllBackgroundTasks(ownerSessionID: String) async {}
    func warmShell(at cwd: URL) async {}
    func backgroundForegroundCommand(toolCallID: String) async -> Bool { false }
    func waitForCompletion(_ taskID: String, timeout: ShellDuration?) async -> ShellTaskSnapshot? { nil }
    func listTasks() async -> [ShellTaskSnapshot] { [] }
    func shellCWD() async -> URL? { nil }
}
