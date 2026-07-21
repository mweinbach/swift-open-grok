// SandboxTypes.swift
//
// Sandbox API request and response types. Ported from
// prod/mc/cli-chat-proxy-types/src/sandbox_types.rs.
//
// All types use `camelCase` serialization to match the proto3 canonical JSON
// encoding used on the wire.

import Foundation

// MARK: - SandboxMode

/// Sandbox operating mode.
///
/// Proto3 enum serialized as its string name on the wire
/// (e.g. `"SANDBOX_MODE_AGENT"`).
public enum SandboxMode: String, Sendable, Codable, Equatable, Defaultable {
    case invalid = "SANDBOX_MODE_INVALID"
    case agent = "SANDBOX_MODE_AGENT"
    case workspaceServer = "SANDBOX_MODE_WORKSPACE_SERVER"
    case bare = "SANDBOX_MODE_BARE"

    public static let defaultValue = SandboxMode.invalid
}

// MARK: - SandboxForkRequest

/// Request body for forking a sandbox session.
/// POST /v1/sandbox/sessions/fork
public struct SandboxForkRequest: Hashable, Sendable, Codable, Equatable {
    public var sourceSandboxId: String
    public var copies: UInt32?
    /// SECURITY (CWE-284): Accepted for backwards compatibility but MUST NOT
    /// be forwarded to backend services. The server always uses the configured
    /// default bucket.
    public var snapshotBucket: String?

    public init(sourceSandboxId: String, copies: UInt32? = nil, snapshotBucket: String? = nil) {
        self.sourceSandboxId = sourceSandboxId
        self.copies = copies
        self.snapshotBucket = snapshotBucket
    }

    enum CodingKeys: String, CodingKey {
        case sourceSandboxId
        case copies
        case snapshotBucket
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceSandboxId = try container.decode(String.self, forKey: .sourceSandboxId)
        copies = try container.decodeIfPresent(UInt32.self, forKey: .copies)
        snapshotBucket = try container.decodeIfPresent(String.self, forKey: .snapshotBucket)
    }
}

// MARK: - SandboxForkedSession / SandboxForkResponse

/// Information about a single forked session.
public struct SandboxForkedSession: Hashable, Sendable, Codable, Equatable {
    public var sandboxId: String
    public var websocketURL: String
    public var jwtToken: String

    public init(sandboxId: String, websocketURL: String, jwtToken: String) {
        self.sandboxId = sandboxId
        self.websocketURL = websocketURL
        self.jwtToken = jwtToken
    }

    // Rust `#[serde(rename_all = "camelCase")]` maps `websocket_url` →
    // `websocketUrl` (lower-casing the `U` after `_`), NOT Swift's
    // `websocketURL` acronym preservation. Pin the raw value explicitly
    // so Swift round-trips with Rust peers.
    enum CodingKeys: String, CodingKey {
        case sandboxId
        case websocketURL = "websocketUrl"
        case jwtToken
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sandboxId = try container.decodeIfPresent(String.self, forKey: .sandboxId) ?? ""
        websocketURL = try container.decodeIfPresent(String.self, forKey: .websocketURL) ?? ""
        jwtToken = try container.decodeIfPresent(String.self, forKey: .jwtToken) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sandboxId, forKey: .sandboxId)
        try container.encode(websocketURL, forKey: .websocketURL)
        try container.encode(jwtToken, forKey: .jwtToken)
    }
}

/// Response from forking a sandbox session.
public struct SandboxForkResponse: Hashable, Sendable, Codable, Equatable {
    public var sandboxIds: [String]
    public var sessions: [SandboxForkedSession]

    public init(sandboxIds: [String] = [], sessions: [SandboxForkedSession] = []) {
        self.sandboxIds = sandboxIds
        self.sessions = sessions
    }
}

// MARK: - SandboxTerminateRequest

/// Request body/query for terminating a sandbox session.
/// DELETE /v1/sandbox/sessions/{sandbox_id}
public struct SandboxTerminateRequest: Hashable, Sendable, Codable, Equatable {
    public var environmentId: String?

    public init(environmentId: String? = nil) {
        self.environmentId = environmentId
    }

    enum CodingKeys: String, CodingKey {
        case environmentId
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        environmentId = try container.decodeIfPresent(String.self, forKey: .environmentId)
    }
}

// MARK: - SandboxStartRequest / SandboxStartResponse

/// Request body for starting a sandbox session (non-TUI).
/// POST /v1/sandbox/sessions/start
public struct SandboxStartRequest: Hashable, Sendable, Codable, Equatable {
    public var environmentId: String?
    public var sessionId: String?
    public var repository: String?
    public var branch: String?
    public var memoryLimitBytes: String?
    public var cpus: UInt32?
    public var sessionTimeoutSeconds: UInt32?
    public var envVars: [String: String]
    public var diskBytes: String?
    public var gpus: UInt32?
    public var gpuType: String?
    public var mode: SandboxMode

    public init(
        environmentId: String? = nil,
        sessionId: String? = nil,
        repository: String? = nil,
        branch: String? = nil,
        memoryLimitBytes: String? = nil,
        cpus: UInt32? = nil,
        sessionTimeoutSeconds: UInt32? = nil,
        envVars: [String: String] = [:],
        diskBytes: String? = nil,
        gpus: UInt32? = nil,
        gpuType: String? = nil,
        mode: SandboxMode = .invalid
    ) {
        self.environmentId = environmentId
        self.sessionId = sessionId
        self.repository = repository
        self.branch = branch
        self.memoryLimitBytes = memoryLimitBytes
        self.cpus = cpus
        self.sessionTimeoutSeconds = sessionTimeoutSeconds
        self.envVars = envVars
        self.diskBytes = diskBytes
        self.gpus = gpus
        self.gpuType = gpuType
        self.mode = mode
    }

    enum CodingKeys: String, CodingKey {
        case environmentId
        case sessionId
        case repository
        case branch
        case memoryLimitBytes
        case cpus
        case sessionTimeoutSeconds
        case envVars
        case diskBytes
        case gpus
        case gpuType
        case mode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        environmentId = try container.decodeIfPresent(String.self, forKey: .environmentId)
        sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
        repository = try container.decodeIfPresent(String.self, forKey: .repository)
        branch = try container.decodeIfPresent(String.self, forKey: .branch)
        memoryLimitBytes = try container.decodeIfPresent(String.self, forKey: .memoryLimitBytes)
        cpus = try container.decodeIfPresent(UInt32.self, forKey: .cpus)
        sessionTimeoutSeconds = try container.decodeIfPresent(UInt32.self, forKey: .sessionTimeoutSeconds)
        envVars = try container.decodeIfPresent([String: String].self, forKey: .envVars) ?? [:]
        diskBytes = try container.decodeIfPresent(String.self, forKey: .diskBytes)
        gpus = try container.decodeIfPresent(UInt32.self, forKey: .gpus)
        gpuType = try container.decodeIfPresent(String.self, forKey: .gpuType)
        mode = try container.decodeIfPresent(SandboxMode.self, forKey: .mode) ?? .invalid
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(environmentId, forKey: .environmentId)
        try container.encodeIfPresent(sessionId, forKey: .sessionId)
        try container.encodeIfPresent(repository, forKey: .repository)
        try container.encodeIfPresent(branch, forKey: .branch)
        try container.encodeIfPresent(memoryLimitBytes, forKey: .memoryLimitBytes)
        try container.encodeIfPresent(cpus, forKey: .cpus)
        try container.encodeIfPresent(sessionTimeoutSeconds, forKey: .sessionTimeoutSeconds)
        if !envVars.isEmpty {
            try container.encode(envVars, forKey: .envVars)
        }
        try container.encodeIfPresent(diskBytes, forKey: .diskBytes)
        try container.encodeIfPresent(gpus, forKey: .gpus)
        try container.encodeIfPresent(gpuType, forKey: .gpuType)
        try container.encode(mode, forKey: .mode)
    }
}

/// Response from starting a sandbox session.
public struct SandboxStartResponse: Hashable, Sendable, Codable, Equatable {
    public var sandboxId: String
    public var sessionId: String
    public var websocketURL: String
    public var environment: SandboxEnvironmentWithMetadata?
    public var directUrls: [String: String]
    public var cloudflareUrls: [String: String]
    public var mode: SandboxMode?

    public init(
        sandboxId: String = "",
        sessionId: String = "",
        websocketURL: String = "",
        environment: SandboxEnvironmentWithMetadata? = nil,
        directUrls: [String: String] = [:],
        cloudflareUrls: [String: String] = [:],
        mode: SandboxMode? = nil
    ) {
        self.sandboxId = sandboxId
        self.sessionId = sessionId
        self.websocketURL = websocketURL
        self.environment = environment
        self.directUrls = directUrls
        self.cloudflareUrls = cloudflareUrls
        self.mode = mode
    }

    enum CodingKeys: String, CodingKey {
        case sandboxId
        case sessionId
        case websocketURL = "websocketUrl"
        case environment
        case directUrls
        case cloudflareUrls
        case mode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sandboxId = try container.decodeIfPresent(String.self, forKey: .sandboxId) ?? ""
        sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId) ?? ""
        websocketURL = try container.decodeIfPresent(String.self, forKey: .websocketURL) ?? ""
        environment = try container.decodeIfPresent(SandboxEnvironmentWithMetadata.self, forKey: .environment)
        directUrls = try container.decodeIfPresent([String: String].self, forKey: .directUrls) ?? [:]
        cloudflareUrls = try container.decodeIfPresent([String: String].self, forKey: .cloudflareUrls) ?? [:]
        mode = try container.decodeIfPresent(SandboxMode.self, forKey: .mode)
    }
}

// MARK: - SandboxStatusResponse

/// Response from getting sandbox session status.
public struct SandboxStatusResponse: Hashable, Sendable, Codable, Equatable {
    public var status: String
    public var message: String
    public var metadata: [String: String]
    public var timestamp: String?

    public init(status: String = "", message: String = "", metadata: [String: String] = [:], timestamp: String? = nil) {
        self.status = status
        self.message = message
        self.metadata = metadata
        self.timestamp = timestamp
    }

    enum CodingKeys: String, CodingKey {
        case status
        case message
        case metadata
        case timestamp
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? ""
        message = try container.decodeIfPresent(String.self, forKey: .message) ?? ""
        metadata = try container.decodeIfPresent([String: String].self, forKey: .metadata) ?? [:]
        timestamp = try container.decodeIfPresent(String.self, forKey: .timestamp)
    }
}

// MARK: - SandboxLogsExitCodes / SandboxLogsResponse

/// Exit codes for sandbox log commands.
public struct SandboxLogsExitCodes: Hashable, Sendable, Codable, Equatable {
    public var env: Int32?
    public var directMode: Int32?
    public var fetch: Int32?

    public init(env: Int32? = nil, directMode: Int32? = nil, fetch: Int32? = nil) {
        self.env = env
        self.directMode = directMode
        self.fetch = fetch
    }

    enum CodingKeys: String, CodingKey {
        case env
        case directMode
        case fetch
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        env = try container.decodeIfPresent(Int32.self, forKey: .env)
        directMode = try container.decodeIfPresent(Int32.self, forKey: .directMode)
        fetch = try container.decodeIfPresent(Int32.self, forKey: .fetch)
    }
}

/// Response from getting sandbox session logs.
public struct SandboxLogsResponse: Hashable, Sendable, Codable, Equatable {
    public var envVars: String
    public var directModeLogs: String
    public var fetchLogs: String
    public var exitCodes: SandboxLogsExitCodes?

    public init(
        envVars: String = "",
        directModeLogs: String = "",
        fetchLogs: String = "",
        exitCodes: SandboxLogsExitCodes? = nil
    ) {
        self.envVars = envVars
        self.directModeLogs = directModeLogs
        self.fetchLogs = fetchLogs
        self.exitCodes = exitCodes
    }

    enum CodingKeys: String, CodingKey {
        case envVars
        case directModeLogs
        case fetchLogs
        case exitCodes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        envVars = try container.decodeIfPresent(String.self, forKey: .envVars) ?? ""
        directModeLogs = try container.decodeIfPresent(String.self, forKey: .directModeLogs) ?? ""
        fetchLogs = try container.decodeIfPresent(String.self, forKey: .fetchLogs) ?? ""
        exitCodes = try container.decodeIfPresent(SandboxLogsExitCodes.self, forKey: .exitCodes)
    }
}

// MARK: - SandboxHibernateResponse / SandboxRestoreRequest / SandboxRestoreResponse

/// Response from hibernating a sandbox session.
public struct SandboxHibernateResponse: Hashable, Sendable, Codable, Equatable {
    public var snapshotPath: String

    public init(snapshotPath: String = "") {
        self.snapshotPath = snapshotPath
    }

    enum CodingKeys: String, CodingKey {
        case snapshotPath
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        snapshotPath = try container.decodeIfPresent(String.self, forKey: .snapshotPath) ?? ""
    }
}

/// Request body for restoring a hibernated sandbox session.
public struct SandboxRestoreRequest: Hashable, Sendable, Codable, Equatable {
    public var serverKey: String

    public init(serverKey: String) {
        self.serverKey = serverKey
    }
}

/// Response from restoring a hibernated sandbox session.
public struct SandboxRestoreResponse: Hashable, Sendable, Codable, Equatable {
    public var sandboxId: String
    public var snapshotPath: String
    public var websocketURL: String

    public init(sandboxId: String = "", snapshotPath: String = "", websocketURL: String = "") {
        self.sandboxId = sandboxId
        self.snapshotPath = snapshotPath
        self.websocketURL = websocketURL
    }

    // Rust `#[serde(rename_all = "camelCase")]` maps `websocket_url` →
    // `websocketUrl` (lower-casing the `U` after `_`), NOT Swift's
    // `websocketURL` acronym preservation. Pin the raw value explicitly
    // so Swift round-trips with Rust peers.
    enum CodingKeys: String, CodingKey {
        case sandboxId
        case snapshotPath
        case websocketURL = "websocketUrl"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sandboxId = try container.decodeIfPresent(String.self, forKey: .sandboxId) ?? ""
        snapshotPath = try container.decodeIfPresent(String.self, forKey: .snapshotPath) ?? ""
        websocketURL = try container.decodeIfPresent(String.self, forKey: .websocketURL) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sandboxId, forKey: .sandboxId)
        try container.encode(snapshotPath, forKey: .snapshotPath)
        try container.encode(websocketURL, forKey: .websocketURL)
    }
}

// MARK: - SandboxEnvironment

/// A sandbox environment configuration.
public struct SandboxEnvironment: Hashable, Sendable, Codable, Equatable {
    public var environmentId: String?
    public var userId: String?
    public var teamId: String?
    public var name: String?
    public var description: String?
    public var repository: String?
    public var defaultBranch: String?
    public var workspaceDirectory: String?
    public var containerImage: String?
    public var setupScript: String?
    public var maintenanceScript: String?
    public var cachingEnabled: Bool?
    public var internetEnabled: Bool?
    public var domainAllowlistPreset: String?
    public var additionalDomains: String?
    public var allowedHttpMethods: String?
    public var preinstalledPackages: [String: String]
    public var createTime: String?
    public var modifyTime: String?
    public var cachedCommitSha: String?
    public var providerId: String?
    public var requestedCpus: UInt32?
    public var requestedMemoryBytes: String?
    public var requestedDiskBytes: String?
    public var requestedGpus: UInt32?

    public init() {
        self.preinstalledPackages = [:]
    }

    enum CodingKeys: String, CodingKey {
        case environmentId
        case userId
        case teamId
        case name
        case description
        case repository
        case defaultBranch
        case workspaceDirectory
        case containerImage
        case setupScript
        case maintenanceScript
        case cachingEnabled
        case internetEnabled
        case domainAllowlistPreset
        case additionalDomains
        case allowedHttpMethods
        case preinstalledPackages
        case createTime
        case modifyTime
        case cachedCommitSha
        case providerId
        case requestedCpus
        case requestedMemoryBytes
        case requestedDiskBytes
        case requestedGpus
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        environmentId = try container.decodeIfPresent(String.self, forKey: .environmentId)
        userId = try container.decodeIfPresent(String.self, forKey: .userId)
        teamId = try container.decodeIfPresent(String.self, forKey: .teamId)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        repository = try container.decodeIfPresent(String.self, forKey: .repository)
        defaultBranch = try container.decodeIfPresent(String.self, forKey: .defaultBranch)
        workspaceDirectory = try container.decodeIfPresent(String.self, forKey: .workspaceDirectory)
        containerImage = try container.decodeIfPresent(String.self, forKey: .containerImage)
        setupScript = try container.decodeIfPresent(String.self, forKey: .setupScript)
        maintenanceScript = try container.decodeIfPresent(String.self, forKey: .maintenanceScript)
        cachingEnabled = try container.decodeIfPresent(Bool.self, forKey: .cachingEnabled)
        internetEnabled = try container.decodeIfPresent(Bool.self, forKey: .internetEnabled)
        domainAllowlistPreset = try container.decodeIfPresent(String.self, forKey: .domainAllowlistPreset)
        additionalDomains = try container.decodeIfPresent(String.self, forKey: .additionalDomains)
        allowedHttpMethods = try container.decodeIfPresent(String.self, forKey: .allowedHttpMethods)
        preinstalledPackages = try container.decodeIfPresent([String: String].self, forKey: .preinstalledPackages) ?? [:]
        createTime = try container.decodeIfPresent(String.self, forKey: .createTime)
        modifyTime = try container.decodeIfPresent(String.self, forKey: .modifyTime)
        cachedCommitSha = try container.decodeIfPresent(String.self, forKey: .cachedCommitSha)
        providerId = try container.decodeIfPresent(String.self, forKey: .providerId)
        requestedCpus = try container.decodeIfPresent(UInt32.self, forKey: .requestedCpus)
        requestedMemoryBytes = try container.decodeIfPresent(String.self, forKey: .requestedMemoryBytes)
        requestedDiskBytes = try container.decodeIfPresent(String.self, forKey: .requestedDiskBytes)
        requestedGpus = try container.decodeIfPresent(UInt32.self, forKey: .requestedGpus)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(environmentId, forKey: .environmentId)
        try container.encodeIfPresent(userId, forKey: .userId)
        try container.encodeIfPresent(teamId, forKey: .teamId)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(repository, forKey: .repository)
        try container.encodeIfPresent(defaultBranch, forKey: .defaultBranch)
        try container.encodeIfPresent(workspaceDirectory, forKey: .workspaceDirectory)
        try container.encodeIfPresent(containerImage, forKey: .containerImage)
        try container.encodeIfPresent(setupScript, forKey: .setupScript)
        try container.encodeIfPresent(maintenanceScript, forKey: .maintenanceScript)
        try container.encodeIfPresent(cachingEnabled, forKey: .cachingEnabled)
        try container.encodeIfPresent(internetEnabled, forKey: .internetEnabled)
        try container.encodeIfPresent(domainAllowlistPreset, forKey: .domainAllowlistPreset)
        try container.encodeIfPresent(additionalDomains, forKey: .additionalDomains)
        try container.encodeIfPresent(allowedHttpMethods, forKey: .allowedHttpMethods)
        if !preinstalledPackages.isEmpty {
            try container.encode(preinstalledPackages, forKey: .preinstalledPackages)
        }
        try container.encodeIfPresent(createTime, forKey: .createTime)
        try container.encodeIfPresent(modifyTime, forKey: .modifyTime)
        try container.encodeIfPresent(cachedCommitSha, forKey: .cachedCommitSha)
        try container.encodeIfPresent(providerId, forKey: .providerId)
        try container.encodeIfPresent(requestedCpus, forKey: .requestedCpus)
        try container.encodeIfPresent(requestedMemoryBytes, forKey: .requestedMemoryBytes)
        try container.encodeIfPresent(requestedDiskBytes, forKey: .requestedDiskBytes)
        try container.encodeIfPresent(requestedGpus, forKey: .requestedGpus)
    }
}

// MARK: - SandboxEnvironmentVariable / SandboxSecretInput

/// An environment variable key-value pair.
public struct SandboxEnvironmentVariable: Hashable, Sendable, Codable, Equatable {
    public var key: String?
    public var value: String?

    public init(key: String? = nil, value: String? = nil) {
        self.key = key
        self.value = value
    }

    enum CodingKeys: String, CodingKey {
        case key
        case value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decodeIfPresent(String.self, forKey: .key)
        value = try container.decodeIfPresent(String.self, forKey: .value)
    }
}

/// A secret input key-value pair for environment creation/update.
public struct SandboxSecretInput: Hashable, Sendable, Codable, Equatable {
    public var key: String?
    public var value: String?

    public init(key: String? = nil, value: String? = nil) {
        self.key = key
        self.value = value
    }

    enum CodingKeys: String, CodingKey {
        case key
        case value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decodeIfPresent(String.self, forKey: .key)
        value = try container.decodeIfPresent(String.self, forKey: .value)
    }
}

// MARK: - SandboxEnvironmentWithMetadata

/// A sandbox environment with its associated metadata.
public struct SandboxEnvironmentWithMetadata: Hashable, Sendable, Codable, Equatable {
    public var environment: SandboxEnvironment?
    public var environmentVariables: [SandboxEnvironmentVariable]
    public var secrets: [SandboxEnvironmentVariable]
    public var userRole: String?

    public init(
        environment: SandboxEnvironment? = nil,
        environmentVariables: [SandboxEnvironmentVariable] = [],
        secrets: [SandboxEnvironmentVariable] = [],
        userRole: String? = nil
    ) {
        self.environment = environment
        self.environmentVariables = environmentVariables
        self.secrets = secrets
        self.userRole = userRole
    }

    enum CodingKeys: String, CodingKey {
        case environment
        case environmentVariables
        case secrets
        case userRole
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        environment = try container.decodeIfPresent(SandboxEnvironment.self, forKey: .environment)
        environmentVariables = try container.decodeIfPresent([SandboxEnvironmentVariable].self, forKey: .environmentVariables) ?? []
        secrets = try container.decodeIfPresent([SandboxEnvironmentVariable].self, forKey: .secrets) ?? []
        userRole = try container.decodeIfPresent(String.self, forKey: .userRole)
    }
}

// MARK: - SandboxListEnvironmentsRequest / SandboxListEnvironmentsResponse

/// Query parameters for listing sandbox environments.
public struct SandboxListEnvironmentsRequest: Hashable, Sendable, Codable, Equatable {
    public var page: Int32?
    public var pageSize: Int32?

    public init(page: Int32? = nil, pageSize: Int32? = nil) {
        self.page = page
        self.pageSize = pageSize
    }

    enum CodingKeys: String, CodingKey {
        case page
        case pageSize
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        page = try container.decodeIfPresent(Int32.self, forKey: .page)
        pageSize = try container.decodeIfPresent(Int32.self, forKey: .pageSize)
    }
}

/// Response from listing sandbox environments.
public struct SandboxListEnvironmentsResponse: Hashable, Sendable, Codable, Equatable {
    public var environments: [SandboxEnvironmentWithMetadata]
    public var page: Int32?
    public var pageSize: Int32?
    public var hasMore: Bool?

    public init(
        environments: [SandboxEnvironmentWithMetadata] = [],
        page: Int32? = nil,
        pageSize: Int32? = nil,
        hasMore: Bool? = nil
    ) {
        self.environments = environments
        self.page = page
        self.pageSize = pageSize
        self.hasMore = hasMore
    }

    enum CodingKeys: String, CodingKey {
        case environments
        case page
        case pageSize
        case hasMore
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        environments = try container.decodeIfPresent([SandboxEnvironmentWithMetadata].self, forKey: .environments) ?? []
        page = try container.decodeIfPresent(Int32.self, forKey: .page)
        pageSize = try container.decodeIfPresent(Int32.self, forKey: .pageSize)
        hasMore = try container.decodeIfPresent(Bool.self, forKey: .hasMore)
    }
}

// MARK: - SandboxCreateEnvironmentRequest / SandboxUpdateEnvironmentRequest

/// Request body for creating a sandbox environment.
public struct SandboxCreateEnvironmentRequest: Hashable, Sendable, Codable, Equatable {
    public var name: String?
    public var description: String?
    public var repository: String?
    public var defaultBranch: String?
    public var workspaceDirectory: String?
    public var containerImage: String?
    public var setupScript: String?
    public var maintenanceScript: String?
    public var cachingEnabled: Bool?
    public var internetEnabled: Bool?
    public var domainAllowlistPreset: String?
    public var additionalDomains: String?
    public var allowedHttpMethods: String?
    public var environmentVariables: [SandboxEnvironmentVariable]?
    public var secrets: [SandboxSecretInput]?
    public var preinstalledPackages: [String: String]
    public var providerId: String?
    public var requestedCpus: UInt32?
    public var requestedMemoryBytes: String?
    public var requestedDiskBytes: String?
    public var requestedGpus: UInt32?

    public init() {
        self.preinstalledPackages = [:]
    }

    enum CodingKeys: String, CodingKey {
        case name
        case description
        case repository
        case defaultBranch
        case workspaceDirectory
        case containerImage
        case setupScript
        case maintenanceScript
        case cachingEnabled
        case internetEnabled
        case domainAllowlistPreset
        case additionalDomains
        case allowedHttpMethods
        case environmentVariables
        case secrets
        case preinstalledPackages
        case providerId
        case requestedCpus
        case requestedMemoryBytes
        case requestedDiskBytes
        case requestedGpus
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        repository = try container.decodeIfPresent(String.self, forKey: .repository)
        defaultBranch = try container.decodeIfPresent(String.self, forKey: .defaultBranch)
        workspaceDirectory = try container.decodeIfPresent(String.self, forKey: .workspaceDirectory)
        containerImage = try container.decodeIfPresent(String.self, forKey: .containerImage)
        setupScript = try container.decodeIfPresent(String.self, forKey: .setupScript)
        maintenanceScript = try container.decodeIfPresent(String.self, forKey: .maintenanceScript)
        cachingEnabled = try container.decodeIfPresent(Bool.self, forKey: .cachingEnabled)
        internetEnabled = try container.decodeIfPresent(Bool.self, forKey: .internetEnabled)
        domainAllowlistPreset = try container.decodeIfPresent(String.self, forKey: .domainAllowlistPreset)
        additionalDomains = try container.decodeIfPresent(String.self, forKey: .additionalDomains)
        allowedHttpMethods = try container.decodeIfPresent(String.self, forKey: .allowedHttpMethods)
        environmentVariables = try container.decodeIfPresent([SandboxEnvironmentVariable].self, forKey: .environmentVariables)
        secrets = try container.decodeIfPresent([SandboxSecretInput].self, forKey: .secrets)
        preinstalledPackages = try container.decodeIfPresent([String: String].self, forKey: .preinstalledPackages) ?? [:]
        providerId = try container.decodeIfPresent(String.self, forKey: .providerId)
        requestedCpus = try container.decodeIfPresent(UInt32.self, forKey: .requestedCpus)
        requestedMemoryBytes = try container.decodeIfPresent(String.self, forKey: .requestedMemoryBytes)
        requestedDiskBytes = try container.decodeIfPresent(String.self, forKey: .requestedDiskBytes)
        requestedGpus = try container.decodeIfPresent(UInt32.self, forKey: .requestedGpus)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(repository, forKey: .repository)
        try container.encodeIfPresent(defaultBranch, forKey: .defaultBranch)
        try container.encodeIfPresent(workspaceDirectory, forKey: .workspaceDirectory)
        try container.encodeIfPresent(containerImage, forKey: .containerImage)
        try container.encodeIfPresent(setupScript, forKey: .setupScript)
        try container.encodeIfPresent(maintenanceScript, forKey: .maintenanceScript)
        try container.encodeIfPresent(cachingEnabled, forKey: .cachingEnabled)
        try container.encodeIfPresent(internetEnabled, forKey: .internetEnabled)
        try container.encodeIfPresent(domainAllowlistPreset, forKey: .domainAllowlistPreset)
        try container.encodeIfPresent(additionalDomains, forKey: .additionalDomains)
        try container.encodeIfPresent(allowedHttpMethods, forKey: .allowedHttpMethods)
        try container.encodeIfPresent(environmentVariables, forKey: .environmentVariables)
        try container.encodeIfPresent(secrets, forKey: .secrets)
        if !preinstalledPackages.isEmpty {
            try container.encode(preinstalledPackages, forKey: .preinstalledPackages)
        }
        try container.encodeIfPresent(providerId, forKey: .providerId)
        try container.encodeIfPresent(requestedCpus, forKey: .requestedCpus)
        try container.encodeIfPresent(requestedMemoryBytes, forKey: .requestedMemoryBytes)
        try container.encodeIfPresent(requestedDiskBytes, forKey: .requestedDiskBytes)
        try container.encodeIfPresent(requestedGpus, forKey: .requestedGpus)
    }
}

/// Request body for updating a sandbox environment.
/// Same shape as `SandboxCreateEnvironmentRequest` (all fields optional).
public typealias SandboxUpdateEnvironmentRequest = SandboxCreateEnvironmentRequest

/// Response wrapping a single environment with metadata.
public struct SandboxEnvironmentResponse: Hashable, Sendable, Codable, Equatable {
    public var environment: SandboxEnvironmentWithMetadata?

    public init(environment: SandboxEnvironmentWithMetadata? = nil) {
        self.environment = environment
    }

    enum CodingKeys: String, CodingKey {
        case environment
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        environment = try container.decodeIfPresent(SandboxEnvironmentWithMetadata.self, forKey: .environment)
    }
}

// MARK: - SandboxPreinstalledPackage / SandboxListPreinstalledPackagesResponse

/// A preinstalled package available for sandbox environments.
public struct SandboxPreinstalledPackage: Hashable, Sendable, Codable, Equatable {
    public var name: String?
    public var versions: [String]
    public var defaultVersion: String?

    public init(name: String? = nil, versions: [String] = [], defaultVersion: String? = nil) {
        self.name = name
        self.versions = versions
        self.defaultVersion = defaultVersion
    }

    enum CodingKeys: String, CodingKey {
        case name
        case versions
        case defaultVersion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        versions = try container.decodeIfPresent([String].self, forKey: .versions) ?? []
        defaultVersion = try container.decodeIfPresent(String.self, forKey: .defaultVersion)
    }
}

/// Response from listing preinstalled packages.
public struct SandboxListPreinstalledPackagesResponse: Hashable, Sendable, Codable, Equatable {
    public var packages: [SandboxPreinstalledPackage]

    public init(packages: [SandboxPreinstalledPackage] = []) {
        self.packages = packages
    }

    enum CodingKeys: String, CodingKey {
        case packages
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        packages = try container.decodeIfPresent([SandboxPreinstalledPackage].self, forKey: .packages) ?? []
    }
}
