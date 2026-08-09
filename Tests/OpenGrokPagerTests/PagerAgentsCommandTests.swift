// PagerAgentsCommandTests.swift
//
// `/config-agents` (alias `/agents`) and `/personas` at the controller
// seam (AGENTS.md §3): real input events into the real controller,
// asserted on the overlay intents that land on the render adapter. The
// upstream contract is `xai-grok-pager/src/slash/commands/config_agents.rs`
// and `personas.rs` (metadata verbatim), `slash/commands/mod.rs:150-153`
// (registry order after `/tutorial`), and the dispatch's optional initial
// tab (`Action::OpenConfigAgentsModal(Option<AgentsTab>)`,
// `dispatch/transcript.rs:521-523`). The live half — the painted tabs,
// rows, toggle states, and the document-overlay view route — is pinned in
// `Tests/OpenGrokCLITests/LiveAgentsReachabilityTests.swift`.

import Foundation
@testable import OpenGrokPager
import OpenGrokPagerMinimal
import OpenGrokTerminalCore
import Testing

@Suite("agents modal commands at the controller seam")
struct PagerAgentsCommandTests {
    // MARK: - Registry

    @Test("the two registry rows carry upstream's names, alias, descriptions and usage verbatim")
    func registryRowsAreVerbatim() {
        let commands = OpenGrokPagerInteractiveController.builtinCommands
        // `config_agents.rs:10-24`: name, the `agents` alias, description,
        // usage.
        let configAgents = commands.first { $0.name == "config-agents" }
        #expect(configAgents != nil)
        #expect(configAgents?.aliases == ["agents"])
        #expect(configAgents?.summary == "Manage agent definitions")
        #expect(configAgents?.usage == "/config-agents")
        #expect(configAgents?.requiresArguments == false)
        #expect(configAgents?.isHidden == false)
        // `personas.rs:11-25`: no aliases; the description is upstream's
        // own copy — the mutation verbs stay verbatim even though the b1
        // modal browses read-only (the FOOTER is where honesty about
        // handled keys lives, per AGENTS.md §4).
        let personas = commands.first { $0.name == "personas" }
        #expect(personas != nil)
        #expect(personas?.aliases.isEmpty == true)
        #expect(personas?.summary == "Manage personas (create, edit, delete)")
        #expect(personas?.usage == "/personas")
        #expect(personas?.requiresArguments == false)
        #expect(personas?.isHidden == false)
    }

    @Test("registry order matches upstream: /tutorial, /config-agents, /personas")
    func registryOrderMatchesUpstream() {
        // `slash/commands/mod.rs:150-153`: release_notes, tutorial,
        // config_agents, personas — the two new rows sit immediately after
        // `/tutorial`.
        let names = OpenGrokPagerInteractiveController.builtinCommands.map(\.name)
        let tutorialIndex = names.firstIndex(of: "tutorial")
        #expect(tutorialIndex != nil)
        guard let tutorialIndex else { return }
        #expect(Array(names[(tutorialIndex + 1)...(tutorialIndex + 2)])
            == ["config-agents", "personas"])
    }

    @Test("both rows are visible in /help")
    func helpVisibility() {
        let help = OpenGrokPagerInteractiveController.helpText
        #expect(help.contains("/config-agents  /agents   Manage agent definitions"))
        #expect(help.contains("/personas                 Manage personas (create, edit, delete)"))
    }

    // MARK: - Dispatch

    @Test("/config-agents opens the modal with no initial tab; /personas opens on Personas")
    func commandsCarryTheirInitialTabs() async throws {
        // `config_agents.rs:26-28` → `OpenConfigAgentsModal(None)`;
        // `personas.rs:27-29` → `OpenConfigAgentsModal(Some(Personas))`.
        let harness = try await AgentsHarness.run(submitting: [
            "/config-agents", "/personas",
        ])
        #expect(await harness.overlayRequests == [
            .agentsModal(initialTab: nil),
            .agentsModal(initialTab: .personas),
        ])
        // Every one is a modal open, never a model turn.
        #expect(await harness.turnPrompts.isEmpty)
    }

    @Test("the /agents alias dispatches the same intent")
    func aliasDispatches() async throws {
        // `config_agents.rs:14-16` — `aliases: ["agents"]`.
        let harness = try await AgentsHarness.run(submitting: ["/agents"])
        #expect(await harness.overlayRequests == [.agentsModal(initialTab: nil)])
    }

    @Test("arguments are ignored, matching upstream's discarded _args")
    func argumentsAreIgnored() async throws {
        // `config_agents.rs:26` / `personas.rs:27` — `run(&self, _ctx,
        // _args)` discards the tail.
        let harness = try await AgentsHarness.run(submitting: [
            "/config-agents whatever", "/personas extra words",
        ])
        #expect(await harness.overlayRequests == [
            .agentsModal(initialTab: nil),
            .agentsModal(initialTab: .personas),
        ])
        #expect(await harness.notices.isEmpty)
    }
}

// MARK: - Harness

private actor AgentsHarness {
    private let renderer: AgentsRecordingRenderer

    private init(renderer: AgentsRecordingRenderer) {
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
    static func run(submitting lines: [String]) async throws -> AgentsHarness {
        var events: [InputEvent] = []
        for line in lines {
            events.append(.paste(line))
            events.append(.key(KeyEvent(key: .escape)))
            events.append(.key(KeyEvent(key: .enter)))
        }
        let renderer = AgentsRecordingRenderer()
        let controller = OpenGrokPagerInteractiveController(
            input: AsyncStream { continuation in
                for event in events { continuation.yield(event) }
                continuation.finish()
            },
            runtime: AgentsCompletingRuntime(),
            renderer: renderer,
            output: AgentsSilentOutput()
        )
        _ = try await controller.run(.init(prompt: "", mode: .inline))
        return AgentsHarness(renderer: renderer)
    }
}

private actor AgentsRecordingRenderer: OpenGrokPagerInteractiveRenderAdapter {
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

private struct AgentsCompletingRuntime: OpenGrokPagerRuntimeAdapter {
    func makeSession(
        for request: OpenGrokPagerRequest
    ) async throws -> any OpenGrokPagerSessionAdapter {
        _ = request
        return AgentsCompletingSession()
    }
}

private struct AgentsCompletingSession: OpenGrokPagerSessionAdapter {
    var sessionID: String? { "agents-turn" }
    var events: AsyncThrowingStream<OpenGrokPagerEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.completed(OpenGrokPagerMinimalCompletion()))
            continuation.finish()
        }
    }
    func cancel() async {}
    func close() async {}
}

private struct AgentsSilentOutput: OpenGrokPagerInteractiveOutputAdapter {
    func forward(_ event: OpenGrokPagerInteractiveEvent) async throws { _ = event }
}
