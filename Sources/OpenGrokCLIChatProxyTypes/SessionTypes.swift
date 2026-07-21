// SessionTypes.swift
//
// Session registration, update, search, and download types. Ported from
// prod/mc/cli-chat-proxy-types/src/session_types.rs.

import Foundation

/// Request body for registering a session.
/// POST /v1/sessions
public struct RegisterSessionRequest: Hashable, Sendable, Codable, Equatable {
    public var sessionId: String
    public var cwd: String
    /// Ignored; server derives this from `session_id`. Kept for wire-compat.
    public var gcsTracePrefix: String?
    public var modelId: String?
    public var repoRemoteURL: String?
    public var repoBranch: String?
    public var repoHeadAtStart: String?
    /// Ignored; server uses its own bucket constant. Kept for wire-compat.
    public var gcsBucket: String?
    public var hostname: String?
    public var parentSessionId: String?
    /// Opaque per-machine device id. Optional for backward-compat.
    public var deviceId: String?

    public init(
        sessionId: String,
        cwd: String,
        gcsTracePrefix: String? = nil,
        modelId: String? = nil,
        repoRemoteURL: String? = nil,
        repoBranch: String? = nil,
        repoHeadAtStart: String? = nil,
        gcsBucket: String? = nil,
        hostname: String? = nil,
        parentSessionId: String? = nil,
        deviceId: String? = nil
    ) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.gcsTracePrefix = gcsTracePrefix
        self.modelId = modelId
        self.repoRemoteURL = repoRemoteURL
        self.repoBranch = repoBranch
        self.repoHeadAtStart = repoHeadAtStart
        self.gcsBucket = gcsBucket
        self.hostname = hostname
        self.parentSessionId = parentSessionId
        self.deviceId = deviceId
    }

    enum CodingKeys: String, CodingKey {
        case sessionId
        case cwd
        case gcsTracePrefix
        case modelId
        // Rust `#[serde(rename_all = "camelCase")]` maps `repo_remote_url` →
        // `repoRemoteUrl` (lower-casing the `U` after `_`), NOT Swift's
        // `repoRemoteURL` acronym preservation. Pin the raw value explicitly
        // so Swift round-trips with Rust peers.
        case repoRemoteURL = "repoRemoteUrl"
        case repoBranch
        case repoHeadAtStart
        case gcsBucket
        case hostname
        case parentSessionId
        case deviceId
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        cwd = try container.decode(String.self, forKey: .cwd)
        gcsTracePrefix = try container.decodeIfPresent(String.self, forKey: .gcsTracePrefix)
        modelId = try container.decodeIfPresent(String.self, forKey: .modelId)
        repoRemoteURL = try container.decodeIfPresent(String.self, forKey: .repoRemoteURL)
        repoBranch = try container.decodeIfPresent(String.self, forKey: .repoBranch)
        repoHeadAtStart = try container.decodeIfPresent(String.self, forKey: .repoHeadAtStart)
        gcsBucket = try container.decodeIfPresent(String.self, forKey: .gcsBucket)
        hostname = try container.decodeIfPresent(String.self, forKey: .hostname)
        parentSessionId = try container.decodeIfPresent(String.self, forKey: .parentSessionId)
        deviceId = try container.decodeIfPresent(String.self, forKey: .deviceId)
    }
}

/// Request body for updating a session.
/// PATCH /v1/sessions/{session_id}
public struct UpdateSessionRequest: Hashable, Sendable, Codable, Equatable {
    public var summary: String?
    public var firstPrompt: String?
    public var lastTurnNumber: Int32?
    public var repoHeadAtEnd: String?
    /// Latest turn whose restore artifacts are confirmed durable.
    public var restorableTurnNumber: Int32?

    public init(
        summary: String? = nil,
        firstPrompt: String? = nil,
        lastTurnNumber: Int32? = nil,
        repoHeadAtEnd: String? = nil,
        restorableTurnNumber: Int32? = nil
    ) {
        self.summary = summary
        self.firstPrompt = firstPrompt
        self.lastTurnNumber = lastTurnNumber
        self.repoHeadAtEnd = repoHeadAtEnd
        self.restorableTurnNumber = restorableTurnNumber
    }

    enum CodingKeys: String, CodingKey {
        case summary
        case firstPrompt
        case lastTurnNumber
        case repoHeadAtEnd
        case restorableTurnNumber
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        firstPrompt = try container.decodeIfPresent(String.self, forKey: .firstPrompt)
        lastTurnNumber = try container.decodeIfPresent(Int32.self, forKey: .lastTurnNumber)
        repoHeadAtEnd = try container.decodeIfPresent(String.self, forKey: .repoHeadAtEnd)
        restorableTurnNumber = try container.decodeIfPresent(Int32.self, forKey: .restorableTurnNumber)
    }
}

/// Query parameters for searching sessions.
/// GET /v1/sessions
public struct SearchSessionsQuery: Hashable, Sendable, Codable, Equatable {
    public var query: String?
    public var status: String?
    public var cwd: String?
    public var limit: Int64

    public init(query: String? = nil, status: String? = nil, cwd: String? = nil, limit: Int64 = 20) {
        self.query = query
        self.status = status
        self.cwd = cwd
        self.limit = limit
    }

    enum CodingKeys: String, CodingKey {
        case query
        case status
        case cwd
        case limit
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        query = try container.decodeIfPresent(String.self, forKey: .query)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        limit = try container.decodeIfPresent(Int64.self, forKey: .limit) ?? 20
    }
}

/// A session replica returned by the server.
public struct SessionReplicaResponse: Hashable, Sendable, Codable, Equatable {
    public var sessionId: String
    public var summary: String
    public var firstPrompt: String?
    public var modelId: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var endedAt: Date?
    public var lastTurnNumber: Int32
    public var restorableTurnNumber: Int32?
    public var cwd: String
    public var repoRemoteURL: String?
    public var repoBranch: String?
    public var repoHeadAtStart: String?
    public var repoHeadAtEnd: String?
    public var gcsTracePrefix: String
    public var gcsBucket: String
    public var hostname: String?
    public var parentSessionId: String?
    public var status: String
    public var lastActiveAt: Date?

    public init(
        sessionId: String,
        summary: String,
        firstPrompt: String? = nil,
        modelId: String? = nil,
        createdAt: Date,
        updatedAt: Date,
        endedAt: Date? = nil,
        lastTurnNumber: Int32,
        restorableTurnNumber: Int32? = nil,
        cwd: String,
        repoRemoteURL: String? = nil,
        repoBranch: String? = nil,
        repoHeadAtStart: String? = nil,
        repoHeadAtEnd: String? = nil,
        gcsTracePrefix: String,
        gcsBucket: String,
        hostname: String? = nil,
        parentSessionId: String? = nil,
        status: String,
        lastActiveAt: Date? = nil
    ) {
        self.sessionId = sessionId
        self.summary = summary
        self.firstPrompt = firstPrompt
        self.modelId = modelId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.endedAt = endedAt
        self.lastTurnNumber = lastTurnNumber
        self.restorableTurnNumber = restorableTurnNumber
        self.cwd = cwd
        self.repoRemoteURL = repoRemoteURL
        self.repoBranch = repoBranch
        self.repoHeadAtStart = repoHeadAtStart
        self.repoHeadAtEnd = repoHeadAtEnd
        self.gcsTracePrefix = gcsTracePrefix
        self.gcsBucket = gcsBucket
        self.hostname = hostname
        self.parentSessionId = parentSessionId
        self.status = status
        self.lastActiveAt = lastActiveAt
    }

    enum CodingKeys: String, CodingKey {
        case sessionId
        case summary
        case firstPrompt
        case modelId
        case createdAt
        case updatedAt
        case endedAt
        case lastTurnNumber
        case restorableTurnNumber
        case cwd
        // Rust `#[serde(rename_all = "camelCase")]` maps `repo_remote_url` →
        // `repoRemoteUrl` (lower-casing the `U` after `_`), NOT Swift's
        // `repoRemoteURL` acronym preservation. Pin the raw value explicitly
        // so Swift round-trips with Rust peers.
        case repoRemoteURL = "repoRemoteUrl"
        case repoBranch
        case repoHeadAtStart
        case repoHeadAtEnd
        case gcsTracePrefix
        case gcsBucket
        case hostname
        case parentSessionId
        case status
        case lastActiveAt
    }
}

/// Response from searching sessions.
public struct SearchSessionsResponse: Hashable, Sendable, Codable, Equatable {
    public var sessions: [SessionReplicaResponse]

    public init(sessions: [SessionReplicaResponse] = []) {
        self.sessions = sessions
    }
}

/// Query parameters for downloading a session file.
/// GET /v1/sessions/{session_id}/download
public struct DownloadSessionQuery: Hashable, Sendable, Codable, Equatable {
    public var file: String
    public var turn: Int32?

    public init(file: String, turn: Int32? = nil) {
        self.file = file
        self.turn = turn
    }

    enum CodingKeys: String, CodingKey {
        case file
        case turn
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        file = try container.decode(String.self, forKey: .file)
        turn = try container.decodeIfPresent(Int32.self, forKey: .turn)
    }
}

/// Response from downloading a session file.
public struct DownloadSessionResponse: Hashable, Sendable, Codable, Equatable {
    public var downloadURL: String
    public var expiresInseconds: UInt64
    public var file: String
    public var turn: Int32

    public init(downloadURL: String, expiresInseconds: UInt64, file: String, turn: Int32) {
        self.downloadURL = downloadURL
        self.expiresInseconds = expiresInseconds
        self.file = file
        self.turn = turn
    }

    // Rust `#[serde(rename_all = "camelCase")]` maps:
    //   `download_url`      → `downloadUrl`      (NOT `downloadURL`)
    //   `expires_in_seconds`→ `expiresInSeconds` (NOT `expiresInseconds`)
    // Pin both raw values explicitly so Swift round-trips with Rust peers.
    enum CodingKeys: String, CodingKey {
        case downloadURL = "downloadUrl"
        case expiresInseconds = "expiresInSeconds"
        case file
        case turn
    }
}
