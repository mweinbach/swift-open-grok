// Description.swift
//
// Tool-description builders, the `// @exec:` pragma parser, and the
// JSON-Schema-to-TypeScript renderer. Ported from
// `crates/codegen/xai-grok-code-mode-protocol/src/description.rs`.
//
// The `exec` tool description is the largest static string in the
// code-mode protocol — it documents the global helpers (`text`,
// `image`, `generatedImage`, `store`, `load`, `notify`, `setTimeout`,
// `clearTimeout`, `yield_control`, `exit`, `ALL_TOOLS`), the
// `// @exec:` pragma, the yield-time / max-output-token overrides, and
// (in code-mode-only mode) the typed declarations for every enabled
// nested tool. The `wait` tool description documents the
// `cell_id` / `yield_time_ms` / `max_tokens` / `terminate` shape.
//
// `parseExecSource` strips the optional first-line `// @exec:` pragma
// and validates its JSON object shape (only `yield_time_ms` and
// `max_output_tokens` are supported; both must be non-negative safe
// integers ≤ 2^53 - 1).
//
// `renderJSONSchemaToTypeScript` is the JSON-Schema-to-TypeScript
// renderer used to surface nested-tool argument shapes to the model. It
// handles `type`, `enum`, `const`, `oneOf`/`anyOf`/`allOf`, `properties`,
// `required`, `additionalProperties`, `items`, `prefixItems`, and the
// `true`/`false` schema shortcuts. MCP `CallToolResult<T>` shapes are
// detected by `mcpStructuredContentSchema` so the renderer can emit
// `CallToolResult<TStructured>` for tools that produce structured
// content.

import Foundation
import OpenGrokShared

/// First-line pragma prefix recognized by `parseExecSource`.
public let CODE_MODE_PRAGMA_PREFIX: String = "// @exec:"

/// Maximum value a `yield_time_ms` / `max_output_tokens` pragma field
/// may carry (2^53 - 1). Mirrors `Number.MAX_SAFE_INTEGER` in JS.
private let MAX_JS_SAFE_INTEGER: UInt64 = (1 &<< 53) - 1

/// The deferred-nested-tools guidance string appended to the exec
/// description when any deferred tools exist.
private let DEFERRED_NESTED_TOOLS_GUIDANCE: String = """
Some deferred nested tools may be omitted from this description. They are still available on the global `tools` object and listed in `ALL_TOOLS`.
To find one, filter `ALL_TOOLS` by `name` and `description`.
"""

/// The exec tool description template. The builder appends the
/// deferred-tools guidance (if any), the shared MCP types (if any
/// enabled or deferred tool produces structured content), and the
/// per-tool typed declarations (in code-mode-only mode).
private let EXEC_DESCRIPTION_TEMPLATE: String = """
Run JavaScript code to orchestrate/compose tool calls
- Evaluates the provided JavaScript code in a fresh V8 isolate as an async module.
- All nested tools are available on the global `tools` object, for example `await tools.exec_command(...)`. Tool names are exposed as normalized JavaScript identifiers, for example `await tools.mcp__ologs__get_profile(...)`.
- Nested tool methods take either a string or an object as their input argument.
- Nested tools return either an object or a string, based on the description.
- Nested tool promises expose `onProgress(handler)`: call `p.onProgress(fn)` before awaiting to receive incremental `{ text, payload? }` chunks while that nested tool runs. Registering replaces any previous handler for that call; handler exceptions are ignored; if the script falls behind, the oldest queued chunks are dropped.
- Runs raw JavaScript -- no Node, no file system, no network access, no console.
- Accepts raw JavaScript source text, not JSON, quoted strings, or markdown code fences.
- You may optionally start the tool input with a first-line pragma like `// @exec: {"yield_time_ms": 10000, "max_output_tokens": 1000}`.
- `yield_time_ms` asks `exec` to yield early if the script is still running. Defaults to 30000 ms.
- `max_output_tokens` sets the token budget for direct `exec` results. Defaults to 10000 tokens.
- When the JS code is fully evaluated, the isolate's lifetime ends and unawaited promises are silently discarded.

- Global helpers:
- `exit()`: Immediately ends the current script successfully (like an early return from the top level).
- `text(value: string | number | boolean | undefined | null)`: Appends a text item. Non-string values are stringified with `JSON.stringify(...)` when possible.
- `image(imageUrlOrItem: string | { image_url: string; detail?: "auto" | "low" | "high" | "original" | null } | ImageContent, detail?: "auto" | "low" | "high" | "original" | null)`: Appends an image item. `image_url` should be a base64-encoded `data:` URL. To forward an MCP tool image, pass an individual `ImageContent` block from `result.content`, for example `image(result.content[0])`. MCP image blocks may request detail with `_meta: { "codex/imageDetail": "original" }`. When provided, the second `detail` argument overrides any detail embedded in the first argument.
- `generatedImage(result: { image_url: string; output_hint?: string })`: Appends an image-generation result and its optional output hint. HTTP(S) URLs are not supported.
- `store(key: string, value: any)`: stores a serializable value under a string key for later `exec` calls in the same session.
- `load(key: string)`: returns the stored value for a string key, or `undefined` if it is missing.
- `notify(value: string | number | boolean | undefined | null)`: immediately injects an extra `custom_tool_call_output` for the current `exec` call. Values are stringified like `text(...)`.
- `setTimeout(callback: () => void, delayMs?: number)`: schedules a callback to run later and returns a timeout id. Pending timeouts do not keep `exec` alive by themselves; await an explicit promise if you need to wait for one.
- `clearTimeout(timeoutId?: number)`: cancels a timeout created by `setTimeout`.
- `ALL_TOOLS`: metadata for the enabled nested tools as `{ name, description }` entries.
- `yield_control()`: yields the accumulated output to the model immediately while the script keeps running.
"""

/// The wait tool description template.
private let WAIT_DESCRIPTION_TEMPLATE: String = """
- Use `wait` only after `exec` returns `Script running with cell ID ...`.
- `cell_id` identifies the running `exec` cell to resume.
- `yield_time_ms` controls how long to wait for more output before yielding again. Defaults to 10000 ms.
- `max_tokens` limits how much new output this wait call returns. Defaults to 10000 tokens.
- `terminate: true` stops the running cell; false or omitted waits for output.
- `wait` returns only the new output since the last yield, or the final completion or termination result for that cell.
- If the cell is still running, `wait` may yield again with the same `cell_id`.
- If the cell has already finished, `wait` returns the completed result and closes the cell.
"""

/// TypeScript preamble for the shared MCP types block, emitted once per
/// exec description when any enabled or deferred tool produces structured
/// content. Based off of
/// https://modelcontextprotocol.io/specification/draft/schema#calltoolresult
private let MCP_TYPESCRIPT_PREAMBLE: String = """
type Role = "user" | "assistant";
type MetaObject = Record<string, unknown>;
type Annotations = {
  audience?: Role[];
  priority?: number;
  lastModified?: string;
};
type Icon = {
  src: string;
  mimeType?: string;
  sizes?: string[];
  theme?: "light" | "dark";
};
type TextResourceContents = {
  uri: string;
  mimeType?: string;
  _meta?: MetaObject;
  text: string;
};
type BlobResourceContents = {
  uri: string;
  mimeType?: string;
  _meta?: MetaObject;
  blob: string;
};
type TextContent = {
  type: "text";
  text: string;
  annotations?: Annotations;
  _meta?: MetaObject;
};
type ImageContent = {
  type: "image";
  data: string;
  mimeType: string;
  annotations?: Annotations;
  _meta?: MetaObject;
};
type AudioContent = {
  type: "audio";
  data: string;
  mimeType: string;
  annotations?: Annotations;
  _meta?: MetaObject;
};
type ResourceLink = {
  icons?: Icon[];
  name: string;
  title?: string;
  uri: string;
  description?: string;
  mimeType?: string;
  annotations?: Annotations;
  size?: number;
  _meta?: MetaObject;
  type: "resource_link";
};
type EmbeddedResource = {
  type: "resource";
  resource: TextResourceContents | BlobResourceContents;
  annotations?: Annotations;
  _meta?: MetaObject;
};
type ContentBlock =
  | TextContent
  | ImageContent
  | AudioContent
  | ResourceLink
  | EmbeddedResource;
type CallToolResult<TStructured = { [key: string]: unknown }> = {
  _meta?: MetaObject;
  content: ContentBlock[];
  isError?: boolean;
  structuredContent?: TStructured;
  [key: string]: unknown;
};
"""

// MARK: - CodeModeToolKind

/// Whether a code-mode nested tool takes a typed JSON-object argument
/// (`function`) or a free-form string argument (`freeform`).
public enum CodeModeToolKind: Hashable, Sendable, Codable, Equatable {
    case function
    case freeform

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode(String.self)
        switch raw {
        case "function": self = .function
        case "freeform": self = .freeform
        default:
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "unknown CodeModeToolKind: \(raw)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .function: try c.encode("function")
        case .freeform: try c.encode("freeform")
        }
    }
}

// MARK: - ToolDefinition / EnabledToolMetadata / ToolNamespaceDescription

/// A nested tool definition surfaced to the JS isolate.
public struct ToolDefinition: Hashable, Sendable, Codable, Equatable {
    public var name: String
    public var toolName: ToolName
    public var description: String
    public var kind: CodeModeToolKind
    /// JSON Schema for the tool's input arguments. `nil` for freeform
    /// tools (the input is a bare string).
    public var inputSchema: JSONValue?
    /// JSON Schema for the tool's output. `nil` when the tool's output
    /// shape is untyped.
    public var outputSchema: JSONValue?

    public init(
        name: String,
        toolName: ToolName,
        description: String,
        kind: CodeModeToolKind,
        inputSchema: JSONValue? = nil,
        outputSchema: JSONValue? = nil
    ) {
        self.name = name
        self.toolName = toolName
        self.description = description
        self.kind = kind
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
    }

    enum CodingKeys: String, CodingKey {
        case name
        case toolName = "tool_name"
        case description, kind
        case inputSchema = "input_schema"
        case outputSchema = "output_schema"
    }
}

/// Metadata for an enabled nested tool, surfaced via the JS isolate's
/// `ALL_TOOLS` global. Carries the tool name, the normalized JS
/// identifier, the human-readable description, and the tool kind.
public struct EnabledToolMetadata: Hashable, Sendable, Codable, Equatable {
    public var toolName: ToolName
    public var globalName: String
    public var description: String
    public var kind: CodeModeToolKind

    public init(toolName: ToolName, globalName: String, description: String, kind: CodeModeToolKind) {
        self.toolName = toolName
        self.globalName = globalName
        self.description = description
        self.kind = kind
    }

    enum CodingKeys: String, CodingKey {
        case toolName = "tool_name"
        case globalName = "global_name"
        case description, kind
    }
}

/// Description of a tool namespace, used to group nested tool sections
/// in the exec description.
public struct ToolNamespaceDescription: Hashable, Sendable, Equatable {
    public var name: String
    public var description: String

    public init(name: String, description: String) {
        self.name = name
        self.description = description
    }
}

// MARK: - ParsedExecSource

/// The result of `parseExecSource`: the JS source code with the optional
/// `// @exec:` pragma stripped, plus the parsed `yield_time_ms` and
/// `max_output_tokens` overrides.
public struct ParsedExecSource: Hashable, Sendable, Equatable {
    public var code: String
    public var yieldTimeMs: UInt64?
    public var maxOutputTokens: Int?

    public init(code: String, yieldTimeMs: UInt64? = nil, maxOutputTokens: Int? = nil) {
        self.code = code
        self.yieldTimeMs = yieldTimeMs
        self.maxOutputTokens = maxOutputTokens
    }
}

/// Parse an `exec` tool input into a `ParsedExecSource`.
///
/// Recognizes the optional first-line `// @exec:` pragma and validates
/// its JSON object shape:
/// * Only `yield_time_ms` and `max_output_tokens` fields are supported.
/// * Both must be non-negative safe integers (≤ 2^53 - 1).
/// * The pragma must be followed by JS source on subsequent lines.
///
/// Returns the parsed source on success, or a `CodeModeError` on failure
/// (mirrors the Rust `Result<ParsedExecSource, String>` shape — the
/// error message is preserved verbatim on `CodeModeError.message`).
public func parseExecSource(_ input: String) -> Result<ParsedExecSource, CodeModeError> {
    if input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return .failure(
            CodeModeError(
                "exec expects raw JavaScript source text (non-empty). Provide JS only, optionally with first-line `// @exec: {\"yield_time_ms\": 10000, \"max_output_tokens\": 1000}`."
            )
        )
    }

    var args = ParsedExecSource(code: input)

    // `splitn(2, '\n')` — split on the first newline only.
    let lines = input.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
    let firstLine = lines.first.map(String.init) ?? ""
    let rest = lines.count > 1 ? String(lines[1]) : ""
    let trimmed = firstLine.drop(while: { $0.isWhitespace })

    guard trimmed.hasPrefix(CODE_MODE_PRAGMA_PREFIX) else {
        return .success(args)
    }

    let pragma = trimmed.dropFirst(CODE_MODE_PRAGMA_PREFIX.count)

    if rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return .failure(
            CodeModeError("exec pragma must be followed by JavaScript source on subsequent lines")
        )
    }

    let directive = pragma.trimmingCharacters(in: .whitespaces)
    if directive.isEmpty {
        return .failure(
            CodeModeError("exec pragma must be a JSON object with supported fields `yield_time_ms` and `max_output_tokens`")
        )
    }

    guard let data = directive.data(using: .utf8),
          let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
        return .failure(
            CodeModeError("exec pragma must be valid JSON with supported fields `yield_time_ms` and `max_output_tokens`: invalid JSON")
        )
    }

    guard case .object(let obj) = value else {
        return .failure(
            CodeModeError("exec pragma must be a JSON object with supported fields `yield_time_ms` and `max_output_tokens`")
        )
    }

    for key in obj.keys {
        switch key {
        case "yield_time_ms", "max_output_tokens":
            continue
        default:
            return .failure(
                CodeModeError("exec pragma only supports `yield_time_ms` and `max_output_tokens`; got `\(key)`")
            )
        }
    }

    // Extract `yield_time_ms` (UInt64).
    if let ytm = obj["yield_time_ms"] {
        guard let uint = ytm.uint64Value, uint <= MAX_JS_SAFE_INTEGER else {
            return .failure(
                CodeModeError("exec pragma fields `yield_time_ms` and `max_output_tokens` must be non-negative safe integers: yield_time_ms out of range")
            )
        }
        args.yieldTimeMs = uint
    }

    // Extract `max_output_tokens` (Int / usize).
    if let mot = obj["max_output_tokens"] {
        // Allow either unsigned or signed encoding; reject negatives and
        // values above MAX_JS_SAFE_INTEGER.
        let asInt: Int?
        if let u = mot.uint64Value {
            asInt = Int(exactly: u)
        } else if let i = mot.int64Value {
            asInt = Int(exactly: i)
        } else {
            asInt = nil
        }
        guard let parsed = asInt, parsed >= 0, UInt64(parsed) <= MAX_JS_SAFE_INTEGER else {
            return .failure(
                CodeModeError("exec pragma fields `yield_time_ms` and `max_output_tokens` must be non-negative safe integers: max_output_tokens out of range")
            )
        }
        args.maxOutputTokens = parsed
    }

    args.code = rest
    return .success(args)
}

// MARK: - isCodeModeNestedTool

/// `true` when `toolName` is a code-mode nested tool (i.e. not `exec` or
/// `wait`). Used by the runtime to decide whether a tool call should be
/// routed through the JS isolate's `tools.<name>` global.
public func isCodeModeNestedTool(_ toolName: String) -> Bool {
    toolName != PUBLIC_TOOL_NAME && toolName != WAIT_TOOL_NAME
}

// MARK: - normalizeCodeModeIdentifier

/// Normalize a tool name into a valid JavaScript identifier.
///
/// The first character must be `_`, `$`, or an ASCII letter; subsequent
/// characters may additionally be ASCII digits. Any other character is
/// replaced with `_`. An all-invalid name normalizes to `_`.
public func normalizeCodeModeIdentifier(_ toolKey: String) -> String {
    var identifier = ""
    for (index, ch) in toolKey.unicodeScalars.enumerated() {
        let isValid: Bool
        if index == 0 {
            isValid = ch == "_" || ch == "$" || (ch.isASCII && CharacterSet.letters.contains(ch))
        } else {
            isValid = ch == "_" || ch == "$"
                || (ch.isASCII && CharacterSet.letters.contains(ch))
                || (ch.isASCII && CharacterSet.decimalDigits.contains(ch))
        }
        identifier.append(isValid ? Character(ch) : "_")
    }
    return identifier.isEmpty ? "_" : identifier
}

// MARK: - enabledToolMetadata / augmentToolDefinition

/// Build the `EnabledToolMetadata` for a tool definition (mirrors the
/// Rust `enabled_tool_metadata` function).
public func enabledToolMetadata(_ definition: ToolDefinition) -> EnabledToolMetadata {
    EnabledToolMetadata(
        toolName: definition.toolName,
        globalName: normalizeCodeModeIdentifier(definition.name),
        description: definition.description,
        kind: definition.kind
    )
}

/// Augment a tool definition by appending the typed JS declaration to
/// its description (mirrors the Rust `augment_tool_definition`
/// function). The `exec` / `wait` tools are passed through unchanged.
public func augmentToolDefinition(_ definition: ToolDefinition) -> ToolDefinition {
    var copy = definition
    if definition.name != PUBLIC_TOOL_NAME {
        copy.description = renderCodeModeSampleForDefinition(definition)
    }
    return copy
}

// MARK: - buildExecToolDescription / buildWaitToolDescription

/// Build the `exec` tool description.
///
/// Sections:
/// 1. The exec description template (always).
/// 2. The deferred-nested-tools guidance (when `deferredTools` is
///    non-empty).
/// 3. In code-mode-only mode: the shared MCP types block (when any
///    enabled or deferred tool produces structured content) and the
///    per-tool typed declarations, grouped by namespace.
public func buildExecToolDescription(
    enabledTools: [ToolDefinition],
    deferredTools: [ToolDefinition],
    namespaceDescriptions: [String: ToolNamespaceDescription],
    codeModeOnly: Bool
) -> String {
    var sections: [String] = [EXEC_DESCRIPTION_TEMPLATE]
    if !deferredTools.isEmpty {
        sections.append(DEFERRED_NESTED_TOOLS_GUIDANCE)
    }
    if !codeModeOnly {
        return sections.joined(separator: "\n\n")
    }

    let hasMCPTools = enabledTools.contains { tool in
        mcpStructuredContentSchema(tool.outputSchema) != nil
    } || deferredTools.contains { tool in
        mcpStructuredContentSchema(tool.outputSchema) != nil
    }
    if hasMCPTools {
        sections.append("Shared MCP Types:\n```ts\n\(MCP_TYPESCRIPT_PREAMBLE)\n```")
    }

    if !enabledTools.isEmpty {
        var currentNamespace: String? = nil
        var nestedToolSections: [String] = []
        nestedToolSections.reserveCapacity(enabledTools.count)

        for tool in enabledTools {
            let name = tool.name
            let nestedDescription = renderCodeModeSampleForDefinition(tool)
            let namespaceDescription = tool.toolName.namespace.flatMap {
                namespaceDescriptions[$0]
            }
            let nextNamespace = namespaceDescription?.name
            if nextNamespace != currentNamespace {
                if let nd = namespaceDescription {
                    let text = nd.description.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        nestedToolSections.append("## \(nd.name)\n\(text)")
                    }
                }
                currentNamespace = nextNamespace
            }

            let globalName = normalizeCodeModeIdentifier(name)
            let trimmedDescription = nestedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedDescription.isEmpty {
                nestedToolSections.append(renderToolHeading(globalName: globalName, rawName: name))
            } else {
                nestedToolSections.append(
                    "\(renderToolHeading(globalName: globalName, rawName: name))\n\(trimmedDescription)"
                )
            }
        }

        sections.append(nestedToolSections.joined(separator: "\n\n"))
    }

    return sections.joined(separator: "\n\n")
}

/// Build the `wait` tool description. Returns the static template.
public func buildWaitToolDescription() -> String {
    WAIT_DESCRIPTION_TEMPLATE
}

// MARK: - renderCodeModeSample / renderJSONSchemaToTypeScript

/// Render the typed JS declaration sample for a single tool definition.
/// Appended to the tool's description by `augmentToolDefinition`.
public func renderCodeModeSample(
    description: String,
    toolName: String,
    inputName: String,
    inputType: String,
    outputType: String
) -> String {
    let declaration = renderCodeModeToolDeclaration(
        toolName: toolName,
        inputName: inputName,
        inputType: inputType,
        outputType: outputType
    )
    return "\(description)\n\nexec tool declaration:\n```ts\n\(declaration)\n```"
}

/// Render the JSON Schema as a TypeScript type expression.
public func renderJSONSchemaToTypeScript(_ schema: JSONValue) -> String {
    renderJSONSchemaToTypeScriptInner(schema)
}

// MARK: - Internal helpers

private func renderCodeModeSampleForDefinition(_ definition: ToolDefinition) -> String {
    let inputName: String
    let inputType: String
    switch definition.kind {
    case .function:
        inputName = "args"
        inputType = definition.inputSchema.map(renderJSONSchemaToTypeScript) ?? "unknown"
    case .freeform:
        inputName = "input"
        inputType = "string"
    }

    let outputType: String
    if let structuredContentSchema = mcpStructuredContentSchema(definition.outputSchema) {
        let structuredContentType = renderJSONSchemaToTypeScript(structuredContentSchema)
        if structuredContentType == "unknown" {
            outputType = "CallToolResult"
        } else {
            outputType = "CallToolResult<\(structuredContentType)>"
        }
    } else {
        outputType = definition.outputSchema.map(renderJSONSchemaToTypeScript) ?? "unknown"
    }

    return renderCodeModeSample(
        description: definition.description,
        toolName: definition.name,
        inputName: inputName,
        inputType: inputType,
        outputType: outputType
    )
}

private func renderCodeModeToolDeclaration(
    toolName: String,
    inputName: String,
    inputType: String,
    outputType: String
) -> String {
    let normalized = normalizeCodeModeIdentifier(toolName)
    return "\(normalized)(\(inputName): \(inputType)): Promise<\(outputType)>;"
}

private func renderToolHeading(globalName: String, rawName: String) -> String {
    if globalName == rawName {
        return "### `\(globalName)`"
    } else {
        return "### `\(globalName)` (`\(rawName)`)"
    }
}

/// Detect an MCP `CallToolResult<T>` structured-content schema in a
/// tool's `output_schema`. Returns the `structuredContent` subschema
/// (or `.bool(true)` when the schema omits it) when the output matches
/// the MCP shape, `nil` otherwise.
private func mcpStructuredContentSchema(_ outputSchema: JSONValue?) -> JSONValue? {
    guard let outputSchema = outputSchema,
          case .object(let properties) = outputSchema else { return nil }

    guard case .object(let contentSchema)? = properties["content"],
          case .string(let type)? = contentSchema["type"],
          type == "array" else { return nil }

    // `items` must be present and have `type: "object"`.
    guard case .object(let itemsSchema)? = contentSchema["items"],
          case .string(let itemsType)? = itemsSchema["type"],
          itemsType == "object" else { return nil }

    // `isError` must be `{ "type": "boolean" }`.
    guard case .object(let isErrorSchema)? = properties["isError"],
          case .string(let isErrorType)? = isErrorSchema["type"],
          isErrorType == "boolean" else { return nil }

    // `_meta` must be `{ "type": "object" }`.
    guard case .object(let metaSchema)? = properties["_meta"],
          case .string(let metaType)? = metaSchema["type"],
          metaType == "object" else { return nil }

    return properties["structuredContent"] ?? .bool(true)
}

private func renderJSONSchemaToTypeScriptInner(_ schema: JSONValue) -> String {
    switch schema {
    case .bool(true):
        return "unknown"
    case .bool(false):
        return "never"
    case .object(let map):
        if let const = map["const"] {
            return renderJSONSchemaLiteral(const)
        }

        if case .array(let values)? = map["enum"] {
            let rendered = values.map(renderJSONSchemaLiteral)
            if !rendered.isEmpty {
                return rendered.joined(separator: " | ")
            }
        }

        for key in ["anyOf", "oneOf"] {
            if case .array(let variants)? = map[key] {
                let rendered = variants.map(renderJSONSchemaToTypeScriptInner)
                if !rendered.isEmpty {
                    return rendered.joined(separator: " | ")
                }
            }
        }

        if case .array(let variants)? = map["allOf"] {
            let rendered = variants.map(renderJSONSchemaToTypeScriptInner)
            if !rendered.isEmpty {
                return rendered.joined(separator: " & ")
            }
        }

        if let typeValue = map["type"] {
            if case .array(let types) = typeValue {
                let rendered = types.compactMap { v -> String? in
                    if case .string(let s) = v {
                        return renderJSONSchemaTypeKeyword(map: map, type: s)
                    }
                    return nil
                }
                if !rendered.isEmpty {
                    return rendered.joined(separator: " | ")
                }
            }
            if case .string(let s) = typeValue {
                return renderJSONSchemaTypeKeyword(map: map, type: s)
            }
        }

        if map["properties"] != nil || map["additionalProperties"] != nil || map["required"] != nil {
            return renderJSONSchemaObject(map)
        }

        if map["items"] != nil || map["prefixItems"] != nil {
            return renderJSONSchemaArray(map)
        }

        return "unknown"
    default:
        return "unknown"
    }
}

private func renderJSONSchemaTypeKeyword(map: [String: JSONValue], type: String) -> String {
    switch type {
    case "string": return "string"
    case "number", "integer": return "number"
    case "boolean": return "boolean"
    case "null": return "null"
    case "array": return renderJSONSchemaArray(map)
    case "object": return renderJSONSchemaObject(map)
    default: return "unknown"
    }
}

private func renderJSONSchemaArray(_ map: [String: JSONValue]) -> String {
    if let items = map["items"] {
        let itemType = renderJSONSchemaToTypeScriptInner(items)
        return "Array<\(itemType)>"
    }
    if case .array(let items)? = map["prefixItems"] {
        let itemTypes = items.map(renderJSONSchemaToTypeScriptInner)
        if !itemTypes.isEmpty {
            return "[\(itemTypes.joined(separator: ", "))]"
        }
    }
    return "unknown[]"
}

private func appendAdditionalPropertiesLine(
    into lines: inout [String],
    map: [String: JSONValue],
    properties: [String: JSONValue],
    linePrefix: String
) {
    if let additional = map["additionalProperties"] {
        let propertyType: String?
        switch additional {
        case .bool(true): propertyType = "unknown"
        case .bool(false): propertyType = nil
        default: propertyType = renderJSONSchemaToTypeScriptInner(additional)
        }
        if let pt = propertyType {
            lines.append("\(linePrefix)[key: string]: \(pt);")
        }
    } else if properties.isEmpty {
        lines.append("\(linePrefix)[key: string]: unknown;")
    }
}

private func hasPropertyDescription(_ value: JSONValue) -> Bool {
    if case .string(let s)? = value["description"] {
        return !s.isEmpty
    }
    return false
}

private func renderJSONSchemaObjectProperty(
    name: String,
    value: JSONValue,
    required: [String]
) -> String {
    let optional = required.contains(name) ? "" : "?"
    let propertyName = renderJSONSchemaPropertyName(name)
    let propertyType = renderJSONSchemaToTypeScriptInner(value)
    return "\(propertyName)\(optional): \(propertyType);"
}

private func renderJSONSchemaObject(_ map: [String: JSONValue]) -> String {
    let required: [String]
    if case .array(let items)? = map["required"] {
        required = items.compactMap { v -> String? in
            if case .string(let s) = v { return s }
            return nil
        }
    } else {
        required = []
    }

    let properties: [String: JSONValue]
    if case .object(let p)? = map["properties"] {
        properties = p
    } else {
        properties = [:]
    }

    let sortedProperties = properties.sorted { $0.key < $1.key }
    let anyHasDescription = sortedProperties.contains { _, value in
        hasPropertyDescription(value)
    }

    if anyHasDescription {
        var lines: [String] = ["{"]
        for (name, value) in sortedProperties {
            if case .string(let description)? = value["description"] {
                for line in description.split(separator: "\n", omittingEmptySubsequences: true) {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty {
                        lines.append("  // \(trimmed)")
                    }
                }
            }
            lines.append("  \(renderJSONSchemaObjectProperty(name: name, value: value, required: required))")
        }
        appendAdditionalPropertiesLine(into: &lines, map: map, properties: properties, linePrefix: "  ")
        lines.append("}")
        return lines.joined(separator: "\n")
    }

    var lines = sortedProperties.map { name, value in
        renderJSONSchemaObjectProperty(name: name, value: value, required: required)
    }
    appendAdditionalPropertiesLine(into: &lines, map: map, properties: properties, linePrefix: "")
    if lines.isEmpty {
        return "{}"
    }
    return "{ \(lines.joined(separator: " ")) }"
}

private func renderJSONSchemaPropertyName(_ name: String) -> String {
    if normalizeCodeModeIdentifier(name) == name {
        return name
    }
    // Match Rust's `serde_json::to_string(name)` (a quoted, escaped JSON
    // string).
    do {
        let data = try JSONEncoder().encode(name)
        return String(data: data, encoding: .utf8) ?? "\"\(name)\""
    } catch {
        return "\"\(name.replacingOccurrences(of: "\"", with: "\\\""))\""
    }
}

private func renderJSONSchemaLiteral(_ value: JSONValue) -> String {
    do {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        return String(data: data, encoding: .utf8) ?? "unknown"
    } catch {
        return "unknown"
    }
}
