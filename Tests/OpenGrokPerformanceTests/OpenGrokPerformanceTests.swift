import Dispatch
import Foundation
import OpenGrokMemory
import OpenGrokMarkdown
import OpenGrokPager
import OpenGrokSampler
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokShell
import OpenGrokShellBase
import Testing

@Suite("Performance gates")
struct PerformanceGateTests {
    @Test("Chat stream throughput preserves ordered text and one terminal event")
    func chatStreamThroughput() async throws {
        #expect(PerformanceBudgets.profile == "macos-15")
        let chunkCount = 1_024
        let expected = (0..<chunkCount).map { "token-\($0) " }.joined()
        let median = await medianAsync {
            let input = AsyncStream<Result<ChatCompletionChunk, SamplingError>> { continuation in
                for index in 0..<chunkCount {
                    let chunk = ChatCompletionChunk(
                        id: "chunk-\(index)",
                        object: "chat.completion.chunk",
                        created: UInt64(index),
                        model: "performance-model",
                        choices: [ChatChunkChoice(
                            index: 0,
                            delta: ChatChunkDelta(content: "token-\(index) ")
                        )]
                    )
                    continuation.yield(.success(chunk))
                }
                continuation.yield(.success(ChatCompletionChunk(
                    id: "terminal",
                    object: "chat.completion.chunk",
                    created: UInt64(chunkCount),
                    model: "performance-model",
                    choices: [ChatChunkChoice(index: 0, delta: ChatChunkDelta(), finishReason: .stop)]
                )))
                continuation.finish()
            }
            let events = streamChatCompletions(
                rawStream: input,
                modelMetadata: nil,
                requestId: RequestId("performance-stream"),
                idleTimeout: .seconds(30)
            )
            var reconstructed = ""
            var tokenEvents = 0
            var terminalEvents = 0
            for await event in events {
                switch event {
                case .channelToken(_, _, let text, _):
                    reconstructed += text
                    tokenEvents += 1
                case .completed:
                    terminalEvents += 1
                case .failed(_, let error):
                    #expect(Bool(false), "stream failed: \(error.message)")
                default:
                    break
                }
            }
            #expect(reconstructed == expected)
            #expect(tokenEvents == chunkCount)
            #expect(terminalEvents == 1)
        }
        print("G050 stream profile=\(PerformanceBudgets.profile) median_ns=\(median) budget_ns=\(PerformanceBudgets.streamNanoseconds)")
        #expect(median <= PerformanceBudgets.streamNanoseconds)
    }

    @Test("large transcript rendering stays equivalent through pager mapping")
    func transcriptRenderThroughput() throws {
        #expect(PerformanceBudgets.profile == "macos-15")
        let source = Self.largeTranscript
        let median = medianSync {
            var streaming = StreamingMarkdownRenderer()
            let characters = Array(source)
            var offset = 0
            while offset < characters.count {
                let end = min(offset + 32, characters.count)
                _ = streaming.pushAndRender(String(characters[offset..<end]))
                offset = end
            }
            let streamed = streaming.finish()
            let full = MarkdownRenderer().render(source)
            #expect(streamed == full)
            let pager = PagerMarkdownRenderer.map(full)
            #expect(pager.flatMap(\.spans).allSatisfy { !$0.text.isEmpty })
            #expect(pager.map(\.text).joined().contains("Architecture"))
            #expect(pager.flatMap(\.spans).filter { $0.url != nil }.allSatisfy { !$0.url!.isEmpty })
        }
        print("G050 render profile=\(PerformanceBudgets.profile) median_ns=\(median) budget_ns=\(PerformanceBudgets.renderNanoseconds)")
        #expect(median <= PerformanceBudgets.renderNanoseconds)
    }

    @Test("long shell session preserves identity and ordered turn results")
    func longShellSession() async throws {
        #expect(PerformanceBudgets.profile == "macos-15")
        let median = try await medianAsync {
            let root = try makeTemporaryDirectory(prefix: "opengrok-shell-performance")
            defer { removeTemporaryDirectory(root) }
            let provider = PerformanceProvider(sessionID: "performance-session")
            let shell = makeShell(root: root, provider: provider)
            let startup = try await shell.start()
            #expect(startup.state == .running)
            let sessionID = SessionID("performance-session")
            let descriptor = try await shell.createSession(
                OpenGrokShellSessionRequest(sessionID: sessionID, cwd: root, restorePersistedState: false)
            )
            #expect(descriptor.sessionID == sessionID)

            for index in 0..<128 {
                let handle = try await shell.submitTurn(
                    sessionID: sessionID,
                    request: OpenGrokShellTurnRequest(
                        promptID: "prompt-\(index)",
                        text: "turn-\(index)",
                        turnID: "turn-\(index)"
                    )
                )
                let result = try await shell.waitForTurn(handle, timeout: .seconds(10))
                #expect(result.sessionID == sessionID)
                #expect(result.turnID == "turn-\(index)")
                #expect(result.output == "reply turn-\(index)")
            }

            #expect(await shell.lookupSession(sessionID)?.sessionID == sessionID)
            let shutdown = await shell.shutdown(timeout: .seconds(10))
            #expect(shutdown.state == .closed)
            #expect(shutdown.closedSessionCount == 1)
        }
        print("G050 session profile=\(PerformanceBudgets.profile) median_ns=\(median) budget_ns=\(PerformanceBudgets.sessionNanoseconds)")
        #expect(median <= PerformanceBudgets.sessionNanoseconds)
    }

    @Test("memory reindex and persisted FTS search stay within budget")
    func memoryIndexThroughput() throws {
        #expect(PerformanceBudgets.profile == "macos-15")
        let median = try medianSync {
            let root = try makeTemporaryDirectory(prefix: "opengrok-memory-performance")
            defer { removeTemporaryDirectory(root) }
            let memoryRoot = root.appendingPathComponent("memory", isDirectory: true)
            let storage = MemoryStorage.newFlat(cwd: root, root: memoryRoot)
            let indexURL = root.appendingPathComponent("index.json")
            let index = try MemoryIndex(indexURL: indexURL, storage: storage)
            for indexNumber in 0..<48 {
                let file = root.appendingPathComponent("note-\(indexNumber).md")
                try "# Note \(indexNumber)\n\nRust memory indexing performance and persistence signal.".write(to: file, atomically: true, encoding: .utf8)
                let result = try index.reindexFile(path: file, source: "workspace")
                #expect(result.added == 1)
            }
            let hits = try index.searchFTS("Rust persistence", limit: 20)
            #expect(hits.count == 20)
            let reopened = try MemoryIndex(indexURL: indexURL, storage: storage)
            #expect(try reopened.searchFTS("Rust persistence", limit: 20).count == 20)
        }
        print("G050 memory profile=\(PerformanceBudgets.profile) median_ns=\(median) budget_ns=\(PerformanceBudgets.memoryNanoseconds)")
        #expect(median <= PerformanceBudgets.memoryNanoseconds)
    }

    private static let largeTranscript = String(repeating: #"""
    ## Architecture Overview

    The **streaming** pager keeps ordered content, [links](https://example.com), and `inline code` stable across incremental renders.

    - first item
      - nested item
    - second item

    ```swift
    let value = "wide unicode 🚀 漢字"
    ```

    | stage | cached |
    |---|---|
    | markdown | yes |

    """#, count: 32)
}

private enum PerformanceClock {
    static func elapsed(_ operation: () throws -> Void) rethrows -> UInt64 {
        let start = DispatchTime.now().uptimeNanoseconds
        try operation()
        return DispatchTime.now().uptimeNanoseconds - start
    }
}

private func medianSync(_ operation: () throws -> Void) rethrows -> UInt64 {
    try operation()
    let samples = try (0..<3).map { _ in try PerformanceClock.elapsed(operation) }
    return samples.sorted()[samples.count / 2]
}

private func medianAsync(_ operation: () async throws -> Void) async rethrows -> UInt64 {
    try await operation()
    var samples: [UInt64] = []
    for _ in 0..<3 {
        let start = DispatchTime.now().uptimeNanoseconds
        try await operation()
        samples.append(DispatchTime.now().uptimeNanoseconds - start)
    }
    return samples.sorted()[samples.count / 2]
}

private func makeTemporaryDirectory(prefix: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func removeTemporaryDirectory(_ directory: URL) {
    try? FileManager.default.removeItem(at: directory)
}

private actor PerformanceBackend: ShellProcessBackend {
    func run(_ request: ShellCommandRequest) async throws -> ShellCommandResult {
        throw ShellError.unsupported(capability: .processExecution, platform: "performance-test")
    }

    func runBackground(_ request: ShellCommandRequest) async throws -> ShellBackgroundHandle {
        throw ShellError.unsupported(capability: .processExecution, platform: "performance-test")
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

private actor PerformanceProvider: OpenGrokShellProviderSession {
    let sessionID: String
    private var activeTurnID: String?

    init(sessionID: String) {
        self.sessionID = sessionID
    }

    func snapshot() async -> OpenGrokShellProviderSessionSnapshot {
        OpenGrokShellProviderSessionSnapshot(
            sessionID: sessionID,
            modelID: "performance-model",
            provider: "performance-provider",
            generation: 0
        )
    }

    func beginTurn(turnID: String) async throws -> OpenGrokShellProviderTurnContext {
        guard activeTurnID == nil else { throw OpenGrokShellError.turnAlreadyActive(turnID) }
        activeTurnID = turnID
        return OpenGrokShellProviderTurnContext(sessionID: sessionID, turnID: turnID, modelID: "performance-model", attempt: 0)
    }

    func finishTurn(turnID: String) async throws {
        guard activeTurnID == turnID else { throw OpenGrokShellError.turnNotFound(turnID) }
        activeTurnID = nil
    }

    func failTurn(turnID: String) async {
        if activeTurnID == turnID { activeTurnID = nil }
    }

    func cancelTurn(turnID: String) async throws {
        if activeTurnID == turnID { activeTurnID = nil }
    }
}

private struct PerformanceProviderFactory: OpenGrokShellProviderFactory {
    let provider: PerformanceProvider

    func makeSession(for request: OpenGrokShellSessionRequest) throws -> any OpenGrokShellProviderSession {
        provider
    }
}

private struct PerformanceTurnDriver: OpenGrokShellTurnDriver {
    func submit(
        providerSession: any OpenGrokShellProviderSession,
        request: OpenGrokShellTurnRequest,
        emit: @escaping @Sendable (OpenGrokShellTurnUpdateKind) async -> Void
    ) async throws -> OpenGrokShellTurnResult {
        let context = try await providerSession.beginTurn(turnID: request.turnID)
        await emit(.assistantText("reply \(request.text)"))
        try await providerSession.finishTurn(turnID: request.turnID)
        return OpenGrokShellTurnResult(
            sessionID: SessionID(context.sessionID),
            turnID: request.turnID,
            output: "reply \(request.text)",
            stopReason: "performance"
        )
    }

    func cancel(providerSession: any OpenGrokShellProviderSession, turnID: String) async throws {
        try await providerSession.cancelTurn(turnID: turnID)
    }
}

private func makeShell(root: URL, provider: PerformanceProvider) -> OpenGrokShell {
    OpenGrokShell(configuration: OpenGrokShellConfiguration(
        openGrokHome: root.appendingPathComponent("home", isDirectory: true),
        processBackend: PerformanceBackend(),
        providerFactory: PerformanceProviderFactory(provider: provider),
        turnDriver: PerformanceTurnDriver(),
        now: { Date(timeIntervalSince1970: 1_700_000_000) }
    ))
}
