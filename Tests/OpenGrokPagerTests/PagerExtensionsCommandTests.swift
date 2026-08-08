// PagerExtensionsCommandTests.swift
//
// `/hooks`, `/plugins`, `/marketplace`, `/skills` and `Ctrl+L` at the
// controller seam (AGENTS.md §3): real input events into the real controller,
// asserted on the overlay intents that land on the render adapter. The
// upstream contract is `xai-grok-pager/src/slash/commands/plugin.rs:15-106`
// (the four commands, metadata verbatim), `slash/commands/mod.rs:110-114`
// (display order after `/vim-mode`), and `agent_view/input.rs:1266-1271`
// (`Ctrl+L` → the Plugins tab). The live half — the painted tabs, rows, and
// empty states — is pinned in
// `Tests/OpenGrokCLITests/LiveExtensionsReachabilityTests.swift`.

import Foundation
@testable import OpenGrokPager
import OpenGrokPagerMinimal
import OpenGrokTerminalCore
import Testing

@Suite("extensions commands at the controller seam")
struct PagerExtensionsCommandTests {
    // MARK: - Registry

    @Test("the four registry rows carry upstream's names, descriptions and usage verbatim")
    func registryRowsAreVerbatim() {
        let commands = OpenGrokPagerInteractiveController.builtinCommands
        // `plugin.rs:16-26, 40-50, 64-74, 88-98`: no aliases, args optional.
        let expected: [(name: String, summary: String, usage: String)] = [
            ("hooks", "View hooks", "/hooks"),
            ("plugins", "View plugins", "/plugins"),
            ("marketplace", "View marketplace", "/marketplace"),
            ("skills", "View skills", "/skills"),
        ]
        for pin in expected {
            let row = commands.first { $0.name == pin.name }
            #expect(row != nil, "\(pin.name) is not registered")
            #expect(row?.summary == pin.summary)
            #expect(row?.usage == pin.usage)
            #expect(row?.aliases.isEmpty == true)
            #expect(row?.requiresArguments == false)
            #expect(row?.isHidden == false)
        }
    }

    @Test("display order matches upstream: after /vim-mode, before /session-info")
    func displayOrderMatchesUpstream() {
        // `slash/commands/mod.rs:110-116`: vim_mode, hooks, plugins,
        // marketplace, skills, share, session_info — `/share` is not ported,
        // so the four sit contiguously between the neighbors that are.
        let names = OpenGrokPagerInteractiveController.builtinCommands.map(\.name)
        let vimIndex = names.firstIndex(of: "vim-mode")
        #expect(vimIndex != nil)
        guard let vimIndex else { return }
        #expect(Array(names[(vimIndex + 1)...(vimIndex + 4)])
            == ["hooks", "plugins", "marketplace", "skills"])
        #expect(names[vimIndex + 5] == "session-info")
    }

    @Test("all four are visible in /help")
    func helpVisibility() {
        // A registered-but-invisible command is the Wave 15 D1 failure
        // repeating; the palette fallback parses this text too.
        let help = OpenGrokPagerInteractiveController.helpText
        #expect(help.contains("/hooks                    View hooks"))
        #expect(help.contains("/plugins                  View plugins"))
        #expect(help.contains("/marketplace              View marketplace"))
        #expect(help.contains("/skills                   View skills"))
    }

    // MARK: - Dispatch (plugin.rs:28-33, 52-57, 76-81, 100-105)

    @Test("each command opens the extensions modal on its tab")
    func commandsOpenTheirTabs() async throws {
        let harness = try await ExtensionsHarness.run(submitting: [
            "/hooks", "/plugins", "/marketplace", "/skills",
        ])
        #expect(await harness.overlayRequests == [
            .extensions(tab: .hooks),
            .extensions(tab: .plugins),
            .extensions(tab: .marketplace),
            .extensions(tab: .skills),
        ])
        // Every one is a modal open, never a model turn.
        #expect(await harness.turnPrompts.isEmpty)
    }

    @Test("arguments are ignored, matching upstream's discarded _args")
    func argumentsAreIgnored() async throws {
        // `plugin.rs:28,52,76,100` — `run(&self, _ctx, _args)` discards the
        // tail; `/hooks whatever` still opens the Hooks tab.
        let harness = try await ExtensionsHarness.run(submitting: ["/hooks whatever"])
        #expect(await harness.overlayRequests == [.extensions(tab: .hooks)])
        #expect(await harness.notices.isEmpty)
    }

    @Test("Ctrl+L opens the Plugins tab")
    func ctrlLOpensPlugins() async throws {
        // `defaults.rs:594-613` binds Ctrl+L; `agent_view/input.rs:1266-1271`
        // dispatches it to the Plugins tab.
        let harness = try await ExtensionsHarness.run(events: [
            .key(KeyEvent(key: .char("l"), modifiers: [.control])),
        ])
        #expect(await harness.overlayRequests == [.extensions(tab: .plugins)])
    }
}

// MARK: - Harness

private actor ExtensionsHarness {
    private let renderer: ExtensionsRecordingRenderer

    private init(renderer: ExtensionsRecordingRenderer) {
        self.renderer = renderer
    }

    var overlayRequests: [OpenGrokPagerOverlayRequest] {
        get async { await renderer.overlayRequests }
    }
    var notices: [String] { get async { await renderer.notices } }
    var turnPrompts: [String] { get async { await renderer.turnPrompts } }

    /// Type a line, close the dropdown, and press Enter — the Esc keeps
    /// Enter from accepting a highlighted suggestion instead of the typed
    /// text (the docs/fork harness discipline).
    static func run(submitting lines: [String]) async throws -> ExtensionsHarness {
        var events: [InputEvent] = []
        for line in lines {
            events.append(.paste(line))
            events.append(.key(KeyEvent(key: .escape)))
            events.append(.key(KeyEvent(key: .enter)))
        }
        return try await run(events: events)
    }

    static func run(events: [InputEvent]) async throws -> ExtensionsHarness {
        let renderer = ExtensionsRecordingRenderer()
        let controller = OpenGrokPagerInteractiveController(
            input: AsyncStream { continuation in
                for event in events { continuation.yield(event) }
                continuation.finish()
            },
            runtime: ExtensionsCompletingRuntime(),
            renderer: renderer,
            output: ExtensionsSilentOutput()
        )
        _ = try await controller.run(.init(prompt: "", mode: .inline))
        return ExtensionsHarness(renderer: renderer)
    }
}

private actor ExtensionsRecordingRenderer: OpenGrokPagerInteractiveRenderAdapter {
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

    var turnPrompts: [String] {
        events.compactMap { if case .turnStarted(let request) = $0 { return request.prompt } else { return nil } }
    }
}

private struct ExtensionsCompletingRuntime: OpenGrokPagerRuntimeAdapter {
    func makeSession(
        for request: OpenGrokPagerRequest
    ) async throws -> any OpenGrokPagerSessionAdapter {
        _ = request
        return ExtensionsCompletingSession()
    }
}

private struct ExtensionsCompletingSession: OpenGrokPagerSessionAdapter {
    var sessionID: String? { "extensions-turn" }
    var events: AsyncThrowingStream<OpenGrokPagerEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.completed(OpenGrokPagerMinimalCompletion()))
            continuation.finish()
        }
    }
    func cancel() async {}
    func close() async {}
}

private struct ExtensionsSilentOutput: OpenGrokPagerInteractiveOutputAdapter {
    func forward(_ event: OpenGrokPagerInteractiveEvent) async throws { _ = event }
}
