// Handshake.swift
//
// Open Grok — Swift port of `xai-tool-protocol/src/handshake.rs`.

import Foundation
import OpenGrokShared

/// Wire-protocol version both ends speak.
public let toolProtocolVersion = "1.0.0"

/// First frame sent by the client after the WebSocket upgrade succeeds.
public struct HelloMsg: Codable, Sendable, Hashable {
    public var protocolVersion: String
    public var kind: ConnectionKind
    public var serverId: ServerId?
    public var description: String?
    public var metadata: JSONValue?

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case kind
        case serverId = "server_id"
        case description
        case metadata
    }

    public init(
        protocolVersion: String = toolProtocolVersion,
        kind: ConnectionKind,
        serverId: ServerId? = nil,
        description: String? = nil,
        metadata: JSONValue? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.kind = kind
        self.serverId = serverId
        self.description = description
        self.metadata = metadata
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(protocolVersion, forKey: .protocolVersion)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(serverId, forKey: .serverId)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encodeIfPresent(metadata, forKey: .metadata)
    }
}

/// Computer hub's reply to `HelloMsg`.
public struct HelloAckMsg: Codable, Sendable, Hashable {
    public var connectionId: ConnectionId
    public var userId: UserId
    public var computerHubVersion: String
    public var supportedProtocolVersions: [String]
    public var capabilities: [String]

    private enum CodingKeys: String, CodingKey {
        case connectionId = "connection_id"
        case userId = "user_id"
        case computerHubVersion = "computer_hub_version"
        case supportedProtocolVersions = "supported_protocol_versions"
        case capabilities
    }

    public init(
        connectionId: ConnectionId,
        userId: UserId,
        computerHubVersion: String,
        supportedProtocolVersions: [String],
        capabilities: [String] = []
    ) {
        self.connectionId = connectionId
        self.userId = userId
        self.computerHubVersion = computerHubVersion
        self.supportedProtocolVersions = supportedProtocolVersions
        self.capabilities = capabilities
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.connectionId = try c.decode(ConnectionId.self, forKey: .connectionId)
        self.userId = try c.decode(UserId.self, forKey: .userId)
        self.computerHubVersion = try c.decode(String.self, forKey: .computerHubVersion)
        self.supportedProtocolVersions = try c.decode([String].self, forKey: .supportedProtocolVersions)
        self.capabilities = try c.decodeIfPresent([String].self, forKey: .capabilities) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(connectionId, forKey: .connectionId)
        try c.encode(userId, forKey: .userId)
        try c.encode(computerHubVersion, forKey: .computerHubVersion)
        try c.encode(supportedProtocolVersions, forKey: .supportedProtocolVersions)
        if !capabilities.isEmpty {
            try c.encode(capabilities, forKey: .capabilities)
        }
    }
}
