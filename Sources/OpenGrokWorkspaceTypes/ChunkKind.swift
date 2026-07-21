// ChunkKind.swift
//
// Static discriminator for every variant across `ToolChunk`, `OpsChunk`,
// and `SessionChunk`. Ported from
// crates/codegen/xai-grok-workspace-types/src/chunks/mod.rs.
//
// Used as the `got` field of `WorkspaceError.protocolMismatch`. Each chunk
// enum exposes a `kind()` method that returns its current variant's
// discriminator. The discriminator is also serialized (snake_case wire
// form) so consumers can persist it as a stable label.

import Foundation

/// Static discriminator for every variant across `ToolChunk`, `OpsChunk`,
/// and `SessionChunk`.
public enum ChunkKind: Hashable, Sendable, Codable, Equatable, CaseIterable {
    // ToolChunk variants
    case toolOutput
    case toolProgress
    case toolFinal
    case toolDefinitions
    case needPermission
    case needUserAnswer
    case needPlanModeChange

    // OpsChunk variants
    case gitStatus
    case gitDiff
    case gitBranchInfo
    case gitMetadata
    case hunks
    case skills
    case plugins
    case projectConfig
    case permissions
    case envrc
    case resolvedFiles
    case memoryChunks
    case plugin
    case ack
    case fuzzyMatch
    case ripgrepHit
    case ripgrepDone

    // SessionChunk variants
    case sessionId
    case sessionInfo
    case rewindResult
    case rewindPoints
    case sessionAck

    /// Stable static name (used for error messages and persistence).
    ///
    /// Implemented as an exhaustive `switch` so that adding a new variant
    /// fails compilation here — `allCases` depends on this property to stay
    /// in sync with the enum.
    public var asString: String {
        switch self {
        case .toolOutput: return "ToolOutput"
        case .toolProgress: return "ToolProgress"
        case .toolFinal: return "ToolFinal"
        case .toolDefinitions: return "ToolDefinitions"
        case .needPermission: return "NeedPermission"
        case .needUserAnswer: return "NeedUserAnswer"
        case .needPlanModeChange: return "NeedPlanModeChange"

        case .gitStatus: return "GitStatus"
        case .gitDiff: return "GitDiff"
        case .gitBranchInfo: return "GitBranchInfo"
        case .gitMetadata: return "GitMetadata"
        case .hunks: return "Hunks"
        case .skills: return "Skills"
        case .plugins: return "Plugins"
        case .projectConfig: return "ProjectConfig"
        case .permissions: return "Permissions"
        case .envrc: return "Envrc"
        case .resolvedFiles: return "ResolvedFiles"
        case .memoryChunks: return "MemoryChunks"
        case .plugin: return "Plugin"
        case .ack: return "Ack"
        case .fuzzyMatch: return "FuzzyMatch"
        case .ripgrepHit: return "RipgrepHit"
        case .ripgrepDone: return "RipgrepDone"

        case .sessionId: return "SessionId"
        case .sessionInfo: return "SessionInfo"
        case .rewindResult: return "RewindResult"
        case .rewindPoints: return "RewindPoints"
        case .sessionAck: return "SessionAck"
        }
    }

    // MARK: Codable — snake_case wire form

    private static let wireNames: [(ChunkKind, String)] = [
        (.toolOutput, "tool_output"),
        (.toolProgress, "tool_progress"),
        (.toolFinal, "tool_final"),
        (.toolDefinitions, "tool_definitions"),
        (.needPermission, "need_permission"),
        (.needUserAnswer, "need_user_answer"),
        (.needPlanModeChange, "need_plan_mode_change"),

        (.gitStatus, "git_status"),
        (.gitDiff, "git_diff"),
        (.gitBranchInfo, "git_branch_info"),
        (.gitMetadata, "git_metadata"),
        (.hunks, "hunks"),
        (.skills, "skills"),
        (.plugins, "plugins"),
        (.projectConfig, "project_config"),
        (.permissions, "permissions"),
        (.envrc, "envrc"),
        (.resolvedFiles, "resolved_files"),
        (.memoryChunks, "memory_chunks"),
        (.plugin, "plugin"),
        (.ack, "ack"),
        (.fuzzyMatch, "fuzzy_match"),
        (.ripgrepHit, "ripgrep_hit"),
        (.ripgrepDone, "ripgrep_done"),

        (.sessionId, "session_id"),
        (.sessionInfo, "session_info"),
        (.rewindResult, "rewind_result"),
        (.rewindPoints, "rewind_points"),
        (.sessionAck, "session_ack")
    ]

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        for (kind, name) in ChunkKind.wireNames where name == raw {
            self = kind
            return
        }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "unknown ChunkKind wire name: \(raw)")
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        for (kind, name) in ChunkKind.wireNames where kind == self {
            try container.encode(name)
            return
        }
        throw EncodingError.invalidValue(self, .init(codingPath: encoder.codingPath, debugDescription: "ChunkKind has no wire name"))
    }
}

extension ChunkKind: CustomStringConvertible {
    public var description: String { asString }
}
