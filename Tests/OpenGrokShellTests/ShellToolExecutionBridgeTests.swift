import Foundation
import Testing
import OpenGrokShared
import OpenGrokShellBase
@testable import OpenGrokShell

private actor BridgeBackend: ShellProcessBackend {
    private let blocksForeground: Bool
    private var releaseForeground = false
    private(set) var foregroundRequests: [ShellCommandRequest] = []
    private(set) var backgroundRequests: [ShellCommandRequest] = []
    private(set) var killedForegroundOwners: [String] = []
    private(set) var killedBackgroundOwners: [String] = []
    private(set) var killedTaskIDs: [String] = []

    init(blocksForeground: Bool = false) {
        self.blocksForeground = blocksForeground
    }

    func run(_ request: ShellCommandRequest) async throws -> ShellCommandResult {
        foregroundRequests.append(request)
        if blocksForeground {
            while !releaseForeground {
                do {
                    try await Task.sleep(nanoseconds: 1_000_000)
                } catch {
                    break
                }
            }
        }
        return ShellCommandResult(
            combinedOutput: "bridge-output",
            exitCode: 0,
            cancelled: releaseForeground,
            startedAt: Date(timeIntervalSince1970: 1),
            endedAt: Date(timeIntervalSince1970: 2)
        )
    }

    func runBackground(_ request: ShellCommandRequest) async throws -> ShellBackgroundHandle {
        backgroundRequests.append(request)
        return ShellBackgroundHandle(taskID: "task-1", outputFile: nil, processID: 42)
    }

    func getTask(_ taskID: String) async -> ShellTaskSnapshot? {
        guard taskID == "task-1" else { return nil }
        let request = backgroundRequests.last
        return ShellTaskSnapshot(
            taskID: taskID,
            command: request?.command ?? "background",
            cwd: request?.workingDirectory ?? URL(fileURLWithPath: "/tmp"),
            completed: false,
            ownerSessionID: request?.ownerSessionID,
            isBackgrounded: true
        )
    }

    func killTask(_ taskID: String) async -> ShellKillOutcome {
        killedTaskIDs.append(taskID)
        return taskID == "task-1" ? .killed : .notFound
    }

    func killForegroundCommands() async {}

    func killForegroundCommands(ownerSessionID: String) async {
        killedForegroundOwners.append(ownerSessionID)
        releaseForeground = true
    }

    func killAllBackgroundTasks() async {}

    func killAllBackgroundTasks(ownerSessionID: String) async {
        killedBackgroundOwners.append(ownerSessionID)
    }

    func warmShell(at cwd: URL) async {}
    func backgroundForegroundCommand(toolCallID: String) async -> Bool { false }

    func waitForCompletion(_ taskID: String, timeout: ShellDuration?) async -> ShellTaskSnapshot? {
        await getTask(taskID)
    }

    func listTasks() async -> [ShellTaskSnapshot] {
        if let task = await getTask("task-1") { return [task] }
        return []
    }

    func shellCWD() async -> URL? { nil }

    func state() -> (
        foregroundRequests: [ShellCommandRequest],
        backgroundRequests: [ShellCommandRequest],
        killedForegroundOwners: [String],
        killedBackgroundOwners: [String],
        killedTaskIDs: [String]
    ) {
        (
            foregroundRequests,
            backgroundRequests,
            killedForegroundOwners,
            killedBackgroundOwners,
            killedTaskIDs
        )
    }
}

private func bridgeRequest(
    command: String = "printf bridge",
    callID: String = "call-1",
    ownerSessionID: String? = nil,
    cwd: URL
) -> ShellCommandRequest {
    ShellCommandRequest(
        command: command,
        workingDirectory: cwd,
        timeout: .seconds(1),
        toolCallID: callID,
        ownerSessionID: ownerSessionID
    )
}

/// A backend whose foreground `run` outruns its budget and gets backgrounded,
/// which is what `autoBackgroundOnTimeout` produces in a live session.
private actor AutoBackgroundingBackend: ShellProcessBackend {
    static let taskID = "auto-task-1"
    private(set) var killedTaskIDs: [String] = []

    func run(_ request: ShellCommandRequest) async throws -> ShellCommandResult {
        ShellCommandResult(
            combinedOutput: "partial",
            backgrounded: true,
            taskID: Self.taskID
        )
    }

    func runBackground(_ request: ShellCommandRequest) async throws -> ShellBackgroundHandle {
        ShellBackgroundHandle(taskID: Self.taskID)
    }

    func getTask(_ taskID: String) async -> ShellTaskSnapshot? {
        guard taskID == Self.taskID else { return nil }
        return ShellTaskSnapshot(
            taskID: taskID,
            command: "sleep 60",
            cwd: URL(fileURLWithPath: "/tmp"),
            ownerSessionID: "session-auto",
            isBackgrounded: true
        )
    }

    func killTask(_ taskID: String) async -> ShellKillOutcome {
        killedTaskIDs.append(taskID)
        return taskID == Self.taskID ? .killed : .notFound
    }

    func killForegroundCommands() async {}
    func killForegroundCommands(ownerSessionID: String) async {}
    func killAllBackgroundTasks() async {}
    func killAllBackgroundTasks(ownerSessionID: String) async {}
    func warmShell(at cwd: URL) async {}
    func backgroundForegroundCommand(toolCallID: String) async -> Bool { false }

    func waitForCompletion(_ taskID: String, timeout: ShellDuration?) async -> ShellTaskSnapshot? {
        await getTask(taskID)
    }

    func listTasks() async -> [ShellTaskSnapshot] {
        if let task = await getTask(Self.taskID) { return [task] }
        return []
    }

    func shellCWD() async -> URL? { nil }

    func kills() -> [String] { killedTaskIDs }
}

@Test("an auto-backgrounded foreground command stays reachable by task id")
func autoBackgroundedTaskIsOwned() async throws {
    // A command the model did not ask to background — it just outran the
    // foreground budget — still hands back a task id. If that id is not
    // recorded as owned, every consumer (`get_task_output`, `wait_tasks`,
    // `kill_task`) rejects it as belonging to no one, and the model is left
    // holding an id it can never use.
    let cwd = URL(fileURLWithPath: "/tmp/bridge-auto")
    let backend = AutoBackgroundingBackend()
    let process = try OpenGrokShellOwnedProcessExecution(
        sessionID: "session-auto",
        workingDirectory: cwd,
        backend: backend
    )

    let result = try await process.run(bridgeRequest(cwd: cwd))
    #expect(result.backgrounded)
    #expect(result.taskID == AutoBackgroundingBackend.taskID)

    let snapshot = await process.taskSnapshot(AutoBackgroundingBackend.taskID)
    #expect(snapshot?.taskID == AutoBackgroundingBackend.taskID)
    #expect(await process.waitForCompletion(AutoBackgroundingBackend.taskID, timeout: .seconds(1)) != nil)
    #expect(await process.listTasks().map(\.taskID) == [AutoBackgroundingBackend.taskID])
    #expect(await process.killTask(AutoBackgroundingBackend.taskID) == .killed)
}

@Test("ownership scoping still refuses a task this session never started")
func unownedTaskIsRefused() async throws {
    let cwd = URL(fileURLWithPath: "/tmp/bridge-auto-scope")
    let process = try OpenGrokShellOwnedProcessExecution(
        sessionID: "session-auto",
        workingDirectory: cwd,
        backend: AutoBackgroundingBackend()
    )
    // Recording auto-backgrounded ids must not weaken the scope check: an id
    // this session never produced stays unreachable.
    #expect(await process.taskSnapshot(AutoBackgroundingBackend.taskID) == nil)
    #expect(await process.killTask(AutoBackgroundingBackend.taskID) == .notFound)
    #expect(await process.listTasks().isEmpty)
}

@Test("owned process execution stamps and preserves the session owner")
func ownedProcessExecutionStampsOwner() async throws {
    let cwd = URL(fileURLWithPath: "/tmp/bridge-owner")
    let backend = BridgeBackend()
    let process = try OpenGrokShellOwnedProcessExecution(
        sessionID: "session-owner",
        workingDirectory: cwd,
        backend: backend
    )

    _ = try await process.run(bridgeRequest(cwd: cwd))
    let state = await backend.state()
    #expect(state.foregroundRequests.count == 1)
    #expect(state.foregroundRequests[0].ownerSessionID == "session-owner")
    #expect(state.foregroundRequests[0].toolCallID == "call-1")

    let foreignRequest = bridgeRequest(ownerSessionID: "other-session", cwd: cwd)
    await #expect(throws: OpenGrokShellToolBridgeError.ownerMismatch(expected: "session-owner", actual: "other-session")) {
        try await process.run(foreignRequest)
    }
}

@Test("cancellation kills only foreground commands owned by the session")
func ownedForegroundCancellation() async throws {
    let cwd = URL(fileURLWithPath: "/tmp/bridge-cancel")
    let backend = BridgeBackend(blocksForeground: true)
    let process = try OpenGrokShellOwnedProcessExecution(
        sessionID: "session-cancel",
        workingDirectory: cwd,
        backend: backend
    )
    let task = Task {
        try await process.run(bridgeRequest(callID: "cancel-call", cwd: cwd))
    }

    for _ in 0 ..< 100 {
        if !(await backend.state().foregroundRequests.isEmpty) { break }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    task.cancel()
    _ = await task.result

    for _ in 0 ..< 100 {
        if !(await backend.state().killedForegroundOwners.isEmpty) { break }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    #expect(await backend.state().killedForegroundOwners == ["session-cancel"])
}

@Test("background task queries and cancellation remain session-scoped")
func ownedBackgroundTaskIsolation() async throws {
    let cwd = URL(fileURLWithPath: "/tmp/bridge-background")
    let backend = BridgeBackend()
    let process = try OpenGrokShellOwnedProcessExecution(
        sessionID: "session-background",
        workingDirectory: cwd,
        backend: backend
    )

    _ = try await process.runBackground(bridgeRequest(callID: "background-call", cwd: cwd))
    #expect(await process.taskSnapshot("task-1")?.ownerSessionID == "session-background")
    #expect(await process.taskSnapshot("other-task") == nil)
    #expect(await process.killTask("other-task") == .notFound)
    #expect(await process.killTask("task-1") == .killed)
    #expect(await backend.state().killedTaskIDs == ["task-1"])
}

@Test("runtime composition dispatches through the owned process capability")
func runtimeCompositionDispatch() async throws {
    let cwd = URL(fileURLWithPath: "/tmp/bridge-runtime")
    let backend = BridgeBackend()
    let runtime = ClosureOpenGrokShellToolRuntime { call, process in
        do {
            let result = try await process.run(
                bridgeRequest(command: "printf \(call.name)", callID: call.callID, cwd: process.workingDirectory)
            )
            return .success(
                OpenGrokShellToolCallResult(
                    value: .object(["output": .string(result.combinedOutput)]),
                    promptText: result.combinedOutput
                )
            )
        } catch let error as ShellError {
            return .failure(.unsupported(error.description))
        } catch {
            return .failure(.failed(String(describing: error)))
        }
    }
    let composition = OpenGrokShellToolRuntimeComposition(processBackend: backend, runtime: runtime)
    try await composition.registerSession(sessionID: "session-runtime", workingDirectory: cwd)

    let result = try await composition.invoke(
        sessionID: "session-runtime",
        workingDirectory: cwd,
        name: "run_terminal_cmd",
        args: .object(["command": .string("printf runtime")]),
        callID: "runtime-call"
    )
    guard case let .success(output) = result else {
        Issue.record("runtime composition did not return a successful tool result: \(result)")
        return
    }
    #expect(output.promptText == "bridge-output")
    #expect(output.value == .object(["output": .string("bridge-output")]))

    let state = await backend.state()
    #expect(state.foregroundRequests.last?.ownerSessionID == "session-runtime")
    #expect(state.foregroundRequests.last?.toolCallID == "runtime-call")

    await #expect(throws: OpenGrokShellToolBridgeError.sessionWorkingDirectoryMismatch(
        sessionID: "session-runtime",
        expected: cwd.standardizedFileURL,
        actual: URL(fileURLWithPath: "/tmp/other").standardizedFileURL
    )) {
        _ = try await composition.invoke(
            sessionID: "session-runtime",
            workingDirectory: URL(fileURLWithPath: "/tmp/other"),
            name: "run_terminal_cmd",
            args: .object([:]),
            callID: "other-call"
        )
    }
}
