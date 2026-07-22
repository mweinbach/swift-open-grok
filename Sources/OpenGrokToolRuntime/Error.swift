// Error.swift
//
// Open Grok — Swift port of `xai-tool-runtime/src/error.rs`.

import Foundation
import OpenGrokShared
import OpenGrokToolProtocol

/// Discriminator for tool errors.
public enum ToolErrorKind: String, Codable, Sendable, Hashable {
    case notImplemented = "not_implemented"
    case invalidArguments = "invalid_arguments"
    case notFound = "not_found"
    case permissionDenied = "permission_denied"
    case unauthorized
    case timeout
    case cancelled
    case rateLimited = "rate_limited"
    case usagePoolExhausted = "usage_pool_exhausted"
    case usageLimitReached = "usage_limit_reached"
    case globalRateLimit = "global_rate_limit"
    case concurrencyLimit = "concurrency_limit"
    case serviceUnavailable = "service_unavailable"
    case networkError = "network_error"
    case execution
    case behaviorVersionUnsupported = "behavior_version_unsupported"
    case renderLimited = "render_limited"
    case terminalError = "terminal_error"
    case custom

    /// Snake-case identifier for metrics / logs.
    public var asStr: String { rawValue }
}

/// Cross-ecosystem error type for tool execution.
///
/// Every error carries:
/// - `kind` — the machine-readable discriminator
/// - `detail` — the model/user-facing message that tools MUST provide
/// - `details` — optional structured metadata
public struct ToolError: Error, Codable, Sendable, Hashable, CustomStringConvertible {
    public var kind: ToolErrorKind
    /// Human-readable message provided by the tool. Sent back to the model.
    public var detail: String
    /// Optional structured metadata (validation report, retry_after, tool_id, …).
    public var details: JSONValue?

    public init(kind: ToolErrorKind, detail: String, details: JSONValue? = nil) {
        self.kind = kind
        self.detail = detail
        self.details = details
    }

    public var description: String { detail }

    public func withDetails(_ details: JSONValue) -> ToolError {
        var copy = self
        copy.details = details
        return copy
    }

    public var variantName: String { kind.asStr }

    // MARK: Constructors

    public static func notImplemented(_ detail: String) -> ToolError {
        ToolError(kind: .notImplemented, detail: detail)
    }

    public static func invalidArguments(_ detail: String) -> ToolError {
        ToolError(kind: .invalidArguments, detail: detail)
    }

    public static func notFound(toolId: ToolId, detail: String) -> ToolError {
        ToolError(
            kind: .notFound,
            detail: detail,
            details: .object(["tool_id": .string(toolId.rawValue)])
        )
    }

    public static func permissionDenied(_ detail: String) -> ToolError {
        ToolError(kind: .permissionDenied, detail: detail)
    }

    public static func unauthorized(_ detail: String) -> ToolError {
        ToolError(kind: .unauthorized, detail: detail)
    }

    public static func timeout(toolId: ToolId, detail: String) -> ToolError {
        ToolError(
            kind: .timeout,
            detail: detail,
            details: .object(["tool_id": .string(toolId.rawValue)])
        )
    }

    public static func cancelled(toolId: ToolId, detail: String) -> ToolError {
        ToolError(
            kind: .cancelled,
            detail: detail,
            details: .object(["tool_id": .string(toolId.rawValue)])
        )
    }

    public static func rateLimited(_ detail: String) -> ToolError {
        ToolError(kind: .rateLimited, detail: detail)
    }

    public static func usagePoolExhausted(_ detail: String) -> ToolError {
        ToolError(kind: .usagePoolExhausted, detail: detail)
    }

    public static func usageLimitReached(_ detail: String) -> ToolError {
        ToolError(kind: .usageLimitReached, detail: detail)
    }

    public static func globalRateLimit(_ detail: String) -> ToolError {
        ToolError(kind: .globalRateLimit, detail: detail)
    }

    public static func concurrencyLimit(_ detail: String) -> ToolError {
        ToolError(kind: .concurrencyLimit, detail: detail)
    }

    public static func serviceUnavailable(_ detail: String) -> ToolError {
        ToolError(kind: .serviceUnavailable, detail: detail)
    }

    public static func networkError(_ detail: String) -> ToolError {
        ToolError(kind: .networkError, detail: detail)
    }

    public static func execution(toolId: ToolId, detail: String) -> ToolError {
        ToolError(
            kind: .execution,
            detail: detail,
            details: .object(["tool_id": .string(toolId.rawValue)])
        )
    }

    public static func terminalError(toolId: ToolId, detail: String) -> ToolError {
        ToolError(
            kind: .terminalError,
            detail: detail,
            details: .object(["tool_id": .string(toolId.rawValue)])
        )
    }

    public static func custom(code: String, detail: String) -> ToolError {
        ToolError(
            kind: .custom,
            detail: detail,
            details: .object(["code": .string(code)])
        )
    }
}

// MARK: - Wire bridge

private func customDetailsWithCode(_ details: JSONValue?, code: String) -> JSONValue? {
    guard case .object(var map) = details else { return details }
    if map["code"] == nil {
        map["code"] = .string(code)
    }
    return .object(map)
}

private func toolIdFromDetails(_ details: JSONValue?) -> ToolId {
    if case .object(let map) = details,
       case .string(let s) = map["tool_id"],
       let id = try? ToolId(s)
    {
        return id
    }
    return try! ToolId("unknown")
}

extension ToolError {
    /// Convert to the wire-friendly `ToolErrorWire` form.
    public func toWire() -> ToolErrorWire {
        switch kind {
        case .notImplemented:
            return .custom(
                subcode: "not_implemented",
                message: detail,
                details: customDetailsWithCode(details, code: "not_implemented")
            )
        case .invalidArguments:
            return .invalidArguments(message: detail, details: details)
        case .notFound:
            return .toolNotFound(toolId: toolIdFromDetails(details))
        case .permissionDenied:
            return .permissionDenied(reason: detail)
        case .unauthorized:
            return .custom(
                subcode: "unauthorized",
                message: detail,
                details: customDetailsWithCode(details, code: "unauthorized")
            )
        case .timeout:
            let elapsed: UInt64
            if case .object(let map) = details, let n = map["elapsed_ms"]?.doubleValue {
                elapsed = UInt64(n)
            } else {
                elapsed = 0
            }
            return .timeout(toolId: toolIdFromDetails(details), elapsedMs: elapsed)
        case .cancelled:
            return .cancelled(toolId: toolIdFromDetails(details))
        case .rateLimited:
            return .custom(
                subcode: "rate_limited",
                message: detail,
                details: customDetailsWithCode(details, code: "rate_limited")
            )
        case .usagePoolExhausted:
            return .custom(
                subcode: "usage_pool_exhausted",
                message: detail,
                details: customDetailsWithCode(details, code: "usage_pool_exhausted")
            )
        case .usageLimitReached:
            return .custom(
                subcode: "usage_limit_reached",
                message: detail,
                details: customDetailsWithCode(details, code: "usage_limit_reached")
            )
        case .globalRateLimit:
            return .custom(
                subcode: "global_rate_limit",
                message: detail,
                details: customDetailsWithCode(details, code: "global_rate_limit")
            )
        case .concurrencyLimit:
            return .custom(
                subcode: "concurrency_limit",
                message: detail,
                details: customDetailsWithCode(details, code: "concurrency_limit")
            )
        case .serviceUnavailable:
            return .custom(
                subcode: "service_unavailable",
                message: detail,
                details: customDetailsWithCode(details, code: "service_unavailable")
            )
        case .networkError:
            return .custom(
                subcode: "network_error",
                message: detail,
                details: customDetailsWithCode(details, code: "network_error")
            )
        case .execution:
            return .execution(toolId: toolIdFromDetails(details), message: detail)
        case .behaviorVersionUnsupported:
            let requested: String
            if case .object(let map) = details, case .string(let s) = map["requested"] {
                requested = s
            } else {
                requested = "unknown"
            }
            return .behaviorVersionUnsupported(
                toolId: toolIdFromDetails(details),
                requested: requested
            )
        case .renderLimited:
            let cardId: String?
            if case .object(let map) = details, case .string(let s) = map["card_id"] {
                cardId = s
            } else {
                cardId = nil
            }
            return .renderLimited(
                toolId: toolIdFromDetails(details),
                cardId: cardId,
                reason: detail
            )
        case .terminalError:
            return .terminalError(toolId: toolIdFromDetails(details), message: detail)
        case .custom:
            let subcode: String
            if case .object(let map) = details, case .string(let s) = map["code"] {
                subcode = s
            } else {
                subcode = "custom"
            }
            return .custom(subcode: subcode, message: detail, details: details)
        }
    }
}
