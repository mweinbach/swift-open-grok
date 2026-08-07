import Foundation
import OpenGrokShared
import OpenGrokShellBase

public enum OpenGrokShellToolBridgeError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidSessionID
    case invalidToolCallID
    case ownerMismatch(expected: String, actual: String?)
    case duplicateToolCall(String)
    case sessionNotRegistered(String)
    case sessionWorkingDirectoryMismatch(sessionID: String, expected: URL, actual: URL)
    case invalidBackgroundHandle
    case taskNotOwned(String)

    public var description: String {
        switch self {
        case .invalidSessionID:
            return "shell tool bridge requires a non-empty session id"
        case .invalidToolCallID:
            return "shell tool bridge requires a non-empty tool call id"
        case let .ownerMismatch(expected, actual):
            return "shell tool owner mismatch: expected \(expected), got \(actual ?? "none")"
        case let .duplicateToolCall(callID):
            return "shell tool call is already active: \(callID)"
        case let .sessionNotRegistered(sessionID):
            return "shell tool session is not registered: \(sessionID)"
        case let .sessionWorkingDirectoryMismatch(sessionID, expected, actual):
            return "shell tool session cwd changed: \(sessionID) expected \(expected.path), got \(actual.path)"
        case .invalidBackgroundHandle:
            return "shell backend returned an empty background task id"
        case let .taskNotOwned(taskID):
            return "shell task is not owned by this session: \(taskID)"
        }
    }
}

public protocol OpenGrokShellProcessExecution: Sendable {
    var sessionID: String { get }
    var workingDirectory: URL { get }

    func run(_ request: ShellCommandRequest) async throws -> ShellCommandResult
    func runBackground(_ request: ShellCommandRequest) async throws -> ShellBackgroundHandle
    func cancel(toolCallID: String) async
    func cancelAll() async
    func killTask(_ taskID: String) async -> ShellKillOutcome
    func taskSnapshot(_ taskID: String) async -> ShellTaskSnapshot?
    func waitForCompletion(_ taskID: String, timeout: ShellDuration?) async -> ShellTaskSnapshot?
    func listTasks() async -> [ShellTaskSnapshot]
}

public actor OpenGrokShellOwnedProcessExecution: OpenGrokShellProcessExecution {
    public let sessionID: String
    public let workingDirectory: URL

    private let backend: any ShellProcessBackend
    private var foregroundCallIDs: Set<String> = []
    private var backgroundTaskOwners: [String: String] = [:]

    public init(
        sessionID: String,
        workingDirectory: URL,
        backend: any ShellProcessBackend
    ) throws {
        let normalizedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSessionID.isEmpty else {
            throw OpenGrokShellToolBridgeError.invalidSessionID
        }
        self.sessionID = normalizedSessionID
        self.workingDirectory = workingDirectory.standardizedFileURL
        self.backend = backend
    }

    public func run(_ request: ShellCommandRequest) async throws -> ShellCommandResult {
        let ownedRequest = try ownedRequest(request)
        let callID = try toolCallID(from: ownedRequest)
        guard !foregroundCallIDs.contains(callID), !backgroundTaskOwners.values.contains(callID) else {
            throw OpenGrokShellToolBridgeError.duplicateToolCall(callID)
        }
        foregroundCallIDs.insert(callID)
        defer { foregroundCallIDs.remove(callID) }

        let result = try await withTaskCancellationHandler(
            operation: {
                try await backend.run(ownedRequest)
            },
            onCancel: {
                Task { await backend.killForegroundCommands(ownerSessionID: sessionID) }
            }
        )
        // A foreground command that outruns `foregroundBlockBudget` is moved to
        // the background by the backend, not by an explicit `runBackground`
        // call, so its task id never passes through the branch below. Without
        // recording it here every ownership check — `taskSnapshot`, `killTask`,
        // `waitForCompletion` — rejects the very id `run` just handed back, and
        // the model has no way to reach a task it did not choose to background.
        if result.backgrounded, let taskID = result.taskID, !taskID.isEmpty {
            backgroundTaskOwners[taskID] = callID
        }
        return result
    }

    public func runBackground(_ request: ShellCommandRequest) async throws -> ShellBackgroundHandle {
        let ownedRequest = try ownedRequest(request)
        let callID = try toolCallID(from: ownedRequest)
        guard !foregroundCallIDs.contains(callID), !backgroundTaskOwners.values.contains(callID) else {
            throw OpenGrokShellToolBridgeError.duplicateToolCall(callID)
        }

        let handle = try await backend.runBackground(ownedRequest)
        guard !handle.taskID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenGrokShellToolBridgeError.invalidBackgroundHandle
        }
        backgroundTaskOwners[handle.taskID] = callID
        return handle
    }

    public func cancel(toolCallID: String) async {
        let normalizedCallID = toolCallID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedCallID.isEmpty else { return }
        if foregroundCallIDs.contains(normalizedCallID) {
            await backend.killForegroundCommands(ownerSessionID: sessionID)
        }
        let taskIDs = backgroundTaskOwners.compactMap { taskID, owner in
            owner == normalizedCallID ? taskID : nil
        }
        for taskID in taskIDs {
            _ = await backend.killTask(taskID)
        }
    }

    public func cancelAll() async {
        await backend.killForegroundCommands(ownerSessionID: sessionID)
        await backend.killAllBackgroundTasks(ownerSessionID: sessionID)
    }

    public func killTask(_ taskID: String) async -> ShellKillOutcome {
        guard backgroundTaskOwners[taskID] != nil else { return .notFound }
        return await backend.killTask(taskID)
    }

    public func taskSnapshot(_ taskID: String) async -> ShellTaskSnapshot? {
        guard backgroundTaskOwners[taskID] != nil else { return nil }
        return await ownedSnapshot(for: taskID)
    }

    public func waitForCompletion(_ taskID: String, timeout: ShellDuration?) async -> ShellTaskSnapshot? {
        guard backgroundTaskOwners[taskID] != nil else { return nil }
        let snapshot = await backend.waitForCompletion(taskID, timeout: timeout)
        guard let snapshot, snapshot.ownerSessionID == sessionID else { return nil }
        return snapshot
    }

    public func listTasks() async -> [ShellTaskSnapshot] {
        let knownTaskIDs = Set(backgroundTaskOwners.keys)
        return await backend.listTasks().filter {
            knownTaskIDs.contains($0.taskID) && $0.ownerSessionID == sessionID
        }
    }

    private func ownedSnapshot(for taskID: String) async -> ShellTaskSnapshot? {
        let snapshot = await backend.getTask(taskID)
        guard let snapshot, snapshot.ownerSessionID == sessionID else { return nil }
        return snapshot
    }

    private func ownedRequest(_ request: ShellCommandRequest) throws -> ShellCommandRequest {
        try request.validate()
        let callID = try toolCallID(from: request)
        if let ownerSessionID = request.ownerSessionID, ownerSessionID != sessionID {
            throw OpenGrokShellToolBridgeError.ownerMismatch(expected: sessionID, actual: ownerSessionID)
        }
        var ownedRequest = request
        ownedRequest.toolCallID = callID
        ownedRequest.ownerSessionID = sessionID
        return ownedRequest
    }

    private func toolCallID(from request: ShellCommandRequest) throws -> String {
        guard let toolCallID = request.toolCallID?.trimmingCharacters(in: .whitespacesAndNewlines), !toolCallID.isEmpty else {
            throw OpenGrokShellToolBridgeError.invalidToolCallID
        }
        return toolCallID
    }
}

public struct OpenGrokShellToolCall: Sendable, Equatable {
    public let sessionID: String
    public let name: String
    public let args: JSONValue
    public let callID: String

    public init(sessionID: String, name: String, args: JSONValue, callID: String) {
        self.sessionID = sessionID
        self.name = name
        self.args = args
        self.callID = callID
    }
}

public struct OpenGrokShellToolCallResult: Sendable, Equatable {
    public let value: JSONValue
    public let promptText: String

    public init(value: JSONValue, promptText: String) {
        self.value = value
        self.promptText = promptText
    }
}

public enum OpenGrokShellToolRuntimeError: Error, Sendable, Equatable, CustomStringConvertible {
    case cancelled
    case invalidCall(String)
    case unsupported(String)
    case failed(String)
    /// The permission pipeline refused to authorize the call. Distinct from
    /// `failed` so a caller can fire `PermissionDenied` rather than
    /// `PostToolUseFailure`: a denied tool never ran, and upstream keeps the
    /// two hook events separate (tool_calls.rs:1718-1741 fires
    /// `PermissionDenied` at the decision site; `PostToolUseFailure` fires
    /// only for a tool that executed and errored).
    case denied(String)

    public var description: String {
        switch self {
        case .cancelled:
            return "shell tool call cancelled"
        case let .invalidCall(message):
            return "invalid shell tool call: \(message)"
        case let .unsupported(message):
            return "unsupported shell tool operation: \(message)"
        case let .failed(message):
            return "shell tool runtime failed: \(message)"
        case let .denied(message):
            return "shell tool denied: \(message)"
        }
    }
}

public protocol OpenGrokShellToolRuntime: Sendable {
    func invoke(
        _ call: OpenGrokShellToolCall,
        using process: any OpenGrokShellProcessExecution
    ) async -> Result<OpenGrokShellToolCallResult, OpenGrokShellToolRuntimeError>
    func cancel(_ call: OpenGrokShellToolCall) async
}

public struct ClosureOpenGrokShellToolRuntime: OpenGrokShellToolRuntime, Sendable {
    public typealias InvokeOperation = @Sendable (
        OpenGrokShellToolCall,
        any OpenGrokShellProcessExecution
    ) async -> Result<OpenGrokShellToolCallResult, OpenGrokShellToolRuntimeError>
    public typealias CancelOperation = @Sendable (OpenGrokShellToolCall) async -> Void

    private let invokeOperation: InvokeOperation
    private let cancelOperation: CancelOperation

    public init(
        invoke: @escaping InvokeOperation,
        cancel: @escaping CancelOperation = { _ in }
    ) {
        self.invokeOperation = invoke
        self.cancelOperation = cancel
    }

    public func invoke(
        _ call: OpenGrokShellToolCall,
        using process: any OpenGrokShellProcessExecution
    ) async -> Result<OpenGrokShellToolCallResult, OpenGrokShellToolRuntimeError> {
        await invokeOperation(call, process)
    }

    public func cancel(_ call: OpenGrokShellToolCall) async {
        await cancelOperation(call)
    }
}

public actor OpenGrokShellToolRuntimeComposition {
    private let backend: any ShellProcessBackend
    private let runtime: any OpenGrokShellToolRuntime
    private var executions: [String: OpenGrokShellOwnedProcessExecution] = [:]
    private var workingDirectories: [String: URL] = [:]
    private var activeCalls: [String: OpenGrokShellToolCall] = [:]
    private var cancelledCallKeys: Set<String> = []

    public init(
        processBackend: any ShellProcessBackend,
        runtime: any OpenGrokShellToolRuntime
    ) {
        self.backend = processBackend
        self.runtime = runtime
    }

    public func registerSession(sessionID: String, workingDirectory: URL) throws {
        let normalizedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSessionID.isEmpty else {
            throw OpenGrokShellToolBridgeError.invalidSessionID
        }
        let normalizedDirectory = workingDirectory.standardizedFileURL
        if let existingDirectory = workingDirectories[normalizedSessionID] {
            guard existingDirectory == normalizedDirectory else {
                throw OpenGrokShellToolBridgeError.sessionWorkingDirectoryMismatch(
                    sessionID: normalizedSessionID,
                    expected: existingDirectory,
                    actual: normalizedDirectory
                )
            }
            return
        }
        executions[normalizedSessionID] = try OpenGrokShellOwnedProcessExecution(
            sessionID: normalizedSessionID,
            workingDirectory: normalizedDirectory,
            backend: backend
        )
        workingDirectories[normalizedSessionID] = normalizedDirectory
    }

    public func execution(
        for sessionID: String,
        workingDirectory: URL
    ) throws -> any OpenGrokShellProcessExecution {
        let normalizedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let execution = executions[normalizedSessionID], let existingDirectory = workingDirectories[normalizedSessionID] else {
            throw OpenGrokShellToolBridgeError.sessionNotRegistered(normalizedSessionID)
        }
        let normalizedDirectory = workingDirectory.standardizedFileURL
        guard normalizedDirectory == existingDirectory else {
            throw OpenGrokShellToolBridgeError.sessionWorkingDirectoryMismatch(
                sessionID: normalizedSessionID,
                expected: existingDirectory,
                actual: normalizedDirectory
            )
        }
        return execution
    }

    public func invoke(
        sessionID: String,
        workingDirectory: URL,
        name: String,
        args: JSONValue,
        callID: String
    ) async throws -> Result<OpenGrokShellToolCallResult, OpenGrokShellToolRuntimeError> {
        let normalizedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedCallID = callID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSessionID.isEmpty else {
            throw OpenGrokShellToolBridgeError.invalidSessionID
        }
        guard !normalizedName.isEmpty else {
            throw OpenGrokShellToolRuntimeError.invalidCall("tool name is empty")
        }
        guard !normalizedCallID.isEmpty else {
            throw OpenGrokShellToolBridgeError.invalidToolCallID
        }
        let process = try execution(for: normalizedSessionID, workingDirectory: workingDirectory)
        let call = OpenGrokShellToolCall(
            sessionID: normalizedSessionID,
            name: normalizedName,
            args: args,
            callID: normalizedCallID
        )
        let callKey = Self.callKey(for: call)
        activeCalls[callKey] = call
        defer {
            activeCalls.removeValue(forKey: callKey)
            cancelledCallKeys.remove(callKey)
        }

        return await withTaskCancellationHandler(
            operation: {
                let result = await runtime.invoke(call, using: process)
                if Task.isCancelled || cancelledCallKeys.contains(callKey) {
                    try? await cancel(call)
                    return .failure(.cancelled)
                }
                return result
            },
            onCancel: {
                Task {
                    await process.cancel(toolCallID: call.callID)
                    await runtime.cancel(call)
                }
            }
        )
    }

    public func cancel(
        sessionID: String,
        name: String,
        args: JSONValue = .object([:]),
        callID: String
    ) async throws {
        let normalizedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        let process = try execution(for: normalizedSessionID, workingDirectory: workingDirectories[normalizedSessionID] ?? URL(fileURLWithPath: "/"))
        let call = OpenGrokShellToolCall(
            sessionID: normalizedSessionID,
            name: name,
            args: args,
            callID: callID
        )
        await cancel(call, process: process)
    }

    public func closeSession(_ sessionID: String) async throws {
        let normalizedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let process = executions[normalizedSessionID] else {
            throw OpenGrokShellToolBridgeError.sessionNotRegistered(normalizedSessionID)
        }
        let calls = activeCalls.values.filter { $0.sessionID == normalizedSessionID }
        for call in calls {
            await cancel(call, process: process)
        }
        await process.cancelAll()
        executions.removeValue(forKey: normalizedSessionID)
        workingDirectories.removeValue(forKey: normalizedSessionID)
    }

    public func shutdown() async {
        let calls = Array(activeCalls.values)
        for call in calls {
            if let process = executions[call.sessionID] {
                await cancel(call, process: process)
            }
        }
        let activeExecutions = Array(executions.values)
        for process in activeExecutions {
            await process.cancelAll()
        }
        executions.removeAll()
        workingDirectories.removeAll()
    }

    private func cancel(_ call: OpenGrokShellToolCall) async throws {
        let process = try execution(for: call.sessionID, workingDirectory: workingDirectories[call.sessionID] ?? URL(fileURLWithPath: "/"))
        await cancel(call, process: process)
    }

    private func cancel(
        _ call: OpenGrokShellToolCall,
        process: any OpenGrokShellProcessExecution
    ) async {
        cancelledCallKeys.insert(Self.callKey(for: call))
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await process.cancel(toolCallID: call.callID) }
            group.addTask { await self.runtime.cancel(call) }
            await group.waitForAll()
        }
    }

    private static func callKey(for call: OpenGrokShellToolCall) -> String {
        "\(call.sessionID)\u{1F}\(call.callID)"
    }
}
