// MCPToolBridge.swift
//
// Exposes tools discovered on connected MCP servers through the finalized
// toolset, so a live session can call them exactly like a file tool.
//
// Naming follows the Rust convention: a bridged tool is registered under
// `{server}__{tool}` — server name, the two-underscore delimiter, then the raw
// tool name. There is no `mcp__` prefix; two servers exposing the same raw tool
// name get distinct entries because the server name is part of the key.
//
// A server name that is not a provider-safe identifier is hex-encoded into the
// reserved `_mcp_` namespace rather than causing the tool to be dropped, so
// servers called `"DS Dev"` or `"123"` still reach the model. Ported from
// `crates/codegen/xai-grok-mcp/src/servers.rs:47-155` at pin 9ed09e2a; the
// delimiter's canonical home is `MCP_TOOL_NAME_DELIMITER` in
// `OpenGrokWorkspaceTypes` (Rust: `xai-grok-workspace-types`).
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
import OpenGrokWorkspaceTypes

// MARK: - Naming

/// Reserved namespace prefix for hex-encoded server names.
public let encodedMCPServerPrefix = "_mcp_"

/// Whether `name` satisfies the strictest cross-provider tool-name rules:
/// `^[a-zA-Z_][a-zA-Z0-9_-]{0,63}$`.
///
/// Must start with a letter or underscore (Gemini), allows only alphanumerics,
/// underscores, and hyphens — no dots (Anthropic/OpenAI) — and caps at 64
/// characters. Mirrors `validate_tool_name` (`servers.rs:81-100`).
public func validateMCPToolName(_ name: String) -> Bool {
    let characters = Array(name)
    guard !characters.isEmpty, characters.count <= 64 else { return false }
    guard let first = characters[0] as Character?,
          first.isASCII, first.isLetter || first == "_" else { return false }
    return characters.dropFirst().allSatisfy { character in
        character.isASCII
            && (character.isLetter || character.isNumber
                || character == "_" || character == "-")
    }
}

/// Server name as it appears in a qualified tool name.
///
/// Used verbatim only when it cannot be confused with an encoded namespace, has
/// no embedded delimiter, does not end in `_` (which would create an ambiguous
/// `___` boundary against the delimiter), and is itself a valid tool name.
/// Otherwise every UTF-8 byte is hex-encoded behind `_mcp_`. Mirrors
/// `encode_mcp_server_namespace` (`servers.rs:102-119`).
public func encodeMCPServerNamespace(_ serverName: String) -> String {
    if !serverName.hasPrefix(encodedMCPServerPrefix),
       !serverName.contains(MCP_TOOL_NAME_DELIMITER),
       !serverName.hasSuffix("_"),
       validateMCPToolName(serverName) {
        return serverName
    }
    var encoded = encodedMCPServerPrefix
    for byte in Array(serverName.utf8) {
        encoded += String(format: "%02x", byte)
    }
    return encoded
}

/// Reverse `encodeMCPServerNamespace`. Anything that is not a well-formed
/// encoding — absent prefix, empty or odd-length hex, a bad hex digit, or bytes
/// that are not valid UTF-8 — is returned unchanged rather than treated as an
/// error. Mirrors `decode_mcp_server_namespace` (`servers.rs:121-140`).
public func decodeMCPServerNamespace(_ namespace: String) -> String {
    guard namespace.hasPrefix(encodedMCPServerPrefix) else { return namespace }
    // Byte-oriented like the Rust original, so a multi-byte character in the
    // hex region fails the same way rather than splitting differently.
    let hex = Array(namespace.dropFirst(encodedMCPServerPrefix.count).utf8)
    guard !hex.isEmpty, hex.count % 2 == 0 else { return namespace }

    var bytes: [UInt8] = []
    bytes.reserveCapacity(hex.count / 2)
    for index in stride(from: 0, to: hex.count, by: 2) {
        guard let pair = String(bytes: [hex[index], hex[index + 1]], encoding: .utf8),
              let byte = UInt8(pair, radix: 16) else {
            return namespace
        }
        bytes.append(byte)
    }
    guard let decoded = String(bytes: bytes, encoding: .utf8) else { return namespace }
    return decoded
}

/// Prefix every tool on `server` is registered under, and the prefix used to
/// unregister them. Mirrors `mcp_tool_name_prefix` (`servers.rs:142-148`).
public func mcpToolNamePrefix(_ server: String) -> String {
    encodeMCPServerNamespace(server) + MCP_TOOL_NAME_DELIMITER
}

/// Qualified registry name for a tool on `server`, or `nil` when no
/// provider-safe name can represent it.
///
/// Mirrors `qualified_mcp_tool_name` (`servers.rs:150-155`): the result must
/// both split cleanly and be a valid tool name, which is what rejects an
/// over-long pair or a tool whose own name reintroduces a delimiter.
public func qualifiedMCPToolName(server: String, tool: String) -> String? {
    let qualified = mcpToolNamePrefix(server) + tool
    guard parseMCPQualifiedToolName(qualified) != nil else { return nil }
    guard validateMCPToolName(qualified) else { return nil }
    return qualified
}

/// Split a qualified name into its raw server-namespace and tool halves.
///
/// Rejects names with no delimiter and names with more than one delimiter
/// boundary, so an ambiguous `a___b` (which could split two ways) is refused
/// rather than silently mis-attributed. The server half is returned still
/// encoded — use `parseMCPToolName` for the original name. Mirrors
/// `parse_mcp_qualified_name` (`servers.rs:1120-1138`).
public func parseMCPQualifiedToolName(_ name: String) -> (server: String, tool: String)? {
    let bytes = Array(name.utf8)
    let delimiter = Array(MCP_TOOL_NAME_DELIMITER.utf8)
    guard bytes.count >= delimiter.count else { return nil }

    // Overlapping byte windows, so `___` correctly yields two boundaries.
    var boundaries: [Int] = []
    for start in 0...(bytes.count - delimiter.count)
    where Array(bytes[start..<(start + delimiter.count)]) == delimiter {
        boundaries.append(start)
        if boundaries.count > 1 { return nil }
    }
    guard let boundary = boundaries.first else { return nil }

    let server = String(decoding: bytes[0..<boundary], as: UTF8.self)
    let tool = String(decoding: bytes[(boundary + delimiter.count)...], as: UTF8.self)
    guard !server.isEmpty, !tool.isEmpty else { return nil }
    guard (try? ToolId(name)) != nil else { return nil }
    return (server, tool)
}

/// Split a qualified name, decoding the server half back to the name the user
/// configured. Mirrors `parse_mcp_tool_name` (`servers.rs:1141-1144`).
public func parseMCPToolName(_ name: String) -> (server: String, tool: String)? {
    guard let parsed = parseMCPQualifiedToolName(name) else { return nil }
    return (decodeMCPServerNamespace(parsed.server), parsed.tool)
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
        // A server name that is not provider-safe is hex-encoded rather than
        // rejected, so naming is decided per tool below, never per server.
        //
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
            guard let clientName = qualifiedMCPToolName(server: server, tool: tool.name),
                  let toolId = try? ToolId(clientName) else {
                skipped[tool.name] =
                    "no provider-safe qualified name exists for '\(server)' + '\(tool.name)'"
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
        toolset.unregister(prefix: mcpToolNamePrefix(server))
    }

    /// Qualified names currently registered for `server`.
    public static func registeredNames(
        for server: String,
        in toolset: FinalizedToolset
    ) -> [String] {
        let prefix = mcpToolNamePrefix(server)
        return toolset.clientNames.filter { $0.hasPrefix(prefix) }
    }
}
