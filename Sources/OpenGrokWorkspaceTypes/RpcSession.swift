// RpcSession.swift
//
// Session file-state / rewind methods. Ported from
// `crates/codegen/xai-grok-workspace-types/src/rpc/session.rs`.

import Foundation
import OpenGrokShared

/// Begin tracking file state for a prompt (`workspace.begin_prompt`).
public struct BeginPromptReq: Hashable, Sendable, Codable, Equatable, WorkspaceRpc {
    public var sessionId: String
    public var promptIndex: UInt64

    public init(sessionId: String, promptIndex: UInt64) {
        self.sessionId = sessionId
        self.promptIndex = promptIndex
    }

    public static let method: String = "workspace.begin_prompt"
    public typealias Response = WorkspaceRpcUnit

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case promptIndex = "prompt_index"
    }
}

/// End tracking file state for a prompt (`workspace.end_prompt`).
public struct EndPromptReq: Hashable, Sendable, Codable, Equatable, WorkspaceRpc {
    public var sessionId: String
    public var promptIndex: UInt64

    public init(sessionId: String, promptIndex: UInt64) {
        self.sessionId = sessionId
        self.promptIndex = promptIndex
    }

    public static let method: String = "workspace.end_prompt"
    public typealias Response = WorkspaceRpcUnit

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case promptIndex = "prompt_index"
    }
}

/// Rewind files to the state before a given prompt index (`workspace.rewind_to`).
public struct RewindToReq: Hashable, Sendable, Codable, Equatable, WorkspaceRpc {
    public var sessionId: String
    public var targetPromptIndex: UInt64

    public init(sessionId: String, targetPromptIndex: UInt64) {
        self.sessionId = sessionId
        self.targetPromptIndex = targetPromptIndex
    }

    public static let method: String = "workspace.rewind_to"
    public typealias Response = FileRewindResponse

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case targetPromptIndex = "target_prompt_index"
    }
}

/// Type of external modification detected during file rewind.
public enum FileRewindConflictType: Hashable, Sendable, Codable, Equatable {
    case deletedExternally
    case createdExternally
    case modifiedExternally

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        switch try c.decode(String.self) {
        case "deleted_externally": self = .deletedExternally
        case "created_externally": self = .createdExternally
        case "modified_externally": self = .modifiedExternally
        default:
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "unknown FileRewindConflictType")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .deletedExternally: try c.encode("deleted_externally")
        case .createdExternally: try c.encode("created_externally")
        case .modifiedExternally: try c.encode("modified_externally")
        }
    }
}

/// A single conflict detected during file rewind.
public struct FileRewindConflict: Hashable, Sendable, Codable, Equatable {
    public var path: String
    public var conflictType: FileRewindConflictType

    public init(path: String, conflictType: FileRewindConflictType) {
        self.path = path
        self.conflictType = conflictType
    }

    enum CodingKeys: String, CodingKey {
        case path
        case conflictType = "conflict_type"
    }
}

/// Response returned by `workspace.rewind_to`.
public struct FileRewindResponse: Hashable, Sendable, Codable, Equatable {
    public var success: Bool
    public var targetPromptIndex: UInt64
    public var revertedFiles: [String]
    public var cleanFiles: [String]
    public var conflicts: [FileRewindConflict]
    public var error: String?

    public init(
        success: Bool,
        targetPromptIndex: UInt64,
        revertedFiles: [String] = [],
        cleanFiles: [String] = [],
        conflicts: [FileRewindConflict] = [],
        error: String? = nil
    ) {
        self.success = success
        self.targetPromptIndex = targetPromptIndex
        self.revertedFiles = revertedFiles
        self.cleanFiles = cleanFiles
        self.conflicts = conflicts
        self.error = error
    }

    enum CodingKeys: String, CodingKey {
        case success
        case targetPromptIndex = "target_prompt_index"
        case revertedFiles = "reverted_files"
        case cleanFiles = "clean_files"
        case conflicts
        case error
    }
}
