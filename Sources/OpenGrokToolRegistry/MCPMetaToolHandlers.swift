// MCPMetaToolHandlers.swift
//
// Runtime handlers for the `search_tool` and `use_tool` MCP meta-tools.
// Ported from:
//   search_tool: `xai-grok-tools/src/implementations/search_tool/mod.rs:208-326`
//   use_tool:    `xai-grok-tools/src/implementations/use_tool/mod.rs:63-380`
// at pin 650c1db7.
//
// search_tool reads the ToolSearchIndexing resource from ToolResources.extras
// and groups results by server, preserving BM25 score order within groups.
//
// use_tool validates the qualified `server__tool` name, detects native-tool
// misrouting (corrective error), normalizes arguments, and dispatches through
// FinalizedToolset.prepareAndCall on the target MCP tool.

import Foundation
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokToolRuntime
import OpenGrokToolTypes

// MARK: - search_tool handler

/// Handler for `search_tool`. Groups results by server, preserving BM25
/// score order within groups (best-matching server first). Returns JSON
/// carrying schemas so the model can construct `use_tool` calls directly.
///
/// Ported from `SearchTool::run` (`search_tool/mod.rs:208-326`).
public struct SearchToolHandler: ToolHandler {
    public init() {}

    public func invoke(
        clientName: String,
        args: JSONValue,
        ctx: ToolCallContext,
        resources: ToolResources
    ) async -> Result<TypedToolOutput, ToolError> {
        _ = ctx
        let query: String
        let limit: Int

        if case .object(let obj) = args {
            if case .string(let q) = obj["query"] {
                query = q
            } else {
                return .failure(.invalidArguments("'query' is required and must be a string"))
            }
            if case .number(let n) = obj["limit"],
               let intVal = n.int64Value {
                limit = max(1, Int(intVal))
            } else {
                limit = 5
            }
        } else {
            return .failure(.invalidArguments("arguments must be an object"))
        }

        guard let indexResource = resources.extras.get(ToolSearchIndexResource.self) else {
            let empty = formatEmptyCatalog()
            return .success(textOutput(clientName, empty))
        }

        let snapshot = indexResource.index.searchSnapshot(query: query, limit: limit)
        let grouped = groupByServer(snapshot.results)
        let status: String = snapshot.isReady ? "ready" : "partial"

        var resultGroups: [JSONValue] = []
        for group in grouped {
            var toolEntries: [JSONValue] = []
            for result in group.tools {
                toolEntries.append(.object([
                    "tool_name": .string(result.toolName),
                    "description": .string(truncateMCPDescription(result.description)),
                    "input_schema": result.inputSchema,
                ]))
            }
            resultGroups.append(.object([
                "server": .string(group.serverName),
                "tools": .array(toolEntries),
            ]))
        }

        let response: JSONValue = .object([
            "status": .string(status),
            "results": .array(resultGroups),
            "total_hidden_tools": .number(.int64(Int64(snapshot.totalHiddenTools))),
        ])

        let text = jsonPrettyString(response) ?? "{}"
        return .success(textOutput(clientName, text))
    }
}

// MARK: - use_tool handler

/// Handler for `use_tool`. Validates the qualified name, detects native-tool
/// misrouting with a corrective error, normalizes arguments, and dispatches
/// through the toolset.
///
/// Ported from `UseTool::run` (`use_tool/mod.rs:315-380`).
public struct UseToolHandler: ToolHandler {
    /// The toolset through which MCP calls are dispatched. Injected at
    /// registration time so dispatch is a direct method call, matching how
    /// Rust `InnerDispatch` works without the extension-scoped pattern.
    public let toolset: FinalizedToolset

    public init(toolset: FinalizedToolset) {
        self.toolset = toolset
    }

    public func invoke(
        clientName: String,
        args: JSONValue,
        ctx: ToolCallContext,
        resources: ToolResources
    ) async -> Result<TypedToolOutput, ToolError> {
        _ = ctx
        let toolName: String
        let toolInput: JSONValue

        if case .object(let obj) = args {
            if case .string(let name) = obj["tool_name"] {
                toolName = name
            } else {
                return .failure(.invalidArguments("'tool_name' is required and must be a string"))
            }
            toolInput = normalizeArguments(obj["tool_input"] ?? .object([:]))
        } else {
            return .failure(.invalidArguments("arguments must be an object"))
        }

        let isQualified = toolName.contains("__")

        if !isQualified {
            let isNative = resources.extras.get(EnabledNativeToolNames.self)
                .map { $0.names.contains(toolName) } ?? false

            if isNative {
                return .failure(.invalidArguments(
                    "`\(toolName)` is a native tool, not an MCP integration tool. "
                    + "Call `\(toolName)` directly as its own tool call instead of "
                    + "routing it through `use_tool`."
                ))
            }

            return .failure(.invalidArguments(
                "'\(toolName)' is not a valid MCP tool name. "
                + "Tool names must be qualified as `server__tool` "
                + "(e.g., `linear__save_issue`). "
                + "Use `search_tool` to discover available tools."
            ))
        }

        let result = await toolset.prepareAndCall(
            clientName: toolName,
            args: toolInput
        )

        switch result {
        case .success(let typed):
            return .success(typed)
        case .failure(let err):
            return .failure(err)
        }
    }
}

// MARK: - Helpers

/// Group search results by server, preserving BM25 score order within each
/// group. Groups are sorted by highest score (best-matching server first).
///
/// Ported from `search_tool/mod.rs:268-301`.
struct ServerGroup {
    var serverName: String
    var bestScore: Float
    var tools: [ToolSearchResult]
}

func groupByServer(_ results: [ToolSearchResult]) -> [ServerGroup] {
    var groups: [String: ServerGroup] = [:]
    var order: [String] = []

    for result in results {
        if var group = groups[result.serverName] {
            group.tools.append(result)
            groups[result.serverName] = group
        } else {
            groups[result.serverName] = ServerGroup(
                serverName: result.serverName,
                bestScore: result.score,
                tools: [result]
            )
            order.append(result.serverName)
        }
    }

    return order.compactMap { groups[$0] }
        .sorted { $0.bestScore > $1.bestScore }
}

func formatEmptyCatalog() -> String {
    jsonPrettyString(.object([
        "results": .array([]),
        "total_hidden_tools": .number(.int64(0)),
        "note": .string(
            "No integration tools are configured. "
            + "MCP servers are not connected."
        ),
    ])) ?? "{}"
}

/// Normalize MCP tool arguments: parse string-encoded JSON, coerce null to
/// empty object. Ported from `use_tool/mod.rs:139-148`.
func normalizeArguments(_ input: JSONValue) -> JSONValue {
    switch input {
    case .string(let s):
        if let data = s.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data),
           parsed is [String: Any],
           let reparsed = try? JSONDecoder().decode(JSONValue.self, from: data) {
            return reparsed
        }
        return input
    case .null:
        return .object([:])
    default:
        return input
    }
}

private func textOutput(_ toolId: String, _ text: String) -> TypedToolOutput {
    let tid = (try? ToolId(toolId)) ?? (try! ToolId("search_tool"))
    return TypedToolOutput(
        toolId: tid,
        value: .object(["content": .string(text)]),
        modelOutput: [.text(text: text)]
    )
}

private func jsonPrettyString(_ value: JSONValue) -> String? {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(value) else { return nil }
    return String(data: data, encoding: .utf8)
}
