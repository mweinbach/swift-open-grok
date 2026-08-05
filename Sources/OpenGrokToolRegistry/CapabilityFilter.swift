// CapabilityFilter.swift
//
// Capability-mode filtering for session toolsets (Rust
// `xai-grok-workspace/src/capability.rs`). Owned here so registry finalization
// can apply it deterministically without inventing a second protocol.

import Foundation

/// Capability mode applied to a session's toolset.
///
/// Partial order: `readOnly < readWrite < all` and `readOnly < execute < all`.
/// `readWrite` and `execute` are incomparable.
public enum ToolCapabilityMode: String, Codable, Sendable, Hashable, CaseIterable {
    case readOnly = "read_only"
    case readWrite = "read_write"
    case execute
    case all

    public static let `default`: ToolCapabilityMode = .readWrite

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode(String.self)
        switch raw {
        case "read_only", "read-only", "readonly": self = .readOnly
        case "read_write", "read-write", "readwrite": self = .readWrite
        case "execute": self = .execute
        case "all": self = .all
        default:
            throw DecodingError.dataCorruptedError(
                in: c, debugDescription: "unknown ToolCapabilityMode: \(raw)"
            )
        }
    }

    /// Drop tools whose kind is not allowed. Tools with `kind == nil` are
    /// preserved (baseline ad-hoc tools).
    public func filter(_ config: ToolServerConfig) -> ToolServerConfig {
        let kept = config.tools.filter { tool in
            guard let kind = tool.kind else { return true }
            return kindAllowed(kind)
        }
        return ToolServerConfig(tools: kept, behaviorPreset: config.behaviorPreset)
    }

    public func kindAllowed(_ kind: ProductToolKind) -> Bool {
        Self.kindAllowed(mode: self, kind: kind)
    }

    public func isSubset(of other: ToolCapabilityMode) -> Bool {
        for kind in ProductToolKind.allCases {
            if kindAllowed(kind) && !other.kindAllowed(kind) {
                return false
            }
        }
        return true
    }

    public static func kindAllowed(mode: ToolCapabilityMode, kind: ProductToolKind) -> Bool {
        if mode == .all { return true }
        switch kind {
        // Meta tools: always allowed. `agentCollaboration` joined this arm in
        // `xai-grok-workspace/src/capability.rs:130-133` — peer messaging is
        // orthogonal to read/write/execute authority.
        case .plan, .enterPlan, .exitPlan, .askUser, .skill, .searchTool, .goalUpdate,
             .agentCollaboration:
            return true
        case .read, .memoryGet, .memorySearch:
            return mode == .readOnly || mode == .readWrite || mode == .execute
        case .search, .webSearch, .webFetch:
            return mode == .readOnly || mode == .readWrite || mode == .execute
        case .lsp, .listDir, .list:
            return mode == .readOnly || mode == .readWrite || mode == .execute
        case .edit, .write, .delete, .move, .imageGen, .videoGen, .imageToVideo,
             .referenceToVideo, .deployApp:
            return mode == .readWrite
        case .execute:
            return mode == .execute
        case .backgroundTaskAction, .waitTasksAction, .killTaskAction, .task,
             .agentSwarm, .workflow, .monitor:
            return mode == .execute
        case .useTool:
            return mode == .readWrite || mode == .execute
        case .other:
            return false
        }
    }
}
