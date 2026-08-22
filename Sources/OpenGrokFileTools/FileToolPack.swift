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
                concise: false,
                context: ctx
            )
        case "list_dir":
            return await ListDirTool.run(args: args, resources: resources)
        case "grep", "grep_files", "hashline_grep":
            return await GrepTool.run(
                args: args,
                resources: resources,
                withHashline: clientName == "hashline_grep",
                context: ctx
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
                return await ReadFileTool.run(
                    args: args,
                    resources: resources,
                    concise: true,
                    context: ctx
                )
            }
            if clientName.contains("replace") || clientName.contains("edit") {
                return await SearchReplaceTool.run(args: args, resources: resources)
            }
            return .failure(.notImplemented("file tool handler does not implement \(clientName)"))
        }
    }
}

/// Replay only the already-formatted, permission-authorized model-visible body.
func streamFileToolContent(
    _ content: String,
    subkind: String,
    context: ToolCallContext?,
    flushPerLine: Bool = false
) async -> Bool {
    guard let context,
          context.get(WorkspaceViewerContext.self)?.streamToolProgress == true,
          let reporter = context.get(ToolProgressReporter.self) else {
        return true
    }
    guard !reporter.isCancelled else { return false }

    let bytes = Array(content.utf8)
    let spec = StreamingSpec(subkind: subkind)
    var windowStart = 0
    var lastTotal: UInt64 = 0

    while windowStart < bytes.count {
        let windowEnd: Int
        if flushPerLine {
            let searchStart = bytes[windowStart] == 0x0A ? windowStart + 1 : windowStart
            windowEnd = bytes[searchStart...].firstIndex(of: 0x0A) ?? bytes.count
        } else {
            var alignedEnd = min(windowStart + 4_096, bytes.count)
            while alignedEnd < bytes.count,
                  alignedEnd > windowStart,
                  bytes[alignedEnd] & 0xC0 == 0x80 {
                alignedEnd -= 1
            }
            windowEnd = alignedEnd
        }

        let visibleBytes = Array(bytes[..<windowEnd])
        while lastTotal < UInt64(windowEnd) {
            guard !reporter.isCancelled else { return false }
            guard let progress = streamChunk(
                spec: spec,
                tail: visibleBytes,
                total: UInt64(windowEnd),
                lastTotal: &lastTotal,
                truncated: false
            ) else {
                return false
            }
            guard await reporter.emit(progress) else { return false }
        }
        windowStart = windowEnd
    }
    return true
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
