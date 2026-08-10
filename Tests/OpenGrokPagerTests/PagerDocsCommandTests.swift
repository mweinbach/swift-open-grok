// PagerDocsCommandTests.swift
//
// `/docs` at the controller seam (AGENTS.md §3): real input events into the
// real controller, asserted on the overlay requests and notices that land on
// the render adapter. The upstream contract is
// `xai-grok-pager/src/slash/commands/docs.rs` (metadata, dispatch arms, the
// byte-exact unknown-target error, `suggest_args`) and
// `xai-grok-pager/src/docs.rs` (the corpus tables and `find_doc`); every copy
// assertion here is byte-exact. The live half (the painted guides list, the
// content viewer, the injected browser opener) is pinned in
// `Tests/OpenGrokCLITests/LivePagerDocsReachabilityTests.swift`.

import Foundation
@testable import OpenGrokPager
import OpenGrokPagerMinimal
import OpenGrokTerminalCore
import Testing

@Suite("/docs at the controller seam")
struct PagerDocsCommandTests {
    // MARK: - Registry

    @Test("the registry row carries upstream's name, aliases, description and usage verbatim")
    func registryRowIsVerbatim() {
        let commands = OpenGrokPagerInteractiveController.builtinCommands
        let docs = commands.first { $0.name == "docs" }
        // `docs.rs:18-32`.
        #expect(docs?.summary == "Open How-to Guides or online Build docs")
        #expect(docs?.usage == "/docs [web|title]")
        // Upstream declares ["howto", "guides"] (docs.rs:22-24);
        // `PagerCommandDefinition` stores aliases sorted.
        #expect(docs?.aliases == ["guides", "howto"])
        // `args_required() == false` (docs.rs:38-40): a bare Enter
        // dispatches instead of parking in the argument phase.
        #expect(docs?.requiresArguments == false)

        // Registration order is display order: `/docs` follows `/help`
        // (`slash/commands/mod.rs:84-85`).
        let names = commands.map(\.name)
        let helpIndex = names.firstIndex(of: "help")
        #expect(helpIndex != nil)
        #expect(names.firstIndex(of: "docs") == helpIndex.map { $0 + 1 })

        // Visible in `/help` (and therefore in the palette fallback, which
        // parses this text) — a registered-but-invisible command is the
        // Wave 15 D1 failure repeating.
        #expect(OpenGrokPagerInteractiveController.helpText.contains("/docs [web|title]"))
    }

    // MARK: - Dispatch arms (docs.rs:70-87)

    @Test("bare /docs and both aliases open the guides browser")
    func bareDocsOpensGuides() async throws {
        let harness = try await DocsHarness.run(submitting: ["/docs", "/howto", "/guides"])
        #expect(await harness.overlayRequests == [.howtoGuides, .howtoGuides, .howtoGuides])
        #expect(await harness.turnPrompts.isEmpty)
    }

    @Test("every how-to-list token opens the guides browser, case-insensitively")
    func howtoListTokensOpenGuides() async throws {
        // `is_howto_list_arg` (docs.rs:90-95) matches on
        // `to_ascii_lowercase`, so the uppercase forms ride along.
        let tokens = ["how-to", "howto", "guides", "guide", "list", "tui", "HOW-TO", "TUI", "Guide"]
        let harness = try await DocsHarness.run(submitting: tokens.map { "/docs \($0)" })
        #expect(await harness.overlayRequests == tokens.map { _ in .howtoGuides })
    }

    @Test("every web token opens BUILD_DOCS_URL, case-insensitively")
    func webTokensOpenBuildDocs() async throws {
        // `is_web_arg` (docs.rs:97-102) and `BUILD_DOCS_URL` (docs.rs:12).
        let tokens = ["web", "online", "browser", "site", "www", "WEB", "Browser"]
        let harness = try await DocsHarness.run(submitting: tokens.map { "/docs \($0)" })
        #expect(await harness.overlayRequests == tokens.map { _ in
            .openURL("https://docs.x.ai/build/overview")
        })
    }

    @Test("/docs <title> opens that guide with its corpus content")
    func titleOpensGuide() async throws {
        let harness = try await DocsHarness.run(submitting: ["/docs Getting Started"])
        let requests = await harness.overlayRequests
        try #require(requests.count == 1)
        guard case .showDocument(let title, let content) = requests[0] else {
            Issue.record("expected .showDocument, got \(requests[0])")
            return
        }
        #expect(title == "Getting Started")
        // The content is the corpus constant itself, not a copy that could
        // drift from it.
        #expect(content == PagerDocs.userGuide[0].content)
        #expect(content.hasPrefix("# Getting Started"))
    }

    @Test("the title lookup is ASCII-case-insensitive, like find_doc")
    func titleLookupIsCaseInsensitive() async throws {
        // `find_doc` uses `eq_ignore_ascii_case` (docs.rs:193-198).
        let harness = try await DocsHarness.run(submitting: [
            "/docs getting started",
            "/docs GETTING STARTED",
            "/docs hooks & plugins guide",
        ])
        let requests = await harness.overlayRequests
        try #require(requests.count == 3)
        for (index, expected) in ["Getting Started", "Getting Started", "Hooks & Plugins Guide"]
            .enumerated() {
            guard case .showDocument(let title, _) = requests[index] else {
                Issue.record("expected .showDocument at \(index), got \(requests[index])")
                continue
            }
            #expect(title == expected)
        }
    }

    @Test("an unknown target surfaces upstream's error, byte-exact, and dispatches nothing")
    func unknownTargetErrors() async throws {
        let harness = try await DocsHarness.run(submitting: ["/docs not-a-real-guide"])
        // docs.rs:83-85 — including the Rust `{trimmed:?}` quoting.
        #expect(await harness.notices == [
            "Unknown docs target \"not-a-real-guide\". "
                + "Try /docs, /docs web, or a guide title (e.g. /docs Getting Started).",
        ])
        #expect(await harness.overlayRequests.isEmpty)
    }

    @Test("the unknown-target echo quotes the raw tail as Rust {:?} would")
    func unknownTargetQuotesLikeRustDebug() async throws {
        // The argument channel is the raw tail (upstream's `args.trim()`),
        // so interior quotes survive to the echo and get escaped.
        let harness = try await DocsHarness.run(submitting: ["/docs he said \"hi\""])
        #expect(await harness.notices == [
            "Unknown docs target \"he said \\\"hi\\\"\". "
                + "Try /docs, /docs web, or a guide title (e.g. /docs Getting Started).",
        ])
    }

    @Test("rustDebugQuoted escapes the named controls and backslash as Rust does")
    func rustDebugQuotedEscapes() {
        #expect(PagerDocs.rustDebugQuoted("plain") == "\"plain\"")
        #expect(PagerDocs.rustDebugQuoted("a\\b") == "\"a\\\\b\"")
        #expect(PagerDocs.rustDebugQuoted("a\nb\tc\rd") == "\"a\\nb\\tc\\rd\"")
        #expect(PagerDocs.rustDebugQuoted("bell\u{07}") == "\"bell\\u{7}\"")
    }

    // MARK: - Argument suggestions (docs.rs:46-68)

    @Test("the argument phase offers how-to, web, then every guide title in order")
    func argumentSuggestions() async throws {
        let harness = try await DocsHarness.run(events: [.paste("/docs ")])
        let states = await harness.promptStates
        let phase = states.last { $0.text == "/docs " }
        let rows = try #require(phase?.completions)
        try #require(rows.count == 2 + PagerDocs.allTitles.count)

        // docs.rs:47-60 — the two fixed rows first, descriptions verbatim.
        #expect(rows[0].name == "how-to")
        #expect(rows[0].summary == "Browse in-TUI How-to Guides")
        #expect(rows[0].insertText == "/docs how-to")
        #expect(rows[1].name == "web")
        #expect(rows[1].summary == "Open docs.x.ai/build in the browser")
        #expect(rows[1].insertText == "/docs web")

        // docs.rs:61-66 — every title, `Open "{title}"`, corpus order.
        #expect(Array(rows.dropFirst(2).map(\.name)) == PagerDocs.allTitles)
        #expect(rows[2].summary == "Open \"Getting Started\"")
        #expect(rows[2].insertText == "/docs Getting Started")
        #expect(rows.last?.summary == "Open \"Creating Custom Hooks\"")
    }

    @Test("the alias argument phase offers the same rows")
    func aliasArgumentSuggestions() async throws {
        // The argument phase hands over the typed name, not the canonical
        // one, so the alias arm must be enumerated (`/theme`/`/t` precedent).
        let harness = try await DocsHarness.run(events: [.paste("/guides ")])
        let states = await harness.promptStates
        let phase = states.last { $0.text == "/guides " }
        #expect(phase?.completions.first?.name == "how-to")
    }

    @Test("a typed query ranks the matching row first")
    func argumentQueryRanks() async throws {
        let harness = try await DocsHarness.run(events: [.paste("/docs web")])
        let states = await harness.promptStates
        let phase = states.last { $0.text == "/docs web" }
        #expect(phase?.completions.first?.name == "web")
    }

    // MARK: - Corpus integrity (docs.rs:48-188)

    @Test("all_titles pins the 26 upstream titles, in upstream order")
    func corpusTitlesAndOrder() {
        // USER_GUIDE (docs.rs:48-169) then REFERENCE_DOCS (docs.rs:175-188),
        // the chain order `find_doc`/`all_titles` share (docs.rs:193-206).
        #expect(PagerDocs.userGuide.count == 24)
        #expect(PagerDocs.referenceDocs.count == 2)
        #expect(PagerDocs.allTitles == [
            "Getting Started",
            "Authentication",
            "Keyboard Shortcuts",
            "Slash Commands",
            "Configuration",
            "Theming and Appearance",
            "MCP Servers",
            "Skills",
            "Plugins and Marketplace",
            "Hooks",
            "Custom Models",
            "Project Rules (AGENTS.md)",
            "Memory",
            "Headless Mode and Scripting",
            "Agent Mode and IDE Integration",
            "Subagents and Personas",
            "Session Management",
            "Sandbox Mode",
            "Plan Mode",
            "Background Tasks and Monitoring",
            "Terminal Support and Troubleshooting",
            "Permissions and Safety",
            "Agent Dashboard",
            "Monitoring Usage (External OpenTelemetry)",
            "Hooks & Plugins Guide",
            "Creating Custom Hooks",
        ])
    }

    @Test("the corpus content pins per-file UTF-8 counts and first lines")
    func corpusContentPins() {
        // Most counts are the reference markdown at commit 650c1db7. The
        // dashboard is a deliberate port adaptation, so its count pins the
        // current port text rather than falsely claiming upstream identity.
        let expectedByteCounts: [String: Int] = [
            "01-getting-started.md": 9267,
            "02-authentication.md": 16265,
            "03-keyboard-shortcuts.md": 23148,
            "04-slash-commands.md": 22014,
            "05-configuration.md": 49610,
            "06-theming.md": 14410,
            "07-mcp-servers.md": 16370,
            "08-skills.md": 12435,
            "09-plugins.md": 18551,
            "10-hooks.md": 27465,
            "11-custom-models.md": 17657,
            "12-project-rules.md": 9632,
            "13-memory.md": 16673,
            "14-headless-mode.md": 40790,
            "15-agent-mode.md": 11904,
            "16-subagents.md": 24775,
            "17-sessions.md": 12085,
            "18-sandbox.md": 16653,
            "19-plan-mode.md": 8901,
            "20-background-tasks.md": 10192,
            "21-terminal-support.md": 11664,
            "22-permissions-and-safety.md": 30024,
            "23-dashboard.md": 4985,
            "24-monitoring-usage.md": 13576,
            "hooks-and-plugins.md": 5181,
            "custom-hooks.md": 11861,
        ]
        for doc in PagerDocs.all {
            #expect(
                doc.content.utf8.count == expectedByteCounts[doc.filename],
                "byte count drifted for \(doc.filename)"
            )
        }

        // First lines, exact — a paraphrased or re-rendered corpus cannot
        // reproduce these together with the byte counts above.
        func firstLine(_ doc: PagerDoc) -> String {
            String(doc.content.prefix { !$0.isNewline })
        }
        #expect(firstLine(PagerDocs.userGuide[0]) == "# Getting Started")
        #expect(firstLine(PagerDocs.userGuide[4]) == "# Configuration")
        #expect(firstLine(PagerDocs.userGuide[13]) == "# Headless Mode and Scripting")
        #expect(firstLine(PagerDocs.userGuide[23]) == "# Monitoring Usage (External OpenTelemetry)")
        #expect(firstLine(PagerDocs.referenceDocs[0]) == "# Hooks & Plugins Guide")
        #expect(firstLine(PagerDocs.referenceDocs[1]) == "# Custom Hooks Guide")
    }

    @Test("dashboard docs keep deferred controls out of the live table and example")
    func dashboardDocsAdvertiseOnlyLiveBindings() throws {
        func section(_ text: String, from start: String, to end: String) -> String {
            guard let startRange = text.range(of: start) else { return "" }
            let body = text[startRange.upperBound...]
            guard let endRange = body.range(of: end) else { return String(body) }
            return String(body[..<endRange.lowerBound])
        }

        let dashboard = try #require(PagerDocs.find(title: "Agent Dashboard")?.content)
        let liveGuide = section(dashboard, from: "## What you see", to: "## Deferred controls")
        let deferredSection = section(
            dashboard,
            from: "## Deferred controls",
            to: "## Historical upstream/reference (not current behavior)"
        )
        let liveShortcuts = section(
            try #require(PagerDocs.find(title: "Keyboard Shortcuts")?.content),
            from: "## Agent Dashboard",
            to: "---"
        )
        let live = liveGuide + liveShortcuts

        for required in [
            "read-only peek",
            "Enter",
            "/resume",
            "`x`",
            "Ctrl+T",
            "Shift+↑",
            "Ctrl+G",
            "Ctrl+/",
            "←",
            "→",
            "Esc"
        ] {
            #expect(live.contains(required), "missing live dashboard control: \(required)")
        }

        for deferred in [
            "Ctrl+S",
            "Ctrl+R",
            "Ctrl+X",
            "Ctrl+O",
            "Tab",
            "dispatch composer",
            "reply box",
            "rename",
            "/cd",
            "location picker",
            "subagent",
            "question mode",
            "wide side peek",
            "worktree dialog",
            "leader bridge",
            "| `/` |"
        ] {
            #expect(
                !live.localizedCaseInsensitiveContains(deferred),
                "deferred dashboard control leaked into live docs: \(deferred)"
            )
        }

        for namedDeferred in [
            "dispatch and replies",
            "/cd",
            "SetWorkingDir",
            "location picker",
            "rename",
            "subagent peek/attach",
            "question mode",
            "wide side peek",
            "worktree dialog",
            "separate bare `/` search",
            "leader bridge"
        ] {
            #expect(
                deferredSection.localizedCaseInsensitiveContains(namedDeferred),
                "missing deferred dashboard note: \(namedDeferred)"
            )
        }
    }

    @Test("every user-guide entry is non-empty and starts with a markdown header")
    func corpusEntriesAreValid() {
        // Upstream's `user_guide_entries_are_valid` (docs.rs:269-288).
        for doc in PagerDocs.userGuide {
            #expect(!doc.content.isEmpty, "Doc \(doc.filename) is empty")
            #expect(!doc.title.isEmpty, "Doc \(doc.filename) has empty title")
            #expect(!doc.description.isEmpty, "Doc \(doc.filename) has empty description")
            #expect(
                doc.content.hasPrefix("#"),
                "Doc \(doc.filename) should start with a markdown header"
            )
        }
    }

    @Test("find(title:) resolves both tables and misses honestly")
    func findDocResolvesBothTables() {
        // Upstream's `find_doc_is_case_insensitive` and
        // `get_howto_doc_delegates_to_find_doc` (docs.rs:311-329).
        #expect(PagerDocs.find(title: "getting started")?.title == "Getting Started")
        #expect(PagerDocs.find(title: "Hooks & Plugins Guide")?.title == "Hooks & Plugins Guide")
        #expect(PagerDocs.find(title: "nonexistent guide") == nil)
    }
}

// MARK: - Harness

private actor DocsHarness {
    private let renderer: DocsRecordingRenderer
    let result: OpenGrokPagerInteractiveResult

    private init(renderer: DocsRecordingRenderer, result: OpenGrokPagerInteractiveResult) {
        self.renderer = renderer
        self.result = result
    }

    var overlayRequests: [OpenGrokPagerOverlayRequest] {
        get async { await renderer.overlayRequests }
    }
    var notices: [String] { get async { await renderer.notices } }
    var promptStates: [OpenGrokPagerInteractivePromptState] {
        get async { await renderer.promptStates }
    }
    var turnPrompts: [String] { get async { await renderer.turnPrompts } }

    /// Type a line, close the dropdown, and press Enter. The Esc matters:
    /// with the dropdown open, Enter accepts the highlighted suggestion row
    /// instead of the typed text — the fork/plan harness discipline.
    static func run(submitting lines: [String]) async throws -> DocsHarness {
        var events: [InputEvent] = []
        for line in lines {
            events.append(.paste(line))
            events.append(.key(KeyEvent(key: .escape)))
            events.append(.key(KeyEvent(key: .enter)))
        }
        return try await run(events: events)
    }

    static func run(events: [InputEvent]) async throws -> DocsHarness {
        let renderer = DocsRecordingRenderer()
        let controller = OpenGrokPagerInteractiveController(
            input: AsyncStream { continuation in
                for event in events { continuation.yield(event) }
                continuation.finish()
            },
            runtime: DocsCompletingRuntime(),
            renderer: renderer,
            output: DocsSilentOutput()
        )
        let result = try await controller.run(.init(prompt: "", mode: .inline))
        return DocsHarness(renderer: renderer, result: result)
    }
}

private actor DocsRecordingRenderer: OpenGrokPagerInteractiveRenderAdapter {
    private var events: [OpenGrokPagerInteractiveEvent] = []

    func begin() {}
    func restoreTerminal() {}

    func render(_ event: OpenGrokPagerInteractiveEvent) {
        events.append(event)
    }

    var overlayRequests: [OpenGrokPagerOverlayRequest] {
        events.compactMap { if case .overlay(let request) = $0 { return request } else { return nil } }
    }

    var notices: [String] {
        events.compactMap { if case .notice(let message) = $0 { return message } else { return nil } }
    }

    var promptStates: [OpenGrokPagerInteractivePromptState] {
        events.compactMap { if case .promptChanged(let state) = $0 { return state } else { return nil } }
    }

    var turnPrompts: [String] {
        events.compactMap { if case .turnStarted(let request) = $0 { return request.prompt } else { return nil } }
    }
}

private struct DocsCompletingRuntime: OpenGrokPagerRuntimeAdapter {
    func makeSession(
        for request: OpenGrokPagerRequest
    ) async throws -> any OpenGrokPagerSessionAdapter {
        _ = request
        return DocsCompletingSession()
    }
}

private struct DocsCompletingSession: OpenGrokPagerSessionAdapter {
    var sessionID: String? { "docs-turn" }
    var events: AsyncThrowingStream<OpenGrokPagerEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.completed(OpenGrokPagerMinimalCompletion()))
            continuation.finish()
        }
    }
    func cancel() async {}
    func close() async {}
}

private struct DocsSilentOutput: OpenGrokPagerInteractiveOutputAdapter {
    func forward(_ event: OpenGrokPagerInteractiveEvent) async throws { _ = event }
}
