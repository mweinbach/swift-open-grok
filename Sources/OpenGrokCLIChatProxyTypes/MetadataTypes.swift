// MetadataTypes.swift
//
// Prompt metadata types shared between the CLI client and the cli-chat-proxy
// server. Ported from prod/mc/cli-chat-proxy-types/src/metadata_types.rs.
//
// The CLI client serializes `PromptMetadata` and uploads it as `metadata.json`
// to GCS via the `/v1/storage` endpoint. The server deserializes it to inject
// authenticated user identity fields (`user_id`, `user_email`) before
// forwarding to GCS.

import Foundation

// MARK: - Schema version

/// Schema version for the GCS metadata format.
///
/// v1.23: Removed `prompt`, `full_prompt`, and `truncated_prompt_local_path`
/// from metadata.json (prompt content is no longer uploaded in metadata).
public let gcsSchemaVersion = "v1.23"

// MARK: - LocalSandboxTelemetry

/// OS-level sandbox state for a trace turn (local sandbox, not cloud sandbox).
public struct LocalSandboxTelemetry: Hashable, Sendable, Codable, Equatable {
    public var profile: String
    public var applied: Bool

    public init(profile: String, applied: Bool) {
        self.profile = profile
        self.applied = applied
    }
}

// MARK: - PromptMetadata

/// Metadata about a prompt turn, uploaded as JSON for tracing/debugging.
///
/// Path format: `{session_id}/turn_{N}/metadata.json`
public struct PromptMetadata: Hashable, Sendable, Codable, Equatable {
    public var schemaVersion: String
    public var sessionId: String
    public var turnNumber: UInt64
    public var requestId: String
    public var turnStartedAt: String
    public var repoRoot: String?
    public var remoteURL: String?
    public var workspaceType: String?
    public var userId: String?
    public var userEmail: String?
    public var teamId: String?
    public var clientSource: String?
    public var clientVersion: String?
    public var model: String
    public var reasoningEffort: String?
    public var experimentId: String?
    public var hostOS: String
    public var hostArch: String
    public var promptHasImage: Bool?
    public var promptWasTruncated: Bool?
    public var promptVerbatim: Bool?
    public var cwd: String?
    public var agentType: String?
    public var shellVersion: String?
    public var sandbox: LocalSandboxTelemetry?

    public init(
        schemaVersion: String = gcsSchemaVersion,
        sessionId: String,
        turnNumber: UInt64,
        requestId: String,
        turnStartedAt: String,
        repoRoot: String? = nil,
        remoteURL: String? = nil,
        workspaceType: String? = nil,
        userId: String? = nil,
        userEmail: String? = nil,
        teamId: String? = nil,
        clientSource: String? = nil,
        clientVersion: String? = nil,
        model: String,
        reasoningEffort: String? = nil,
        experimentId: String? = nil,
        hostOS: String,
        hostArch: String,
        promptHasImage: Bool? = nil,
        promptWasTruncated: Bool? = nil,
        promptVerbatim: Bool? = nil,
        cwd: String? = nil,
        agentType: String? = nil,
        shellVersion: String? = nil,
        sandbox: LocalSandboxTelemetry? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.sessionId = sessionId
        self.turnNumber = turnNumber
        self.requestId = requestId
        self.turnStartedAt = turnStartedAt
        self.repoRoot = repoRoot
        self.remoteURL = remoteURL
        self.workspaceType = workspaceType
        self.userId = userId
        self.userEmail = userEmail
        self.teamId = teamId
        self.clientSource = clientSource
        self.clientVersion = clientVersion
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.experimentId = experimentId
        self.hostOS = hostOS
        self.hostArch = hostArch
        self.promptHasImage = promptHasImage
        self.promptWasTruncated = promptWasTruncated
        self.promptVerbatim = promptVerbatim
        self.cwd = cwd
        self.agentType = agentType
        self.shellVersion = shellVersion
        self.sandbox = sandbox
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case sessionId = "session_id"
        case turnNumber = "turn_number"
        case requestId = "request_id"
        case turnStartedAt = "turn_started_at"
        case repoRoot = "repo_root"
        case remoteURL = "remote_url"
        case workspaceType = "workspace_type"
        case userId = "user_id"
        case userEmail = "user_email"
        case teamId = "team_id"
        case clientSource = "client_source"
        case clientVersion = "client_version"
        case model
        case reasoningEffort = "reasoning_effort"
        case experimentId = "experiment_id"
        case hostOS = "host_os"
        case hostArch = "host_arch"
        case promptHasImage = "prompt_has_image"
        case promptWasTruncated = "prompt_was_truncated"
        case promptVerbatim = "prompt_verbatim"
        case cwd
        case agentType = "agent_type"
        case shellVersion = "shell_version"
        case sandbox
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(String.self, forKey: .schemaVersion)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        turnNumber = try container.decode(UInt64.self, forKey: .turnNumber)
        requestId = try container.decode(String.self, forKey: .requestId)
        turnStartedAt = try container.decode(String.self, forKey: .turnStartedAt)
        repoRoot = try container.decodeIfPresent(String.self, forKey: .repoRoot)
        remoteURL = try container.decodeIfPresent(String.self, forKey: .remoteURL)
        workspaceType = try container.decodeIfPresent(String.self, forKey: .workspaceType)
        userId = try container.decodeIfPresent(String.self, forKey: .userId)
        userEmail = try container.decodeIfPresent(String.self, forKey: .userEmail)
        teamId = try container.decodeIfPresent(String.self, forKey: .teamId)
        clientSource = try container.decodeIfPresent(String.self, forKey: .clientSource)
        clientVersion = try container.decodeIfPresent(String.self, forKey: .clientVersion)
        model = try container.decode(String.self, forKey: .model)
        reasoningEffort = try container.decodeIfPresent(String.self, forKey: .reasoningEffort)
        experimentId = try container.decodeIfPresent(String.self, forKey: .experimentId)
        hostOS = try container.decode(String.self, forKey: .hostOS)
        hostArch = try container.decode(String.self, forKey: .hostArch)
        promptHasImage = try container.decodeIfPresent(Bool.self, forKey: .promptHasImage)
        promptWasTruncated = try container.decodeIfPresent(Bool.self, forKey: .promptWasTruncated)
        promptVerbatim = try container.decodeIfPresent(Bool.self, forKey: .promptVerbatim)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        agentType = try container.decodeIfPresent(String.self, forKey: .agentType)
        shellVersion = try container.decodeIfPresent(String.self, forKey: .shellVersion)
        sandbox = try container.decodeIfPresent(LocalSandboxTelemetry.self, forKey: .sandbox)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(turnNumber, forKey: .turnNumber)
        try container.encode(requestId, forKey: .requestId)
        try container.encode(turnStartedAt, forKey: .turnStartedAt)
        try container.encodeIfPresent(repoRoot, forKey: .repoRoot)
        try container.encodeIfPresent(remoteURL, forKey: .remoteURL)
        try container.encodeIfPresent(workspaceType, forKey: .workspaceType)
        try container.encodeIfPresent(userId, forKey: .userId)
        try container.encodeIfPresent(userEmail, forKey: .userEmail)
        try container.encodeIfPresent(teamId, forKey: .teamId)
        try container.encodeIfPresent(clientSource, forKey: .clientSource)
        try container.encodeIfPresent(clientVersion, forKey: .clientVersion)
        try container.encode(model, forKey: .model)
        try container.encodeIfPresent(reasoningEffort, forKey: .reasoningEffort)
        try container.encodeIfPresent(experimentId, forKey: .experimentId)
        try container.encode(hostOS, forKey: .hostOS)
        try container.encode(hostArch, forKey: .hostArch)
        try container.encodeIfPresent(promptHasImage, forKey: .promptHasImage)
        try container.encodeIfPresent(promptWasTruncated, forKey: .promptWasTruncated)
        try container.encodeIfPresent(promptVerbatim, forKey: .promptVerbatim)
        try container.encodeIfPresent(cwd, forKey: .cwd)
        try container.encodeIfPresent(agentType, forKey: .agentType)
        try container.encodeIfPresent(shellVersion, forKey: .shellVersion)
        try container.encodeIfPresent(sandbox, forKey: .sandbox)
    }
}
