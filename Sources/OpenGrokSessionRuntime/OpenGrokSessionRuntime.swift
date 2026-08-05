import Foundation
import OpenGrokAgentCoordinator
import OpenGrokSessionPersistence
import OpenGrokShared
import OpenGrokToolRegistry
import OpenGrokToolTypes
import OpenGrokWorkflow

public struct WorkflowRuntimeCompletion: Codable, Sendable, Hashable {
    public var runID: String
    public var workflowName: String
    public var status: PersistedWorkflowStatus
    public var result: JSONValue?
    public var message: String?

    private enum CodingKeys: String, CodingKey {
        case runID = "run_id"
        case workflowName = "workflow_name"
        case status
        case result
        case message
    }

    public init(
        runID: String,
        workflowName: String,
        status: PersistedWorkflowStatus,
        result: JSONValue? = nil,
        message: String? = nil
    ) {
        self.runID = runID
        self.workflowName = workflowName
        self.status = status
        self.result = result
        self.message = message
    }
}

public enum WorkflowRuntimeError: Error, Sendable, Hashable, CustomStringConvertible {
    case missingRun(String)
    case immutableResumeMismatch
    case notResumable(String)
    case persistence(String)

    public var description: String {
        switch self {
        case .missingRun(let id): return "workflow run does not exist: \(id)"
        case .immutableResumeMismatch: return "workflow resume requires the same immutable script and arguments"
        case .notResumable(let id): return "workflow run is not resumable: \(id)"
        case .persistence(let value): return value
        }
    }
}

public actor OpenGrokSessionRuntime {
    public let store: WorkflowSessionStore
    public let coordinator: OpenGrokAgentCoordinator

    private var runs: [String: WorkflowRun] = [:]
    private var cancellations: [String: WorkflowCancellation] = [:]
    private var arguments: [String: JSONValue] = [:]
    private var sources: [String: WorkflowSource] = [:]
    private var hosts: [String: any WorkflowHost] = [:]
    private var records: [String: WorkflowRunRecord] = [:]

    public init(
        store: WorkflowSessionStore = WorkflowSessionStore(),
        coordinator: OpenGrokAgentCoordinator = OpenGrokAgentCoordinator()
    ) {
        self.store = store
        self.coordinator = coordinator
    }

    public func restore() async throws -> [WorkflowRunRecord] {
        do {
            let restored = try await store.restore()
            records = Dictionary(uniqueKeysWithValues: restored.map { ($0.runID, $0) })
            return restored
        } catch {
            throw WorkflowRuntimeError.persistence(String(describing: error))
        }
    }

    @discardableResult
    public func start(
        source: WorkflowSource,
        arguments: JSONValue = .object([:]),
        agentBudget: UInt64 = defaultWorkflowAgentBudget,
        host: any WorkflowHost
    ) async throws -> WorkflowRunRecord {
        let metadata = try extractWorkflowMetadata(from: source.script)
        let runID = UUID().uuidString
        let finalJournalURL = try await store.journalURL(for: runID)
        let journal = try WorkflowJournal(path: finalJournalURL)
        let run = WorkflowRun(runID: runID, script: source.script, arguments: arguments, journal: journal)
        let record = WorkflowRunRecord(
            runID: runID,
            workflowName: metadata.name,
            scriptHash: stableDigest(source.script),
            argumentsHash: stableDigest(arguments),
            status: .active,
            journalPath: finalJournalURL?.path,
            agentBudget: max(1, min(agentBudget, maxWorkflowAgentBudget))
        )
        try await store.insert(record)
        records[runID] = record
        runs[runID] = run
        cancellations[runID] = WorkflowCancellation()
        self.arguments[runID] = arguments
        sources[runID] = source
        hosts[runID] = host
        launch(runID: runID, run: run, budget: record.agentBudget, host: host, cancellation: cancellations[runID]!)
        return record
    }

    @discardableResult
    public func startInline(
        script: String,
        arguments: JSONValue = .object([:]),
        agentBudget: UInt64 = defaultWorkflowAgentBudget,
        host: any WorkflowHost
    ) async throws -> WorkflowRunRecord {
        let metadata = try extractWorkflowMetadata(from: script)
        return try await start(
            source: WorkflowSource(name: metadata.name, path: "<inline>", script: script, scope: .registered),
            arguments: arguments,
            agentBudget: agentBudget,
            host: host
        )
    }

    public func pause(runID: String, message: String = "workflow paused") throws {
        guard let cancellation = cancellations[runID] else { throw WorkflowRuntimeError.missingRun(runID) }
        cancellation.requestPause(message: message)
    }

    public func stop(runID: String) throws {
        guard let cancellation = cancellations[runID] else { throw WorkflowRuntimeError.missingRun(runID) }
        cancellation.cancel()
    }

    @discardableResult
    public func resume(
        runID: String,
        script: String,
        arguments: JSONValue,
        agentBudget: UInt64,
        host: any WorkflowHost
    ) async throws -> WorkflowRunRecord {
        let record: WorkflowRunRecord
        if let localRecord = records[runID] {
            record = localRecord
        } else if let storedRecord = try? await store.record(runID) {
            record = storedRecord
            records[runID] = storedRecord
        } else {
            throw WorkflowRuntimeError.missingRun(runID)
        }
        guard record.status.isResumable else { throw WorkflowRuntimeError.notResumable(runID) }
        guard let source = sources[runID], source.script == script, self.arguments[runID] == arguments else {
            throw WorkflowRuntimeError.immutableResumeMismatch
        }
        guard let run = runs[runID] else {
            throw WorkflowRuntimeError.notResumable(runID)
        }
        let cancellation = WorkflowCancellation()
        cancellations[runID] = cancellation
        hosts[runID] = host
        var activeRecord = record
        activeRecord.status = .active
        activeRecord.agentBudget = max(1, min(agentBudget, maxWorkflowAgentBudget))
        activeRecord.revision = activeRecord.revision.saturatingAdd(1)
        try await store.update(activeRecord)
        records[runID] = activeRecord
        launchResume(
            runID: runID,
            run: run,
            source: source,
            arguments: arguments,
            budget: activeRecord.agentBudget,
            host: host,
            cancellation: cancellation
        )
        return activeRecord
    }

    public func record(runID: String) async throws -> WorkflowRunRecord {
        if let record = records[runID] { return record }
        do {
            let record = try await store.record(runID)
            records[runID] = record
            return record
        } catch {
            throw WorkflowRuntimeError.missingRun(runID)
        }
    }

    public func list() async throws -> [WorkflowRunRecord] {
        do { return try await store.list() }
        catch { throw WorkflowRuntimeError.persistence(String(describing: error)) }
    }

    public func pollCompletions() async throws -> [WorkflowRuntimeCompletion] {
        let terminal = records.values.filter { $0.status.isCompletionReportable && !$0.completionDelivered }
        var completions: [WorkflowRuntimeCompletion] = []
        for record in terminal.sorted(by: { $0.createdAtMS < $1.createdAtMS }) {
            if try await store.claimCompletion(runID: record.runID, revision: record.revision) {
                var claimed = record
                claimed.completionDelivered = true
                records[record.runID] = claimed
                completions.append(WorkflowRuntimeCompletion(
                    runID: record.runID,
                    workflowName: record.workflowName,
                    status: record.status,
                    result: record.result,
                    message: record.message
                ))
            }
        }
        return completions
    }

    public func awaitCompletion(runID: String, timeoutMS: UInt64? = nil) async throws -> WorkflowRunRecord {
        let startMS = UInt64(Date().timeIntervalSince1970 * 1_000)
        while true {
            let current = try await record(runID: runID)
            if current.status.isTerminal || current.status.isResumable { return current }
            if let timeoutMS, UInt64(Date().timeIntervalSince1970 * 1_000) >= startMS.saturatingAdd(timeoutMS) {
                throw WorkflowRuntimeError.persistence("workflow completion wait timed out")
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private func launch(
        runID: String,
        run: WorkflowRun,
        budget: UInt64,
        host: any WorkflowHost,
        cancellation: WorkflowCancellation
    ) {
        Task { [weak self] in
            let result = await run.start(agentBudget: budget, host: host, cancellation: cancellation)
            await self?.finish(runID: runID, outcome: result)
        }
    }

    private func launchResume(
        runID: String,
        run: WorkflowRun,
        source: WorkflowSource,
        arguments: JSONValue,
        budget: UInt64,
        host: any WorkflowHost,
        cancellation: WorkflowCancellation
    ) {
        Task { [weak self] in
            let result = await run.resume(script: source.script, arguments: arguments, agentBudget: budget, host: host, cancellation: cancellation)
            await self?.finish(runID: runID, outcome: result)
        }
    }

    private func finish(runID: String, outcome: WorkflowOutcome) async {
        guard var record = records[runID] else { return }
        switch outcome {
        case .completed(let result):
            record.status = .completed
            record.result = result
            record.message = nil
        case .paused(_, let message):
            record.status = .paused
            record.message = message
        case .budgetExceeded(let message):
            record.status = .budgetExceeded
            record.message = message
        case .cancelled:
            record.status = .cancelled
            record.message = "workflow cancelled"
        case .failed(let error):
            record.status = .failed
            record.message = error
        }
        record.revision = record.revision.saturatingAdd(1)
        records[runID] = record
        try? await store.update(record)
    }
}

private func stableDigest(_ value: String) -> String {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in value.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 1_099_511_628_211
    }
    return String(format: "%016llx", hash)
}

private func stableDigest(_ value: JSONValue) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return stableDigest(String(data: (try? encoder.encode(value)) ?? Data(), encoding: .utf8) ?? "")
}

// Internal rather than fileprivate so the module's other files (the workflow
// run registry) can bump their own counters with it instead of reaching for a
// helper in another module.
extension UInt64 {
    func saturatingAdd(_ value: UInt64) -> UInt64 { addingReportingOverflow(value).overflow ? UInt64.max : self + value }
}
