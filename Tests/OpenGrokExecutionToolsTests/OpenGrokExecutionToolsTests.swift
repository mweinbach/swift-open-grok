import Foundation
import OpenGrokExecutionTools
import OpenGrokPTY
import OpenGrokTTY
import OpenGrokWorkspace
import Testing

private final class FakePTYProcess: PTYProcess, @unchecked Sendable {
    let identifier = "pid:4242"
    let processID: Int32? = 4242
    private let chunks: [Data]
    private let exit: ProcessExit
    private let delayNanoseconds: UInt64
    private let lock = NSLock()
    private var cancelled = false

    init(chunks: [Data], exit: ProcessExit, delayNanoseconds: UInt64 = 0) {
        self.chunks = chunks
        self.exit = exit
        self.delayNanoseconds = delayNanoseconds
    }

    var wasCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func resize(to size: TerminalSize) async throws {}

    func write(_ data: Data) async throws {}

    func output() -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
    }

    func signal(_ signal: ProcessSignal) async throws {
        await cancel()
    }

    func waitForExit() async throws -> ProcessExit {
        if delayNanoseconds > 0 {
            while true {
                if cancellationState() {
                    return .signal(Int32(clamping: ProcessSignal.kill.portableValue))
                }
                try await Task.sleep(nanoseconds: min(delayNanoseconds, 10_000_000))
                if delayNanoseconds <= 10_000_000 { return exit }
            }
        }
        return exit
    }

    func cancel() async {
        markCancelled()
    }

    private func cancellationState() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    private func markCancelled() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
    }
}

private final class FakePTYAdapter: PTYAdapter, @unchecked Sendable {
    let process: FakePTYProcess
    private let lock = NSLock()
    private var recordedSpec: ProcessSpec?

    init(process: FakePTYProcess) {
        self.process = process
    }

    var spec: ProcessSpec? {
        lock.lock()
        defer { lock.unlock() }
        return recordedSpec
    }

    func spawn(_ spec: ProcessSpec) async throws -> any PTYProcess {
        record(spec)
        return process
    }

    private func record(_ spec: ProcessSpec) {
        lock.lock()
        defer { lock.unlock() }
        recordedSpec = spec
    }
}

/// Mirrors the Windows Job Object wait: cancelling the Swift task does not
/// release the waiter; only terminating the underlying process does.
private final class CancellationIgnoringPTYProcess: PTYProcess, @unchecked Sendable {
    let identifier = "pid:4343"
    let processID: Int32? = 4343

    private let lock = NSLock()
    private var cancelled = false
    private var rescued = false
    private var waiters: [CheckedContinuation<ProcessExit, Never>] = []

    var wasCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    var wasRescued: Bool {
        lock.lock()
        defer { lock.unlock() }
        return rescued
    }

    func resize(to size: TerminalSize) async throws {}

    func write(_ data: Data) async throws {}

    func output() -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in continuation.finish() }
    }

    func signal(_ signal: ProcessSignal) async throws {
        await cancel()
    }

    func waitForExit() async throws -> ProcessExit {
        await withCheckedContinuation { continuation in
            register(continuation)
        }
    }

    func cancel() async {
        terminate(rescued: false)
    }

    func rescue() async {
        terminate(rescued: true)
    }

    private func register(_ continuation: CheckedContinuation<ProcessExit, Never>) {
        lock.lock()
        if cancelled {
            lock.unlock()
            continuation.resume(returning: .signal(Int32(ProcessSignal.kill.portableValue)))
            return
        }
        waiters.append(continuation)
        lock.unlock()
    }

    private func terminate(rescued: Bool) {
        lock.lock()
        cancelled = true
        self.rescued = self.rescued || rescued
        let pending = waiters
        waiters.removeAll()
        lock.unlock()

        for continuation in pending {
            continuation.resume(returning: .signal(Int32(ProcessSignal.kill.portableValue)))
        }
    }
}

private struct CancellationIgnoringPTYAdapter: PTYAdapter {
    let process: CancellationIgnoringPTYProcess

    func spawn(_ spec: ProcessSpec) async throws -> any PTYProcess {
        process
    }
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("opengrok-execution-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("execution launch policy")
struct ExecutionLaunchPolicyTests {
    @Test("rewrites the shell launch before the PTY adapter receives it")
    func rewritesShellLaunch() async throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let adapter = FakePTYAdapter(process: FakePTYProcess(chunks: [], exit: .code(0)))
        let runtime = ExecutionToolRuntime(
            adapter: adapter,
            outputHome: home,
            launchTransform: { executable, arguments in
                #expect(executable == "/bin/sh")
                #expect(arguments == ["-lc", "printf output"])
                return ("/wrapped/sh", ["--network-denied", executable] + arguments)
            }
        )

        let result = await runtime.execute(ExecutionRequest(command: "printf output", toolCallId: "launch-rewrite"))
        guard case .success = result else {
            Issue.record("expected transformed execution to reach the adapter")
            return
        }
        #expect(adapter.spec?.command == "/wrapped/sh")
        #expect(adapter.spec?.arguments == ["--network-denied", "/bin/sh", "-lc", "printf output"])
    }

    @Test("does not spawn when the launch transform throws")
    func throwingTransformPreventsSpawn() async throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let adapter = FakePTYAdapter(process: FakePTYProcess(chunks: [], exit: .code(0)))
        let runtime = ExecutionToolRuntime(
            adapter: adapter,
            outputHome: home,
            launchTransform: { _, _ in throw NSError(domain: "launch", code: 1) }
        )

        let result = await runtime.execute(ExecutionRequest(command: "printf output", toolCallId: "launch-failure"))
        guard case .failure(let error) = result else {
            Issue.record("expected a launch-policy execution failure")
            return
        }
        #expect(error.kind == .execution)
        #expect(error.detail.contains("failed to prepare command launch"))
        #expect(adapter.spec == nil)
    }
}

@Test("execution validation applies Rust timeout and output defaults")
func executionValidationDefaultsAndCaps() throws {
    let foreground = try validateExecutionRequest(ExecutionRequest(command: "echo ok"))
    #expect(foreground.timeoutMilliseconds == executionForegroundDefaultTimeoutMilliseconds)
    #expect(foreground.outputByteLimit == executionDefaultOutputByteLimit)
    let zeroTimeout = try validateExecutionRequest(ExecutionRequest(command: "echo ok", timeoutMilliseconds: 0))
    #expect(zeroTimeout.timeoutMilliseconds == executionForegroundDefaultTimeoutMilliseconds)

    let capped = try validateExecutionRequest(
        ExecutionRequest(command: "echo ok", timeoutMilliseconds: 999_999, outputByteLimit: executionMaximumOutputByteLimit * 2)
    )
    #expect(capped.timeoutMilliseconds == executionForegroundMaximumTimeoutMilliseconds)
    #expect(capped.outputByteLimit == executionMaximumOutputByteLimit)

    let background = try validateExecutionRequest(ExecutionRequest(command: "sleep 1", isBackground: true))
    #expect(background.timeoutMilliseconds == 0)

    let explicitlyUnbounded = try validateExecutionRequest(
        ExecutionRequest(command: "sleep 1", timeoutMilliseconds: 0, isBackground: true)
    )
    #expect(explicitlyUnbounded.timeoutMilliseconds == 0)

    let boundedBackground = try validateExecutionRequest(
        ExecutionRequest(command: "sleep 1", timeoutMilliseconds: 250, isBackground: true)
    )
    #expect(boundedBackground.timeoutMilliseconds == 250)

    let cappedBackground = try validateExecutionRequest(
        ExecutionRequest(
            command: "sleep 1",
            timeoutMilliseconds: executionBackgroundMaximumTimeoutMilliseconds + 1,
            isBackground: true
        )
    )
    #expect(cappedBackground.timeoutMilliseconds == executionBackgroundMaximumTimeoutMilliseconds)
}

@Test("execution validation handles quotes and background operators deterministically")
func executionValidationErrors() throws {
    do {
        _ = try validateExecutionRequest(ExecutionRequest(command: "echo 'unterminated"))
        Issue.record("unbalanced quotes should fail")
    } catch let error as ExecutionValidationError {
        #expect(error == .unbalancedQuotes)
    }

    do {
        _ = try validateExecutionRequest(
            ExecutionRequest(command: "sleep 1 &", allowBackgroundOperator: false)
        )
        Issue.record("unquoted background operator should fail")
    } catch let error as ExecutionValidationError {
        #expect(error == .backgroundOperatorRejected)
    }

    let logicalAnd = try validateExecutionRequest(
        ExecutionRequest(command: "echo one && echo two", allowBackgroundOperator: false)
    )
    #expect(logicalAnd.request.command == "echo one && echo two")
}

@Test("bounded output retains head and tail while preserving byte totals")
func boundedOutputRetainsHeadAndTail() {
    let output = BoundedOutput(data: Data("0123456789".utf8), limit: 6)
    #expect(output.text == "012789")
    #expect(output.totalBytes == 10)
    #expect(output.truncated)
}

@Test("execution request accepts numeric strings and round-trips its wire shape")
func executionRequestWireRoundTrip() throws {
    let data = Data("{\"command\":\"echo ok\",\"timeout_ms\":\"250\",\"output_byte_limit\":\"128\",\"is_background\":false}".utf8)
    let request = try JSONDecoder().decode(ExecutionRequest.self, from: data)
    #expect(request.timeoutMilliseconds == 250)
    #expect(request.outputByteLimit == 128)
    let encoded = try JSONEncoder().encode(request)
    let decoded = try JSONDecoder().decode(ExecutionRequest.self, from: encoded)
    #expect(decoded == request)
}

@Test("foreground execution uses a shell, writes bounded output, and returns exit status")
func foregroundExecution() async throws {
    let home = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    let process = FakePTYProcess(
        chunks: [Data("0123456789".utf8)],
        exit: .code(0)
    )
    let adapter = FakePTYAdapter(process: process)
    let runtime = ExecutionToolRuntime(adapter: adapter, outputHome: home)
    let result = await runtime.execute(
        ExecutionRequest(command: "printf output", outputByteLimit: 6, toolCallId: "call-1")
    )

    guard case .success(.foreground(let value)) = result else {
        Issue.record("expected a successful foreground result, got \(result)")
        return
    }
    #expect(value.combinedOutput == "012789")
    #expect(value.totalBytes == 10)
    #expect(value.truncated)
    #expect(value.exitCode == 0)
    #expect(!value.timedOut)
    #expect(adapter.spec?.command == "/bin/sh")
    #expect(adapter.spec?.arguments == ["-lc", "printf output"])
    let fileContents = try String(contentsOfFile: value.outputFile, encoding: .utf8)
    #expect(fileContents == "0123456789")
}

@Test("foreground timeout cancels the process and reports deterministic state")
func foregroundTimeout() async throws {
    let home = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    let process = FakePTYProcess(chunks: [], exit: .code(0), delayNanoseconds: 100_000_000)
    let runtime = ExecutionToolRuntime(adapter: FakePTYAdapter(process: process), outputHome: home)
    let result = await runtime.execute(
        ExecutionRequest(command: "sleep 1", timeoutMilliseconds: 1, toolCallId: "call-timeout")
    )

    guard case .success(.foreground(let value)) = result else {
        Issue.record("expected a timeout result, got \(result)")
        return
    }
    #expect(value.timedOut)
    #expect(!value.cancelled)
    #expect(process.wasCancelled)
}

@Test("timeouts terminate a process before waiting on cancellation-insensitive adapters")
func timeoutCancelsNonCooperativeProcessBeforeJoiningWaiter() async throws {
    let home = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    let process = CancellationIgnoringPTYProcess()
    let runtime = ExecutionToolRuntime(
        adapter: CancellationIgnoringPTYAdapter(process: process),
        outputHome: home
    )

    // A bounded rescue turns the original deadlock into a deterministic test
    // failure rather than stranding the entire package verification run.
    let rescue = Task {
        do {
            try await Task.sleep(nanoseconds: 750_000_000)
            await process.rescue()
        } catch {}
    }
    defer { rescue.cancel() }

    let result = await runtime.execute(
        ExecutionRequest(command: "sleep forever", timeoutMilliseconds: 5, toolCallId: "non-cooperative")
    )
    guard case .success(.foreground(let value)) = result else {
        Issue.record("expected a timeout result, got \(result)")
        return
    }

    #expect(value.timedOut)
    #expect(process.wasCancelled)
    #expect(!process.wasRescued)
}

@Test("background commands without a positive timeout stay alive until explicitly killed")
func backgroundZeroTimeoutRemainsUnbounded() async throws {
    let timeouts: [UInt64?] = [nil, 0]
    for timeout in timeouts {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let process = FakePTYProcess(
            chunks: [],
            exit: .code(0),
            delayNanoseconds: 100_000_000
        )
        let runtime = ExecutionToolRuntime(adapter: FakePTYAdapter(process: process), outputHome: home)
        let result = await runtime.execute(ExecutionRequest(
            command: "sleep forever",
            timeoutMilliseconds: timeout,
            isBackground: true,
            toolCallId: timeout == nil ? "background-default" : "background-zero"
        ))

        guard case .success(.background(let handle)) = result else {
            Issue.record("expected a background handle, got \(result)")
            continue
        }

        let running = await runtime.waitForTask(handle.taskId, timeoutMilliseconds: 30)
        #expect(running?.completed == false)
        #expect(!process.wasCancelled)

        let killed = await runtime.killTask(handle.taskId)
        #expect(killed == .killed)
        let finished = await runtime.waitForTask(handle.taskId, timeoutMilliseconds: 500)
        #expect(finished?.completed == true)
    }
}

@Test("background execution returns a task id and supports wait and kill outcomes")
func backgroundLifecycle() async throws {
    let home = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    let process = FakePTYProcess(chunks: [Data("done".utf8)], exit: .code(0))
    let runtime = ExecutionToolRuntime(adapter: FakePTYAdapter(process: process), outputHome: home)
    let result = await runtime.execute(
        ExecutionRequest(command: "printf done", isBackground: true, toolCallId: "call-background")
    )

    guard case .success(.background(let handle)) = result else {
        Issue.record("expected a background handle, got \(result)")
        return
    }
    #expect(handle.taskId.hasPrefix("task-"))
    let snapshot = await runtime.waitForTask(handle.taskId, timeoutMilliseconds: 500)
    #expect(snapshot?.completed == true)
    #expect(snapshot?.exitCode == 0)
    let killOutcome = await runtime.killTask(handle.taskId)
    #expect(killOutcome == .alreadyExited)
}

@Test("sandbox-required workspaces fail closed before spawning")
func sandboxFailureIsTyped() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let config = WorkspaceConfig(root: root, isolation: .sandbox, requireSandbox: true)
    let workspace = LocalWorkspaceOps(config: config)
    let runtime = ExecutionToolRuntime(workspace: workspace, outputHome: root)
    let result = await runtime.execute(ExecutionRequest(command: "echo blocked", toolCallId: "call-sandbox"))

    guard case .failure(let error) = result else {
        Issue.record("sandbox-required execution should fail")
        return
    }
    #expect(error.kind == .permissionDenied)
    #expect(error.detail.contains("sandbox policy unavailable"))
}
