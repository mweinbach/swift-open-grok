import Foundation
import OpenGrokFileUtils
import OpenGrokShared
import OpenGrokVersion
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if os(Windows)
import OpenGrokConfig
#elseif canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum ShellSessionSupportError: Error, Sendable, Equatable {
    case invalidSession(String)
    case invalidCommand(String)
    case commandNotOwned
    case commandNotFound(String)
    case commandAlreadyCompleted(String)
    case persistence(String)
    case invalidWireValue(String)
}

public enum OpenGrokHome {
    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let configured = environment["OPENGROK_HOME"], !configured.isEmpty {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        return homeDirectory.appendingPathComponent(".opengrok", isDirectory: true)
    }
}

public enum SessionLifecyclePhase: String, Codable, Sendable, Hashable {
    case idle
    case starting
    case sampling
    case toolExecution = "tool_execution"
    case permissionPrompt = "permission_prompt"
    case interrupted
    case recovering
    case shuttingDown = "shutting_down"
}

public enum SessionCommandOwner: String, Codable, Sendable, Hashable {
    case session
    case client
    case recovery
    case system
    case tool
}

public struct CancellationContext: Codable, Sendable, Hashable {
    public var toolName: String?
    public var reason: String?
    public var hookName: String?
    public var trigger: String?

    public init(
        toolName: String? = nil,
        reason: String? = nil,
        hookName: String? = nil,
        trigger: String? = nil
    ) {
        self.toolName = toolName
        self.reason = reason
        self.hookName = hookName
        self.trigger = trigger
    }

    private enum CodingKeys: String, CodingKey {
        case toolName = "tool_name"
        case reason
        case hookName = "hook_name"
        case trigger
    }
}

public enum PromptCompletionKind: Codable, Sendable, Hashable {
    case completed
    case stationarityEnded
    case cancelled(category: String?, context: CancellationContext?)
    case maxTurnsReached(limit: UInt64)
    case rewound
    case removedFromQueue

    private enum CodingKeys: String, CodingKey {
        case kind
        case category
        case context
        case limit
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "completed": self = .completed
        case "stationarity_ended": self = .stationarityEnded
        case "cancelled":
            self = .cancelled(
                category: try container.decodeIfPresent(String.self, forKey: .category),
                context: try container.decodeIfPresent(CancellationContext.self, forKey: .context)
            )
        case "max_turns_reached":
            self = .maxTurnsReached(limit: try container.decode(UInt64.self, forKey: .limit))
        case "rewound": self = .rewound
        case "removed_from_queue": self = .removedFromQueue
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "unknown prompt completion kind"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .completed:
            try container.encode("completed", forKey: .kind)
        case .stationarityEnded:
            try container.encode("stationarity_ended", forKey: .kind)
        case .cancelled(let category, let context):
            try container.encode("cancelled", forKey: .kind)
            try container.encodeIfPresent(category, forKey: .category)
            try container.encodeIfPresent(context, forKey: .context)
        case .maxTurnsReached(let limit):
            try container.encode("max_turns_reached", forKey: .kind)
            try container.encode(limit, forKey: .limit)
        case .rewound:
            try container.encode("rewound", forKey: .kind)
        case .removedFromQueue:
            try container.encode("removed_from_queue", forKey: .kind)
        }
    }
}

public enum SessionCommandKind: Codable, Sendable, Hashable {
    case initialize(systemPrompt: String)
    case replaceSystemPrompt(systemPrompt: String)
    case prompt(promptID: String, text: String)
    case cancel(context: CancellationContext?, preserveQueuedPrompts: Bool)
    case restorePlanApproval
    case compact(userContext: String?)
    case rewind(targetPromptIndex: UInt64)
    case reloadTools
    case flush
    case shutdown
    case custom(name: String, payload: JSONValue)

    private enum CodingKeys: String, CodingKey {
        case kind
        case systemPrompt = "system_prompt"
        case promptID = "prompt_id"
        case text
        case context
        case preserveQueuedPrompts = "preserve_queued_prompts"
        case userContext = "user_context"
        case targetPromptIndex = "target_prompt_index"
        case name
        case payload
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "initialize": self = .initialize(systemPrompt: try container.decode(String.self, forKey: .systemPrompt))
        case "replace_system_prompt": self = .replaceSystemPrompt(systemPrompt: try container.decode(String.self, forKey: .systemPrompt))
        case "prompt":
            self = .prompt(
                promptID: try container.decode(String.self, forKey: .promptID),
                text: try container.decode(String.self, forKey: .text)
            )
        case "cancel":
            self = .cancel(
                context: try container.decodeIfPresent(CancellationContext.self, forKey: .context),
                preserveQueuedPrompts: try container.decodeIfPresent(Bool.self, forKey: .preserveQueuedPrompts) ?? true
            )
        case "restore_plan_approval": self = .restorePlanApproval
        case "compact": self = .compact(userContext: try container.decodeIfPresent(String.self, forKey: .userContext))
        case "rewind": self = .rewind(targetPromptIndex: try container.decode(UInt64.self, forKey: .targetPromptIndex))
        case "reload_tools": self = .reloadTools
        case "flush": self = .flush
        case "shutdown": self = .shutdown
        case "custom":
            self = .custom(
                name: try container.decode(String.self, forKey: .name),
                payload: try container.decodeIfPresent(JSONValue.self, forKey: .payload) ?? .null
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "unknown session command"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .initialize(let systemPrompt):
            try container.encode("initialize", forKey: .kind)
            try container.encode(systemPrompt, forKey: .systemPrompt)
        case .replaceSystemPrompt(let systemPrompt):
            try container.encode("replace_system_prompt", forKey: .kind)
            try container.encode(systemPrompt, forKey: .systemPrompt)
        case .prompt(let promptID, let text):
            try container.encode("prompt", forKey: .kind)
            try container.encode(promptID, forKey: .promptID)
            try container.encode(text, forKey: .text)
        case .cancel(let context, let preserveQueuedPrompts):
            try container.encode("cancel", forKey: .kind)
            try container.encodeIfPresent(context, forKey: .context)
            try container.encode(preserveQueuedPrompts, forKey: .preserveQueuedPrompts)
        case .restorePlanApproval:
            try container.encode("restore_plan_approval", forKey: .kind)
        case .compact(let userContext):
            try container.encode("compact", forKey: .kind)
            try container.encodeIfPresent(userContext, forKey: .userContext)
        case .rewind(let targetPromptIndex):
            try container.encode("rewind", forKey: .kind)
            try container.encode(targetPromptIndex, forKey: .targetPromptIndex)
        case .reloadTools:
            try container.encode("reload_tools", forKey: .kind)
        case .flush:
            try container.encode("flush", forKey: .kind)
        case .shutdown:
            try container.encode("shutdown", forKey: .kind)
        case .custom(let name, let payload):
            try container.encode("custom", forKey: .kind)
            try container.encode(name, forKey: .name)
            try container.encode(payload, forKey: .payload)
        }
    }
}

public struct SessionCommand: Codable, Sendable, Hashable {
    public let commandID: String
    public let sessionID: SessionID
    public let owner: SessionCommandOwner
    public let sequence: UInt64
    public let issuedAtMS: UInt64
    public let kind: SessionCommandKind

    public init(
        commandID: String,
        sessionID: SessionID,
        owner: SessionCommandOwner,
        sequence: UInt64,
        issuedAtMS: UInt64,
        kind: SessionCommandKind
    ) throws {
        guard !commandID.isEmpty else { throw ShellSessionSupportError.invalidCommand("command id is empty") }
        try validateSessionPathComponent(sessionID.rawValue)
        self.commandID = commandID
        self.sessionID = sessionID
        self.owner = owner
        self.sequence = sequence
        self.issuedAtMS = issuedAtMS
        self.kind = kind
    }
}

public struct SessionCommandMailboxSnapshot: Codable, Sendable, Hashable {
    public let queued: [SessionCommand]
    public let inFlight: SessionCommand?
    public let completedCommandIDs: [String]
    public let cancelledCommandIDs: [String]

    public init(
        queued: [SessionCommand],
        inFlight: SessionCommand?,
        completedCommandIDs: [String],
        cancelledCommandIDs: [String]
    ) {
        self.queued = queued
        self.inFlight = inFlight
        self.completedCommandIDs = completedCommandIDs
        self.cancelledCommandIDs = cancelledCommandIDs
    }
}

public actor SessionCommandMailbox {
    private let sessionID: SessionID
    private let ownerID: String
    private var nextSequence: UInt64 = 0
    private var queued: [SessionCommand] = []
    private var inFlight: SessionCommand?
    private var completedCommandIDs = Set<String>()
    private var cancelledCommandIDs = Set<String>()

    public init(sessionID: SessionID, ownerID: String) throws {
        guard !ownerID.isEmpty else { throw ShellSessionSupportError.invalidCommand("owner id is empty") }
        try validateSessionPathComponent(sessionID.rawValue)
        self.sessionID = sessionID
        self.ownerID = ownerID
    }

    public func enqueue(_ kind: SessionCommandKind, owner: SessionCommandOwner, issuedAtMS: UInt64) throws -> SessionCommand {
        guard nextSequence < UInt64.max else {
            throw ShellSessionSupportError.invalidCommand("command sequence exhausted")
        }
        let commandID = "\(sessionID.rawValue)-\(nextSequence)"
        let command = try SessionCommand(
            commandID: commandID,
            sessionID: sessionID,
            owner: owner,
            sequence: nextSequence,
            issuedAtMS: issuedAtMS,
            kind: kind
        )
        nextSequence += 1
        queued.append(command)
        return command
    }

    public func claimNext(by claimantID: String) throws -> SessionCommand? {
        try requireOwner(claimantID)
        guard inFlight == nil else { return nil }
        guard !queued.isEmpty else { return nil }
        inFlight = queued.removeFirst()
        return inFlight
    }

    public func complete(commandID: String, by claimantID: String) throws {
        try requireOwner(claimantID)
        guard let inFlight, inFlight.commandID == commandID else {
            if completedCommandIDs.contains(commandID) { throw ShellSessionSupportError.commandAlreadyCompleted(commandID) }
            throw ShellSessionSupportError.commandNotFound(commandID)
        }
        self.inFlight = nil
        completedCommandIDs.insert(inFlight.commandID)
    }

    public func cancel(commandID: String, by claimantID: String) throws -> Bool {
        try requireOwner(claimantID)
        if let index = queued.firstIndex(where: { $0.commandID == commandID }) {
            queued.remove(at: index)
            cancelledCommandIDs.insert(commandID)
            return true
        }
        if inFlight?.commandID == commandID {
            inFlight = nil
            cancelledCommandIDs.insert(commandID)
            return true
        }
        return false
    }

    public func snapshot() -> SessionCommandMailboxSnapshot {
        SessionCommandMailboxSnapshot(
            queued: queued,
            inFlight: inFlight,
            completedCommandIDs: completedCommandIDs.sorted(),
            cancelledCommandIDs: cancelledCommandIDs.sorted()
        )
    }

    private func requireOwner(_ claimantID: String) throws {
        guard claimantID == ownerID else { throw ShellSessionSupportError.commandNotOwned }
    }
}

public struct SessionContinuation: Codable, Sendable, Hashable {
    public let continuationID: String
    public let sessionID: SessionID
    public let commandID: String?
    public let issuedAtMS: UInt64

    public init(
        continuationID: String,
        sessionID: SessionID,
        commandID: String? = nil,
        issuedAtMS: UInt64
    ) throws {
        guard !continuationID.isEmpty else {
            throw ShellSessionSupportError.invalidCommand("continuation id is empty")
        }
        try validateSessionPathComponent(sessionID.rawValue)
        if let commandID, commandID.isEmpty {
            throw ShellSessionSupportError.invalidCommand("continuation command id is empty")
        }
        self.continuationID = continuationID
        self.sessionID = sessionID
        self.commandID = commandID
        self.issuedAtMS = issuedAtMS
    }
}

public struct SessionContinuationRegistrySnapshot: Codable, Sendable, Hashable {
    public let pending: [SessionContinuation]
    public let completedContinuationIDs: [String]
    public let cancelledContinuationIDs: [String]

    public init(
        pending: [SessionContinuation],
        completedContinuationIDs: [String],
        cancelledContinuationIDs: [String]
    ) {
        self.pending = pending
        self.completedContinuationIDs = completedContinuationIDs
        self.cancelledContinuationIDs = cancelledContinuationIDs
    }
}

public actor SessionContinuationRegistry {
    private let sessionID: SessionID
    private let ownerID: String
    private var pending: [String: SessionContinuation] = [:]
    private var completedContinuationIDs = Set<String>()
    private var cancelledContinuationIDs = Set<String>()

    public init(sessionID: SessionID, ownerID: String) throws {
        try validateSessionPathComponent(sessionID.rawValue)
        guard !ownerID.isEmpty else {
            throw ShellSessionSupportError.invalidCommand("owner id is empty")
        }
        self.sessionID = sessionID
        self.ownerID = ownerID
    }

    public func register(
        continuationID: String,
        commandID: String? = nil,
        issuedAtMS: UInt64
    ) throws -> SessionContinuation {
        guard !continuationID.isEmpty else {
            throw ShellSessionSupportError.invalidCommand("continuation id is empty")
        }
        guard pending[continuationID] == nil else {
            throw ShellSessionSupportError.invalidCommand("continuation already registered: \(continuationID)")
        }
        guard !completedContinuationIDs.contains(continuationID),
              !cancelledContinuationIDs.contains(continuationID) else {
            throw ShellSessionSupportError.commandAlreadyCompleted(continuationID)
        }
        let continuation = try SessionContinuation(
            continuationID: continuationID,
            sessionID: sessionID,
            commandID: commandID,
            issuedAtMS: issuedAtMS
        )
        pending[continuationID] = continuation
        return continuation
    }

    public func complete(continuationID: String, by claimantID: String) throws {
        try requireOwner(claimantID)
        guard pending.removeValue(forKey: continuationID) != nil else {
            if completedContinuationIDs.contains(continuationID) || cancelledContinuationIDs.contains(continuationID) {
                throw ShellSessionSupportError.commandAlreadyCompleted(continuationID)
            }
            throw ShellSessionSupportError.commandNotFound(continuationID)
        }
        completedContinuationIDs.insert(continuationID)
    }

    public func cancel(continuationID: String, by claimantID: String) throws -> Bool {
        try requireOwner(claimantID)
        guard pending.removeValue(forKey: continuationID) != nil else { return false }
        cancelledContinuationIDs.insert(continuationID)
        return true
    }

    public func snapshot() -> SessionContinuationRegistrySnapshot {
        SessionContinuationRegistrySnapshot(
            pending: pending.values.sorted { $0.continuationID < $1.continuationID },
            completedContinuationIDs: completedContinuationIDs.sorted(),
            cancelledContinuationIDs: cancelledContinuationIDs.sorted()
        )
    }

    private func requireOwner(_ claimantID: String) throws {
        guard claimantID == ownerID else { throw ShellSessionSupportError.commandNotOwned }
    }
}

public enum SessionToolHistoryView: String, Codable, Sendable, Hashable {
    case modelVisible = "model_visible"
    case durableReplay = "durable_replay"
    case liveUI = "live_ui"
    case codeModeTransport = "code_mode_transport"
    case nestedTool = "nested_tool"
    case redactedExport = "redacted_export"
}

public struct SessionToolHistoryEntry: Codable, Sendable, Hashable {
    public let entryID: String
    public let sequence: UInt64
    public let timestampMS: UInt64
    public let toolCallID: String
    public let parentToolCallID: String?
    public let title: String
    public let paths: [String]
    public let input: JSONValue
    public let output: JSONValue?
    public let views: Set<SessionToolHistoryView>
    public let isRedacted: Bool

    public init(
        entryID: String,
        sequence: UInt64,
        timestampMS: UInt64,
        toolCallID: String,
        parentToolCallID: String? = nil,
        title: String,
        paths: [String] = [],
        input: JSONValue = .null,
        output: JSONValue? = nil,
        views: Set<SessionToolHistoryView>,
        isRedacted: Bool = false
    ) {
        self.entryID = entryID
        self.sequence = sequence
        self.timestampMS = timestampMS
        self.toolCallID = toolCallID
        self.parentToolCallID = parentToolCallID
        self.title = title
        self.paths = paths
        self.input = input
        self.output = output
        self.views = views
        self.isRedacted = isRedacted
    }

    public func redactedForExport() -> SessionToolHistoryEntry {
        SessionToolHistoryEntry(
            entryID: entryID,
            sequence: sequence,
            timestampMS: timestampMS,
            toolCallID: toolCallID,
            parentToolCallID: nil,
            title: "<redacted>",
            paths: [],
            input: .null,
            output: nil,
            views: [.redactedExport],
            isRedacted: true
        )
    }
}

public struct SessionToolHistoryProjection: Codable, Sendable, Hashable {
    public let modelVisible: [SessionToolHistoryEntry]
    public let durableReplay: [SessionToolHistoryEntry]
    public let liveUI: [SessionToolHistoryEntry]
    public let codeModeTransport: [SessionToolHistoryEntry]
    public let nestedTools: [SessionToolHistoryEntry]
    public let redactedExport: [SessionToolHistoryEntry]

    public init(
        modelVisible: [SessionToolHistoryEntry],
        durableReplay: [SessionToolHistoryEntry],
        liveUI: [SessionToolHistoryEntry],
        codeModeTransport: [SessionToolHistoryEntry],
        nestedTools: [SessionToolHistoryEntry],
        redactedExport: [SessionToolHistoryEntry]
    ) {
        self.modelVisible = modelVisible
        self.durableReplay = durableReplay
        self.liveUI = liveUI
        self.codeModeTransport = codeModeTransport
        self.nestedTools = nestedTools
        self.redactedExport = redactedExport
    }

    public static func project(_ entries: [SessionToolHistoryEntry]) -> SessionToolHistoryProjection {
        let ordered = entries.sorted { left, right in
            if left.sequence == right.sequence { return left.entryID < right.entryID }
            return left.sequence < right.sequence
        }
        func values(for view: SessionToolHistoryView) -> [SessionToolHistoryEntry] {
            ordered.filter { $0.views.contains(view) }
        }
        return SessionToolHistoryProjection(
            modelVisible: values(for: .modelVisible),
            durableReplay: values(for: .durableReplay),
            liveUI: values(for: .liveUI),
            codeModeTransport: values(for: .codeModeTransport),
            nestedTools: values(for: .nestedTool),
            redactedExport: ordered.filter { $0.views.contains(.redactedExport) }.map { $0.redactedForExport() }
        )
    }
}

public actor SessionToolHistorySink {
    private var entries: [SessionToolHistoryEntry] = []
    private var entryIDs = Set<String>()
    private var nextSequence: UInt64 = 0

    public init() {}

    public func record(
        entryID: String,
        timestampMS: UInt64,
        toolCallID: String,
        parentToolCallID: String? = nil,
        title: String,
        paths: [String] = [],
        input: JSONValue = .null,
        output: JSONValue? = nil,
        views: Set<SessionToolHistoryView>
    ) throws -> SessionToolHistoryEntry {
        let entry = SessionToolHistoryEntry(
            entryID: entryID,
            sequence: nextSequence,
            timestampMS: timestampMS,
            toolCallID: toolCallID,
            parentToolCallID: parentToolCallID,
            title: title,
            paths: paths,
            input: input,
            output: output,
            views: views
        )
        try append(entry)
        return entry
    }

    public func append(_ entry: SessionToolHistoryEntry) throws {
        guard !entry.entryID.isEmpty, !entry.toolCallID.isEmpty else {
            throw ShellSessionSupportError.invalidWireValue("tool history identifiers are empty")
        }
        guard entryIDs.insert(entry.entryID).inserted else {
            throw ShellSessionSupportError.invalidWireValue("duplicate tool history entry: \(entry.entryID)")
        }
        guard entry.sequence == nextSequence else {
            throw ShellSessionSupportError.invalidWireValue("tool history sequence is not contiguous")
        }
        entries.append(entry)
        nextSequence = nextSequence.saturatingAdd(1)
    }

    public func snapshot() -> [SessionToolHistoryEntry] { entries }

    public func projection() -> SessionToolHistoryProjection {
        SessionToolHistoryProjection.project(entries)
    }
}

public struct SessionUpdateEnvelope: Codable, Sendable, Hashable {
    public let timestamp: UInt64
    public let method: String
    public let params: JSONValue

    public init(timestamp: UInt64 = 0, method: String, params: JSONValue) throws {
        guard !method.isEmpty else { throw ShellSessionSupportError.invalidWireValue("session update method is empty") }
        self.timestamp = timestamp
        self.method = method
        self.params = params
    }
}

public enum SessionUpdate: Codable, Sendable, Hashable {
    case acp(JSONValue)
    case xai(JSONValue)
    case raw(method: String, params: JSONValue)

    public var method: String {
        switch self {
        case .acp: return "session/update"
        case .xai: return "_x.ai/session/update"
        case .raw(let method, _): return method
        }
    }

    public var params: JSONValue {
        switch self {
        case .acp(let params), .xai(let params), .raw(_, let params): return params
        }
    }

    public func envelope(timestamp: UInt64 = 0) throws -> SessionUpdateEnvelope {
        try SessionUpdateEnvelope(timestamp: timestamp, method: method, params: params)
    }

    public init(from decoder: Decoder) throws {
        let value = try JSONValue(from: decoder)
        guard case .object(let object) = value else {
            throw DecodingError.typeMismatch(
                [String: JSONValue].self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "session update must be an object")
            )
        }
        if let method = object["method"], case .string(let methodValue) = method, let params = object["params"] {
            if methodValue == "_x.ai/session/update" { self = .xai(params) }
            else if methodValue == "session/update" { self = .acp(params) }
            else { self = .raw(method: methodValue, params: params) }
        } else {
            self = .acp(value)
        }
    }

    public func encode(to encoder: Encoder) throws {
        guard !method.isEmpty else {
            throw ShellSessionSupportError.invalidWireValue("session update method is empty")
        }
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        try container.encode(method, forKey: DynamicCodingKey("method"))
        try container.encode(params, forKey: DynamicCodingKey("params"))
    }
}

public struct SessionTranscriptEntry: Codable, Sendable, Hashable {
    public let sequence: UInt64
    public let timestampMS: UInt64
    public let event: SessionTranscriptEvent

    public init(sequence: UInt64, timestampMS: UInt64, event: SessionTranscriptEvent) {
        self.sequence = sequence
        self.timestampMS = timestampMS
        self.event = event
    }
}

public enum SessionTranscriptEvent: Codable, Sendable, Hashable {
    case userTextChunk(text: String, promptIndex: UInt64?)
    case assistantTextChunk(text: String)
    case toolCall(title: String, paths: [String])
    case interruption(context: CancellationContext)
    case turnCompleted(kind: PromptCompletionKind)
    case rewind(targetPromptIndex: UInt64)
    case phaseChanged(SessionLifecyclePhase)
    case custom(name: String, payload: JSONValue)

    private enum CodingKeys: String, CodingKey {
        case kind
        case text
        case promptIndex = "prompt_index"
        case title
        case paths
        case context
        case completion
        case targetPromptIndex = "target_prompt_index"
        case phase
        case name
        case payload
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "user_text_chunk": self = .userTextChunk(text: try container.decode(String.self, forKey: .text), promptIndex: try container.decodeIfPresent(UInt64.self, forKey: .promptIndex))
        case "assistant_text_chunk": self = .assistantTextChunk(text: try container.decode(String.self, forKey: .text))
        case "tool_call": self = .toolCall(title: try container.decode(String.self, forKey: .title), paths: try container.decodeIfPresent([String].self, forKey: .paths) ?? [])
        case "interruption": self = .interruption(context: try container.decode(CancellationContext.self, forKey: .context))
        case "turn_completed": self = .turnCompleted(kind: try container.decode(PromptCompletionKind.self, forKey: .completion))
        case "rewind": self = .rewind(targetPromptIndex: try container.decode(UInt64.self, forKey: .targetPromptIndex))
        case "phase_changed": self = .phaseChanged(try container.decode(SessionLifecyclePhase.self, forKey: .phase))
        case "custom": self = .custom(name: try container.decode(String.self, forKey: .name), payload: try container.decodeIfPresent(JSONValue.self, forKey: .payload) ?? .null)
        default: throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "unknown transcript event")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .userTextChunk(let text, let promptIndex):
            try container.encode("user_text_chunk", forKey: .kind)
            try container.encode(text, forKey: .text)
            try container.encodeIfPresent(promptIndex, forKey: .promptIndex)
        case .assistantTextChunk(let text):
            try container.encode("assistant_text_chunk", forKey: .kind)
            try container.encode(text, forKey: .text)
        case .toolCall(let title, let paths):
            try container.encode("tool_call", forKey: .kind)
            try container.encode(title, forKey: .title)
            try container.encode(paths, forKey: .paths)
        case .interruption(let context):
            try container.encode("interruption", forKey: .kind)
            try container.encode(context, forKey: .context)
        case .turnCompleted(let kind):
            try container.encode("turn_completed", forKey: .kind)
            try container.encode(kind, forKey: .completion)
        case .rewind(let targetPromptIndex):
            try container.encode("rewind", forKey: .kind)
            try container.encode(targetPromptIndex, forKey: .targetPromptIndex)
        case .phaseChanged(let phase):
            try container.encode("phase_changed", forKey: .kind)
            try container.encode(phase, forKey: .phase)
        case .custom(let name, let payload):
            try container.encode("custom", forKey: .kind)
            try container.encode(name, forKey: .name)
            try container.encode(payload, forKey: .payload)
        }
    }
}

public struct SessionTranscript: Codable, Sendable, Hashable {
    public let entries: [SessionTranscriptEntry]

    public init(entries: [SessionTranscriptEntry] = []) {
        self.entries = entries.sorted { $0.sequence < $1.sequence }
    }

    public func appending(event: SessionTranscriptEvent, timestampMS: UInt64) -> SessionTranscript {
        let sequence = (entries.last?.sequence ?? 0).saturatingAdd(1)
        return SessionTranscript(entries: entries + [SessionTranscriptEntry(sequence: sequence, timestampMS: timestampMS, event: event)])
    }
}

public struct SessionTranscriptProjection: Codable, Sendable, Hashable {
    public let prompts: [String]
    public let assistantMessages: [String]
    public let toolMetadata: [String]
    public let events: [SessionTranscriptEvent]
    public let malformedUpdateCount: UInt64

    public init(
        prompts: [String],
        assistantMessages: [String],
        toolMetadata: [String],
        events: [SessionTranscriptEvent],
        malformedUpdateCount: UInt64 = 0
    ) {
        self.prompts = prompts
        self.assistantMessages = assistantMessages
        self.toolMetadata = toolMetadata
        self.events = events
        self.malformedUpdateCount = malformedUpdateCount
    }
}

public typealias SessionEventProjection = SessionTranscriptProjection

public enum PromptExtractEvent: Sendable, Hashable {
    case userTextChunk(text: String, promptIndex: UInt64?)
    case rewind(toPromptIndex: UInt64)
    case notUserMessage
}

public enum SessionTranscriptProjector {
    public static let maxAssistantCharacters = 100_000
    public static let maxToolCalls = 200
    public static let maxToolMetadataCharacters = 100_000

    public static func project(_ updates: [SessionUpdate]) -> SessionTranscriptProjection {
        // A terminal update may be the only marked line, so discover exact
        // transport identities across the complete timeline before projection.
        let hiddenTransportCallIDs = Set(updates.compactMap { update -> String? in
            guard update.method == "session/update",
                  let payload = update.params.objectValue,
                  payload["_meta"]?.objectValue?["open-grok/codeModeTransport"]?.boolValue == true,
                  let updateObject = payload["update"]?.objectValue,
                  let tag = updateObject["sessionUpdate"]?.stringValue,
                  tag == "tool_call" || tag == "tool_call_update",
                  let callID = updateObject["toolCallId"]?.stringValue,
                  !callID.isEmpty
            else { return nil }
            if tag == "tool_call",
               updateObject["title"]?.stringValue != "exec",
               updateObject["title"]?.stringValue != "wait" {
                return nil
            }
            return callID
        })
        var promptEvents: [PromptExtractEvent] = []
        var assistantMessages: [String] = []
        var toolMetadata: [String] = []
        var transcriptEvents: [SessionTranscriptEvent] = []
        var malformedUpdateCount: UInt64 = 0
        var assistantCurrent = ""
        var assistantCharacters = 0
        var toolCallCount = 0
        var toolCharacters = 0

        for update in updates {
            guard let payload = update.params.objectValue else {
                malformedUpdateCount = malformedUpdateCount.saturatingAdd(1)
                promptEvents.append(.notUserMessage)
                flushAssistant(&assistantCurrent, into: &assistantMessages)
                continue
            }
            let updateObject = payload["update"]?.objectValue ?? payload
            guard let tag = updateObject["sessionUpdate"]?.stringValue else {
                malformedUpdateCount = malformedUpdateCount.saturatingAdd(1)
                promptEvents.append(.notUserMessage)
                flushAssistant(&assistantCurrent, into: &assistantMessages)
                continue
            }
            if update.method == "session/update",
               (tag == "tool_call" || tag == "tool_call_update"),
               let callID = updateObject["toolCallId"]?.stringValue,
               hiddenTransportCallIDs.contains(callID) {
                continue
            }

            if tag == "user_message_chunk" {
                if update.method == "session/update",
                   let content = updateObject["content"]?.objectValue,
                   content["type"]?.stringValue == "text",
                   let text = content["text"]?.stringValue {
                    let contentMetadata = content["_meta"]?.objectValue
                    let updateMetadata = updateObject["_meta"]?.objectValue
                    let isHidden = contentMetadata?["bash_command"] != nil
                        || contentMetadata?["bashCommand"] != nil
                        || contentMetadata?["hideFromScrollback"]?.boolValue == true
                        || contentMetadata?["hostTurn"]?.boolValue == true
                        || updateMetadata?["hideFromScrollback"]?.boolValue == true
                        || updateMetadata?["host_turn"]?.boolValue == true
                        || updateMetadata?["hostTurn"]?.boolValue == true
                    if isHidden {
                        promptEvents.append(.notUserMessage)
                    } else {
                        let promptIndex = contentMetadata?["promptIndex"]?.uint64Value
                            ?? contentMetadata?["prompt_index"]?.uint64Value
                            ?? updateMetadata?["promptIndex"]?.uint64Value
                            ?? updateMetadata?["prompt_index"]?.uint64Value
                        promptEvents.append(.userTextChunk(text: text, promptIndex: promptIndex))
                        transcriptEvents.append(.userTextChunk(text: text, promptIndex: promptIndex))
                    }
                } else {
                    malformedUpdateCount = malformedUpdateCount.saturatingAdd(1)
                    promptEvents.append(.notUserMessage)
                }
            } else if tag == "rewind_marker" {
                if let target = updateObject["target_prompt_index"]?.uint64Value {
                    promptEvents.append(.rewind(toPromptIndex: target))
                    transcriptEvents.append(.rewind(targetPromptIndex: target))
                } else {
                    malformedUpdateCount = malformedUpdateCount.saturatingAdd(1)
                    promptEvents.append(.notUserMessage)
                }
            } else {
                let knownTags: Set<String> = [
                    "agent_thought_chunk",
                    "agent_message_chunk",
                    "available_commands_update",
                    "config_option_update",
                    "current_mode_update",
                    "plan",
                    "prompt_rejected",
                    "session_info_update",
                    "tool_call",
                    "tool_call_update",
                    "turn_complete",
                    "turn_completed",
                    "usage_update"
                ]
                if !knownTags.contains(tag) {
                    malformedUpdateCount = malformedUpdateCount.saturatingAdd(1)
                }
                promptEvents.append(.notUserMessage)
            }

            if tag == "turn_completed" {
                guard update.method == "_x.ai/session/update",
                      let promptID = updateObject["prompt_id"]?.stringValue,
                      !promptID.isEmpty,
                      let stopReason = updateObject["stop_reason"]?.stringValue,
                      !stopReason.isEmpty else {
                    malformedUpdateCount = malformedUpdateCount.saturatingAdd(1)
                    flushAssistant(&assistantCurrent, into: &assistantMessages)
                    continue
                }

                switch stopReason {
                case "cancelled", "canceled":
                    transcriptEvents.append(.turnCompleted(kind: .cancelled(category: nil, context: nil)))
                case "max_turns_reached":
                    if let limit = updateObject["limit"]?.uint64Value {
                        transcriptEvents.append(.turnCompleted(kind: .maxTurnsReached(limit: limit)))
                    } else {
                        transcriptEvents.append(.turnCompleted(
                            kind: .cancelled(category: "max_turns_reached", context: nil)
                        ))
                    }
                case "error":
                    transcriptEvents.append(.custom(
                        name: "turn_failed",
                        payload: updateObject["agent_result"] ?? .null
                    ))
                default:
                    transcriptEvents.append(.turnCompleted(kind: .completed))
                }
            }

            if tag == "agent_message_chunk" {
                guard update.method == "session/update",
                      let content = updateObject["content"]?.objectValue,
                      content["type"]?.stringValue == "text",
                      let text = content["text"]?.stringValue,
                      !text.isEmpty else {
                    malformedUpdateCount = malformedUpdateCount.saturatingAdd(1)
                    flushAssistant(&assistantCurrent, into: &assistantMessages)
                    continue
                }
                let separatorCost = assistantCurrent.isEmpty ? 0 : 1
                let budget = max(0, maxAssistantCharacters - assistantCharacters - separatorCost)
                if budget > 0 {
                    let accepted = text.prefixUTF8Bytes(budget)
                    if !accepted.isEmpty {
                        if !assistantCurrent.isEmpty { assistantCurrent.append(" "); assistantCharacters += 1 }
                        assistantCurrent.append(contentsOf: accepted)
                        assistantCharacters += accepted.utf8.count
                        transcriptEvents.append(.assistantTextChunk(text: String(accepted)))
                    }
                }
            } else if tag != "user_message_chunk" {
                flushAssistant(&assistantCurrent, into: &assistantMessages)
            }

            if tag == "tool_call", toolCallCount < maxToolCalls {
                toolCallCount += 1
                let title = updateObject["title"]?.stringValue ?? ""
                let paths = updateObject["locations"]?.arrayValue?.compactMap { $0.objectValue?["path"]?.stringValue } ?? []
                if !title.isEmpty {
                    let accepted = title.prefixUTF8Bytes(maxToolMetadataCharacters - toolCharacters)
                    if !accepted.isEmpty {
                        toolMetadata.append(String(accepted))
                        toolCharacters += accepted.utf8.count
                    }
                }
                for path in paths where toolCharacters < maxToolMetadataCharacters {
                    let accepted = path.prefixUTF8Bytes(maxToolMetadataCharacters - toolCharacters)
                    if !accepted.isEmpty {
                        toolMetadata.append(String(accepted))
                        toolCharacters += accepted.utf8.count
                    }
                }
                transcriptEvents.append(.toolCall(title: title, paths: paths))
            }
        }
        flushAssistant(&assistantCurrent, into: &assistantMessages)
        return SessionTranscriptProjection(
            prompts: collectPrompts(from: promptEvents),
            assistantMessages: assistantMessages,
            toolMetadata: toolMetadata,
            events: transcriptEvents,
            malformedUpdateCount: malformedUpdateCount
        )
    }

    public static func collectPrompts(from events: [PromptExtractEvent]) -> [String] {
        var prompts: [String] = []
        var current = ""
        var inUser = false
        var currentPromptIndex: UInt64?
        var currentCounts = false
        var seenMarker = false

        func flush() {
            guard inUser else { return }
            if currentCounts {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { prompts.append(trimmed) }
            }
            current = ""
            inUser = false
            currentPromptIndex = nil
            currentCounts = false
        }

        for event in events {
            switch event {
            case .userTextChunk(let text, let promptIndex):
                if promptIndex != nil { seenMarker = true }
                if !inUser {
                    flush()
                    inUser = true
                    currentPromptIndex = promptIndex
                    currentCounts = !seenMarker || promptIndex != nil
                    current.append(text)
                } else if currentPromptIndex == nil, let promptIndex {
                    currentPromptIndex = promptIndex
                    currentCounts = true
                    current.append(text)
                } else if let currentPromptIndex, let promptIndex, currentPromptIndex == promptIndex {
                    current.append(text)
                } else if currentPromptIndex == nil, promptIndex == nil, !seenMarker {
                    current.append(text)
                } else if currentPromptIndex != nil, promptIndex == nil {
                    flush()
                    inUser = true
                    currentPromptIndex = nil
                    currentCounts = false
                    current.append(text)
                } else {
                    flush()
                    inUser = true
                    currentPromptIndex = promptIndex
                    currentCounts = promptIndex != nil
                    current.append(text)
                }
            case .rewind(let target):
                flush()
                prompts = Array(prompts.prefix(Int(min(target, UInt64(prompts.count)))))
            case .notUserMessage:
                flush()
            }
        }
        flush()
        return prompts
    }

    public static func collectAssistantText(from updates: [SessionUpdate]) -> [String] {
        project(updates).assistantMessages
    }

    public static func collectToolMetadata(from updates: [SessionUpdate]) -> [String] {
        project(updates).toolMetadata
    }

    private static func flushAssistant(_ current: inout String, into messages: inout [String]) {
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { messages.append(trimmed) }
        current = ""
    }
}

public enum SessionInterruptionTrigger: String, Codable, Sendable, Hashable {
    case esc
    case ctrlC = "ctrl_c"
    case sendNow = "send_now"
    case timeout
    case processExit = "process_exit"
    case unknown
}

public struct SessionInterruption: Codable, Sendable, Hashable {
    public let trigger: SessionInterruptionTrigger
    public let context: CancellationContext
    public let interruptedAtMS: UInt64
    public let preserveQueuedPrompts: Bool

    public init(
        trigger: SessionInterruptionTrigger,
        context: CancellationContext = CancellationContext(),
        interruptedAtMS: UInt64,
        preserveQueuedPrompts: Bool = true
    ) {
        self.trigger = trigger
        self.context = context
        self.interruptedAtMS = interruptedAtMS
        self.preserveQueuedPrompts = preserveQueuedPrompts
    }
}

public enum SessionRecoveryStatus: String, Codable, Sendable, Hashable {
    case clean
    case interrupted
    case recoverable
    case recovered
    case terminal
}

public struct SessionRecoveryState: Codable, Sendable, Hashable {
    public var status: SessionRecoveryStatus
    public var interruption: SessionInterruption?
    public var recoveryGeneration: UInt64
    public var lastCompletedSequence: UInt64

    public init(
        status: SessionRecoveryStatus = .clean,
        interruption: SessionInterruption? = nil,
        recoveryGeneration: UInt64 = 0,
        lastCompletedSequence: UInt64 = 0
    ) {
        self.status = status
        self.interruption = interruption
        self.recoveryGeneration = recoveryGeneration
        self.lastCompletedSequence = lastCompletedSequence
    }
}

public enum SessionRecoveryDecision: Codable, Sendable, Hashable {
    case resume
    case requireUser
    case discardQueuedWork
    case noAction
}

public struct SessionRecoveryPlan: Codable, Sendable, Hashable {
    public let decision: SessionRecoveryDecision
    public let state: SessionRecoveryState
    public let commandsToReplay: [SessionCommand]

    public init(decision: SessionRecoveryDecision, state: SessionRecoveryState, commandsToReplay: [SessionCommand]) {
        self.decision = decision
        self.state = state
        self.commandsToReplay = commandsToReplay
    }
}

public enum SessionRecoveryPlanner {
    public static func plan(
        recovery: SessionRecoveryState,
        mailbox: SessionCommandMailboxSnapshot,
        processWasAlive: Bool
    ) -> SessionRecoveryPlan {
        if processWasAlive { return SessionRecoveryPlan(decision: .noAction, state: recovery, commandsToReplay: []) }
        guard recovery.status == .interrupted || recovery.status == .recoverable else {
            return SessionRecoveryPlan(decision: .noAction, state: recovery, commandsToReplay: [])
        }
        let replay = mailbox.queued.sorted { $0.sequence < $1.sequence }
        var next = recovery
        next.status = .recoverable
        next.recoveryGeneration = next.recoveryGeneration.saturatingAdd(1)
        return SessionRecoveryPlan(decision: replay.isEmpty ? .requireUser : .resume, state: next, commandsToReplay: replay)
    }
}

/// Chat-history format version written by this build.
///
/// `CHAT_FORMAT_VERSION` — `crates/codegen/xai-grok-shell/src/session/persistence.rs:31`.
/// Version 0 is the legacy `ChatRequestMessage` shape; version 1 is
/// `ConversationItem`.
public let chatFormatVersion: UInt8 = 1

/// Which decode shape to try first for a chat-history line.
///
/// This is the whole of the version check on load: it is **not** a hard
/// reject. `read_chat_history_sync`
/// (`.../session/storage/jsonl/mod.rs:842`) tries `ConversationItem` first
/// at or above the current version and `ChatRequestMessage` first below it,
/// falling back to the other shape either way, so no line is lost to a
/// version mismatch.
public enum ChatHistoryDecodeOrder: String, Sendable, Hashable {
    /// `chat_format_version >= 1`: `ConversationItem`, then `ChatRequestMessage`.
    case conversationItemFirst
    /// `chat_format_version < 1`: `ChatRequestMessage`, then `ConversationItem`.
    case chatRequestMessageFirst

    public static func forVersion(_ version: UInt8) -> ChatHistoryDecodeOrder {
        version >= chatFormatVersion ? .conversationItemFirst : .chatRequestMessageFirst
    }
}

/// Whether an empty/missing chat-history file may be rebuilt from the
/// session's updates log.
///
/// `ensure_chat_history` (`.../session/storage/jsonl/mod.rs:103`) rebuilds
/// **only** at an exact version match: a summary from a different format
/// version is left alone rather than rebuilt into the wrong shape. Note this
/// is `==`, not `>=` — a future version is skipped too.
public func chatHistoryMayBeRebuilt(chatFormatVersion version: UInt8) -> Bool {
    version == chatFormatVersion
}

public struct SessionSummary: Codable, Sendable, Hashable {
    public var sessionID: SessionID
    public var cwd: String
    public var sessionSummary: String
    public var createdAt: Date
    public var updatedAt: Date
    public var messageCount: UInt64
    public var chatMessageCount: UInt64
    public var currentModelID: String
    public var parentSessionID: String?
    public var nextTraceTurn: UInt64
    public var chatFormatVersion: UInt8
    public var everUsedCodex: Bool
    public var sessionKind: String?
    /// Every summary key this build does not model, preserved verbatim.
    ///
    /// Load-bearing for the working-directory **relocation** subsystem
    /// (`crates/codegen/xai-grok-shell/src/session/storage/relocation/`, new
    /// at pin 80dff0a9): a Rust-written summary carries `cwd_generation`,
    /// `previous_cwd`, `pending_cwd_switch_reminder` and
    /// `cwd_switch_bookkeeping_generation` (persistence.rs:858-870) that this
    /// port does not yet interpret. Without this bag a Swift round-trip would
    /// silently drop a session's in-flight relocation record. Porting the
    /// subsystem itself is deliberately out of scope here.
    public var extra: [String: JSONValue]

    public init(
        sessionID: SessionID,
        cwd: String,
        sessionSummary: String = "",
        createdAt: Date = Date(timeIntervalSince1970: 0),
        updatedAt: Date = Date(timeIntervalSince1970: 0),
        messageCount: UInt64 = 0,
        chatMessageCount: UInt64 = 0,
        currentModelID: String = "",
        parentSessionID: String? = nil,
        nextTraceTurn: UInt64 = 0,
        chatFormatVersion: UInt8 = OpenGrokShellSessionSupport.chatFormatVersion,
        everUsedCodex: Bool = false,
        sessionKind: String? = nil,
        extra: [String: JSONValue] = [:]
    ) {
        self.sessionID = sessionID
        self.cwd = cwd
        self.sessionSummary = sessionSummary
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messageCount = messageCount
        self.chatMessageCount = chatMessageCount
        self.currentModelID = currentModelID
        self.parentSessionID = parentSessionID
        self.nextTraceTurn = nextTraceTurn
        self.chatFormatVersion = chatFormatVersion
        self.everUsedCodex = everUsedCodex
        self.sessionKind = sessionKind
        self.extra = extra
    }

    /// Decode order for this summary's chat history.
    public var chatHistoryDecodeOrder: ChatHistoryDecodeOrder {
        .forVersion(chatFormatVersion)
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case cwd
        case sessionSummary = "session_summary"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case messageCount = "num_messages"
        case chatMessageCount = "num_chat_messages"
        case currentModelID = "current_model_id"
        case parentSessionID = "parent_session_id"
        case nextTraceTurn = "next_trace_turn"
        case chatFormatVersion = "chat_format_version"
        case everUsedCodex = "ever_used_codex"
        case sessionKind = "session_kind"
    }

    private static let knownKeys: Set<String> = Set(
        [
            CodingKeys.sessionID, .cwd, .sessionSummary, .createdAt, .updatedAt,
            .messageCount, .chatMessageCount, .currentModelID, .parentSessionID,
            .nextTraceTurn, .chatFormatVersion, .everUsedCodex, .sessionKind,
        ].map(\.rawValue)
    )

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try c.decode(SessionID.self, forKey: .sessionID)
        cwd = try c.decode(String.self, forKey: .cwd)
        sessionSummary = try c.decodeIfPresent(String.self, forKey: .sessionSummary) ?? ""
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        messageCount = try c.decodeIfPresent(UInt64.self, forKey: .messageCount) ?? 0
        chatMessageCount = try c.decodeIfPresent(UInt64.self, forKey: .chatMessageCount) ?? 0
        currentModelID = try c.decodeIfPresent(String.self, forKey: .currentModelID) ?? ""
        parentSessionID = try c.decodeIfPresent(String.self, forKey: .parentSessionID)
        nextTraceTurn = try c.decodeIfPresent(UInt64.self, forKey: .nextTraceTurn) ?? 0
        // serde `#[serde(default)]` on a `u8` is 0, not CHAT_FORMAT_VERSION:
        // a summary with no version field is legacy-format by definition
        // (persistence.rs:905-909). Only the *constructor* defaults to 1.
        chatFormatVersion = try c.decodeIfPresent(UInt8.self, forKey: .chatFormatVersion) ?? 0
        everUsedCodex = try c.decodeIfPresent(Bool.self, forKey: .everUsedCodex) ?? false
        sessionKind = try c.decodeIfPresent(String.self, forKey: .sessionKind)
        extra = try UnknownFields.decode(from: decoder, knownKeyStrings: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sessionID, forKey: .sessionID)
        try c.encode(cwd, forKey: .cwd)
        try c.encode(sessionSummary, forKey: .sessionSummary)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(messageCount, forKey: .messageCount)
        try c.encode(chatMessageCount, forKey: .chatMessageCount)
        try c.encode(currentModelID, forKey: .currentModelID)
        try c.encodeIfPresent(parentSessionID, forKey: .parentSessionID)
        try c.encode(nextTraceTurn, forKey: .nextTraceTurn)
        try c.encode(chatFormatVersion, forKey: .chatFormatVersion)
        try c.encode(everUsedCodex, forKey: .everUsedCodex)
        try c.encodeIfPresent(sessionKind, forKey: .sessionKind)
        if !extra.isEmpty {
            var any = encoder.container(keyedBy: AnyCodingKey.self)
            try UnknownFields.encode(extra, into: &any)
        }
    }
}

public struct PersistedSessionState: Codable, Sendable, Hashable {
    public var summary: SessionSummary
    public var chatHistory: [JSONValue]
    public var updates: [SessionUpdateEnvelope]
    public var transcript: SessionTranscript
    public var toolHistory: [SessionToolHistoryEntry]
    public var recovery: SessionRecoveryState
    public var pendingCommands: [SessionCommand]

    public init(
        summary: SessionSummary,
        chatHistory: [JSONValue] = [],
        updates: [SessionUpdateEnvelope] = [],
        transcript: SessionTranscript = SessionTranscript(),
        toolHistory: [SessionToolHistoryEntry] = [],
        recovery: SessionRecoveryState = SessionRecoveryState(),
        pendingCommands: [SessionCommand] = []
    ) {
        self.summary = summary
        self.chatHistory = chatHistory
        self.updates = updates
        self.transcript = transcript
        self.toolHistory = toolHistory.sorted { left, right in
            if left.sequence == right.sequence { return left.entryID < right.entryID }
            return left.sequence < right.sequence
        }
        self.recovery = recovery
        self.pendingCommands = pendingCommands.sorted { $0.sequence < $1.sequence }
    }

    private enum CodingKeys: String, CodingKey {
        case summary
        case chatHistory = "chat_history"
        case legacyChatHistory = "chatHistory"
        case updates
        case transcript
        case toolHistory = "tool_history"
        case legacyToolHistory = "toolHistory"
        case recovery
        case pendingCommands = "pending_commands"
        case legacyPendingCommands = "pendingCommands"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(summary, forKey: .summary)
        try container.encode(chatHistory, forKey: .chatHistory)
        try container.encode(updates, forKey: .updates)
        try container.encode(transcript, forKey: .transcript)
        try container.encode(toolHistory, forKey: .toolHistory)
        try container.encode(recovery, forKey: .recovery)
        try container.encode(pendingCommands, forKey: .pendingCommands)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let chatHistory = try container.decodeIfPresent([JSONValue].self, forKey: .chatHistory)
            ?? (try container.decodeIfPresent([JSONValue].self, forKey: .legacyChatHistory))
            ?? []
        let toolHistory = try container.decodeIfPresent([SessionToolHistoryEntry].self, forKey: .toolHistory)
            ?? (try container.decodeIfPresent([SessionToolHistoryEntry].self, forKey: .legacyToolHistory))
            ?? []
        let pendingCommands = try container.decodeIfPresent([SessionCommand].self, forKey: .pendingCommands)
            ?? (try container.decodeIfPresent([SessionCommand].self, forKey: .legacyPendingCommands))
            ?? []
        self.init(
            summary: try container.decode(SessionSummary.self, forKey: .summary),
            chatHistory: chatHistory,
            updates: try container.decodeIfPresent([SessionUpdateEnvelope].self, forKey: .updates) ?? [],
            transcript: try container.decodeIfPresent(SessionTranscript.self, forKey: .transcript) ?? SessionTranscript(),
            toolHistory: toolHistory,
            recovery: try container.decodeIfPresent(SessionRecoveryState.self, forKey: .recovery) ?? SessionRecoveryState(),
            pendingCommands: pendingCommands
        )
    }
}

public struct PersistedSessionStateLight: Codable, Sendable, Hashable {
    public var summary: SessionSummary
    public var chatHistory: [JSONValue]
    public var transcript: SessionTranscript
    public var toolHistory: [SessionToolHistoryEntry]
    public var recovery: SessionRecoveryState
    public var pendingCommands: [SessionCommand]

    public init(from state: PersistedSessionState) {
        summary = state.summary
        chatHistory = state.chatHistory
        transcript = state.transcript
        toolHistory = state.toolHistory
        recovery = state.recovery
        pendingCommands = state.pendingCommands
    }
}

public typealias PersistedData = PersistedSessionState
public typealias PersistedDataLight = PersistedSessionStateLight

public struct CopySessionOptions: Codable, Sendable, Hashable {
    public var parentSessionID: String?
    public var newModelID: String?
    public var targetPromptIndex: UInt64?
    public var preserveWorkingDirectory: Bool

    public init(
        parentSessionID: String? = nil,
        newModelID: String? = nil,
        targetPromptIndex: UInt64? = nil,
        preserveWorkingDirectory: Bool = false
    ) {
        self.parentSessionID = parentSessionID
        self.newModelID = newModelID
        self.targetPromptIndex = targetPromptIndex
        self.preserveWorkingDirectory = preserveWorkingDirectory
    }
}

public struct CopySessionResult: Codable, Sendable, Hashable {
    public var chatMessagesCopied: UInt64
    public var updatesCopied: UInt64
    public var transcriptEntriesCopied: UInt64
    public var recoveryStateCopied: Bool

    public init(chatMessagesCopied: UInt64 = 0, updatesCopied: UInt64 = 0, transcriptEntriesCopied: UInt64 = 0, recoveryStateCopied: Bool = false) {
        self.chatMessagesCopied = chatMessagesCopied
        self.updatesCopied = updatesCopied
        self.transcriptEntriesCopied = transcriptEntriesCopied
        self.recoveryStateCopied = recoveryStateCopied
    }
}

public struct ActiveSessionRecord: Codable, Sendable, Hashable {
    public let sessionID: SessionID
    public let pid: UInt32
    public let cwd: String
    public let openedAt: Date

    public init(sessionID: SessionID, pid: UInt32, cwd: String, openedAt: Date = Date(timeIntervalSince1970: 0)) {
        self.sessionID = sessionID
        self.pid = pid
        self.cwd = cwd
        self.openedAt = openedAt
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case pid
        case cwd
        case openedAt = "opened_at"
        case legacySessionID = "sessionID"
        case legacyOpenedAt = "openedAt"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.sessionID) {
            sessionID = try container.decode(SessionID.self, forKey: .sessionID)
        } else {
            sessionID = try container.decode(SessionID.self, forKey: .legacySessionID)
        }
        pid = try container.decode(UInt32.self, forKey: .pid)
        cwd = try container.decode(String.self, forKey: .cwd)

        if container.contains(.openedAt) {
            let timestamp = try container.decode(String.self, forKey: .openedAt)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: timestamp) {
                openedAt = date
            } else if let date = ISO8601DateFormatter().date(from: timestamp) {
                openedAt = date
            } else {
                throw DecodingError.dataCorruptedError(
                    forKey: .openedAt,
                    in: container,
                    debugDescription: "active-session timestamp must be RFC 3339"
                )
            }
        } else {
            openedAt = try container.decode(Date.self, forKey: .legacyOpenedAt)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(pid, forKey: .pid)
        try container.encode(cwd, forKey: .cwd)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        try container.encode(formatter.string(from: openedAt), forKey: .openedAt)
    }
}

public actor ActiveSessionRegistry {
    public static let dataFileName = "active_sessions.json"
    public static let lockFileName = "active_sessions.lock"
    private let storage: ActiveSessionFileLock
    private var sessions: [ActiveSessionRecord] = []

    public init(root: URL) {
        storage = ActiveSessionFileLock(root: root.standardizedFileURL)
    }

    public func load() throws {
        sessions = try withPersistenceErrors { try storage.read() }
    }

    public func register(_ record: ActiveSessionRecord) throws {
        try validateSessionPathComponent(record.sessionID.rawValue)
        sessions = try withPersistenceErrors {
            try storage.modify { records in
                records.removeAll { $0.sessionID == record.sessionID }
                records.append(record)
                return records
            }
        }
    }

    public func unregister(sessionID: SessionID) throws -> Bool {
        try validateSessionPathComponent(sessionID.rawValue)
        let result = try withPersistenceErrors {
            try storage.modify { records in
                let previousCount = records.count
                records.removeAll { $0.sessionID == sessionID }
                return (records, previousCount != records.count)
            }
        }
        sessions = result.0
        return result.1
    }

    /// A contended shutdown must not hang; the next startup reaps its orphan.
    public func tryUnregister(sessionID: SessionID) throws -> Bool {
        try validateSessionPathComponent(sessionID.rawValue)
        let updated = try withPersistenceErrors {
            try storage.tryModify { records in
                records.removeAll { $0.sessionID == sessionID }
                return records
            }
        }
        guard let updated else { return false }
        sessions = updated
        return true
    }

    public func list() throws -> [ActiveSessionRecord] {
        sessions = try withPersistenceErrors { try storage.read() }
        return sessions.sorted { $0.sessionID.rawValue < $1.sessionID.rawValue }
    }

    public func collectCrashed(alivePIDs: Set<UInt32>) throws -> [ActiveSessionRecord] {
        try collectCrashed(whereAlive: { alivePIDs.contains($0) })
    }

    public func collectCrashed() throws -> [ActiveSessionRecord] {
        try collectCrashed(whereAlive: ActiveSessionProcessLiveness.isAlive)
    }

    private func collectCrashed(
        whereAlive isAlive: (UInt32) -> Bool
    ) throws -> [ActiveSessionRecord] {
        let result = try withPersistenceErrors {
            try storage.modify { records in
                var crashed: [ActiveSessionRecord] = []
                records.removeAll { record in
                    guard !isAlive(record.pid) else { return false }
                    crashed.append(record)
                    return true
                }
                return (records, crashed)
            }
        }
        sessions = result.0
        return result.1.sorted { $0.sessionID.rawValue < $1.sessionID.rawValue }
    }

    private func withPersistenceErrors<Value>(
        _ operation: () throws -> Value
    ) throws -> Value {
        do {
            return try operation()
        } catch let error as ShellSessionSupportError {
            throw error
        } catch {
            throw ShellSessionSupportError.persistence(String(describing: error))
        }
    }
}

public actor SessionStateStore {
    public static let fileName = "state.json"
    private let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    public func save(_ state: PersistedSessionState) throws {
        try validateSessionPathComponent(state.summary.sessionID.rawValue)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(state)
            try SessionStateSecureStorage(root: root).save(
                data,
                sessionID: state.summary.sessionID.rawValue
            )
        } catch {
            throw persistenceFailure(error)
        }
    }

    public func load(sessionID: SessionID) throws -> PersistedSessionState? {
        try validateSessionPathComponent(sessionID.rawValue)
        do {
            guard let data = try SessionStateSecureStorage(root: root).load(
                sessionID: sessionID.rawValue
            ) else {
                return nil
            }
            return try JSONDecoder().decode(PersistedSessionState.self, from: data)
        } catch {
            throw ShellSessionSupportError.persistence("invalid session state: \(describePersistenceError(error))")
        }
    }

    public func delete(sessionID: SessionID) throws {
        try validateSessionPathComponent(sessionID.rawValue)
        do {
            try SessionStateSecureStorage(root: root).delete(sessionID: sessionID.rawValue)
        } catch {
            throw persistenceFailure(error)
        }
    }

    private func persistenceFailure(_ error: Error) -> ShellSessionSupportError {
        if let failure = error as? ShellSessionSupportError {
            return failure
        }
        return .persistence(error.localizedDescription)
    }

    private func describePersistenceError(_ error: Error) -> String {
        if case let ShellSessionSupportError.persistence(message) = error {
            return message
        }
        return error.localizedDescription
    }
}

private struct SessionStateSecureStorage {
    let root: URL

    #if os(Windows)
    func save(_ data: Data, sessionID: String) throws {
        guard let directory = try sessionDirectory(sessionID: sessionID, create: true) else {
            throw failure("session directory could not be created")
        }
        let destination = directory.appendingPathComponent(SessionStateStore.fileName)
        try secureExistingFile(destination)
        try AtomicFile.write(destination, data: data, options: .ownerOnly)
        try SecureFile.ensureOwnerOnlyPermissions(at: destination)
        guard try SecureFile.isOwnerOnly(at: destination) else {
            throw failure("session state is not private to the current user")
        }
    }

    func load(sessionID: String) throws -> Data? {
        guard let directory = try sessionDirectory(sessionID: sessionID, create: false) else {
            return nil
        }
        let destination = directory.appendingPathComponent(SessionStateStore.fileName)
        guard try secureExistingFile(destination) else { return nil }
        return try PathSecurity.readNoFollow(destination, maximumBytes: nil, requireOwnerOnly: true)
    }

    func delete(sessionID: String) throws {
        guard let directory = try sessionDirectory(sessionID: sessionID, create: false) else {
            return
        }
        let destination = directory.appendingPathComponent(SessionStateStore.fileName)
        if try secureExistingFile(destination) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.removeItem(at: directory)
    }

    private func sessionDirectory(sessionID: String, create: Bool) throws -> URL? {
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        let directory = sessions.appendingPathComponent(sessionID, isDirectory: true)

        for path in [root, sessions, directory] {
            if let metadata = try WindowsSecurePath.metadata(at: path) {
                guard metadata.isDirectory, !metadata.isReparsePoint else {
                    throw failure("session directory must be a real, non-symlink directory: \(path.path)")
                }
            } else if !create {
                return nil
            }
        }

        try OpenGrokConfig.createDirAllOwnerOnly(directory, stateRoot: root)
        return directory
    }

    @discardableResult
    private func secureExistingFile(_ path: URL) throws -> Bool {
        guard let metadata = try WindowsSecurePath.metadata(at: path) else { return false }
        guard !metadata.isDirectory, !metadata.isReparsePoint else {
            throw failure("session state must be a regular, non-symlink file: \(path.path)")
        }
        try SecureFile.ensureOwnerOnlyPermissions(at: path)
        guard try SecureFile.isOwnerOnly(at: path) else {
            throw failure("session state is not private to the current user")
        }
        return true
    }
    #elseif canImport(Darwin) || canImport(Glibc)
    private static var directoryFlags: Int32 {
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    }

    private final class SessionDirectory {
        let rootDescriptor: Int32
        let sessionsDescriptor: Int32
        let descriptor: Int32
        let root: URL
        let sessionID: String

        init(rootDescriptor: Int32, sessionsDescriptor: Int32, descriptor: Int32, root: URL, sessionID: String) {
            self.rootDescriptor = rootDescriptor
            self.sessionsDescriptor = sessionsDescriptor
            self.descriptor = descriptor
            self.root = root
            self.sessionID = sessionID
        }

        deinit {
            close(descriptor)
            close(sessionsDescriptor)
            close(rootDescriptor)
        }
    }

    func save(_ data: Data, sessionID: String) throws {
        guard let directory = try sessionDirectory(sessionID: sessionID, create: true) else {
            throw failure("session directory could not be created")
        }
        try verify(directory)
        if let existing = try openFile(in: directory, allowMissing: true) {
            close(existing)
        }

        let temporary = ".state-\(UUID().uuidString).tmp"
        let descriptor = temporary.withCString {
            openat(
                directory.descriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode_t(0o600)
            )
        }
        guard descriptor >= 0 else {
            throw failure("create private session-state file: \(posixDescription())")
        }

        var descriptorOpen = true
        var temporaryExists = true
        defer {
            if descriptorOpen { close(descriptor) }
            if temporaryExists {
                _ = temporary.withCString { unlinkat(directory.descriptor, $0, 0) }
            }
        }

        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                #if canImport(Darwin)
                let written = Darwin.write(descriptor, base.advanced(by: offset), buffer.count - offset)
                #else
                let written = Glibc.write(descriptor, base.advanced(by: offset), buffer.count - offset)
                #endif
                if written < 0 {
                    if errno == EINTR { continue }
                    throw failure("write private session-state file: \(posixDescription())")
                }
                guard written > 0 else {
                    throw failure("write private session-state file: zero-byte write")
                }
                offset += written
            }
        }

        guard fchmod(descriptor, mode_t(0o600)) == 0, fsync(descriptor) == 0 else {
            throw failure("secure private session-state file: \(posixDescription())")
        }
        close(descriptor)
        descriptorOpen = false

        try verify(directory)
        if let existing = try openFile(in: directory, allowMissing: true) {
            close(existing)
        }
        let renamed = temporary.withCString { source in
            SessionStateStore.fileName.withCString { destination in
                renameat(directory.descriptor, source, directory.descriptor, destination)
            }
        }
        guard renamed == 0 else {
            throw failure("atomically persist private session state: \(posixDescription())")
        }
        temporaryExists = false
        guard fsync(directory.descriptor) == 0 else {
            throw failure("synchronize private session directory: \(posixDescription())")
        }
        try verify(directory)
    }

    func load(sessionID: String) throws -> Data? {
        guard let directory = try sessionDirectory(sessionID: sessionID, create: false) else {
            return nil
        }
        try verify(directory)
        guard let descriptor = try openFile(in: directory, allowMissing: true) else {
            return nil
        }
        defer { close(descriptor) }

        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                #if canImport(Darwin)
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
                #else
                Glibc.read(descriptor, bytes.baseAddress, bytes.count)
                #endif
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw failure("read private session state: \(posixDescription())")
            }
            guard count > 0 else { break }
            result.append(contentsOf: buffer.prefix(count))
        }
        try verify(directory)
        return result
    }

    func delete(sessionID: String) throws {
        guard let directory = try sessionDirectory(sessionID: sessionID, create: false) else {
            return
        }
        try verify(directory)
        try removeEntries(descriptor: directory.descriptor)
        try verify(directory)
        let removed = sessionID.withCString {
            unlinkat(directory.sessionsDescriptor, $0, AT_REMOVEDIR)
        }
        guard removed == 0 else {
            throw failure("remove private session directory: \(posixDescription())")
        }
        try verify(directory, requireSession: false)
    }

    private func sessionDirectory(sessionID: String, create: Bool) throws -> SessionDirectory? {
        guard root.isFileURL else {
            throw failure("session-state root must be a local file URL")
        }
        guard let rootDescriptor = try openRoot(create: create) else { return nil }
        var ownsRoot = true
        defer { if ownsRoot { close(rootDescriptor) } }

        guard let sessionsDescriptor = try openDirectory(
            named: "sessions",
            under: rootDescriptor,
            create: create
        ) else { return nil }
        var ownsSessions = true
        defer { if ownsSessions { close(sessionsDescriptor) } }

        guard let descriptor = try openDirectory(
            named: sessionID,
            under: sessionsDescriptor,
            create: create
        ) else { return nil }
        ownsRoot = false
        ownsSessions = false
        return SessionDirectory(
            rootDescriptor: rootDescriptor,
            sessionsDescriptor: sessionsDescriptor,
            descriptor: descriptor,
            root: root,
            sessionID: sessionID
        )
    }

    private func openRoot(create: Bool) throws -> Int32? {
        let anchor = "/".withCString { open($0, Self.directoryFlags) }
        guard anchor >= 0 else {
            throw failure("open filesystem root for session state: \(posixDescription())")
        }

        let components = root.path.split(separator: "/").map(String.init)
        var current = anchor
        var createdAncestor = false

        do {
            for (index, component) in components.enumerated() {
                let isApplicationRoot = index == components.count - 1
                var next = component.withCString { openat(current, $0, Self.directoryFlags) }

                if next < 0, errno == ENOENT {
                    guard create else {
                        close(current)
                        return nil
                    }
                    guard let created = try openDirectory(named: component, under: current, create: true) else {
                        throw failure("session-state root disappeared during creation")
                    }
                    next = created
                    createdAncestor = true
                } else if next < 0 {
                    var information = stat()
                    let inspected = component.withCString {
                        fstatat(current, $0, &information, AT_SYMLINK_NOFOLLOW)
                    }

                    // macOS exposes its temporary state root through trusted,
                    // root-owned /var and /tmp aliases. User-owned aliases can
                    // redirect application state and must never be followed.
                    guard inspected == 0,
                          information.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK),
                          information.st_uid == 0,
                          !isApplicationRoot,
                          !createdAncestor
                    else {
                        throw failure("session-state root contains an unsafe symlink or directory: \(component)")
                    }
                    next = component.withCString {
                        openat(current, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
                    }
                    guard next >= 0 else {
                        throw failure("open trusted system directory alias: \(posixDescription())")
                    }
                }

                if isApplicationRoot || createdAncestor {
                    do {
                        try secureDirectory(next, description: isApplicationRoot ? root.path : component)
                    } catch {
                        close(next)
                        throw error
                    }
                }
                close(current)
                current = next
            }

            if components.isEmpty {
                try secureDirectory(current, description: root.path)
            }
            return current
        } catch {
            close(current)
            throw error
        }
    }

    private func openDirectory(named component: String, under parent: Int32, create: Bool) throws -> Int32? {
        if create {
            let created = component.withCString { mkdirat(parent, $0, mode_t(0o700)) }
            if created != 0, errno != EEXIST {
                throw failure("create private session directory: \(posixDescription())")
            }
        }

        let descriptor = component.withCString { openat(parent, $0, Self.directoryFlags) }
        guard descriptor >= 0 else {
            if !create, errno == ENOENT { return nil }
            throw failure("session directory must be a real, non-symlink directory: \(posixDescription())")
        }
        do {
            try secureDirectory(descriptor, description: component)
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    private func secureDirectory(_ descriptor: Int32, description: String) throws {
        var information = stat()
        guard fstat(descriptor, &information) == 0 else {
            throw failure("inspect session directory: \(posixDescription())")
        }
        guard information.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              information.st_uid == geteuid()
        else {
            throw failure("session directory is not owned by the current user: \(description)")
        }

        let permissions = information.st_mode & mode_t(0o777)
        guard permissions & mode_t(0o022) == 0 else {
            throw failure("session directory is writable by another user: \(description)")
        }
        if permissions != mode_t(0o700), fchmod(descriptor, mode_t(0o700)) != 0 {
            throw failure("restrict session directory to its owner: \(posixDescription())")
        }
    }

    private func openFile(in directory: SessionDirectory, allowMissing: Bool) throws -> Int32? {
        let descriptor = SessionStateStore.fileName.withCString {
            openat(directory.descriptor, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            if allowMissing, errno == ENOENT { return nil }
            throw failure("session state must be a real, non-symlink file: \(posixDescription())")
        }

        do {
            var information = stat()
            guard fstat(descriptor, &information) == 0 else {
                throw failure("inspect session state: \(posixDescription())")
            }
            guard information.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  information.st_uid == geteuid(),
                  information.st_nlink == 1
            else {
                throw failure("session state must be an owned regular file without hard links")
            }

            let permissions = information.st_mode & mode_t(0o777)
            guard permissions & mode_t(0o022) == 0 else {
                throw failure("session state is writable by another user")
            }
            if permissions != mode_t(0o600), fchmod(descriptor, mode_t(0o600)) != 0 {
                throw failure("restrict session state to its owner: \(posixDescription())")
            }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    private func verify(_ directory: SessionDirectory, requireSession: Bool = true) throws {
        let observedRoot = directory.root.path.withCString { open($0, Self.directoryFlags) }
        guard observedRoot >= 0 else {
            throw failure("session-state root changed during its operation")
        }
        defer { close(observedRoot) }
        guard sameFile(directory.rootDescriptor, observedRoot) else {
            throw failure("session-state root changed during its operation")
        }

        let observedSessions = "sessions".withCString {
            openat(observedRoot, $0, Self.directoryFlags)
        }
        guard observedSessions >= 0 else {
            throw failure("session parent directory changed during its operation")
        }
        defer { close(observedSessions) }
        guard sameFile(directory.sessionsDescriptor, observedSessions) else {
            throw failure("session parent directory changed during its operation")
        }
        guard requireSession else { return }

        let observed = directory.sessionID.withCString {
            openat(observedSessions, $0, Self.directoryFlags)
        }
        guard observed >= 0 else {
            throw failure("session directory changed during its operation")
        }
        defer { close(observed) }
        guard sameFile(directory.descriptor, observed) else {
            throw failure("session directory changed during its operation")
        }
    }

    private func sameFile(_ first: Int32, _ second: Int32) -> Bool {
        var firstInformation = stat()
        var secondInformation = stat()
        return fstat(first, &firstInformation) == 0
            && fstat(second, &secondInformation) == 0
            && firstInformation.st_dev == secondInformation.st_dev
            && firstInformation.st_ino == secondInformation.st_ino
    }

    private func removeEntries(descriptor: Int32) throws {
        let duplicate = dup(descriptor)
        guard duplicate >= 0 else {
            throw failure("inspect private session directory: \(posixDescription())")
        }
        guard let stream = fdopendir(duplicate) else {
            close(duplicate)
            throw failure("inspect private session directory: \(posixDescription())")
        }
        defer { closedir(stream) }

        var entries: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 {
                    throw failure("inspect private session directory: \(posixDescription())")
                }
                break
            }
            var storage = entry.pointee.d_name
            let capacity = MemoryLayout.size(ofValue: storage)
            let name = withUnsafePointer(to: &storage) { pointer in
                pointer.withMemoryRebound(
                    to: CChar.self,
                    capacity: capacity
                ) { String(validatingCString: $0) }
            }
            guard let name else {
                throw failure("private session directory contains an invalid file name")
            }
            if name != ".", name != ".." {
                entries.append(name)
            }
        }

        for entry in entries {
            var information = stat()
            let inspected = entry.withCString {
                fstatat(descriptor, $0, &information, AT_SYMLINK_NOFOLLOW)
            }
            guard inspected == 0 else {
                throw failure("inspect private session entry: \(posixDescription())")
            }
            let kind = information.st_mode & mode_t(S_IFMT)
            if kind == mode_t(S_IFDIR) {
                guard let child = try openDirectory(named: entry, under: descriptor, create: false) else {
                    throw failure("private session entry disappeared")
                }
                defer { close(child) }
                try removeEntries(descriptor: child)
            } else {
                guard kind == mode_t(S_IFREG),
                      information.st_uid == geteuid(),
                      information.st_nlink == 1,
                      information.st_mode & mode_t(0o022) == 0
                else {
                    throw failure("session directory contains a symlink, hard link, or unsafe entry")
                }
                if entry == SessionStateStore.fileName,
                   let opened = try openFileDescriptor(named: entry, under: descriptor) {
                    close(opened)
                }
            }

            let flags: Int32 = kind == mode_t(S_IFDIR) ? AT_REMOVEDIR : 0
            let removed = entry.withCString { unlinkat(descriptor, $0, flags) }
            guard removed == 0 else {
                throw failure("remove private session entry: \(posixDescription())")
            }
        }
    }

    private func openFileDescriptor(named name: String, under parent: Int32) throws -> Int32? {
        let descriptor = name.withCString {
            openat(parent, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw failure("session state must be a real, non-symlink file: \(posixDescription())")
        }
        return descriptor
    }

    private func posixDescription() -> String {
        String(cString: strerror(errno))
    }
    #else
    func save(_ data: Data, sessionID: String) throws {
        throw failure("owner-private session-state persistence is unavailable on this platform")
    }

    func load(sessionID: String) throws -> Data? {
        throw failure("owner-private session-state persistence is unavailable on this platform")
    }

    func delete(sessionID: String) throws {
        throw failure("owner-private session-state persistence is unavailable on this platform")
    }
    #endif

    private func failure(_ detail: String) -> ShellSessionSupportError {
        .persistence(detail)
    }
}

public struct ManagedMcpConfig: Codable, Sendable, Hashable {
    public var name: String
    public var endpoint: String
    public var headers: [String: String]
    public var tokenExpiresAt: Date?
    public var scope: String?
    public var scopeID: String?
    public var scopeName: String?

    public init(name: String = "", endpoint: String, headers: [String: String] = [:], tokenExpiresAt: Date? = nil, scope: String? = nil, scopeID: String? = nil, scopeName: String? = nil) {
        self.name = name
        self.endpoint = endpoint
        self.headers = headers
        self.tokenExpiresAt = tokenExpiresAt
        self.scope = scope
        self.scopeID = scopeID
        self.scopeName = scopeName
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case endpoint
        case headers
        case tokenExpiresAt = "token_expires_at"
        case scope
        case scopeID = "scope_id"
        case scopeName = "scope_name"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        endpoint = try container.decode(String.self, forKey: .endpoint)
        headers = try container.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        tokenExpiresAt = try container.decodeIfPresent(Date.self, forKey: .tokenExpiresAt)
        scope = try container.decodeIfPresent(String.self, forKey: .scope)
        scopeID = try container.decodeIfPresent(String.self, forKey: .scopeID)
        scopeName = try container.decodeIfPresent(String.self, forKey: .scopeName)
    }
}

public struct GatewayToolCallRequest: Codable, Sendable, Hashable {
    public var callID: String
    public var arguments: JSONValue

    public init(callID: String, arguments: JSONValue = .object([:])) {
        self.callID = callID
        self.arguments = arguments.isNull ? .object([:]) : arguments
    }

    private enum CodingKeys: String, CodingKey {
        case callID = "call_id"
        case arguments
    }
}

public struct GatewayToolCallResponse: Codable, Sendable, Hashable {
    public var result: JSONValue
    public var connectorsNeedingReauth: [String]

    public init(result: JSONValue, connectorsNeedingReauth: [String] = []) {
        self.result = result
        self.connectorsNeedingReauth = connectorsNeedingReauth
    }

    private enum CodingKeys: String, CodingKey {
        case result
        case connectorsNeedingReauth = "connectors_needing_reauth"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        result = try container.decode(JSONValue.self, forKey: .result)
        connectorsNeedingReauth = try container.decodeIfPresent([String].self, forKey: .connectorsNeedingReauth) ?? []
    }
}

public struct GatewayTool: Codable, Sendable, Hashable {
    public var connectorID: String
    public var connectorName: String
    public var toolID: String
    public var toolName: String
    public var callID: String
    public var description: String
    public var jsonSchema: JSONValue

    public init(connectorID: String, connectorName: String, toolID: String, toolName: String, callID: String, description: String, jsonSchema: JSONValue) {
        self.connectorID = connectorID
        self.connectorName = connectorName
        self.toolID = toolID
        self.toolName = toolName
        self.callID = callID
        self.description = description
        self.jsonSchema = jsonSchema
    }

    public var qualifiedName: String { "\(connectorID)__\(toolID)" }

    private enum CodingKeys: String, CodingKey {
        case connectorID = "connector_id"
        case connectorName = "connector_name"
        case toolID = "tool_id"
        case toolName = "tool_name"
        case callID = "call_id"
        case description
        case jsonSchema = "json_schema"
    }
}

public struct GatewayToolCatalog: Codable, Sendable, Hashable {
    public var tools: [GatewayTool]
    public var totalTools: UInt32
    public var connectorsNeedingReauth: [String]

    public init(tools: [GatewayTool] = [], totalTools: UInt32 = 0, connectorsNeedingReauth: [String] = []) {
        self.tools = tools
        self.totalTools = totalTools
        self.connectorsNeedingReauth = connectorsNeedingReauth
    }

    private enum CodingKeys: String, CodingKey {
        case tools
        case totalTools = "total_tools"
        case connectorsNeedingReauth = "connectors_needing_reauth"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tools = try container.decodeIfPresent([GatewayTool].self, forKey: .tools) ?? []
        totalTools = try container.decodeIfPresent(UInt32.self, forKey: .totalTools) ?? 0
        connectorsNeedingReauth = try container.decodeIfPresent([String].self, forKey: .connectorsNeedingReauth) ?? []
    }
}

public enum ManagedMcpFetchError: Error, Sendable, Equatable {
    case status(code: Int, message: String)
    case transport(String)
    case noAuth
    case invalidResponse(String)
}

public enum ManagedMcpCacheState: Sendable, Hashable {
    case notFetched
    case fetching
    case ready([ManagedMcpConfig])
}

private enum ManagedMcpFetchClaim: Sendable {
    case ready([ManagedMcpConfig])
    case fetch(UInt64)
    case wait
}

public enum GatewayToolCatalogCacheState: Sendable, Hashable {
    case notFetched
    case fetching(epoch: UInt64)
    case ready(GatewayToolCatalog)
}

public struct ManagedMcpStateSnapshot: Sendable, Hashable {
    public let cache: ManagedMcpCacheState
    public let gatewayToolsActive: Bool
    public let gatewayToolEpoch: UInt64
    public let gatewayToolCache: GatewayToolCatalogCacheState
    public let connectorsSeen: Set<String>

    public init(cache: ManagedMcpCacheState, gatewayToolsActive: Bool, gatewayToolEpoch: UInt64, gatewayToolCache: GatewayToolCatalogCacheState, connectorsSeen: Set<String>) {
        self.cache = cache
        self.gatewayToolsActive = gatewayToolsActive
        self.gatewayToolEpoch = gatewayToolEpoch
        self.gatewayToolCache = gatewayToolCache
        self.connectorsSeen = connectorsSeen
    }
}

public actor ManagedMcpState {
    public static let managedMcpPrefix = "grok_com_"
    public static let managedMcpNameMaxCharacters = 39
    public static let tokenExpiryBufferMinutes: Int64 = 5
    public static let maxReactiveReauthAttempts: UInt32 = 3

    private var cache: ManagedMcpCacheState = .notFetched
    private var gatewayToolsActive = false
    private var gatewayToolEpoch: UInt64 = 0
    private var gatewayToolCache: GatewayToolCatalogCacheState = .notFetched
    private var connectorsSeen = Set<String>()
    private var reauthFailures: [String: (count: UInt32, nextAllowedAt: Date)] = [:]
    private var managedFetchGeneration: UInt64 = 0
    private var managedFetchWaiters: [CheckedContinuation<Void, Never>] = []
    private var gatewayFetchWaiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func snapshot() -> ManagedMcpStateSnapshot {
        ManagedMcpStateSnapshot(cache: cache, gatewayToolsActive: gatewayToolsActive, gatewayToolEpoch: gatewayToolEpoch, gatewayToolCache: gatewayToolCache, connectorsSeen: connectorsSeen)
    }

    public func completeFetch(_ configs: [ManagedMcpConfig]) {
        if case .fetching = cache {
            _ = finishManagedFetch(configs, generation: managedFetchGeneration)
        } else {
            cache = .ready(configs)
        }
    }

    public func failFetch() {
        cache = .notFetched
        resumeManagedFetchWaiters()
    }

    public func invalidateCache() {
        cache = .notFetched
        resumeManagedFetchWaiters()
        gatewayToolEpoch = gatewayToolEpoch &+ 1
        gatewayToolCache = .notFetched
        resumeGatewayFetchWaiters()
    }

    public func invalidateGatewayToolCache() {
        gatewayToolEpoch = gatewayToolEpoch &+ 1
        gatewayToolCache = .notFetched
        resumeGatewayFetchWaiters()
    }

    public func enableGatewayTools() -> UInt64 {
        if !gatewayToolsActive { gatewayToolEpoch = gatewayToolEpoch &+ 1 }
        gatewayToolsActive = true
        return gatewayToolEpoch
    }

    public func startGatewayToolFetch() -> UInt64? {
        guard gatewayToolsActive else { return nil }
        if case .fetching(let epoch) = gatewayToolCache { return epoch }
        gatewayToolCache = .fetching(epoch: gatewayToolEpoch)
        return gatewayToolEpoch
    }

    public func completeGatewayToolFetch(epoch: UInt64, catalog: GatewayToolCatalog) -> Bool {
        guard gatewayToolsActive,
              gatewayToolEpoch == epoch,
              case .fetching(let activeEpoch) = gatewayToolCache,
              activeEpoch == epoch else { return false }
        connectorsSeen.formUnion(catalog.tools.map(\.connectorID))
        gatewayToolCache = .ready(catalog)
        resumeGatewayFetchWaiters()
        return true
    }

    public func failGatewayToolFetch(epoch: UInt64) {
        guard case .fetching(let currentEpoch) = gatewayToolCache, currentEpoch == epoch else { return }
        gatewayToolCache = .notFetched
        resumeGatewayFetchWaiters()
    }

    public func disableGatewayTools() {
        gatewayToolsActive = false
        gatewayToolEpoch = gatewayToolEpoch &+ 1
        gatewayToolCache = .notFetched
        resumeGatewayFetchWaiters()
    }

    private func claimManagedFetch() -> ManagedMcpFetchClaim {
        switch cache {
        case .ready(let configs):
            return .ready(configs)
        case .fetching:
            return .wait
        case .notFetched:
            managedFetchGeneration = managedFetchGeneration &+ 1
            cache = .fetching
            return .fetch(managedFetchGeneration)
        }
    }

    private func waitForManagedFetch() async {
        guard case .fetching = cache else { return }
        await withCheckedContinuation { continuation in
            managedFetchWaiters.append(continuation)
        }
    }

    private func finishManagedFetch(_ configs: [ManagedMcpConfig], generation: UInt64) -> Bool {
        guard generation == managedFetchGeneration, case .fetching = cache else { return false }
        cache = .ready(configs)
        resumeManagedFetchWaiters()
        return true
    }

    private func failManagedFetch(generation: UInt64) {
        guard generation == managedFetchGeneration, case .fetching = cache else { return }
        cache = .notFetched
        resumeManagedFetchWaiters()
    }

    private func resumeManagedFetchWaiters() {
        let waiters = managedFetchWaiters
        managedFetchWaiters.removeAll(keepingCapacity: true)
        for waiter in waiters { waiter.resume() }
    }

    private func waitForGatewayFetch() async {
        guard case .fetching = gatewayToolCache else { return }
        await withCheckedContinuation { continuation in
            gatewayFetchWaiters.append(continuation)
        }
    }

    private func resumeGatewayFetchWaiters() {
        let waiters = gatewayFetchWaiters
        gatewayFetchWaiters.removeAll(keepingCapacity: true)
        for waiter in waiters { waiter.resume() }
    }

    public func reauthAllowed(server: String, now: Date) -> Bool {
        guard let state = reauthFailures[server] else { return true }
        return state.count < Self.maxReactiveReauthAttempts && now >= state.nextAllowedAt
    }

    public func recordReauthFailure(server: String, now: Date) {
        let oldCount = reauthFailures[server]?.count ?? 0
        let count = oldCount.saturatingAdd(1)
        let backoff = min(UInt64(64), UInt64(2).saturatingPower(count))
        reauthFailures[server] = (count, now.addingTimeInterval(TimeInterval(backoff)))
    }

    public func reauthIsTerminal(server: String) -> Bool {
        (reauthFailures[server]?.count ?? 0) >= Self.maxReactiveReauthAttempts
    }

    public func recordReauthSuccess(server: String) {
        reauthFailures.removeValue(forKey: server)
    }

    public func clearReauthCooldowns() {
        reauthFailures.removeAll()
    }

    public static func normalizeURL(_ url: String) -> String {
        var result = url
        while result.last == "/" { result.removeLast() }
        return result
    }

    public static func toManagedName(_ displayName: String) -> String {
        let normalized = displayName.lowercased().replacingOccurrences(of: " ", with: "_")
        return String((managedMcpPrefix + normalized).prefix(managedMcpNameMaxCharacters))
    }

    public static func managedTokenIsStale(expiresAt: Date?, now: Date) -> Bool {
        guard let expiresAt else { return true }
        return now > expiresAt.addingTimeInterval(-TimeInterval(tokenExpiryBufferMinutes * 60))
    }

    public static func shouldInjectManagedAuth(serverName: String, serverURL: String, managed: [ManagedMcpConfig]) -> Bool {
        serverName.hasPrefix(managedMcpPrefix) && managed.contains { normalizeURL($0.endpoint) == normalizeURL(serverURL) }
    }

    public static func injectedHeaders(serverName: String, serverURL: String, existing: [String: String], managed: [ManagedMcpConfig]) -> [String: String] {
        guard serverName.hasPrefix(managedMcpPrefix) else { return existing }
        let normalizedURL = normalizeURL(serverURL)
        let scope = existing.first { key, _ in key.caseInsensitiveCompare("x-connector-scope") == .orderedSame }?.value
        let scopeID = existing.first { key, _ in key.caseInsensitiveCompare("x-connector-scope-id") == .orderedSame }?.value
        let config: ManagedMcpConfig?
        if let scope, let scopeID {
            config = managed.first {
                normalizeURL($0.endpoint) == normalizedURL && $0.scope == scope && $0.scopeID == scopeID
            }
        } else {
            config = managed.first { normalizeURL($0.endpoint) == normalizedURL }
        }
        guard let config, !config.headers.isEmpty else { return existing }
        var result = existing
        result = result.filter { key, _ in
            !config.headers.keys.contains(where: { $0.caseInsensitiveCompare(key) == .orderedSame }) &&
            key.caseInsensitiveCompare("x-connector-scope") != .orderedSame &&
            key.caseInsensitiveCompare("x-connector-scope-id") != .orderedSame
        }
        for (key, value) in config.headers { result[key] = value }
        return result
    }
}

public typealias ManagedMCPState = ManagedMcpState

public protocol ManagedMcpFetcher: Sendable {
    func fetchManagedConfigs(proxyBaseURL: URL, authKey: String) async throws -> [ManagedMcpConfig]
    func fetchGatewayToolCatalog(proxyBaseURL: URL, authKey: String) async throws -> GatewayToolCatalog
    func callGatewayTool(proxyBaseURL: URL, authKey: String, request: GatewayToolCallRequest) async throws -> GatewayToolCallResponse
}

public func fetchManagedConfigs(proxyBaseURL: URL, authKey: String) async throws -> [ManagedMcpConfig] {
    try await URLSessionManagedMcpFetcher().fetchManagedConfigs(proxyBaseURL: proxyBaseURL, authKey: authKey)
}

public func fetchGatewayToolCatalog(proxyBaseURL: URL, authKey: String) async throws -> GatewayToolCatalog {
    try await URLSessionManagedMcpFetcher().fetchGatewayToolCatalog(proxyBaseURL: proxyBaseURL, authKey: authKey)
}

public func callGatewayTool(
    proxyBaseURL: URL,
    authKey: String,
    callID: String,
    arguments: JSONValue = .object([:])
) async throws -> GatewayToolCallResponse {
    try await URLSessionManagedMcpFetcher().callGatewayTool(
        proxyBaseURL: proxyBaseURL,
        authKey: authKey,
        request: GatewayToolCallRequest(callID: callID, arguments: arguments)
    )
}

public struct URLSessionManagedMcpFetcher: ManagedMcpFetcher, Sendable {
    public init() {}

    public func fetchManagedConfigs(proxyBaseURL: URL, authKey: String) async throws -> [ManagedMcpConfig] {
        let response: ManagedMcpConfigResponse = try await request(path: "mcp/configs", proxyBaseURL: proxyBaseURL, authKey: authKey, method: "GET", body: nil)
        return response.mcpServers
    }

    public func fetchGatewayToolCatalog(proxyBaseURL: URL, authKey: String) async throws -> GatewayToolCatalog {
        try await request(path: "mcp/tools/list", proxyBaseURL: proxyBaseURL, authKey: authKey, method: "GET", body: nil)
    }

    public func callGatewayTool(proxyBaseURL: URL, authKey: String, request: GatewayToolCallRequest) async throws -> GatewayToolCallResponse {
        let body = try JSONEncoder().encode(request)
        return try await self.request(path: "mcp/tools/call", proxyBaseURL: proxyBaseURL, authKey: authKey, method: "POST", body: body)
    }

    private func request<T: Decodable>(path: String, proxyBaseURL: URL, authKey: String, method: String, body: Data?) async throws -> T {
        var request = URLRequest(url: proxyBaseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = method == "POST" ? 75 : 10
        request.setValue("Bearer \(authKey)", forHTTPHeaderField: "Authorization")
        request.setValue("xai-grok-cli", forHTTPHeaderField: "X-XAI-Token-Auth")
        request.setValue(OpenGrokVersion.compiledVersion, forHTTPHeaderField: "x-grok-client-version")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.httpBody = body
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw ManagedMcpFetchError.invalidResponse("not an HTTP response") }
            guard (200..<300).contains(http.statusCode) else {
                let message = (try? JSONDecoder().decode(ManagedMcpErrorBody.self, from: data).error) ?? "HTTP \(http.statusCode)"
                throw ManagedMcpFetchError.status(code: http.statusCode, message: message)
            }
            do {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                return try decoder.decode(T.self, from: data)
            } catch {
                throw ManagedMcpFetchError.invalidResponse(error.localizedDescription)
            }
        } catch let error as ManagedMcpFetchError {
            throw error
        } catch {
            throw ManagedMcpFetchError.transport(error.localizedDescription)
        }
    }
}

public extension ManagedMcpState {
    func getOrFetchManagedConfigs(
        proxyBaseURL: URL,
        authKey: String?,
        fetcher: any ManagedMcpFetcher
    ) async -> [ManagedMcpConfig] {
        while true {
            switch await claimManagedFetch() {
            case .ready(let configs):
                return configs
            case .wait:
                await waitForManagedFetch()
            case .fetch(let generation):
                guard let authKey else {
                    await failManagedFetch(generation: generation)
                    return []
                }
                do {
                    let configs = try await fetcher.fetchManagedConfigs(proxyBaseURL: proxyBaseURL, authKey: authKey)
                    _ = await finishManagedFetch(configs, generation: generation)
                    return configs
                } catch {
                    await failManagedFetch(generation: generation)
                    return []
                }
            }
        }
    }

    func getOrFetchGatewayToolCatalog(
        proxyBaseURL: URL,
        authKey: String?,
        fetcher: any ManagedMcpFetcher
    ) async -> GatewayToolCatalog? {
        while true {
            let state = await snapshot()
            guard state.gatewayToolsActive else { return nil }
            switch state.gatewayToolCache {
            case .ready(let catalog):
                return catalog
            case .fetching:
                await waitForGatewayFetch()
            case .notFetched:
                guard let epoch = await startGatewayToolFetch() else { return nil }
                guard let authKey else {
                    await failGatewayToolFetch(epoch: epoch)
                    return nil
                }
                do {
                    let catalog = try await fetcher.fetchGatewayToolCatalog(proxyBaseURL: proxyBaseURL, authKey: authKey)
                    return await completeGatewayToolFetch(epoch: epoch, catalog: catalog) ? catalog : nil
                } catch {
                    await failGatewayToolFetch(epoch: epoch)
                    return nil
                }
            }
        }
    }
}

private struct ManagedMcpConfigResponse: Decodable {
    let mcpServers: [ManagedMcpConfig]

    enum CodingKeys: String, CodingKey {
        case mcpServers = "mcp_servers"
    }
}

private struct ManagedMcpErrorBody: Decodable {
    let error: String?
}

private extension JSONValue {
    var uint64Value: UInt64? {
        switch self {
        case .number(let value): return value.uint64Value
        case .string(let value): return UInt64(value)
        default: return nil
        }
    }
}

private extension String {
    func prefixUTF8Bytes(_ count: Int) -> Substring {
        guard count > 0 else { return Substring() }
        var bytes = 0
        var end = startIndex
        while end < endIndex {
            let next = self.index(after: end)
            let cost = self[end].utf8.count
            if bytes + cost > count { break }
            bytes += cost
            end = next
        }
        return self[..<end]
    }
}

private extension UInt64 {
    func saturatingAdd(_ value: UInt64) -> UInt64 {
        let result = addingReportingOverflow(value)
        return result.overflow ? .max : result.partialValue
    }

    func saturatingPower(_ exponent: UInt32) -> UInt64 {
        var result: UInt64 = 1
        for _ in 0..<exponent {
            let next = result.multipliedReportingOverflow(by: self)
            if next.overflow { return .max }
            result = next.partialValue
        }
        return result
    }
}

private extension UInt32 {
    func saturatingAdd(_ value: UInt32) -> UInt32 {
        let result = addingReportingOverflow(value)
        return result.overflow ? .max : result.partialValue
    }
}

private func validateSessionPathComponent(_ value: String) throws {
    guard !value.isEmpty else {
        throw ShellSessionSupportError.invalidSession("session id is empty")
    }
    guard value != ".", value != ".." else {
        throw ShellSessionSupportError.invalidSession("session id is not a safe path component")
    }
    guard !value.contains(where: { character in
        character == "/" || character == "\\" || character == ":" || character.isWhitespace
    }) else {
        throw ShellSessionSupportError.invalidSession("session id is not a safe path component")
    }
    guard !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
        throw ShellSessionSupportError.invalidSession("session id contains a control character")
    }
}
