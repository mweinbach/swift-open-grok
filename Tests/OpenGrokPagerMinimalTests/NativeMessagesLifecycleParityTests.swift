import OpenGrokPagerMinimal
import Testing

@Suite("Native Messages minimal pager lifecycle")
struct NativeMessagesLifecycleParityTests {
    @Test("native response lifecycle is forwarded losslessly before terminal completion")
    func forwardsNativeLifecycleInOrder() async throws {
        let completion = OpenGrokPagerMinimalCompletion(
            sessionID: "session-native",
            summary: "stop",
            messageID: "msg_native_1",
            rawStopReason: "stop_sequence",
            stopSequence: "\n\nHuman:",
            inputTokens: 7,
            outputTokens: 17,
            cacheReadInputTokens: 11,
            cacheCreationInputTokens: 13
        )
        let providerEvents: [OpenGrokPagerMinimalEvent] = [
            .responseStarted(
                messageID: "msg_native_1",
                model: "claude-sonnet-4-5",
                inputTokens: 7,
                cacheReadInputTokens: 11,
                cacheCreationInputTokens: 13
            ),
            .reasoning("thinking"),
            .reasoningCompleted(signature: "encrypted-signature"),
            .output("answer"),
            .responseCompleted(
                messageID: "msg_native_1",
                stopReason: "stop_sequence",
                stopSequence: "\n\nHuman:",
                inputTokens: 7,
                outputTokens: 17,
                cacheReadInputTokens: 11,
                cacheCreationInputTokens: 13
            ),
            .completed(completion),
        ]
        let session = NativeMessagesMinimalSession(events: providerEvents)
        let renderer = NativeMessagesMinimalRenderer()
        let output = NativeMessagesMinimalOutput()
        let pager = OpenGrokPagerMinimal(
            runtime: NativeMessagesMinimalRuntime(session: session),
            renderer: renderer,
            output: output
        )

        let result = try await pager.run(.init(prompt: "explain"))

        #expect(result.lifecycle == .completed)
        #expect(result.forwardedEventCount == providerEvents.count + 2)
        #expect(await output.events == [
            .lifecycle(.starting),
            .lifecycle(.running),
        ] + providerEvents)
        #expect(await renderer.events == [
            .lifecycle(.starting),
            .lifecycle(.running),
        ] + providerEvents)
    }

    @Test("legacy completion callers retain nil metadata and zero usage")
    func preservesLegacyCompletionDefaults() {
        let completion = OpenGrokPagerMinimalCompletion(sessionID: "legacy", summary: "done")

        #expect(completion.messageID == nil)
        #expect(completion.rawStopReason == nil)
        #expect(completion.stopSequence == nil)
        #expect(completion.inputTokens == 0)
        #expect(completion.outputTokens == 0)
        #expect(completion.cacheReadInputTokens == 0)
        #expect(completion.cacheCreationInputTokens == 0)
    }
}

private struct NativeMessagesMinimalSession: OpenGrokPagerMinimalSessionAdapter {
    let sessionID: String? = "session-native"
    let events: AsyncThrowingStream<OpenGrokPagerMinimalEvent, Error>

    init(events: [OpenGrokPagerMinimalEvent]) {
        self.events = AsyncThrowingStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }

    func cancel() async {}
    func close() async {}
}

private struct NativeMessagesMinimalRuntime: OpenGrokPagerMinimalRuntimeAdapter {
    let session: NativeMessagesMinimalSession

    func makeSession(
        for request: OpenGrokPagerMinimalRequest
    ) async throws -> any OpenGrokPagerMinimalSessionAdapter {
        session
    }
}

private actor NativeMessagesMinimalRenderer: OpenGrokPagerMinimalRenderAdapter {
    private(set) var events: [OpenGrokPagerMinimalEvent] = []

    func begin() async throws {}

    func render(_ event: OpenGrokPagerMinimalEvent) async throws {
        events.append(event)
    }

    func restoreTerminal() async throws {}
}

private actor NativeMessagesMinimalOutput: OpenGrokPagerMinimalOutputAdapter {
    private(set) var events: [OpenGrokPagerMinimalEvent] = []

    func forward(_ event: OpenGrokPagerMinimalEvent) async throws {
        events.append(event)
    }
}
