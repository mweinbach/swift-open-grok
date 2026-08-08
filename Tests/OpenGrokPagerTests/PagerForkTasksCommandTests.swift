// PagerForkTasksCommandTests.swift
//
// `/fork` and `/tasks` at the controller seam (AGENTS.md §3): real input
// events into the real controller, asserted on the overlay requests and
// notices that land on the render adapter — never on registry membership
// alone. The upstream contract is `slash/commands/fork.rs` (metadata,
// `parse_fork_args` and its test catalog, fork.rs:145-337) and
// `slash/commands/tasks.rs`; every copy assertion here is byte-exact. The
// live half (the real on-disk fork, the painted tasks block) is pinned in
// `Tests/OpenGrokCLITests/LivePagerForkTasksReachabilityTests.swift`.

import Foundation
@testable import OpenGrokPager
import OpenGrokPagerMinimal
import OpenGrokTerminalCore
import Testing

@Suite("/fork and /tasks at the controller seam")
struct PagerForkTasksCommandTests {
    // MARK: - Registry

    @Test("registry rows carry upstream's names, descriptions and usage verbatim")
    func registryRowsAreVerbatim() {
        let commands = OpenGrokPagerInteractiveController.builtinCommands

        let fork = commands.first { $0.name == "fork" }
        // `fork.rs:102-116` (name, description, usage); no aliases upstream.
        #expect(fork?.summary == "Branch the current session into a peer agent")
        #expect(fork?.usage == "/fork [--worktree|--no-worktree] [directive]")
        #expect(fork?.aliases.isEmpty == true)
        // `args_required() == false` (fork.rs:122-124): a bare Enter
        // dispatches instead of parking in the argument phase.
        #expect(fork?.requiresArguments == false)

        let tasks = commands.first { $0.name == "tasks" }
        // `tasks.rs:16-30`.
        #expect(tasks?.summary == "List background tasks, subagents, and scheduled tasks")
        #expect(tasks?.usage == "/tasks")
        #expect(tasks?.aliases.isEmpty == true)
        #expect(tasks?.requiresArguments == false)

        // Registration order is display order: `/fork` follows `/new`
        // (`slash/commands/mod.rs:88-89`) and `/tasks` follows `/queue`
        // (`mod.rs:148-149`).
        let names = commands.map(\.name)
        let newIndex = names.firstIndex(of: "new")
        #expect(newIndex != nil)
        #expect(names.firstIndex(of: "fork") == newIndex.map { $0 + 1 })
        let queueIndex = names.firstIndex(of: "queue")
        #expect(queueIndex != nil)
        #expect(names.firstIndex(of: "tasks") == queueIndex.map { $0 + 1 })

        // Both commands are visible in `/help` (and therefore in the
        // palette fallback, which parses this text) — D1 shipped a
        // registered command that was invisible here.
        let help = OpenGrokPagerInteractiveController.helpText
        #expect(help.contains("/fork [directive]"))
        #expect(help.contains("/tasks"))
    }

    // MARK: - parse_fork_args catalog (fork.rs:145-256)

    @Test("empty args parse to no override and no directive")
    func parseEmpty() throws {
        let parsed = try PagerForkArguments.parse("").get()
        #expect(parsed.worktreeOverride == nil)
        #expect(parsed.directive == nil)
    }

    @Test("directive-only input parses with no override")
    func parseDirectiveOnly() throws {
        let parsed = try PagerForkArguments.parse("explore the rate-limit hypothesis").get()
        #expect(parsed.worktreeOverride == nil)
        #expect(parsed.directive == "explore the rate-limit hypothesis")
    }

    @Test("--worktree alone sets the override true")
    func parseWorktreeAlone() throws {
        let parsed = try PagerForkArguments.parse("--worktree").get()
        #expect(parsed.worktreeOverride == true)
        #expect(parsed.directive == nil)
    }

    @Test("--no-worktree alone sets the override false")
    func parseNoWorktreeAlone() throws {
        let parsed = try PagerForkArguments.parse("--no-worktree").get()
        #expect(parsed.worktreeOverride == false)
        #expect(parsed.directive == nil)
    }

    @Test("--worktree with a directive sets both")
    func parseWorktreeWithDirective() throws {
        let parsed = try PagerForkArguments.parse("--worktree investigate the bug").get()
        #expect(parsed.worktreeOverride == true)
        #expect(parsed.directive == "investigate the bug")
    }

    @Test("--no-worktree with a directive sets both")
    func parseNoWorktreeWithDirective() throws {
        let parsed = try PagerForkArguments.parse("--no-worktree quick fix").get()
        #expect(parsed.worktreeOverride == false)
        #expect(parsed.directive == "quick fix")
    }

    @Test("--worktree then --no-worktree is the mutual-exclusion error, byte-exact")
    func parseWorktreeThenNoWorktreeErrors() {
        let result = PagerForkArguments.parse("--worktree --no-worktree x")
        #expect(errorMessage(result) == "--worktree and --no-worktree are mutually exclusive")
    }

    @Test("--no-worktree then --worktree is the mutual-exclusion error, byte-exact")
    func parseNoWorktreeThenWorktreeErrors() {
        let result = PagerForkArguments.parse("--no-worktree --worktree x")
        #expect(errorMessage(result) == "--worktree and --no-worktree are mutually exclusive")
    }

    @Test("--worktree repeated is the duplicate error, byte-exact")
    func parseWorktreeRepeatedErrors() {
        let result = PagerForkArguments.parse("--worktree --worktree foo")
        #expect(errorMessage(result) == "--worktree specified twice")
    }

    @Test("--no-worktree repeated is the duplicate error, byte-exact")
    func parseNoWorktreeRepeatedErrors() {
        let result = PagerForkArguments.parse("--no-worktree --no-worktree foo")
        #expect(errorMessage(result) == "--no-worktree specified twice")
    }

    @Test("--at returns the friendly deferral error, byte-exact")
    func parseAtFlagErrors() {
        let result = PagerForkArguments.parse("--at 3 directive")
        #expect(errorMessage(result) == "--at is not supported in this version")
    }

    @Test("leading whitespace is trimmed before flag lookup")
    func parseLeadingWhitespaceTrimmed() throws {
        let parsed = try PagerForkArguments.parse("   --worktree foo bar").get()
        #expect(parsed.worktreeOverride == true)
        #expect(parsed.directive == "foo bar")
    }

    @Test("an unknown token conservatively starts the directive")
    func parseUnknownTokenStartsDirective() throws {
        // fork.rs:239-248: `/fork --foo bar` must not be rejected for a
        // typo — the directive is `--foo bar`.
        let parsed = try PagerForkArguments.parse("--foo bar").get()
        #expect(parsed.worktreeOverride == nil)
        #expect(parsed.directive == "--foo bar")
    }

    @Test("extra whitespace between flag and directive is trimmed")
    func parseExtraWhitespaceTrimmed() throws {
        let parsed = try PagerForkArguments.parse("--worktree    investigate").get()
        #expect(parsed.worktreeOverride == true)
        #expect(parsed.directive == "investigate")
    }

    @Test("interior directive whitespace survives — the raw-tail channel exists for it")
    func parseInteriorWhitespaceSurvives() throws {
        // No upstream twin (Rust keeps the slice trivially); this pins the
        // port-side hazard — a tokenizer rejoin would collapse the run.
        let parsed = try PagerForkArguments.parse("--worktree fix  the   spacing").get()
        #expect(parsed.directive == "fix  the   spacing")
    }

    private func errorMessage(
        _ result: Result<PagerForkArguments, PagerForkParseError>
    ) -> String? {
        guard case .failure(let error) = result else { return nil }
        return error.message
    }

    // MARK: - /fork dispatch

    @Test("bare /fork dispatches the fork intent with default args and starts no turn")
    func bareForkDispatches() async throws {
        let harness = try await ForkTasksHarness.run(submitting: ["/fork"])
        // fork.rs:276-288: no args → `Action::Fork` with default `ForkArgs`.
        #expect(await harness.overlayRequests == [
            .fork(worktreeOverride: nil, directive: nil),
        ])
        #expect(await harness.turnPrompts.isEmpty)
        #expect(harness.result.submittedPrompts.isEmpty)
    }

    @Test("/fork --worktree with a directive carries both on the intent")
    func forkWorktreeWithDirectiveDispatches() async throws {
        let harness = try await ForkTasksHarness.run(
            submitting: ["/fork --worktree fix the test"]
        )
        // fork.rs:290-302.
        #expect(await harness.overlayRequests == [
            .fork(worktreeOverride: true, directive: "fix the test"),
        ])
    }

    @Test("/fork --no-worktree quick fix carries the false override")
    func forkNoWorktreeDispatches() async throws {
        let harness = try await ForkTasksHarness.run(
            submitting: ["/fork --no-worktree quick fix"]
        )
        #expect(await harness.overlayRequests == [
            .fork(worktreeOverride: false, directive: "quick fix"),
        ])
    }

    @Test("conflicting flags surface the byte-exact error and dispatch nothing")
    func forkConflictingFlagsNotice() async throws {
        let harness = try await ForkTasksHarness.run(
            submitting: ["/fork --worktree --no-worktree"]
        )
        // fork.rs:304-315 maps the parse error to `CommandResult::Error`;
        // the port's error channel is the notice.
        #expect(await harness.notices.contains(
            "--worktree and --no-worktree are mutually exclusive"
        ))
        #expect(await harness.overlayRequests.isEmpty)
    }

    @Test("/fork --at surfaces the deferral error and dispatches nothing")
    func forkAtFlagNotice() async throws {
        let harness = try await ForkTasksHarness.run(submitting: ["/fork --at 5"])
        // fork.rs:317-328.
        #expect(await harness.notices.contains("--at is not supported in this version"))
        #expect(await harness.overlayRequests.isEmpty)
    }

    @Test("/fork with an unknown flag dispatches it as the directive")
    func forkUnknownFlagBecomesDirective() async throws {
        let harness = try await ForkTasksHarness.run(submitting: ["/fork --foo bar"])
        #expect(await harness.overlayRequests == [
            .fork(worktreeOverride: nil, directive: "--foo bar"),
        ])
    }

    @Test("the directive keeps its interior whitespace through the dispatch")
    func forkDirectiveKeepsInteriorWhitespace() async throws {
        // The whole reason the fork grammar reads the raw tail: the
        // tokenizer's rejoin would hand the renderer "fix  me" as "fix me".
        let harness = try await ForkTasksHarness.run(submitting: ["/fork fix  me"])
        #expect(await harness.overlayRequests == [
            .fork(worktreeOverride: nil, directive: "fix  me"),
        ])
    }

    // MARK: - /tasks dispatch

    @Test("/tasks dispatches ShowTasks; arguments are ignored")
    func tasksDispatchesShowTasks() async throws {
        let harness = try await ForkTasksHarness.run(submitting: [
            "/tasks", "/tasks whatever",
        ])
        // tasks.rs:32-37: `run` takes no arguments and discards what it
        // gets; the session-scoped "No active session" arm belongs to the
        // live renderer, the only layer that owns a session id here.
        #expect(await harness.overlayRequests == [.showTasks, .showTasks])
        #expect(await harness.turnPrompts.isEmpty)
    }

    // MARK: - Argument completion

    @Test("/fork's argument phase offers no rows and the name phase offers the command")
    func forkArgumentCompletion() async throws {
        // Upstream's `ForkCommand` defines no `suggest_args`; the directive
        // is free prose.
        let harness = try await ForkTasksHarness.run(events: [
            .paste("/fork "),
        ])
        let states = await harness.promptStates
        let argumentPhase = states.last { $0.text == "/fork " }
        #expect(argumentPhase != nil)
        #expect(argumentPhase?.completions.isEmpty == true)

        let nameHarness = try await ForkTasksHarness.run(events: [
            .paste("/for"),
        ])
        let nameStates = await nameHarness.promptStates
        let opened = nameStates.last { $0.text == "/for" }
        let row = opened?.completions.first { $0.name == "/fork" }
        #expect(row?.summary == "Branch the current session into a peer agent")
    }
}

// MARK: - Harness

private actor ForkTasksHarness {
    private let renderer: ForkTasksRecordingRenderer
    let result: OpenGrokPagerInteractiveResult

    private init(renderer: ForkTasksRecordingRenderer, result: OpenGrokPagerInteractiveResult) {
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
    /// instead of the typed text, so the submission must exercise the typed
    /// path — the same discipline the plan-command harness applies.
    static func run(submitting lines: [String]) async throws -> ForkTasksHarness {
        var events: [InputEvent] = []
        for line in lines {
            events.append(.paste(line))
            events.append(.key(KeyEvent(key: .escape)))
            events.append(.key(KeyEvent(key: .enter)))
        }
        return try await run(events: events)
    }

    static func run(events: [InputEvent]) async throws -> ForkTasksHarness {
        let renderer = ForkTasksRecordingRenderer()
        let controller = OpenGrokPagerInteractiveController(
            input: AsyncStream { continuation in
                for event in events { continuation.yield(event) }
                continuation.finish()
            },
            runtime: ForkTasksCompletingRuntime(),
            renderer: renderer,
            output: ForkTasksSilentOutput()
        )
        let result = try await controller.run(.init(prompt: "", mode: .inline))
        return ForkTasksHarness(renderer: renderer, result: result)
    }
}

private actor ForkTasksRecordingRenderer: OpenGrokPagerInteractiveRenderAdapter {
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

private struct ForkTasksCompletingRuntime: OpenGrokPagerRuntimeAdapter {
    func makeSession(
        for request: OpenGrokPagerRequest
    ) async throws -> any OpenGrokPagerSessionAdapter {
        _ = request
        return ForkTasksCompletingSession()
    }
}

private struct ForkTasksCompletingSession: OpenGrokPagerSessionAdapter {
    var sessionID: String? { "fork-tasks-turn" }
    var events: AsyncThrowingStream<OpenGrokPagerEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.completed(OpenGrokPagerMinimalCompletion()))
            continuation.finish()
        }
    }
    func cancel() async {}
    func close() async {}
}

private struct ForkTasksSilentOutput: OpenGrokPagerInteractiveOutputAdapter {
    func forward(_ event: OpenGrokPagerInteractiveEvent) async throws { _ = event }
}
