import Foundation
import Testing
import OpenGrokShared
import OpenGrokShell
import OpenGrokShellBase
import OpenGrokSamplingTypes
@testable import OpenGrokCLI

// MARK: - Classification matrix (A3)

@Test("exit 0 stays succeeded with real promptText")
func exitZeroDisplayStateSucceeded() async {
    let process = FixedShellResultProcess(
        result: ShellCommandResult(
            combinedOutput: "ok",
            exitCode: 0
        )
    )
    let outcome = await invokeTerminal(command: "true", process: process)
    guard case .success(let result) = outcome else {
        Issue.record("expected success, got \(outcome)")
        return
    }
    #expect(result.displayState == .succeeded)
    #expect(result.promptText.contains("ok"))
    #expect(result.promptText.contains("Exit code: 0"))
    #expect(!result.promptText.hasPrefix("Tool failed:"))
}

@Test("exit 7 is failed displayState but Result.success keeps promptText")
func exitSevenDisplayStateFailedKeepsPromptText() async {
    let process = FixedShellResultProcess(
        result: ShellCommandResult(
            combinedOutput: "partial stdout from failing command",
            exitCode: 7
        )
    )
    let outcome = await invokeTerminal(command: "exit 7", process: process)
    guard case .success(let result) = outcome else {
        Issue.record("expected success result with failed display, got \(outcome)")
        return
    }
    #expect(result.displayState == .failed)
    #expect(result.promptText.contains("partial stdout from failing command"))
    #expect(result.promptText.contains("Exit code: 7"))
    #expect(!result.promptText.hasPrefix("Tool failed:"))
}

@Test("signal kill is failed displayState")
func signalKillDisplayStateFailed() async {
    let process = FixedShellResultProcess(
        result: ShellCommandResult(
            combinedOutput: "interrupted",
            exitCode: nil,
            signal: "SIGKILL"
        )
    )
    let outcome = await invokeTerminal(command: "sleep 99", process: process)
    guard case .success(let result) = outcome else {
        Issue.record("expected success result with failed display, got \(outcome)")
        return
    }
    #expect(result.displayState == .failed)
    #expect(result.promptText.contains("Signal: SIGKILL"))
    #expect(!result.promptText.hasPrefix("Tool failed:"))
}

@Test("timeout is failed displayState")
func timeoutDisplayStateFailed() async {
    let process = FixedShellResultProcess(
        result: ShellCommandResult(
            combinedOutput: "partial",
            exitCode: nil,
            timedOut: true
        )
    )
    let outcome = await invokeTerminal(command: "sleep 999", process: process)
    guard case .success(let result) = outcome else {
        Issue.record("expected success result with failed display, got \(outcome)")
        return
    }
    #expect(result.displayState == .failed)
    #expect(result.promptText.contains("The command timed out."))
    #expect(!result.promptText.hasPrefix("Tool failed:"))
}

@Test("cancelled process is cancelled displayState")
func cancelledDisplayStateCancelled() async {
    let process = FixedShellResultProcess(
        result: ShellCommandResult(
            combinedOutput: "partial",
            cancelled: true
        )
    )
    let outcome = await invokeTerminal(command: "sleep 999", process: process)
    guard case .success(let result) = outcome else {
        Issue.record("expected success result with cancelled display, got \(outcome)")
        return
    }
    #expect(result.displayState == .cancelled)
    #expect(result.promptText.contains("The command was cancelled."))
}

@Test("background start stays succeeded")
func backgroundStartDisplayStateSucceeded() async {
    let process = FixedShellResultProcess(
        result: ShellCommandResult(combinedOutput: "", exitCode: 0),
        backgroundHandle: ShellBackgroundHandle(taskID: "task-bg-1", processID: 9)
    )
    let runtime = LiveRunTerminalToolRuntime(subagents: nil)
    let call = OpenGrokShellToolCall(
        sessionID: "session",
        name: "run_terminal_cmd",
        args: .object([
            "command": .string("sleep 60"),
            "is_background": .bool(true)
        ]),
        callID: "call-bg"
    )
    let outcome = await runtime.invoke(call, using: process)
    guard case .success(let result) = outcome else {
        Issue.record("expected success, got \(outcome)")
        return
    }
    #expect(result.displayState == .succeeded)
    #expect(result.promptText.contains("Background task task-bg-1 started."))
}

@Test("auto-backgrounded foreground stays succeeded")
func autoBackgroundedDisplayStateSucceeded() async {
    let process = FixedShellResultProcess(
        result: ShellCommandResult(
            combinedOutput: "partial",
            signal: "backgrounded",
            backgrounded: true,
            taskID: "task-auto-1"
        )
    )
    let outcome = await invokeTerminal(command: "sleep 60", process: process)
    guard case .success(let result) = outcome else {
        Issue.record("expected success, got \(outcome)")
        return
    }
    #expect(result.displayState == .succeeded)
}

@Test("displayState(for:) pure mapping matches matrix")
func displayStatePureMapping() {
    #expect(
        LiveRunTerminalToolRuntime.displayState(for: ShellCommandResult(
            combinedOutput: "",
            exitCode: 0
        )) == .succeeded
    )
    #expect(
        LiveRunTerminalToolRuntime.displayState(for: ShellCommandResult(
            combinedOutput: "",
            exitCode: 7
        )) == .failed
    )
    #expect(
        LiveRunTerminalToolRuntime.displayState(for: ShellCommandResult(
            combinedOutput: "",
            timedOut: true
        )) == .failed
    )
    #expect(
        LiveRunTerminalToolRuntime.displayState(for: ShellCommandResult(
            combinedOutput: "",
            signal: "SIGTERM"
        )) == .failed
    )
    #expect(
        LiveRunTerminalToolRuntime.displayState(for: ShellCommandResult(
            combinedOutput: "",
            cancelled: true
        )) == .cancelled
    )
    #expect(
        LiveRunTerminalToolRuntime.displayState(for: ShellCommandResult(
            combinedOutput: "",
            signal: "backgrounded",
            backgrounded: true
        )) == .succeeded
    )
}

// MARK: - Output sink plumbing (A5)

@Test("TaskLocal onOutput is forwarded into process.run")
func taskLocalOnOutputReachesProcessRun() async {
    actor Captured {
        var deltas: [OpenGrokShellOutputDelta] = []
        func append(_ delta: OpenGrokShellOutputDelta) { deltas.append(delta) }
        func all() -> [OpenGrokShellOutputDelta] { deltas }
    }
    let captured = Captured()
    let process = SinkRecordingProcess()
    let runtime = LiveRunTerminalToolRuntime(subagents: nil)
    let call = OpenGrokShellToolCall(
        sessionID: "session",
        name: "run_terminal_cmd",
        args: .object(["command": .string("printf hi")]),
        callID: "call-sink"
    )
    let sink: OpenGrokShellForegroundOutputSink = { delta in
        await captured.append(delta)
    }
    let outcome = await OpenGrokShellToolOutputContext.$onOutput.withValue(sink) {
        await runtime.invoke(call, using: process)
    }
    guard case .success(let result) = outcome else {
        Issue.record("expected success, got \(outcome)")
        return
    }
    #expect(result.displayState == .succeeded)
    #expect(await process.sawOnOutput() == true)
    // Recording process synthesizes one append chunk when a sink is present.
    let deltas = await captured.all()
    #expect(deltas.count == 1)
    #expect(deltas.first?.callID == "call-sink")
    #expect(deltas.first?.text == "hi")
    #expect(deltas.first?.op == .append)
}

// MARK: - Helpers

private func invokeTerminal(
    command: String,
    process: some OpenGrokShellProcessExecution
) async -> Result<OpenGrokShellToolCallResult, OpenGrokShellToolRuntimeError> {
    let runtime = LiveRunTerminalToolRuntime(subagents: nil)
    let call = OpenGrokShellToolCall(
        sessionID: "session",
        name: "run_terminal_cmd",
        args: .object(["command": .string(command)]),
        callID: "call-1"
    )
    return await runtime.invoke(call, using: process)
}

private actor FixedShellResultProcess: OpenGrokShellProcessExecution {
    nonisolated let sessionID = "session"
    nonisolated let workingDirectory = URL(fileURLWithPath: "/tmp")

    private let result: ShellCommandResult
    private let backgroundHandle: ShellBackgroundHandle?

    init(
        result: ShellCommandResult,
        backgroundHandle: ShellBackgroundHandle? = nil
    ) {
        self.result = result
        self.backgroundHandle = backgroundHandle
    }

    func run(_ request: ShellCommandRequest) async throws -> ShellCommandResult {
        result
    }

    func runBackground(_ request: ShellCommandRequest) async throws -> ShellBackgroundHandle {
        backgroundHandle ?? ShellBackgroundHandle(taskID: "unused")
    }

    func cancel(toolCallID: String) async {}
    func cancelAll() async {}
    func killTask(_ taskID: String) async -> ShellKillOutcome { .notFound }
    func taskSnapshot(_ taskID: String) async -> ShellTaskSnapshot? { nil }
    func waitForCompletion(
        _ taskID: String,
        timeout: ShellDuration?
    ) async -> ShellTaskSnapshot? { nil }
    func listTasks() async -> [ShellTaskSnapshot] { [] }
}

/// Records whether `run(_:onOutput:)` received a non-nil sink and emits one
/// synthetic append so TaskLocal → runtime → process wiring is assertable
/// without a real PTY.
private actor SinkRecordingProcess: OpenGrokShellProcessExecution {
    nonisolated let sessionID = "session"
    nonisolated let workingDirectory = URL(fileURLWithPath: "/tmp")

    private var receivedOnOutput = false

    func sawOnOutput() -> Bool { receivedOnOutput }

    func run(_ request: ShellCommandRequest) async throws -> ShellCommandResult {
        ShellCommandResult(combinedOutput: "hi", exitCode: 0)
    }

    func run(
        _ request: ShellCommandRequest,
        onOutput: OpenGrokShellForegroundOutputSink?
    ) async throws -> ShellCommandResult {
        receivedOnOutput = onOutput != nil
        if let onOutput {
            await onOutput(OpenGrokShellOutputDelta(
                callID: request.toolCallID ?? "",
                text: "hi",
                op: .append
            ))
        }
        return ShellCommandResult(combinedOutput: "hi", exitCode: 0)
    }

    func runBackground(_ request: ShellCommandRequest) async throws -> ShellBackgroundHandle {
        ShellBackgroundHandle(taskID: "unused")
    }

    func cancel(toolCallID: String) async {}
    func cancelAll() async {}
    func killTask(_ taskID: String) async -> ShellKillOutcome { .notFound }
    func taskSnapshot(_ taskID: String) async -> ShellTaskSnapshot? { nil }
    func waitForCompletion(
        _ taskID: String,
        timeout: ShellDuration?
    ) async -> ShellTaskSnapshot? { nil }
    func listTasks() async -> [ShellTaskSnapshot] { [] }
}
