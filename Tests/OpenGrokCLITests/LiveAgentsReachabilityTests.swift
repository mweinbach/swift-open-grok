// LiveAgentsReachabilityTests.swift
//
// The agents/personas modal through the LIVE adapter (AGENTS.md §3): the
// real `LiveInteractiveControllerRenderer` painting into a captured sink
// under an isolated `$HOME`/`$OPENGROK_HOME`, driven end-to-end through the
// real controller from typed input. What is asserted is what the live
// loaders actually surfaced on screen — a real project agent definition
// through `AgentDefinitionDiscovery`, real persona files through the
// B9-b0 `SubagentPersonaLoader` (the same data a live spawn resolves
// with), the `[subagents.toggle]` reader, the `[agent] name` default
// marker, the `Enter` route into the document overlay, and the mutual
// exclusivity with the extensions modal. As of B9-b2, also the `t`/`s`
// mutation round-trips: a keypress in the open modal landing on the USER
// config.toml, the repainted state after the in-place refresh, upstream's
// inline-message copy, the failed-write arm, and — the §3 stake — the
// same `[subagents.toggle]` file the writer produces gating a REAL
// session's spawn surface through real executor dispatch. The controller
// half (registry pins, dispatch, initial tab) is in
// `Tests/OpenGrokPagerTests/PagerAgentsCommandTests.swift`.

import Foundation
import OpenGrokHTTP
import OpenGrokPager
import OpenGrokPagerRender
import OpenGrokSamplingTypes
import OpenGrokTerminalCore
import OpenGrokTestSupport
import Testing
@testable import OpenGrokCLI

// MARK: - Fixtures

private final class AgentsCapturingSink: PagerTerminalSink, CustomReflectable,
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
    /// erase-in-display, erase-in-line; every other CSI/OSC skipped) —
    /// the E14-recorded capture discipline: the renderer diffs frames, so
    /// only a replayed screen states what was painted.
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
/// can read the developer's real agents, personas, or config.
private struct AgentsRendererFixture {
    let home: URL
    let sink: AgentsCapturingSink
    let renderer: LiveInteractiveControllerRenderer

    init() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-agents-reach-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        sink = AgentsCapturingSink(width: 140, height: 40)
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
            sessionID: "agents-live",
            mcpServers: [],
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

    /// A real agent definition where project discovery reads it
    /// (`{cwd}/.opengrok/agents/{name}.md`).
    func writeProjectAgent(
        named name: String = "reviewer",
        description: String = "Reviews code changes before landing",
        body: String = "Always cite the diff hunk you are judging."
    ) throws {
        let directory = home
            .appendingPathComponent(".opengrok", isDirectory: true)
            .appendingPathComponent("agents", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let content = "---\nname: \(name)\ndescription: \(description)\n---\n\n\(body)\n"
        try content.write(
            to: directory.appendingPathComponent("\(name).md"),
            atomically: true,
            encoding: .utf8
        )
    }

    /// A real persona file where the B9-b0 loader's USER scope reads it
    /// (`$OPENGROK_HOME/personas/{name}.toml`). The blank line between the
    /// keys keeps the document viewer's markdown pass from folding both
    /// into one over-wide paragraph the text overlay would clip.
    func writeUserPersona(
        named name: String = "socratic",
        content: String = "description = \"Asks questions before answering\"\n\ninstructions = \"Lead with questions.\"\n"
    ) throws {
        let directory = home.appendingPathComponent("personas", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try content.write(
            to: directory.appendingPathComponent("\(name).toml"),
            atomically: true,
            encoding: .utf8
        )
    }

    /// A real persona file in the trusted-project overlay's directory
    /// (`{cwd}/.opengrok/personas/{name}.toml`).
    func writeProjectPersona(
        named name: String = "auditor",
        content: String = "instructions = \"Review everything twice.\"\n"
    ) throws {
        let directory = home
            .appendingPathComponent(".opengrok", isDirectory: true)
            .appendingPathComponent("personas", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try content.write(
            to: directory.appendingPathComponent("\(name).toml"),
            atomically: true,
            encoding: .utf8
        )
    }

    /// The user config the fresh effective-config read resolves
    /// (`$OPENGROK_HOME/config.toml`).
    func writeConfig(_ toml: String) throws {
        try toml.write(
            to: home.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )
    }

    /// What the USER config.toml actually says right now — the disk truth
    /// every mutation assertion compares against.
    func readConfig() -> String? {
        try? String(
            contentsOf: home.appendingPathComponent("config.toml"),
            encoding: .utf8
        )
    }

    /// Press one key against the open modal through the real input route.
    func press(_ key: Character) async throws {
        let routing = try await renderer.handleInput(
            .key(KeyEvent(key: .char(key), modifiers: []))
        )
        #expect(routing == .consumed, "key \(key) leaked past the open modal")
    }

    /// The reconstructed screen with all whitespace removed, so a
    /// multi-word needle matches regardless of the column its row starts
    /// at.
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

    /// Poll until a previously painted needle is repainted away — the
    /// dismissal proof for mutual-exclusivity checks.
    func waitForErase(of marker: String, timeout: TimeInterval = 5) async -> Bool {
        let needle = marker.filter { !$0.isWhitespace }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, paintedCompact().contains(needle) {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return !paintedCompact().contains(needle)
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
            runtime: AgentsUnusedRuntime(),
            renderer: renderer,
            output: AgentsDiscardingOutput()
        )
        _ = try await controller.run(.init(prompt: "", mode: .inline))
    }
}

private struct AgentsUnusedRuntime: OpenGrokPagerRuntimeAdapter {
    func makeSession(
        for request: OpenGrokPagerRequest
    ) async throws -> any OpenGrokPagerSessionAdapter {
        _ = request
        throw CancellationError()
    }
}

private struct AgentsDiscardingOutput: OpenGrokPagerInteractiveOutputAdapter {
    func forward(_ event: OpenGrokPagerInteractiveEvent) async throws { _ = event }
}

// MARK: - Tests

@Suite("agents modal live seam", .serialized)
struct LiveAgentsReachabilityTests {
    @Test("typed /config-agents paints built-ins in order, a real project agent, toggle state, and the default marker")
    func agentsTabPaintsLiveData() async throws {
        let fixture = try AgentsRendererFixture()
        defer { fixture.dispose() }
        try fixture.writeProjectAgent()
        // A real config.toml: the `[subagents.toggle]` READER (`t` writer
        // is b2) and the `[agent] name` leg of the default-agent chain.
        try fixture.writeConfig("""
        [agent]
        name = "grok-build"

        [subagents.toggle]
        explore = false
        """)
        // Through the REAL controller: keystrokes → registry → dispatch →
        // overlay intent → snapshot built from live discovery → paint.
        try await fixture.runController(submitting: ["/config-agents"])

        // The Built-in section with upstream's five user-visible builtins
        // (`agents_modal.rs:275-283`) in order.
        #expect(await fixture.waitForPaint(of: "\u{2500}\u{2500} Built-in \u{2500}\u{2500}"))
        let compact = fixture.paintedCompact()
        let order = ["grok-build", "general-purpose", "explore", "plan", "browser-use"]
        var cursor = compact.startIndex..<compact.endIndex
        for name in order {
            let range = compact.range(of: name, range: cursor)
            #expect(range != nil, "\(name) missing or out of order")
            guard let range else { return }
            cursor = range.upperBound..<compact.endIndex
        }
        // The real project definition, discovered from disk, under its
        // section header with its description.
        #expect(await fixture.waitForPaint(of: "\u{2500}\u{2500} Project \u{2500}\u{2500}"))
        #expect(await fixture.waitForPaint(of: "reviewer"))
        #expect(await fixture.waitForPaint(of: "Reviews code changes before landing"))
        // `[subagents.toggle] explore = false` → hollow dot + ` [off]`
        // (`load_agent_toggle`, `:569-587`; row markers `:1380-1456`).
        #expect(await fixture.waitForPaint(of: "\u{25CB} explore"))
        #expect(await fixture.waitForPaint(of: "explore [off]"))
        // `[agent] name = "grok-build"` resolves the default marker
        // (`resolve_default_agent_name`, `:712-722`).
        #expect(await fixture.waitForPaint(of: "grok-build default"))
        // The Agents-tab footer advertises the b2 verbs (`t toggle`
        // `:1080-1083`, `s default` `:1084-1088`) — and still none of the
        // b3 ones.
        let footer = fixture.paintedCompact()
        #expect(footer.contains("ttoggle"))
        #expect(footer.contains("sdefault"))
        #expect(!footer.contains("nnew"))
        #expect(!footer.contains("ddelete"))
    }

    @Test("typed /personas opens the Personas tab with real persona files and scope tags")
    func personasTabPaintsLiveData() async throws {
        let fixture = try AgentsRendererFixture()
        defer { fixture.dispose() }
        try fixture.writeUserPersona()
        try fixture.writeProjectPersona()
        try await fixture.runController(submitting: ["/personas"])

        // The Personas tab is active (`initial_tab`,
        // `dispatch/transcript.rs:521-523`): its blurb is unique to it.
        #expect(await fixture.waitForPaint(
            of: "Personas shape subagent behavior via the persona parameter on spawn_subagent."
        ))
        // The user persona with its declared description and scope tag —
        // read by the same B9-b0 loader a live spawn resolves with.
        #expect(await fixture.waitForPaint(of: "socratic user"))
        #expect(await fixture.waitForPaint(of: "Asks questions before answering"))
        // The project persona: no description field, so the first
        // paragraph of instructions is sniffed
        // (`persona_detail_from_local_file`, `:538-550`).
        #expect(await fixture.waitForPaint(of: "auditor project"))
        #expect(await fixture.waitForPaint(of: "Review everything twice."))
        // The Personas footer carries neither the b2 Agents-tab verbs
        // (upstream's personas footer has no `t`/`s` rows) nor the b3
        // ones.
        let footer = fixture.paintedCompact()
        #expect(!footer.contains("ttoggle"))
        #expect(!footer.contains("sdefault"))
        #expect(!footer.contains("nnew"))
        #expect(!footer.contains("ddelete"))
    }

    @Test("Enter routes the selected definition through the document overlay, layered over the modal")
    func enterOpensDocumentViewer() async throws {
        let fixture = try AgentsRendererFixture()
        defer { fixture.dispose() }
        try await fixture.renderer.begin()
        try await fixture.renderer.render(.overlay(.agentsModal(initialTab: nil)))
        #expect(await fixture.waitForPaint(of: "\u{2500}\u{2500} Built-in \u{2500}\u{2500}"))

        // `j` to general-purpose (grok-build has no prompt body), then
        // Enter → the `.showDocument` overlay with upstream's title shape
        // (`"{name} — prompt extension"`, `agents_modal.rs:2127`) and the
        // synthesized body (`synthesize_agent_markdown`, `:863-872`).
        var routing = try await fixture.renderer.handleInput(
            .key(KeyEvent(key: .char("j"), modifiers: []))
        )
        #expect(routing == .consumed)
        routing = try await fixture.renderer.handleInput(.key(KeyEvent(key: .enter)))
        #expect(routing == .consumed)
        #expect(await fixture.waitForPaint(of: "general-purpose \u{2014} prompt extension"))
        #expect(await fixture.waitForPaint(of: "Complete the assigned task directly."))
        // Esc closes the viewer and the agents modal is STILL THERE —
        // upstream's viewer-over-modal layering
        // (`agent_view/modals.rs:33-36`).
        routing = try await fixture.renderer.handleInput(.key(KeyEvent(key: .escape)))
        #expect(routing == .consumed)
        #expect(await fixture.waitForErase(of: "prompt extension"))
        #expect(fixture.paintedCompact().contains(
            "\u{2500}\u{2500}Built-in\u{2500}\u{2500}"
        ))
        try await fixture.renderer.restoreTerminal()
    }

    @Test("Enter on a persona views its real file through the document overlay")
    func personaEnterViewsFile() async throws {
        let fixture = try AgentsRendererFixture()
        defer { fixture.dispose() }
        try fixture.writeUserPersona()
        try await fixture.renderer.begin()
        try await fixture.renderer.render(.overlay(.agentsModal(initialTab: .personas)))
        #expect(await fixture.waitForPaint(of: "socratic user"))

        let routing = try await fixture.renderer.handleInput(.key(KeyEvent(key: .enter)))
        #expect(routing == .consumed)
        // The b3 detail modal's title shape (`persona: {name}`,
        // `persona_detail.rs:382`) over the persona file's own text.
        #expect(await fixture.waitForPaint(of: "persona: socratic"))
        #expect(await fixture.waitForPaint(of: "Lead with questions."))
        try await fixture.renderer.restoreTerminal()
    }

    @Test("opening extensions closes the agents modal, and the reverse — both dispatch directions")
    func mutualExclusivityWithExtensions() async throws {
        // `dispatch/transcript.rs:463-464` (extensions closes agents) and
        // `:500-501` (agents closes extensions).
        let fixture = try AgentsRendererFixture()
        defer { fixture.dispose() }
        try await fixture.renderer.begin()

        // Direction 1: agents → extensions → Esc must reveal NO agents
        // modal beneath.
        try await fixture.renderer.render(.overlay(.agentsModal(initialTab: nil)))
        #expect(await fixture.waitForPaint(of: "\u{2500}\u{2500} Built-in \u{2500}\u{2500}"))
        try await fixture.renderer.render(.overlay(.extensions(tab: .hooks)))
        #expect(await fixture.waitForPaint(of: "MCP Servers"))
        var routing = try await fixture.renderer.handleInput(.key(KeyEvent(key: .escape)))
        #expect(routing == .consumed)
        #expect(await fixture.waitForErase(of: "MCP Servers"))
        #expect(!fixture.paintedCompact().contains("\u{2500}\u{2500}Built-in\u{2500}\u{2500}"))

        // Direction 2: extensions → agents → Esc must reveal NO extensions
        // modal beneath.
        try await fixture.renderer.render(.overlay(.extensions(tab: .hooks)))
        #expect(await fixture.waitForPaint(of: "MCP Servers"))
        try await fixture.renderer.render(.overlay(.agentsModal(initialTab: nil)))
        #expect(await fixture.waitForPaint(of: "\u{2500}\u{2500} Built-in \u{2500}\u{2500}"))
        routing = try await fixture.renderer.handleInput(.key(KeyEvent(key: .escape)))
        #expect(routing == .consumed)
        #expect(await fixture.waitForErase(of: "Built-in"))
        #expect(!fixture.paintedCompact().contains("MCPServers"))
        try await fixture.renderer.restoreTerminal()
    }

    @Test("the b3 keys n and d stay swallowed without a write or a notice")
    func unbackedKeysAreInert() async throws {
        let fixture = try AgentsRendererFixture()
        defer { fixture.dispose() }
        try await fixture.renderer.begin()
        try await fixture.renderer.render(.overlay(.agentsModal(initialTab: nil)))
        #expect(await fixture.waitForPaint(of: "\u{2500}\u{2500} Built-in \u{2500}\u{2500}"))

        // The b3 persona keys: each is swallowed by the open modal (never
        // leaks to the composer), changes nothing on screen, and — the
        // real stake — writes nothing to config.toml. (`t`/`s` write as
        // of b2 and are covered by the mutation tests below.)
        for mutation in ["n", "d"] as [Character] {
            try await fixture.press(mutation)
        }
        let configPath = fixture.home.appendingPathComponent("config.toml").path
        #expect(
            !FileManager.default.fileExists(atPath: configPath),
            "an unbacked key must not create config.toml"
        )
        try await fixture.renderer.restoreTerminal()
    }

    @Test("t writes [subagents.toggle] to the user config and the repainted list states disk, both directions")
    func toggleKeyRoundTrips() async throws {
        let fixture = try AgentsRendererFixture()
        defer { fixture.dispose() }
        try await fixture.renderer.begin()
        try await fixture.renderer.render(.overlay(.agentsModal(initialTab: nil)))
        #expect(await fixture.waitForPaint(of: "\u{25CF} explore"))

        // j j → explore (third builtin), then `t` (`toggle_agent`,
        // `agents_modal.rs:754-778,:2183-2196`): the write lands in the
        // USER config.toml and the rebuilt list (`rebuild_agents`,
        // `:322-328` — a fresh effective-config read, not a snapshot
        // patch) paints the hollow dot + ` [off]`. No success message —
        // upstream's `t` arm sets none.
        try await fixture.press("j")
        try await fixture.press("j")
        try await fixture.press("t")
        #expect(await fixture.waitForPaint(of: "\u{25CB} explore"))
        #expect(await fixture.waitForPaint(of: "explore [off]"))
        var config = fixture.readConfig() ?? ""
        #expect(config.contains("[subagents.toggle]"))
        #expect(config.contains("explore = false"))

        // `t` again re-enables: an explicit `true` on disk (upstream sets,
        // never prunes) and the marker repaints away.
        try await fixture.press("t")
        #expect(await fixture.waitForErase(of: "explore [off]"))
        #expect(await fixture.waitForPaint(of: "\u{25CF} explore"))
        config = fixture.readConfig() ?? ""
        #expect(config.contains("explore = true"))
        #expect(!config.contains("explore = false"))
        try await fixture.renderer.restoreTerminal()
    }

    @Test("s sets [agent] name with upstream's message; s again clears the key and quotes the fallback")
    func defaultKeyRoundTrips() async throws {
        let fixture = try AgentsRendererFixture()
        defer { fixture.dispose() }
        try await fixture.renderer.begin()
        try await fixture.renderer.render(.overlay(.agentsModal(initialTab: nil)))
        #expect(await fixture.waitForPaint(of: "\u{25CF} grok-build"))

        // `s` on grok-build (first row): `set_default_agent(Some)`
        // (`agents_modal.rs:730-752,:2152-2181`) writes `[agent] name`,
        // the default re-resolves through the full chain, the marker
        // moves, and the info message carries upstream's exact copy.
        try await fixture.press("s")
        #expect(await fixture.waitForPaint(of: "New sessions will start with 'grok-build'"))
        #expect(await fixture.waitForPaint(of: "grok-build default"))
        var config = fixture.readConfig() ?? ""
        #expect(config.contains("[agent]"))
        #expect(config.contains("name = \"grok-build\""))

        // `s` again on the SAME entry: it now IS the explicit config name
        // (`load_config_agent_name`, `:707-709`), so the key CLEARS and
        // the message quotes the RE-RESOLVED fallback — the chain default
        // `grok-build-plan`, not the entry just cleared (`:2156-2168`).
        try await fixture.press("s")
        #expect(await fixture.waitForPaint(
            of: "Cleared \u{2014} new sessions use 'grok-build-plan'"
        ))
        config = fixture.readConfig() ?? ""
        #expect(!config.contains("name = \"grok-build\""))
        #expect(await fixture.waitForErase(of: "grok-build default"))
        try await fixture.renderer.restoreTerminal()
    }

    @Test("a failed write surfaces upstream's copy and the modal keeps stating what disk holds")
    func failedWriteSurfacesAndStaysConsistent() async throws {
        let fixture = try AgentsRendererFixture()
        defer { fixture.dispose() }
        // A non-empty config.toml that does not parse: the writers refuse
        // it rather than clobber (`read_config_document_for_edit`,
        // `config_toml_edit.rs:7-27`) — the failed-write consistency arm.
        let bad = "this is [not valid toml\n"
        try fixture.writeConfig(bad)
        try await fixture.renderer.begin()
        try await fixture.renderer.render(.overlay(.agentsModal(initialTab: nil)))
        #expect(await fixture.waitForPaint(of: "\u{2500}\u{2500} Built-in \u{2500}\u{2500}"))

        try await fixture.press("t")
        // The inline error, byte-parity (`agents_modal.rs:760` surfaced
        // via `:2192`), and NO optimistic flip — the list still states
        // what disk holds.
        #expect(await fixture.waitForPaint(of: "Could not read or parse config.toml"))
        #expect(!fixture.paintedCompact().contains("[off]"))
        #expect(fixture.readConfig() == bad, "a refused write must leave the file untouched")

        // `s` refuses identically (`:736` via `:2177`), and the next key
        // clears the message (`:1978`).
        try await fixture.press("s")
        #expect(await fixture.waitForPaint(of: "Could not read or parse config.toml"))
        #expect(fixture.readConfig() == bad)
        try await fixture.press("j")
        #expect(await fixture.waitForErase(of: "Could not read or parse config.toml"))
        try await fixture.renderer.restoreTerminal()
    }
}

// MARK: - The toggle writer at the spawn surface (§3, item 5)

/// The B9-b2 stake beyond pixels: the SAME `[subagents.toggle]` table the
/// `t` writer produces is what gates a real session's spawn surface — at
/// session build (`LiveComposition.makeSubagentHost` feeds it into
/// `DefinitionResolutionContext`, mirroring upstream's `resolve_subagents`
/// → `ctx.subagent_toggle` → `resolve_agent_definition`,
/// `agent/config.rs:2257-2271` / `agent/subagent/mod.rs:1729-1751`) and at
/// every spawn validation. Upstream's running session snapshots the map at
/// startup exactly the same way (`subagent_coordinator.rs:283-293`), so
/// "the toggle takes effect for NEW sessions" is parity, not a shortcut.
@Suite("agents toggle writer gates the live spawn surface", .serialized)
struct LiveAgentsToggleSpawnGateTests {
    private struct GateFixture {
        let root: URL
        let home: URL
        let workspace: URL
        let server: MockInferenceServer
        let store: PagerAgentsConfigStore

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("opengrok-agents-gate-\(UUID().uuidString)", isDirectory: true)
            home = root.appendingPathComponent("home", isDirectory: true)
            workspace = root.appendingPathComponent("workspace", isDirectory: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            server = try MockInferenceServer()
            try """
            [endpoints]
            xai_api_base_url = "\(server.url)"
            """.write(
                to: home.appendingPathComponent("config.toml"),
                atomically: true,
                encoding: .utf8
            )
            store = PagerAgentsConfigStore(
                configPath: home.appendingPathComponent("config.toml")
            )
        }

        func dispose() {
            server.stop()
            try? FileManager.default.removeItem(at: root)
        }

        func makeFoundation() async throws
            -> OpenGrokLiveApplicationLauncher.LiveSessionFoundation {
            let command = try CLICommandParser.parseOrThrow([
                "headless", "--prompt", "hello", "--cwd", workspace.path,
                "--model", "grok-4.5",
            ])
            guard case .launch(let options) = command else {
                throw CLIApplicationError.failed("fixture did not parse to a launch")
            }
            return try await OpenGrokLiveApplicationLauncher.makeSessionFoundation(
                options: options,
                context: CLIApplicationContext(
                    environment: [
                        "HOME": home.path,
                        "OPENGROK_HOME": home.path,
                        "XDG_STATE_HOME": home.appendingPathComponent("state").path,
                        "XAI_API_KEY": "test-xai-key",
                    ],
                    streams: CLIStreams(out: { _ in }, err: { _ in }),
                    control: .never
                ),
                dependencies: OpenGrokLiveCompositionDependencies(
                    makeSampler: OpenGrokLiveSampler.production(configuration:)
                )
            )
        }
    }

    @Test("a writer-toggled-off agent is refused by real executor dispatch, and preserved keys keep working")
    func writerOutputGatesSpawn() async throws {
        let fixture = try GateFixture()
        defer { fixture.dispose() }
        // The WRITER produces the config — not a hand-written fixture —
        // so this proves the b2 file format is the one the session gate
        // actually consumes, and that the write preserved the sibling
        // `[endpoints]` table the session needs to reach the mock server.
        try fixture.store.toggleAgent(name: "explore", enabled: false)

        let foundation = try await fixture.makeFoundation()
        defer { Task { await foundation.toolExecutor.shutdown() } }
        // The roster still has other built-ins, so the surface stays up…
        #expect(foundation.toolExecutor.tools.map(\.name).contains("spawn_subagent"))
        // …and the toggled-off type is refused at REAL dispatch with the
        // config message (`validate_subagent_type` → `Disabled`,
        // `agent/subagent/mod.rs:1782-1806`).
        let result = await foundation.toolExecutor.invoke(
            sessionID: foundation.sessionID,
            workingDirectory: foundation.cwd,
            call: ToolCall(
                id: "call-spawn-toggled",
                name: "spawn_subagent",
                arguments: #"{"prompt":"p","description":"d","subagent_type":"explore"}"#
            )
        )
        guard case .failure(let error) = result else {
            Issue.record("a writer-disabled type unexpectedly spawned")
            return
        }
        #expect(error.description.contains(
            "Subagent 'explore' is disabled via [subagents.toggle] in config.toml"
        ))
    }

    @Test("writer-toggling every builtin off strips the spawn surface of a new session")
    func writerOutputStripsSurface() async throws {
        let fixture = try GateFixture()
        defer { fixture.dispose() }
        for name in ["general-purpose", "explore", "plan"] {
            try fixture.store.toggleAgent(name: name, enabled: false)
        }
        let foundation = try await fixture.makeFoundation()
        defer { Task { await foundation.toolExecutor.shutdown() } }
        #expect(foundation.subagentHost == nil)
        #expect(!foundation.toolExecutor.tools.map(\.name).contains("spawn_subagent"))
    }
}
