// OpenGrokToolsAPI.swift
//
// Open Grok — Swift port of `xai-grok-tools-api` (crates/codegen/xai-grok-tools-api).
//
// Shared API definitions for Grok tools:
//   * Full `xai.grok.tools.v1` protobuf contract (`GrokToolsV1` / `GrokToolsPB.swift`)
//   * Config validation (`ConfigValidation.swift`)
//   * Canonical slash-command wording (`SlashCommands.swift`)
//   * JSON wire `ToolConfigEntry` re-export for session.bind / finalize metadata
//
// Rust crate mapping: crates/codegen/xai-grok-tools-api. See CRATE_MAP.md (W1-S1 / R01).

import Foundation
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokToolRuntime
import OpenGrokToolTypes

// Re-export the shared ToolConfigEntry defined in the runtime layer so
// ToolsAPI consumers have a single JSON wire import surface matching
// session-bind / finalize metadata. The protobuf message of the same
// name lives at `GrokToolsV1.ToolConfigEntry` / `ProtobufToolConfigEntry`.
public typealias ToolConfigEntry = OpenGrokToolRuntime.ToolConfigEntry

/// Alias for Rust-style `pb` module access.
public typealias Pb = GrokToolsV1

/// Default client-facing tool name derived from a namespaced tool id.
///
/// Tool ids are colon-separated `Namespace:tool` (e.g. `GrokBuild:grep`); the
/// default name is the segment after the FIRST colon, so an id with embedded
/// colons (`ns:a:b`) resolves to `a`. Ids without a colon are returned as-is.
///
/// This is the single source of truth shared by the tools server (which
/// advertises tools under this name unless `name_override` is set) and any
/// client that needs to predict the advertised name from a config entry.
public func defaultClientName(_ id: String) -> String {
    // Match Rust: id.split(':').nth(1).unwrap_or(id)
    let all = id.split(separator: ":", omittingEmptySubsequences: false)
    if all.count >= 2 {
        return String(all[1])
    }
    return id
}

// MARK: - JSON ↔ Protobuf ToolConfigEntry bridge

extension GrokToolsV1.ToolConfigEntry {
    /// Build the protobuf message from the JSON wire entry used by session.bind.
    public static func fromJSONWire(_ entry: OpenGrokToolRuntime.ToolConfigEntry) -> GrokToolsV1.ToolConfigEntry {
        GrokToolsV1.ToolConfigEntry(
            id: entry.id,
            paramsJson: entry.paramsJson,
            nameOverride: entry.nameOverride,
            paramsNameOverrides: entry.paramsNameOverrides,
            behaviorVersion: entry.behaviorVersion,
            descriptionOverride: entry.descriptionOverride
        )
    }

    /// Convert to the JSON wire entry used by session.bind / config storage.
    public var jsonWire: OpenGrokToolRuntime.ToolConfigEntry {
        OpenGrokToolRuntime.ToolConfigEntry(
            id: id,
            paramsJson: paramsJson,
            nameOverride: nameOverride,
            paramsNameOverrides: paramsNameOverrides,
            behaviorVersion: behaviorVersion,
            descriptionOverride: descriptionOverride
        )
    }
}

// MARK: - Service descriptors

/// Fully-qualified gRPC service / method paths for `GrokToolsService`.
public enum GrokToolsServiceDescriptor: Sendable {
    public static let packageName = "xai.grok.tools.v1"
    public static let serviceName = "xai.grok.tools.v1.GrokToolsService"

    public static func methodPath(_ rpc: String) -> String {
        "/\(serviceName)/\(rpc)"
    }

    /// All RPC method paths in proto declaration order.
    public static var allMethodPaths: [String] {
        grokToolsServiceRPCNames.map(methodPath)
    }

    public static let methodExecuteTool = methodPath("ExecuteTool")
    public static let methodExecuteToolStream = methodPath("ExecuteToolStream")
    public static let methodListTools = methodPath("ListTools")
    public static let methodGetToolInfo = methodPath("GetToolInfo")
    public static let methodFinalizeToolConfigRequest = methodPath("FinalizeToolConfigRequest")
    public static let methodGetToolState = methodPath("GetToolState")
    public static let methodEnableTool = methodPath("EnableTool")
    public static let methodDisableTool = methodPath("DisableTool")
    public static let methodSetToolOptions = methodPath("SetToolOptions")
    public static let methodGetToolOptions = methodPath("GetToolOptions")
    public static let methodResetToolOptions = methodPath("ResetToolOptions")
    public static let methodSetToolOverride = methodPath("SetToolOverride")
    public static let methodClearToolOverride = methodPath("ClearToolOverride")
    public static let methodSetSystemReminders = methodPath("SetSystemReminders")
    public static let methodGetSystemReminders = methodPath("GetSystemReminders")
    public static let methodSetTruncationConfig = methodPath("SetTruncationConfig")
    public static let methodGetTruncationConfig = methodPath("GetTruncationConfig")
    public static let methodGetSystemPrompt = methodPath("GetSystemPrompt")
    public static let methodGetAgentInfo = methodPath("GetAgentInfo")
    public static let methodGetCompletionState = methodPath("GetCompletionState")
    public static let methodResetCompletionState = methodPath("ResetCompletionState")
    public static let methodFinalizeAgent = methodPath("FinalizeAgent")
}

/// Protobuf package name for the Grok tools service contract.
public let grokToolsProtoPackage = GrokToolsServiceDescriptor.packageName
