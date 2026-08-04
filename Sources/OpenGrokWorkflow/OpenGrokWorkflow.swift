import Foundation
import OpenGrokShared
import OpenGrokToolTypes

public let maxWorkflowNameLength = 64
public let maxWorkflowDescriptionLength = 1_024
public let maxWorkflowWhenToUseLength = 2_048
public let maxWorkflowPhases = 64
public let maxWorkflowPhaseTitleLength = 128
public let maxWorkflowPhaseDetailLength = 1_024
public let maxWorkflowParallel = 1_024
public let defaultWorkflowAgentBudget: UInt64 = 128
public let maxWorkflowAgentBudget: UInt64 = 1_024
public let maxWorkflowHostCalls: UInt64 = 10_000
public let maxWorkflowJournalBytes: UInt64 = 64 * 1024 * 1024

public struct WorkflowPhaseMetadata: Codable, Sendable, Hashable {
    public var title: String
    public var detail: String?

    public init(title: String, detail: String? = nil) {
        self.title = title
        self.detail = detail
    }
}

public struct WorkflowMetadata: Codable, Sendable, Hashable {
    public var name: String
    public var description: String
    public var whenToUse: String?
    public var phases: [WorkflowPhaseMetadata]

    private enum CodingKeys: String, CodingKey {
        case name
        case description
        case whenToUse = "when_to_use"
        case phases
    }

    public init(
        name: String,
        description: String,
        whenToUse: String? = nil,
        phases: [WorkflowPhaseMetadata] = []
    ) {
        self.name = name
        self.description = description
        self.whenToUse = whenToUse
        self.phases = phases
    }
}

public enum WorkflowMetadataError: Error, Sendable, Hashable, CustomStringConvertible {
    case metadataNotFirst
    case invalidShape(String)
    case missingField(String)
    case invalidName
    case stringTooLong(field: String, maximum: Int, actual: Int)
    case tooManyPhases(Int)
    case duplicatePhaseTitle(String)
    case parse(String)

    public var description: String {
        switch self {
        case .metadataNotFirst:
            return "first statement must be let meta = #{ ... };"
        case .invalidShape(let value):
            return "workflow metadata has an invalid shape: \(value)"
        case .missingField(let field):
            return "\(field) must be a non-empty string"
        case .invalidName:
            return "meta.name must be lowercase ASCII letters or digits separated by single hyphens"
        case .stringTooLong(let field, let maximum, let actual):
            return "\(field) must be at most \(maximum) UTF-8 bytes (got \(actual))"
        case .tooManyPhases(let count):
            return "meta.phases must contain at most \(maxWorkflowPhases) entries (got \(count))"
        case .duplicatePhaseTitle(let title):
            return "duplicate meta.phases[].title: \"\(title)\""
        case .parse(let value):
            return "script failed to parse: \(value)"
        }
    }
}

public func extractWorkflowMetadata(from script: String) throws -> WorkflowMetadata {
    guard let object = firstMetadataObject(in: script) else {
        throw WorkflowMetadataError.metadataNotFirst
    }
    let map: [String: JSONValue]
    do {
        map = try RhaiValueParser.parseMap(object)
    } catch {
        throw WorkflowMetadataError.parse(String(describing: error))
    }
    let allowed = Set(["name", "description", "when_to_use", "phases"])
    if let unknown = map.keys.first(where: { !allowed.contains($0) }) {
        throw WorkflowMetadataError.invalidShape("unknown field \(unknown)")
    }
    guard let name = map["name"]?.stringValue, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw WorkflowMetadataError.missingField("meta.name")
    }
    guard name.utf8.count <= maxWorkflowNameLength else {
        throw WorkflowMetadataError.stringTooLong(field: "meta.name", maximum: maxWorkflowNameLength, actual: name.utf8.count)
    }
    guard isValidWorkflowName(name) else { throw WorkflowMetadataError.invalidName }
    guard let description = map["description"]?.stringValue, !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw WorkflowMetadataError.missingField("meta.description")
    }
    guard description.utf8.count <= maxWorkflowDescriptionLength else {
        throw WorkflowMetadataError.stringTooLong(field: "meta.description", maximum: maxWorkflowDescriptionLength, actual: description.utf8.count)
    }
    let whenToUse = map["when_to_use"]?.stringValue
    if let whenToUse, whenToUse.utf8.count > maxWorkflowWhenToUseLength {
        throw WorkflowMetadataError.stringTooLong(field: "meta.when_to_use", maximum: maxWorkflowWhenToUseLength, actual: whenToUse.utf8.count)
    }
    var phases: [WorkflowPhaseMetadata] = []
    var titles = Set<String>()
    if let phaseValue = map["phases"] {
        guard let phaseValues = phaseValue.arrayValue else {
            throw WorkflowMetadataError.invalidShape("meta.phases must be an array")
        }
        guard phaseValues.count <= maxWorkflowPhases else {
            throw WorkflowMetadataError.tooManyPhases(phaseValues.count)
        }
        for value in phaseValues {
            guard let phase = value.objectValue else {
                throw WorkflowMetadataError.invalidShape("meta.phases entries must be maps")
            }
            let phaseKeys = Set(phase.keys)
            guard phaseKeys.isSubset(of: ["title", "detail"]) else {
                throw WorkflowMetadataError.invalidShape("unknown phase field")
            }
            guard let title = phase["title"]?.stringValue, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw WorkflowMetadataError.missingField("meta.phases[].title")
            }
            guard titles.insert(title).inserted else {
                throw WorkflowMetadataError.duplicatePhaseTitle(title)
            }
            guard title.utf8.count <= maxWorkflowPhaseTitleLength else {
                throw WorkflowMetadataError.stringTooLong(field: "meta.phases[].title", maximum: maxWorkflowPhaseTitleLength, actual: title.utf8.count)
            }
            let detail = phase["detail"]?.stringValue
            if let detail, detail.utf8.count > maxWorkflowPhaseDetailLength {
                throw WorkflowMetadataError.stringTooLong(field: "meta.phases[].detail", maximum: maxWorkflowPhaseDetailLength, actual: detail.utf8.count)
            }
            phases.append(WorkflowPhaseMetadata(title: title, detail: detail))
        }
    }
    return WorkflowMetadata(name: name, description: description, whenToUse: whenToUse, phases: phases)
}

public struct WorkflowAgentResult: Codable, Sendable, Hashable {
    public var agentID: String
    public var success: Bool
    public var output: JSONValue
    public var cancelled: Bool
    public var tokensUsed: UInt64
    public var durationMS: UInt64

    private enum CodingKeys: String, CodingKey {
        case agentID = "agent_id"
        case success
        case output
        case cancelled
        case tokensUsed = "tokens_used"
        case durationMS = "duration_ms"
    }

    public init(
        agentID: String,
        success: Bool,
        output: JSONValue,
        cancelled: Bool = false,
        tokensUsed: UInt64 = 0,
        durationMS: UInt64 = 0
    ) {
        self.agentID = agentID
        self.success = success
        self.output = output
        self.cancelled = cancelled
        self.tokensUsed = tokensUsed
        self.durationMS = durationMS
    }
}

public struct WorkflowBudgetState: Codable, Sendable, Hashable {
    public var total: UInt64?
    public var spent: UInt64
    public var reserved: UInt64
    public var remaining: UInt64?

    public init(total: UInt64?, spent: UInt64, reserved: UInt64, remaining: UInt64?) {
        self.total = total
        self.spent = spent
        self.reserved = reserved
        self.remaining = remaining
    }
}

public enum WorkflowHostError: Error, Sendable, Hashable, CustomStringConvertible {
    case agentCallQuotaExceeded(requested: UInt64, maximum: UInt64)
    case budgetExceeded
    case cancelled
    case unsupported(String)
    case failed(String)

    public var description: String {
        switch self {
        case .agentCallQuotaExceeded(let requested, let maximum):
            return "workflow agent-call quota exceeded: requested \(requested), maximum \(maximum)"
        case .budgetExceeded:
            return "workflow token budget exceeded"
        case .cancelled:
            return "workflow cancelled"
        case .unsupported(let value):
            return "unsupported in this context: \(value)"
        case .failed(let value):
            return "host failure: \(value)"
        }
    }
}

public enum WorkflowHostRequest: Sendable, Hashable {
    case reserveAgentCalls(count: UInt64)
    case releaseAgentCalls(count: UInt64)
    case spawnAgent(options: WorkflowAgentOptions)
    case phase(title: String, replayed: Bool)
    case log(message: String, replayed: Bool)
    case telemetry(name: String, fields: JSONValue, replayed: Bool)
    case budgetQuery
    case renderTemplate(name: String, variables: JSONValue)
    case writeScratchFile(name: String, content: String)
    case readScratchFile(name: String)
    case gitDiffSince(commit: String)

    public var kind: String {
        switch self {
        case .reserveAgentCalls: return "reserve_agent_calls"
        case .releaseAgentCalls: return "release_agent_calls"
        case .spawnAgent: return "spawn_agent"
        case .phase: return "phase"
        case .log: return "log"
        case .telemetry: return "telemetry"
        case .budgetQuery: return "budget"
        case .renderTemplate: return "render_template"
        case .writeScratchFile: return "write_scratch_file"
        case .readScratchFile: return "read_scratch_file"
        case .gitDiffSince: return "git_diff_since"
        }
    }

    public var payload: JSONValue {
        switch self {
        case .reserveAgentCalls(let count), .releaseAgentCalls(let count):
            return .object(["count": .number(.uint64(count))])
        case .spawnAgent(let options):
            return (try? JSONValue.encode(options)) ?? .object([:])
        case .phase(let title, _):
            return .object(["title": .string(title)])
        case .log(let message, _):
            return .object(["message": .string(message)])
        case .telemetry(let name, let fields, _):
            return .object(["name": .string(name), "fields": fields])
        case .budgetQuery:
            return .object([:])
        case .renderTemplate(let name, let variables):
            return .object(["name": .string(name), "vars": variables])
        case .writeScratchFile(let name, let content):
            return .object(["name": .string(name), "content": .string(content)])
        case .readScratchFile(let name):
            return .object(["name": .string(name)])
        case .gitDiffSince(let commit):
            return .object(["commit": .string(commit)])
        }
    }
}

public enum WorkflowHostResponse: Sendable, Hashable {
    case none
    case agent(WorkflowAgentResult)
    case budget(WorkflowBudgetState)
    case text(String)
    case path(String)

    fileprivate var jsonValue: JSONValue {
        switch self {
        case .none:
            return .object(["kind": .string("none")])
        case .agent(let result):
            return .object(["kind": .string("agent"), "value": (try? JSONValue.encode(result)) ?? .null])
        case .budget(let state):
            return .object(["kind": .string("budget"), "value": (try? JSONValue.encode(state)) ?? .null])
        case .text(let value):
            return .object(["kind": .string("text"), "value": .string(value)])
        case .path(let value):
            return .object(["kind": .string("path"), "value": .string(value)])
        }
    }

    fileprivate static func from(jsonValue: JSONValue) throws -> WorkflowHostResponse {
        guard let kind = jsonValue["kind"]?.stringValue else {
            throw WorkflowHostError.failed("journal response has no kind")
        }
        switch kind {
        case "none": return .none
        case "agent":
            guard let value = jsonValue["value"] else { throw WorkflowHostError.failed("journal agent response is missing value") }
            return .agent(try value.decode(WorkflowAgentResult.self))
        case "budget":
            guard let value = jsonValue["value"] else { throw WorkflowHostError.failed("journal budget response is missing value") }
            return .budget(try value.decode(WorkflowBudgetState.self))
        case "text": return .text(jsonValue["value"]?.stringValue ?? "")
        case "path": return .path(jsonValue["value"]?.stringValue ?? "")
        default: throw WorkflowHostError.failed("unknown journal response kind \(kind)")
        }
    }
}

public protocol WorkflowHost: Sendable {
    func handle(_ request: WorkflowHostRequest) async throws -> WorkflowHostResponse
}

public actor InMemoryWorkflowHost: WorkflowHost {
    public typealias AgentHandler = @Sendable (WorkflowAgentOptions) -> WorkflowAgentResult

    private var agentHandler: AgentHandler
    private var nextAgentID = 0
    private var spent: UInt64 = 0
    private var reserved: UInt64 = 0
    private let total: UInt64?

    public init(total: UInt64? = nil, agentHandler: @escaping AgentHandler = { options in
        WorkflowAgentResult(
            agentID: "stub",
            success: true,
            output: .object(["prompt": .string(options.prompt)])
        )
    }) {
        self.total = total
        self.agentHandler = agentHandler
    }

    public func handle(_ request: WorkflowHostRequest) async throws -> WorkflowHostResponse {
        switch request {
        case .reserveAgentCalls(let count):
            let requested = reserved.saturatingAdd(count)
            if let total, requested.saturatingAdd(spent) > total {
                throw WorkflowHostError.agentCallQuotaExceeded(requested: requested, maximum: total)
            }
            reserved = requested
            return .none
        case .releaseAgentCalls(let count):
            reserved = reserved >= count ? reserved - count : 0
            return .none
        case .spawnAgent(let options):
            if let total, spent.saturatingAdd(1) > total {
                throw WorkflowHostError.agentCallQuotaExceeded(requested: spent.saturatingAdd(1), maximum: total)
            }
            spent = spent.saturatingAdd(1)
            nextAgentID = nextAgentID == Int.max ? Int.max : nextAgentID + 1
            let result = agentHandler(options)
            if result.agentID == "stub" {
                return .agent(WorkflowAgentResult(
                    agentID: "agent-\(nextAgentID)",
                    success: result.success,
                    output: result.output,
                    cancelled: result.cancelled,
                    tokensUsed: result.tokensUsed,
                    durationMS: result.durationMS
                ))
            }
            return .agent(result)
        case .phase, .log, .telemetry:
            return .none
        case .budgetQuery:
            return .budget(WorkflowBudgetState(
                total: total,
                spent: spent,
                reserved: reserved,
                remaining: total.map { $0 > spent + reserved ? $0 - spent - reserved : 0 }
            ))
        case .renderTemplate(let name, _):
            return .text(name)
        case .writeScratchFile(let name, _):
            return .path("scratch/\(name)")
        case .readScratchFile:
            return .text("")
        case .gitDiffSince:
            return .text("")
        }
    }
}

public enum WorkflowPauseKind: String, Codable, Sendable, Hashable {
    case user
    case agent
    case unknown
}

public enum WorkflowOutcome: Codable, Sendable, Hashable {
    case completed(result: JSONValue)
    case paused(kind: WorkflowPauseKind, message: String)
    case budgetExceeded(message: String)
    case cancelled
    case failed(error: String)

    private enum CodingKeys: String, CodingKey { case kind, result, pauseKind = "pause_kind", message, error }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .completed(let result):
            try container.encode("completed", forKey: .kind)
            try container.encode(result, forKey: .result)
        case .paused(let kind, let message):
            try container.encode("paused", forKey: .kind)
            try container.encode(kind, forKey: .pauseKind)
            try container.encode(message, forKey: .message)
        case .budgetExceeded(let message):
            try container.encode("budget_exceeded", forKey: .kind)
            try container.encode(message, forKey: .message)
        case .cancelled:
            try container.encode("cancelled", forKey: .kind)
        case .failed(let error):
            try container.encode("failed", forKey: .kind)
            try container.encode(error, forKey: .error)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "completed": self = .completed(result: try container.decode(JSONValue.self, forKey: .result))
        case "paused": self = .paused(kind: try container.decode(WorkflowPauseKind.self, forKey: .pauseKind), message: try container.decode(String.self, forKey: .message))
        case "budget_exceeded": self = .budgetExceeded(message: try container.decode(String.self, forKey: .message))
        case "cancelled": self = .cancelled
        case "failed": self = .failed(error: try container.decode(String.self, forKey: .error))
        default: throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "unknown workflow outcome")
        }
    }

    public var status: String {
        switch self {
        case .completed: return "completed"
        case .paused: return "paused"
        case .budgetExceeded: return "budget_exceeded"
        case .cancelled: return "cancelled"
        case .failed: return "failed"
        }
    }

    public var isResumable: Bool {
        switch self {
        case .paused, .budgetExceeded: return true
        default: return false
        }
    }
}

public enum WorkflowCancellationState: Sendable, Hashable {
    case running
    case pause(String)
    case cancel
}

public final class WorkflowCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var state: WorkflowCancellationState = .running

    public init() {}

    public func requestPause(message: String) {
        lock.lock()
        state = .pause(message)
        lock.unlock()
    }

    public func cancel() {
        lock.lock()
        state = .cancel
        lock.unlock()
    }

    public var currentState: WorkflowCancellationState {
        lock.lock()
        let value = state
        lock.unlock()
        return value
    }
}

public struct WorkflowJournalEntry: Codable, Sendable, Hashable {
    public var sequence: UInt64
    public var kind: String
    public var requestHash: String
    public var result: JSONValue
    public var atMS: UInt64

    private enum CodingKeys: String, CodingKey {
        case sequence = "seq"
        case kind
        case requestHash = "req_hash"
        case result
        case atMS = "at_ms"
    }

    public init(sequence: UInt64, kind: String, requestHash: String, result: JSONValue, atMS: UInt64) {
        self.sequence = sequence
        self.kind = kind
        self.requestHash = requestHash
        self.result = result
        self.atMS = atMS
    }
}

public enum WorkflowJournalError: Error, Sendable, Hashable, CustomStringConvertible {
    case parse(line: Int, error: String)
    case unsafeRestore(String)
    case full
    case sequence(expected: UInt64, actual: UInt64)
    case divergence(sequence: UInt64, kind: String)

    public var description: String {
        switch self {
        case .parse(let line, let error): return "journal parse at line \(line): \(error)"
        case .unsafeRestore(let reason): return "journal restore rejected: \(reason)"
        case .full: return "workflow journal is full"
        case .sequence(let expected, let actual): return "journal is not dense: expected \(expected), found \(actual)"
        case .divergence(let sequence, let kind): return "replay divergence at seq \(sequence) (\(kind))"
        }
    }
}

public final class WorkflowJournal: @unchecked Sendable {
    public static let maxEntries = Int(maxWorkflowHostCalls)

    private let lock = NSLock()
    private var entries: [WorkflowJournalEntry]
    private let path: URL?
    private var replayCursor: Int = 0

    public init(path: URL? = nil, entries: [WorkflowJournalEntry] = []) throws {
        self.path = path
        self.entries = []
        for entry in entries {
            guard entry.sequence == UInt64(self.entries.count) else {
                throw WorkflowJournalError.sequence(expected: UInt64(self.entries.count), actual: entry.sequence)
            }
            self.entries.append(entry)
        }
    }

    public static func load(path: URL) throws -> WorkflowJournal {
        guard FileManager.default.fileExists(atPath: path.path) else {
            return try WorkflowJournal(path: path)
        }
        let data = try Data(contentsOf: path)
        guard UInt64(data.count) <= maxWorkflowJournalBytes else {
            throw WorkflowJournalError.unsafeRestore("journal exceeds the 64 MiB limit")
        }
        let bytes = Array(data)
        var offset = 0
        var lineNumber = 0
        var entries: [WorkflowJournalEntry] = []
        while offset < bytes.count {
            lineNumber += 1
            let lineStart = offset
            guard let newline = bytes[offset...].firstIndex(of: 10) else {
                let tail = Array(bytes[offset...])
                if tail.allSatisfy({ $0 == 9 || $0 == 10 || $0 == 13 || $0 == 32 }) {
                    try truncate(path: path, length: lineStart)
                    break
                }
                do {
                    let entry = try JSONDecoder().decode(WorkflowJournalEntry.self, from: Data(tail))
                    try validateLoaded(entry, expected: entries.count)
                    entries.append(entry)
                    try appendNewline(path: path)
                } catch {
                    try truncate(path: path, length: lineStart)
                }
                break
            }
            let line = Array(bytes[lineStart..<newline])
            offset = newline + 1
            if line.allSatisfy({ $0 == 9 || $0 == 13 || $0 == 32 }) { continue }
            do {
                let entry = try JSONDecoder().decode(WorkflowJournalEntry.self, from: Data(line))
                try validateLoaded(entry, expected: entries.count)
                entries.append(entry)
            } catch let error as WorkflowJournalError {
                throw error
            } catch {
                throw WorkflowJournalError.parse(line: lineNumber, error: String(describing: error))
            }
        }
        return try WorkflowJournal(path: path, entries: entries)
    }

    public var count: Int {
        lock.lock()
        let value = entries.count
        lock.unlock()
        return value
    }

    public var snapshot: [WorkflowJournalEntry] {
        lock.lock()
        let value = entries
        lock.unlock()
        return value
    }

    public func resetReplayCursor() {
        lock.lock()
        replayCursor = 0
        lock.unlock()
    }

    public func replayOrRecord(
        kind: String,
        payload: JSONValue,
        operation: () async throws -> JSONValue
    ) async throws -> JSONValue {
        let hash = WorkflowHash.sha256Hex(kind: kind, payload: payload)
        let reservation = try reserveReplayEntry(kind: kind, requestHash: hash)
        if let result = reservation.result {
            return result
        }
        let result = try await operation()
        try record(
            result: result,
            sequence: reservation.sequence,
            kind: kind,
            requestHash: hash
        )
        return result
    }

    private func reserveReplayEntry(
        kind: String,
        requestHash: String
    ) throws -> (sequence: UInt64, result: JSONValue?) {
        lock.lock()
        defer { lock.unlock() }
        let sequence: UInt64
        if replayCursor < entries.count {
            sequence = UInt64(replayCursor)
            replayCursor += 1
        } else {
            sequence = UInt64(entries.count)
        }
        if let entry = entries.first(where: { $0.sequence == sequence }) {
            guard entry.kind == kind, entry.requestHash == requestHash else {
                throw WorkflowJournalError.divergence(sequence: sequence, kind: kind)
            }
            return (sequence, entry.result)
        }
        return (sequence, nil)
    }

    private func record(
        result: JSONValue,
        sequence: UInt64,
        kind: String,
        requestHash: String
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard entries.count < Self.maxEntries else { throw WorkflowJournalError.full }
        guard entries.count == Int(sequence) else {
            throw WorkflowJournalError.divergence(sequence: sequence, kind: kind)
        }
        let entry = WorkflowJournalEntry(
            sequence: sequence,
            kind: kind,
            requestHash: requestHash,
            result: result,
            atMS: UInt64(Date().timeIntervalSince1970 * 1_000)
        )
        try append(entry)
        entries.append(entry)
        replayCursor = entries.count
    }

    private func append(_ entry: WorkflowJournalEntry) throws {
        guard let path else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(entry)
        data.append(10)
        let attributes = try? FileManager.default.attributesOfItem(atPath: path.path)
        let currentSize = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        guard currentSize.saturatingAdd(UInt64(data.count)) <= maxWorkflowJournalBytes else {
            throw WorkflowJournalError.full
        }
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: path.path) {
            FileManager.default.createFile(atPath: path.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: path)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private static func validateLoaded(_ entry: WorkflowJournalEntry, expected: Int) throws {
        guard entry.sequence == UInt64(expected) else {
            throw WorkflowJournalError.sequence(expected: UInt64(expected), actual: entry.sequence)
        }
    }

    private static func truncate(path: URL, length: Int) throws {
        let data = try Data(contentsOf: path)
        try Data(data.prefix(length)).write(to: path, options: .atomic)
    }

    private static func appendNewline(path: URL) throws {
        let handle = try FileHandle(forWritingTo: path)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([10]))
    }
}

public struct WorkflowRunParameters: Sendable {
    public var script: String
    public var arguments: JSONValue
    public var agentBudget: UInt64
    public var journal: WorkflowJournal
    public var host: any WorkflowHost
    public var cancellation: WorkflowCancellation
    public var resuming: Bool

    public init(
        script: String,
        arguments: JSONValue = .object([:]),
        agentBudget: UInt64 = defaultWorkflowAgentBudget,
        journal: WorkflowJournal,
        host: any WorkflowHost,
        cancellation: WorkflowCancellation = WorkflowCancellation(),
        resuming: Bool = false
    ) {
        self.script = script
        self.arguments = arguments
        self.agentBudget = agentBudget
        self.journal = journal
        self.host = host
        self.cancellation = cancellation
        self.resuming = resuming
    }
}

public enum WorkflowEngine {
    public static func run(_ parameters: WorkflowRunParameters) async -> WorkflowOutcome {
        do {
            _ = try extractWorkflowMetadata(from: parameters.script)
            try validateScript(parameters.script, agentBudget: parameters.agentBudget)
            return try await execute(parameters)
        } catch let error as WorkflowHostError {
            switch error {
            case .agentCallQuotaExceeded, .budgetExceeded:
                return .budgetExceeded(message: error.description)
            case .cancelled:
                return .cancelled
            default:
                return .failed(error: error.description)
            }
        } catch let error as WorkflowJournalError {
            return .failed(error: error.description)
        } catch let error as WorkflowMetadataError {
            return .failed(error: error.description)
        } catch {
            return .failed(error: String(describing: error))
        }
    }

    private static func execute(_ parameters: WorkflowRunParameters) async throws -> WorkflowOutcome {
        if parameters.resuming { parameters.journal.resetReplayCursor() }
        var environment: [String: JSONValue] = ["args": parameters.arguments]
        var agentCalls: UInt64 = 0
        let body = workflowBody(after: parameters.script)
        for statement in splitStatements(body) {
            switch parameters.cancellation.currentState {
            case .cancel:
                return .cancelled
            case .pause(let message):
                return .paused(kind: .user, message: message)
            case .running:
                break
            }
            guard !Task.isCancelled else { return .cancelled }
            if statement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            if let assignment = splitAssignment(statement) {
                let expressionResult = try await executeExpression(
                    assignment.expression,
                    parameters: parameters,
                    environment: &environment,
                    agentCalls: &agentCalls
                )
                switch expressionResult {
                case .value(let value):
                    environment[assignment.name] = value
                case .complete(let result):
                    return .completed(result: result)
                case .pause(let kind, let message):
                    if parameters.resuming { continue }
                    return .paused(kind: kind, message: message)
                case .cancel:
                    return .cancelled
                }
                continue
            }
            let signal = try await executeExpression(
                statement,
                parameters: parameters,
                environment: &environment,
                agentCalls: &agentCalls
            )
            switch signal {
            case .value:
                continue
            case .complete(let result):
                return .completed(result: result)
            case .pause(let kind, let message):
                if parameters.resuming { continue }
                return .paused(kind: kind, message: message)
            case .cancel:
                return .cancelled
            }
        }
        return .completed(result: .null)
    }

    private enum ExpressionResult {
        case value(JSONValue)
        case complete(JSONValue)
        case pause(WorkflowPauseKind, String)
        case cancel
    }

    private static func executeExpression(
        _ expression: String,
        parameters: WorkflowRunParameters,
        environment: inout [String: JSONValue],
        agentCalls: inout UInt64
    ) async throws -> ExpressionResult {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let call = parseCall(trimmed) else {
            return .value(try evaluateValue(trimmed, environment: environment))
        }
        switch call.name {
        case "agent":
            let result = try await runAgent(
                options: parseAgentOptions(call.arguments),
                parameters: parameters,
                agentCalls: &agentCalls
            )
            return .value(result)
        case "parallel":
            let nested = parseNestedCalls(call.arguments, named: "agent")
            guard nested.count <= maxWorkflowParallel else {
                return .value(.null)
            }
            var results: [JSONValue] = []
            for nestedCall in nested {
                let result = try await runAgent(
                    options: parseAgentOptions(nestedCall.arguments),
                    parameters: parameters,
                    agentCalls: &agentCalls
                )
                results.append(result)
            }
            return .value(.array(results))
        case "phase":
            let title = try evaluateValue(firstArgument(call.arguments), environment: environment).stringValue ?? ""
            _ = try await hostCall(.phase(title: title, replayed: false), parameters: parameters)
            return .value(.null)
        case "log":
            let message = try evaluateValue(firstArgument(call.arguments), environment: environment).stringValue ?? ""
            _ = try await hostCall(.log(message: message, replayed: false), parameters: parameters)
            return .value(.null)
        case "telemetry":
            let name = try evaluateValue(firstArgument(call.arguments), environment: environment).stringValue ?? ""
            _ = try await hostCall(.telemetry(name: name, fields: .object([:]), replayed: false), parameters: parameters)
            return .value(.null)
        case "budget":
            let response = try await hostCall(.budgetQuery, parameters: parameters)
            if case .budget(let state) = response {
                return .value((try? JSONValue.encode(state)) ?? .null)
            }
            return .value(.null)
        case "render_template":
            let name = try evaluateValue(firstArgument(call.arguments), environment: environment).stringValue ?? ""
            let response = try await hostCall(.renderTemplate(name: name, variables: .object([:])), parameters: parameters)
            if case .text(let value) = response { return .value(.string(value)) }
            return .value(.null)
        case "write_scratch_file":
            let name = try evaluateValue(firstArgument(call.arguments), environment: environment).stringValue ?? ""
            let response = try await hostCall(.writeScratchFile(name: name, content: ""), parameters: parameters)
            if case .path(let value) = response { return .value(.string(value)) }
            return .value(.null)
        case "read_scratch_file":
            let name = try evaluateValue(firstArgument(call.arguments), environment: environment).stringValue ?? ""
            let response = try await hostCall(.readScratchFile(name: name), parameters: parameters)
            if case .text(let value) = response { return .value(.string(value)) }
            return .value(.null)
        case "git_diff_since":
            let commit = try evaluateValue(firstArgument(call.arguments), environment: environment).stringValue ?? ""
            let response = try await hostCall(.gitDiffSince(commit: commit), parameters: parameters)
            if case .text(let value) = response { return .value(.string(value)) }
            return .value(.null)
        case "pause":
            let values = splitTopLevel(call.arguments, separator: ",")
            let kind = values.first.flatMap { try? evaluateValue($0, environment: environment).stringValue }.flatMap(WorkflowPauseKind.init(rawValue:)) ?? .user
            let message = values.dropFirst().first.flatMap { try? evaluateValue($0, environment: environment).stringValue } ?? "workflow paused"
            return .pause(kind, message)
        case "complete":
            return .complete(try evaluateValue(call.arguments, environment: environment))
        case "cancel":
            return .cancel
        default:
            throw WorkflowHostError.unsupported("unknown workflow host call \(call.name)")
        }
    }

    private static func runAgent(
        options: WorkflowAgentOptions,
        parameters: WorkflowRunParameters,
        agentCalls: inout UInt64
    ) async throws -> JSONValue {
        guard agentCalls < parameters.agentBudget else {
            throw WorkflowHostError.agentCallQuotaExceeded(requested: agentCalls.saturatingAdd(1), maximum: parameters.agentBudget)
        }
        agentCalls = agentCalls.saturatingAdd(1)
        _ = try await hostCall(.reserveAgentCalls(count: 1), parameters: parameters)
        do {
            let response = try await hostCall(.spawnAgent(options: options), parameters: parameters)
            _ = try? await hostCall(.releaseAgentCalls(count: 1), parameters: parameters)
            guard case .agent(let result) = response else {
                throw WorkflowHostError.failed("spawn_agent returned no agent result")
            }
            if let schema = options.outputSchema {
                try validateJSONSchema(schema, value: result.output)
            }
            return (try? JSONValue.encode(result)) ?? .null
        } catch {
            _ = try? await hostCall(.releaseAgentCalls(count: 1), parameters: parameters)
            throw error
        }
    }

    private static func hostCall(
        _ request: WorkflowHostRequest,
        parameters: WorkflowRunParameters
    ) async throws -> WorkflowHostResponse {
        let value = try await parameters.journal.replayOrRecord(kind: request.kind, payload: request.payload) {
            let response = try await parameters.host.handle(request)
            return response.jsonValue
        }
        return try WorkflowHostResponse.from(jsonValue: value)
    }

    private static func validateScript(_ script: String, agentBudget: UInt64) throws {
        guard agentBudget >= 1, agentBudget <= maxWorkflowAgentBudget else {
            throw WorkflowHostError.agentCallQuotaExceeded(requested: agentBudget, maximum: maxWorkflowAgentBudget)
        }
        let forbidden = ["eval(", "sleep(", "timestamp(", "now(", "random(", "exit(", "import ", "spawn("]
        if let token = forbidden.first(where: { script.localizedCaseInsensitiveContains($0) }) {
            throw WorkflowHostError.unsupported("nondeterministic or unrestricted operation \(token)")
        }
        let statements = splitStatements(workflowBody(after: script))
        guard UInt64(statements.count) <= maxWorkflowHostCalls else {
            throw WorkflowJournalError.full
        }
        let agentCount = occurrences(of: "agent(", in: script)
        guard UInt64(agentCount) <= maxWorkflowAgentBudget else {
            throw WorkflowHostError.agentCallQuotaExceeded(requested: UInt64(agentCount), maximum: maxWorkflowAgentBudget)
        }
        let parallelCount = occurrences(of: "parallel(", in: script)
        guard parallelCount == 0 || agentCount <= maxWorkflowParallel else {
            throw WorkflowHostError.unsupported("parallel agent count exceeds the limit")
        }
    }
}

public actor WorkflowRun {
    public let runID: String
    public let script: String
    public let arguments: JSONValue
    public let journal: WorkflowJournal

    private var started = false
    private var outcome: WorkflowOutcome?

    public init(runID: String = UUID().uuidString, script: String, arguments: JSONValue, journal: WorkflowJournal) {
        self.runID = runID
        self.script = script
        self.arguments = arguments
        self.journal = journal
    }

    public func start(
        agentBudget: UInt64,
        host: any WorkflowHost,
        cancellation: WorkflowCancellation = WorkflowCancellation()
    ) async -> WorkflowOutcome {
        guard !started else { return .failed(error: "workflow run has already started") }
        started = true
        let result = await WorkflowEngine.run(WorkflowRunParameters(
            script: script,
            arguments: arguments,
            agentBudget: agentBudget,
            journal: journal,
            host: host,
            cancellation: cancellation
        ))
        outcome = result
        return result
    }

    public func resume(
        script: String,
        arguments: JSONValue,
        agentBudget: UInt64,
        host: any WorkflowHost,
        cancellation: WorkflowCancellation = WorkflowCancellation()
    ) async -> WorkflowOutcome {
        guard self.script == script, self.arguments == arguments else {
            return .failed(error: "workflow resume requires the same immutable script and arguments")
        }
        guard let previous = outcome, previous.isResumable else {
            return .failed(error: "workflow run is not resumable")
        }
        let result = await WorkflowEngine.run(WorkflowRunParameters(
            script: self.script,
            arguments: self.arguments,
            agentBudget: agentBudget,
            journal: journal,
            host: host,
            cancellation: cancellation,
            resuming: true
        ))
        outcome = result
        return result
    }

    public func lastOutcome() -> WorkflowOutcome? { outcome }
}

private struct ParsedCall {
    var name: String
    var arguments: String
}

private enum RhaiValueParser {
    static func parseMap(_ value: String) throws -> [String: JSONValue] {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("#{"), trimmed.hasSuffix("}") else { throw WorkflowMetadataError.invalidShape(value) }
        let body = String(trimmed.dropFirst(2).dropLast())
        var result: [String: JSONValue] = [:]
        for part in splitTopLevel(body, separator: ",") where !part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let colon = topLevelIndex(of: ":", in: part) else { throw WorkflowMetadataError.invalidShape(part) }
            let rawKey = String(part[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines)
            let key = rawKey.hasPrefix("\"") ? (try parseString(rawKey)) : rawKey
            result[key] = try parseValue(String(part[part.index(after: colon)...]))
        }
        return result
    }

    static func parseValue(_ value: String) throws -> JSONValue {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("#{") { return .object(try parseMap(trimmed)) }
        if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
            let body = String(trimmed.dropFirst().dropLast())
            return .array(try splitTopLevel(body, separator: ",").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map { try parseValue($0) })
        }
        if trimmed.hasPrefix("\"") { return .string(try parseString(trimmed)) }
        if trimmed == "true" { return .bool(true) }
        if trimmed == "false" { return .bool(false) }
        if trimmed == "null" || trimmed == "()" { return .null }
        if let integer = Int64(trimmed) { return .number(.int64(integer)) }
        if let double = Double(trimmed) { return .number(.double(double)) }
        throw WorkflowMetadataError.invalidShape(trimmed)
    }

    static func parseString(_ value: String) throws -> String {
        let data = Data(value.utf8)
        if let result = try? JSONDecoder().decode(String.self, from: data) { return result }
        if value.hasPrefix("'") && value.hasSuffix("'") { return String(value.dropFirst().dropLast()) }
        throw WorkflowMetadataError.invalidShape(value)
    }
}

private func firstMetadataObject(in script: String) -> String? {
    var remainder = script
    while true {
        remainder = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        if remainder.hasPrefix("//") {
            guard let newline = remainder.firstIndex(of: "\n") else { return nil }
            remainder = String(remainder[remainder.index(after: newline)...])
            continue
        }
        if remainder.hasPrefix("/*"), let end = remainder.range(of: "*/") {
            remainder = String(remainder[end.upperBound...])
            continue
        }
        break
    }
    guard remainder.hasPrefix("let meta") || remainder.hasPrefix("const meta") else { return nil }
    guard let start = remainder.range(of: "#{")?.lowerBound,
          let end = matchingDelimiter(in: String(remainder[start...]), open: "{", close: "}") else { return nil }
    let suffix = String(remainder[start...])
    let objectEnd = suffix.index(suffix.startIndex, offsetBy: end + 1)
    return String(suffix[..<objectEnd])
}

private func workflowBody(after script: String) -> String {
    guard let object = firstMetadataObject(in: script), let range = script.range(of: object) else { return script }
    return String(script[range.upperBound...])
}

private func isValidWorkflowName(_ name: String) -> Bool {
    let bytes = Array(name.utf8)
    guard let first = bytes.first, let last = bytes.last else { return false }
    guard (first >= 97 && first <= 122) || (first >= 48 && first <= 57) else { return false }
    guard (last >= 97 && last <= 122) || (last >= 48 && last <= 57) else { return false }
    guard bytes.allSatisfy({ ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45 }) else { return false }
    return !bytes.indices.dropLast().contains(where: { bytes[$0] == 45 && bytes[$0 + 1] == 45 })
}

private func matchingDelimiter(in value: String, open: Character, close: Character) -> Int? {
    var depth = 0
    var quoted = false
    var escaped = false
    for (index, character) in value.enumerated() {
        if quoted {
            if escaped { escaped = false }
            else if character == "\\" { escaped = true }
            else if character == "\"" { quoted = false }
            continue
        }
        if character == "\"" { quoted = true; continue }
        if character == open { depth += 1 }
        if character == close {
            depth -= 1
            if depth == 0 { return index }
        }
    }
    return nil
}

private func splitTopLevel(_ value: String, separator: Character) -> [String] {
    var result: [String] = []
    var start = value.startIndex
    var depth = 0
    var quoted = false
    var escaped = false
    var index = value.startIndex
    while index < value.endIndex {
        let character = value[index]
        if quoted {
            if escaped { escaped = false }
            else if character == "\\" { escaped = true }
            else if character == "\"" { quoted = false }
        } else if character == "\"" {
            quoted = true
        } else if character == "{" || character == "(" || character == "[" {
            depth += 1
        } else if character == "}" || character == ")" || character == "]" {
            depth -= 1
        } else if character == separator && depth == 0 {
            result.append(String(value[start..<index]))
            start = value.index(after: index)
        }
        index = value.index(after: index)
    }
    result.append(String(value[start...]))
    return result
}

private func topLevelIndex(of character: Character, in value: String) -> String.Index? {
    var depth = 0
    var quoted = false
    var escaped = false
    var index = value.startIndex
    while index < value.endIndex {
        let current = value[index]
        if quoted {
            if escaped { escaped = false }
            else if current == "\\" { escaped = true }
            else if current == "\"" { quoted = false }
        } else if current == "\"" {
            quoted = true
        } else if current == "{" || current == "(" || current == "[" {
            depth += 1
        } else if current == "}" || current == ")" || current == "]" {
            depth -= 1
        } else if current == character && depth == 0 {
            return index
        }
        index = value.index(after: index)
    }
    return nil
}

private func splitStatements(_ value: String) -> [String] {
    splitTopLevel(value, separator: ";")
}

private func parseCall(_ value: String) -> ParsedCall? {
    guard let open = value.firstIndex(of: "("), value.last == ")" else { return nil }
    let name = String(value[..<open]).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return nil }
    return ParsedCall(name: name, arguments: String(value[value.index(after: open)..<value.index(before: value.endIndex)]))
}

private func parseNestedCalls(_ value: String, named name: String) -> [ParsedCall] {
    var calls: [ParsedCall] = []
    var searchStart = value.startIndex
    while searchStart < value.endIndex, let range = value.range(of: "\(name)(", range: searchStart..<value.endIndex) {
        let start = range.lowerBound
        guard let endOffset = matchingDelimiter(in: String(value[start...]), open: "(", close: ")") else { break }
        let suffix = String(value[start...])
        let end = suffix.index(suffix.startIndex, offsetBy: endOffset + 1)
        if let call = parseCall(String(suffix[..<end])) { calls.append(call) }
        searchStart = value.index(start, offsetBy: max(endOffset + 1, 1), limitedBy: value.endIndex) ?? value.endIndex
    }
    return calls
}

private func parseAgentOptions(_ value: String) throws -> WorkflowAgentOptions {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("#{") {
        let map = try RhaiValueParser.parseMap(trimmed)
        guard let prompt = map["prompt"]?.stringValue else {
            throw WorkflowHostError.failed("agent options require prompt")
        }
        return WorkflowAgentOptions(
            prompt: prompt,
            label: map["label"]?.stringValue,
            model: map["model"]?.stringValue,
            reasoningEffort: map["reasoning_effort"]?.stringValue,
            maxOutputTokens: map["max_output_tokens"]?.uint64Value,
            agentType: map["agent_type"]?.stringValue,
            capabilityMode: map["capability_mode"]?.stringValue,
            isolationWorktree: map["isolation_worktree"]?.boolValue ?? false,
            forkContext: map["fork_context"]?.boolValue ?? false,
            resumeFrom: map["resume_from"]?.stringValue,
            outputSchema: map["output_schema"],
            phase: map["phase"]?.stringValue
        )
    }
    guard let prompt = try RhaiValueParser.parseValue(trimmed).stringValue else {
        throw WorkflowHostError.failed("agent prompt must be a string")
    }
    return WorkflowAgentOptions(prompt: prompt)
}

private func evaluateValue(_ value: String, environment: [String: JSONValue]) throws -> JSONValue {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if let direct = try? RhaiValueParser.parseValue(trimmed) { return direct }
    if let exact = environment[trimmed] { return exact }
    let components = trimmed.split(separator: ".").map(String.init)
    if let first = components.first, var current = environment[first] {
        for component in components.dropFirst() {
            guard let next = current[component] else { throw WorkflowHostError.failed("unknown workflow value \(trimmed)") }
            current = next
        }
        return current
    }
    throw WorkflowHostError.failed("unknown workflow value \(trimmed)")
}

private func firstArgument(_ value: String) -> String {
    splitTopLevel(value, separator: ",").first ?? ""
}

private func splitAssignment(_ value: String) -> (name: String, expression: String)? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let withoutKeyword: String
    if trimmed.hasPrefix("let ") { withoutKeyword = String(trimmed.dropFirst(4)) }
    else if trimmed.hasPrefix("const ") { withoutKeyword = String(trimmed.dropFirst(6)) }
    else { return nil }
    guard let index = topLevelIndex(of: "=", in: withoutKeyword) else { return nil }
    let name = String(withoutKeyword[..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return nil }
    return (String(name), String(withoutKeyword[withoutKeyword.index(after: index)...]))
}

private func occurrences(of needle: String, in value: String) -> Int {
    var count = 0
    var start = value.startIndex
    while start < value.endIndex, let range = value.range(of: needle, range: start..<value.endIndex) {
        count += 1
        start = range.upperBound
    }
    return count
}

private func validateJSONSchema(_ schema: JSONValue, value: JSONValue) throws {
    guard let object = schema.objectValue else { return }
    if let type = object["type"]?.stringValue {
        let matches: Bool
        switch type {
        case "object": matches = value.objectValue != nil
        case "array": matches = value.arrayValue != nil
        case "string": matches = value.stringValue != nil
        case "boolean": matches = value.boolValue != nil
        case "number", "integer": matches = value.doubleValue != nil
        case "null": matches = value.isNull
        default: matches = true
        }
        guard matches else { throw WorkflowHostError.failed("agent output does not match output_schema type") }
    }
    if let required = object["required"]?.arrayValue, let output = value.objectValue {
        for requiredName in required.compactMap(\.stringValue) where output[requiredName] == nil {
            throw WorkflowHostError.failed("agent output is missing required field \(requiredName)")
        }
    }
    if let properties = object["properties"]?.objectValue, let output = value.objectValue {
        for (name, propertySchema) in properties {
            if let property = output[name] { try validateJSONSchema(propertySchema, value: property) }
        }
    }
}

private enum WorkflowHash {
    static func sha256Hex(kind: String, payload: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(payload)) ?? Data()
        var input = Data(kind.utf8)
        input.append(0)
        input.append(data)
        return SHA256.hash(input).map { String(format: "%02x", $0) }.joined()
    }
}

private enum SHA256 {
    private static let constants: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    ]

    static func hash(_ data: Data) -> [UInt8] {
        var bytes = Array(data)
        let bitLength = UInt64(bytes.count) * 8
        bytes.append(0x80)
        while bytes.count % 64 != 56 { bytes.append(0) }
        withUnsafeBytes(of: bitLength.bigEndian) { bytes.append(contentsOf: $0) }
        var state: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        for chunkStart in stride(from: 0, to: bytes.count, by: 64) {
            var words = Array(repeating: UInt32(0), count: 64)
            for index in 0..<16 {
                let base = chunkStart + index * 4
                words[index] = UInt32(bytes[base]) << 24 | UInt32(bytes[base + 1]) << 16 | UInt32(bytes[base + 2]) << 8 | UInt32(bytes[base + 3])
            }
            for index in 16..<64 {
                let s0 = words[index - 15].rotateRight(7) ^ words[index - 15].rotateRight(18) ^ (words[index - 15] >> 3)
                let s1 = words[index - 2].rotateRight(17) ^ words[index - 2].rotateRight(19) ^ (words[index - 2] >> 10)
                words[index] = words[index - 16] &+ s0 &+ words[index - 7] &+ s1
            }
            var a = state[0], b = state[1], c = state[2], d = state[3], e = state[4], f = state[5], g = state[6], h = state[7]
            for index in 0..<64 {
                let s1 = e.rotateRight(6) ^ e.rotateRight(11) ^ e.rotateRight(25)
                let choice = (e & f) ^ ((~e) & g)
                let temporary1 = h &+ s1 &+ choice &+ constants[index] &+ words[index]
                let s0 = a.rotateRight(2) ^ a.rotateRight(13) ^ a.rotateRight(22)
                let majority = (a & b) ^ (a & c) ^ (b & c)
                let temporary2 = s0 &+ majority
                h = g; g = f; f = e; e = d &+ temporary1; d = c; c = b; b = a; a = temporary1 &+ temporary2
            }
            state[0] &+= a; state[1] &+= b; state[2] &+= c; state[3] &+= d; state[4] &+= e; state[5] &+= f; state[6] &+= g; state[7] &+= h
        }
        return state.flatMap { word in
            withUnsafeBytes(of: word.bigEndian) { Array($0) }
        }
    }
}

private extension UInt32 {
    func rotateRight(_ amount: UInt32) -> UInt32 { (self >> amount) | (self << (32 - amount)) }
}

private extension UInt64 {
    func saturatingAdd(_ value: UInt64) -> UInt64 { addingReportingOverflow(value).overflow ? UInt64.max : self + value }
}
