// ACPStdioWireGoldenTests.swift
//
// Byte-level goldens for what `agent stdio` puts on the wire.
//
// The behavior tests in `ACPStdioHostTests` assert on decoded messages, which
// would keep passing if the encoding drifted — a renamed key or a changed
// `stopReason` spelling breaks real clients while leaving those assertions
// green. These pin the actual lines.
//
// The corpus is embedded in source rather than kept as a file, matching
// `Tests/OpenGrokACPTests/ACPWireCorpusFixture.swift`, so it needs no
// Package.swift resource registration.
//
// Determinism comes from injecting `makeSessionId` and `timestamp` into
// `ACPAgentRuntime`, which are the only two nondeterministic inputs on this
// path. The `initialize` response is deliberately NOT byte-pinned: it carries
// `agentInfo.version`, which the OpenGrokVersion build plugin stamps from the
// environment, so a byte golden there would fail on any versioned build.

import Foundation
import OpenGrokACP
import OpenGrokShared
import Testing

@testable import OpenGrokACPRuntime

private enum ACPStdioWireGolden {
    static let sessionId = "session-golden-0001"
    static let timestamp = "2024-01-01T00:00:00Z"

    /// Every frame after `initialize`, in the order the agent emits them.
    ///
    /// Note the `session\/update` method names: `ACPMessage.encodedData()`
    /// encodes with `[.sortedKeys]` and does not set `.withoutEscapingSlashes`,
    /// so Foundation escapes forward slashes. That is valid JSON and decodes
    /// identically, but it is exactly the shape upstream's
    /// `normalize_json_line` (`crates/codegen/xai-acp-lib/src/normalize.rs`)
    /// was written to cope with on the ACP 0.6 wire, so it is pinned here
    /// rather than left to chance.
    static let expected: [String] = [
        #"{"id":2,"jsonrpc":"2.0","result":{"sessionId":"session-golden-0001"}}"#,
        #"{"jsonrpc":"2.0","method":"session\/update","params":{"sessionId":"session-golden-0001","update":{"content":{"text":"hello","type":"text"},"sessionUpdate":"user_message_chunk"}}}"#,
        #"{"jsonrpc":"2.0","method":"session\/update","params":{"sessionId":"session-golden-0001","update":{"content":{"text":"pong","type":"text"},"sessionUpdate":"agent_message_chunk"}}}"#,
        // The turn-end broadcast (`x.ai/session/prompt_complete`,
        // acp_agent.rs:2952-2986): the scripted request carries
        // `_meta.promptId`/`_meta.turnId` so the frame is deterministic —
        // an unscripted promptId is a fresh UUID and unpinnable.
        #"{"jsonrpc":"2.0","method":"x.ai\/session\/prompt_complete","params":{"agentResult":null,"promptId":"prompt-golden-0001","sessionId":"session-golden-0001","stopReason":"end_turn","turnId":7}}"#,
        #"{"id":3,"jsonrpc":"2.0","result":{"stopReason":"end_turn"}}"#,
    ]
}

/// Answers with a single fixed chunk so the frames are reproducible.
private struct GoldenPromptDriver: ACPPromptDriver {
    func run(
        context: ACPPromptContext,
        emit: @escaping @Sendable (SessionNotification, ACPNotificationDisposition) async -> Void
    ) async throws -> PromptResponse {
        await emit(
            SessionNotification(
                sessionId: context.session.sessionId,
                update: .agentMessageChunk(ContentChunk(content: .text(TextContent(text: "pong"))))
            ),
            .durable
        )
        return PromptResponse(stopReason: .endTurn)
    }

    func cancel(sessionId: AcpSessionId) async {}
}

/// Feeds scripted lines and captures everything written back.
///
/// After the script runs out it does *not* report EOF immediately: it waits
/// until `expectedWrites` frames have been emitted. Dispatch is concurrent, so
/// returning `nil` the moment the last request was read would close the
/// runtime out from under the prompt that request started.
private final class RecordingLineIO: ACPLineIO, @unchecked Sendable {
    private let lock = NSLock()
    private var inbound: [String]
    private var outbound: [String] = []
    private let expectedWrites: Int

    init(script: [String], expectedWrites: Int) {
        inbound = script
        self.expectedWrites = expectedWrites
    }

    var written: [String] {
        lock.lock()
        defer { lock.unlock() }
        return outbound
    }

    func readLine() async throws -> String? {
        if let line = nextScriptedLine() { return line }
        // Give the in-flight exchange a bounded window to finish. The bound
        // matters: without it a dropped frame would hang instead of failing.
        for _ in 0..<200 {
            if writeCount() >= expectedWrites { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        return nil
    }

    func writeLine(_ line: String) async throws { record(line) }

    func close() async {}

    private func nextScriptedLine() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return inbound.isEmpty ? nil : inbound.removeFirst()
    }

    private func writeCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return outbound.count
    }

    private func record(_ line: String) {
        lock.lock()
        outbound.append(line)
        lock.unlock()
    }
}

@Suite("ACP stdio wire goldens")
struct ACPStdioWireGoldenTests {

    @Test("a scripted exchange produces the exact expected frames")
    func emitsGoldenFrames() async throws {
        let cwd = FileManager.default.temporaryDirectory.standardizedFileURL.path
        let script = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{}}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"\#(cwd)","mcpServers":[]}}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{"sessionId":"\#(ACPStdioWireGolden.sessionId)","prompt":[{"type":"text","text":"hello"}],"_meta":{"promptId":"prompt-golden-0001","turnId":7}}}"#,
        ]
        // initialize + session/new + two notifications + prompt_complete +
        // the prompt response.
        let io = RecordingLineIO(script: script, expectedWrites: 6)
        let runtime = ACPAgentRuntime(
            promptDriver: GoldenPromptDriver(),
            makeSessionId: { ACPStdioWireGolden.sessionId },
            timestamp: { ACPStdioWireGolden.timestamp }
        )

        await ACPStdioHost(runtime: runtime, transport: ACPStdioTransport(io: io)).run()

        let written = io.written
        #expect(written.count == 6)

        // `initialize` carries a build-stamped version, so check its shape.
        let initialize = try #require(written.first)
        let initializeMessage = try ACPMessage(data: Data(initialize.utf8))
        guard case .response(let id, let result, let error) = initializeMessage else {
            Issue.record("first frame was not a response: \(initialize)")
            return
        }
        #expect(id == .number(1))
        #expect(error == nil)
        let response = try #require(result).decode(InitializeResponse.self)
        #expect(try response.protocolVersion == .v1)

        // Everything else is byte-pinned. Responses and notifications can
        // interleave now that dispatch is concurrent, so match as a set.
        let rest = Set(written.dropFirst())
        for frame in ACPStdioWireGolden.expected {
            #expect(rest.contains(frame), "missing golden frame: \(frame)")
        }
    }

    @Test("cancel produces the cancelled stop reason on the wire")
    func cancelStopReasonSpelling() throws {
        let response = PromptResponse(stopReason: .cancelled)
        let encoded = try ACPMessage.response(
            id: .number(4),
            result: try JSONValue.encode(response),
            error: nil
        ).encodedData()
        #expect(
            String(decoding: encoded, as: UTF8.self)
                == #"{"id":4,"jsonrpc":"2.0","result":{"stopReason":"cancelled"}}"#
        )
    }
}
