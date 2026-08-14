// Events.swift
//
// Outbound events and serializable error mirrors for the sampler.
// Mirrors Rust `events.rs`.

import Foundation
import OpenGrokSamplingTypes
import OpenGrokShared

// MARK: - Channel

/// Which content channel a token belongs to.
public enum SamplingChannel: String, Codable, Sendable, Equatable, Hashable {
    case text
    case reasoning
}

// MARK: - Error kind

/// Coarse-grained classification of a sampling failure.
public enum SamplingErrorKind: String, Codable, Sendable, Equatable, Hashable {
    case auth
    case http
    case api
    case serialization
    case idleTimeout = "idle_timeout"
    case rateLimited = "rate_limited"
    case emptyResponse = "empty_response"
    case maxTokensTruncation = "max_tokens_truncation"
    case doomLoopDetected = "doom_loop_detected"

    /// Stable lowercase string for telemetry tags.
    public var asString: String {
        switch self {
        case .auth: return "auth"
        case .http: return "http"
        case .api: return "api"
        case .serialization: return "serialization"
        case .idleTimeout: return "idle_timeout"
        case .rateLimited: return "rate_limited"
        case .emptyResponse: return "empty_response"
        case .maxTokensTruncation: return "max_tokens_truncation"
        case .doomLoopDetected: return "doom_loop_detected"
        }
    }
}

// MARK: - Error info

/// Serializable mirror of ``SamplingError`` for UI / event channels.
public struct SamplingErrorInfo: Codable, Sendable, Equatable, Error {
    public var kind: SamplingErrorKind
    public var statusCode: UInt16?
    public var message: String
    public var isRetryable: Bool
    public var retryAfterSecs: UInt64?
    public var modelMetadata: ResponseModelMetadata?
    public var credential: SentCredential?
    public var emptyResponseContext: EmptyResponseContext?
    public var doomLoopTriggers: [String]?
    public var doomLoopAbortedAtChunk: UInt64?
    public var errorCode: String?

    public init(
        kind: SamplingErrorKind,
        statusCode: UInt16? = nil,
        message: String,
        isRetryable: Bool,
        retryAfterSecs: UInt64? = nil,
        modelMetadata: ResponseModelMetadata? = nil,
        credential: SentCredential? = nil,
        emptyResponseContext: EmptyResponseContext? = nil,
        doomLoopTriggers: [String]? = nil,
        doomLoopAbortedAtChunk: UInt64? = nil,
        errorCode: String? = nil
    ) {
        self.kind = kind
        self.statusCode = statusCode
        self.message = message
        self.isRetryable = isRetryable
        self.retryAfterSecs = retryAfterSecs
        self.modelMetadata = modelMetadata
        self.credential = credential
        self.emptyResponseContext = emptyResponseContext
        self.doomLoopTriggers = doomLoopTriggers
        self.doomLoopAbortedAtChunk = doomLoopAbortedAtChunk
        self.errorCode = errorCode
    }

    public enum CodingKeys: String, CodingKey {
        case kind
        case statusCode = "status_code"
        case message
        case isRetryable = "is_retryable"
        case retryAfterSecs = "retry_after_secs"
        case modelMetadata = "model_metadata"
        case credential
        case emptyResponseContext = "empty_response_context"
        case doomLoopTriggers = "doom_loop_triggers"
        case doomLoopAbortedAtChunk = "doom_loop_aborted_at_chunk"
        case errorCode = "error_code"
    }

    /// Build from a rich ``SamplingError``.
    public init(from error: SamplingError) {
        let isRetryable = error.isRetryable
        let message = error.displayMessage
        switch error {
        case .auth(_, let credential):
            self.init(
                kind: .auth,
                message: message,
                isRetryable: isRetryable,
                credential: credential
            )
        case .invalidConfiguration:
            self.init(kind: .api, message: message, isRetryable: isRetryable)
        case .http:
            self.init(kind: .http, message: message, isRetryable: isRetryable)
        case .serialization:
            self.init(kind: .serialization, message: message, isRetryable: isRetryable)
        case .api(let status, _, let modelMetadata, let retryAfterSecs, _, let errorCode):
            let kind: SamplingErrorKind = error.isRateLimited ? .rateLimited : .api
            self.init(
                kind: kind,
                statusCode: UInt16(clamping: status.code),
                message: message,
                isRetryable: isRetryable,
                retryAfterSecs: retryAfterSecs,
                modelMetadata: modelMetadata,
                errorCode: errorCode
            )
        case .eventStreamError:
            self.init(kind: .http, message: message, isRetryable: isRetryable)
        case .streamError(let errorType, _, let code):
            self.init(kind: .api, message: message, isRetryable: isRetryable, errorCode: code ?? errorType)
        case .idleTimeout:
            self.init(kind: .idleTimeout, message: message, isRetryable: isRetryable)
        case .emptyResponse(let context):
            self.init(
                kind: .emptyResponse,
                message: message,
                isRetryable: isRetryable,
                emptyResponseContext: context
            )
        case .maxTokensTruncation:
            self.init(kind: .maxTokensTruncation, message: message, isRetryable: isRetryable)
        case .doomLoopDetected(let triggers, let abortedAtChunk):
            self.init(
                kind: .doomLoopDetected,
                message: message,
                isRetryable: isRetryable,
                doomLoopTriggers: triggers,
                doomLoopAbortedAtChunk: abortedAtChunk
            )
        }
    }
}

// MARK: - SamplingEvent

/// Events emitted by the sampler for a single in-flight request.
public enum SamplingEvent: Sendable, Equatable {
    /// HTTP stream established, headers read. Emitted before any content.
    case streamStarted(requestId: RequestId, timestampMs: Int64)

    /// First content token received for a request.
    case firstToken(requestId: RequestId)

    /// Content token in a named channel (text or reasoning).
    case channelToken(requestId: RequestId, channel: SamplingChannel, text: String, chunkIndex: UInt64)

    /// Streaming delta carrying a fragment of a tool call.
    case toolCallDelta(
        requestId: RequestId,
        toolIndex: UInt32,
        id: String?,
        name: String?,
        argumentsDelta: String?
    )

    /// Streaming completed successfully.
    case completed(
        requestId: RequestId,
        response: ConversationResponse,
        metrics: InferenceLatencyStats
    )

    /// Request is being retried.
    case retrying(
        requestId: RequestId,
        attempt: UInt32,
        maxRetries: UInt32,
        kind: SamplingErrorKind,
        reason: String,
        doomLoopTriggers: [String]?,
        doomLoopAbortedAtChunk: UInt64?
    )

    /// Request failed (after exhausting retries or non-retryable error).
    case failed(requestId: RequestId, error: SamplingErrorInfo)

    /// Model metadata received from response headers.
    case modelMetadata(requestId: RequestId, metadata: ResponseModelMetadata)

    /// A backend-hosted tool call has started execution on the server.
    case backendToolCallStarted(requestId: RequestId, callId: String, name: String)

    /// A backend-hosted tool call has completed execution on the server.
    case backendToolCallCompleted(
        requestId: RequestId,
        callId: String,
        name: String,
        result: JSONValue?
    )
}

// MARK: - SamplingError display helpers

extension SamplingError {
    /// Human-readable display string matching the Rust Display impl surface.
    public var displayMessage: String {
        switch self {
        case .auth(let msg, _):
            return "authentication error: \(msg)"
        case .invalidConfiguration(let msg):
            return "invalid configuration: \(msg)"
        case .http(let msg):
            return "http error: \(msg)"
        case .serialization(let msg):
            return "\(Self.serializationDisplayPrefix)\(msg)"
        case .api(let status, let message, _, _, _, _):
            return "API error (\(status.code)): \(message)"
        case .eventStreamError(let msg):
            return "event stream error: \(msg)"
        case .streamError(let errorType, let message, _):
            return "stream error (\(errorType)): \(message)"
        case .idleTimeout(let elapsedSecs):
            return "idle timeout after \(elapsedSecs)s"
        case .emptyResponse(let context):
            return "empty response (\(context.reason.asString))"
        case .maxTokensTruncation:
            return "max tokens truncation"
        case .doomLoopDetected(let triggers, _):
            return "doom loop detected: \(triggers.joined(separator: ","))"
        }
    }

    /// Connection-reset / broken-pipe during body upload often means nginx
    /// rejected an oversized payload. Heuristic used by the retry loop.
    public var isLikelyBodyRejected: Bool {
        if case .http(let msg) = self {
            let lower = msg.lowercased()
            let bodyLike =
                lower.contains("broken pipe")
                || lower.contains("connection reset")
                || lower.contains("connection was lost")
                || lower.contains("body")
                || lower.contains("write")
            let excluded = lower.contains("timeout") || lower.contains("connect")
            return bodyLike && !excluded
        }
        return false
    }
}

extension StopReason {
    /// Stable snake_case wire form.
    public var asString: String {
        switch self {
        case .stop: return "stop"
        case .length: return "length"
        case .toolCalls: return "tool_calls"
        case .contentFilter: return "content_filter"
        }
    }
}
