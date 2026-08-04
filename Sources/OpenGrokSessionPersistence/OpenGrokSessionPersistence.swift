import Foundation
import OpenGrokShared

public enum PersistedWorkflowStatus: String, Codable, Sendable, Hashable {
    case active
    case completed
    case paused
    case budgetExceeded = "budget_exceeded"
    case cancelled
    case failed
    case interrupted

    public var isTerminal: Bool {
        switch self {
        case .active, .paused, .budgetExceeded: return false
        case .completed, .cancelled, .failed, .interrupted: return true
        }
    }

    public var isResumable: Bool {
        self == .paused || self == .budgetExceeded
    }

    public var isCompletionReportable: Bool {
        self != .active && self != .interrupted
    }
}

public struct WorkflowRunRecord: Codable, Sendable, Hashable {
    public var runID: String
    public var workflowName: String
    public var scriptHash: String
    public var argumentsHash: String
    public var status: PersistedWorkflowStatus
    public var result: JSONValue?
    public var message: String?
    public var journalPath: String?
    public var agentBudget: UInt64
    public var agentsUsed: UInt64
    public var revision: UInt64
    public var completionDelivered: Bool
    public var createdAtMS: UInt64

    private enum CodingKeys: String, CodingKey {
        case runID = "run_id"
        case workflowName = "workflow_name"
        case scriptHash = "script_hash"
        case argumentsHash = "arguments_hash"
        case status
        case result
        case message
        case journalPath = "journal_path"
        case agentBudget = "agent_budget"
        case agentsUsed = "agents_used"
        case revision
        case completionDelivered = "completion_delivered"
        case createdAtMS = "created_at_ms"
    }

    public init(
        runID: String,
        workflowName: String,
        scriptHash: String,
        argumentsHash: String,
        status: PersistedWorkflowStatus = .active,
        result: JSONValue? = nil,
        message: String? = nil,
        journalPath: String? = nil,
        agentBudget: UInt64,
        agentsUsed: UInt64 = 0,
        revision: UInt64 = 0,
        completionDelivered: Bool = false,
        createdAtMS: UInt64 = UInt64(Date().timeIntervalSince1970 * 1_000)
    ) {
        self.runID = runID
        self.workflowName = workflowName
        self.scriptHash = scriptHash
        self.argumentsHash = argumentsHash
        self.status = status
        self.result = result
        self.message = message
        self.journalPath = journalPath
        self.agentBudget = agentBudget
        self.agentsUsed = agentsUsed
        self.revision = revision
        self.completionDelivered = completionDelivered
        self.createdAtMS = createdAtMS
    }
}

public enum WorkflowPersistenceError: Error, Sendable, Hashable, CustomStringConvertible {
    case duplicateRun(String)
    case missingRun(String)
    case invalidDirectory(String)
    case io(String)

    public var description: String {
        switch self {
        case .duplicateRun(let id): return "workflow run already exists: \(id)"
        case .missingRun(let id): return "workflow run does not exist: \(id)"
        case .invalidDirectory(let path): return "invalid workflow persistence directory: \(path)"
        case .io(let message): return "workflow persistence I/O failed: \(message)"
        }
    }
}

public actor WorkflowSessionStore {
    public static let manifestName = "workflow-runs.json"
    public static let journalDirectoryName = "workflow-journals"

    private let directory: URL?
    private var records: [String: WorkflowRunRecord] = [:]
    private var loaded = false

    public init(directory: URL? = nil) {
        self.directory = directory
    }

    public func load() throws -> [WorkflowRunRecord] {
        if loaded { return records.values.sorted { $0.createdAtMS < $1.createdAtMS } }
        loaded = true
        guard let directory else { return [] }
        let manifest = directory.appendingPathComponent(Self.manifestName)
        guard FileManager.default.fileExists(atPath: manifest.path) else { return [] }
        do {
            let data = try Data(contentsOf: manifest)
            let decoded = try JSONDecoder().decode([WorkflowRunRecord].self, from: data)
            records = Dictionary(uniqueKeysWithValues: decoded.map { ($0.runID, $0) })
            return decoded.sorted { $0.createdAtMS < $1.createdAtMS }
        } catch {
            throw WorkflowPersistenceError.io(String(describing: error))
        }
    }

    public func restore() throws -> [WorkflowRunRecord] {
        _ = try load()
        var restored: [WorkflowRunRecord] = []
        for id in Array(records.keys) {
            guard var record = records[id] else { continue }
            if record.status == .active {
                record.status = .interrupted
                record.message = "the session ended while this workflow was active; start a new run"
                record.revision = record.revision.saturatingAdd(1)
                record.completionDelivered = true
                records[id] = record
            }
            restored.append(record)
        }
        try persist()
        return restored.sorted { $0.createdAtMS < $1.createdAtMS }
    }

    public func insert(_ record: WorkflowRunRecord) throws {
        _ = try load()
        guard records[record.runID] == nil else { throw WorkflowPersistenceError.duplicateRun(record.runID) }
        records[record.runID] = record
        try persist()
    }

    public func update(_ record: WorkflowRunRecord) throws {
        _ = try load()
        guard records[record.runID] != nil else { throw WorkflowPersistenceError.missingRun(record.runID) }
        records[record.runID] = record
        try persist()
    }

    public func record(_ runID: String) throws -> WorkflowRunRecord {
        _ = try load()
        guard let record = records[runID] else { throw WorkflowPersistenceError.missingRun(runID) }
        return record
    }

    public func list() throws -> [WorkflowRunRecord] {
        _ = try load()
        return records.values.sorted { $0.createdAtMS < $1.createdAtMS }
    }

    public func claimCompletion(runID: String, revision: UInt64) throws -> Bool {
        _ = try load()
        guard var record = records[runID] else { throw WorkflowPersistenceError.missingRun(runID) }
        guard record.revision == revision, !record.completionDelivered, record.status.isCompletionReportable else { return false }
        record.completionDelivered = true
        records[runID] = record
        try persist()
        return true
    }

    public func journalURL(for runID: String) throws -> URL? {
        guard let directory else { return nil }
        guard !runID.isEmpty, runID.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
            throw WorkflowPersistenceError.invalidDirectory(runID)
        }
        let journalDirectory = directory.appendingPathComponent(Self.journalDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: journalDirectory, withIntermediateDirectories: true)
        return journalDirectory.appendingPathComponent("\(runID).jsonl")
    }

    private func persist() throws {
        guard let directory else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder.workflowEncoder.encode(records.values.sorted { $0.createdAtMS < $1.createdAtMS })
            try data.write(to: directory.appendingPathComponent(Self.manifestName), options: .atomic)
        } catch {
            throw WorkflowPersistenceError.io(String(describing: error))
        }
    }
}

private extension JSONEncoder {
    static var workflowEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension UInt64 {
    func saturatingAdd(_ value: UInt64) -> UInt64 { addingReportingOverflow(value).overflow ? UInt64.max : self + value }
}
