// SamplingError.swift
//
// Open Grok — Swift port of the sampling error types in
// `crates/codegen/xai-grok-sampling-types/src/error.rs`.
//
// These are the provider-neutral error variants the sampler (W3-S3) and
// session runtime (W7-S1) consume. The HTTP-specific variants carry an
// HTTP status code and structured metadata so retryability, auth-error
// classification, and context-length detection can branch without re-parsing
// the wire body.

import Foundation
import OpenGrokShared

/// Provenance of the credential presented on an authentication failure.
/// Kept in the dependency-neutral sampling-types target so retry policy and
/// transport layers can share it without creating a target cycle.
public enum SentCredential: String, Sendable, Hashable, Codable {
    case sent
    case missing
    case unknown

    public static let `default`: SentCredential = .unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SentCredential(rawValue: raw) ?? .unknown
    }

    public static func fromSentFragment(_ fragment: String?) -> SentCredential {
        fragment == nil ? .missing : .sent
    }

    public var isMissing: Bool { self == .missing }
    public var isUnknown: Bool { self == .unknown }
}

/// Why the model's response was classified as "empty".
public enum EmptyReason: String, Codable, Sendable, Equatable, Hashable {
    /// The model emitted reasoning tokens but produced no visible content
    /// and no tool calls. The stream completed normally.
    case reasoningOnly
    /// The stream carried at least one `choice` but the final assistant
    /// message has empty `content` and no tool calls.
    case noVisibleContent

    public var asString: String { rawValue }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw {
        case "reasoning_only": self = .reasoningOnly
        case "no_visible_content": self = .noVisibleContent
        default:
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "unknown EmptyReason: \(raw)")
        }
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .reasoningOnly: try container.encode("reasoning_only")
        case .noVisibleContent: try container.encode("no_visible_content")
        }
    }
}

extension EmptyReason: CustomStringConvertible {
    public var description: String { asString }
}

/// Structured context captured at L2 stream completion time when the response
/// is classified as empty.
public struct EmptyResponseContext: Codable, Sendable, Equatable, Hashable {
    public var reason: EmptyReason
    public var hadReasoning: Bool
    public var contentLen: Int
    public var toolCallCount: Int
    public var finishReason: String?
    public var completionTokens: UInt32?
    public var reasoningTokens: UInt32?
    public var promptTokens: UInt32?
    public var model: String
    public var firstChoiceSeen: Bool

    public init(
        reason: EmptyReason,
        hadReasoning: Bool,
        contentLen: Int,
        toolCallCount: Int,
        finishReason: String?,
        completionTokens: UInt32?,
        reasoningTokens: UInt32?,
        promptTokens: UInt32?,
        model: String,
        firstChoiceSeen: Bool
    ) {
        self.reason = reason
        self.hadReasoning = hadReasoning
        self.contentLen = contentLen
        self.toolCallCount = toolCallCount
        self.finishReason = finishReason
        self.completionTokens = completionTokens
        self.reasoningTokens = reasoningTokens
        self.promptTokens = promptTokens
        self.model = model
        self.firstChoiceSeen = firstChoiceSeen
    }

    public var finishReasonStr: String { finishReason ?? "none" }
}

/// Model metadata from response headers.
public struct ResponseModelMetadata: Codable, Sendable, Equatable, Hashable {
    public var contextWindow: UInt64?
    public var maxCompletionTokens: UInt32?
    /// `x-models-etag` — triggers model catalog refresh when changed.
    public var modelsEtag: String?

    public init(contextWindow: UInt64? = nil, maxCompletionTokens: UInt32? = nil, modelsEtag: String? = nil) {
        self.contextWindow = contextWindow
        self.maxCompletionTokens = maxCompletionTokens
        self.modelsEtag = modelsEtag
    }
}

/// HTTP status code, carried on `SamplingError.api` so retryability and
/// auth classification can branch without re-parsing the wire body.
public struct HTTPStatus: Sendable, Equatable, Hashable {
    public let code: Int

    public init(_ code: Int) { self.code = code }

    public var isClientError: Bool { (400..<500).contains(code) }
    public var isServerError: Bool { (500..<600).contains(code) }
    public var isUnauthorized: Bool { code == 401 }
    public var isForbidden: Bool { code == 403 }
    public var isTooManyRequests: Bool { code == 429 }
    public var isPayloadTooLarge: Bool { code == 413 }
    public var isBadRequest: Bool { code == 400 }
    public var isBadGateway: Bool { code == 502 }
}

/// Sampling error variants.
public enum SamplingError: Error, Sendable, Equatable {
    case auth(String, credential: SentCredential)
    case invalidConfiguration(String)
    case http(String)
    case serialization(String)
    case api(
        status: HTTPStatus,
        message: String,
        modelMetadata: ResponseModelMetadata?,
        retryAfterSecs: UInt64?,
        shouldRetry: Bool?
    )
    case eventStreamError(String)
    case streamError(errorType: String, message: String)
    case idleTimeout(elapsedSecs: UInt64)
    case emptyResponse(context: EmptyResponseContext)
    case maxTokensTruncation
    case doomLoopDetected(triggers: [String], abortedAtChunk: UInt64?)

    /// Display prefix of `.serialization`. Shared with the variant's render
    /// template so `serializationFromRendered` can never drift.
    public static let serializationDisplayPrefix = "serialization error: "

    /// Compatibility constructor for callers that do not have wire provenance.
    public static func auth(_ message: String) -> Self {
        .auth(message, credential: .unknown)
    }

    /// Rebuild a `.serialization` error from a rendered message.
    public static func serializationMessage(_ msg: String) -> Self {
        .serialization(msg)
    }

    /// Rebuild from this variant's full rendered Display, stripping the
    /// Display prefix so the rebuilt error does not render it twice.
    public static func serializationFromRendered(_ rendered: String) -> Self {
        if rendered.hasPrefix(serializationDisplayPrefix) {
            return .serialization(String(rendered.dropFirst(serializationDisplayPrefix.count)))
        }
        return .serialization(rendered)
    }

    public var isAuthError: Bool {
        switch self {
        case .auth(_, _): return true
        case .api(let status, _, _, _, _): return status.isUnauthorized
        default: return false
        }
    }

    public var isRateLimited: Bool {
        if case .api(let status, _, _, _, _) = self { return status.isTooManyRequests }
        return false
    }

    public var isPayloadTooLarge: Bool {
        if case .api(let status, _, _, _, _) = self { return status.isPayloadTooLarge }
        return false
    }

    /// The server rejected the request because the conversation history
    /// contains `encrypted_content` from a different model family. Never
    /// retryable.
    public var isEncryptedContentError: Bool {
        if case .api(let status, let message, _, _, _) = self {
            return status.isBadRequest && message.contains("encrypted_content")
        }
        return false
    }

    /// The API rejected the request because an inline image could not be
    /// processed. Matches both direct 400 and proxy-wrapped 500 responses.
    public var isImageProcessingError: Bool {
        if case .api(let status, let message, _, _, _) = self {
            let isMatchedStatus = status.code == 400 || status.code == 500
            return isMatchedStatus && (
                message.contains("Could not process image") ||
                isCodexInvalidImageURLError(message)
            )
        }
        return false
    }

    public var isRetryable: Bool {
        switch self {
        case .auth(_, _): return false
        case .invalidConfiguration: return false
        case .http: return true  // mirrors is_retryable_reqwest for request/body errors
        case .serialization: return false
        case .api(let status, _, _, _, _):
            return [429, 500, 502, 503, 504, 520].contains(status.code)
        case .eventStreamError: return true
        case .streamError: return true
        case .idleTimeout: return false
        case .emptyResponse: return true
        case .maxTokensTruncation: return false
        case .doomLoopDetected: return true
        }
    }

    public var modelMetadata: ResponseModelMetadata? {
        if case .api(_, _, let metadata, _, _) = self { return metadata }
        return nil
    }

    public var retryAfter: UInt64? {
        if case .api(_, _, _, let retryAfterSecs, _) = self { return retryAfterSecs }
        return nil
    }

    public var shouldRetryHeader: Bool? {
        if case .api(_, _, _, _, let shouldRetry) = self { return shouldRetry }
        return nil
    }

    /// True when this error is a context-window/size overflow —
    /// deterministic, so retrying the same payload can't help.
    public var isContextLengthError: Bool {
        switch self {
        case .api(_, let message, _, _, _): return OpenGrokSamplingTypes.isContextLengthError(message)
        case .streamError(_, let message): return OpenGrokSamplingTypes.isContextLengthError(message)
        default: return false
        }
    }
}

/// Codex/OpenAI Responses: `Invalid '…image_url'. Expected a base64-encoded
/// data URL…` (invalid base64, missing image MIME, or similar).
private func isCodexInvalidImageURLError(_ message: String) -> Bool {
    let lower = message.lowercased()
    let mentionsImageURL = lower.contains("image_url") || lower.contains("input_image")
    let invalid = lower.contains("invalid") &&
        (lower.contains("base64") || lower.contains("data url") ||
         lower.contains("data-url") || lower.contains("mime"))
    return mentionsImageURL && invalid
}

/// Max chars of a structured (JSON) error message shown to users.
public let MAX_USER_ERROR_BODY_CHARS = 280

/// Short status-based copy when the body is not a structured JSON error.
public func statusUserMessage(_ status: HTTPStatus) -> String {
    switch status.code {
    case 502...504:
        return "Grok is temporarily unavailable. Please try again in a moment. (HTTP \(status.code))."
    case 520...524:
        return "Connection to Grok timed out or was interrupted. Please try again. (HTTP \(status.code))."
    default:
        if status.isServerError {
            return "Something went wrong on the server (HTTP \(status.code))."
        }
        return "Request failed (HTTP \(status.code))."
    }
}

/// Truncate to `MAX_USER_ERROR_BODY_CHARS` chars, appending the ellipsis if
/// cut (char-based, like the Python `text[:n]`).
private func truncateUserError(_ s: String) -> String {
    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
    let count = trimmed.count
    if count <= MAX_USER_ERROR_BODY_CHARS { return trimmed }
    return String(trimmed.prefix(MAX_USER_ERROR_BODY_CHARS)) + "\u{2026}"
}

/// Format a known JSON error envelope; `nil` if the body is not structured.
private func structuredErrorMessage(_ bytes: Data) -> String? {
    guard let text = String(data: bytes, encoding: .utf8) else { return nil }
    guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) else {
        return nil
    }
    // OpenAI-standard: {"error": {"message": "...", "type": "..."}}
    if let error = value["error"] {
        let errorType = error["type"]?.stringValue ?? "unknown"
        let message = error["message"]?.stringValue ?? "unknown error"
        let msg = (errorType == "unknown" || errorType == "server_error") ? message : "\(errorType): \(message)"
        return truncateUserError(msg)
    }
    // Flat Grok proxy/gateway: {"code": "...", "error": "..."}
    if let flatError = value["error"]?.stringValue {
        let code = value["code"]?.stringValue ?? "server_error"
        return truncateUserError("\(code): \(flatError)")
    }
    return nil
}

/// Parse an API error body into a short string.
public func parseErrorBytes(_ bytes: Data) -> String {
    structuredErrorMessage(bytes) ?? "upstream error"
}

/// User-facing message for a failed API call.
public func userFacingAPIMessage(status: HTTPStatus, bytes: Data) -> String {
    structuredErrorMessage(bytes) ?? statusUserMessage(status)
}

/// Try to parse a server-side stream error from a raw JSON payload. Returns
/// `nil` if the payload is not a structured error envelope.
public func tryParseStreamError(_ data: String) -> SamplingError? {
    guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(data.utf8)) else {
        return nil
    }
    // OpenAI-standard envelope.
    if let error = value["error"] {
        let errorType = error["type"]?.stringValue ?? "unknown"
        let message = error["message"]?.stringValue ?? "unknown error"
        return .streamError(errorType: errorType, message: message)
    }
    // Flat Grok proxy/gateway envelope.
    if let flatError = value["error"]?.stringValue {
        let code = value["code"]?.stringValue ?? "server_error"
        return .streamError(errorType: code, message: flatError)
    }
    return nil
}

/// True when an error message indicates a context-window overflow.
public func isContextLengthError(_ message: String) -> Bool {
    let m = message.lowercased()
    return m.contains("too long for this model")
        || m.contains("prompt is too long")
        || m.contains("maximum prompt length")
        || m.contains("maximum context length")
        || m.contains("context_length_exceeded")
}
