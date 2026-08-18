import Foundation
import OpenGrokSandbox

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public actor LocalShellProcessBackend: ShellProcessBackend, ShellCapabilityProvider {
    public let capabilities: ShellCapabilities

    private let inheritedEnvironment: [String: String]
    private let cancellationGracePeriod: ShellDuration
    private let maximumOutputFileBytes: Int
    private let taskIDProvider: @Sendable () -> String
    private let launchTransform: @Sendable (
        _ executable: String,
        _ arguments: [String]
    ) throws -> (executable: String, arguments: [String])
    private let lifecycle = ShellProcessLifecycle()

    private var records: [String: LocalShellTaskRecord] = [:]
    private var currentCWD: URL

    public init(
        inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        capabilities: ShellCapabilities = FoundationShellCapabilities.currentCapabilities,
        cancellationGracePeriod: ShellDuration = .milliseconds(200),
        maximumOutputFileBytes: Int = 64 * 1024 * 1024,
        taskIDProvider: @escaping @Sendable () -> String = {
            "task-\(UUID().uuidString.lowercased())"
        },
        launchTransform: @escaping @Sendable (
            _ executable: String,
            _ arguments: [String]
        ) throws -> (executable: String, arguments: [String]) = childNetworkRestrictedLaunch
    ) {
        self.inheritedEnvironment = inheritedEnvironment
        self.capabilities = capabilities
        self.cancellationGracePeriod = ShellDuration(timeInterval: max(0, cancellationGracePeriod.timeInterval))
        self.maximumOutputFileBytes = max(0, maximumOutputFileBytes)
        self.taskIDProvider = taskIDProvider
        self.launchTransform = launchTransform
        self.currentCWD = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL
    }

    public func run(_ request: ShellCommandRequest) async throws -> ShellCommandResult {
        try await run(request, onChunk: nil)
    }

    /// Foreground run with optional raw output-chunk delivery (stdout/stderr as
    /// produced). Chunks are not JSON and are not persisted; callers own UTF-8
    /// assembly. `nil` matches plain `run(_:)`.
    public func run(
        _ request: ShellCommandRequest,
        onChunk: (@Sendable (Data) async -> Void)?
    ) async throws -> ShellCommandResult {
        let record = try await startTask(request, background: false)
        let deadline = foregroundDeadline(for: request)

        let pumpTask: Task<Void, Never>?
        if let onChunk {
            let stream = record.lifecycle.outputStream(taskID: record.taskID)
            pumpTask = Task {
                do {
                    for try await event in stream {
                        if case let .output(_, _, data, _) = event, !data.isEmpty {
                            await onChunk(data)
                        }
                    }
                } catch {
                    // Wait path owns terminal failure; a mid-stream error just
                    // stops progress delivery.
                }
            }
        } else {
            pumpTask = nil
        }

        let waitResult = await withTaskCancellationHandler(
            operation: {
                await record.completion.wait(timeout: deadline)
            },
            onCancel: {
                Task.detached { [weak self] in
                    await self?.stopTask(record.taskID, cause: .cancellation, explicitlyKilled: false)
                }
            }
        )

        // Drain the pump after the process completes so the final chunks are
        // not cancelled mid-flight. Cancel only on paths that never finish the
        // lifecycle stream.
        func finishPump(cancel: Bool) async {
            guard let pumpTask else { return }
            if cancel {
                pumpTask.cancel()
            }
            await pumpTask.value
        }

        switch waitResult {
        case let .completed(result):
            await finishPump(cancel: false)
            return try result.get()
        case .cancelled:
            await stopTask(record.taskID, cause: .cancellation, explicitlyKilled: false)
            await finishPump(cancel: true)
            throw ShellError.cancelled
        case .timedOut:
            if request.autoBackgroundOnTimeout, await backgroundTask(record.taskID) {
                var result = await record.capture.result(
                    taskID: record.taskID,
                    processID: record.process.processID,
                    backgrounded: true,
                    startedAt: record.startedAt,
                    endedAt: Date()
                )
                result.signal = "backgrounded"
                result.terminationReason = .backgrounded
                // Still running in background — stop progress for this call.
                await finishPump(cancel: true)
                return result
            }

            await stopTask(record.taskID, cause: .timeout, explicitlyKilled: false)
            let timedOutResult = try await waitForResult(record)
            await finishPump(cancel: false)
            return timedOutResult
        }
    }

    public func runBackground(_ request: ShellCommandRequest) async throws -> ShellBackgroundHandle {
        let record = try await startTask(request, background: true)
        return ShellBackgroundHandle(
            taskID: record.taskID,
            outputFile: request.outputFile,
            processID: record.process.processID
        )
    }

    public func getTask(_ taskID: String) async -> ShellTaskSnapshot? {
        guard records[taskID] != nil else {
            return nil
        }
        return await enrichedSnapshot(for: taskID)
    }

    public func killTask(_ taskID: String) async -> ShellKillOutcome {
        guard let record = records[taskID] else {
            return .notFound
        }
        guard let snapshot = await lifecycle.snapshot(taskID: taskID) else {
            return .notFound
        }
        guard !snapshot.completed else {
            return .alreadyExited
        }
        guard record.process.isRunning else {
            return .alreadyExited
        }

        await stopTask(taskID, cause: .cancellation, explicitlyKilled: true)
        return .killed
    }

    public func killForegroundCommands() async {
        await stopMatching { _, metadata in
            !metadata.completed && !metadata.backgrounded
        }
    }

    public func killForegroundCommands(ownerSessionID: String) async {
        await stopMatching { record, metadata in
            !metadata.completed && !metadata.backgrounded && record.request.ownerSessionID == ownerSessionID
        }
    }

    public func killAllBackgroundTasks() async {
        await stopMatching { _, metadata in
            !metadata.completed && metadata.backgrounded
        }
    }

    public func killAllBackgroundTasks(ownerSessionID: String) async {
        await stopMatching { record, metadata in
            !metadata.completed && metadata.backgrounded && record.request.ownerSessionID == ownerSessionID
        }
    }

    public func warmShell(at cwd: URL) async {
        guard let directory = try? ShellWorkingDirectory.validate(cwd) else {
            return
        }
        currentCWD = directory
    }

    public func backgroundForegroundCommand(toolCallID: String) async -> Bool {
        guard let record = records.values.first(where: {
            $0.request.toolCallID == toolCallID
        }) else {
            return false
        }
        return await backgroundTask(record.taskID)
    }

    public func waitForCompletion(_ taskID: String, timeout: ShellDuration?) async -> ShellTaskSnapshot? {
        guard let record = records[taskID] else {
            return nil
        }
        guard let snapshot = await lifecycle.waitForCompletion(taskID: taskID, timeout: timeout) else {
            return nil
        }
        if snapshot.completed {
            await record.control.markBlockWaited()
        }
        return await enrichedSnapshot(snapshot, control: record.control)
    }

    public func listTasks() async -> [ShellTaskSnapshot] {
        let snapshots = await lifecycle.list()
        var result: [ShellTaskSnapshot] = []
        result.reserveCapacity(snapshots.count)
        for snapshot in snapshots {
            guard let record = records[snapshot.taskID] else {
                result.append(snapshot)
                continue
            }
            result.append(await enrichedSnapshot(snapshot, control: record.control))
        }
        return result
    }

    public func shellCWD() async -> URL? {
        currentCWD
    }

    public func outputStream(for taskID: String) async -> AsyncThrowingStream<ShellOutputEvent, Error>? {
        guard let record = records[taskID] else {
            return nil
        }
        return record.lifecycle.outputStream(taskID: taskID)
    }

    public func processHandle(for taskID: String) async -> LocalShellProcessHandle? {
        guard let record = records[taskID] else {
            return nil
        }
        return LocalShellProcessHandle(
            taskID: taskID,
            processID: record.process.processID,
            backend: self
        )
    }

    fileprivate func send(_ signal: ShellSignal, to taskID: String) async throws {
        guard let record = records[taskID] else {
            throw ShellLifecycleTransitionError.taskNotFound(taskID)
        }
        if signal == .terminate || signal == .kill {
            _ = await record.control.requestStop(
                cause: signal == .kill ? .signal(.kill) : .cancellation,
                explicitlyKilled: false
            )
        }
        try record.process.send(signal)
    }

    fileprivate func cancel(_ taskID: String) async {
        await stopTask(taskID, cause: .cancellation, explicitlyKilled: false)
    }

    private func startTask(_ request: ShellCommandRequest, background: Bool) async throws -> LocalShellTaskRecord {
        try request.validate()
        try capabilities.require(.processExecution)
        try capabilities.require(.workingDirectory)
        try capabilities.require(.environmentOverrides)
        try capabilities.require(.outputStreaming)

        let prepared = try ShellCommandPreparation.prepare(
            request: request,
            baseWorkingDirectory: currentCWD,
            inheritedEnvironment: inheritedEnvironment,
            validateWorkingDirectory: true
        )
        let launch = try launchTransform(prepared.executable, prepared.arguments)
        let taskID = taskIDProvider().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !taskID.isEmpty else {
            throw ShellError.invalidRequest("task ID provider returned an empty identifier")
        }
        guard records[taskID] == nil else {
            throw ShellError.invalidRequest("task ID already exists: \(taskID)")
        }

        let capture = try LocalShellOutputCapture(
            outputFile: request.outputFile,
            outputByteLimit: request.outputByteLimit,
            maximumOutputFileBytes: maximumOutputFileBytes,
            lifecycle: lifecycle
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launch.executable)
        process.arguments = launch.arguments
        process.environment = prepared.environment
        process.currentDirectoryURL = prepared.workingDirectory

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let controller = LocalShellProcessController(
            process: process,
            stdout: LocalShellPipeReader(stdoutPipe),
            stderr: LocalShellPipeReader(stderrPipe)
        )
        do {
            try controller.start()
        } catch {
            await capture.close()
            throw ShellError.io("failed to spawn shell command: \(error)")
        }

        let startedAt = Date()
        do {
            _ = try await lifecycle.register(
                request: request,
                taskID: taskID,
                processID: controller.processID,
                startedAt: startedAt
            )
            try await lifecycle.transition(taskID: taskID, to: .running)
            let control = LocalShellTaskControl()
            if background {
                _ = await control.markBackgrounded()
                try await lifecycle.markBackgrounded(taskID: taskID)
            }
            let completion = LocalShellCompletionBox()
            let stdoutTask = makeReaderTask(
                reader: controller.stdout,
                channel: .stdout,
                taskID: taskID,
                capture: capture
            )
            let stderrTask = makeReaderTask(
                reader: controller.stderr,
                channel: .stderr,
                taskID: taskID,
                capture: capture
            )
            let monitor = Task.detached { [lifecycle, controller, capture, control, completion] in
                let exit = await controller.waitForExit()
                await stdoutTask.value
                await stderrTask.value
                controller.closePipes()

                let metadata = await control.snapshot()
                var result = await capture.result(
                    taskID: taskID,
                    processID: controller.processID,
                    exit: exit,
                    backgrounded: metadata.backgrounded,
                    startedAt: startedAt,
                    endedAt: Date()
                )
                let outputFailure = await capture.failureDescription()
                let completionResult: Result<ShellCommandResult, ShellError>
                if let outputFailure {
                    result.exitCode = nil
                    result.signal = "output_io_error"
                    result.terminationReason = nil
                    completionResult = .failure(.io(outputFailure))
                } else if let cause = metadata.stopCause {
                    result = ShellResultMapping.applying(cause, to: result, endedAt: Date())
                    result.backgrounded = metadata.backgrounded
                    completionResult = .success(result)
                } else {
                    if metadata.backgrounded {
                        result.backgrounded = true
                        result.signal = "backgrounded"
                        result.terminationReason = .backgrounded
                    }
                    completionResult = .success(result)
                }

                try? await lifecycle.complete(taskID: taskID, result: result)
                await capture.close()
                await control.markCompleted()
                await completion.resolve(completionResult)
            }
            let record = LocalShellTaskRecord(
                taskID: taskID,
                request: request,
                process: controller,
                capture: capture,
                lifecycle: lifecycle,
                control: control,
                completion: completion,
                startedAt: startedAt,
                monitor: monitor
            )
            records[taskID] = record
            return record
        } catch {
            try? controller.send(.terminate)
            try? controller.send(.kill)
            controller.closePipes()
            await capture.close()
            throw error
        }
    }

    private func waitForResult(_ record: LocalShellTaskRecord) async throws -> ShellCommandResult {
        let waitResult = await record.completion.wait(timeout: nil)
        switch waitResult {
        case let .completed(result):
            return try result.get()
        case .cancelled:
            throw ShellError.cancelled
        case .timedOut:
            throw ShellError.timedOut
        }
    }

    private func foregroundDeadline(for request: ShellCommandRequest) -> ShellDuration? {
        var deadline: ShellDuration?
        if request.timeout.timeInterval > 0 {
            deadline = request.timeout
        }
        if request.autoBackgroundOnTimeout,
           let budget = request.foregroundBlockBudget,
           budget.timeInterval > 0
        {
            if let current = deadline {
                deadline = min(current, budget)
            } else {
                deadline = budget
            }
        }
        return deadline
    }

    private func backgroundTask(_ taskID: String) async -> Bool {
        guard let record = records[taskID],
              let snapshot = await lifecycle.snapshot(taskID: taskID),
              !snapshot.completed
        else {
            return false
        }
        guard await record.control.markBackgrounded() else {
            return false
        }
        do {
            try await lifecycle.markBackgrounded(taskID: taskID)
            return true
        } catch {
            return false
        }
    }

    private func stopTask(
        _ taskID: String,
        cause: ShellStopCause,
        explicitlyKilled: Bool
    ) async {
        guard let record = records[taskID] else {
            return
        }
        guard await record.control.requestStop(cause: cause, explicitlyKilled: explicitlyKilled) else {
            return
        }
        await Self.stopProcess(record.process, gracePeriod: cancellationGracePeriod)
    }

    private func stopMatching(
        where predicate: @escaping @Sendable (LocalShellTaskRecord, LocalShellTaskMetadata) -> Bool
    ) async {
        var taskIDs: [String] = []
        for record in records.values {
            if predicate(record, await record.control.snapshot()) {
                taskIDs.append(record.taskID)
            }
        }
        for taskID in taskIDs {
            await stopTask(taskID, cause: .cancellation, explicitlyKilled: true)
        }
    }

    private static func stopProcess(_ process: LocalShellProcessController, gracePeriod: ShellDuration) async {
        try? process.send(.terminate)
        let nanoseconds = UInt64(max(0, gracePeriod.timeInterval) * 1_000_000_000)
        if nanoseconds > 0 {
            await Task.detached {
                try? await Task.sleep(nanoseconds: nanoseconds)
            }.value
        }
        if process.isRunning {
            try? process.send(.kill)
        }
    }

    private func enrichedSnapshot(for taskID: String) async -> ShellTaskSnapshot? {
        guard let snapshot = await lifecycle.snapshot(taskID: taskID),
              let record = records[taskID]
        else {
            return nil
        }
        return await enrichedSnapshot(snapshot, control: record.control)
    }

    private func enrichedSnapshot(
        _ snapshot: ShellTaskSnapshot,
        control: LocalShellTaskControl
    ) async -> ShellTaskSnapshot {
        let metadata = await control.snapshot()
        var result = snapshot
        result.blockWaited = metadata.blockWaited
        result.explicitlyKilled = metadata.explicitlyKilled
        result.isBackgrounded = result.isBackgrounded || metadata.backgrounded
        return result
    }

    private func makeReaderTask(
        reader: LocalShellPipeReader,
        channel: ShellOutputChannel,
        taskID: String,
        capture: LocalShellOutputCapture
    ) -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            while true {
                do {
                    guard let data = try reader.readChunk(), !data.isEmpty else {
                        break
                    }
                    // Publish through the capture actor so stdout/stderr
                    // sequences stay ordered. A concurrent hop after
                    // `append` used to drop `.output` on sequence mismatch
                    // (`try?` swallowed it) and the pager never saw a tail.
                    await capture.publish(data, channel: channel, taskID: taskID)
                } catch {
                    break
                }
            }
        }
    }
}

public struct LocalShellProcessHandle: ShellProcessHandle, Sendable {
    public let taskID: String
    public let processID: Int32?

    private let backend: LocalShellProcessBackend

    fileprivate init(taskID: String, processID: Int32?, backend: LocalShellProcessBackend) {
        self.taskID = taskID
        self.processID = processID
        self.backend = backend
    }

    public func output() -> AsyncThrowingStream<ShellOutputEvent, Error> {
        AsyncThrowingStream { continuation in
            _ = Task {
                guard let stream = await backend.outputStream(for: taskID) else {
                    continuation.finish(throwing: ShellLifecycleTransitionError.taskNotFound(taskID))
                    return
                }
                do {
                    for try await event in stream {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    public func waitForCompletion(timeout: ShellDuration?) async -> ShellTaskSnapshot? {
        await backend.waitForCompletion(taskID, timeout: timeout)
    }

    public func send(_ signal: ShellSignal) async throws {
        try await backend.send(signal, to: taskID)
    }

    public func cancel() async {
        await backend.cancel(taskID)
    }
}

private struct LocalShellTaskRecord: Sendable {
    let taskID: String
    let request: ShellCommandRequest
    let process: LocalShellProcessController
    let capture: LocalShellOutputCapture
    let lifecycle: ShellProcessLifecycle
    let control: LocalShellTaskControl
    let completion: LocalShellCompletionBox
    let startedAt: Date
    let monitor: Task<Void, Never>
}

private struct LocalShellTaskMetadata: Sendable {
    let stopCause: ShellStopCause?
    let backgrounded: Bool
    let explicitlyKilled: Bool
    let blockWaited: Bool
    let completed: Bool
}

private actor LocalShellTaskControl {
    private var stopCause: ShellStopCause?
    private var backgrounded = false
    private var explicitlyKilled = false
    private var blockWaited = false
    private var completed = false

    func requestStop(cause: ShellStopCause, explicitlyKilled: Bool) -> Bool {
        guard !completed else {
            return false
        }
        if stopCause == nil {
            stopCause = cause
        }
        self.explicitlyKilled = self.explicitlyKilled || explicitlyKilled
        return true
    }

    func markBackgrounded() -> Bool {
        guard !completed, stopCause == nil else {
            return false
        }
        backgrounded = true
        return true
    }

    func markBlockWaited() {
        blockWaited = true
    }

    func markCompleted() {
        completed = true
    }

    func snapshot() -> LocalShellTaskMetadata {
        LocalShellTaskMetadata(
            stopCause: stopCause,
            backgrounded: backgrounded,
            explicitlyKilled: explicitlyKilled,
            blockWaited: blockWaited,
            completed: completed
        )
    }
}

private enum LocalShellCompletionWait: Sendable {
    case completed(Result<ShellCommandResult, ShellError>)
    case timedOut
    case cancelled
}

private actor LocalShellCompletionBox {
    private var result: Result<ShellCommandResult, ShellError>?

    func resolve(_ result: Result<ShellCommandResult, ShellError>) {
        self.result = result
    }

    func wait(timeout: ShellDuration?) async -> LocalShellCompletionWait {
        if let result {
            return .completed(result)
        }
        let deadline = timeout.map { Date().addingTimeInterval(max(0, $0.timeInterval)) }
        while result == nil {
            if Task.isCancelled {
                return .cancelled
            }
            if let deadline, Date() >= deadline {
                return .timedOut
            }
            do {
                try await Task.sleep(nanoseconds: 10_000_000)
            } catch {
                return .cancelled
            }
        }
        return .completed(result!)
    }
}

private actor LocalShellOutputCapture {
    private var accumulator: ShellOutputAccumulator
    private let outputFile: URL?
    private let maximumOutputFileBytes: Int
    private let lifecycle: ShellProcessLifecycle
    private var fileHandle: FileHandle?
    private var fileBytesWritten = 0
    private var fileFailure: String?
    private var publishFailed = false

    init(
        outputFile: URL?,
        outputByteLimit: Int,
        maximumOutputFileBytes: Int,
        lifecycle: ShellProcessLifecycle
    ) throws {
        if let outputFile, outputFile.path.utf8.contains(0) {
            throw ShellError.invalidRequest("output file contains a NUL byte")
        }
        self.outputFile = outputFile
        self.maximumOutputFileBytes = max(0, maximumOutputFileBytes)
        self.lifecycle = lifecycle
        self.accumulator = ShellOutputAccumulator(limit: outputByteLimit)

        if let outputFile {
            try FileManager.default.createDirectory(
                at: outputFile.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: outputFile.path) {
                guard FileManager.default.createFile(atPath: outputFile.path, contents: nil) else {
                    throw ShellError.io("could not create output file at \(outputFile.path)")
                }
            }
            let handle = try FileHandle(forWritingTo: outputFile)
            try handle.seek(toOffset: 0)
            try handle.truncate(atOffset: 0)
            self.fileHandle = handle
        }
    }

    func append(_ data: Data, channel: ShellOutputChannel, taskID: String) -> ShellOutputEvent {
        let event = accumulator.append(data, channel: channel, taskID: taskID)
        guard let fileHandle, fileFailure == nil, fileBytesWritten < maximumOutputFileBytes else {
            return event
        }
        let count = min(data.count, maximumOutputFileBytes - fileBytesWritten)
        guard count > 0 else {
            return event
        }
        do {
            try fileHandle.write(contentsOf: Data(data.prefix(count)))
            fileBytesWritten += count
        } catch {
            fileFailure = "writing output file \(outputFile?.path ?? "") failed: \(error)"
        }
        return event
    }

    /// Accumulate, then emit `.output` on the lifecycle stream from this
    /// actor so stdout/stderr cannot race the sequence counter.
    func publish(_ data: Data, channel: ShellOutputChannel, taskID: String) async {
        let event = append(data, channel: channel, taskID: taskID)
        guard !publishFailed, case let .output(_, _, payload, sequence) = event else {
            return
        }
        do {
            try await lifecycle.appendOutput(
                taskID: taskID,
                channel: channel,
                data: payload,
                sequence: sequence
            )
        } catch {
            publishFailed = true
        }
    }

    func result(
        taskID: String,
        processID: Int32?,
        exit: LocalShellProcessExit? = nil,
        backgrounded: Bool = false,
        startedAt: Date,
        endedAt: Date
    ) -> ShellCommandResult {
        let exitCode = exit?.code
        let signal = exit?.signal.map(Self.signalName)
        var result = accumulator.result(
            taskID: taskID,
            processID: processID,
            outputFile: outputFile,
            exitCode: exitCode,
            signal: signal,
            backgrounded: backgrounded,
            startedAt: startedAt,
            endedAt: endedAt
        )
        if let signal = exit?.signal {
            result.terminationReason = .signal(Self.shellSignal(for: signal))
        }
        return result
    }

    func failureDescription() -> String? {
        fileFailure
    }

    func close() {
        try? fileHandle?.close()
        fileHandle = nil
    }

    private static func signalName(_ value: Int32) -> String {
        switch value {
        case 1: return "SIGHUP"
        case 2: return "SIGINT"
        case 9: return "SIGKILL"
        case 15: return "SIGTERM"
        default: return "SIG\(value)"
        }
    }

    private static func shellSignal(for value: Int32) -> ShellSignal {
        switch value {
        case 1: return .hangup
        case 2: return .interrupt
        case 9: return .kill
        default: return .terminate
        }
    }
}

private final class LocalShellPipeReader: @unchecked Sendable {
    private let pipe: Pipe
    private let handle: FileHandle

    init(_ pipe: Pipe) {
        self.pipe = pipe
        self.handle = pipe.fileHandleForReading
    }

    /// One POSIX `read` of whatever is currently in the pipe. Foundation's
    /// `FileHandle.read(upToCount:)` waits for the requested count or EOF
    /// (`readData(ofLength:)`), so a 64 KiB request coalesced `printf one;
    /// sleep; printf two` into a single post-exit blob and the live tail
    /// never moved. `read(2)` returns as soon as any byte is available.
    func readChunk() throws -> Data? {
        #if canImport(Darwin) || canImport(Glibc)
        let fd = handle.fileDescriptor
        guard fd >= 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n: ssize_t
            #if canImport(Darwin)
            n = Darwin.read(fd, &buffer, buffer.count)
            #else
            n = Glibc.read(fd, &buffer, buffer.count)
            #endif
            if n == 0 {
                return nil
            }
            if n > 0 {
                return Data(buffer.prefix(Int(n)))
            }
            let code = errno
            if code == EINTR {
                continue
            }
            if code == EBADF || code == EPIPE {
                return nil
            }
            throw ShellError.io("failed to read shell output: errno \(code)")
        }
        #else
        return try handle.read(upToCount: 4096)
        #endif
    }

    func close() {
        try? handle.close()
    }
}

private struct LocalShellProcessExit: Sendable {
    let code: Int32?
    let signal: Int32?
}

private final class LocalShellProcessController: @unchecked Sendable {
    let process: Process
    let stdout: LocalShellPipeReader
    let stderr: LocalShellPipeReader

    private let lock = NSLock()
    private var groupIsolated = false
    private var started = false
    private var termination: LocalShellProcessExit?
    private var waiters: [CheckedContinuation<LocalShellProcessExit, Never>] = []

    init(process: Process, stdout: LocalShellPipeReader, stderr: LocalShellPipeReader) {
        self.process = process
        self.stdout = stdout
        self.stderr = stderr
    }

    var processID: Int32? {
        let value = process.processIdentifier
        return value > 0 ? value : nil
    }

    var isRunning: Bool {
        process.isRunning
    }

    func start() throws {
        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            let exit: LocalShellProcessExit
            if process.terminationReason == .uncaughtSignal {
                exit = LocalShellProcessExit(code: nil, signal: process.terminationStatus)
            } else {
                exit = LocalShellProcessExit(code: process.terminationStatus, signal: nil)
            }
            self.recordTermination(exit)
            process.terminationHandler = nil
        }
        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            throw error
        }
        lock.lock()
        started = true
        lock.unlock()
        isolateProcessGroup()
    }

    func waitForExit() async -> LocalShellProcessExit {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let termination {
                lock.unlock()
                continuation.resume(returning: termination)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    private func recordTermination(_ exit: LocalShellProcessExit) {
        let pending: [CheckedContinuation<LocalShellProcessExit, Never>]
        lock.lock()
        guard termination == nil else {
            lock.unlock()
            return
        }
        termination = exit
        pending = waiters
        waiters.removeAll()
        lock.unlock()

        for waiter in pending {
            waiter.resume(returning: exit)
        }
    }

    func send(_ signal: ShellSignal) throws {
        guard started, isRunning, let processID else {
            return
        }

        #if canImport(Darwin) || canImport(Glibc)
        let target: Int32
        lock.lock()
        target = groupIsolated ? -processID : processID
        lock.unlock()
        let result: Int32
        #if canImport(Darwin)
        result = Darwin.kill(pid_t(target), signal.portableValue)
        #else
        result = Glibc.kill(pid_t(target), signal.portableValue)
        #endif
        if result != 0 {
            #if canImport(Darwin) || canImport(Glibc)
            if errno == ESRCH {
                return
            }
            #endif
            throw ShellError.io("failed to send \(signal.displayName) to process \(processID)")
        }
        #elseif os(Windows)
        guard signal == .terminate || signal == .kill else {
            throw ShellError.unsupported(capability: .gracefulTermination, platform: "windows")
        }
        process.terminate()
        #else
        throw ShellError.unsupported(capability: .gracefulTermination, platform: "unsupported")
        #endif
    }

    func closePipes() {
        stdout.close()
        stderr.close()
    }

    private func isolateProcessGroup() {
        guard let processID, processID > 1 else {
            return
        }
        #if canImport(Darwin)
        if Darwin.setpgid(pid_t(processID), pid_t(processID)) == 0 {
            lock.lock()
            groupIsolated = true
            lock.unlock()
        } else if Darwin.getpgid(pid_t(processID)) == pid_t(processID) {
            lock.lock()
            groupIsolated = true
            lock.unlock()
        }
        #elseif canImport(Glibc)
        if Glibc.setpgid(pid_t(processID), pid_t(processID)) == 0 {
            lock.lock()
            groupIsolated = true
            lock.unlock()
        } else if Glibc.getpgid(pid_t(processID)) == pid_t(processID) {
            lock.lock()
            groupIsolated = true
            lock.unlock()
        }
        #endif
    }
}
