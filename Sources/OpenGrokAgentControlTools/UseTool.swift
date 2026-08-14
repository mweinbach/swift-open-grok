// UseTool.swift
//
// Open Grok — MCP Meta-Dispatch: use_tool for invoking discovered MCP tools.
//
// Rust provenance (pin `650c1db7`):
//   * crates/codegen/xai-grok-tools/src/implementations/use_tool/mod.rs

import Foundation
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokToolRuntime
import OpenGrokToolTypes

/// Parse a qualified MCP tool name into server and tool components.
/// E.g. "linear__save_issue" -> (server: "linear", tool: "save_issue").
public func parseMCPQualifiedName(_ name: String) -> (server: String, tool: String)? {
    let parts = name.components(separatedBy: "__")
    guard parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty else {
        return nil
    }
    return (parts[0], parts.dropFirst().joined(separator: "__"))
}

/// Normalizes MCP tool input arguments, decoding JSON string if necessary or replacing null with empty object.
public func normalizeMCPArguments(_ input: JSONValue) -> JSONValue {
    switch input {
    case .string(let s):
        if let data = s.data(using: .utf8),
           let json = try? JSONDecoder().decode(JSONValue.self, from: data),
           case .object = json {
            return json
        }
        return .string(s)
    case .null:
        return .object([:])
    default:
        return input
    }
}

/// Input parameters for `use_tool`.
public struct UseToolInput: Sendable, Codable, Equatable {
    /// Qualified MCP tool name (e.g., "linear__save_issue").
    public var toolName: String
    /// Tool input arguments as a JSON object.
    public var toolInput: JSONValue

    public init(toolName: String, toolInput: JSONValue = .object([:])) {
        self.toolName = toolName
        self.toolInput = toolInput
    }

    public static func parse(_ value: JSONValue) throws -> UseToolInput {
        guard case .object(let dict) = value else {
            throw ToolError.invalidArguments("expected object input for use_tool")
        }
        guard let nameVal = dict["tool_name"] else {
            throw ToolError.invalidArguments("'tool_name' is required and must be a string")
        }
        let name: String
        switch nameVal {
        case .string(let s): name = s
        default: name = "\(nameVal)"
        }
        let inputVal = dict["tool_input"] ?? .object([:])
        return UseToolInput(toolName: name, toolInput: normalizeMCPArguments(inputVal))
    }
}

/// Backend interface for dispatching MCP tool calls.
public protocol MCPToolBackend: Sendable {
    func executeMCPTool(name: String, input: JSONValue) async throws -> JSONValue
}

/// Validator for `use_tool` invocation parameters.
public enum UseToolValidation {
    public static func validate(
        toolName: String,
        enabledNativeTools: Set<String>? = nil
    ) throws {
        let isQualified = toolName.contains("__")
        if !isQualified {
            if let native = enabledNativeTools, native.contains(toolName) {
                throw ToolError.invalidArguments(
                    "`\(toolName)` is a native tool, not an MCP integration tool. "
                    + "Call `\(toolName)` directly as its own tool call instead of "
                    + "routing it through `use_tool`."
                )
            }
            throw ToolError.invalidArguments(
                "'\(toolName)' is not a valid MCP tool name. "
                + "Tool names must be qualified as `server__tool` "
                + "(e.g., `linear__save_issue`). "
                + "Use `search_tool` to discover available tools."
            )
        }
    }
}

/// Meta-dispatch tool for executing MCP integration tools.
public struct UseTool: Sendable {
    public static let clientName = "use_tool"
    public static let namespace = "GrokBuild"

    public static let descriptionTemplate = """
    Call an MCP integration tool.

    The `tool_name` must be the qualified `server__tool` name (e.g., `linear__save_issue`). \
    The `tool_input` must conform exactly to the tool's input schema as returned by `search_tool`.
    """

    public static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "tool_name": .object([
                "type": .string("string"),
                "description": .string(
                    "The qualified name of the integration tool to call (e.g., \"linear__save_issue\"). "
                    + "Must be a tool previously discovered via search_tool."
                )
            ]),
            "tool_input": .object([
                "type": .string("object"),
                "additionalProperties": .bool(true),
                "description": .string(
                    "The arguments to pass to the tool, as a JSON object. "
                    + "Use the parameter schema returned by search_tool to construct this."
                )
            ])
        ]),
        "required": .array([.string("tool_name"), .string("tool_input")])
    ])

    public init() {}

    /// Validate tool name qualification and native tool detection.
    public func validate(input: UseToolInput, enabledNativeTools: Set<String>? = nil) throws {
        try UseToolValidation.validate(toolName: input.toolName, enabledNativeTools: enabledNativeTools)
    }

    /// Execute an MCP tool call through a backend handler.
    public func execute(
        input: UseToolInput,
        backend: some MCPToolBackend,
        enabledNativeTools: Set<String>? = nil
    ) async throws -> JSONValue {
        try validate(input: input, enabledNativeTools: enabledNativeTools)
        return try await backend.executeMCPTool(name: input.toolName, input: input.toolInput)
    }
}
