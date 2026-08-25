import Foundation
import OpenGrokCodeModeProtocol
import OpenGrokShared
import Testing

@testable import OpenGrokJavaScriptRuntime

private struct PortableRuntimeObservation {
    let texts: [String]
    let storedWrites: [String: JSONValue]
    let yieldCount: Int
    let errorText: String?
}

private enum PortableRuntimeObservationError: Error {
    case closedWithoutResult
    case missingToolCall
    case missingStartEvent
}

private final class PortableRuntimeEvents {
    private var iterator: AsyncStream<JavaScriptRuntimeEvent>.AsyncIterator

    init(_ events: AsyncStream<JavaScriptRuntimeEvent>) {
        iterator = events.makeAsyncIterator()
    }

    func next() async -> JavaScriptRuntimeEvent? {
        await iterator.next()
    }

    func result() async throws -> PortableRuntimeObservation {
        var texts: [String] = []
        var yieldCount = 0

        while let event = await next() {
            switch event {
            case .contentItem(.inputText(let text)):
                texts.append(text)
            case .yieldRequested:
                yieldCount += 1
            case .result(let storedWrites, let errorText):
                return PortableRuntimeObservation(
                    texts: texts,
                    storedWrites: storedWrites,
                    yieldCount: yieldCount,
                    errorText: errorText
                )
            default:
                continue
            }
        }

        throw PortableRuntimeObservationError.closedWithoutResult
    }

    func nextToolCall() async throws -> (id: String, name: ToolName) {
        while let event = await next() {
            switch event {
            case .started, .pending:
                continue
            case .toolCall(let id, let name, _, _):
                return (id, name)
            default:
                Issue.record("expected a nested tool call, got \(event)")
                throw PortableRuntimeObservationError.missingToolCall
            }
        }

        throw PortableRuntimeObservationError.missingToolCall
    }
}

private func portableRuntime(
    source: String,
    tools: [EnabledToolMetadata] = [],
    executionCeilingMs: UInt64 = CODE_MODE_DEFAULT_EXECUTION_CEILING_MS
) throws -> (runtime: JavaScriptCellRuntime, events: PortableRuntimeEvents) {
    let (runtime, events) = try JavaScriptCellRuntime.start(
        configuration: JavaScriptCellConfiguration(
            toolCallId: "portable-runtime-parity",
            enabledTools: tools,
            source: source,
            executionCeilingMs: executionCeilingMs
        ),
        pendingMode: .continueImmediately
    )
    return (runtime, PortableRuntimeEvents(events))
}

@Suite("Portable JavaScript runtime security parity")
struct PortableJavaScriptSecurityParityTests {
    /// Rust runtime/globals.rs:14-45 installs only explicit host callbacks.
    @Test("ambient process, filesystem, networking, and shared-memory globals stay inaccessible")
    func ambientHostCapabilitiesAreUnavailable() async throws {
        let (runtime, events) = try portableRuntime(
            source: """
                const ambient = [
                  "process", "require", "module", "exports", "Deno", "Bun",
                  "fetch", "XMLHttpRequest", "WebSocket", "fs", "console",
                  "Atomics", "SharedArrayBuffer", "WebAssembly"
                ];
                text(JSON.stringify(ambient.map((name) => [name, typeof globalThis[name]])));
                """
        )
        defer { runtime.beginTermination() }

        let result = try await events.result()
        #expect(result.errorText == nil)
        let output = try #require(result.texts.first)
        let observed = try JSONDecoder().decode([[String]].self, from: Data(output.utf8))
        #expect(observed.count == 14)
        for item in observed {
            #expect(item.count == 2)
            #expect(item.last == "undefined", "ambient host global \(item.first ?? "?") escaped")
        }
    }

    @Test("recovering the global object through Function cannot expose host capabilities")
    func functionConstructorCannotRecoverAmbientCapabilities() async throws {
        let (runtime, events) = try portableRuntime(
            source: """
                const recovered = ({}).constructor.constructor("return globalThis")();
                const names = ["process", "require", "fetch", "WebSocket"];
                text(String(names.every((name) => typeof recovered[name] === "undefined")));
                """
        )
        defer { runtime.beginTermination() }

        let result = try await events.result()
        #expect(result.errorText == nil)
        #expect(result.texts == ["true"])
    }

    /// Rust runtime/module_loader.rs:177-220 rejects dynamic imports even
    /// when the specifier is computed after parsing.
    @Test(
        "computed dynamic imports cannot load process or filesystem modules",
        arguments: ["node:fs", "node:child_process", "./private.mjs"]
    )
    func computedDynamicImportsFailClosed(_ specifier: String) async throws {
        let encoded = try #require(
            String(data: JSONEncoder().encode(specifier), encoding: .utf8)
        )
        let (runtime, events) = try portableRuntime(
            source: """
                const specifier = \(encoded).split("").join("");
                try {
                  await import(specifier);
                  text("loaded:" + specifier);
                } catch (error) {
                  text("rejected:" + specifier);
                }
                """
        )
        defer { runtime.beginTermination() }

        let result = try await events.result()
        #expect(result.errorText == nil)
        #expect(result.texts == ["rejected:\(specifier)"])
    }

    /// The existing JavaScriptCore adapter rejects export declarations
    /// before evaluation; the portable backend must preserve that contract.
    @Test(
        "export declarations remain rejected on every embedded backend",
        arguments: [
            "export const answer = 42;",
            "export default 42;",
            "export { answer } from './private.mjs';",
        ]
    )
    func exportDeclarationsFailClosed(_ source: String) async throws {
        let (runtime, events) = try portableRuntime(source: source)
        defer { runtime.beginTermination() }

        let result = try await events.result()
        let error = try #require(result.errorText)
        #expect(error.hasPrefix("Unsupported import in exec:"))
        #expect(result.texts.isEmpty)
    }
}

@Suite("Portable JavaScript runtime host parity")
struct PortableJavaScriptHostParityTests {
    @Test("top-level await composes timers, cancellation, state writes, yield, and output")
    func hostCallbacksComposeAcrossAnAwaitBoundary() async throws {
        let (runtime, events) = try portableRuntime(
            source: """
                store("portable", { count: 41 });
                const cancelled = setTimeout(() => text("unexpected timer"), 0);
                clearTimeout(cancelled);
                await new Promise((resolve) => setTimeout(resolve, 1));
                store("portable", { count: load("portable").count + 1 });
                yield_control();
                text(JSON.stringify(load("portable")));
                """
        )
        defer { runtime.beginTermination() }

        let result = try await events.result()
        #expect(result.errorText == nil)
        #expect(result.texts == [#"{"count":42}"#])
        #expect(result.yieldCount == 1)
        #expect(result.storedWrites == [
            "portable": .object(["count": .number(.int64(42))])
        ])
    }

    /// Rust runtime/callbacks.rs:70-76 and :138-167 scope progress to the
    /// originating unresolved promise, including concurrent invocations.
    @Test("concurrent nested promises keep progress and results scoped to their own call IDs")
    func concurrentToolCallsPreserveProgressIsolation() async throws {
        let tools = ["left", "right"].map { name in
            EnabledToolMetadata(
                toolName: .plain(name),
                globalName: name,
                description: "portable \(name) tool",
                kind: .function
            )
        }
        let (runtime, events) = try portableRuntime(
            source: """
                const left = tools.left({ side: "left" });
                const right = tools.right({ side: "right" });
                left.onProgress((chunk) => text("left:" + chunk.text));
                right.onProgress((chunk) => text("right:" + chunk.text));
                text(JSON.stringify(await Promise.all([left, right])));
                """,
            tools: tools
        )
        defer { runtime.beginTermination() }

        let first = try await events.nextToolCall()
        let second = try await events.nextToolCall()
        let calls = [first, second]
        let left = try #require(calls.first { $0.name == .plain("left") })
        let right = try #require(calls.first { $0.name == .plain("right") })
        #expect(left.id != right.id)

        runtime.send(.toolProgress(id: right.id, progress: .text("right-chunk")))
        runtime.send(.toolProgress(id: left.id, progress: .text("left-chunk")))
        runtime.send(.toolResponse(id: right.id, result: .string("right-result")))
        runtime.send(.toolResponse(id: left.id, result: .string("left-result")))

        let result = try await events.result()
        #expect(result.errorText == nil)
        #expect(result.texts == [
            "right:right-chunk",
            "left:left-chunk",
            #"["left-result","right-result"]"#,
        ])
    }
}

#if !canImport(JavaScriptCore)

@Suite("QuickJS isolate teardown memory safety")
struct QuickJSIsolateTeardownSafetyTests {
    private let tool = EnabledToolMetadata(
        toolName: .plain("teardown_probe"),
        globalName: "teardown_probe",
        description: "exercises host callback and pending-promise ownership",
        kind: .function
    )

    /// QuickJS 0.15.1 asynchronous ES modules retain internal module values
    /// inside C-function closures. Abandoning an unresolved module used to
    /// free that value before its closure and abort during JS_FreeRuntime.
    /// Constructing engines directly makes teardown synchronous and keeps a
    /// worker-process exit from concealing allocator corruption.
    @Test("completed and abandoned top-level awaits safely destroy repeated isolates")
    func repeatedlyDisposesResolvedAndPendingIsolates() throws {
        for round in 0..<32 {
            try disposeIsolate(round: round, leavingPendingTool: false)
            try disposeIsolate(round: round, leavingPendingTool: true)
        }
    }

    private func disposeIsolate(round: Int, leavingPendingTool: Bool) throws {
        let source: String
        if leavingPendingTool {
            source = """
                const invocation = tools.teardown_probe({ round: \(round) });
                invocation.onProgress((chunk) => text(chunk.text));
                await invocation;
                """
        } else {
            source = """
                store("round", \(round));
                await Promise.resolve();
                text(String(load("round")));
                """
        }

        var observed: [JavaScriptRuntimeEvent] = []
        let mailbox = JavaScriptRuntimeMailbox<JavaScriptRuntimeCommand>()
        var engine: QuickJSCellEngine? = try #require(QuickJSCellEngine(
            configuration: JavaScriptCellConfiguration(
                toolCallId: "teardown-\(round)",
                enabledTools: [tool],
                source: source
            ),
            commands: mailbox,
            emit: { observed.append($0) }
        ))

        #expect(engine?.installGlobals() == nil)
        #expect(engine?.evaluateSource() == nil)
        if leavingPendingTool {
            #expect(observed.contains { event in
                if case .toolCall = event { return true }
                return false
            })
            #expect(engine?.takeCompletion() == nil)
        } else {
            let completion = try #require(engine?.takeCompletion())
            #expect(completion.errorText == nil)
            #expect(observed.contains { event in
                if case .contentItem(.inputText(let text)) = event {
                    return text == String(round)
                }
                return false
            })
        }

        engine = nil
    }
}

@Suite("QuickJS hard-interrupt parity")
struct QuickJSHardInterruptParityTests {
    /// Rust runtime/mod.rs:397 terminates an unbounded V8 entry immediately.
    /// JavaScriptCore cannot safely run this probe under swiftpm-testing-helper.
    @Test("an unbounded QuickJS entry terminates immediately instead of waiting for its ceiling")
    func immediatelyInterruptsInfiniteLoop() async throws {
        let (runtime, events) = try portableRuntime(
            source: "while (true) {}",
            executionCeilingMs: 60_000
        )
        defer { runtime.beginTermination() }

        guard case .started = await events.next() else {
            throw PortableRuntimeObservationError.missingStartEvent
        }

        let started = ContinuousClock.now
        runtime.beginTermination()
        if let event = await events.next() {
            Issue.record("expected the interrupted runtime to close, got \(event)")
        }
        #expect(ContinuousClock.now - started < .seconds(1))
    }
}

#endif
