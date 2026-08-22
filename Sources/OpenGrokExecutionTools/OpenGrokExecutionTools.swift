import Foundation
import OpenGrokSandbox
import OpenGrokPTY
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokToolRuntime
import OpenGrokToolTypes
import OpenGrokWorkspace

public let executionForegroundDefaultTimeoutMilliseconds: UInt64 = 120_000
public let executionForegroundMaximumTimeoutMilliseconds: UInt64 = 300_000
public let executionBackgroundMaximumTimeoutMilliseconds: UInt64 = 36_000_000
public let executionDefaultOutputByteLimit = 20_000
public let executionMaximumOutputByteLimit = 64 * 1024 * 1024
public let executionMaximumCommandBytes = 128 * 1024
public let executionMaximumWaitMilliseconds: UInt64 = 600_000

public enum ExecutionValidationError: Error, Equatable, Sendable, CustomStringConvertible {
    case emptyCommand
    case nulByte
    case controlCharacter(UInt32)
    case commandTooLarge(actual: Int, maximum: Int)
    case unbalancedQuotes
    case backgroundOperatorRejected
    case invalidOutputLimit
    case invalidTaskIdentifier
    case invalidWorkingDirectory(String)

    public var description: String {
        switch self {
        case .emptyCommand:
            return "command must not be empty"
        case .nulByte:
            return "command contains a NUL byte"
        case .controlCharacter(let value):
            return "command contains unsupported control character U+\(String(value, radix: 16, uppercase: true))"
        case .commandTooLarge(let actual, let maximum):
            return "command is \(actual) bytes; maximum is \(maximum) bytes"
        case .unbalancedQuotes:
            return "command contains unbalanced quotes"
        case .backgroundOperatorRejected:
            return "background '&' is not allowed for this command"
        case .invalidOutputLimit:
            return "output_byte_limit must be greater than zero"
        case .invalidTaskIdentifier:
            return "tool_call_id must not be empty"
        case .invalidWorkingDirectory(let path):
            return "working directory is not a directory: \(path)"
        }
    }
}

public struct ExecutionRequest: Codable, Sendable, Hashable {
    public var command: String
    public var workingDirectory: String?
    public var environment: [String: String]
    public var timeoutMilliseconds: UInt64?
    public var outputByteLimit: Int?
    public var outputFile: String?
    public var isBackground: Bool
    public var allowBackgroundOperator: Bool
    public var toolCallId: String
    public var description: String?

    private enum CodingKeys: String, CodingKey {
        case command
        case workingDirectory = "working_directory"
        case environment
        case timeoutMilliseconds = "timeout_ms"
        case outputByteLimit = "output_byte_limit"
        case outputFile = "output_file"
        case isBackground = "is_background"
        case allowBackgroundOperator = "allow_background_operator"
        case toolCallId = "tool_call_id"
        case description
    }

    public init(
        command: String,
        workingDirectory: String? = nil,
        environment: [String: String] = [:],
        timeoutMilliseconds: UInt64? = nil,
        outputByteLimit: Int? = nil,
        outputFile: String? = nil,
        isBackground: Bool = false,
        allowBackgroundOperator: Bool = true,
        toolCallId: String = "execution",
        description: String? = nil
    ) {
        self.command = command
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.timeoutMilliseconds = timeoutMilliseconds
        self.outputByteLimit = outputByteLimit
        self.outputFile = outputFile
        self.isBackground = isBackground
        self.allowBackgroundOperator = allowBackgroundOperator
        self.toolCallId = toolCallId
        self.description = description
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        command = try container.decode(String.self, forKey: .command)
        workingDirectory = try container.decodeIfPresent(String.self, forKey: .workingDirectory)
        environment = try container.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        timeoutMilliseconds = try decodeLenientUInt64(container, key: .timeoutMilliseconds)
        outputByteLimit = try decodeLenientInt(container, key: .outputByteLimit)
        outputFile = try container.decodeIfPresent(String.self, forKey: .outputFile)
        isBackground = try container.decodeIfPresent(Bool.self, forKey: .isBackground) ?? false
        allowBackgroundOperator = try container.decodeIfPresent(Bool.self, forKey: .allowBackgroundOperator) ?? true
        toolCallId = try container.decodeIfPresent(String.self, forKey: .toolCallId) ?? "execution"
        description = try container.decodeIfPresent(String.self, forKey: .description)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(command, forKey: .command)
        try container.encodeIfPresent(workingDirectory, forKey: .workingDirectory)
        if !environment.isEmpty { try container.encode(environment, forKey: .environment) }
        try container.encodeIfPresent(timeoutMilliseconds, forKey: .timeoutMilliseconds)
        try container.encodeIfPresent(outputByteLimit, forKey: .outputByteLimit)
        try container.encodeIfPresent(outputFile, forKey: .outputFile)
        try container.encode(isBackground, forKey: .isBackground)
        if !allowBackgroundOperator { try container.encode(false, forKey: .allowBackgroundOperator) }
        if toolCallId != "execution" { try container.encode(toolCallId, forKey: .toolCallId) }
        try container.encodeIfPresent(description, forKey: .description)
    }
}

private func decodeLenientUInt64<K: CodingKey>(
    _ container: KeyedDecodingContainer<K>,
    key: K
) throws -> UInt64? {
    guard let value = try container.decodeIfPresent(JSONValue.self, forKey: key) else { return nil }
    switch value {
    case .number(let number): return number.uint64Value
    case .string(let string): return UInt64(string.trimmingCharacters(in: .whitespacesAndNewlines))
    default: return nil
    }
}

private func decodeLenientInt<K: CodingKey>(
    _ container: KeyedDecodingContainer<K>,
    key: K
) throws -> Int? {
    guard let value = try container.decodeIfPresent(JSONValue.self, forKey: key) else { return nil }
    switch value {
    case .number(let number):
        if let value = number.int64Value { return Int(exactly: value) }
        if let value = number.uint64Value { return Int(exactly: value) }
        return nil
    case .string(let string): return Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
    default: return nil
    }
}

public struct ValidatedExecutionRequest: Sendable, Hashable {
    public let request: ExecutionRequest
    public let timeoutMilliseconds: UInt64
    public let outputByteLimit: Int

    public init(request: ExecutionRequest, timeoutMilliseconds: UInt64, outputByteLimit: Int) {
        self.request = request
        self.timeoutMilliseconds = timeoutMilliseconds
        self.outputByteLimit = outputByteLimit
    }
}

public func validateExecutionRequest(_ request: ExecutionRequest) throws -> ValidatedExecutionRequest {
    let command = request.command.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !command.isEmpty else { throw ExecutionValidationError.emptyCommand }
    guard !command.unicodeScalars.contains(where: { $0.value == 0 }) else {
        throw ExecutionValidationError.nulByte
    }
    for scalar in command.unicodeScalars where scalar.value < 0x20 && scalar.value != 0x09 && scalar.value != 0x0A && scalar.value != 0x0D {
        throw ExecutionValidationError.controlCharacter(scalar.value)
    }
    let byteCount = command.utf8.count
    guard byteCount <= executionMaximumCommandBytes else {
        throw ExecutionValidationError.commandTooLarge(actual: byteCount, maximum: executionMaximumCommandBytes)
    }
    guard hasBalancedQuotes(command) else { throw ExecutionValidationError.unbalancedQuotes }
    if !request.isBackground && !request.allowBackgroundOperator && containsUnquotedBackgroundOperator(command) {
        throw ExecutionValidationError.backgroundOperatorRejected
    }
    let outputLimit = request.outputByteLimit ?? executionDefaultOutputByteLimit
    guard outputLimit > 0 else { throw ExecutionValidationError.invalidOutputLimit }
    let boundedOutputLimit = min(outputLimit, executionMaximumOutputByteLimit)
    guard !request.toolCallId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw ExecutionValidationError.invalidTaskIdentifier
    }
    let timeout: UInt64
    if request.isBackground {
        // Background jobs belong to the model until they exit or are killed.
        // Zero is the explicit unbounded sentinel; omitted has the same
        // meaning. Only an explicitly positive timeout installs a deadline.
        let requestedTimeout = request.timeoutMilliseconds ?? 0
        timeout = requestedTimeout == 0
            ? 0
            : min(requestedTimeout, executionBackgroundMaximumTimeoutMilliseconds)
    } else {
        let requestedTimeout = request.timeoutMilliseconds ?? 0
        timeout = min(
            requestedTimeout > 0 ? requestedTimeout : executionForegroundDefaultTimeoutMilliseconds,
            executionForegroundMaximumTimeoutMilliseconds
        )
    }
    var normalized = request
    normalized.command = command
    return ValidatedExecutionRequest(
        request: normalized,
        timeoutMilliseconds: timeout,
        outputByteLimit: boundedOutputLimit
    )
}

private func hasBalancedQuotes(_ command: String) -> Bool {
    var single = false
    var double = false
    var escaped = false
    for character in command {
        if escaped {
            escaped = false
            continue
        }
        if character == "\\" && !single {
            escaped = true
        } else if character == "'" && !double {
            single.toggle()
        } else if character == "\"" && !single {
            double.toggle()
        }
    }
    return !single && !double && !escaped
}

private func containsUnquotedBackgroundOperator(_ command: String) -> Bool {
    let characters = Array(command)
    var single = false
    var double = false
    var escaped = false
    var index = characters.startIndex
    while index < characters.endIndex {
        let character = characters[index]
        if escaped {
            escaped = false
            index = characters.index(after: index)
            continue
        }
        if character == "\\" && !single {
            escaped = true
            index = characters.index(after: index)
            continue
        }
        if character == "'" && !double {
            single.toggle()
            index = characters.index(after: index)
            continue
        }
        if character == "\"" && !single {
            double.toggle()
            index = characters.index(after: index)
            continue
        }
        guard !single && !double && character == "&" else {
            index = characters.index(after: index)
            continue
        }
        let next = characters.index(after: index)
        if next < characters.endIndex && characters[next] == "&" {
            index = characters.index(after: next)
            continue
        }
        let previous = index > characters.startIndex ? characters[characters.index(before: index)] : nil
        if previous == ">" {
            index = characters.index(after: index)
            continue
        }
        return true
    }
    return false
}

public struct BoundedOutput: Codable, Sendable, Hashable {
    public let text: String
    public let totalBytes: Int
    public let truncated: Bool

    private enum CodingKeys: String, CodingKey {
        case text
        case totalBytes = "total_bytes"
        case truncated
    }

    public init(data: Data, totalBytes: Int? = nil, limit: Int) {
        let retained = Self.retainedBytes(data, limit: max(limit, 1))
        self.text = String(decoding: retained, as: UTF8.self)
        self.totalBytes = totalBytes ?? data.count
        self.truncated = self.totalBytes > retained.count
    }

    public init(text: String, totalBytes: Int, truncated: Bool) {
        self.text = text
        self.totalBytes = totalBytes
        self.truncated = truncated
    }

    fileprivate static func retainedBytes(_ data: Data, limit: Int) -> Data {
        guard data.count > limit else { return data }
        let headLimit = limit / 2
        let tailLimit = limit - headLimit
        return Data(data.prefix(headLimit)) + Data(data.suffix(tailLimit))
    }
}

public struct ExecutionResult: Codable, Sendable, Hashable, ToolOutput {
    public let combinedOutput: String
    public let exitCode: Int?
    public let truncated: Bool
    public let signal: String?
    public let timedOut: Bool
    public let cancelled: Bool
    public let outputFile: String
    public let totalBytes: Int
    public let pid: Int?

    private enum CodingKeys: String, CodingKey {
        case combinedOutput = "combined_output"
        case exitCode = "exit_code"
        case truncated
        case signal
        case timedOut = "timed_out"
        case cancelled
        case outputFile = "output_file"
        case totalBytes = "total_bytes"
        case pid
    }

    public init(
        combinedOutput: String,
        exitCode: Int?,
        truncated: Bool,
        signal: String?,
        timedOut: Bool,
        cancelled: Bool,
        outputFile: String,
        totalBytes: Int,
        pid: Int?
    ) {
        self.combinedOutput = combinedOutput
        self.exitCode = exitCode
        self.truncated = truncated
        self.signal = signal
        self.timedOut = timedOut
        self.cancelled = cancelled
        self.outputFile = outputFile
        self.totalBytes = totalBytes
        self.pid = pid
    }

    public func modelOutput() -> [ContentBlock] {
        [.text(text: combinedOutput)]
    }
}

public struct BackgroundTaskHandle: Codable, Sendable, Hashable, ToolOutput {
    public let taskId: String
    public let outputFile: String
    public let pid: Int?

    private enum CodingKeys: String, CodingKey {
        case taskId = "task_id"
        case outputFile = "output_file"
        case pid
    }

    public init(taskId: String, outputFile: String, pid: Int?) {
        self.taskId = taskId
        self.outputFile = outputFile
        self.pid = pid
    }

    public func modelOutput() -> [ContentBlock] {
        [.text(text: "Background task \(taskId) started. Output: \(outputFile)")]
    }
}

public enum ExecutionToolOutput: Codable, Sendable, Hashable, ToolOutput {
    case foreground(ExecutionResult)
    case background(BackgroundTaskHandle)

    private enum CodingKeys: String, CodingKey { case type, result, task }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "foreground": self = .foreground(try container.decode(ExecutionResult.self, forKey: .result))
        case "background": self = .background(try container.decode(BackgroundTaskHandle.self, forKey: .task))
        default: throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "unknown execution output")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .foreground(let result):
            try container.encode("foreground", forKey: .type)
            try container.encode(result, forKey: .result)
        case .background(let task):
            try container.encode("background", forKey: .type)
            try container.encode(task, forKey: .task)
        }
    }

    public func modelOutput() -> [ContentBlock] {
        switch self {
        case .foreground(let result): return result.modelOutput()
        case .background(let task): return task.modelOutput()
        }
    }
}

public typealias BashToolInput = ExecutionRequest
public typealias BashToolOutput = ExecutionToolOutput
public typealias TerminalRunRequest = ExecutionRequest
public typealias TerminalRunResult = ExecutionResult
public typealias BackgroundHandle = BackgroundTaskHandle
public typealias KillOutcome = ExecutionKillOutcome

public struct ExecutionTaskSnapshot: Codable, Sendable, Hashable {
    public let taskId: String
    public let command: String
    public let displayCommand: String?
    public let cwd: String
    public let startTime: Date
    public let endTime: Date?
    public let output: String
    public let outputFile: String
    public let truncated: Bool
    public let exitCode: Int?
    public let signal: String?
    public let timedOut: Bool
    public let completed: Bool
    public let isBackgrounded: Bool
    public let description: String?

    private enum CodingKeys: String, CodingKey {
        case taskId = "task_id"
        case command
        case displayCommand = "display_command"
        case cwd
        case startTime = "start_time"
        case endTime = "end_time"
        case output
        case outputFile = "output_file"
        case truncated
        case exitCode = "exit_code"
        case signal
        case timedOut = "timed_out"
        case completed
        case isBackgrounded = "is_backgrounded"
        case description
    }

    public var status: String { completed ? "completed" : "running" }

    fileprivate init(
        taskId: String,
        command: String,
        displayCommand: String?,
        cwd: String,
        startTime: Date,
        endTime: Date?,
        output: String,
        outputFile: String,
        truncated: Bool,
        exitCode: Int?,
        signal: String?,
        timedOut: Bool,
        completed: Bool,
        isBackgrounded: Bool,
        description: String?
    ) {
        self.taskId = taskId
        self.command = command
        self.displayCommand = displayCommand
        self.cwd = cwd
        self.startTime = startTime
        self.endTime = endTime
        self.output = output
        self.outputFile = outputFile
        self.truncated = truncated
        self.exitCode = exitCode
        self.signal = signal
        self.timedOut = timedOut
        self.completed = completed
        self.isBackgrounded = isBackgrounded
        self.description = description
    }
}

private func shellProcessSpec(for request: ValidatedExecutionRequest, workingDirectory: String) -> ProcessSpec {
    #if os(Windows)
    let shell = ProcessInfo.processInfo.environment["ComSpec"] ?? "cmd.exe"
    return ProcessSpec(
        command: shell,
        arguments: ["/d", "/s", "/c", request.request.command],
        environment: request.request.environment,
        workingDirectory: workingDirectory,
        usePTY: false,
        newProcessGroup: true
    )
    #else
    return ProcessSpec(
        command: "/bin/sh",
        arguments: ["-lc", request.request.command],
        environment: request.request.environment,
        workingDirectory: workingDirectory,
        usePTY: false,
        newProcessGroup: true
    )
    #endif
}

public enum ExecutionKillOutcome: String, Codable, Sendable, Hashable {
    case killed = "killed"
    case alreadyExited = "already_exited"
    case notFound = "not_found"
}

public protocol ExecutionTaskIDProvider: Sendable {
    func nextTaskId() -> String
}

public struct UUIDExecutionTaskIDProvider: ExecutionTaskIDProvider, Sendable {
    public init() {}
    public func nextTaskId() -> String { "task-\(UUID().uuidString.lowercased())" }
}

private final class OutputFileWriter: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        handle = try FileHandle(forWritingTo: url)
    }

    func append(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        try handle.write(contentsOf: data)
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        try? handle.close()
    }
}

private struct OutputAccumulator {
    private(set) var retained = Data()
    private(set) var totalBytes = 0
    private(set) var truncated = false
    private let outputLimit: Int
    private let fileLimit: Int
    private var persistedBytes = 0
    private let writer: OutputFileWriter

    init(outputLimit: Int, fileLimit: Int, writer: OutputFileWriter) {
        self.outputLimit = max(outputLimit, 1)
        self.fileLimit = max(fileLimit, 1)
        self.writer = writer
    }

    mutating func append(_ chunk: Data) throws {
        totalBytes += chunk.count
        if persistedBytes < fileLimit {
            let count = min(chunk.count, fileLimit - persistedBytes)
            if count > 0 {
                try writer.append(Data(chunk.prefix(count)))
                persistedBytes += count
            }
        }
        if totalBytes <= outputLimit && !truncated {
            retained.append(chunk)
            return
        }
        if !truncated {
            retained = BoundedOutput.retainedBytes(retained + chunk, limit: outputLimit)
            truncated = true
        } else {
            let tailLimit = outputLimit - outputLimit / 2
            let combined = Data(retained.suffix(tailLimit)) + chunk
            let tail = Data(combined.suffix(tailLimit))
            retained = Data(retained.prefix(outputLimit / 2)) + tail
        }
    }

    func result() -> BoundedOutput {
        BoundedOutput(
            text: String(decoding: retained, as: UTF8.self),
            totalBytes: totalBytes,
            truncated: truncated
        )
    }
}

private enum ProcessRunError: Error {
    case timedOut
}

private final class ProcessTimeoutState: @unchecked Sendable {
    private let lock = NSLock()
    private var expired = false

    func markExpired() {
        lock.lock()
        expired = true
        lock.unlock()
    }

    var hasExpired: Bool {
        lock.lock()
        defer { lock.unlock() }
        return expired
    }
}

private enum ProcessRunner {
    static func run(
        process: any PTYProcess,
        request: ValidatedExecutionRequest,
        outputFile: URL,
        toolId: ToolId
    ) async -> Result<ExecutionResult, ToolError> {
        let writer: OutputFileWriter
        do {
            writer = try OutputFileWriter(url: outputFile)
        } catch {
            return .failure(.execution(toolId: toolId, detail: "opening output file: \(error)"))
        }
        let outputTask = Task { () -> (BoundedOutput, ToolError?) in
            var accumulator = OutputAccumulator(
                outputLimit: request.outputByteLimit,
                fileLimit: executionMaximumOutputByteLimit,
                writer: writer
            )
            do {
                for try await chunk in process.output() {
                    try accumulator.append(chunk)
                }
                return (accumulator.result(), nil)
            } catch let error as PTYError where error == .cancelled {
                return (accumulator.result(), nil)
            } catch {
                return (accumulator.result(), .execution(toolId: toolId, detail: "reading command output: \(error)"))
            }
        }

        var timedOut = false
        var cancelled = false
        var exit: ProcessExit = .stillRunning
        do {
            if request.timeoutMilliseconds == 0 {
                exit = try await process.waitForExit()
            } else {
                let timeoutState = ProcessTimeoutState()
                exit = try await withThrowingTaskGroup(of: ProcessExit.self) { group in
                    group.addTask { try await process.waitForExit() }
                    group.addTask {
                        try await Task.sleep(nanoseconds: request.timeoutMilliseconds * 1_000_000)
                        timeoutState.markExpired()
                        // A Windows Job Object waits with WaitForSingleObject,
                        // which does not observe Swift task cancellation. Kill
                        // first so the group can actually join its waiter.
                        await process.cancel()
                        throw ProcessRunError.timedOut
                    }
                    let first = try await group.next()!
                    group.cancelAll()
                    return first
                }
                timedOut = timeoutState.hasExpired
            }
        } catch is ProcessRunError {
            timedOut = true
            await process.cancel()
            exit = (try? await process.waitForExit()) ?? .signal(Int32(ProcessSignal.kill.portableValue))
        } catch is CancellationError {
            cancelled = true
            await process.cancel()
            exit = (try? await process.waitForExit()) ?? .signal(Int32(ProcessSignal.kill.portableValue))
        } catch {
            writer.close()
            _ = await outputTask.value
            return .failure(.execution(toolId: toolId, detail: "waiting for command: \(error)"))
        }

        let (bounded, outputError) = await outputTask.value
        writer.close()
        if let outputError { return .failure(outputError) }
        if cancelled {
            return .failure(.cancelled(toolId: toolId, detail: "command cancelled"))
        }
        let exitCode: Int?
        let signal: String?
        switch exit {
        case .code(let code):
            exitCode = Int(code)
            signal = nil
        case .signal(let value):
            exitCode = nil
            signal = "SIG\(value)"
        case .stillRunning:
            exitCode = nil
            signal = "still_running"
        }
        return .success(
            ExecutionResult(
                combinedOutput: bounded.text,
                exitCode: exitCode,
                truncated: bounded.truncated,
                signal: signal,
                timedOut: timedOut,
                cancelled: cancelled,
                outputFile: outputFile.path,
                totalBytes: bounded.totalBytes,
                pid: process.processID.map(Int.init)
            )
        )
    }
}

public actor ExecutionToolRuntime {
    private let adapter: any PTYAdapter
    private let launchTransform: ChildLaunchTransform
    private let workspace: LocalWorkspaceOps?
    private let taskIdProvider: any ExecutionTaskIDProvider
    private let outputHome: URL?
    private var processes: [String: any PTYProcess] = [:]
    private var running: [String: Task<Void, Never>] = [:]
    private var snapshots: [String: ExecutionTaskSnapshot] = [:]
    private var snapshotOrder: [String] = []

    public init(
        adapter: any PTYAdapter = PlatformPTYAdapter(),
        workspace: LocalWorkspaceOps? = nil,
        taskIdProvider: any ExecutionTaskIDProvider = UUIDExecutionTaskIDProvider(),
        outputHome: URL? = nil,
        launchTransform: @escaping ChildLaunchTransform = childNetworkRestrictedLaunch
    ) {
        self.adapter = adapter
        self.workspace = workspace
        self.taskIdProvider = taskIdProvider
        self.outputHome = outputHome
        self.launchTransform = launchTransform
    }

    public func execute(_ request: ExecutionRequest) async -> Result<ExecutionToolOutput, ToolError> {
        do {
            let validated = try validateExecutionRequest(request)
            let cwd = try await resolveWorkingDirectory(validated.request.workingDirectory)
            if let workspace {
                try await workspace.authorizeProcess(
                    ProcessSpawnRequest(
                        command: validated.request.command,
                        workingDirectory: cwd,
                        toolCallId: validated.request.toolCallId
                    )
                )
            }
            let outputURL = try await resolveOutputURL(validated.request.outputFile, taskId: validated.request.toolCallId)
            var processSpec = shellProcessSpec(for: validated, workingDirectory: cwd)
            do {
                let launch = try launchTransform(processSpec.command, processSpec.arguments)
                processSpec.command = launch.executable
                processSpec.arguments = launch.arguments
            } catch {
                return .failure(.execution(toolId: Self.executionToolId, detail: "failed to prepare command launch: \(error)"))
            }
            let process = try await adapter.spawn(processSpec)
            if validated.request.isBackground {
                let taskId = taskIdProvider.nextTaskId()
                let now = Date()
                let snapshot = ExecutionTaskSnapshot(
                    taskId: taskId,
                    command: validated.request.command,
                    displayCommand: validated.request.description,
                    cwd: cwd,
                    startTime: now,
                    endTime: nil,
                    output: "",
                    outputFile: outputURL.path,
                    truncated: false,
                    exitCode: nil,
                    signal: nil,
                    timedOut: false,
                    completed: false,
                    isBackgrounded: true,
                    description: validated.request.description
                )
                snapshots[taskId] = snapshot
                snapshotOrder.append(taskId)
                processes[taskId] = process
                let task = Task { [self] in
                    let result = await ProcessRunner.run(
                        process: process,
                        request: validated,
                        outputFile: outputURL,
                        toolId: Self.executionToolId
                    )
                    finish(taskId: taskId, result: result)
                }
                running[taskId] = task
                return .success(.background(BackgroundTaskHandle(taskId: taskId, outputFile: outputURL.path, pid: process.processID.map(Int.init))))
            }
            let result = await withTaskCancellationHandler(
                operation: {
                    await ProcessRunner.run(
                        process: process,
                        request: validated,
                        outputFile: outputURL,
                        toolId: Self.executionToolId
                    )
                },
                onCancel: {
                    Task { await process.cancel() }
                }
            )
            return result.map { .foreground($0) }
        } catch let error as ExecutionValidationError {
            return .failure(.invalidArguments(error.description))
        } catch let error as WorkspaceRuntimeError {
            return .failure(.permissionDenied(error.description))
        } catch let error as PTYError {
            return .failure(Self.mapPTYError(error))
        } catch {
            return .failure(.execution(toolId: Self.executionToolId, detail: error.localizedDescription))
        }
    }

    public func taskSnapshot(_ taskId: String) -> ExecutionTaskSnapshot? {
        snapshots[taskId]
    }

    public func waitForTask(_ taskId: String, timeoutMilliseconds: UInt64? = nil) async -> ExecutionTaskSnapshot? {
        let timeout = min(timeoutMilliseconds ?? 0, executionMaximumWaitMilliseconds)
        if timeout == 0 { return snapshots[taskId] }
        let deadline = UInt64(Date().timeIntervalSince1970 * 1_000) + timeout
        while let snapshot = snapshots[taskId], !snapshot.completed {
            if UInt64(Date().timeIntervalSince1970 * 1_000) >= deadline { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return snapshots[taskId]
    }

    public func waitForTasks(_ taskIds: [String], timeoutMilliseconds: UInt64? = nil) async -> [ExecutionTaskSnapshot] {
        var ids: [String] = []
        var seen = Set<String>()
        for id in taskIds {
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && seen.insert(trimmed).inserted && ids.count < 20 { ids.append(trimmed) }
        }
        let timeout = min(timeoutMilliseconds ?? 0, executionMaximumWaitMilliseconds)
        if timeout > 0 {
            let deadline = UInt64(Date().timeIntervalSince1970 * 1_000) + timeout
            while !ids.allSatisfy({ snapshots[$0]?.completed == true || snapshots[$0] == nil }) {
                if UInt64(Date().timeIntervalSince1970 * 1_000) >= deadline { break }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        return ids.compactMap { snapshots[$0] }
    }

    public func killTask(_ taskId: String) async -> ExecutionKillOutcome {
        guard let snapshot = snapshots[taskId] else { return .notFound }
        guard !snapshot.completed else { return .alreadyExited }
        guard let process = processes[taskId] else { return .alreadyExited }
        await process.cancel()
        return .killed
    }

    public func cancelAll() async {
        for process in processes.values { await process.cancel() }
    }

    private static let executionToolId = try! ToolId("run_terminal_cmd")

    private func resolveWorkingDirectory(_ requested: String?) async throws -> String {
        let path: String
        if let requested {
            if let workspace { path = try workspace.resolvePath(requested).path }
            else { path = URL(fileURLWithPath: requested, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL.path }
        } else if let workspace {
            path = workspace.root.path
        } else {
            path = FileManager.default.currentDirectoryPath
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ExecutionValidationError.invalidWorkingDirectory(path)
        }
        return path
    }

    private func resolveOutputURL(_ requested: String?, taskId: String) async throws -> URL {
        let home: URL
        if let outputHome { home = outputHome }
        else if let workspace { home = await workspace.config.openGrokHome }
        else if let value = ProcessInfo.processInfo.environment["OPENGROK_HOME"], !value.isEmpty { home = URL(fileURLWithPath: value) }
        else { home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".opengrok", isDirectory: true) }
        let base = home.standardizedFileURL
        let url: URL
        if let requested {
            if let workspace { url = try workspace.resolvePath(requested) }
            else { url = URL(fileURLWithPath: requested, relativeTo: base).standardizedFileURL }
        } else {
            url = base.appendingPathComponent("tasks", isDirectory: true).appendingPathComponent("\(taskId).output")
        }
        let basePath = base.path.hasSuffix("/") ? base.path : base.path + "/"
        guard url.standardizedFileURL.path == base.path || url.standardizedFileURL.path.hasPrefix(basePath) || workspace != nil else {
            throw ExecutionValidationError.invalidWorkingDirectory(url.path)
        }
        return url.standardizedFileURL
    }

    private func finish(taskId: String, result: Result<ExecutionResult, ToolError>) {
        processes.removeValue(forKey: taskId)
        running.removeValue(forKey: taskId)
        guard let previous = snapshots[taskId] else { return }
        switch result {
        case .success(let value):
            snapshots[taskId] = ExecutionTaskSnapshot(
                taskId: previous.taskId,
                command: previous.command,
                displayCommand: previous.displayCommand,
                cwd: previous.cwd,
                startTime: previous.startTime,
                endTime: Date(),
                output: value.combinedOutput,
                outputFile: value.outputFile,
                truncated: value.truncated,
                exitCode: value.exitCode,
                signal: value.signal,
                timedOut: value.timedOut,
                completed: true,
                isBackgrounded: true,
                description: previous.description
            )
        case .failure(let error):
            snapshots[taskId] = ExecutionTaskSnapshot(
                taskId: previous.taskId,
                command: previous.command,
                displayCommand: previous.displayCommand,
                cwd: previous.cwd,
                startTime: previous.startTime,
                endTime: Date(),
                output: error.detail,
                outputFile: previous.outputFile,
                truncated: false,
                exitCode: nil,
                signal: nil,
                timedOut: error.kind == .timeout,
                completed: true,
                isBackgrounded: true,
                description: previous.description
            )
        }
        while snapshotOrder.count > 100 {
            let old = snapshotOrder.removeFirst()
            if snapshots[old]?.completed == true { snapshots.removeValue(forKey: old) }
        }
    }

    private static func mapPTYError(_ error: PTYError) -> ToolError {
        switch error {
        case .cancelled: return .cancelled(toolId: executionToolId, detail: "command cancelled")
        case .timeout: return .timeout(toolId: executionToolId, detail: "command timed out")
        case .unsupported(let detail): return .custom(code: "unsupported", detail: detail)
        case .spawnFailed(let detail): return .execution(toolId: executionToolId, detail: "failed to spawn command: \(detail)")
        case .ioFailed(let detail): return .execution(toolId: executionToolId, detail: detail)
        }
    }
}

public struct RunTerminalCommandTool: BlockingTool {
    public typealias Output = ExecutionToolOutput
    public let runtime: ExecutionToolRuntime

    public init(runtime: ExecutionToolRuntime) {
        self.runtime = runtime
    }

    public func id() -> ToolId { try! ToolId("run_terminal_cmd") }

    public func description(ctx: ListToolsContext) -> ToolDescription {
        _ = ctx
        let schema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "command": .object(["type": .string("string")]),
                "timeout_ms": .object(["type": .string("integer")]),
                "description": .object(["type": .string("string")]),
                "is_background": .object(["type": .string("boolean")]),
            ]),
            "required": .array([.string("command")]),
        ])
        return ToolDescription(name: "run_terminal_cmd", description: "Run a validated shell command in the workspace, with bounded output and cancellable process-group cleanup.")
            .withKind("execute")
            .withArgumentsSchema(schema)
    }

    public func capabilities() -> ToolCapabilities {
        ToolCapabilities(
            streaming: StreamingSpec(subkind: "bash_output_chunk", maxDeltaBytes: 16 * 1024),
            supportsCancel: true,
            isReadOnly: false,
            timeoutMs: executionForegroundMaximumTimeoutMilliseconds,
            toolScope: .write
        )
    }

    public func run(ctx: ToolCallContext, args: JSONValue) async -> Result<ExecutionToolOutput, ToolError> {
        do {
            var request = try JSONDecoder().decode(ExecutionRequest.self, from: JSONEncoder().encode(args))
            if request.toolCallId == "execution" { request.toolCallId = ctx.callId.stringValue }
            return await runtime.execute(request)
        } catch {
            return .failure(.invalidArguments("invalid execution arguments: \(error)"))
        }
    }
}

public typealias BashTool = RunTerminalCommandTool
