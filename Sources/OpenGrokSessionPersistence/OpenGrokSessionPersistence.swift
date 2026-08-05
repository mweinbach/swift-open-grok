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

/// Manifest version this build writes.
///
/// `WORKFLOW_RUN_MANIFEST_VERSION`
/// (`crates/codegen/xai-grok-shell/src/session/workflow/store.rs:13`).
public let workflowRunManifestVersion: UInt8 = 4

/// Manifest versions this build will load at all.
///
/// Restore validates a **range**, not equality
/// (`.../session/storage/jsonl/mod.rs:714-723`): a manifest outside
/// `1...current` is skipped with a warning rather than loaded, so a file
/// written by a newer build is never reinterpreted under this build's
/// assumptions. Version `0` is not a valid manifest.
public let supportedWorkflowRunManifestVersions: ClosedRange<UInt8> = 1...workflowRunManifestVersion

/// Why a within-range but outdated manifest cannot be resumed.
/// store.rs:104-106.
public let workflowManifestPredatesAgentAccountingMessage =
    "this workflow predates agent-count accounting and cannot be resumed; start a new run"

public struct WorkflowRunRecord: Codable, Sendable, Hashable {
    /// Manifest version this record was written at. Absent in files written
    /// before versioning; those decode as `1`, the oldest supported version.
    public var version: UInt8
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
    /// Whether agent-usage accounting for this run is known to be incomplete.
    /// Set when an outdated manifest is downgraded on restore.
    /// `agent_usage_incomplete`, store.rs:110.
    public var agentUsageIncomplete: Bool
    /// Keys this build does not model, preserved verbatim across a
    /// load/store round trip.
    public var extra: [String: JSONValue]

    /// Whether this record's version is loadable by this build.
    public var versionIsSupported: Bool {
        supportedWorkflowRunManifestVersions.contains(version)
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case agentUsageIncomplete = "agent_usage_incomplete"
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
        version: UInt8 = workflowRunManifestVersion,
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
        createdAtMS: UInt64 = UInt64(Date().timeIntervalSince1970 * 1_000),
        agentUsageIncomplete: Bool = false,
        extra: [String: JSONValue] = [:]
    ) {
        self.version = version
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
        self.agentUsageIncomplete = agentUsageIncomplete
        self.extra = extra
    }

    private static let knownKeys: Set<String> = Set(
        [
            CodingKeys.version, .agentUsageIncomplete, .runID, .workflowName,
            .scriptHash, .argumentsHash, .status, .result, .message,
            .journalPath, .agentBudget, .agentsUsed, .revision,
            .completionDelivered, .createdAtMS,
        ].map(\.rawValue)
    )

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(UInt8.self, forKey: .version)
            ?? supportedWorkflowRunManifestVersions.lowerBound
        runID = try c.decode(String.self, forKey: .runID)
        workflowName = try c.decode(String.self, forKey: .workflowName)
        scriptHash = try c.decode(String.self, forKey: .scriptHash)
        argumentsHash = try c.decode(String.self, forKey: .argumentsHash)
        status = try c.decodeIfPresent(PersistedWorkflowStatus.self, forKey: .status) ?? .active
        result = try c.decodeIfPresent(JSONValue.self, forKey: .result)
        message = try c.decodeIfPresent(String.self, forKey: .message)
        journalPath = try c.decodeIfPresent(String.self, forKey: .journalPath)
        agentBudget = try c.decodeIfPresent(UInt64.self, forKey: .agentBudget) ?? 0
        agentsUsed = try c.decodeIfPresent(UInt64.self, forKey: .agentsUsed) ?? 0
        revision = try c.decodeIfPresent(UInt64.self, forKey: .revision) ?? 0
        completionDelivered = try c.decodeIfPresent(Bool.self, forKey: .completionDelivered) ?? false
        createdAtMS = try c.decodeIfPresent(UInt64.self, forKey: .createdAtMS) ?? 0
        agentUsageIncomplete = try c.decodeIfPresent(Bool.self, forKey: .agentUsageIncomplete) ?? false
        extra = try UnknownFields.decode(from: decoder, knownKeyStrings: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(runID, forKey: .runID)
        try c.encode(workflowName, forKey: .workflowName)
        try c.encode(scriptHash, forKey: .scriptHash)
        try c.encode(argumentsHash, forKey: .argumentsHash)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(result, forKey: .result)
        try c.encodeIfPresent(message, forKey: .message)
        try c.encodeIfPresent(journalPath, forKey: .journalPath)
        try c.encode(agentBudget, forKey: .agentBudget)
        try c.encode(agentsUsed, forKey: .agentsUsed)
        try c.encode(revision, forKey: .revision)
        try c.encode(completionDelivered, forKey: .completionDelivered)
        try c.encode(createdAtMS, forKey: .createdAtMS)
        if agentUsageIncomplete { try c.encode(true, forKey: .agentUsageIncomplete) }
        if !extra.isEmpty {
            var any = encoder.container(keyedBy: AnyCodingKey.self)
            try UnknownFields.encode(extra, into: &any)
        }
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
            // Range validation, not equality: a manifest outside
            // `1...WORKFLOW_RUN_MANIFEST_VERSION` is skipped rather than
            // loaded (jsonl/mod.rs:714-723).
            let supported = decoded.filter(\.versionIsSupported)
            records = Dictionary(uniqueKeysWithValues: supported.map { ($0.runID, $0) })
            return supported.sorted { $0.createdAtMS < $1.createdAtMS }
        } catch {
            throw WorkflowPersistenceError.io(String(describing: error))
        }
    }

    public func restore() throws -> [WorkflowRunRecord] {
        _ = try load()
        var restored: [WorkflowRunRecord] = []
        for id in Array(records.keys) {
            guard var record = records[id] else { continue }
            // A manifest older than this build's version predates agent-count
            // accounting: it is loadable but not resumable, and its usage
            // figures are not trustworthy (store.rs:100-112).
            if record.version < workflowRunManifestVersion {
                record.status = .interrupted
                record.message = workflowManifestPredatesAgentAccountingMessage
                record.agentBudget = 0
                record.agentsUsed = 0
                record.agentUsageIncomplete = true
                record.version = workflowRunManifestVersion
                record.revision = record.revision.saturatingAdd(1)
                record.completionDelivered = true
                records[id] = record
                restored.append(record)
                continue
            }
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
