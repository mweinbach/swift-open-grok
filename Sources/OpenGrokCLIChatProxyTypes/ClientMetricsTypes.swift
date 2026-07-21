// ClientMetricsTypes.swift
//
// Client metrics API request/response types. Ported from
// prod/mc/cli-chat-proxy-types/src/client_metrics_types.rs.

import Foundation

/// A single client metric event.
public struct ClientMetric: Hashable, Sendable, Codable, Equatable {
    public var metric: String
    public var value: Double
    public var timestamp: Date?
    public var idempotencyKey: String?

    public init(metric: String, value: Double, timestamp: Date? = nil, idempotencyKey: String? = nil) {
        self.metric = metric
        self.value = value
        self.timestamp = timestamp
        self.idempotencyKey = idempotencyKey
    }

    // Rust serde defaults to the field name as the JSON key (snake_case).
    // Pin every CodingKey raw value explicitly so Swift never emits or
    // accepts the camelCase Swift property spelling on the wire.
    enum CodingKeys: String, CodingKey {
        case metric
        case value
        case timestamp
        case idempotencyKey = "idempotency_key"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        metric = try container.decode(String.self, forKey: .metric)
        value = try container.decode(Double.self, forKey: .value)
        timestamp = try container.decodeIfPresent(Date.self, forKey: .timestamp)
        idempotencyKey = try container.decodeIfPresent(String.self, forKey: .idempotencyKey)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(metric, forKey: .metric)
        try container.encode(value, forKey: .value)
        try container.encodeIfPresent(timestamp, forKey: .timestamp)
        try container.encodeIfPresent(idempotencyKey, forKey: .idempotencyKey)
    }

    /// Add a timestamp and return self for chaining.
    @discardableResult
    public func withTimestamp(_ ts: Date) -> ClientMetric {
        var copy = self
        copy.timestamp = ts
        return copy
    }

    /// Add an idempotency key and return self for chaining.
    @discardableResult
    public func withIdempotencyKey(_ key: String) -> ClientMetric {
        var copy = self
        copy.idempotencyKey = key
        return copy
    }
}

/// A batch of client metrics events.
public struct ClientMetricsBatch: Hashable, Sendable, Codable, Equatable {
    public var events: [ClientMetric]
    public var processId: String?
    public var sessionId: String?
    public var clientVersion: String?
    public var clientType: String?
    public var os: String?
    public var arch: String?

    public init(
        events: [ClientMetric] = [],
        processId: String? = nil,
        sessionId: String? = nil,
        clientVersion: String? = nil,
        clientType: String? = nil,
        os: String? = nil,
        arch: String? = nil
    ) {
        self.events = events
        self.processId = processId
        self.sessionId = sessionId
        self.clientVersion = clientVersion
        self.clientType = clientType
        self.os = os
        self.arch = arch
    }

    // Rust serde defaults to the field name as the JSON key (snake_case).
    // Pin every CodingKey raw value explicitly so Swift never emits or
    // accepts the camelCase Swift property spelling on the wire.
    enum CodingKeys: String, CodingKey {
        case events
        case processId = "process_id"
        case sessionId = "session_id"
        case clientVersion = "client_version"
        case clientType = "client_type"
        case os
        case arch
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        events = try container.decodeIfPresent([ClientMetric].self, forKey: .events) ?? []
        processId = try container.decodeIfPresent(String.self, forKey: .processId)
        sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
        clientVersion = try container.decodeIfPresent(String.self, forKey: .clientVersion)
        clientType = try container.decodeIfPresent(String.self, forKey: .clientType)
        os = try container.decodeIfPresent(String.self, forKey: .os)
        arch = try container.decodeIfPresent(String.self, forKey: .arch)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(events, forKey: .events)
        try container.encodeIfPresent(processId, forKey: .processId)
        try container.encodeIfPresent(sessionId, forKey: .sessionId)
        try container.encodeIfPresent(clientVersion, forKey: .clientVersion)
        try container.encodeIfPresent(clientType, forKey: .clientType)
        try container.encodeIfPresent(os, forKey: .os)
        try container.encodeIfPresent(arch, forKey: .arch)
    }
}

/// Response from submitting client metrics.
public struct ClientMetricsResponse: Hashable, Sendable, Codable, Equatable {
    public var accepted: Int

    public init(accepted: Int = 0) {
        self.accepted = accepted
    }
}
