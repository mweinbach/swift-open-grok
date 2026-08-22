import Foundation
import OpenGrokShared

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum SessionEventPhase: String, Codable, Sendable, Equatable {
    case waitingForModel = "waiting_for_model"
    case streamingText = "streaming_text"
    case streamingReasoning = "streaming_reasoning"
    case toolExecution = "tool_execution"
    case permissionPrompt = "permission_prompt"
}

public enum SessionEventRelationship: String, Codable, Sendable, Equatable {
    case primary
    case subagent
}

public enum SessionEventTurnOutcome: String, Codable, Sendable, Equatable {
    case completed
    case cancelled
    case error
}

public enum SessionEventToolOutcome: String, Codable, Sendable, Equatable {
    case success
    case error
    case permissionRejected = "permission_rejected"
    case permissionCancelled = "permission_cancelled"
    case followup
    case hookDenied = "hook_denied"
    case invalidTool = "invalid_tool"
    case cancelled
}

public enum SessionEventPermissionDecision: String, Codable, Sendable, Equatable {
    case allow
    case deny
    case cancelled
    case followup
}

public enum SessionEventCancellationCategory: String, Codable, Sendable, Equatable {
    case hookDenied = "hook_denied"
    case permissionRejected = "permission_rejected"
    case permissionCancelled = "permission_cancelled"
    case midTurnAbort = "mid_turn_abort"
}

public enum SessionEventRedirectKind: String, Codable, Sendable, Equatable {
    case interjection
    case cancelThenSend = "cancel_then_send"
    case queuedAfterCancel = "queued_after_cancel"
}

public enum SessionEventInterjectionSource: String, Codable, Sendable, Equatable {
    case direct
    case queue
}

public enum SessionEventToolSource: String, Codable, Sendable, Equatable {
    case shell
    case workspace
}

public enum SessionEventMCPErrorCategory: String, Codable, Sendable, Equatable {
    case spawnFailed = "spawn_failed"
    case timeout
    case handshakeFailed = "handshake_failed"
    case authRequired = "auth_required"
    case clientError = "client_error"
}

public enum SessionEventLogEvent: Sendable, Equatable {
    public static let schemaVersion = "1.0"

    case turnStarted(
        sessionID: String,
        turnNumber: UInt64,
        modelID: String,
        yoloMode: Bool,
        conversationMessageCount: Int,
        relationship: SessionEventRelationship,
        redirectKind: SessionEventRedirectKind?
    )
    case phaseChanged(SessionEventPhase)
    case firstToken
    case loopStarted(UInt32)
    case toolStarted(toolName: String)
    case toolCompleted(
        toolName: String,
        durationMilliseconds: UInt64,
        outcome: SessionEventToolOutcome,
        toolCallID: String,
        source: SessionEventToolSource
    )
    case permissionRequested(toolName: String)
    case permissionResolved(
        toolName: String,
        decision: SessionEventPermissionDecision,
        waitMilliseconds: UInt64
    )
    case turnEnded(
        outcome: SessionEventTurnOutcome,
        cancellationCategory: SessionEventCancellationCategory?,
        cancellationContext: JSONValue?
    )
    case interjected(source: SessionEventInterjectionSource, imageCount: UInt32)
    case yoloToggled(enabled: Bool)
    case mcpServerConnected(
        serverName: String,
        transport: String,
        toolCount: UInt32,
        durationMilliseconds: UInt64,
        tools: [String]
    )
    case mcpServerFailed(
        serverName: String,
        transport: String?,
        errorType: SessionEventMCPErrorCategory,
        errorMessage: String,
        durationMilliseconds: UInt64?,
        target: String?,
        timeoutSeconds: UInt64?
    )
    case mcpToolCallStarted(
        serverName: String,
        toolName: String,
        callID: String,
        timeoutSeconds: UInt64
    )
    case mcpToolCallCompleted(
        serverName: String,
        toolName: String,
        callID: String,
        durationMilliseconds: UInt64,
        success: Bool,
        isTimeout: Bool,
        error: String?,
        reconnectAttempted: Bool,
        authRetryAttempted: Bool
    )

    public var fields: [String: JSONValue] {
        var values: [String: JSONValue]

        switch self {
        case let .turnStarted(
            sessionID, turnNumber, modelID, yoloMode, messageCount, relationship, redirect
        ):
            values = [
                "type": .string("turn_started"),
                "session_id": .string(sessionID),
                "turn_number": .number(.uint64(turnNumber)),
                "model_id": .string(modelID),
                "yolo_mode": .bool(yoloMode),
                "conversation_message_count": .number(.uint64(UInt64(max(0, messageCount)))),
                "session_relationship": .string(relationship.rawValue),
                "schema_version": .string(Self.schemaVersion),
            ]
            if let redirect { values["redirect_kind"] = .string(redirect.rawValue) }

        case .phaseChanged(let phase):
            values = ["type": .string("phase_changed"), "phase": .string(phase.rawValue)]

        case .firstToken:
            values = ["type": .string("first_token")]

        case .loopStarted(let loopIndex):
            values = [
                "type": .string("loop_started"),
                "loop_index": .number(.uint64(UInt64(loopIndex))),
            ]

        case .toolStarted(let name):
            values = ["type": .string("tool_started"), "tool_name": .string(name)]

        case let .toolCompleted(name, duration, outcome, callID, source):
            values = [
                "type": .string("tool_completed"),
                "tool_name": .string(name),
                "duration_ms": .number(.uint64(duration)),
                "outcome": .string(outcome.rawValue),
            ]
            if !callID.isEmpty { values["tool_call_id"] = .string(callID) }
            if source != .shell { values["source"] = .string(source.rawValue) }

        case .permissionRequested(let name):
            values = ["type": .string("permission_requested"), "tool_name": .string(name)]

        case let .permissionResolved(name, decision, wait):
            values = [
                "type": .string("permission_resolved"),
                "tool_name": .string(name),
                "decision": .string(decision.rawValue),
                "wait_ms": .number(.uint64(wait)),
            ]

        case let .turnEnded(outcome, category, context):
            values = ["type": .string("turn_ended"), "outcome": .string(outcome.rawValue)]
            if let category {
                values["cancellation_category"] = .string(category.rawValue)
            }
            if let context { values["cancellation_context"] = context }

        case let .interjected(source, imageCount):
            values = [
                "type": .string("interjected"),
                "source": .string(source.rawValue),
                "image_count": .number(.uint64(UInt64(imageCount))),
                "redirect_kind": .string(SessionEventRedirectKind.interjection.rawValue),
            ]

        case .yoloToggled(let enabled):
            values = ["type": .string("yolo_toggled"), "enabled": .bool(enabled)]

        case let .mcpServerConnected(name, transport, count, duration, tools):
            values = [
                "type": .string("mcp_server_connected"),
                "server_name": .string(name),
                "transport": .string(transport),
                "tool_count": .number(.uint64(UInt64(count))),
                "duration_ms": .number(.uint64(duration)),
                "tools": .array(tools.map(JSONValue.string)),
            ]

        case let .mcpServerFailed(name, transport, category, message, duration, target, timeout):
            values = [
                "type": .string("mcp_server_failed"),
                "server_name": .string(name),
                "error_type": .string(category.rawValue),
                "error_message": .string(message),
            ]
            if let transport { values["transport"] = .string(transport) }
            if let duration { values["duration_ms"] = .number(.uint64(duration)) }
            if let target { values["target"] = .string(target) }
            if let timeout { values["timeout_sec"] = .number(.uint64(timeout)) }

        case let .mcpToolCallStarted(server, tool, callID, timeout):
            values = [
                "type": .string("mcp_tool_call_started"),
                "server_name": .string(server),
                "tool_name": .string(tool),
                "call_id": .string(callID),
                "timeout_sec": .number(.uint64(timeout)),
            ]

        case let .mcpToolCallCompleted(
            server, tool, callID, duration, success, isTimeout, error, reconnected, authRetried
        ):
            values = [
                "type": .string("mcp_tool_call_completed"),
                "server_name": .string(server),
                "tool_name": .string(tool),
                "call_id": .string(callID),
                "duration_ms": .number(.uint64(duration)),
                "success": .bool(success),
                "is_timeout": .bool(isTimeout),
                "reconnect_attempted": .bool(reconnected),
                "auth_retry_attempted": .bool(authRetried),
            ]
            if let error { values["error"] = .string(error) }
        }

        return values
    }
}

public enum SessionEventLogError: Error, LocalizedError, Sendable, Equatable {
    case invalidDirectory(String)
    case openFailed(String)
    case unsafeFile(String)
    case writeFailed(String)
    case recordTooLarge(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidDirectory(let path):
            return "session event directory is unavailable: \(path)"
        case .openFailed(let detail):
            return "failed to open session event log: \(detail)"
        case .unsafeFile(let path):
            return "session event log is not an owner-private regular file: \(path)"
        case .writeFailed(let detail):
            return "failed to append session event: \(detail)"
        case .recordTooLarge(let bytes):
            return "session event exceeds the 65536-byte limit: \(bytes)"
        }
    }
}

public final class SessionEventLog: @unchecked Sendable {
    public static let fileName = "events.jsonl"
    public static let maximumRecordBytes = 65_536

    public let fileURL: URL
    private let lock = NSLock()
    private let descriptor: Int32
    private let clock: @Sendable () -> Date
    private let formatter: ISO8601DateFormatter
    private let onFirstFailure: @Sendable (SessionEventLogError) -> Void
    private var recordedFailure: SessionEventLogError?

    public init(
        sessionDirectory: URL,
        clock: @escaping @Sendable () -> Date = Date.init,
        onFirstFailure: @escaping @Sendable (SessionEventLogError) -> Void = { _ in }
    ) throws {
        let directory = sessionDirectory.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { throw SessionEventLogError.invalidDirectory(directory.path) }

        let path = directory.appendingPathComponent(Self.fileName)
        let opened = path.path.withCString {
            open($0, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        }
        guard opened >= 0 else {
            throw SessionEventLogError.openFailed(String(cString: strerror(errno)))
        }

        var attributes = stat()
        guard fstat(opened, &attributes) == 0,
              (attributes.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              attributes.st_uid == geteuid(),
              fchmod(opened, mode_t(0o600)) == 0
        else {
            close(opened)
            throw SessionEventLogError.unsafeFile(path.path)
        }

        self.fileURL = path
        self.descriptor = opened
        self.clock = clock
        self.onFirstFailure = onFirstFailure
        self.formatter = ISO8601DateFormatter()
        self.formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.formatter.timeZone = TimeZone(secondsFromGMT: 0)
    }

    deinit {
        close(descriptor)
    }

    public var firstFailure: SessionEventLogError? {
        lock.lock()
        defer { lock.unlock() }
        return recordedFailure
    }

    @discardableResult
    public func emit(_ event: SessionEventLogEvent) -> Bool {
        lock.lock()
        var fields = event.fields
        fields["ts"] = .string(formatter.string(from: clock()))

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            var bytes = try encoder.encode(JSONValue.object(fields))
            bytes.append(0x0A)
            guard bytes.count <= Self.maximumRecordBytes else {
                throw SessionEventLogError.recordTooLarge(bytes.count)
            }
            try Self.writeAll(bytes, descriptor: descriptor)
            lock.unlock()
            return true
        } catch {
            let failure = (error as? SessionEventLogError)
                ?? .writeFailed(String(describing: error))
            let shouldReport = recordedFailure == nil
            if shouldReport { recordedFailure = failure }
            lock.unlock()
            if shouldReport { onFirstFailure(failure) }
            return false
        }
    }

    private static func writeAll(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var written = 0
            while written < buffer.count {
                let count = write(descriptor, base.advanced(by: written), buffer.count - written)
                if count > 0 {
                    written += count
                } else if count < 0 && errno == EINTR {
                    continue
                } else {
                    throw SessionEventLogError.writeFailed(String(cString: strerror(errno)))
                }
            }
        }
    }
}
