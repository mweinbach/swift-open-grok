// FinalizedToolset.swift
//
// Immutable toolset produced by finalize, with prepare/gate/dispatch
// re-entry for direct and nested Code Mode calls.

import Foundation
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokToolRuntime
import OpenGrokToolTypes
import OpenGrokWorkspace

// MARK: - Finalized tool

public struct FinalizedTool: Sendable {
    public var qualifiedId: String
    public var namespace: ProductToolNamespace
    public var id: String
    public var clientName: String
    public var kind: ProductToolKind
    public var description: String
    public var definition: ToolDescription
    public var inputSchema: JSONValue
    public var reverseParams: [String: String]
    public var contractVersion: String?
    public var visibility: ToolListVisibility
    public var exposure: ToolExposureFlags
    public var handler: (any ToolHandler)?
}

// MARK: - Toolset

/// Toolset produced by `ToolRegistryBuilder.finalize`.
public final class FinalizedToolset: @unchecked Sendable {
    private let lock = NSLock()
    private var toolsByClientName: [String: FinalizedTool]
    private var toolsOrdered: [FinalizedTool]
    public let resources: ToolResources
    public let codeModeNamespaces: [String: CodeModeToolNamespace]
    public let options: FinalizeOptions

    public init(
        tools: [FinalizedTool],
        resources: ToolResources,
        codeModeNamespaces: [String: CodeModeToolNamespace],
        options: FinalizeOptions
    ) {
        self.toolsOrdered = tools
        self.toolsByClientName = Dictionary(uniqueKeysWithValues: tools.map { ($0.clientName, $0) })
        self.resources = resources
        self.codeModeNamespaces = codeModeNamespaces
        self.options = options
    }

    public var clientNames: [String] {
        lock.lock(); defer { lock.unlock() }
        return toolsOrdered.map(\.clientName)
    }

    public func tool(named clientName: String) -> FinalizedTool? {
        lock.lock(); defer { lock.unlock() }
        return toolsByClientName[clientName]
    }

    /// Model-facing top-level definitions (excludes nestedOnly / hidden).
    public func topLevelDefinitions() -> [ToolDescription] {
        lock.lock(); defer { lock.unlock() }
        return toolsOrdered
            .filter { $0.visibility == .topLevel }
            .map(\.definition)
    }

    /// Nested Code Mode definitions (all non-hidden tools).
    public func nestedDefinitions() -> [ToolDescription] {
        lock.lock(); defer { lock.unlock() }
        return toolsOrdered
            .filter { $0.visibility != .hidden }
            .map(\.definition)
    }

    public func toolKind(for clientName: String) -> ProductToolKind? {
        tool(named: clientName)?.kind
    }

    // MARK: Prepare + dispatch

    /// Full prepare → dispatch path. Nested Code Mode calls MUST re-enter here
    /// (same plan gate + hooks + permissions). Never bypass for nested tools.
    public func prepareAndCall(
        clientName: String,
        args: JSONValue,
        callId: String = UUID().uuidString,
        nested: Bool = false
    ) async -> Result<TypedToolOutput, ToolError> {
        guard let tool = tool(named: clientName) else {
            return .failure(toolNotFound(clientName, detail: "tool not found: \(clientName)"))
        }

        if nested && tool.visibility == .hidden {
            return .failure(toolNotFound(clientName, detail: "tool not nested-callable: \(clientName)"))
        }

        // Reverse-remap client param names → canonical.
        let canonical = reverseRemap(args, map: tool.reverseParams)

        // Build AccessKind for permission pipeline.
        let access = accessKind(for: tool, args: canonical)
        let applyPatchLabel = tool.id == "apply_patch"

        if let pipeline = resources.permissionPipeline {
            let prepared = await pipeline.prepare(
                PrepareToolAccessRequest(
                    access: access,
                    toolName: clientName,
                    toolCallId: callId,
                    applyPatchLabel: applyPatchLabel
                )
            )
            if !prepared.mayDispatch {
                return .failure(.permissionDenied(prepared.reason ?? prepared.decision.description))
            }
        }

        guard let handler = tool.handler else {
            return .failure(.notImplemented("no handler registered for \(tool.qualifiedId)"))
        }

        var ctx = ToolCallContext()
        ctx.insert(Cwd(resources.cwd))
        if let version = tool.contractVersion {
            ctx.insert(BehaviorVersion(version))
        }
        ctx.insert(NestedCodeModeCall(nested))

        let result = await handler.invoke(
            clientName: clientName,
            args: canonical,
            ctx: ctx,
            resources: resources
        )

        // Apply output cap with head/tail metadata when oversized.
        switch result {
        case .success(let typed):
            return .success(applyOutputCap(typed, toolId: clientName))
        case .failure(let err):
            return .failure(err)
        }
    }

    /// Nested Code Mode entry — always re-enters prepare/gate/dispatch.
    public func callNested(
        clientName: String,
        args: JSONValue,
        callId: String = UUID().uuidString
    ) async -> Result<TypedToolOutput, ToolError> {
        await prepareAndCall(clientName: clientName, args: args, callId: callId, nested: true)
    }

    /// Register a dynamic (MCP) tool at runtime.
    public func registerDynamic(_ tool: FinalizedTool) {
        lock.lock()
        defer { lock.unlock() }
        toolsByClientName[tool.clientName] = tool
        toolsOrdered.removeAll { $0.clientName == tool.clientName }
        toolsOrdered.append(tool)
        toolsOrdered.sort { $0.clientName < $1.clientName }
    }

    public func unregister(prefix: String) {
        lock.lock()
        defer { lock.unlock() }
        toolsOrdered.removeAll { $0.clientName.hasPrefix(prefix) }
        toolsByClientName = toolsByClientName.filter { !$0.key.hasPrefix(prefix) }
    }
}

// MARK: - Context extensions

public struct BehaviorVersion: Sendable, Hashable {
    public var value: String
    public init(_ value: String) { self.value = value }
}

public struct NestedCodeModeCall: Sendable, Hashable {
    public var isNested: Bool
    public init(_ isNested: Bool) { self.isNested = isNested }
}

// MARK: - Helpers

private func toolNotFound(_ name: String, detail: String) -> ToolError {
    // Prefer the client name as ToolId when well-formed; otherwise a stable placeholder.
    let tid: ToolId
    if let parsed = try? ToolId(name) {
        tid = parsed
    } else if let fallback = try? ToolId("not_found") {
        tid = fallback
    } else {
        // "not_found" is always well-formed; this branch is unreachable.
        return .custom(code: "not_found", detail: detail)
    }
    return .notFound(toolId: tid, detail: detail)
}

private func reverseRemap(_ args: JSONValue, map: [String: String]) -> JSONValue {
    guard !map.isEmpty, case .object(let obj) = args else { return args }
    var out: [String: JSONValue] = [:]
    for (k, v) in obj {
        let canonical = map[k] ?? k
        out[canonical] = v
    }
    return .object(out)
}

private func accessKind(for tool: FinalizedTool, args: JSONValue) -> AccessKind {
    switch tool.kind {
    case .read, .listDir, .list:
        let path = stringArg(args, keys: ["target_file", "path", "file_path", "target_directory", "filePath"])
        return .read(path)
    case .search:
        let path = stringArg(args, keys: ["path", "target_directory"])
        let glob = stringArg(args, keys: ["glob", "pattern"])
        return .grep(path: path, glob: glob)
    case .edit, .write, .delete, .move:
        let path = stringArg(args, keys: ["file_path", "filePath", "path", "target_file"]) ?? ""
        return .edit(path)
    case .execute:
        let cmd = stringArg(args, keys: ["command", "cmd"]) ?? ""
        return .bash(cmd)
    case .webFetch:
        return .webFetch(stringArg(args, keys: ["url"]) ?? "")
    case .webSearch:
        return .webSearch(stringArg(args, keys: ["query"]) ?? "")
    default:
        return .read(nil)
    }
}

private func stringArg(_ args: JSONValue, keys: [String]) -> String? {
    guard case .object(let obj) = args else { return nil }
    for k in keys {
        if case .string(let s) = obj[k] { return s }
    }
    return nil
}

private func applyOutputCap(_ typed: TypedToolOutput, toolId: String) -> TypedToolOutput {
    // Cap large string payloads in value.text / value.content / model text blocks.
    guard case .object(var obj) = typed.value else { return typed }
    var meta: TruncationMetadata?
    for key in ["content", "output", "text", "prompt_text"] {
        if case .string(let s) = obj[key], s.utf8.count > defaultToolOutputBytes {
            let capped = capToolOutput(s, maxBytes: defaultToolOutputBytes)
            obj[key] = .string(capped.modelText)
            meta = capped.metadata
        }
    }
    if let meta {
        obj["truncation"] = .object([
            "truncated": .bool(meta.truncated),
            "total_bytes": .number(.int64(Int64(meta.totalBytes))),
            "shown_bytes": .number(.int64(Int64(meta.shownBytes))),
            "head_chars": .number(.int64(Int64(meta.headChars))),
            "tail_chars": .number(.int64(Int64(meta.tailChars))),
        ])
        var out = typed
        out.value = .object(obj)
        _ = toolId
        return out
    }
    return typed
}

extension PermissionDecision {
    fileprivate var description: String {
        switch self {
        case .allow: return "allow"
        case .ask: return "ask"
        case .followupMessage(let m): return m
        case .reject(let m): return m
        case .policyDeny(let m): return m
        case .cancelled: return "cancelled"
        }
    }
}
