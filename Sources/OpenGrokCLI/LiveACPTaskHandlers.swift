import Foundation
import OpenGrokACP
import OpenGrokACPRuntime
import OpenGrokAgentCoordinator
import OpenGrokShared
import OpenGrokShell
import OpenGrokShellBase

private actor LiveACPTaskControlWireSessions {
    private struct Owner: Sendable, Equatable {
        let clientID: String?
    }

    private var sessions: [AcpSessionId: Owner] = [:]
    private var authenticatedRootOwnerClientID: String?

    func register(_ sessionID: AcpSessionId, clientID: String?) {
        let owner = Owner(clientID: clientID)
        if let clientID {
            if let authenticatedRootOwnerClientID,
               authenticatedRootOwnerClientID != clientID
            {
                return
            }
            if authenticatedRootOwnerClientID == nil {
                authenticatedRootOwnerClientID = clientID
                // A direct stdio carrier has no leader identity. Once a
                // leader-authenticated carrier claims this root, retaining an
                // anonymous binding would leave a second authority path into
                // the same process, subagent, and scheduler capabilities.
                sessions = sessions.filter { $0.value.clientID != nil }
            }
        } else if authenticatedRootOwnerClientID != nil {
            return
        }
        guard sessions[sessionID] == nil || sessions[sessionID] == owner else {
            return
        }
        sessions[sessionID] = owner
    }

    func unregister(_ sessionID: AcpSessionId) {
        sessions.removeValue(forKey: sessionID)
    }

    func contains(_ sessionID: AcpSessionId, clientID: String?) -> Bool {
        sessions[sessionID] == Owner(clientID: clientID)
    }

    func ownedSessions(clientID: String?) -> [AcpSessionId] {
        sessions.compactMap { sessionID, owner in
            owner == Owner(clientID: clientID) ? sessionID : nil
        }
    }
}

/// Owner-bound ACP controls for the running root, never a caller-selected host.
/// ACP wire session IDs and the durable root ID are distinct; lifecycle hooks
/// bind the former before any request can reach the immutable latter.
struct LiveACPTaskControlHandler: ACPAgentExtensionHandler, Sendable {
    static let methods = [
        "x.ai/task/list",
        "x.ai/task/kill",
        "x.ai/subagent/cancel",
        "x.ai/subagent/get",
        "x.ai/subagent/list_running",
        "x.ai/scheduler/delete",
    ]

    static let maximumSubagentWaitMilliseconds: UInt64 = 30_000

    let gateway: ACPNotificationGateway
    let ownerRootSessionID: String
    let workingDirectory: URL
    let toolExecutor: LiveToolExecutor
    let schedulerHost: LiveSchedulerHost?
    private let sessions = LiveACPTaskControlWireSessions()

    init(
        gateway: ACPNotificationGateway,
        ownerRootSessionID: String,
        workingDirectory: URL,
        toolExecutor: LiveToolExecutor,
        schedulerHost: LiveSchedulerHost? = nil
    ) {
        self.gateway = gateway
        self.ownerRootSessionID = ownerRootSessionID
        self.workingDirectory = workingDirectory
        self.toolExecutor = toolExecutor
        self.schedulerHost = schedulerHost ?? toolExecutor.schedulerHost
    }

    func opened(_ sessionID: AcpSessionId) async {
        let clientID = ACPLeaderRequestAuthority.clientID
        await sessions.register(sessionID, clientID: clientID)
    }

    func closed(_ sessionID: AcpSessionId) async {
        await sessions.unregister(sessionID)
    }

    func handle(method: String, params: JSONValue) async throws -> JSONValue {
        let fields = try object(params)

        switch method {
        case "x.ai/task/list":
            return try await listTasks(fields)
        case "x.ai/task/kill":
            return try await killTask(fields)
        case "x.ai/subagent/cancel":
            return try await cancelSubagent(fields)
        case "x.ai/subagent/get":
            return try await getSubagent(fields)
        case "x.ai/subagent/list_running":
            return try await listRunningSubagents(fields)
        case "x.ai/scheduler/delete":
            return try await deleteScheduledTask(fields)
        default:
            throw AcpError.methodNotFound()
        }
    }

    private func listTasks(_ fields: [String: JSONValue]) async throws -> JSONValue {
        let wireSessionID = try requiredString("sessionId", in: fields)
        guard await authorized(wireSessionID),
              let process = await ownedProcess()
        else {
            return failure("session not found or no terminal backend")
        }

        let snapshots = await process.listTasks().filter {
            $0.ownerSessionID == ownerRootSessionID
        }
        return success(["tasks": .array(snapshots.map(taskSnapshot))])
    }

    private func killTask(_ fields: [String: JSONValue]) async throws -> JSONValue {
        let wireSessionID = try requiredString("sessionId", in: fields)
        let taskID = try requiredString("taskId", in: fields)

        if let source = fields["source"] {
            guard let value = source.stringValue,
                  value == "clientUi" || value == "teardown"
            else {
                throw invalid("invalid field `source`, expected `clientUi` or `teardown`")
            }
        }

        guard await authorized(wireSessionID),
              let process = await ownedProcess()
        else {
            return failure("session not found")
        }

        let outcome: String
        switch await process.killTask(taskID) {
        case .killed:
            outcome = "killed"
        case .alreadyExited:
            outcome = "already_exited"
        case .notFound:
            outcome = "not_found"
        }

        return success([
            "taskId": .string(taskID),
            "outcome": .string(outcome),
        ])
    }

    private func cancelSubagent(_ fields: [String: JSONValue]) async throws -> JSONValue {
        let subagentID = try requiredString("subagentId", in: fields)
        let authorized = try await authorizedOptionalSession(in: fields)
        let outcome: LiveSubagentCancelOutcome

        if authorized,
           let host = await ownedSubagentHost(),
           await ownedChild(id: subagentID, host: host, includingWorkflow: true) != nil
        {
            outcome = await host.cancelSubagent(id: subagentID)
        } else {
            outcome = .notFound
        }

        var detail: [String: JSONValue]
        let cancelled: Bool
        switch outcome {
        case .cancelled:
            detail = ["kind": .string("cancelled")]
            cancelled = true
        case .alreadyFinished(let status):
            detail = [
                "kind": .string("already_finished"),
                "status": .string(status),
            ]
            cancelled = false
        case .notFound:
            detail = ["kind": .string("not_found")]
            cancelled = false
        }

        return success([
            "subagentId": .string(subagentID),
            "cancelled": .bool(cancelled),
            "outcome": .object(detail),
        ])
    }

    private func getSubagent(_ fields: [String: JSONValue]) async throws -> JSONValue {
        let subagentID = try requiredString("subagentId", in: fields)

        let block: Bool
        if let value = fields["block"] {
            guard let decoded = value.boolValue else {
                throw invalid("invalid field `block`, expected a boolean")
            }
            block = decoded
        } else {
            block = false
        }

        let requestedTimeout: UInt64
        if let value = fields["timeoutMs"] {
            guard let decoded = value.uint64Value else {
                throw invalid("invalid field `timeoutMs`, expected a non-negative integer")
            }
            requestedTimeout = decoded
        } else {
            requestedTimeout = Self.maximumSubagentWaitMilliseconds
        }

        guard try await authorizedOptionalSession(in: fields),
              let host = await ownedSubagentHost(),
              let request = await ownedChild(
                id: subagentID,
                host: host,
                includingWorkflow: false
              )
        else {
            return success(["snapshot": .null])
        }

        let snapshot: LiveSubagentSnapshot?
        if block, requestedTimeout > 0 {
            snapshot = await host.awaitSubagent(
                id: subagentID,
                timeoutMS: min(requestedTimeout, Self.maximumSubagentWaitMilliseconds)
            )
        } else {
            snapshot = await host.subagentSnapshot(id: subagentID)
        }

        guard let snapshot else {
            return success(["snapshot": .null])
        }
        let terminalResult: OpenGrokChildResult?
        if snapshot.completed {
            terminalResult = await host.coordinator.listCompleted().first {
                $0.request.id == subagentID
                    && $0.request.parentSessionID == ownerRootSessionID
            }?.result
        } else {
            terminalResult = nil
        }
        return success([
            "snapshot": subagentSnapshot(
                snapshot,
                request: request,
                terminalResult: terminalResult
            ),
        ])
    }

    private func listRunningSubagents(
        _ fields: [String: JSONValue]
    ) async throws -> JSONValue {
        let wireSessionID = try requiredString("sessionId", in: fields)
        guard await authorized(wireSessionID),
              let host = await ownedSubagentHost()
        else {
            return success(["subagents": .array([])])
        }

        let running = await host.coordinator.listActive(
            parentSessionID: ownerRootSessionID
        )
        var values: [JSONValue] = []
        for entry in running where entry.request.owner != .workflow {
            guard let snapshot = await host.subagentSnapshot(id: entry.request.id),
                  snapshot.status == "running"
            else {
                continue
            }
            values.append(runningSubagentSnapshot(snapshot, request: entry.request))
        }
        return success(["subagents": .array(values)])
    }

    private func deleteScheduledTask(
        _ fields: [String: JSONValue]
    ) async throws -> JSONValue {
        let wireSessionID = try requiredString("sessionId", in: fields)
        let taskID = try requiredString("taskId", in: fields)

        guard await authorized(wireSessionID), let schedulerHost else {
            return failure("session not found")
        }

        do {
            let deleted = try await schedulerHost.deleteTask(id: taskID)
            return success([
                "taskId": .string(taskID),
                "deleted": .bool(deleted),
            ])
        } catch {
            return failure(String(describing: error))
        }
    }

    private func authorized(_ value: String) async -> Bool {
        let sessionID = AcpSessionId(value)
        let clientID = ACPLeaderRequestAuthority.clientID
        guard await sessions.contains(sessionID, clientID: clientID) else {
            return false
        }
        return await gateway.ownsSession(sessionID)
    }

    private func authorizedOptionalSession(
        in fields: [String: JSONValue]
    ) async throws -> Bool {
        if fields["sessionId"] != nil {
            return await authorized(try requiredString("sessionId", in: fields))
        }

        let clientID = ACPLeaderRequestAuthority.clientID
        let candidates = await sessions.ownedSessions(clientID: clientID)
        for sessionID in candidates {
            if await gateway.ownsSession(sessionID) {
                return true
            }
        }
        return false
    }

    private func ownedProcess() async -> (any OpenGrokShellProcessExecution)? {
        guard let process = await toolExecutor.processExecution(
            sessionID: ownerRootSessionID,
            workingDirectory: workingDirectory
        ),
        process.sessionID == ownerRootSessionID,
        LiveToolExecutor.workspaceRootsMatch(process.workingDirectory, workingDirectory)
        else {
            return nil
        }
        return process
    }

    private func ownedSubagentHost() async -> LiveSubagentHost? {
        guard let host = toolExecutor.subagentHost,
              await host.context.sessionID == ownerRootSessionID
        else {
            return nil
        }
        return host
    }

    private func ownedChild(
        id: String,
        host: LiveSubagentHost,
        includingWorkflow: Bool
    ) async -> OpenGrokChildRequest? {
        let active = await host.coordinator.listActive(
            parentSessionID: ownerRootSessionID
        )
        let completed = await host.coordinator.listCompleted()
        guard let request = (active + completed).first(where: {
            $0.request.id == id && $0.request.parentSessionID == ownerRootSessionID
        })?.request,
        includingWorkflow || request.owner != .workflow
        else {
            return nil
        }
        return request
    }

    private func taskSnapshot(_ snapshot: ShellTaskSnapshot) -> JSONValue {
        var fields: [String: JSONValue] = [
            "task_id": .string(snapshot.taskID),
            "command": .string(snapshot.command),
            "cwd": .string(snapshot.cwd.path),
            "start_time": systemTime(snapshot.startTime),
            "end_time": snapshot.endTime.map(systemTime) ?? .null,
            "output": .string(snapshot.output),
            "output_file": snapshot.outputFile.map { .string($0.path) } ?? .null,
            "truncated": .bool(snapshot.truncated),
            "output_total_bytes": .number(.uint64(UInt64(max(0, snapshot.outputTotalBytes)))),
            "exit_code": snapshot.exitCode.map { .number(.int64(Int64($0))) } ?? .null,
            "signal": snapshot.signal.map(JSONValue.string) ?? .null,
            "completed": .bool(snapshot.completed),
            "kind": .string(snapshot.kind.rawValue),
            "block_waited": .bool(snapshot.blockWaited),
            "explicitly_killed": .bool(snapshot.explicitlyKilled),
            "kill_result_delivered": .bool(false),
            "is_backgrounded": .bool(snapshot.isBackgrounded),
        ]
        if let displayCommand = snapshot.displayCommand {
            fields["display_command"] = .string(displayCommand)
        }
        if let ownerSessionID = snapshot.ownerSessionID {
            fields["owner_session_id"] = .string(ownerSessionID)
        }
        if let description = snapshot.description {
            fields["description"] = .string(description)
        }
        return .object(fields)
    }

    private func runningSubagentSnapshot(
        _ snapshot: LiveSubagentSnapshot,
        request: OpenGrokChildRequest
    ) -> JSONValue {
        .object([
            "subagentId": .string(snapshot.subagentID),
            "parentSessionId": .string(request.parentSessionID),
            "childSessionId": .string(snapshot.subagentID),
            "subagentType": .string(snapshot.subagentType),
            "description": .string(snapshot.description),
            "startedAtEpochMs": .number(.uint64(epochMilliseconds(snapshot.startedAt))),
            "durationMs": .number(.uint64(snapshot.durationMS)),
            "turnCount": .number(.uint64(UInt64(snapshot.turnCount))),
            "toolCallCount": .number(.uint64(UInt64(snapshot.toolCallCount))),
            "tokensUsed": .number(.uint64(0)),
            "contextWindowTokens": .number(.uint64(0)),
            "contextUsagePct": .number(.uint64(0)),
            "toolsUsed": .array([]),
            "errorCount": .number(.uint64(0)),
        ])
    }

    private func subagentSnapshot(
        _ snapshot: LiveSubagentSnapshot,
        request: OpenGrokChildRequest,
        terminalResult: OpenGrokChildResult?
    ) -> JSONValue {
        var fields: [String: JSONValue] = [
            "subagentId": .string(snapshot.subagentID),
            "parentSessionId": .string(request.parentSessionID),
            "childSessionId": .string(snapshot.subagentID),
            "subagentType": .string(snapshot.subagentType),
            "description": .string(snapshot.description),
            "startedAtEpochMs": .number(.uint64(epochMilliseconds(snapshot.startedAt))),
            "durationMs": .number(.uint64(snapshot.durationMS)),
            "status": .string(snapshot.status),
        ]

        switch snapshot.status {
        case "running":
            fields["turnCount"] = .number(.uint64(UInt64(snapshot.turnCount)))
            fields["toolCallCount"] = .number(.uint64(UInt64(snapshot.toolCallCount)))
            fields["tokensUsed"] = .number(.uint64(0))
            fields["contextWindowTokens"] = .number(.uint64(0))
            fields["contextUsagePct"] = .number(.uint64(0))
            fields["toolsUsed"] = .array([])
            fields["errorCount"] = .number(.uint64(0))
        case "completed":
            fields["output"] = .string(terminalResult?.output ?? snapshot.output)
            fields["toolCalls"] = .number(.uint64(UInt64(snapshot.toolCallCount)))
            fields["turns"] = .number(.uint64(UInt64(snapshot.turnCount)))
            if let worktree = request.worktreePath {
                fields["worktreePath"] = .string(worktree)
            }
        case "failed":
            fields["failureError"] = .string(snapshot.output)
        case "cancelled":
            if let reason = terminalResult?.error, !reason.isEmpty {
                fields["cancelReason"] = .string(reason)
            }
        default:
            break
        }

        if let resumedFrom = request.resumeFrom {
            fields["resumedFrom"] = .string(resumedFrom)
        }
        return .object(fields)
    }

    private func systemTime(_ date: Date) -> JSONValue {
        let interval = max(0, date.timeIntervalSince1970)
        let seconds = UInt64(interval)
        let nanoseconds = UInt64((interval - Double(seconds)) * 1_000_000_000)
        return .object([
            "secs_since_epoch": .number(.uint64(seconds)),
            "nanos_since_epoch": .number(.uint64(min(nanoseconds, 999_999_999))),
        ])
    }

    private func epochMilliseconds(_ date: Date) -> UInt64 {
        UInt64(max(0, date.timeIntervalSince1970 * 1_000))
    }

    private func object(_ value: JSONValue) throws -> [String: JSONValue] {
        guard let result = value.objectValue else {
            throw invalid("expected a JSON object")
        }
        return result
    }

    private func requiredString(
        _ key: String,
        in fields: [String: JSONValue]
    ) throws -> String {
        guard let value = fields[key] else {
            throw invalid("missing field `\(key)`")
        }
        guard let result = value.stringValue else {
            throw invalid("invalid field `\(key)`, expected a string")
        }
        return result
    }

    private func invalid(_ message: String) -> AcpError {
        AcpError.invalidParams().withData(.string("invalid params: \(message)"))
    }

    private func success(_ payload: [String: JSONValue]) -> JSONValue {
        .object(["result": .object(payload)])
    }

    private func failure(_ message: String) -> JSONValue {
        .object([
            "result": .null,
            "error": .string(message),
        ])
    }
}
