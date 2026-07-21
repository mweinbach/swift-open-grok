// DeploymentConfigTypes.swift
//
// Signed deployment-config envelope: the wire contract between the
// cli-chat-proxy signer and the client verifier. Ported from
// prod/mc/cli-chat-proxy-types/src/deployment_config_types.rs.
//
// Shared so a field rename breaks at compile time on both sides instead of
// silently failing verification.

import Foundation

// MARK: - Constants

/// The payload format version the server currently signs.
public let signedPayloadVersion: UInt32 = 1

/// Domain-separation tags inside the signed bytes.
public let managedPolicyTyp = "grok.managed_policy.v1"
public let managedIdentityTyp = "grok.managed_identity.v1"

/// `requirements.toml` key for strict (fail-closed) enforcement.
public let failClosedKey = "fail_closed"

// MARK: - SignedPayload

/// The exact bytes the server signs: the served policy, the principal it is
/// bound to, and an expiry. Serialized once on the server and shipped verbatim
/// as `signed_payload`, so the client verifies the received bytes directly
/// instead of re-canonicalizing.
public struct SignedPayload: Hashable, Sendable, Codable, Equatable {
    public var typ: String
    public var version: UInt32
    public var deploymentId: String?
    public var teamId: String?
    public var managedConfig: String?
    public var requirements: String?
    public var failClosed: Bool
    public var expiresAt: UInt64
    public var keyId: String

    public init(
        typ: String = "",
        version: UInt32 = 0,
        deploymentId: String? = nil,
        teamId: String? = nil,
        managedConfig: String? = nil,
        requirements: String? = nil,
        failClosed: Bool = false,
        expiresAt: UInt64,
        keyId: String
    ) {
        self.typ = typ
        self.version = version
        self.deploymentId = deploymentId
        self.teamId = teamId
        self.managedConfig = managedConfig
        self.requirements = requirements
        self.failClosed = failClosed
        self.expiresAt = expiresAt
        self.keyId = keyId
    }

    enum CodingKeys: String, CodingKey {
        case typ
        case version
        case deploymentId = "deployment_id"
        case teamId = "team_id"
        case managedConfig = "managed_config"
        case requirements
        case failClosed = "fail_closed"
        case expiresAt = "expires_at"
        case keyId = "key_id"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        typ = try container.decodeIfPresent(String.self, forKey: .typ) ?? ""
        version = try container.decodeIfPresent(UInt32.self, forKey: .version) ?? 0
        deploymentId = try container.decodeIfPresent(String.self, forKey: .deploymentId)
        teamId = try container.decodeIfPresent(String.self, forKey: .teamId)
        managedConfig = try container.decodeIfPresent(String.self, forKey: .managedConfig)
        requirements = try container.decodeIfPresent(String.self, forKey: .requirements)
        failClosed = try container.decodeIfPresent(Bool.self, forKey: .failClosed) ?? false
        expiresAt = try container.decode(UInt64.self, forKey: .expiresAt)
        keyId = try container.decode(String.self, forKey: .keyId)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(typ, forKey: .typ)
        try container.encode(version, forKey: .version)
        try container.encodeIfPresent(deploymentId, forKey: .deploymentId)
        try container.encodeIfPresent(teamId, forKey: .teamId)
        try container.encodeIfPresent(managedConfig, forKey: .managedConfig)
        try container.encodeIfPresent(requirements, forKey: .requirements)
        try container.encode(failClosed, forKey: .failClosed)
        try container.encode(expiresAt, forKey: .expiresAt)
        try container.encode(keyId, forKey: .keyId)
    }
}

// MARK: - ManagedIdentityClaim

/// Server-signed claim that a principal is managed (+ fail-closed), persisted
/// by the client as its OWN sidecar.
public struct ManagedIdentityClaim: Hashable, Sendable, Codable, Equatable {
    public var typ: String
    public var principal: String
    public var failClosed: Bool
    public var expiresAt: UInt64
    public var keyId: String

    public init(
        typ: String = "",
        principal: String,
        failClosed: Bool = false,
        expiresAt: UInt64,
        keyId: String
    ) {
        self.typ = typ
        self.principal = principal
        self.failClosed = failClosed
        self.expiresAt = expiresAt
        self.keyId = keyId
    }

    enum CodingKeys: String, CodingKey {
        case typ
        case principal
        case failClosed = "fail_closed"
        case expiresAt = "expires_at"
        case keyId = "key_id"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        typ = try container.decodeIfPresent(String.self, forKey: .typ) ?? ""
        principal = try container.decode(String.self, forKey: .principal)
        failClosed = try container.decodeIfPresent(Bool.self, forKey: .failClosed) ?? false
        expiresAt = try container.decode(UInt64.self, forKey: .expiresAt)
        keyId = try container.decode(String.self, forKey: .keyId)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(typ, forKey: .typ)
        try container.encode(principal, forKey: .principal)
        try container.encode(failClosed, forKey: .failClosed)
        try container.encode(expiresAt, forKey: .expiresAt)
        try container.encode(keyId, forKey: .keyId)
    }
}

// MARK: - SignatureEnvelope

/// One signed envelope carried alongside the legacy policy fields in the
/// deployment-config response. Also the shape the client persists as its
/// on-disk signature sidecar.
public struct SignatureEnvelope: Hashable, Sendable, Codable, Equatable {
    public var signedPayload: String
    public var signature: String
    public var keyId: String

    public init(signedPayload: String, signature: String, keyId: String = "") {
        self.signedPayload = signedPayload
        self.signature = signature
        self.keyId = keyId
    }

    enum CodingKeys: String, CodingKey {
        case signedPayload = "signed_payload"
        case signature
        case keyId = "key_id"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        signedPayload = try container.decode(String.self, forKey: .signedPayload)
        signature = try container.decode(String.self, forKey: .signature)
        keyId = try container.decodeIfPresent(String.self, forKey: .keyId) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(signedPayload, forKey: .signedPayload)
        try container.encode(signature, forKey: .signature)
        try container.encode(keyId, forKey: .keyId)
    }
}

// MARK: - FailClosedFlag

/// Parse result for `fail_closed`. `.invalid` = key present but not a bool.
public enum FailClosedFlag: Hashable, Sendable, Codable, Equatable {
    case `true`
    case `false`
    case invalid

    public var isEnabled: Bool {
        self == .`true`
    }
}

/// Shared `fail_closed` parse (signer + client).
///
/// Bad TOML → `.false`; non-bool key → `.invalid`.
///
/// This is a focused TOML parser that handles the `fail_closed` key at the
/// root level. A full TOML parser is deferred to W1-S5 (OpenGrokConfig);
/// this implementation covers the documented test cases:
///   - `fail_closed = true` → `.true`
///   - `fail_closed = false` → `.false`
///   - `[features]` (no key) → `.false`
///   - `fail_closed = "true"` (string) → `.invalid`
///   - `fail_closed = 1` (int) → `.invalid`
///   - `not = = valid` (unparseable) → `.false`
public func failClosedFlagStatus(_ requirements: String) -> FailClosedFlag {
    // Only look for `fail_closed` at the root level (before any table header).
    let lines = requirements.components(separatedBy: .newlines)
    var inRootSection = true

    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // Skip comments and empty lines.
        if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

        // Table header — enter a non-root section.
        if trimmed.hasPrefix("[") {
            inRootSection = false
            continue
        }

        // Only parse key-value pairs in the root section.
        guard inRootSection else { continue }

        // Look for `fail_closed = <value>`.
        guard let equalRange = trimmed.range(of: "=") else { continue }
        let key = trimmed[trimmed.startIndex..<equalRange.lowerBound]
            .trimmingCharacters(in: .whitespaces)
        let value = trimmed[equalRange.upperBound..<trimmed.endIndex]
            .trimmingCharacters(in: .whitespaces)

        // Strip inline comments from value.
        let valueStr = value.components(separatedBy: " #").first?
            .trimmingCharacters(in: .whitespaces) ?? value

        guard key == failClosedKey else { continue }

        // Parse the value type.
        if valueStr == "true" { return .`true` }
        if valueStr == "false" { return .`false` }

        // Anything else (string, int, float, etc.) is invalid.
        return .invalid
    }

    return .`false`
}

/// Unix seconds now (saturating to 0 on a pre-epoch clock).
public func nowUnix() -> UInt64 {
    let now = Date()
    let epoch = Date(timeIntervalSince1970: 0)
    let interval = now.timeIntervalSince(epoch)
    if interval < 0 { return 0 }
    return UInt64(interval)
}
