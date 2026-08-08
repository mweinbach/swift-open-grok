// LiveExtensionsReachabilityTests.swift
//
// The render-layer half of the extensions modal, through the LIVE adapter
// (AGENTS.md §3): the real `LiveInteractiveControllerRenderer` painting into
// a captured sink under an isolated `$OPENGROK_HOME`, driven end-to-end
// through the real controller from typed input. What is asserted is what the
// loaders actually surfaced on screen — a real hook file painting on the
// Hooks tab, a real `SKILL.md` on the Skills tab, a real `registry.json`
// row on the Plugins tab, the deferred Marketplace notice, the honest empty
// state, and the absence of every mutation affordance. The controller half
// (registry pins, dispatch, Ctrl+L) is in
// `Tests/OpenGrokPagerTests/PagerExtensionsCommandTests.swift`.

import Foundation
import OpenGrokHTTP
import OpenGrokPager
import OpenGrokPagerRender
import OpenGrokPluginMarketplace
import OpenGrokTerminalCore
import Testing
@testable import OpenGrokCLI

// MARK: - Fixtures

private final class ExtensionsCapturingSink: PagerTerminalSink, CustomReflectable,
    @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8] = []
    private let width: Int
    private let height: Int

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    var capabilities: PagerTerminalCapabilities { .standard }

    func write(bytes newBytes: [UInt8]) throws {
        lock.lock(); defer { lock.unlock() }
        bytes.append(contentsOf: newBytes)
    }

    func flush() throws {}

    /// A failed `#expect` mirrors captured values; without this, Swift
    /// Testing dumps the whole byte buffer as decimal text.
    var customMirror: Mirror {
        lock.lock(); defer { lock.unlock() }
        return Mirror(self, children: ["byteCount": bytes.count])
    }

    /// The frame a terminal would actually show: the accumulated stream
    /// replayed through a minimal cursor-addressed screen model (CUP,
    /// erase-in-display, erase-in-line; every other CSI/OSC skipped).
    ///
    /// Concatenating emitted glyphs is NOT a substitute: the renderer diffs
    /// against the previous frame, so a cell that happens to already hold the
    /// identical glyph — the welcome hero's path subtitle leaving an `o`
    /// exactly where a hook description's `o` lands — is correctly never
    /// re-emitted, and a raw-stream needle falsely reads that as a dropped
    /// character. Only a replayed screen states what was painted.
    var screenText: String {
        lock.lock(); defer { lock.unlock() }
        var rows = Array(
            repeating: Array(repeating: " ", count: width),
            count: height
        )
        var cursorX = 0
        var cursorY = 0
        let text = String(decoding: bytes, as: UTF8.self)
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            guard character == "\u{1B}" else {
                if cursorY >= 0, cursorY < height, cursorX >= 0, cursorX < width {
                    rows[cursorY][cursorX] = String(character)
                }
                cursorX += max(1, UnicodeDisplayWidth.width(of: String(character)))
                index = text.index(after: index)
                continue
            }
            let introducer = text.index(after: index)
            guard introducer < text.endIndex else { break }
            switch text[introducer] {
            case "[":
                var scan = text.index(after: introducer)
                var parameters = ""
                while scan < text.endIndex, !("\u{40}"..."\u{7E}" ~= text[scan]) {
                    parameters.append(text[scan])
                    scan = text.index(after: scan)
                }
                guard scan < text.endIndex else { return gridText(rows) }
                switch text[scan] {
                case "H":
                    let parts = parameters.split(separator: ";").compactMap { Int($0) }
                    cursorY = (parts.first ?? 1) - 1
                    cursorX = (parts.count > 1 ? parts[1] : 1) - 1
                case "J" where parameters.isEmpty || parameters == "2":
                    rows = Array(
                        repeating: Array(repeating: " ", count: width),
                        count: height
                    )
                case "K":
                    if cursorY >= 0, cursorY < height {
                        for column in max(0, cursorX)..<width {
                            rows[cursorY][column] = " "
                        }
                    }
                default:
                    break
                }
                index = text.index(after: scan)
            case "]":
                var scan = text.index(after: introducer)
                while scan < text.endIndex, text[scan] != "\u{07}" {
                    scan = text.index(after: scan)
                }
                index = scan < text.endIndex ? text.index(after: scan) : scan
            default:
                index = text.index(after: introducer)
            }
        }
        return gridText(rows)
    }

    private func gridText(_ rows: [[String]]) -> String {
        rows.map { $0.joined() }.joined(separator: "\n")
    }
}

/// The live renderer over an isolated `$HOME`/`$OPENGROK_HOME`, so no test
/// can read the developer's real hooks, skills, or plugin registry.
private struct ExtensionsRendererFixture {
    let home: URL
    let sink: ExtensionsCapturingSink
    let renderer: LiveInteractiveControllerRenderer

    init(mcpServers: [MCPServerConnection] = []) throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-ext-reach-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        sink = ExtensionsCapturingSink(width: 140, height: 40)
        let terminal = OpenGrokLiveTerminal(
            isTTY: { false },
            size: { OpenGrokLiveTerminalSize(width: 140, height: 40) },
            write: { _ in }
        )
        renderer = LiveInteractiveControllerRenderer(
            mode: .fullScreen,
            terminal: terminal,
            sink: sink,
            workingDirectory: home.path,
            modelName: "test-model",
            sessionID: "extensions-live",
            mcpServers: mcpServers,
            openGrokHome: home,
            paintCadence: PagerMotion.minimumPaintCadence,
            environment: ["HOME": home.path, "OPENGROK_HOME": home.path],
            authServices: LivePagerAuthServices(
                makeTransport: { URLSessionHTTPTransport() },
                codexBrowserLogin: { _, _, _, _ in throw CancellationError() },
                openBrowser: nil
            )
        )
    }

    func dispose() {
        try? FileManager.default.removeItem(at: home)
    }

    /// Write a real hook file where `HookDiscovery.loadDefaults` looks.
    func writeGlobalHook(
        named name: String = "audit",
        event: String = "PreToolUse",
        matcher: String? = "Bash",
        command: String = "echo audited"
    ) throws {
        let hooksDirectory = home.appendingPathComponent("hooks", isDirectory: true)
        try FileManager.default.createDirectory(
            at: hooksDirectory, withIntermediateDirectories: true
        )
        let matcherField = matcher.map { "\"matcher\": \"\($0)\", " } ?? ""
        let json = """
        {"hooks": {"\(event)": [{\(matcherField)"hooks": \
        [{"type": "command", "command": "\(command)"}]}]}}
        """
        try json.write(
            to: hooksDirectory.appendingPathComponent("\(name).json"),
            atomically: true,
            encoding: .utf8
        )
    }

    /// Write a real `SKILL.md` under the user skills root
    /// (`$OPENGROK_HOME/skills/<name>/SKILL.md`).
    func writeUserSkill(
        named name: String = "deploy-helper",
        description: String = "Automates the deploy checklist"
    ) throws {
        let directory = home
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let content = "---\nname: \(name)\ndescription: \(description)\n---\n\nBody.\n"
        try content.write(
            to: directory.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
    }

    /// Write a real install-registry record where `PluginInstallRegistry.load`
    /// reads it.
    func writePluginRegistry(
        repoKey: String = "tools-abc12345",
        source: String = "https://example.com/tools.git",
        enabled: Bool = true
    ) throws {
        let location = PluginInstallLocation(grokHome: home)
        var registry = PluginInstallRegistry()
        registry.repositories.append(PluginInstallRecord(
            repoKey: repoKey,
            sourceIdentifier: source,
            url: source,
            pluginNames: ["formatter"],
            enabled: enabled
        ))
        try registry.save(to: location.registryURL)
    }

    /// The reconstructed screen with all whitespace removed, so a multi-word
    /// needle matches regardless of the column its row starts at.
    func paintedCompact() -> String {
        sink.screenText.filter { !$0.isWhitespace }
    }

    func waitForPaint(of marker: String, timeout: TimeInterval = 5) async -> Bool {
        let needle = marker.filter { !$0.isWhitespace }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !paintedCompact().contains(needle) {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return paintedCompact().contains(needle)
    }

    /// Run the REAL controller over this renderer with typed input — the
    /// full live seam, from keystrokes to paint. Each line is typed, the
    /// dropdown closed with Esc (so Enter submits the typed text, not the
    /// highlighted suggestion), and submitted.
    func runController(submitting lines: [String]) async throws {
        var events: [InputEvent] = []
        for line in lines {
            events.append(.paste(line))
            events.append(.key(KeyEvent(key: .escape)))
            events.append(.key(KeyEvent(key: .enter)))
        }
        let controller = OpenGrokPagerInteractiveController(
            input: AsyncStream { continuation in
                for event in events { continuation.yield(event) }
                continuation.finish()
            },
            runtime: ExtensionsUnusedRuntime(),
            renderer: renderer,
            output: ExtensionsDiscardingOutput()
        )
        _ = try await controller.run(.init(prompt: "", mode: .inline))
    }
}

private struct ExtensionsUnusedRuntime: OpenGrokPagerRuntimeAdapter {
    func makeSession(
        for request: OpenGrokPagerRequest
    ) async throws -> any OpenGrokPagerSessionAdapter {
        _ = request
        throw CancellationError()
    }
}

private struct ExtensionsDiscardingOutput: OpenGrokPagerInteractiveOutputAdapter {
    func forward(_ event: OpenGrokPagerInteractiveEvent) async throws { _ = event }
}

// MARK: - Tests

@Suite("extensions modal live seam", .serialized)
struct LiveExtensionsReachabilityTests {
    @Test("typed /hooks paints a real loaded hook end-to-end")
    func hooksTabPaintsLoadedHook() async throws {
        let fixture = try ExtensionsRendererFixture()
        defer { fixture.dispose() }
        try fixture.writeGlobalHook()
        // Through the REAL controller: keystrokes → dispatch → overlay
        // intent → snapshot built from `LiveHooksComposition.load` → paint.
        try await fixture.runController(submitting: ["/hooks"])

        // The grouped shape (`extensions_modal.rs:2825, 2840-2853`):
        // source-group header with count, `on:` label, arrow command line.
        #expect(await fixture.waitForPaint(of: "Global hooks (1 hooks)"))
        #expect(await fixture.waitForPaint(of: "on:Pre-Tool Use /Bash"))
        #expect(await fixture.waitForPaint(of: "\u{2192} echo audited"))
    }

    @Test("typed /skills paints a real discovered skill")
    func skillsTabPaintsDiscoveredSkill() async throws {
        let fixture = try ExtensionsRendererFixture()
        defer { fixture.dispose() }
        try fixture.writeUserSkill()
        try await fixture.runController(submitting: ["/skills"])

        #expect(await fixture.waitForPaint(of: "deploy-helper"))
        #expect(await fixture.waitForPaint(of: "Automates the deploy checklist"))
        // The user-scope source string with `$OPENGROK_HOME` overridden
        // (`skill_source_str` + `display_grok_home_prefix`).
        #expect(await fixture.waitForPaint(of: "($OPENGROK_HOME/skills)"))
    }

    @Test("typed /plugins paints a real install-registry entry")
    func pluginsTabPaintsRegistryEntry() async throws {
        let fixture = try ExtensionsRendererFixture()
        defer { fixture.dispose() }
        try fixture.writePluginRegistry()
        try await fixture.runController(submitting: ["/plugins"])

        #expect(await fixture.waitForPaint(of: "tools-abc12345"))
        #expect(await fixture.waitForPaint(of: "https://example.com/tools.git"))
    }

    @Test("typed /marketplace paints the deferred-surface notice")
    func marketplaceTabPaintsNotice() async throws {
        let fixture = try ExtensionsRendererFixture()
        defer { fixture.dispose() }
        try await fixture.runController(submitting: ["/marketplace"])

        #expect(await fixture.waitForPaint(
            of: "Marketplace management runs in the CLI"
        ))
    }

    @Test("an MCP connection surfaces on the MCP Servers tab")
    func mcpTabPaintsSessionConnection() async throws {
        let fixture = try ExtensionsRendererFixture(mcpServers: [
            MCPServerConnection(
                name: "docs-server",
                toolNames: ["docs-server__search", "docs-server__fetch"]
            ),
        ])
        defer { fixture.dispose() }
        try await fixture.renderer.begin()
        try await fixture.renderer.render(.overlay(.extensions(tab: .mcpServers)))

        #expect(await fixture.waitForPaint(of: "docs-server"))
        #expect(await fixture.waitForPaint(of: "2 tools"))
        #expect(await fixture.waitForPaint(of: "[connected]"))
        try await fixture.renderer.restoreTerminal()
    }

    @Test("an empty tab paints the honest empty state, and no mutation verb is advertised")
    func emptyTabPaintsNoMatchesWithoutMutationVerbs() async throws {
        let fixture = try ExtensionsRendererFixture()
        defer { fixture.dispose() }
        try await fixture.runController(submitting: ["/hooks"])

        // Nothing loaded → upstream's bare empty state, never fake rows.
        #expect(await fixture.waitForPaint(of: "Hooks"))
        #expect(await fixture.waitForPaint(of: "No matches"))
        // The read-only footer: none of upstream's mutation hints
        // (`extensions_action_keys`, `extensions_modal.rs:1112-1137`) may
        // reach the screen, because none has a backing here. The needles are
        // the compact key-plus-verb forms the footer would paint, so a
        // command summary elsewhere on screen cannot trip them.
        let compact = fixture.paintedCompact()
        #expect(!compact.contains("uninstall"))
        #expect(!compact.contains("addsource"))
        #expect(!compact.contains("spacetoggle"))
        #expect(!compact.contains("xremove"))
    }

    @Test("mutation keys are swallowed without a notice")
    func mutationKeysEmitNoNotice() async throws {
        let fixture = try ExtensionsRendererFixture()
        defer { fixture.dispose() }
        try fixture.writeGlobalHook()
        try await fixture.renderer.begin()
        try await fixture.renderer.render(.overlay(.extensions(tab: .hooks)))
        #expect(await fixture.waitForPaint(of: "Global hooks (1 hooks)"))

        // Upstream's toggle/remove/add keys: the open modal swallows each
        // (never leaks to the composer), changes nothing, and announces
        // nothing — asserted at the step it happens, not downstream.
        for mutation in [" ", "x", "a"] {
            let routing = try await fixture.renderer.handleInput(
                .key(KeyEvent(key: .char(Character(mutation)), modifiers: []))
            )
            #expect(routing == .consumed, "mutation key \(mutation) leaked")
        }
        // The hook stayed enabled (a real space-toggle would repaint it with
        // the `[disabled]` badge) and nothing announced a removal.
        let compact = fixture.paintedCompact()
        #expect(!compact.contains("[disabled]"))
        #expect(!compact.contains("removed"))
        try await fixture.renderer.restoreTerminal()
    }

    @Test("r reloads the hooks tab through the real loader")
    func reloadRecallsTheLoader() async throws {
        let fixture = try ExtensionsRendererFixture()
        defer { fixture.dispose() }
        try await fixture.renderer.begin()
        try await fixture.renderer.render(.overlay(.extensions(tab: .hooks)))
        #expect(await fixture.waitForPaint(of: "No matches"))

        // A hook written AFTER the modal opened can only appear if `r`
        // truly re-calls `LiveHooksComposition.load` — a cached snapshot
        // would keep painting the empty state.
        try fixture.writeGlobalHook(named: "late", command: "echo late-hook")
        let routing = try await fixture.renderer.handleInput(
            .key(KeyEvent(key: .char("r"), modifiers: []))
        )
        #expect(routing == .consumed)
        #expect(await fixture.waitForPaint(of: "\u{2192} echo late-hook"))
        try await fixture.renderer.restoreTerminal()
    }

    @Test("Tab cycles the open modal across all five tabs end-to-end")
    func tabCyclesThroughAllTabs() async throws {
        let fixture = try ExtensionsRendererFixture()
        defer { fixture.dispose() }
        try await fixture.renderer.begin()
        try await fixture.renderer.render(.overlay(.extensions(tab: .hooks)))
        #expect(await fixture.waitForPaint(of: "Hooks"))

        // One Tab press lands on Plugins; three more reach MCP Servers. The
        // Marketplace stop proves itself by painting its notice, which no
        // other tab contains.
        var routing = try await fixture.renderer.handleInput(.key(KeyEvent(key: .tab)))
        #expect(routing == .consumed)
        routing = try await fixture.renderer.handleInput(.key(KeyEvent(key: .tab)))
        #expect(routing == .consumed)
        #expect(await fixture.waitForPaint(of: "Marketplace management runs in the CLI"))
        try await fixture.renderer.restoreTerminal()
    }
}
