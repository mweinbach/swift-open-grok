// PagerPlanCommandTests.swift
//
// `/plan` and `/view-plan` at the controller seam (AGENTS.md §3): real input
// events into the real controller, asserted on the overlay requests, notices
// and turn starts that land on the render adapter — never on registry
// membership alone. The upstream contract is `slash/commands/plan.rs`,
// `slash/commands/view_plan.rs` and `app/dispatch/modes.rs`; every copy
// assertion here is byte-exact. The live half (the arm reaching the real
// plan tracker, the preview painting a real plan file) is pinned in
// `Tests/OpenGrokCLITests/LivePagerPlanCommandReachabilityTests.swift`.

import Foundation
@testable import OpenGrokPager
import OpenGrokPagerMinimal
import OpenGrokTerminalCore
import Testing

@Suite("/plan and /view-plan at the controller seam")
struct PagerPlanCommandTests {
    // MARK: - Registry

    @Test("registry rows carry upstream's names, aliases, descriptions and usage verbatim")
    func registryRowsAreVerbatim() {
        let commands = OpenGrokPagerInteractiveController.builtinCommands

        let plan = commands.first { $0.name == "plan" }
        // `plan.rs:15-21` (name, description), `:33-35` (usage).
        #expect(plan?.summary == "Enter plan mode")
        #expect(plan?.usage == "/plan [description]")
        #expect(plan?.aliases.isEmpty == true)
        // `[description]` is optional (`plan.rs:41-43`), so a bare Enter
        // dispatches instead of parking in the argument phase.
        #expect(plan?.requiresArguments == false)

        let viewPlan = commands.first { $0.name == "view-plan" }
        // `view_plan.rs:10-28`. The definition sorts aliases on init.
        #expect(viewPlan?.summary == "View the current plan")
        #expect(viewPlan?.usage == "/view-plan")
        #expect(viewPlan?.aliases == ["plan-view", "show-plan"])
        #expect(viewPlan?.requiresArguments == false)

        // Registration order is display order: `/plan` follows `/remember`
        // and `/view-plan` follows `/plan` (`slash/commands/mod.rs:123-126`;
        // `/swarm`, between them upstream, is not ported).
        let names = commands.map(\.name)
        let rememberIndex = names.firstIndex(of: "remember")
        #expect(rememberIndex != nil)
        #expect(names.firstIndex(of: "plan") == rememberIndex.map { $0 + 1 })
        #expect(names.firstIndex(of: "view-plan") == rememberIndex.map { $0 + 2 })

        // The commands are visible in `/help` (and therefore in the palette
        // fallback, which parses this text) — D1 shipped a registered
        // command that was invisible here.
        let help = OpenGrokPagerInteractiveController.helpText
        #expect(help.contains("/plan [description]"))
        #expect(help.contains("/view-plan  /show-plan"))
    }

    // MARK: - /plan dispatch

    @Test("bare /plan dispatches the plan-mode arm and starts no turn")
    func barePlanDispatchesPlanModeOn() async throws {
        let harness = try await PlanCommandHarness.run(submitting: ["/plan"])
        // `plan.rs:46-48`: empty args → `SetPlanMode(On)`.
        #expect(await harness.overlayRequests == [.planModeOn])
        #expect(await harness.turnPrompts.isEmpty)
        #expect(harness.result.submittedPrompts.isEmpty)
    }

    @Test("whitespace-only arguments are treated as bare")
    func whitespaceOnlyArgsAreBare() async throws {
        // `plan.rs:46-48`: `args.trim()` empties a whitespace-only tail.
        let harness = try await PlanCommandHarness.run(submitting: ["/plan   "])
        #expect(await harness.overlayRequests == [.planModeOn])
        #expect(await harness.turnPrompts.isEmpty)
    }

    @Test("/plan <description> arms plan mode BEFORE the description's turn starts")
    func descriptionArmsBeforeTheTurnStarts() async throws {
        let harness = try await PlanCommandHarness.run(
            submitting: ["/plan Refactor the auth flow"]
        )
        let events = await harness.events
        // The mode-switch intent must be emitted (and, since `emit` awaits
        // the renderer, handled) before the turn starts — the port of
        // upstream's `SetModeThenPrompt` ordering (`dispatch/modes.rs:31-36`).
        let armIndex = events.firstIndex(of: .overlay(.enterPlanMode))
        let turnIndex = events.firstIndex { event in
            if case .turnStarted(let request) = event {
                return request.prompt == "Refactor the auth flow"
            }
            return false
        }
        #expect(armIndex != nil, "the arm intent must be emitted")
        #expect(turnIndex != nil, "the description must run as a turn")
        if let armIndex, let turnIndex {
            #expect(
                armIndex < turnIndex,
                "the mode switch must complete before the prompt dispatches"
            )
        }
        // The description reaches the model as the prompt, trimmed
        // (`plan.rs:46,50-52`).
        #expect(harness.result.submittedPrompts == ["Refactor the auth flow"])
    }

    @Test("the description is trimmed before it becomes the prompt")
    func descriptionIsTrimmed() async throws {
        let harness = try await PlanCommandHarness.run(
            submitting: ["/plan   hello world  "]
        )
        #expect(harness.result.submittedPrompts == ["hello world"])
    }

    @Test("/plan <description> while already in plan mode refuses with upstream's copy")
    func alreadyInPlanRefusesAndSendsNothing() async throws {
        let harness = try await PlanCommandHarness.run(
            submitting: ["/plan something"],
            planModeActive: true
        )
        // `dispatch/modes.rs:48-52`, byte for byte: toast, no re-arm, and —
        // load-bearing — no prompt send.
        #expect(await harness.notices.contains(
            "Already in plan mode. Use /view-plan to view the current plan."
        ))
        #expect(await harness.overlayRequests.isEmpty)
        #expect(await harness.turnPrompts.isEmpty)
        #expect(harness.result.submittedPrompts.isEmpty)
    }

    @Test("bare /plan is dispatched even when already in plan mode")
    func barePlanDispatchesWhenAlreadyInPlan() async throws {
        // Upstream's command emits `SetPlanMode(On)` regardless
        // (`plan.rs:116-129`); the idempotent toast-only behavior belongs to
        // the dispatcher — here, the live renderer.
        let harness = try await PlanCommandHarness.run(
            submitting: ["/plan"],
            planModeActive: true
        )
        #expect(await harness.overlayRequests == [.planModeOn])
    }

    // MARK: - /view-plan dispatch

    @Test("/view-plan and both aliases dispatch ShowPlan; arguments are ignored")
    func viewPlanAndAliasesDispatchShowPlan() async throws {
        let harness = try await PlanCommandHarness.run(submitting: [
            "/view-plan", "/show-plan", "/plan-view", "/view-plan whatever",
        ])
        // `view_plan.rs:14-16` (aliases), `:30-32` (run ignores args).
        #expect(await harness.overlayRequests == [
            .showPlan, .showPlan, .showPlan, .showPlan,
        ])
    }

    // MARK: - Argument completion

    @Test("/plan's argument phase offers no rows and the name phase offers the command")
    func planArgumentCompletion() async throws {
        // Upstream's `PlanCommand` defines no `suggest_args`; the
        // `[description]` argument is free prose.
        let harness = try await PlanCommandHarness.run(events: [
            .paste("/plan "),
        ])
        let states = await harness.promptStates
        let argumentPhase = states.last { $0.text == "/plan " }
        #expect(argumentPhase != nil)
        #expect(argumentPhase?.completions.isEmpty == true)

        // Name phase: the command is reachable from a partial name.
        let nameHarness = try await PlanCommandHarness.run(events: [
            .paste("/pla"),
        ])
        let nameStates = await nameHarness.promptStates
        let opened = nameStates.last { $0.text == "/pla" }
        let row = opened?.completions.first { $0.name == "/plan" }
        #expect(row?.summary == "Enter plan mode")
    }
}

// MARK: - Harness

private actor PlanCommandHarness {
    private let renderer: PlanRecordingRenderer
    let result: OpenGrokPagerInteractiveResult

    private init(renderer: PlanRecordingRenderer, result: OpenGrokPagerInteractiveResult) {
        self.renderer = renderer
        self.result = result
    }

    var events: [OpenGrokPagerInteractiveEvent] {
        get async { await renderer.allEvents }
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
    /// instead of the typed text, so the submission must exercise the typed
    /// path — the same discipline the auth-command harness applies.
    static func run(
        submitting lines: [String],
        planModeActive: Bool? = nil
    ) async throws -> PlanCommandHarness {
        var events: [InputEvent] = []
        for line in lines {
            events.append(.paste(line))
            events.append(.key(KeyEvent(key: .escape)))
            events.append(.key(KeyEvent(key: .enter)))
        }
        return try await run(events: events, planModeActive: planModeActive)
    }

    static func run(
        events: [InputEvent],
        planModeActive: Bool? = nil
    ) async throws -> PlanCommandHarness {
        let renderer = PlanRecordingRenderer()
        let controller = OpenGrokPagerInteractiveController(
            input: AsyncStream { continuation in
                for event in events { continuation.yield(event) }
                continuation.finish()
            },
            runtime: PlanCompletingRuntime(),
            renderer: renderer,
            output: PlanSilentOutput()
        )
        if let planModeActive {
            await controller.setPlanModeStateProvider { planModeActive }
        }
        let result = try await controller.run(.init(prompt: "", mode: .inline))
        return PlanCommandHarness(renderer: renderer, result: result)
    }
}

private actor PlanRecordingRenderer: OpenGrokPagerInteractiveRenderAdapter {
    private var events: [OpenGrokPagerInteractiveEvent] = []

    func begin() {}
    func restoreTerminal() {}

    func render(_ event: OpenGrokPagerInteractiveEvent) {
        events.append(event)
    }

    var allEvents: [OpenGrokPagerInteractiveEvent] { events }

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

/// A runtime whose sessions complete immediately, so `/plan <description>`
/// can drain its queued description into a real (if empty) turn — the
/// ordering assertion needs `.turnStarted` to actually be emitted.
private struct PlanCompletingRuntime: OpenGrokPagerRuntimeAdapter {
    func makeSession(
        for request: OpenGrokPagerRequest
    ) async throws -> any OpenGrokPagerSessionAdapter {
        _ = request
        return PlanCompletingSession()
    }
}

private struct PlanCompletingSession: OpenGrokPagerSessionAdapter {
    var sessionID: String? { "plan-turn" }
    var events: AsyncThrowingStream<OpenGrokPagerEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.completed(OpenGrokPagerMinimalCompletion()))
            continuation.finish()
        }
    }
    func cancel() async {}
    func close() async {}
}

private struct PlanSilentOutput: OpenGrokPagerInteractiveOutputAdapter {
    func forward(_ event: OpenGrokPagerInteractiveEvent) async throws { _ = event }
}
