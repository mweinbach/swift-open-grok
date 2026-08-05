// PagerPTYSessionTests.swift
//
// Scenarios driven through `PagerPTYSession` — the incremental half of the
// harness, where a scenario writes, watches the screen react, and only then
// writes again.
//
// This file deliberately needs no model: it pins the drive/observe mechanics
// that the inference-backed scenarios are built on, so a regression in the
// session plumbing is diagnosed here rather than inside a streaming exchange.
//
// Every scenario skips when the product binary is absent, matching the
// `.enabled(if:)` pattern the rest of the suite uses, so a bare `swift test`
// without `swift build --product open-grok` reports honestly.

import Foundation
import Testing

import OpenGrokPagerPTYHarness
import OpenGrokPTY
import OpenGrokTTY

@Suite("open-grok driven incrementally under a PTY")
struct PagerPTYSessionTests {
    private func makeHarness() -> PagerPTYHarness {
        PagerPTYHarness(size: TerminalSize(width: 100, height: 30), timeoutSeconds: 60)
    }

    /// The interactive TUI refuses to start without a credential ("XAI_API_KEY
    /// or `open-grok login` is required for provider xai"), so a scenario that
    /// wants a painted screen must supply one.
    ///
    /// The base URL is aimed at a closed port through the seam
    /// (`GROK_XAI_API_BASE_URL`): these scenarios never send a turn, and a dead
    /// endpoint guarantees that a regression which *did* send one cannot reach
    /// the real xAI API from a test run.
    private func makeInteractiveHarness() -> PagerPTYHarness {
        PagerPTYHarness(
            size: TerminalSize(width: 100, height: 30),
            timeoutSeconds: 60,
            environment: [
                "XAI_API_KEY": "test-key-for-ci",
                "GROK_XAI_API_BASE_URL": "http://127.0.0.1:1/v1",
                "GROK_CLI_CHAT_PROXY_BASE_URL": "http://127.0.0.1:1/v1"
            ]
        )
    }

    /// The interactive TUI has to come up, paint, and then quit on `/quit`.
    /// Waiting for the banner *before* sending the command is the whole point
    /// of the session API: `run` would have written `/quit` into a terminal
    /// that had not finished starting.
    @Test(
        "an interactive session paints, then quits on /quit",
        .enabled(if: PagerPTYHarness.binaryIsAvailable())
    )
    func interactiveSessionQuits() async throws {
        let session = try await makeInteractiveHarness().start(arguments: [])
        defer { try? FileManager.default.removeItem(at: session.sandbox) }

        // The composer's placeholder, which only exists once the TUI has
        // painted a full frame.
        let painted = try await session.waitForScreen(
            containing: "Build anything",
            timeoutSeconds: 30
        )
        #expect(painted, "the interactive TUI must paint its composer")

        try await session.write("/quit\r")
        let result = try await session.finish(timeoutSeconds: 30)
        #expect(result.exit == .code(0))
    }

    /// `waitForScreen` must report honestly rather than hang: text the CLI
    /// never prints has to come back `false` inside the budget.
    @Test(
        "waitForScreen returns false for text that never appears",
        .enabled(if: PagerPTYHarness.binaryIsAvailable())
    )
    func waitForScreenTimesOutHonestly() async throws {
        let session = try await makeHarness().start(arguments: ["--version"])
        defer { try? FileManager.default.removeItem(at: session.sandbox) }

        let sawNonsense = try await session.waitForScreen(
            containing: "this string is never rendered",
            timeoutSeconds: 2
        )
        #expect(sawNonsense == false)

        let result = try await session.finish(timeoutSeconds: 30)
        #expect(result.exit == .code(0))
        // The same run still captured what the binary really printed.
        #expect(result.screen.containsInAnyRow("Open Grok"))
    }

    /// `terminate()` is the escape hatch for a child that must not be waited
    /// on, and it must be safe to call on an already-finished session.
    @Test(
        "terminate is safe after a session has finished",
        .enabled(if: PagerPTYHarness.binaryIsAvailable())
    )
    func terminateAfterFinishIsSafe() async throws {
        let session = try await makeHarness().start(arguments: ["--version"])
        defer { try? FileManager.default.removeItem(at: session.sandbox) }

        let result = try await session.finish(timeoutSeconds: 30)
        #expect(result.exit == .code(0))
        await session.terminate()
    }
}
