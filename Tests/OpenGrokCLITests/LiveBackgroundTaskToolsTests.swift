// LiveBackgroundTaskToolsTests.swift
//
// Covers the consumer half of background execution: `get_task_output`,
// `wait_tasks` and `kill_task`.
//
// The bug these tools close is that `run_terminal_cmd` hands the model a
// `task_id` — either because it asked for `is_background`, or because the
// command outran the foreground budget and was backgrounded for it — and until
// now nothing could read, wait on, or stop that task. So the assertions worth
// making are about reachability: a known id resolves, an unknown one says so
// without failing the call, and the singular spelling models actually emit
// still works.

import Foundation
import OpenGrokShared
import OpenGrokShell
import OpenGrokShellBase
import Testing
@testable import OpenGrokCLI

// MARK: - Fake process execution

/// Records the calls the tools make and replays canned snapshots.
private actor FakeProcessExecution: OpenGrokShellProcessExecution {
    nonisolated let sessionID = "session"
    nonisolated let workingDirectory = URL(fileURLWithPath: "/tmp")

    private var snapshots: [String: ShellTaskSnapshot]
    private var killOutcomes: [String: ShellKillOutcome]
    private(set) var waited: [String] = []
    private(set) var killed: [String] = []

    init(
        snapshots: [String: ShellTaskSnapshot] = [:],
        killOutcomes: [String: ShellKillOutcome] = [:]
    ) {
        self.snapshots = snapshots
        self.killOutcomes = killOutcomes
    }

    func run(_ request: ShellCommandRequest) async throws -> ShellCommandResult {
        ShellCommandResult(combinedOutput: "")
    }

    func runBackground(_ request: ShellCommandRequest) async throws -> ShellBackgroundHandle {
        ShellBackgroundHandle(taskID: "unused")
    }

    func cancel(toolCallID: String) async {}
    func cancelAll() async {}

    func killTask(_ taskID: String) async -> ShellKillOutcome {
        killed.append(taskID)
        return killOutcomes[taskID] ?? .notFound
    }

    func taskSnapshot(_ taskID: String) async -> ShellTaskSnapshot? {
        snapshots[taskID]
    }

    func waitForCompletion(_ taskID: String, timeout: ShellDuration?) async -> ShellTaskSnapshot? {
        waited.append(taskID)
        guard let snapshot = snapshots[taskID], snapshot.completed else { return nil }
        return snapshot
    }

    func listTasks() async -> [ShellTaskSnapshot] {
        snapshots.values.sorted { $0.taskID < $1.taskID }
    }
}

private func snapshot(
    _ taskID: String,
    command: String = "sleep 60",
    completed: Bool = false,
    exitCode: Int32? = nil,
    signal: String? = nil,
    explicitlyKilled: Bool = false,
    output: String = "",
    truncated: Bool = false,
    outputFile: URL? = nil
) -> ShellTaskSnapshot {
    ShellTaskSnapshot(
        taskID: taskID,
        command: command,
        cwd: URL(fileURLWithPath: "/tmp"),
        output: output,
        outputFile: outputFile,
        truncated: truncated,
        outputTotalBytes: output.utf8.count,
        exitCode: exitCode,
        signal: signal,
        completed: completed,
        explicitlyKilled: explicitlyKilled,
        ownerSessionID: "session",
        isBackgrounded: true
    )
}

private func object(
    _ result: Result<OpenGrokShellToolCallResult, OpenGrokShellToolRuntimeError>
) -> [String: JSONValue]? {
    guard case .success(let value) = result, case .object(let object) = value.value else {
        return nil
    }
    return object
}

// MARK: - Argument leniency

@Test func taskIDsAcceptTheSingularKeyModelsActuallyEmit() {
    // Upstream added this leniency after watching models mirror `kill_task`'s
    // singular `task_id` here and abandon the background workflow when the call
    // hard-failed.
    #expect(
        LiveBackgroundTaskTools.resolveTaskIDs(["task_id": .string("t1")]) == ["t1"]
    )
    #expect(
        LiveBackgroundTaskTools.resolveTaskIDs(["task_ids": .string("t1")]) == ["t1"]
    )
    #expect(
        LiveBackgroundTaskTools.resolveTaskIDs([
            "task_ids": .array([.string("t1"), .string("t2")]),
        ]) == ["t1", "t2"]
    )
}

@Test func taskIDsAreTrimmedAndDeduplicatedInFirstSeenOrder() {
    let ids = LiveBackgroundTaskTools.resolveTaskIDs([
        "task_ids": .array([
            .string(" t2 "), .string("t1"), .string("t2"), .string("   "),
        ]),
    ])
    #expect(ids == ["t2", "t1"])
}

@Test func taskIDsPreferThePluralKeyWhenBothAreSent() {
    let ids = LiveBackgroundTaskTools.resolveTaskIDs([
        "task_ids": .array([.string("plural")]),
        "task_id": .string("singular"),
    ])
    #expect(ids == ["plural"])
}

// MARK: - Status mapping

@Test func statusFollowsUpstreamsTerminalVocabulary() {
    #expect(LiveBackgroundTaskTools.status(for: snapshot("t")) == "running")
    #expect(
        LiveBackgroundTaskTools.status(
            for: snapshot("t", completed: true, exitCode: 0)
        ) == "completed"
    )
    #expect(
        LiveBackgroundTaskTools.status(
            for: snapshot("t", completed: true, exitCode: 1)
        ) == "failed"
    )
    #expect(
        LiveBackgroundTaskTools.status(
            for: snapshot("t", completed: true, signal: "SIGSEGV")
        ) == "failed"
    )
    // A task the model killed is `cancelled`, not `failed` — it did not fail,
    // it was stopped on purpose.
    #expect(
        LiveBackgroundTaskTools.status(
            for: snapshot("t", completed: true, exitCode: 143, explicitlyKilled: true)
        ) == "cancelled"
    )
}

// MARK: - Wait budget

@Test func waitCapHonorsTheEnvironmentOverride() {
    #expect(LiveBackgroundTaskTools.maxWaitBlockMilliseconds(environment: [:]) == 600_000)
    #expect(
        LiveBackgroundTaskTools.maxWaitBlockMilliseconds(
            environment: ["OPENGROK_MAX_WAIT_BLOCK_MS": "5000"]
        ) == 5_000
    )
    // Garbage falls back rather than producing a zero or negative ceiling.
    #expect(
        LiveBackgroundTaskTools.maxWaitBlockMilliseconds(
            environment: ["OPENGROK_MAX_WAIT_BLOCK_MS": "not-a-number"]
        ) == 600_000
    )
}

@Test func waitCapRendersRoundedDown() {
    // A cap must never read as longer than it is.
    #expect(LiveBackgroundTaskTools.formatWaitCap(600_000) == "600000 (~10 min)")
    #expect(LiveBackgroundTaskTools.formatWaitCap(90_000) == "90000 (~1 min)")
    #expect(LiveBackgroundTaskTools.formatWaitCap(5_500) == "5500 (~5 s)")
}

@Test func advertisedWaitCeilingMatchesTheOneActuallyEnforced() {
    // The description tells the model the ceiling; if the two ever disagree the
    // model asks for a wait its own session will silently truncate.
    let environment = ["OPENGROK_MAX_WAIT_BLOCK_MS": "5000"]
    let specs = LiveBackgroundTaskTools.toolSpecs(environment: environment)
    let getOutput = specs.first { $0.name == "get_task_output" }
    #expect(getOutput?.description?.contains("5000 (~5 s)") == true)
    #expect(getOutput?.description?.contains("600000") == false)
}

// MARK: - Tool surface

@Test func allThreeToolsAreAdvertisedWithTheirRequiredArguments() {
    let specs = LiveBackgroundTaskTools.toolSpecs(environment: [:])
    #expect(Set(specs.map(\.name)) == ["get_task_output", "wait_tasks", "kill_task"])

    for spec in specs {
        guard case .object(let schema) = spec.parameters,
              case .array(let required)? = schema["required"]
        else {
            Issue.record("\(spec.name) has no required list")
            continue
        }
        switch spec.name {
        case "get_task_output": #expect(required == [.string("task_ids")])
        case "wait_tasks": #expect(required == [.string("task_ids"), .string("mode")])
        case "kill_task": #expect(required == [.string("task_id")])
        default: Issue.record("unexpected tool \(spec.name)")
        }
    }
}

@Test func upstreamsRenamedSpellingsResolveToTheCanonicalTools() {
    // Every agent profile in `AgentDefinitionSchema` names these tools the way
    // the grok-build preset renames them, so both spellings have to resolve.
    #expect(
        LiveBackgroundTaskTools.canonicalName(for: "get_command_or_subagent_output")
            == "get_task_output"
    )
    #expect(
        LiveBackgroundTaskTools.canonicalName(for: "wait_commands_or_subagents")
            == "wait_tasks"
    )
    #expect(
        LiveBackgroundTaskTools.canonicalName(for: "kill_command_or_subagent")
            == "kill_task"
    )
    #expect(LiveBackgroundTaskTools.canonicalName(for: "get_task_output") == "get_task_output")
    #expect(LiveBackgroundTaskTools.canonicalName(for: "read_file") == nil)
}

// MARK: - get_task_output

@Test func getTaskOutputPollsWithoutBlockingWhenTimeoutIsOmitted() async {
    let process = FakeProcessExecution(snapshots: ["t1": snapshot("t1", output: "partial")])
    let result = await LiveBackgroundTaskTools.invoke(
        name: "get_task_output",
        args: .object(["task_ids": .array([.string("t1")])]),
        process: process,
        environment: [:]
    )
    let object = object(result)
    #expect(object?["task_id"] == .string("t1"))
    #expect(object?["status"] == .string("running"))
    #expect(object?["output"] == .string("partial"))
    // Omitting timeout_ms must not block, so no wait may have been issued.
    #expect(await process.waited.isEmpty)
}

@Test func getTaskOutputWaitsOnlyForAPositiveTimeout() async {
    let process = FakeProcessExecution(
        snapshots: ["t1": snapshot("t1", completed: true, exitCode: 0, output: "done")]
    )
    _ = await LiveBackgroundTaskTools.invoke(
        name: "get_task_output",
        args: .object([
            "task_ids": .array([.string("t1")]),
            "timeout_ms": .number(.int64(0)),
        ]),
        process: process,
        environment: [:]
    )
    #expect(await process.waited.isEmpty)

    _ = await LiveBackgroundTaskTools.invoke(
        name: "get_task_output",
        args: .object([
            "task_ids": .array([.string("t1")]),
            "timeout_ms": .number(.int64(1_000)),
        ]),
        process: process,
        environment: [:]
    )
    #expect(await process.waited == ["t1"])
}

@Test func getTaskOutputReportsAnUnknownIDWithoutFailingTheCall() async {
    let process = FakeProcessExecution(snapshots: ["known": snapshot("known")])
    let result = await LiveBackgroundTaskTools.invoke(
        name: "get_task_output",
        args: .object(["task_id": .string("typo")]),
        process: process,
        environment: [:]
    )
    let object = object(result)
    #expect(object?["status"] == .string("not_found"))
    // Upstream enumerates the ids the session does know so a model that
    // truncated or guessed one can correct itself without another call.
    guard case .string(let message)? = object?["message"] else {
        Issue.record("expected a not-found message")
        return
    }
    #expect(message.contains("known"))
}

@Test func multipleIDsReturnOneRowEachIncludingUnknownOnes() async {
    let process = FakeProcessExecution(
        snapshots: [
            "t1": snapshot("t1", completed: true, exitCode: 0),
            "t2": snapshot("t2"),
        ]
    )
    let result = await LiveBackgroundTaskTools.invoke(
        name: "get_task_output",
        args: .object([
            "task_ids": .array([.string("t1"), .string("t2"), .string("ghost")]),
        ]),
        process: process,
        environment: [:]
    )
    guard let object = object(result), case .array(let rows)? = object["results"] else {
        Issue.record("expected a multi-result payload")
        return
    }
    #expect(rows.count == 3)
    #expect(object["summary"] == .string("1 of 3 task(s) complete."))
}

@Test func truncatedOutputCarriesAPointerToTheFullFile() async {
    let outputFile = URL(fileURLWithPath: "/tmp/task-t1.log")
    let process = FakeProcessExecution(
        snapshots: [
            "t1": snapshot(
                "t1", completed: true, exitCode: 0,
                output: "head…", truncated: true, outputFile: outputFile
            ),
        ]
    )
    let result = await LiveBackgroundTaskTools.invoke(
        name: "get_task_output",
        args: .object(["task_ids": .array([.string("t1")])]),
        process: process,
        environment: [:]
    )
    let object = object(result)
    #expect(object?["truncated"] == .bool(true))
    #expect(object?["output_file"] == .string(outputFile.path))
    guard case .string(let hint)? = object?["truncation_hint"] else {
        Issue.record("expected a truncation hint")
        return
    }
    #expect(hint.contains(outputFile.path))
}

@Test func getTaskOutputRejectsAnEmptyIDList() async {
    let process = FakeProcessExecution()
    let result = await LiveBackgroundTaskTools.invoke(
        name: "get_task_output",
        args: .object(["task_ids": .array([])]),
        process: process,
        environment: [:]
    )
    guard case .failure(.invalidCall) = result else {
        Issue.record("expected an invalid-call failure")
        return
    }
}

// MARK: - wait_tasks

@Test func waitTasksWaitsForEveryIDInWaitAllMode() async {
    let process = FakeProcessExecution(
        snapshots: [
            "t1": snapshot("t1", completed: true, exitCode: 0),
            "t2": snapshot("t2", completed: true, exitCode: 0),
        ]
    )
    let result = await LiveBackgroundTaskTools.invoke(
        name: "wait_tasks",
        args: .object([
            "task_ids": .array([.string("t1"), .string("t2")]),
            "mode": .string("wait_all"),
        ]),
        process: process,
        environment: [:]
    )
    let object = object(result)
    #expect(object?["mode"] == .string("wait_all"))
    #expect(object?["summary"] == .string("2 of 2 task(s) complete."))
    #expect(Set(await process.waited) == ["t1", "t2"])
}

@Test func waitTasksRejectsAnUnknownMode() async {
    let process = FakeProcessExecution()
    let result = await LiveBackgroundTaskTools.invoke(
        name: "wait_tasks",
        args: .object([
            "task_ids": .array([.string("t1")]),
            "mode": .string("wait_soon"),
        ]),
        process: process,
        environment: [:]
    )
    guard case .failure(.invalidCall) = result else {
        Issue.record("expected an invalid-call failure")
        return
    }
}

// MARK: - kill_task

@Test func killTaskReportsEachOutcomeDistinctly() async {
    let process = FakeProcessExecution(
        snapshots: ["gone": snapshot("gone", completed: true, exitCode: 0)],
        killOutcomes: ["live": .killed, "gone": .alreadyExited]
    )

    let killed = object(await LiveBackgroundTaskTools.invoke(
        name: "kill_task",
        args: .object(["task_id": .string("live")]),
        process: process,
        environment: [:]
    ))
    #expect(killed?["outcome"] == .string("killed"))

    // Already exited is a success, not an error: the model asked for the task
    // to be stopped and the task is stopped.
    let exited = object(await LiveBackgroundTaskTools.invoke(
        name: "kill_task",
        args: .object(["task_id": .string("gone")]),
        process: process,
        environment: [:]
    ))
    #expect(exited?["outcome"] == .string("already_exited"))

    let missing = object(await LiveBackgroundTaskTools.invoke(
        name: "kill_task",
        args: .object(["task_id": .string("ghost")]),
        process: process,
        environment: [:]
    ))
    #expect(missing?["outcome"] == .string("not_found"))
}

@Test func killTaskRequiresATaskID() async {
    let process = FakeProcessExecution()
    let result = await LiveBackgroundTaskTools.invoke(
        name: "kill_task",
        args: .object(["task_id": .string("  ")]),
        process: process,
        environment: [:]
    )
    guard case .failure(.invalidCall) = result else {
        Issue.record("expected an invalid-call failure")
        return
    }
}

@Test func renamedSpellingsDispatchToTheSameImplementation() async {
    let process = FakeProcessExecution(killOutcomes: ["live": .killed])
    let result = object(await LiveBackgroundTaskTools.invoke(
        name: "kill_command_or_subagent",
        args: .object(["task_id": .string("live")]),
        process: process,
        environment: [:]
    ))
    #expect(result?["outcome"] == .string("killed"))
}

@Test func anUnrelatedToolNameIsRefused() async {
    let process = FakeProcessExecution()
    let result = await LiveBackgroundTaskTools.invoke(
        name: "read_file",
        args: .object([:]),
        process: process,
        environment: [:]
    )
    guard case .failure(.unsupported) = result else {
        Issue.record("expected an unsupported failure")
        return
    }
}
