// LivePlanApprovalReachabilityTests.swift
//
// Proves the dedicated `exit_plan_mode` plan-approval view is REACHED end to
// end, not merely implemented: the real registered tool invoked through the
// live `LiveToolExecutor`, the plan sheet presented by the live renderer via
// the shared `PagerPlanApprovalCoordinator`, the decision typed through
// `renderer.handleInput`, and the tool result carrying the outcome. The plan
// CONTENT is asserted painted on the sheet — the generic permission sheet
// never showed it, which is the point of the dedicated view. Gate effects
// are observed the way the plan-gate tests observe them: a non-plan write
// through the same executor is blocked while the gate is armed and flows
// once it is not, with the abandoned-disarms behavior matching upstream
// (`tool_calls.rs:1833-1854`).

import Foundation
import OpenGrokPager
import OpenGrokPagerRender
import OpenGrokSamplingTypes
import OpenGrokShared
import OpenGrokShell
import OpenGrokShellBase
import OpenGrokTerminalCore
import Testing
@testable import OpenGrokCLI

// MARK: - Fixtures

/// Runs nothing; the executor requires a backend but these tests never
/// exercise the shell.
private actor InertShellBackend: ShellProcessBackend {
    func run(_ request: ShellCommandRequest) async throws -> ShellCommandResult {
        ShellCommandResult(combinedOutput: "", stdout: "", exitCode: 0)
    }

    func runBackground(_ request: ShellCommandRequest) async throws -> ShellBackgroundHandle {
        ShellBackgroundHandle(taskID: "bg")
    }

    func getTask(_ taskID: String) async -> ShellTaskSnapshot? { nil }
    func killTask(_ taskID: String) async -> ShellKillOutcome { .notFound }
    func killForegroundCommands() async {}
    func killForegroundCommands(ownerSessionID: String) async {}
    func killAllBackgroundTasks() async {}
    func killAllBackgroundTasks(ownerSessionID: String) async {}
    func warmShell(at cwd: URL) async {}
    func backgroundForegroundCommand(toolCallID: String) async -> Bool { false }
    func waitForCompletion(_ taskID: String, timeout: ShellDuration?) async -> ShellTaskSnapshot? { nil }
    func listTasks() async -> [ShellTaskSnapshot] { [] }
    func shellCWD() async -> URL? { nil }
}

private final class CapturingSink: PagerTerminalSink, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8] = []

    var capabilities: PagerTerminalCapabilities { .standard }

    func write(bytes newBytes: [UInt8]) throws {
        lock.lock(); defer { lock.unlock() }
        bytes.append(contentsOf: newBytes)
    }

    func flush() throws {}

    var strippedText: String {
        lock.lock(); defer { lock.unlock() }
        var output = ""
        var index = 0
        while index < bytes.count {
            guard bytes[index] == 0x1B else {
                output.unicodeScalars.append(Unicode.Scalar(bytes[index]))
                index += 1
                continue
            }
            index += 1
            guard index < bytes.count else { break }
            switch bytes[index] {
            case UInt8(ascii: "["):
                index += 1
                while index < bytes.count, !(0x40...0x7E).contains(bytes[index]) {
                    index += 1
                }
                index += 1
            case UInt8(ascii: "]"):
                index += 1
                while index < bytes.count {
                    if bytes[index] == 0x07 { index += 1; break }
                    if bytes[index] == 0x1B, index + 1 < bytes.count,
                       bytes[index + 1] == UInt8(ascii: "\\") {
                        index += 2
                        break
                    }
                    index += 1
                }
            default:
                index += 1
            }
        }
        return output
    }
}

/// An isolated workspace + `$HOME`/`$OPENGROK_HOME` so the executor's hook
/// and MCP discovery cannot pick up the developer's real configuration.
private struct PlanWorkspace {
    let root: URL
    let environment: [String: String]

    init() {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("og-plan-live-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("repo", isDirectory: true)
        let home = base.appendingPathComponent("home", isDirectory: true)
        let grokHome = home.appendingPathComponent(".opengrok", isDirectory: true)
        for directory in [root, home, grokHome] {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        environment = [
            "HOME": home.path,
            "OPENGROK_HOME": grokHome.path,
        ]
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }
}

/// One armed session: executor with the plan broker installed, renderer with
/// the sheet presenter, plan mode entered and plan content on disk.
private struct ArmedPlanSession {
    let executor: LiveToolExecutor
    let renderer: LiveInteractiveControllerRenderer
    let sink: CapturingSink
    let coordinator: PagerPlanApprovalCoordinator

    static func start(
        _ workspace: PlanWorkspace,
        planContent: String?
    ) async throws -> ArmedPlanSession {
        let coordinator = PagerPlanApprovalCoordinator()
        let executor = try await LiveToolExecutor(
            processBackend: InertShellBackend(),
            sessionID: "plan-approval-live",
            workingDirectory: workspace.root,
            toolPolicy: nil,
            telemetryBootstrapContext: .empty,
            fileAccessPolicy: .allowAll,
            environment: workspace.environment,
            planApprovals: LivePlanApprovalBroker(coordinator: coordinator)
        )
        let sink = CapturingSink()
        let terminal = OpenGrokLiveTerminal(
            isTTY: { false },
            size: { OpenGrokLiveTerminalSize(width: 100, height: 30) },
            write: { _ in }
        )
        let renderer = LiveInteractiveControllerRenderer(
            mode: .fullScreen,
            terminal: terminal,
            sink: sink,
            workingDirectory: workspace.root.path,
            modelName: "test-model",
            planApprovalCoordinator: coordinator,
            paintCadence: PagerMotion.minimumPaintCadence
        )
        try await renderer.begin()
        // A real session always has a composer on screen; the bottom sheet
        // anchors to its bottom edge. Without this first prompt paint the
        // input band is degenerate and the sheet collapses to its title row.
        try await renderer.render(.promptChanged(OpenGrokPagerInteractivePromptState()))

        let entered = await executor.invoke(
            sessionID: "plan-approval-live",
            workingDirectory: workspace.root,
            call: ToolCall(id: "enter-1", name: "enter_plan_mode", arguments: "{}")
        )
        guard case .success = entered else {
            Issue.record("enter_plan_mode failed: \(entered)")
            throw CancellationError()
        }
        if let planContent {
            try planContent.write(
                to: workspace.root.appendingPathComponent(".opengrok/plan.md"),
                atomically: true,
                encoding: .utf8
            )
        }
        return ArmedPlanSession(
            executor: executor,
            renderer: renderer,
            sink: sink,
            coordinator: coordinator
        )
    }

    /// The painted frame with all whitespace removed. The diff encoder skips
    /// blank cells, so a multi-word needle can never match the raw capture —
    /// "Waiting on plan approval" arrives as "Waitingonplanapproval".
    func paintedCompact() -> String {
        sink.strippedText.filter { !$0.isWhitespace }
    }

    /// Wait until the sheet has actually painted `marker` — keys mean
    /// nothing before that. Space-insensitive for the encoder reason above.
    func waitForPaint(of marker: String) async {
        let needle = marker.filter { !$0.isWhitespace }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !paintedCompact().contains(needle) {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// Space-insensitive painted-frame assertion helper.
    func paintedContains(_ needle: String) -> Bool {
        paintedCompact().contains(needle.filter { !$0.isWhitespace })
    }

    func press(_ event: KeyEvent) async throws {
        #expect(try await renderer.handleInput(.key(event)) == .consumed)
    }

    /// Whether the plan gate is armed, observed the way the plan-gate tests
    /// observe it: a non-plan write is rejected by the gate while plan mode
    /// is active, and flows under this session's `.allowAll` policy once it
    /// is not.
    func planGateArmed(workspace: PlanWorkspace, probe: String) async -> Bool {
        let result = await executor.invoke(
            sessionID: "plan-approval-live",
            workingDirectory: workspace.root,
            call: ToolCall(
                id: "probe-\(probe)",
                name: "write",
                arguments: #"{"file_path": "probe-\#(probe).txt", "content": "probe"}"#
            )
        )
        switch result {
        case .success: return false
        case .failure: return true
        }
    }
}

private let exitPlanCall = ToolCall(id: "exit-1", name: "exit_plan_mode", arguments: "{}")

private func planKey(_ value: Character) -> KeyEvent {
    KeyEvent(key: .char(value), character: value)
}

// MARK: - Tests

@Suite("exit_plan_mode plan-approval live seam", .serialized)
struct LivePlanApprovalReachabilityTests {
    @Test("the sheet paints the plan content and `a` approves, disarming the gate")
    func approveThroughRenderer() async throws {
        let workspace = PlanWorkspace()
        defer { workspace.cleanup() }
        let plan = "# Live plan\n\nStep 1: paint me on the sheet\nStep 2: approve\n"
        let session = try await ArmedPlanSession.start(workspace, planContent: plan)
        #expect(await session.planGateArmed(workspace: workspace, probe: "before-approve"))

        let cwd = workspace.root
        let invocation = Task {
            await session.executor.invoke(
                sessionID: "plan-approval-live",
                workingDirectory: cwd,
                call: exitPlanCall
            )
        }
        await session.waitForPaint(of: "Step 1: paint me on the sheet")
        // The dedicated view's whole point: the plan body is on screen. The
        // generic permission sheet never painted it.
        #expect(session.paintedContains("Plan approval"))
        #expect(session.paintedContains("Waiting on plan approval"))
        #expect(session.paintedContains("# Live plan"))
        #expect(session.paintedContains("Step 1: paint me on the sheet"))

        try await session.press(planKey("a"))
        let result = await invocation.value
        guard case .success(let output) = result else {
            Issue.record("expected an approved tool result, got \(result)")
            try await session.renderer.restoreTerminal()
            return
        }
        #expect(output.promptText == "Your plan has been approved. You can now start coding.")
        #expect(await !session.planGateArmed(workspace: workspace, probe: "after-approve"))
        #expect(await session.coordinator.pendingCount == 0)
        try await session.renderer.restoreTerminal()
    }

    @Test("s + typed feedback + Enter returns the feedback and keeps plan mode armed")
    func reviseThroughRenderer() async throws {
        let workspace = PlanWorkspace()
        defer { workspace.cleanup() }
        let session = try await ArmedPlanSession.start(
            workspace,
            planContent: "# Live plan\n\nStep 1: revise me\n"
        )

        let cwd = workspace.root
        let invocation = Task {
            await session.executor.invoke(
                sessionID: "plan-approval-live",
                workingDirectory: cwd,
                call: exitPlanCall
            )
        }
        await session.waitForPaint(of: "Step 1: revise me")
        try await session.press(planKey("s"))
        for value in "add tests" {
            try await session.press(planKey(value))
        }
        try await session.press(KeyEvent(key: .enter))

        let result = await invocation.value
        guard case .success(let output) = result else {
            Issue.record("expected a revise tool result, got \(result)")
            try await session.renderer.restoreTerminal()
            return
        }
        // Upstream's cancelled-with-feedback shape (`tool_calls.rs:391-400`):
        // the feedback goes back to the model and the session stays in plan
        // mode (`tool_calls.rs:1856-1879`).
        #expect(output.promptText == "The user wants to revise the plan. The user said:\nadd tests")
        #expect(await session.planGateArmed(workspace: workspace, probe: "after-revise"))
        try await session.renderer.restoreTerminal()
    }

    @Test("q abandons: the do-not-retry result and the gate disarms, as upstream does")
    func abandonThroughRenderer() async throws {
        let workspace = PlanWorkspace()
        defer { workspace.cleanup() }
        let session = try await ArmedPlanSession.start(
            workspace,
            planContent: "# Live plan\n\nStep 1: abandon me\n"
        )

        let cwd = workspace.root
        let invocation = Task {
            await session.executor.invoke(
                sessionID: "plan-approval-live",
                workingDirectory: cwd,
                call: exitPlanCall
            )
        }
        await session.waitForPaint(of: "Step 1: abandon me")
        try await session.press(planKey("q"))

        let result = await invocation.value
        guard case .success(let output) = result else {
            Issue.record("expected an abandoned tool result, got \(result)")
            try await session.renderer.restoreTerminal()
            return
        }
        // Abandon *leaves* plan mode upstream (`leave_plan_mode_to_default`,
        // `tool_calls.rs:1833-1854`; resume: `LeaveOnly`, `:410-419`), so the
        // gate disarms here too.
        #expect(output.promptText.contains("The user chose to abandon the plan entirely"))
        #expect(output.promptText.contains("Plan mode has been disabled."))
        #expect(await !session.planGateArmed(workspace: workspace, probe: "after-abandon"))
        try await session.renderer.restoreTerminal()
    }

    @Test("an empty plan paints upstream's placeholder, not a blank sheet")
    func emptyPlanPlaceholderThroughRenderer() async throws {
        let workspace = PlanWorkspace()
        defer { workspace.cleanup() }
        // enter_plan_mode seeded an empty plan file; nothing written after.
        let session = try await ArmedPlanSession.start(workspace, planContent: nil)

        let cwd = workspace.root
        let invocation = Task {
            await session.executor.invoke(
                sessionID: "plan-approval-live",
                workingDirectory: cwd,
                call: exitPlanCall
            )
        }
        await session.waitForPaint(of: "No plan written yet")
        #expect(session.paintedContains("# No plan written yet"))
        // The status label's em dash crosses the cell grid in a normalized
        // byte form, so the needle is split around it; the label's words are
        // what prove the no-plan status painted.
        #expect(session.paintedContains("No plan written"))
        #expect(session.paintedContains("approve or request changes"))

        try await session.press(planKey("q"))
        let result = await invocation.value
        guard case .success = result else {
            Issue.record("expected an abandoned tool result, got \(result)")
            try await session.renderer.restoreTerminal()
            return
        }
        try await session.renderer.restoreTerminal()
    }
}
