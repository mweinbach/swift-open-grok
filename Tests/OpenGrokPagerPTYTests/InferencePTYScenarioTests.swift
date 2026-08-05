// InferencePTYScenarioTests.swift
//
// The inference-backed half of PORT_PLAN W11-S3: a real `open-grok` process
// under a real PTY, talking to a local mock chat-completions server through the
// provider base-URL seam, with assertions against the reconstructed screen.
//
// The seam is `GROK_XAI_API_BASE_URL`, which upstream reads in
// `impl Default for EndpointsConfig` (`xai-grok-shell/src/agent/config.rs:622`)
// and which `LiveComposition.resolveProviderBaseURL` honours here. Nothing in
// these scenarios can reach the real xAI API: the base URL points at a server
// this process started, and the API key is a fixture string.
//
// Every scenario skips when the product binary is absent, matching the
// `.enabled(if:)` pattern the rest of the suite uses — a bare `swift test`
// without `swift build --product open-grok` reports skips, never false green.

import Foundation
import Testing

import OpenGrokPagerPTYHarness
import OpenGrokPTY
import OpenGrokTestSupport
import OpenGrokTTY

@Suite("open-grok against a mock inference endpoint")
struct InferencePTYScenarioTests {
    /// Deliberately plain prose: no markdown, so the renderer cannot reflow or
    /// decorate it into something the screen assertion would miss.
    private static let replyText = "The mock endpoint answered this turn.\n"

    /// Point the spawned binary at `server` through the base-URL seam.
    ///
    /// `GROK_CLI_CHAT_PROXY_BASE_URL` goes along for the ride so no auxiliary
    /// call escapes to the network either, matching what
    /// `TestEnv.applyTestEnv` does for the non-PTY harnesses.
    private func harness(server: MockInferenceServer) -> PagerPTYHarness {
        PagerPTYHarness(
            size: TerminalSize(width: 100, height: 30),
            timeoutSeconds: 120,
            environment: [
                "GROK_XAI_API_BASE_URL": server.url,
                "GROK_CLI_CHAT_PROXY_BASE_URL": server.url,
                "XAI_API_KEY": "test-key-for-ci"
            ]
        )
    }

    /// One full interactive exchange: the TUI paints, a prompt is typed, the
    /// streamed reply lands on the screen, and `/quit` exits cleanly.
    ///
    /// This has to be driven with `PagerPTYSession` rather than
    /// `PagerPTYHarness.run`, which writes all of its input up front — the
    /// `/quit` would race the reply it is meant to let finish.
    @Test(
        "an interactive turn streams the model reply onto the terminal",
        .enabled(if: PagerPTYHarness.binaryIsAvailable())
    )
    func interactiveTurnRendersStreamedReply() async throws {
        let server = try MockInferenceServer()
        defer { server.stop() }
        server.setResponse(Self.replyText)

        let session = try await harness(server: server).start(arguments: [])
        defer { try? FileManager.default.removeItem(at: session.sandbox) }

        let painted = try await session.waitForScreen(
            containing: "Build anything",
            timeoutSeconds: 60
        )
        #expect(painted, "the interactive TUI must paint before a prompt is typed")

        // A PTY in canonical mode takes CR as the line terminator.
        try await session.write("hello from the harness\r")

        let rendered = try await session.waitForScreen(
            containing: "The mock endpoint answered this turn.",
            timeoutSeconds: 60
        )
        #expect(rendered, "the streamed reply must reach the screen")

        try await session.write("/quit\r")
        let result = try await session.finish(timeoutSeconds: 60)

        #expect(result.exit == .code(0))
        // The prompt really travelled to the endpoint, so this is an exchange
        // rather than a screen that happened to contain the right words. The
        // default model is Responses-backed, so the turn lands on /v1/responses.
        #expect(
            server.hasResponsesRequest(),
            Comment(rawValue: server.requestLogSummary())
        )
    }

    /// The headless streaming-json variant of the same exchange, asserting the
    /// emitted event lines instead of rendered frames.
    ///
    /// `run` is the right driver here: `headless` consumes its prompt from the
    /// command line and exits on its own, so there is nothing to interleave.
    @Test(
        "headless streaming-json emits output and completed events for a turn",
        .enabled(if: PagerPTYHarness.binaryIsAvailable())
    )
    func headlessStreamingJSONEmitsEvents() async throws {
        let server = try MockInferenceServer()
        defer { server.stop() }
        server.setResponse(Self.replyText)

        let result = try await harness(server: server).run(
            arguments: [
                "headless",
                "--prompt", "hello from the harness",
                "--output-format", "streaming-json"
            ]
        )
        defer { try? FileManager.default.removeItem(at: result.sandbox) }

        let diagnostic = Comment(rawValue: String(decoding: result.rawOutput, as: UTF8.self))
        #expect(result.exit == .code(0), diagnostic)
        #expect(server.hasResponsesRequest(), Comment(rawValue: server.requestLogSummary()))

        // Assert on the raw stream, not the screen: these are protocol lines,
        // and the 100-column screen would wrap them. The PTY's ONLCR turns
        // every `\n` into `\r\n`, so the CR has to come off first.
        let records = Self.jsonLines(in: result.rawOutput)
        #expect(records.isEmpty == false, diagnostic)

        let outputText = records
            .filter { $0["type"] as? String == "output" }
            .compactMap { $0["content"] as? String }
            .joined()
        #expect(
            outputText.contains("The mock endpoint answered this turn."),
            "output events must carry the streamed reply"
        )
        #expect(
            records.contains { $0["type"] as? String == "completed" },
            "the turn must end with a completed event"
        )
    }

    /// Parse the JSON objects out of a PTY byte stream, one per line.
    ///
    /// Splits on the LF *byte* rather than on a `Character`: the PTY's ONLCR
    /// turns every `\n` into `\r\n`, and Swift models `"\r\n"` as one
    /// `Character`, so `split(separator: "\n")` over a `String` matches
    /// nothing and silently yields a single unparseable blob.
    private static func jsonLines(in raw: Data) -> [[String: Any]] {
        raw.split(separator: UInt8(ascii: "\n"))
            .map { line -> Data in
                line.last == UInt8(ascii: "\r") ? Data(line.dropLast()) : Data(line)
            }
            .filter { $0.first == UInt8(ascii: "{") }
            .compactMap { line in
                let parsed = try? JSONSerialization.jsonObject(with: line)
                return parsed as? [String: Any]
            }
    }
}
