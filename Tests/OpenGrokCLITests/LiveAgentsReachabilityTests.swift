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
// session's spawn surface through real executor dispatch. As of B9-b3,
// also the Personas CRUD round-trips (`n` create both scopes with the
// byte-exact template, refuse-overwrite, `d` y/n delete, the bundled
// refusal), the persona detail modal with a real inline-edit save landing
// on disk, the `i`/$EDITOR suspend with a fake editor whose mutation
// proves `refresh_after_editor`, and — the §3 stake — a persona the
// modal's own writer created resolving onto a REAL child's sampler
// request. The controller half (registry pins, dispatch, initial tab) is
// in `Tests/OpenGrokPagerTests/PagerAgentsCommandTests.swift`.

import Foundation
import OpenGrokConfig
import OpenGrokHTTP
import OpenGrokPager
import OpenGrokPagerRender
import OpenGrokSamplingTypes
import OpenGrokShared
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

    /// A real persona file in the bundled cache directory
    /// (`$OPENGROK_HOME/bundled/personas/{name}.toml`) — listed by the b0
    /// loader, refused by every delete guard.
    func writeBundledPersona(
        named name: String = "shipping",
        content: String = "description = \"Ships with the CLI\"\n"
    ) throws {
        let directory = home
            .appendingPathComponent("bundled", isDirectory: true)
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

    /// Press a non-character key (Tab, Enter, Esc, Backspace, …).
    func pressKey(_ key: KeyEvent) async throws {
        let routing = try await renderer.handleInput(.key(key))
        #expect(routing == .consumed, "key \(key.key) leaked past the open modal")
    }

    /// Type a whole string through the key route.
    func type(_ text: String) async throws {
        for character in text { try await press(character) }
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
        // The Personas footer carries the b3 verbs (`n new`/`d delete`,
        // `agents_modal.rs:1163-1172`) and still no `t`/`s` — upstream's
        // personas footer has no such rows.
        let footer = fixture.paintedCompact()
        #expect(!footer.contains("ttoggle"))
        #expect(!footer.contains("sdefault"))
        #expect(footer.contains("nnew"))
        #expect(footer.contains("ddelete"))
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

    @Test("Enter on a persona opens the structured detail modal over the list")
    func personaEnterOpensDetail() async throws {
        let fixture = try AgentsRendererFixture()
        defer { fixture.dispose() }
        try fixture.writeUserPersona()
        try await fixture.renderer.begin()
        try await fixture.renderer.render(.overlay(.agentsModal(initialTab: .personas)))
        #expect(await fixture.waitForPaint(of: "socratic user"))

        let routing = try await fixture.renderer.handleInput(.key(KeyEvent(key: .enter)))
        #expect(routing == .consumed)
        // The b3 detail modal (`persona_detail.rs:375-668`): the title
        // shape (`persona: {name}`, `:382`), the structured field labels
        // (`:49-59`), the file's own values, and the source line.
        #expect(await fixture.waitForPaint(of: "persona: socratic"))
        #expect(await fixture.waitForPaint(of: "Asks questions before answering"))
        #expect(await fixture.waitForPaint(of: "Lead with questions."))
        #expect(await fixture.waitForPaint(of: "Instr. file"))
        #expect(await fixture.waitForPaint(of: "Source: "))
        // Esc closes the detail and the personas list is still there —
        // the viewer-over-modal layering plus the close-refresh
        // (`agent_view/modals.rs:126-132`).
        try await fixture.pressKey(KeyEvent(key: .escape))
        #expect(await fixture.waitForErase(of: "Instr. file"))
        #expect(fixture.paintedCompact().contains("socraticuser"))
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

    @Test("n creates a user persona from typed keys: exact template bytes, refreshed list, refuse-overwrite")
    func createPersonaRoundTrip() async throws {
        // The form Enter arm (`agents_modal.rs:2363-2385`) through the
        // real key route into `create_persona_template` (`:620-646`).
        let fixture = try AgentsRendererFixture()
        defer { fixture.dispose() }
        try await fixture.renderer.begin()
        try await fixture.renderer.render(.overlay(.agentsModal(initialTab: .personas)))
        #expect(await fixture.waitForPaint(of: "No personas available"))

        try await fixture.press("n")
        #expect(await fixture.waitForPaint(of: "Create New Persona"))
        try await fixture.type("review pal")
        try await fixture.pressKey(KeyEvent(key: .tab))
        try await fixture.type("Asks first")
        try await fixture.pressKey(KeyEvent(key: .tab))
        try await fixture.type("Lead with questions.")
        try await fixture.pressKey(KeyEvent(key: .enter))

        // Success copy quotes the SANITIZED name (`:2374-2379`), the form
        // closes, and the refreshed list shows the new persona with its
        // scope tag and sniffed description.
        #expect(await fixture.waitForPaint(of: "Created persona 'review-pal'"))
        #expect(await fixture.waitForPaint(of: "review-pal user"))
        #expect(await fixture.waitForPaint(of: "Asks first"))
        // The landed file: sanitized name in the user personas dir, the
        // template byte-exact (trimmed fields, description first).
        let path = fixture.home.appendingPathComponent("personas/review-pal.toml")
        #expect(try String(contentsOf: path, encoding: .utf8)
            == "description = \"Asks first\"\ninstructions = \"Lead with questions.\"\n")

        // The same name again refuses overwrite (`:632-635`), the form
        // stays open with the error inside it, and the file is untouched.
        try await fixture.press("n")
        try await fixture.type("review pal")
        try await fixture.pressKey(KeyEvent(key: .enter))
        #expect(await fixture.waitForPaint(of: "Persona 'review-pal' already exists"))
        #expect(fixture.paintedCompact().contains("CreateNewPersona"))
        #expect(try String(contentsOf: path, encoding: .utf8)
            == "description = \"Asks first\"\ninstructions = \"Lead with questions.\"\n")
        try await fixture.renderer.restoreTerminal()
    }

    @Test("the scope row switches the create target to the project personas dir")
    func createPersonaProjectScope() async throws {
        // `personas_dir_for_scope` (`agents_modal.rs:606-611`) driven by
        // the scope toggle (`try_toggle_create_scope`, `:2298-2314`).
        let fixture = try AgentsRendererFixture()
        defer { fixture.dispose() }
        try await fixture.renderer.begin()
        try await fixture.renderer.render(.overlay(.agentsModal(initialTab: .personas)))
        #expect(await fixture.waitForPaint(of: "No personas available"))

        try await fixture.press("n")
        #expect(await fixture.waitForPaint(of: "Scope: [user]"))
        try await fixture.type("proj-one")
        for _ in 0..<3 { try await fixture.pressKey(KeyEvent(key: .tab)) }
        try await fixture.press(" ")
        #expect(await fixture.waitForPaint(of: "Scope: [project]"))
        try await fixture.pressKey(KeyEvent(key: .enter))
        #expect(await fixture.waitForPaint(of: "Created persona 'proj-one'"))
        #expect(await fixture.waitForPaint(of: "proj-one project"))
        let path = fixture.home
            .appendingPathComponent(".opengrok/personas/proj-one.toml")
        #expect(FileManager.default.fileExists(atPath: path.path))
        #expect(try String(contentsOf: path, encoding: .utf8) == "")
        try await fixture.renderer.restoreTerminal()
    }

    @Test("d deletes through the y/n confirm and the file leaves disk and screen")
    func deletePersonaRoundTrip() async throws {
        // `d` (`agents_modal.rs:2265-2276`), the confirm machine
        // (`:2393-2419`), and `delete_persona_file` (`:685-697`).
        let fixture = try AgentsRendererFixture()
        defer { fixture.dispose() }
        try fixture.writeUserPersona()
        try await fixture.renderer.begin()
        try await fixture.renderer.render(.overlay(.agentsModal(initialTab: .personas)))
        #expect(await fixture.waitForPaint(of: "socratic user"))

        let path = fixture.home.appendingPathComponent("personas/socratic.toml").path
        try await fixture.press("d")
        #expect(await fixture.waitForPaint(of: "Delete persona 'socratic'?"))
        // `n` cancels with nothing deleted (`:2413-2416`).
        try await fixture.press("n")
        #expect(await fixture.waitForErase(of: "Delete persona 'socratic'?"))
        #expect(FileManager.default.fileExists(atPath: path))
        // `y` confirms (`:2395-2411`): the file leaves disk, the success
        // copy paints, and the refreshed list loses the row.
        try await fixture.press("d")
        #expect(await fixture.waitForPaint(of: "Delete persona 'socratic'?"))
        try await fixture.press("y")
        #expect(await fixture.waitForPaint(of: "Deleted persona 'socratic'"))
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(await fixture.waitForErase(of: "socratic user"))
        #expect(await fixture.waitForPaint(of: "No personas available"))
        try await fixture.renderer.restoreTerminal()
    }

    @Test("bundled personas refuse deletion with upstream's copy and never lose their file")
    func bundledDeleteRefusal() async throws {
        // The list-level guard (`agents_modal.rs:2267-2271`) backed by the
        // canonical-path check (`:651-671`): a `bundled` path component
        // can never be removed from the modal.
        let fixture = try AgentsRendererFixture()
        defer { fixture.dispose() }
        try fixture.writeUserPersona()
        try fixture.writeBundledPersona()
        try await fixture.renderer.begin()
        try await fixture.renderer.render(.overlay(.agentsModal(initialTab: .personas)))
        // Precedence grouping paints user before bundled.
        #expect(await fixture.waitForPaint(of: "socratic user"))
        #expect(await fixture.waitForPaint(of: "shipping bundled"))

        try await fixture.press("j") // → shipping
        try await fixture.press("d")
        #expect(await fixture.waitForPaint(of: "Cannot delete bundled personas"))
        #expect(!fixture.paintedCompact().contains("Deletepersona'shipping'?"),
                "the confirm must never arm for a bundled persona")
        let bundledPath = fixture.home
            .appendingPathComponent("bundled/personas/shipping.toml").path
        #expect(FileManager.default.fileExists(atPath: bundledPath))
        try await fixture.renderer.restoreTerminal()
    }

    @Test("an inline field edit in the detail modal saves to the real file and the closed list restates it")
    func detailEditSavesToDisk() async throws {
        // The edit machine (`persona_detail.rs:839-873`) through the real
        // key route, `save_to_file` (`:316-347`) landing on disk, and the
        // close-refresh (`agent_view/modals.rs:126-132`).
        let fixture = try AgentsRendererFixture()
        defer { fixture.dispose() }
        try fixture.writeUserPersona()
        try await fixture.renderer.begin()
        try await fixture.renderer.render(.overlay(.agentsModal(initialTab: .personas)))
        #expect(await fixture.waitForPaint(of: "socratic user"))
        try await fixture.pressKey(KeyEvent(key: .enter))
        #expect(await fixture.waitForPaint(of: "persona: socratic"))

        // j → Description, e → edit, retype, Enter → save.
        try await fixture.press("j")
        try await fixture.press("e")
        for _ in 0..<"Asks questions before answering".count {
            try await fixture.pressKey(KeyEvent(key: .backspace))
        }
        try await fixture.type("Edited live")
        try await fixture.pressKey(KeyEvent(key: .enter))
        #expect(await fixture.waitForPaint(of: "Saved"))
        let saved = try String(
            contentsOf: fixture.home.appendingPathComponent("personas/socratic.toml"),
            encoding: .utf8
        )
        #expect(saved.contains("description = \"Edited live\""))
        #expect(saved.contains("instructions = \"Lead with questions.\""))
        // Esc closes the detail; the refreshed list restates the edit.
        try await fixture.pressKey(KeyEvent(key: .escape))
        #expect(await fixture.waitForErase(of: "persona: socratic"))
        #expect(await fixture.waitForPaint(of: "Edited live"))
        try await fixture.renderer.restoreTerminal()
    }

    @Test("i suspends into $EDITOR and the editor's mutation lands in the refreshed list")
    func editInEditorSuspendsAndRefreshes() async throws {
        // The `$EDITOR` arm on the shared suspend seam (`event_loop.rs:
        // 677-736`): park → teardown → child → restore, then
        // `refresh_after_editor(Personas)` (`external_editor.rs:277-283`)
        // — a fake editor that REWRITES the file proves the refresh is a
        // re-read, not a repaint of stale state.
        let scriptDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("opengrok-fake-editor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: scriptDirectory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: scriptDirectory) }
        #if os(Windows)
        let script = scriptDirectory.appendingPathComponent("fake-editor.cmd")
        #else
        let script = scriptDirectory.appendingPathComponent("fake-editor.sh")
        #endif
        #if os(Windows)
        try """
        @echo off
        > "%~1" echo description = "edited by editor"
        >> "%~1" echo instructions = "Lead with questions."
        """.write(to: script, atomically: true, encoding: .utf8)
        #else
        try """
        #!/bin/sh
        printf 'description = "edited by editor"\\ninstructions = "Lead with questions."\\n' > "$1"
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: script.path
        )
        #endif

        let fixture = try AgentsRendererFixture()
        defer { fixture.dispose() }
        try fixture.writeUserPersona()
        try await fixture.renderer.begin()
        // The recording suspend host carries `$EDITOR` — the host owns the
        // environment the editor resolves from (`resolve_editor_argv`).
        let log = AgentsSuspendLog()
        var editorEnvironment = ["EDITOR": script.path]
        #if os(Windows)
        editorEnvironment["PATH"] = ProcessInfo.processInfo.environment["PATH"] ?? ""
        #else
        editorEnvironment["PATH"] = "/usr/bin:/bin"
        #endif
        await fixture.renderer.setSuspendHost(LiveTUISuspendHost(
            beginInputSuspension: {
                await log.record("park")
                return LiveInputSuspension(end: { await log.record("end") })
            },
            environment: editorEnvironment
        ))
        try await fixture.renderer.render(.overlay(.agentsModal(initialTab: .personas)))
        #expect(await fixture.waitForPaint(of: "Asks questions before answering"))
        try await fixture.pressKey(KeyEvent(key: .enter))
        #expect(await fixture.waitForPaint(of: "persona: socratic"))

        try await fixture.press("i")
        // The ordered suspend ran exactly once.
        #expect(await log.entries == ["park", "end"])
        // The detail closed before the suspend (upstream closes it when
        // queueing, `agent_view/modals.rs:134-140`)…
        #expect(await fixture.waitForErase(of: "persona: socratic"))
        // …the child actually rewrote the file…
        let saved = try String(
            contentsOf: fixture.home.appendingPathComponent("personas/socratic.toml"),
            encoding: .utf8
        )
        #expect(saved.contains("edited by editor"))
        do {
            let parsed = try parseTOML(saved)
            #expect(parsed["description"]?.stringValue == "edited by editor")
        } catch {
            Issue.record("editor output was not valid TOML: \(error); bytes: \(Array(saved.utf8))")
        }
        // …and the refreshed list states the editor's content, not the
        // open-time snapshot.
        let refreshedRows = LiveAgentsComposition.personaRows(
            document: LiveAgentsComposition.effectiveDocument(
                cwd: fixture.home,
                environment: ["HOME": fixture.home.path, "OPENGROK_HOME": fixture.home.path]
            ),
            openGrokHome: fixture.home,
            cwd: fixture.home
        )
        #expect(refreshedRows.first { $0.name == "socratic" }?.description == "edited by editor")
        #expect(
            await fixture.waitForPaint(of: "edited by editor"),
            "refreshed rows: \(refreshedRows); painted: \(fixture.paintedCompact())"
        )
        #expect(await fixture.waitForErase(of: "Asks questions before answering"))
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

// MARK: - Suspend-order log for the $EDITOR test

private actor AgentsSuspendLog {
    private(set) var entries: [String] = []

    func record(_ entry: String) {
        entries.append(entry)
    }
}

// MARK: - $EDITOR resolution pins

/// `resolve_editor_argv`/`parse_editor_argv` (`external_editor.rs:125-137`
/// at pin 650c1db7), pinned with upstream's own test vectors
/// (`editor_resolution_and_parsing_follow_visual_editor_vi_order`,
/// `external_editor.rs:365-378`).
@Suite("editor resolution")
struct LiveEditorResolutionTests {
    @Test("VISUAL beats EDITOR, blanks fall through, vi is the default, quotes group")
    func resolutionOrderAndParsing() {
        let visualFirst = LiveTUISuspendHost.resolveEditor(
            environment: ["VISUAL": "visual --wait", "EDITOR": "editor"]
        )
        #expect(visualFirst?.program == "visual")
        #expect(visualFirst?.arguments == ["--wait"])
        // A blank VISUAL falls through to EDITOR; quoted arguments group.
        let quoted = LiveTUISuspendHost.resolveEditor(
            environment: ["VISUAL": "  ", "EDITOR": "editor --name 'prompt draft'"]
        )
        #expect(quoted?.program == "editor")
        #expect(quoted?.arguments == ["--name", "prompt draft"])
        // Nothing set: vi.
        let fallback = LiveTUISuspendHost.resolveEditor(environment: [:])
        #expect(fallback?.program == "vi")
        #expect(fallback?.arguments == [])
        // An unterminated quote fails the parse — the caller notes
        // upstream's `could not parse $VISUAL or $EDITOR`.
        #expect(LiveTUISuspendHost.resolveEditor(
            environment: ["VISUAL": "editor 'unterminated"]
        ) == nil)
    }
}

// MARK: - The created persona at the spawn surface (§3, the b0 flagship shape)

/// The B9-b3 stake beyond pixels: the SAME `create_persona_template`
/// output the `n` key lands (the keypress → file → exact-bytes loop is
/// pinned by `createPersonaRoundTrip` above) is what a REAL session's
/// spawn resolves against — loader → host context → `resolveRuntimeConfig`
/// → `<persona>` block → wire, the b0 flagship's proof shape.
@Suite("created personas reach the live spawn seam", .serialized)
struct LiveAgentsPersonaCreateSpawnTests {
    private struct SpawnFixture {
        let root: URL
        let home: URL
        let workspace: URL
        let server: MockInferenceServer

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "opengrok-agents-create-spawn-\(UUID().uuidString)",
                    isDirectory: true
                )
            home = root.appendingPathComponent("home", isDirectory: true)
            workspace = root.appendingPathComponent("workspace", isDirectory: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: workspace,
                withIntermediateDirectories: true
            )
            server = try MockInferenceServer()
            try """
            [endpoints]
            xai_api_base_url = "\(server.url)"
            """.write(
                to: home.appendingPathComponent("config.toml"),
                atomically: true,
                encoding: .utf8
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

    @Test("a persona created by the modal's writer lands its instructions on a real child's request")
    func createdPersonaResolvesOnTheWire() async throws {
        let fixture = try SpawnFixture()
        defer { fixture.dispose() }
        let marker = "Cite the keystone ledger \(UUID().uuidString) in every answer."
        // The SAME function the create form's Enter resolves through
        // (`create_persona_template`, `agents_modal.rs:620-646`) — not a
        // hand-written fixture file — so this proves the b3 template is
        // the shape the b0 loader and a live spawn actually consume.
        _ = try PagerPersonaFileStore.createPersonaTemplate(
            name: "probe",
            description: "created by the b3 form",
            instructions: marker,
            scope: .user,
            cwd: fixture.workspace,
            openGrokHome: fixture.home
        )
        try fixture.server.enqueueResponse(
            path: "/v1/responses",
            response: .sse(SseEvents.responsesApiEventsExact(text: "child done", model: "grok-4.5"))
        )
        let foundation = try await fixture.makeFoundation()
        defer { Task { await foundation.toolExecutor.shutdown() } }
        let host = try #require(foundation.subagentHost)
        let result = await host.spawn(
            args: .object([
                "prompt": .string("run the probe"),
                "description": .string("persona probe"),
                "subagent_type": .string("general-purpose"),
                "background": .bool(false),
            ]),
            toolCallID: "call-created-persona",
            persona: "probe"
        )
        guard case .success = result else {
            Issue.record("created-persona spawn failed: \(result)")
            return
        }
        let bodies = fixture.server.requests()
            .filter { $0.method == "POST" && $0.path.contains("responses") }
            .map { (try? $0.body?.encodeString()) ?? "" }
        #expect(bodies.count == 1)
        let childBody = try #require(bodies.first)
        #expect(childBody.contains("<persona>"))
        #expect(childBody.contains(marker))
    }
}
