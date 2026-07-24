// Bridge.swift
//
// Session-facing ToolBridge over FinalizedToolset
// (`xai-grok-tools/src/bridge.rs`).

import Foundation
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokToolRuntime
import OpenGrokToolTypes

/// Result of a bridged tool call.
public struct ToolBridgeResult: Sendable, Equatable {
    public var output: TypedToolOutput
    public var promptText: String

    public init(output: TypedToolOutput, promptText: String) {
        self.output = output
        self.promptText = promptText
    }
}

/// Session-facing wrapper over a finalized toolset.
public final class ToolBridge: @unchecked Sendable {
    public let toolset: FinalizedToolset

    public init(toolset: FinalizedToolset) {
        self.toolset = toolset
    }

    /// Finalize a builder into a bridge.
    public static func finalize(
        builder: ToolRegistryBuilder,
        config: ToolServerConfig,
        resources: ToolResources,
        options: FinalizeOptions = .unrestricted
    ) throws -> ToolBridge {
        switch builder.finalize(config: config, resources: resources, options: options) {
        case .success(let set):
            return ToolBridge(toolset: set)
        case .failure(let errors):
            throw ToolBridgeError.finalizeFailed(errors)
        }
    }

    public func toolDefinitions() -> [ToolDescription] {
        toolset.topLevelDefinitions()
    }

    public func nestedToolDefinitions() -> [ToolDescription] {
        toolset.nestedDefinitions()
    }

    public func toolKind(for clientName: String) -> ProductToolKind? {
        toolset.toolKind(for: clientName)
    }

    public func codeModeNamespaces() -> [String: CodeModeToolNamespace] {
        toolset.codeModeNamespaces
    }

    public func call(
        name: String,
        args: JSONValue,
        callId: String = UUID().uuidString
    ) async -> Result<ToolBridgeResult, ToolError> {
        switch await toolset.prepareAndCall(clientName: name, args: args, callId: callId, nested: false) {
        case .success(let typed):
            return .success(ToolBridgeResult(output: typed, promptText: promptText(from: typed)))
        case .failure(let err):
            return .failure(err)
        }
    }

    /// Nested Code Mode call — full prepare/gate/dispatch re-entry.
    public func callNested(
        name: String,
        args: JSONValue,
        callId: String = UUID().uuidString
    ) async -> Result<ToolBridgeResult, ToolError> {
        switch await toolset.callNested(clientName: name, args: args, callId: callId) {
        case .success(let typed):
            return .success(ToolBridgeResult(output: typed, promptText: promptText(from: typed)))
        case .failure(let err):
            return .failure(err)
        }
    }

    private func promptText(from typed: TypedToolOutput) -> String {
        if case .object(let obj) = typed.value {
            if case .string(let s) = obj["prompt_text"] { return s }
            if case .string(let s) = obj["content"] { return s }
            if case .string(let s) = obj["output"] { return s }
        }
        // Fallback: concatenate text content blocks.
        return typed.modelOutput.compactMap { block -> String? in
            if case .text(let t) = block { return t }
            return nil
        }.joined(separator: "\n")
    }
}

public enum ToolBridgeError: Error, Sendable, Equatable {
    case finalizeFailed([RequirementError])
}
