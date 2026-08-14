// DiagServerTypes.swift
//
// In-guest diagnostics HTTP server (/ready, /statusz, /logs) types and contracts
// for the standalone workspace-server. Swift port of `xai-grok-diag-server`.

import Foundation

#if !os(Windows)
/// Default Unix socket path (next to the log/pid files).
public let DEFAULT_DIAG_SOCKET_PATH = "/tmp/workspace-server.sock"
#endif

/// Default loopback TCP port for Windows guests.
public let DEFAULT_DIAG_PORT: UInt16 = 6016

/// Grep-able daemon-log marker for a diagnostics bind failure.
public let DIAG_BIND_FAILED_MARKER = "diagnostics server bind failed"

/// Process exit code for a fatal diagnostics bind failure in `--daemonize` mode.
public let EXIT_DIAG_BIND_FAILED: Int32 = 5

/// Default `/logs` tail size when `tail_bytes` is not given.
public let DEFAULT_LOG_TAIL_BYTES: UInt64 = 64 * 1024

/// Hard cap on a `/logs` response; larger `tail_bytes` values are clamped.
public let MAX_LOG_TAIL_BYTES: UInt64 = 256 * 1024

/// Soft cap on `/ready` `error_detail` so guest-local messages stay short.
public let MAX_ERROR_DETAIL_BYTES: Int = 256

/// Hub connection state as reported on `/ready`.
public enum DiagState: String, Sendable, Codable, Equatable {
    case starting = "starting"
    case connected = "connected"
    case disconnected = "disconnected"
    case failed = "failed"
}

/// `/ready` `error_class` when `DiagState.failed` (`hub_auth` / `hub_connect` / `unknown`).
public enum ErrorClass: String, Sendable, Codable, Equatable {
    case hubAuth = "hub_auth"
    case hubConnect = "hub_connect"
    case unknown = "unknown"
}

/// Response body for `/ready`. The field set is a frozen contract with the
/// sandbox readiness gate: never rename or remove fields; additions are
/// backward-compatible.
public struct ReadyBody: Sendable, Codable, Equatable {
    /// Serialized as an explicit `null` (never omitted) for nonce-less launches.
    public var launchId: String?
    public var state: DiagState
    public var pid: UInt32
    public var connectedAt: UInt64?
    public var stateChangedAt: UInt64
    public var version: String
    public var errorClass: ErrorClass?
    public var errorDetail: String?
    public var lastCloseCode: UInt16?

    enum CodingKeys: String, CodingKey {
        case launchId = "launch_id"
        case state
        case pid
        case connectedAt = "connected_at"
        case stateChangedAt = "state_changed_at"
        case version
        case errorClass = "error_class"
        case errorDetail = "error_detail"
        case lastCloseCode = "last_close_code"
    }

    public init(
        launchId: String?,
        state: DiagState,
        pid: UInt32,
        connectedAt: UInt64?,
        stateChangedAt: UInt64,
        version: String,
        errorClass: ErrorClass? = nil,
        errorDetail: String? = nil,
        lastCloseCode: UInt16? = nil
    ) {
        self.launchId = launchId
        self.state = state
        self.pid = pid
        self.connectedAt = connectedAt
        self.stateChangedAt = stateChangedAt
        self.version = version
        self.errorClass = errorClass
        self.errorDetail = errorDetail
        self.lastCloseCode = lastCloseCode
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let launchId {
            try container.encode(launchId, forKey: .launchId)
        } else {
            try container.encodeNil(forKey: .launchId)
        }
        try container.encode(state, forKey: .state)
        try container.encode(pid, forKey: .pid)
        if let connectedAt {
            try container.encode(connectedAt, forKey: .connectedAt)
        } else {
            try container.encodeNil(forKey: .connectedAt)
        }
        try container.encode(stateChangedAt, forKey: .stateChangedAt)
        try container.encode(version, forKey: .version)
        if let errorClass {
            try container.encode(errorClass, forKey: .errorClass)
        }
        if let errorDetail {
            try container.encode(errorDetail, forKey: .errorDetail)
        }
        if let lastCloseCode {
            try container.encode(lastCloseCode, forKey: .lastCloseCode)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.launchId = try container.decodeIfPresent(String.self, forKey: .launchId)
        self.state = try container.decode(DiagState.self, forKey: .state)
        self.pid = try container.decode(UInt32.self, forKey: .pid)
        self.connectedAt = try container.decodeIfPresent(UInt64.self, forKey: .connectedAt)
        self.stateChangedAt = try container.decode(UInt64.self, forKey: .stateChangedAt)
        self.version = try container.decode(String.self, forKey: .version)
        self.errorClass = try container.decodeIfPresent(ErrorClass.self, forKey: .errorClass)
        self.errorDetail = try container.decodeIfPresent(String.self, forKey: .errorDetail)
        self.lastCloseCode = try container.decodeIfPresent(UInt16.self, forKey: .lastCloseCode)
    }
}

/// Response body for `/statusz`: the `/ready` fields plus debug extras.
public struct StatuszBody: Sendable, Codable, Equatable {
    public var ready: ReadyBody
    public var os: String
    /// Advisory image capability tokens, sorted, as published by the owning server.
    public var imageCapabilities: [String]
    /// `false` = the declaration was absent/unreadable/self-tokenless
    /// (UNKNOWN), which is not the same as "declares nothing".
    public var imageCapabilitiesDeclared: Bool

    enum CodingKeys: String, CodingKey {
        case launchId = "launch_id"
        case state
        case pid
        case connectedAt = "connected_at"
        case stateChangedAt = "state_changed_at"
        case version
        case errorClass = "error_class"
        case errorDetail = "error_detail"
        case lastCloseCode = "last_close_code"
        case os
        case imageCapabilities = "image_capabilities"
        case imageCapabilitiesDeclared = "image_capabilities_declared"
    }

    public init(
        ready: ReadyBody,
        os: String,
        imageCapabilities: [String],
        imageCapabilitiesDeclared: Bool
    ) {
        self.ready = ready
        self.os = os
        self.imageCapabilities = imageCapabilities
        self.imageCapabilitiesDeclared = imageCapabilitiesDeclared
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let launchId = ready.launchId {
            try container.encode(launchId, forKey: .launchId)
        } else {
            try container.encodeNil(forKey: .launchId)
        }
        try container.encode(ready.state, forKey: .state)
        try container.encode(ready.pid, forKey: .pid)
        if let connectedAt = ready.connectedAt {
            try container.encode(connectedAt, forKey: .connectedAt)
        } else {
            try container.encodeNil(forKey: .connectedAt)
        }
        try container.encode(ready.stateChangedAt, forKey: .stateChangedAt)
        try container.encode(ready.version, forKey: .version)
        if let errorClass = ready.errorClass {
            try container.encode(errorClass, forKey: .errorClass)
        }
        if let errorDetail = ready.errorDetail {
            try container.encode(errorDetail, forKey: .errorDetail)
        }
        if let lastCloseCode = ready.lastCloseCode {
            try container.encode(lastCloseCode, forKey: .lastCloseCode)
        }
        try container.encode(os, forKey: .os)
        try container.encode(imageCapabilities, forKey: .imageCapabilities)
        try container.encode(imageCapabilitiesDeclared, forKey: .imageCapabilitiesDeclared)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let launchId = try container.decodeIfPresent(String.self, forKey: .launchId)
        let state = try container.decode(DiagState.self, forKey: .state)
        let pid = try container.decode(UInt32.self, forKey: .pid)
        let connectedAt = try container.decodeIfPresent(UInt64.self, forKey: .connectedAt)
        let stateChangedAt = try container.decode(UInt64.self, forKey: .stateChangedAt)
        let version = try container.decode(String.self, forKey: .version)
        let errorClass = try container.decodeIfPresent(ErrorClass.self, forKey: .errorClass)
        let errorDetail = try container.decodeIfPresent(String.self, forKey: .errorDetail)
        let lastCloseCode = try container.decodeIfPresent(UInt16.self, forKey: .lastCloseCode)

        self.ready = ReadyBody(
            launchId: launchId,
            state: state,
            pid: pid,
            connectedAt: connectedAt,
            stateChangedAt: stateChangedAt,
            version: version,
            errorClass: errorClass,
            errorDetail: errorDetail,
            lastCloseCode: lastCloseCode
        )
        self.os = try container.decode(String.self, forKey: .os)
        self.imageCapabilities = try container.decode([String].self, forKey: .imageCapabilities)
        self.imageCapabilitiesDeclared = try container.decode(Bool.self, forKey: .imageCapabilitiesDeclared)
    }
}

/// Where the diagnostics server listens: a Unix socket on Linux/macOS, loopback TCP on Windows.
public enum DiagListener: Sendable, Equatable {
    case unix(String)
    case tcp(UInt16)
}
