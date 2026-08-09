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
// exclusivity with the extensions modal. The controller half (registry
// pins, dispatch, initial tab) is in
// `Tests/OpenGrokPagerTests/PagerAgentsCommandTests.swift`.

import Foundation
import OpenGrokHTTP
import OpenGrokPager
import OpenGrokPagerRender
import OpenGrokTerminalCore
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
        // The read-only footer: none of the b2/b3 mutation verbs.
        let footer = fixture.paintedCompact()
        #expect(!footer.contains("ttoggle"))
        #expect(!footer.contains("sdefault"))
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

    @Test("mutation keys are swallowed without a write or a notice")
    func mutationKeysAreInert() async throws {
        let fixture = try AgentsRendererFixture()
        defer { fixture.dispose() }
        try await fixture.renderer.begin()
        try await fixture.renderer.render(.overlay(.agentsModal(initialTab: nil)))
        #expect(await fixture.waitForPaint(of: "\u{2500}\u{2500} Built-in \u{2500}\u{2500}"))

        // The b2/b3 mutation keys: each is swallowed by the open modal
        // (never leaks to the composer), changes nothing on screen, and —
        // the real stake — writes nothing to config.toml.
        for mutation in ["t", "s", "n", "d"] as [Character] {
            let routing = try await fixture.renderer.handleInput(
                .key(KeyEvent(key: .char(mutation), modifiers: []))
            )
            #expect(routing == .consumed, "mutation key \(mutation) leaked")
        }
        let configPath = fixture.home.appendingPathComponent("config.toml").path
        #expect(
            !FileManager.default.fileExists(atPath: configPath),
            "a read-only modal must not create config.toml"
        )
        let compact = fixture.paintedCompact()
        #expect(!compact.contains("[off]"), "t must not toggle anything")
        #expect(!compact.contains("Newsessionswillstart"), "s must not set a default")
        try await fixture.renderer.restoreTerminal()
    }
}
