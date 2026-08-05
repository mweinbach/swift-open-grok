// OpenGrokPagerPTYTests.swift
//
// End-to-end scenarios driven through `PagerPTYHarness`: a real `open-grok`
// process, a real PTY, and assertions against the reconstructed screen.
//
// Only the scenarios that need no model are here. See the SCOPE note at the
// top of `Sources/OpenGrokPagerPTYHarness/OpenGrokPagerPTYHarness.swift` for
// why the inference-backed half of PORT_PLAN W11-S3 is not yet implemented.
//
// Every scenario skips when the product binary is absent, so a bare
// `swift test` without `swift build --product open-grok` reports honestly
// rather than failing on a missing file.

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

@Suite("Virtual screen")
struct VirtualScreenTests {
    @Test("printable text and newlines land on the grid")
    func plainText() {
        var screen = VirtualScreen(width: 10, height: 3)
        screen.feed("hello\nworld")
        #expect(screen.lines == ["hello", "world", ""])
        #expect(screen.text == "hello\nworld")
    }

    @Test("carriage return overwrites the current row")
    func carriageReturn() {
        var screen = VirtualScreen(width: 10, height: 2)
        screen.feed("loading...\rdone")
        #expect(screen.lines[0] == "doneing...")
    }

    @Test("cursor positioning and erase-in-display are honoured")
    func cursorAndErase() {
        var screen = VirtualScreen(width: 10, height: 3)
        screen.feed("aaa\nbbb\nccc")
        screen.feed("\u{1B}[2J\u{1B}[1;1H")
        #expect(screen.text.isEmpty)
        screen.feed("top")
        #expect(screen.lines[0] == "top")
    }

    @Test("erase-in-line clears from the cursor to the end of the row")
    func eraseInLine() {
        var screen = VirtualScreen(width: 10, height: 1)
        screen.feed("abcdefgh")
        screen.feed("\u{1B}[4G\u{1B}[0K")
        #expect(screen.lines[0] == "abc")
    }

    /// SGR colour runs and OSC title strings must be consumed whole; leaking
    /// any part of them into the grid would corrupt every assertion made
    /// against a real CLI's output.
    @Test("styling and OSC sequences leave no residue")
    func escapesAreConsumed() {
        var screen = VirtualScreen(width: 20, height: 1)
        screen.feed("\u{1B}[1;31mred\u{1B}[0m")
        #expect(screen.lines[0] == "red")

        var withTitle = VirtualScreen(width: 20, height: 1)
        withTitle.feed("\u{1B}]0;a window title\u{07}text")
        #expect(withTitle.lines[0] == "text")

        var withST = VirtualScreen(width: 20, height: 1)
        withST.feed("\u{1B}]0;title\u{1B}\\text")
        #expect(withST.lines[0] == "text")
    }

    @Test("output longer than the screen scrolls the top away")
    func scrolling() {
        var screen = VirtualScreen(width: 5, height: 2)
        screen.feed("one\ntwo\nthree")
        #expect(screen.lines == ["two", "three"])
    }

    @Test("writing past the right edge wraps to the next row")
    func wrapping() {
        var screen = VirtualScreen(width: 3, height: 2)
        screen.feed("abcdef")
        #expect(screen.lines == ["abc", "def"])
    }

    @Test("private mode toggles never touch the grid")
    func privateModes() {
        var screen = VirtualScreen(width: 10, height: 2)
        screen.feed("\u{1B}[?25l\u{1B}[?1049hkept\u{1B}[?25h")
        #expect(screen.lines[0] == "kept")
    }
}
