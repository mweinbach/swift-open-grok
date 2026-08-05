// MCPToolBridge.swift
//
// Exposes tools discovered on connected MCP servers through the finalized
// toolset, so a live session can call them exactly like a file tool.
//
// Naming follows the Rust convention: a bridged tool is registered under
// `{server}__{tool}` — server name, the two-underscore delimiter, then the raw
// tool name. See `MCP_TOOL_NAME_DELIMITER` in
// `crates/codegen/xai-grok-workspace-types/src/lib.rs:94` and the registration
// site `McpTool::into_registration` in
// `crates/codegen/xai-grok-mcp/src/servers.rs:1291-1334`. There is no `mcp__`
// prefix; two servers exposing the same raw tool name get distinct entries
// because the server name is part of the key.
//
// This file deliberately does NOT import `OpenGrokMCP`. The registry sits below
// MCP in the dependency graph, so the concrete client is injected through
// `MCPToolProviding` and the conformance lives in the composition layer.

import Foundation
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokToolRuntime
import OpenGrokToolTypes
import OpenGrokWorkspace

// MARK: - Naming

/// Separator between the server name and the raw tool name.
public let mcpToolNameDelimiter = "__"

/// Qualified registry name for a tool on `server`.
public func mcpQualifiedToolName(server: String, tool: String) -> String {
    server + mcpToolNameDelimiter + tool
}

/// Prefix used to unregister every tool belonging to `server`.
public func mcpServerToolPrefix(_ server: String) -> String {
    server + mcpToolNameDelimiter
}

/// Split a qualified name back into its server and tool halves.
///
/// Rejects names with no delimiter and names with more than one delimiter
/// boundary, so an ambiguous `a___b` (which could split two ways) is refused
/// rather than silently mis-attributed. Mirrors `parse_mcp_qualified_name`
/// (`crates/codegen/xai-grok-mcp/src/servers.rs:1063-1080`).
public func parseMCPQualifiedToolName(_ name: String) -> (server: String, tool: String)? {
    let characters = Array(name)
    let delimiter = Array(mcpToolNameDelimiter)
    guard characters.count > delimiter.count else { return nil }

    var boundaries: [Int] = []
    for start in 0...(characters.count - delimiter.count) where
        Array(characters[start..<(start + delimiter.count)]) == delimiter {
        boundaries.append(start)
    }
    guard boundaries.count == 1, let boundary = boundaries.first else { return nil }

    let server = String(characters[0..<boundary])
    let tool = String(characters[(boundary + delimiter.count)...])
    guard !server.isEmpty, !tool.isEmpty else { return nil }
    return (server, tool)
}

// MARK: - Provider seam

/// A tool advertised by a connected MCP server.
public struct MCPBridgedTool: Sendable, Equatable {
    /// Raw name as the server reports it, without the server prefix.
    public var name: String
    public var description: String
    public var inputSchema: JSONValue
    /// Servers may hide a tool from the model via `_meta.ui.visibility`.
    public var modelVisible: Bool

    public init(
        name: String,
        description: String,
        inputSchema: JSONValue = .object(["type": .string("object")]),
        modelVisible: Bool = true
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.modelVisible = modelVisible
    }
}

/// Result of a bridged call, already flattened out of MCP content blocks.
public struct MCPBridgedCallResult: Sendable, Equatable {
    public var text: String
    public var structuredContent: JSONValue?
    public var isError: Bool

    public init(text: String, structuredContent: JSONValue? = nil, isError: Bool = false) {
        self.text = text
        self.structuredContent = structuredContent
        self.isError = isError
    }
}

/// The connected-server capability the bridge needs. Implemented over the real
/// `MCPClient` actor in the composition layer, and over a stub in tests.
public protocol MCPToolProviding: Sendable {
    /// Name this server is registered under; the `{server}` half of every
    /// qualified tool name.
    var serverName: String { get }

    func listBridgedTools() async throws -> [MCPBridgedTool]

    func callBridgedTool(
        name: String,
        arguments: JSONValue
    ) async throws -> MCPBridgedCallResult
}

// MARK: - Handler

/// Bridges one MCP tool into `ToolHandler`.
///
/// A transport failure surfaces as a `ToolError` returned to the model, never
/// as a thrown error or a trap: a server that dies mid-session degrades that
/// server's tools and leaves the rest of the toolset callable.
struct MCPBridgedToolHandler: ToolHandler {
    let provider: any MCPToolProviding
    /// Raw (unqualified) tool name to send back over the wire.
    let rawToolName: String
    let toolId: ToolId

    func invoke(
        clientName: String,
        args: JSONValue,
        ctx: ToolCallContext,
        resources: ToolResources
    ) async -> Result<TypedToolOutput, ToolError> {
        _ = ctx
        _ = resources
        do {
            let result = try await provider.callBridgedTool(
                name: rawToolName,
                arguments: normalizeArguments(args)
            )
            if result.isError {
                return .failure(ToolError(
                    kind: .execution,
                    detail: result.text.isEmpty
                        ? "MCP tool '\(clientName)' reported an error"
                        : result.text
                ))
            }
            var value: [String: JSONValue] = ["content": .string(result.text)]
            if let structured = result.structuredContent {
                value["structuredContent"] = structured
            }
            return .success(TypedToolOutput(
                toolId: toolId,
                value: .object(value),
                modelOutput: [.text(text: result.text)]
            ))
        } catch {
            return .failure(ToolError(
                kind: .execution,
                detail: "MCP tool '\(clientName)' failed: \(describe(error))"
            ))
        }
    }

    /// MCP servers expect an object for `arguments`; anything else is wrapped
    /// rather than rejected so a model passing a bare value still reaches the
    /// server with a well-formed request.
    private func normalizeArguments(_ args: JSONValue) -> JSONValue {
        if case .object = args { return args }
        if case .null = args { return .object([:]) }
        return .object(["value": args])
    }

    private func describe(_ error: Error) -> String {
        if let described = error as? CustomStringConvertible {
            return described.description
        }
        return String(describing: error)
    }
}

// MARK: - Bridge

/// What happened when a server's tools were bridged in.
public struct MCPBridgeRegistration: Sendable, Equatable {
    public var serverName: String
    /// Qualified names now callable through the toolset.
    public var registeredNames: [String]
    /// Tools the server advertised but that were not registered, with why.
    public var skipped: [String: String]
    /// Set when the whole server failed (transport down, malformed list).
    public var failure: String?

    public init(
        serverName: String,
        registeredNames: [String] = [],
        skipped: [String: String] = [:],
        failure: String? = nil
    ) {
        self.serverName = serverName
        self.registeredNames = registeredNames
        self.skipped = skipped
        self.failure = failure
    }

    public var isFailure: Bool { failure != nil }
}

public enum MCPToolBridge {
    /// Discover `provider`'s tools and register them into `toolset`.
    ///
    /// Never throws. A server that is down, that returns garbage, or that
    /// advertises unusable tool names yields a registration carrying the
    /// failure while the toolset is left untouched and fully usable.
    @discardableResult
    public static func register(
        provider: any MCPToolProviding,
        into toolset: FinalizedToolset
    ) async -> MCPBridgeRegistration {
        let server = provider.serverName
        guard isUsableNameSegment(server) else {
            return MCPBridgeRegistration(
                serverName: server,
                failure: "server name '\(server)' is not a usable tool-name segment"
            )
        }
        // Mutation surface is unknown for MCP tools, so they are never part of
        // a read-only session.
        if toolset.options.capabilityMode == .readOnly {
            return MCPBridgeRegistration(
                serverName: server,
                failure: "MCP tools are not exposed in read-only capability mode"
            )
        }

        let discovered: [MCPBridgedTool]
        do {
            discovered = try await provider.listBridgedTools()
        } catch {
            return MCPBridgeRegistration(
                serverName: server,
                failure: "tools/list failed: \(error)"
            )
        }

        var registered: [String] = []
        var skipped: [String: String] = [:]

        for tool in discovered {
            guard tool.modelVisible else {
                skipped[tool.name] = "hidden by the server"
                continue
            }
            guard isUsableNameSegment(tool.name) else {
                skipped[tool.name] = "tool name is not a usable tool-name segment"
                continue
            }
            let clientName = mcpQualifiedToolName(server: server, tool: tool.name)
            guard let toolId = try? ToolId(clientName) else {
                skipped[tool.name] = "qualified name '\(clientName)' is not a valid tool id"
                continue
            }
            guard toolset.options.nameFilters.admits(clientName: clientName) else {
                skipped[tool.name] = "excluded by session tool filters"
                continue
            }

            let description = tool.description.isEmpty
                ? "MCP tool '\(tool.name)' on server '\(server)'."
                : tool.description
            let definition = ToolDescription(name: clientName, description: description)
                .withKind(ProductToolKind.other.rawValue)
                .withNamespace(ProductToolNamespace.mcp.rawValue)
                .withArgumentsSchema(tool.inputSchema)

            toolset.registerDynamic(FinalizedTool(
                qualifiedId: "\(ProductToolNamespace.mcp.displayName):\(clientName)",
                namespace: .mcp,
                id: clientName,
                clientName: clientName,
                kind: .other,
                description: description,
                definition: definition,
                inputSchema: tool.inputSchema,
                reverseParams: [:],
                contractVersion: nil,
                visibility: .topLevel,
                exposure: .ordinary,
                handler: MCPBridgedToolHandler(
                    provider: provider,
                    rawToolName: tool.name,
                    toolId: toolId
                )
            ))
            registered.append(clientName)
        }

        return MCPBridgeRegistration(
            serverName: server,
            registeredNames: registered,
            skipped: skipped
        )
    }

    /// Drop every tool belonging to `server`. Safe when nothing is registered.
    public static func unregister(server: String, from toolset: FinalizedToolset) {
        toolset.unregister(prefix: mcpServerToolPrefix(server))
    }

    /// Qualified names currently registered for `server`.
    public static func registeredNames(
        for server: String,
        in toolset: FinalizedToolset
    ) -> [String] {
        let prefix = mcpServerToolPrefix(server)
        return toolset.clientNames.filter { $0.hasPrefix(prefix) }
    }

    /// A segment is usable when it is a legal tool-id segment and contains no
    /// delimiter of its own — an embedded `__` would make the qualified name
    /// ambiguous to split.
    static func isUsableNameSegment(_ segment: String) -> Bool {
        guard !segment.isEmpty, !segment.contains(mcpToolNameDelimiter) else { return false }
        return segment.allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber
                || character == "_" || character == "-")
        }
    }
}
