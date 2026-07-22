// RpcCommon.swift
//
// Shared helpers for hub-proxied `workspace.*` RPC method types.
// Complements `RpcMethods.swift` (envelope + workspace-core methods).

import Foundation
import OpenGrokShared

/// Unit response for workspace RPC methods whose Rust `Response = ()`.
///
/// Serde serializes `()` as JSON `null`. Clients and servers round-trip
/// that form through this type.
public struct WorkspaceRpcUnit: Hashable, Sendable, Codable, Equatable {
    public init() {}

    public init(from decoder: Decoder) throws {
        // Accept null (serde `()`), empty object, or missing payload.
        if let c = try? decoder.singleValueContainer() {
            if c.decodeNil() { return }
            // Non-null single value: tolerate and discard.
            return
        }
        _ = try? decoder.container(keyedBy: DynamicKey.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encodeNil()
    }

    private struct DynamicKey: CodingKey {
        var stringValue: String
        init?(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { nil }
        init?(intValue: Int) { return nil }
    }
}

/// Empty-object request helper used by many zero-field RPC methods.
public struct WorkspaceRpcEmptyObject: Hashable, Sendable, Codable, Equatable {
    public init() {}

    public init(from decoder: Decoder) throws {
        // Tolerate `{}`, `null`, or missing payload.
        if let c = try? decoder.singleValueContainer(), c.decodeNil() {
            return
        }
        _ = try? decoder.container(keyedBy: DynamicKey.self)
    }

    public func encode(to encoder: Encoder) throws {
        _ = encoder.container(keyedBy: DynamicKey.self)
    }

    private struct DynamicKey: CodingKey {
        var stringValue: String
        init?(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { nil }
        init?(intValue: Int) { return nil }
    }
}
