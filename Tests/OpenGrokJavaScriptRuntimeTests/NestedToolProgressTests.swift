#if canImport(JavaScriptCore)

import Foundation
import OpenGrokCodeModeProtocol
import OpenGrokShared
import Testing

@testable import OpenGrokJavaScriptRuntime

private let progressDemoTool = EnabledToolMetadata(
    toolName: .plain("demo"),
    globalName: "demo",
    description: "progress-aware test tool",
    kind: .function
)

private final class ProgressRuntimeEvents {
    private var iterator: AsyncStream<JavaScriptRuntimeEvent>.AsyncIterator

    init(_ events: AsyncStream<JavaScriptRuntimeEvent>) {
        iterator = events.makeAsyncIterator()
    }

    func next() async -> JavaScriptRuntimeEvent? {
        while let event = await iterator.next() {
            if case .started = event { continue }
            if case .pending = event { continue }
            return event
        }
        return nil
    }

    func outputUntilResult() async -> (texts: [String], errorText: String?) {
        var texts: [String] = []
        while let event = await next() {
            switch event {
            case .contentItem(.inputText(let text)):
                texts.append(text)
            case .result(_, let errorText):
                return (texts, errorText)
            default:
                continue
            }
        }
        return (texts, "runtime ended before reporting a result")
    }
}

private func startProgressRuntime(
    _ source: String
) throws -> (runtime: JavaScriptCellRuntime, events: ProgressRuntimeEvents) {
    let started = try JavaScriptCellRuntime.start(
        configuration: JavaScriptCellConfiguration(
            toolCallId: "outer-progress",
            enabledTools: [progressDemoTool],
            source: source
        ),
        pendingMode: .continueImmediately
    )
    return (started.runtime, ProgressRuntimeEvents(started.events))
}

private func nextProgressToolID(_ events: ProgressRuntimeEvents) async throws -> String {
    let event = try #require(await events.next())
    guard case .toolCall(let id, _, _, _) = event else {
        Issue.record("expected a nested tool call, got \(event)")
        throw CancellationError()
    }
    return id
}

@Suite("JavaScript nested-tool progress callbacks")
struct JavaScriptNestedToolProgressTests {
    @Test("onProgress receives ordered text and structured payload chunks")
    func progressReachesPromiseHandler() async throws {
        let (runtime, events) = try startProgressRuntime(
            """
            const chunks = [];
            const pending = tools.demo({});
            pending.onProgress((chunk) => {
              chunks.push([chunk.text, chunk.payload]);
            });
            text(JSON.stringify({ chunks, result: await pending }));
            """
        )
        defer { runtime.beginTermination() }

        let callID = try await nextProgressToolID(events)
        runtime.send(.toolProgress(id: callID, progress: .text("first")))
        runtime.send(.toolProgress(
            id: callID,
            progress: .withPayload("second", .object(["step": .number(.int64(2))]))
        ))
        runtime.send(.toolResponse(id: callID, result: .string("done")))

        let result = await events.outputUntilResult()
        #expect(result.errorText == nil)
        #expect(result.texts == [#"{"chunks":[["first",null],["second",{"step":2}]],"result":"done"}"#])
    }

    @Test("registering another handler replaces the first one")
    func registeringHandlerReplacesPreviousHandler() async throws {
        let (runtime, events) = try startProgressRuntime(
            """
            const pending = tools.demo({});
            pending.onProgress((chunk) => text("old:" + chunk.text));
            pending.onProgress((chunk) => text("new:" + chunk.text));
            await pending;
            """
        )
        defer { runtime.beginTermination() }

        let callID = try await nextProgressToolID(events)
        runtime.send(.toolProgress(id: callID, progress: .text("chunk")))
        runtime.send(.toolResponse(id: callID, result: .null))

        let result = await events.outputUntilResult()
        #expect(result.errorText == nil)
        #expect(result.texts == ["new:chunk"])
    }

    @Test("throwing progress handlers cannot fail the nested tool or cell")
    func handlerExceptionDoesNotFailCell() async throws {
        let (runtime, events) = try startProgressRuntime(
            """
            const pending = tools.demo({});
            pending.onProgress(() => { throw new Error("handler boom"); });
            text(String(await pending));
            """
        )
        defer { runtime.beginTermination() }

        let callID = try await nextProgressToolID(events)
        runtime.send(.toolProgress(id: callID, progress: .text("ignored")))
        runtime.send(.toolResponse(id: callID, result: .string("done")))

        let result = await events.outputUntilResult()
        #expect(result.errorText == nil)
        #expect(result.texts == ["done"])
    }

    @Test("progress without a registered handler is silently ignored")
    func missingHandlerDoesNotFailCell() async throws {
        let (runtime, events) = try startProgressRuntime(
            "text(String(await tools.demo({})));"
        )
        defer { runtime.beginTermination() }

        let callID = try await nextProgressToolID(events)
        runtime.send(.toolProgress(id: callID, progress: .text("unobserved")))
        runtime.send(.toolResponse(id: callID, result: .string("done")))

        let result = await events.outputUntilResult()
        #expect(result.errorText == nil)
        #expect(result.texts == ["done"])
    }

    @Test("onProgress rejects a non-function handler with the upstream error")
    func nonFunctionHandlerIsRejected() async throws {
        let (runtime, events) = try startProgressRuntime(
            """
            const pending = tools.demo({});
            try {
              pending.onProgress(42);
            } catch (error) {
              text(String(error));
            }
            try {
              pending.onProgress({ call() {} });
            } catch (error) {
              text(String(error));
            }
            await pending;
            """
        )
        defer { runtime.beginTermination() }

        let callID = try await nextProgressToolID(events)
        runtime.send(.toolResponse(id: callID, result: .null))

        let result = await events.outputUntilResult()
        #expect(result.errorText == nil)
        #expect(result.texts == [
            "onProgress expects a handler function",
            "onProgress expects a handler function",
        ])
    }

    @Test("progress for unknown and already-resolved calls fails closed")
    func staleProgressCannotReachAnotherInvocation() async throws {
        let (runtime, events) = try startProgressRuntime(
            """
            const first = tools.demo({});
            first.onProgress((chunk) => text("first:" + chunk.text));
            await first;

            const second = tools.demo({});
            second.onProgress((chunk) => text("second:" + chunk.text));
            await second;
            text("done");
            """
        )
        defer { runtime.beginTermination() }

        let firstID = try await nextProgressToolID(events)
        runtime.send(.toolProgress(id: "tool-404", progress: .text("unknown")))
        runtime.send(.toolResponse(id: firstID, result: .null))

        let secondID = try await nextProgressToolID(events)
        runtime.send(.toolProgress(id: firstID, progress: .text("stale")))
        runtime.send(.toolProgress(id: secondID, progress: .text("live")))
        runtime.send(.toolResponse(id: secondID, result: .null))

        let result = await events.outputUntilResult()
        #expect(result.errorText == nil)
        #expect(result.texts == ["second:live", "done"])
    }

    @Test("progress commands preserve their payload through worker Codable transport")
    func progressCommandRoundTripsThroughWorkerTransport() throws {
        let progress = NestedToolProgress.withPayload(
            "stream",
            .object(["blocks": .array([.string("first")])])
        )
        let command = JavaScriptRuntimeCommand.toolProgress(id: "tool-7", progress: progress)
        let encoded = try JSONEncoder().encode(command)
        let decoded = try JSONDecoder().decode(JavaScriptRuntimeCommand.self, from: encoded)

        guard case .toolProgress(let id, let decodedProgress) = decoded else {
            Issue.record("worker transport decoded the wrong runtime command")
            return
        }
        #expect(id == "tool-7")
        #expect(decodedProgress == progress)
    }
}

#endif
