// OpenGrokPagerPTYTests.swift
//
// End-to-end scenarios driven through `PagerPTYHarness`: a real `open-grok`
// process, a real PTY, and assertions against the reconstructed screen.
//
// Only the scenarios that need no model are here. The inference-backed half of
// PORT_PLAN W11-S3 lives in `InferencePTYScenarioTests.swift`, and the
// incremental drive/observe mechanics those depend on are pinned in
// `PagerPTYSessionTests.swift`.
//
// Ordinary scenarios skip when the product binary is absent, so a bare
// `swift test` without `swift build --product open-grok` reports honestly
// rather than failing on a missing file. CI runs the ungated canary below so
// the supported product-under-PTY path cannot disappear behind those skips.

import Foundation
import Testing

import OpenGrokPagerPTYHarness
import OpenGrokPTY
import OpenGrokTTY

@Suite("open-grok under a PTY")
struct PagerPTYScenarioTests {
    private func makeHarness() -> PagerPTYHarness {
        PagerPTYHarness(size: TerminalSize(width: 100, height: 30), timeoutSeconds: 60)
    }

#if os(macOS) || os(Linux)
    @Test(
        "CI executes the open-grok product under a PTY",
        .enabled(if: ProcessInfo.processInfo.environment["CI"] == "1")
    )
    func ciProductUnderPTYCanary() async throws {
        let binaryAvailable = PagerPTYHarness.binaryIsAvailable()
        #expect(
            binaryAvailable,
            "CI PTY canary requires an executable open-grok product at \(PagerPTYHarness.defaultBinaryPath())"
        )
        guard binaryAvailable else { return }

        let result = try await makeHarness().run(arguments: ["--version"])
        defer { try? FileManager.default.removeItem(at: result.sandbox) }

        #expect(result.exit == .code(0))
        #expect(
            result.screen.containsInAnyRow("Open Grok"),
            Comment(rawValue: String(decoding: result.rawOutput, as: UTF8.self))
        )
    }
#endif

    @Test(
        "version renders on the terminal and exits zero",
        .enabled(if: PagerPTYHarness.binaryIsAvailable())
    )
    func versionScenario() async throws {
        let result = try await makeHarness().run(arguments: ["--version"])
        defer { try? FileManager.default.removeItem(at: result.sandbox) }

        #expect(result.exit == .code(0))
        #expect(result.screen.containsInAnyRow("Open Grok"))
    }

    /// The CLI must not read the developer's real `~/.opengrok`: the harness
    /// points `HOME` and `OPENGROK_HOME` at a fresh directory, and `paths`
    /// prints what it resolved, so the isolation is directly observable.
    @Test(
        "the run is isolated from real ~/.opengrok state",
        .enabled(if: PagerPTYHarness.binaryIsAvailable())
    )
    func isolationScenario() async throws {
        let result = try await makeHarness().run(arguments: ["paths"])
        defer { try? FileManager.default.removeItem(at: result.sandbox) }

        #expect(result.exit == .code(0))
        #expect(result.screen.containsInAnyRow("OPENGROK_HOME"))
        // The developer's real config directory must never appear.
        #expect(!result.text.contains(NSHomeDirectory() + "/.opengrok"))
    }

    /// `mcp list` is a synchronous CLI route, so it exercises the whole
    /// parse → config-load → render path end to end under a PTY with no model
    /// involved. With an empty isolated home there are no servers to list.
    @Test(
        "mcp list runs against an empty isolated config",
        .enabled(if: PagerPTYHarness.binaryIsAvailable())
    )
    func mcpListScenario() async throws {
        let result = try await makeHarness().run(arguments: ["mcp", "list"])
        defer { try? FileManager.default.removeItem(at: result.sandbox) }

        #expect(result.exit == .code(0))
        #expect(result.screen.containsInAnyRow("No MCP servers configured."))
    }

    /// `mcp add` then `mcp remove` proves the config *write* path lands on
    /// disk, in a file a separate process can read back.
    @Test(
        "mcp add writes a server entry and remove takes it away",
        .enabled(if: PagerPTYHarness.binaryIsAvailable())
    )
    func mcpAddThenRemoveScenario() async throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("PTYScenario-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let config = sandbox.appendingPathComponent("config.toml")

        let harness = makeHarness()
        let added = try await harness.run(
            arguments: ["mcp", "add", "docs", "--config", config.path, "--command", "true"]
        )
        defer { try? FileManager.default.removeItem(at: added.sandbox) }
        #expect(added.exit == .code(0))
        #expect(added.screen.containsInAnyRow("docs"))

        let written = try String(contentsOf: config, encoding: .utf8)
        #expect(written.contains("[mcp_servers.docs]"))
        #expect(written.contains("command = \"true\""))

        let removed = try await harness.run(
            arguments: ["mcp", "remove", "docs", "--config", config.path]
        )
        defer { try? FileManager.default.removeItem(at: removed.sandbox) }
        #expect(removed.exit == .code(0))
        let after = try String(contentsOf: config, encoding: .utf8)
        #expect(!after.contains("mcp_servers"))
    }

    /// A bad subcommand must exit non-zero rather than appearing to succeed.
    @Test(
        "an unknown command exits non-zero",
        .enabled(if: PagerPTYHarness.binaryIsAvailable())
    )
    func usageErrorScenario() async throws {
        let result = try await makeHarness().run(arguments: ["definitely-not-a-command"])
        defer { try? FileManager.default.removeItem(at: result.sandbox) }
        #expect(result.exit != .code(0))
    }
}
