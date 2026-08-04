// FileToolPack.swift
//
// Registers concrete file-tool handlers onto ToolRegistryBuilder catalog entries.

import Foundation
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokToolRegistry
import OpenGrokToolRuntime

/// Multiplexed handler for all W5-S1 file tools.
public struct FileToolsHandler: ToolHandler {
    public init() {}

    public func invoke(
        clientName: String,
        args: JSONValue,
        ctx: ToolCallContext,
        resources: ToolResources
    ) async -> Result<TypedToolOutput, ToolError> {
        // Prefer the catalog id from reverse lookup via client name.
        switch clientName {
        case "read_file", "read", "hashline_read":
            return await ReadFileTool.run(
                args: args,
                resources: resources,
                withHashlineAnchors: clientName == "hashline_read",
                concise: false
            )
        case "list_dir":
            return await ListDirTool.run(args: args, resources: resources)
        case "grep", "grep_files", "hashline_grep":
            return await GrepTool.run(
                args: args,
                resources: resources,
                withHashline: clientName == "hashline_grep"
            )
        case "glob":
            return await GlobTool.run(args: args, resources: resources)
        case "search_replace":
            return await SearchReplaceTool.run(args: args, resources: resources)
        case "edit":
            return await SearchReplaceTool.run(args: args, resources: resources, camelCase: true)
        case "write":
            return await WriteTool.run(args: args, resources: resources)
        case "apply_patch":
            return await ApplyPatchTool.run(args: args, resources: resources)
        case "hashline_edit":
            return await Hashline.runEdit(args: args, resources: resources)
        case "view_image":
            return await ViewImageTool.run(args: args, resources: resources)
        default:
            // Concise variants share client names after name_override; try kind-based fallback.
            if clientName.contains("read") {
                return await ReadFileTool.run(args: args, resources: resources, concise: true)
            }
            if clientName.contains("replace") || clientName.contains("edit") {
                return await SearchReplaceTool.run(args: args, resources: resources)
            }
            return .failure(.notImplemented("file tool handler does not implement \(clientName)"))
        }
    }
}

public enum FileToolPack {
    /// Install handlers for every catalogued file tool id.
    public static func install(into builder: inout ToolRegistryBuilder) {
        let handler = FileToolsHandler()
        for spec in BuiltinToolCatalog.fileTools {
            builder.register(spec: spec, handler: handler)
        }
    }

    /// Build a ready-to-finalize registry with file handlers installed.
    public static func makeBuilder() -> ToolRegistryBuilder {
        var builder = ToolRegistryBuilder(registerBuiltins: true)
        install(into: &builder)
        return builder
    }

    /// Convenience: finalize a named file-tool preset with handlers.
    public static func finalizePreset(
        _ preset: NamedToolsetPreset,
        resources: ToolResources,
        options: FinalizeOptions = .unrestricted
    ) throws -> FinalizedToolset {
        let builder = makeBuilder()
        let config = toolServerConfig(for: preset, catalogKinds: builder.knownToolKinds())
        switch builder.finalize(config: config, resources: resources, options: options) {
        case .success(let set): return set
        case .failure(let errors):
            throw ToolBridgeError.finalizeFailed(errors.errors)
        }
    }
}
