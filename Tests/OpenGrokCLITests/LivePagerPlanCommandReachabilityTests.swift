// LivePagerPlanCommandReachabilityTests.swift
//
// The render-layer half of `/plan` and `/view-plan`, through the LIVE
// adapter (AGENTS.md §3): the real `LiveInteractiveControllerRenderer`
// wired to a real `LiveToolExecutor`, painting into a captured sink, with
// effects asserted where they land — the live plan gate and the painted
// frame. The seam-sharing claim is pinned in both directions: a `/plan`
// arm is observed by the real tool dispatch (a non-plan write through
// `executor.invoke` is plan-gated), and a real `enter_plan_mode` tool arm
// is observed by the slash path (idempotent toast). The controller half
// (dispatch → overlay request, mode-switch-before-prompt ordering) is
// pinned in `Tests/OpenGrokPagerTests/PagerPlanCommandTests.swift`.

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
            .appendingPathComponent("og-plan-slash-\(UUID().uuidString)", isDirectory: true)
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

/// One live session: the real executor (plan broker installed) and the real
/// renderer holding it — the exact pair the interactive composition wires.
private struct PlanCommandSession {
    let executor: LiveToolExecutor
    let renderer: LiveInteractiveControllerRenderer
    let sink: CapturingSink
    let coordinator: PagerPlanApprovalCoordinator

    static func start(_ workspace: PlanWorkspace) async throws -> PlanCommandSession {
        let coordinator = PagerPlanApprovalCoordinator()
        let executor = try await LiveToolExecutor(
            processBackend: InertShellBackend(),
            sessionID: "plan-slash-live",
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
            paintCadence: PagerMotion.minimumPaintCadence,
            environment: workspace.environment,
            toolExecutor: executor
        )
        try await renderer.begin()
        // A real session always has a composer on screen; the plan-approval
        // bottom sheet anchors to its bottom edge.
        try await renderer.render(.promptChanged(OpenGrokPagerInteractivePromptState()))
        return PlanCommandSession(
            executor: executor,
            renderer: renderer,
            sink: sink,
            coordinator: coordinator
        )
    }

    /// The painted frame with all whitespace removed — the diff encoder
    /// skips blank cells, so multi-word needles never match raw capture.
    func paintedCompact() -> String {
        sink.strippedText.filter { !$0.isWhitespace }
    }

    func waitForPaint(of marker: String) async {
        let needle = marker.filter { !$0.isWhitespace }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !paintedCompact().contains(needle) {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func paintedContains(_ needle: String) -> Bool {
        paintedCompact().contains(needle.filter { !$0.isWhitespace })
    }

    /// Whether the plan gate is armed, observed through the REAL tool
    /// dispatch: a non-plan write is rejected by the gate while plan mode is
    /// active, and flows under this session's `.allowAll` policy once it is
    /// not. This is the seam-sharing proof — the tracker `/plan` arms is the
    /// tracker the tool pipeline consults.
    func planGateArmed(workspace: PlanWorkspace, probe: String) async -> Bool {
        let result = await executor.invoke(
            sessionID: "plan-slash-live",
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

    /// Arm plan mode through the REAL registered tool, the way a model turn
    /// does — never by poking the tracker directly.
    func enterPlanModeViaTool(workspace: PlanWorkspace) async throws {
        let entered = await executor.invoke(
            sessionID: "plan-slash-live",
            workingDirectory: workspace.root,
            call: ToolCall(id: "enter-1", name: "enter_plan_mode", arguments: "{}")
        )
        guard case .success = entered else {
            Issue.record("enter_plan_mode failed: \(entered)")
            throw CancellationError()
        }
    }

    /// Write plan content at the tracker's OWN resolved path — read through
    /// the executor seam, not recomputed — so the test cannot silently pass
    /// with two different plan locations.
    func writePlanFile(_ content: String) async throws {
        guard let path = await executor.planFileResolvedPath() else {
            Issue.record("session has no plan file path")
            throw CancellationError()
        }
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
}

private func planKey(_ value: Character) -> KeyEvent {
    KeyEvent(key: .char(value), character: value)
}

// MARK: - Tests

@Suite("/plan and /view-plan live seam", .serialized)
struct LivePagerPlanCommandReachabilityTests {
    @Test("/plan arms the live plan gate the tool pipeline consults, and toasts")
    func planArmsTheLiveGate() async throws {
        let workspace = PlanWorkspace()
        defer { workspace.cleanup() }
        let session = try await PlanCommandSession.start(workspace)
        #expect(await !session.executor.planModeActive())
        #expect(await !session.planGateArmed(workspace: workspace, probe: "before-plan"))

        try await session.renderer.render(.overlay(.planModeOn))

        // The arm completed within the awaited render — the property the
        // controller's mode-switch-before-prompt ordering stands on.
        #expect(await session.executor.planModeActive())
        // Seam-sharing, tool-ward: the REAL tool dispatch now plan-gates a
        // non-plan write.
        #expect(await session.planGateArmed(workspace: workspace, probe: "after-plan"))
        // `save_success_toast("Plan mode", true)` (`settings/ui.rs:89-92`),
        // mapped to a transcript note.
        await session.waitForPaint(of: "Plan mode: on")
        #expect(session.paintedContains("Plan mode: on"))
        try await session.renderer.restoreTerminal()
    }

    @Test("/plan after the enter_plan_mode tool is idempotent: toast only, gate stays armed")
    func planIsIdempotentWithToolArm() async throws {
        let workspace = PlanWorkspace()
        defer { workspace.cleanup() }
        let session = try await PlanCommandSession.start(workspace)
        // Seam-sharing, slash-ward: the tool arms, and the slash path reads
        // the very same tracker as already-armed.
        try await session.enterPlanModeViaTool(workspace: workspace)
        #expect(await session.executor.planModeActive())

        try await session.renderer.render(.overlay(.planModeOn))

        #expect(await session.executor.planModeActive())
        #expect(await session.planGateArmed(workspace: workspace, probe: "after-idempotent"))
        await session.waitForPaint(of: "Plan mode: on")
        #expect(session.paintedContains("Plan mode: on"))
        try await session.renderer.restoreTerminal()
    }

    @Test("the /plan <description> arm intent arms the same gate before the render returns")
    func enterPlanModeIntentArmsTheGate() async throws {
        let workspace = PlanWorkspace()
        defer { workspace.cleanup() }
        let session = try await PlanCommandSession.start(workspace)
        #expect(await !session.executor.planModeActive())

        try await session.renderer.render(.overlay(.enterPlanMode))

        #expect(await session.executor.planModeActive())
        #expect(await session.planGateArmed(workspace: workspace, probe: "after-enter"))
        try await session.renderer.restoreTerminal()
    }

    @Test("/view-plan paints the on-disk plan file at the tracker's resolved path")
    func viewPlanPaintsThePlanFile() async throws {
        let workspace = PlanWorkspace()
        defer { workspace.cleanup() }
        let session = try await PlanCommandSession.start(workspace)
        // Upstream shows the saved plan whether or not plan mode is active
        // (`dispatch_show_plan` has no mode check, `modes.rs:16-25`).
        try await session.writePlanFile(
            "# Live plan\n\nStep 1: paint me in the preview\n"
        )

        try await session.renderer.render(.overlay(.showPlan))

        // Upstream titles the viewer `plan.md` (`agent_view/plan.rs:148-152`).
        await session.waitForPaint(of: "plan.md")
        #expect(session.paintedContains("plan.md"))
        await session.waitForPaint(of: "paint me in the preview")
        #expect(session.paintedContains("paint me in the preview"))
        try await session.renderer.restoreTerminal()
    }

    @Test("/view-plan with no plan on disk reports upstream's no-plan toast")
    func viewPlanWithoutPlanNotes() async throws {
        let workspace = PlanWorkspace()
        defer { workspace.cleanup() }
        let session = try await PlanCommandSession.start(workspace)

        try await session.renderer.render(.overlay(.showPlan))

        // `agent_view/plan.rs:144`, byte for byte.
        await session.waitForPaint(of: "No plan written yet.")
        #expect(session.paintedContains("No plan written yet."))
        try await session.renderer.restoreTerminal()
    }

    @Test("/view-plan with a pending exit_plan_mode approval reopens the decision sheet")
    func viewPlanReopensThePendingApproval() async throws {
        let workspace = PlanWorkspace()
        defer { workspace.cleanup() }
        let session = try await PlanCommandSession.start(workspace)
        try await session.enterPlanModeViaTool(workspace: workspace)
        try await session.writePlanFile("# Live plan\n\nStep 1: reopen me\n")

        let cwd = workspace.root
        let invocation = Task {
            await session.executor.invoke(
                sessionID: "plan-slash-live",
                workingDirectory: cwd,
                call: ToolCall(id: "exit-1", name: "exit_plan_mode", arguments: "{}")
            )
        }
        await session.waitForPaint(of: "Waiting on plan approval")
        #expect(session.paintedContains("Waiting on plan approval"))

        // `modes.rs:16-25`: with an approval pending, ShowPlan reopens the
        // sheet — never the read-only preview, which would swallow the
        // decision keys.
        try await session.renderer.render(.overlay(.showPlan))

        // The decision surface must still be live: `a` approves the
        // suspended tool call. Bounded poll before awaiting the invocation
        // so a regression fails instead of hanging the serial suite.
        #expect(try await session.renderer.handleInput(.key(planKey("a"))) == .consumed)
        let deadline = Date().addingTimeInterval(5)
        while await session.coordinator.pendingCount > 0, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        guard await session.coordinator.pendingCount == 0 else {
            let complaint =
                "`a` after /view-plan did not resolve the approval — "
                    + "ShowPlan buried the sheet under another overlay"
            Issue.record(Comment(rawValue: complaint))
            await session.coordinator.resolveAll()
            _ = await invocation.value
            try await session.renderer.restoreTerminal()
            return
        }
        let result = await invocation.value
        guard case .success(let output) = result else {
            Issue.record("expected an approved tool result, got \(result)")
            try await session.renderer.restoreTerminal()
            return
        }
        #expect(output.promptText == "Your plan has been approved. You can now start coding.")
        try await session.renderer.restoreTerminal()
    }
}
