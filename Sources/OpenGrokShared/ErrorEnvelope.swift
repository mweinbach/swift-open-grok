// ErrorEnvelope.swift
//
// A structured error envelope that preserves a machine-readable code, a
// user-facing message, a retryability flag, and structured details — without
// relying on NSError identity. This is the Swift equivalent of the
// thiserror/anyhow error patterns used across the Rust crates, consolidated
// into one Sendable Codable envelope for cross-boundary propagation.
//
// W0-S4 acceptance: "Error envelopes preserve machine code, user message,
// retryability, and structured details without relying on NSError identity."

import Foundation

/// A structured, Sendable, Codable error envelope for cross-boundary
/// propagation.
///
/// `ErrorEnvelope` is designed to be:
/// - **Machine-readable**: the `code` field is a stable string identifier
///   that callers switch on (never localized, never user-facing).
/// - **User-facing**: the `message` field is a human-readable description
///   suitable for display.
/// - **Retry-aware**: the `retryable` flag tells callers whether the
///   operation can be retried (transient failures) or not (permanent
///   failures like permission denials).
/// - **Detailed**: the `details` dictionary carries structured context
///   (HTTP status, provider name, tool name, path, etc.) as `JSONValue`
///   so it survives Codable round-trips.
/// - **NSError-independent**: the envelope does not bridge to or rely on
///   `NSError` identity; two envelopes with the same fields are equal.
public struct ErrorEnvelope: Error, Hashable, Sendable, Codable {
    /// A stable, machine-readable error code (e.g. `"permission_denied"`,
    /// `"provider_unavailable"`, `"sandbox_violation"`).
    public var code: String

    /// A human-readable message suitable for display to the end user.
    public var message: String

    /// `true` when the operation can be retried (transient failure);
    /// `false` when it is permanent (e.g. permission denied, invalid input).
    public var retryable: Bool

    /// Structured details as arbitrary JSON values. Keys are stable
    /// machine-readable strings; values are `JSONValue` for lossless
    /// round-tripping.
    public var details: [String: JSONValue]

    /// An optional correlation/request identifier.
    public var requestID: String?

    /// An optional cause chain (nested envelope for wrapped errors).
    ///
    /// Uses an indirect enum to break the value-type size recursion that
    /// would occur if `ErrorEnvelope` directly contained another
    /// `ErrorEnvelope`. The `indirect` keyword tells the compiler to box
    /// the associated value, giving `ErrorCause` a fixed size.
    public var cause: ErrorCause?

    /// Create an error envelope.
    public init(
        code: String,
        message: String,
        retryable: Bool = false,
        details: [String: JSONValue] = [:],
        requestID: String? = nil,
        cause: ErrorCause? = nil
    ) {
        self.code = code
        self.message = message
        self.retryable = retryable
        self.details = details
        self.requestID = requestID
        self.cause = cause
    }

    // MARK: CodingKeys

    private enum CodingKeys: String, CodingKey {
        case code
        case message
        case retryable
        case details
        case requestID
        case cause
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decode(String.self, forKey: .code)
        message = try container.decode(String.self, forKey: .message)
        retryable = try container.decodeIfPresent(Bool.self, forKey: .retryable) ?? false
        details = try container.decodeIfPresent([String: JSONValue].self, forKey: .details) ?? [:]
        requestID = try container.decodeIfPresent(String.self, forKey: .requestID)
        cause = try container.decodeIfPresent(ErrorCause.self, forKey: .cause)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(code, forKey: .code)
        try container.encode(message, forKey: .message)
        // Only encode retryable when true (matches Rust skip_serializing_if).
        if retryable {
            try container.encode(retryable, forKey: .retryable)
        }
        if !details.isEmpty {
            try container.encode(details, forKey: .details)
        }
        try container.encodeIfPresent(requestID, forKey: .requestID)
        try container.encodeIfPresent(cause, forKey: .cause)
    }

    // MARK: Convenience constructors

    /// Create a permanent (non-retryable) error.
    public static func permanent(
        code: String,
        message: String,
        details: [String: JSONValue] = [:],
        requestID: String? = nil
    ) -> ErrorEnvelope {
        ErrorEnvelope(code: code, message: message, retryable: false, details: details, requestID: requestID)
    }

    /// Create a transient (retryable) error.
    public static func transient(
        code: String,
        message: String,
        details: [String: JSONValue] = [:],
        requestID: String? = nil
    ) -> ErrorEnvelope {
        ErrorEnvelope(code: code, message: message, retryable: true, details: details, requestID: requestID)
    }

    /// Add a detail and return self for chaining.
    @discardableResult
    public func withDetail(_ key: String, _ value: JSONValue) -> ErrorEnvelope {
        var copy = self
        copy.details[key] = value
        return copy
    }

    /// Add a detail as a Codable value and return self for chaining.
    @discardableResult
    public func withDetail<T: Encodable>(_ key: String, _ value: T) -> ErrorEnvelope {
        var copy = self
        if let jsonValue = try? JSONValue.encode(value) {
            copy.details[key] = jsonValue
        }
        return copy
    }
}

/// A wrapper for a nested `ErrorEnvelope` cause.
///
/// Uses Swift's `indirect enum` to break the value-type size recursion
/// that would occur if `ErrorEnvelope` directly stored another
/// `ErrorEnvelope`. The `indirect` keyword tells the compiler to box
/// the associated value behind a reference, giving `ErrorCause` a fixed
/// memory size regardless of nesting depth.
public indirect enum ErrorCause: Hashable, Sendable, Codable {
    /// A wrapped error envelope.
    case envelope(ErrorEnvelope)

    /// The wrapped envelope, if this cause is `.envelope`.
    public var envelopeValue: ErrorEnvelope? {
        if case .envelope(let env) = self { return env }
        return nil
    }

    public init(from decoder: Decoder) throws {
        let env = try ErrorEnvelope(from: decoder)
        self = .envelope(env)
    }

    public func encode(to encoder: Encoder) throws {
        guard case .envelope(let env) = self else { return }
        try env.encode(to: encoder)
    }
}

// MARK: - Common error codes

/// Stable machine-readable error codes used across Open Grok boundaries.
///
/// These are the Swift equivalents of the most common error categories in
/// the Rust codebase. Specific subsystems may define additional codes; the
/// ones here are the cross-cutting defaults.
public enum OpenGrokErrorCode {
    public static let permissionDenied = "permission_denied"
    public static let sandboxViolation = "sandbox_violation"
    public static let providerUnavailable = "provider_unavailable"
    public static let providerAuthExpired = "provider_auth_expired"
    public static let providerRateLimited = "provider_rate_limited"
    public static let networkTimeout = "network_timeout"
    public static let networkUnreachable = "network_unreachable"
    public static let invalidInput = "invalid_input"
    public static let notFound = "not_found"
    public static let alreadyExists = "already_exists"
    public static let cancelled = "cancelled"
    public static let unsupported = "unsupported"
    public static let persistenceCorrupted = "persistence_corrupted"
    public static let persistenceMigrationFailed = "persistence_migration_failed"
    public static let toolExecutionFailed = "tool_execution_failed"
    public static let toolTimeout = "tool_timeout"
    public static let sessionNotFound = "session_not_found"
    public static let sessionClosed = "session_closed"
    public static let configurationInvalid = "configuration_invalid"
    public static let clipboardUnavailable = "clipboard_unavailable"
    public static let placeholderImageInvalid = "placeholder_image_invalid"
}

// MARK: - LocalizedError conformance

extension ErrorEnvelope: LocalizedError {
    public var errorDescription: String? {
        message
    }

    public var failureReason: String? {
        if let cause = cause, let env = cause.envelopeValue {
            return env.message
        }
        return nil
    }
}
