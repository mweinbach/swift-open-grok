// SessionCacheQuery.swift
//
// Open Grok — ACP RPC query handler for prompt cache telemetry and break diagnostics.
//
// Reference in Rust: `crates/codegen/xai-grok-shell/src/extensions/cache.rs`.
//
// Handles `x.ai/session_cache` and `x.ai/session/cache` RPC requests.

import Foundation
import OpenGrokACP
import OpenGrokShared

/// Handler for `x.ai/session_cache` and `x.ai/session/cache` ACP RPC requests.
public struct SessionCacheQuery: ACPAgentExtensionHandler, Sendable {
    /// Supported method names.
    public static let methods: [String] = [
        "x.ai/session_cache",
        "x.ai/session/cache"
    ]

    /// Provider closure for resolving cache snapshots by session ID.
    public typealias SnapshotProvider = @Sendable (String) async throws -> JSONValue?

    private let provider: SnapshotProvider

    /// Initialize with a raw `JSONValue` provider closure.
    public init(provider: @escaping SnapshotProvider) {
        self.provider = provider
    }

    /// Initialize with a typed `Encodable & Sendable` snapshot provider.
    public init<T: Encodable & Sendable>(typedProvider: @escaping @Sendable (String) async throws -> T?) {
        self.provider = { sessionId in
            guard let snapshot = try await typedProvider(sessionId) else { return nil }
            let data = try WireJSONEncoder.make().encode(snapshot)
            return try WireJSONDecoder.make().decode(JSONValue.self, from: data)
        }
    }

    /// Handle ACP extension request.
    public func handle(method: String, params: JSONValue) async throws -> JSONValue {
        guard Self.methods.contains(method) else {
            throw ACPExtensionMethodRouter.unknownExtensionMethodError(method)
        }

        let sessionId: String
        if let id = params["sessionId"]?.stringValue, !id.isEmpty {
            sessionId = id
        } else if let id = params["session_id"]?.stringValue, !id.isEmpty {
            sessionId = id
        } else {
            throw AcpError(
                code: .invalidParams,
                message: AcpErrorCode.invalidParams.displayName,
                data: .string("invalid params: missing sessionId")
            )
        }

        guard let result = try await provider(sessionId) else {
            throw AcpError(
                code: .resourceNotFound,
                message: AcpErrorCode.resourceNotFound.displayName,
                data: .string("session not found: \(sessionId)")
            )
        }

        return result
    }
}
