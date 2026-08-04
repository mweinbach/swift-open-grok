import Foundation
import OpenGrokHooksPluginTypes

public enum HookGateKind: String, Sendable, Equatable, Codable {
    case observe
    case tool
    case stop
}

public enum HookMatcherPolicy: String, Sendable, Equatable, Codable {
    case tested
    case ignored
}

public extension HookEvent {
    static let runtimeOrder: [HookEvent] = [
        .sessionStart,
        .preToolUse,
        .postToolUse,
        .postToolUseFailure,
        .sessionEnd,
        .stop,
        .stopFailure,
        .notification,
        .userPromptSubmit,
        .permissionDenied,
        .subagentStart,
        .subagentStop,
        .preCompact,
        .postCompact
    ]

    init?(hookKey: String) {
        switch hookKey {
        case "SessionStart", "session_start", "sessionStart": self = .sessionStart
        case "PreToolUse", "pre_tool_use", "preToolUse", "beforeShellExecution", "beforeMCPExecution", "beforeReadFile": self = .preToolUse
        case "PostToolUse", "post_tool_use", "postToolUse", "afterShellExecution", "afterMCPExecution", "afterFileEdit", "afterAgentResponse", "afterAgentThought": self = .postToolUse
        case "PostToolUseFailure", "post_tool_use_failure", "postToolUseFailure": self = .postToolUseFailure
        case "SessionEnd", "session_end", "sessionEnd": self = .sessionEnd
        case "Stop", "stop": self = .stop
        case "StopFailure", "stop_failure", "stopFailure": self = .stopFailure
        case "Notification", "notification": self = .notification
        case "UserPromptSubmit", "user_prompt_submit", "userPromptSubmit", "beforeSubmitPrompt": self = .userPromptSubmit
        case "PermissionDenied", "permission_denied", "permissionDenied": self = .permissionDenied
        case "SubagentStart", "subagent_start", "subagentStart": self = .subagentStart
        case "SubagentStop", "subagent_stop", "subagentStop", "SubagentEnd", "subagent_end", "subagentEnd": self = .subagentStop
        case "PreCompact", "pre_compact", "preCompact": self = .preCompact
        case "PostCompact", "post_compact", "postCompact": self = .postCompact
        default: return nil
        }
    }

    var runtimeWireName: String {
        switch self {
        case .sessionStart: return "session_start"
        case .preToolUse: return "pre_tool_use"
        case .postToolUse: return "post_tool_use"
        case .postToolUseFailure: return "post_tool_use_failure"
        case .sessionEnd: return "session_end"
        case .stop: return "stop"
        case .stopFailure: return "stop_failure"
        case .notification: return "notification"
        case .userPromptSubmit: return "user_prompt_submit"
        case .permissionDenied: return "permission_denied"
        case .subagentStart: return "subagent_start"
        case .subagentStop: return "subagent_stop"
        case .preCompact: return "pre_compact"
        case .postCompact: return "post_compact"
        }
    }

    var gateKind: HookGateKind {
        switch self {
        case .preToolUse: return .tool
        case .stop, .subagentStop: return .stop
        default: return .observe
        }
    }

    var matcherPolicy: HookMatcherPolicy {
        switch self {
        case .stop, .subagentStop, .userPromptSubmit: return .ignored
        default: return .tested
        }
    }
}

public enum HookJSONValue: Sendable, Equatable, Hashable, Codable {
    case null
    case boolean(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([HookJSONValue])
    case object([String: HookJSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([HookJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: HookJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .boolean(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }
}

public struct HookEventEnvelope: Sendable, Equatable, Codable {
    public var hookEventName: HookEvent
    public var sessionId: String
    public var cwd: String
    public var workspaceRoot: String
    public var timestamp: String
    public var transcriptPath: String?
    public var clientIdentifier: String?
    public var promptId: String?
    public var permissionMode: String?
    public var payload: [String: HookJSONValue]

    public init(
        hookEventName: HookEvent,
        sessionId: String,
        cwd: String,
        workspaceRoot: String,
        timestamp: String = ISO8601DateFormatter().string(from: Date()),
        transcriptPath: String? = nil,
        clientIdentifier: String? = nil,
        promptId: String? = nil,
        permissionMode: String? = nil,
        payload: [String: HookJSONValue] = [:]
    ) {
        self.hookEventName = hookEventName
        self.sessionId = sessionId
        self.cwd = cwd
        self.workspaceRoot = workspaceRoot
        self.timestamp = timestamp
        self.transcriptPath = transcriptPath
        self.clientIdentifier = clientIdentifier
        self.promptId = promptId
        self.permissionMode = permissionMode
        self.payload = payload
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public var matchValue: String? {
        let keys = ["toolName", "notificationType", "subagentType", "source", "reason", "error"]
        for key in keys where payload[key]?.stringValue?.isEmpty == false {
            return payload[key]?.stringValue
        }
        return nil
    }

    private enum CodingKeys: String, CodingKey {
        case hookEventName, sessionId, cwd, workspaceRoot, timestamp
        case transcriptPath, clientIdentifier, promptId, permissionMode
    }

    private struct DynamicCodingKey: CodingKey {
        var stringValue: String
        var intValue: Int?
        init?(stringValue: String) { self.stringValue = stringValue; self.intValue = nil }
        init?(intValue: Int) { self.stringValue = String(intValue); self.intValue = intValue }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        try container.encode(hookEventName.runtimeWireName, forKey: DynamicCodingKey(stringValue: "hookEventName")!)
        try container.encode(sessionId, forKey: DynamicCodingKey(stringValue: "sessionId")!)
        try container.encode(cwd, forKey: DynamicCodingKey(stringValue: "cwd")!)
        try container.encode(workspaceRoot, forKey: DynamicCodingKey(stringValue: "workspaceRoot")!)
        try container.encode(timestamp, forKey: DynamicCodingKey(stringValue: "timestamp")!)
        if let transcriptPath { try container.encode(transcriptPath, forKey: DynamicCodingKey(stringValue: "transcriptPath")!) }
        if let clientIdentifier { try container.encode(clientIdentifier, forKey: DynamicCodingKey(stringValue: "clientIdentifier")!) }
        if let promptId { try container.encode(promptId, forKey: DynamicCodingKey(stringValue: "promptId")!) }
        if let permissionMode { try container.encode(permissionMode, forKey: DynamicCodingKey(stringValue: "permissionMode")!) }
        for (key, value) in payload where CodingKeys(stringValue: key) == nil {
            guard let codingKey = DynamicCodingKey(stringValue: key) else { continue }
            try container.encode(value, forKey: codingKey)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        func value(_ key: String) throws -> HookJSONValue? {
            guard let codingKey = DynamicCodingKey(stringValue: key) else { return nil }
            return try container.decodeIfPresent(HookJSONValue.self, forKey: codingKey)
        }
        guard let eventValue = try value("hookEventName")?.stringValue,
              let event = HookEvent(hookKey: eventValue) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "missing or invalid hookEventName"))
        }
        func string(_ key: String) throws -> String? { try value(key)?.stringValue }
        hookEventName = event
        sessionId = try string("sessionId") ?? ""
        cwd = try string("cwd") ?? ""
        workspaceRoot = try string("workspaceRoot") ?? ""
        timestamp = try string("timestamp") ?? ""
        transcriptPath = try string("transcriptPath")
        clientIdentifier = try string("clientIdentifier")
        promptId = try string("promptId")
        permissionMode = try string("permissionMode")
        let reserved = Set(["hookEventName", "sessionId", "cwd", "workspaceRoot", "timestamp", "transcriptPath", "clientIdentifier", "promptId", "permissionMode"])
        var decodedPayload: [String: HookJSONValue] = [:]
        for key in container.allKeys where !reserved.contains(key.stringValue) {
            decodedPayload[key.stringValue] = try container.decode(HookJSONValue.self, forKey: key)
        }
        payload = decodedPayload
    }
}

public enum HookSourceKind: String, Sendable, Equatable, Codable {
    case file
    case systemManaged
    case managed
    case requirements
    case user
    case plugin
    case unknown
}

public struct HookSpec: Sendable, Equatable {
    public var name: String
    public var event: HookEvent
    public var handlerType: HookHandlerType
    public var configuredMatcher: String?
    public var matcher: HookMatcher?
    public var enabled: Bool
    public var command: String?
    public var commandRaw: String?
    public var url: String?
    public var urlRaw: String?
    public var timeoutMs: UInt64
    public var sourceDirectory: URL
    public var extraEnvironment: [String: String]
    public var sourceKind: HookSourceKind

    public init(
        name: String,
        event: HookEvent,
        handlerType: HookHandlerType,
        configuredMatcher: String? = nil,
        matcher: HookMatcher? = nil,
        enabled: Bool = true,
        command: String? = nil,
        commandRaw: String? = nil,
        url: String? = nil,
        urlRaw: String? = nil,
        timeoutMs: UInt64,
        sourceDirectory: URL,
        extraEnvironment: [String: String] = [:],
        sourceKind: HookSourceKind = .file
    ) {
        self.name = name
        self.event = event
        self.handlerType = handlerType
        self.configuredMatcher = configuredMatcher
        self.matcher = matcher
        self.enabled = enabled
        self.command = command
        self.commandRaw = commandRaw
        self.url = url
        self.urlRaw = urlRaw
        self.timeoutMs = timeoutMs
        self.sourceDirectory = sourceDirectory
        self.extraEnvironment = extraEnvironment
        self.sourceKind = sourceKind
    }

    public func info(disabled: Bool = false) -> HookInfo {
        HookInfo(
            name: name,
            event: event,
            handlerType: handlerType,
            matcher: configuredMatcher,
            command: commandRaw,
            url: urlRaw,
            timeoutMs: timeoutMs,
            sourceDir: sourceDirectory.path,
            disabled: disabled || !enabled
        )
    }
}

public enum HookError: Error, Sendable, Equatable, CustomStringConvertible {
    case readFile(path: URL, detail: String)
    case parseFile(path: URL, detail: String)
    case invalidMatcher(name: String, path: URL, detail: String)
    case invalidConfiguration(name: String, path: URL, detail: String)
    case unsupportedHandler(name: String, path: URL, handler: String)
    case commandNotFound(name: String, path: URL)
    case timeout(name: String, elapsedMs: UInt64)
    case commandFailed(name: String, detail: String)
    case invalidOutput(name: String, detail: String)

    public var description: String {
        switch self {
        case .readFile(let path, let detail): return "failed to read hook file \(path.path): \(detail)"
        case .parseFile(let path, let detail): return "failed to parse hook file \(path.path): \(detail)"
        case .invalidMatcher(let name, let path, let detail): return "hook \(name) in \(path.path): invalid matcher: \(detail)"
        case .invalidConfiguration(let name, let path, let detail): return "hook \(name) in \(path.path): \(detail)"
        case .unsupportedHandler(let name, let path, let handler): return "hook \(name) in \(path.path): unsupported handler type '\(handler)'"
        case .commandNotFound(let name, let path): return "hook \(name) command not found: \(path.path)"
        case .timeout(let name, let elapsedMs): return "hook \(name) timed out after \(elapsedMs)ms"
        case .commandFailed(let name, let detail): return "hook \(name) command failed: \(detail)"
        case .invalidOutput(let name, let detail): return "hook \(name) produced invalid output: \(detail)"
        }
    }
}
