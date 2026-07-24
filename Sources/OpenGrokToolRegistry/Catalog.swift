// Catalog.swift
//
// Built-in tool catalog entries known to the registry. W5-S1 fully owns
// file/edit/search tools; other ids are catalogued for selection/finalization
// so later packs (W5-S2/W5-S3) can attach implementations without reworking
// finalize semantics.

import Foundation
import OpenGrokHunkTracker
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokToolRuntime
import OpenGrokToolTypes
import OpenGrokWorkspace

/// Static metadata for a registerable tool.
public struct RegisteredToolSpec: Sendable, Hashable, Equatable {
    public var namespace: ProductToolNamespace
    public var id: String
    public var kind: ProductToolKind
    public var description: String
    public var inputSchema: JSONValue
    public var defaultParams: JSONValue
    public var exposure: ToolExposureFlags

    public init(
        namespace: ProductToolNamespace,
        id: String,
        kind: ProductToolKind,
        description: String,
        inputSchema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([:]),
        ]),
        defaultParams: JSONValue = .object([:]),
        exposure: ToolExposureFlags = .ordinary
    ) {
        self.namespace = namespace
        self.id = id
        self.kind = kind
        self.description = description
        self.inputSchema = inputSchema
        self.defaultParams = defaultParams
        self.exposure = exposure
    }

    public var qualifiedId: String { "\(namespace.displayName):\(id)" }
}

// MARK: - Schemas

private func objectSchema(
    properties: [String: JSONValue],
    required: [String] = []
) -> JSONValue {
    var obj: [String: JSONValue] = [
        "type": .string("object"),
        "properties": .object(properties),
    ]
    if !required.isEmpty {
        obj["required"] = .array(required.map { .string($0) })
    }
    return .object(obj)
}

private func stringProp(_ description: String) -> JSONValue {
    .object(["type": .string("string"), "description": .string(description)])
}

private func boolProp(_ description: String) -> JSONValue {
    .object(["type": .string("boolean"), "description": .string(description)])
}

private func intProp(_ description: String) -> JSONValue {
    .object(["type": .string("integer"), "description": .string(description)])
}

// MARK: - File tool catalog

public enum BuiltinToolCatalog {
    public static let readFileSchema = objectSchema(
        properties: [
            "target_file": stringProp("Path of the file to read."),
            "offset": intProp("1-indexed start line."),
            "limit": intProp("Number of lines to read."),
        ],
        required: ["target_file"]
    )

    public static let listDirSchema = objectSchema(
        properties: [
            "target_directory": stringProp("Directory to list."),
        ],
        required: ["target_directory"]
    )

    public static let grepSchema = objectSchema(
        properties: [
            "pattern": stringProp("Regex pattern (rg --regexp)."),
            "path": stringProp("File or directory to search."),
            "glob": stringProp("Glob filter."),
            "-i": boolProp("Case insensitive."),
            "head_limit": intProp("Limit match lines."),
            "multiline": boolProp("Multiline mode."),
        ],
        required: ["pattern"]
    )

    public static let searchReplaceSchema = objectSchema(
        properties: [
            "file_path": stringProp("Path to modify."),
            "old_string": stringProp("Text to replace."),
            "new_string": stringProp("Replacement text."),
            "replace_all": boolProp("Replace every occurrence."),
        ],
        required: ["file_path", "old_string", "new_string"]
    )

    public static let applyPatchSchema = objectSchema(
        properties: [
            "input": stringProp("Freeform apply-patch text."),
        ],
        required: ["input"]
    )

    public static let openCodeEditSchema = objectSchema(
        properties: [
            "filePath": stringProp("Path to modify."),
            "oldString": stringProp("Text to replace."),
            "newString": stringProp("Replacement text."),
            "replaceAll": boolProp("Replace every occurrence."),
        ],
        required: ["filePath", "oldString", "newString"]
    )

    public static let openCodeWriteSchema = objectSchema(
        properties: [
            "file_path": stringProp("Absolute path to write."),
            "content": stringProp("Full file content."),
        ],
        required: ["file_path", "content"]
    )

    public static let openCodeGlobSchema = objectSchema(
        properties: [
            "pattern": stringProp("Glob pattern."),
            "path": stringProp("Root directory."),
        ],
        required: ["pattern"]
    )

    public static let hashlineEditSchema = objectSchema(
        properties: [
            "file_path": stringProp("Path to modify."),
            "edits": .object([
                "type": .string("array"),
                "description": .string("Hashline ops."),
            ]),
        ],
        required: ["file_path", "edits"]
    )

    public static let viewImageSchema = objectSchema(
        properties: [
            "path": stringProp("Image path."),
        ],
        required: ["path"]
    )

    /// File / edit / search tools owned by W5-S1.
    public static let fileTools: [RegisteredToolSpec] = [
        RegisteredToolSpec(
            namespace: .grokBuild, id: "read_file", kind: .read,
            description: "Read a file (text/image/pdf/pptx) with optional offset/limit.",
            inputSchema: readFileSchema
        ),
        RegisteredToolSpec(
            namespace: .grokBuild, id: "list_dir", kind: .listDir,
            description: "List directory contents.",
            inputSchema: listDirSchema
        ),
        RegisteredToolSpec(
            namespace: .grokBuild, id: "grep", kind: .search,
            description: "Search file contents with a regular expression.",
            inputSchema: grepSchema
        ),
        RegisteredToolSpec(
            namespace: .grokBuild, id: "search_replace", kind: .edit,
            description: "Exact string replace or create file when old_string is empty.",
            inputSchema: searchReplaceSchema
        ),
        RegisteredToolSpec(
            namespace: .grokBuild, id: "view_image", kind: .read,
            description: "Attach an image file for multimodal inspection.",
            inputSchema: viewImageSchema
        ),
        RegisteredToolSpec(
            namespace: .grokBuildConcise, id: "read_file", kind: .read,
            description: "Read a file (concise output).",
            inputSchema: readFileSchema
        ),
        RegisteredToolSpec(
            namespace: .grokBuildConcise, id: "search_replace", kind: .edit,
            description: "Exact string replace (concise output).",
            inputSchema: searchReplaceSchema
        ),
        RegisteredToolSpec(
            namespace: .grokBuildHashline, id: "hashline_read", kind: .read,
            description: "Read a file with hashline anchors.",
            inputSchema: readFileSchema
        ),
        RegisteredToolSpec(
            namespace: .grokBuildHashline, id: "hashline_edit", kind: .edit,
            description: "Edit a file using hashline anchors.",
            inputSchema: hashlineEditSchema
        ),
        RegisteredToolSpec(
            namespace: .grokBuildHashline, id: "hashline_grep", kind: .search,
            description: "Grep with hashline anchors on matches.",
            inputSchema: grepSchema
        ),
        RegisteredToolSpec(
            namespace: .codex, id: "apply_patch", kind: .edit,
            description: "Apply a freeform multi-file patch.",
            inputSchema: applyPatchSchema
        ),
        RegisteredToolSpec(
            namespace: .codex, id: "read_file", kind: .read,
            description: "Codex-shaped read_file.",
            inputSchema: readFileSchema
        ),
        RegisteredToolSpec(
            namespace: .codex, id: "list_dir", kind: .listDir,
            description: "Codex-shaped list_dir.",
            inputSchema: listDirSchema
        ),
        RegisteredToolSpec(
            namespace: .codex, id: "grep_files", kind: .search,
            description: "Codex-shaped grep_files.",
            inputSchema: grepSchema
        ),
        RegisteredToolSpec(
            namespace: .openCode, id: "read", kind: .read,
            description: "OpenCode-compatible read.",
            inputSchema: readFileSchema
        ),
        RegisteredToolSpec(
            namespace: .openCode, id: "edit", kind: .edit,
            description: "OpenCode-compatible exact edit.",
            inputSchema: openCodeEditSchema
        ),
        RegisteredToolSpec(
            namespace: .openCode, id: "write", kind: .write,
            description: "OpenCode-compatible full-file write.",
            inputSchema: openCodeWriteSchema
        ),
        RegisteredToolSpec(
            namespace: .openCode, id: "grep", kind: .search,
            description: "OpenCode-compatible grep.",
            inputSchema: grepSchema
        ),
        RegisteredToolSpec(
            namespace: .openCode, id: "glob", kind: .search,
            description: "OpenCode-compatible glob/search.",
            inputSchema: openCodeGlobSchema
        ),
    ]

    public static var fileToolKinds: [String: ProductToolKind] {
        Dictionary(uniqueKeysWithValues: fileTools.map { ($0.qualifiedId, $0.kind) })
    }

    public static var allQualifiedIds: Set<String> {
        Set(fileTools.map(\.qualifiedId))
    }
}

// MARK: - Handler protocol

/// Type-erased runtime handler bound at pack registration / finalize time.
public protocol ToolHandler: Sendable {
    func invoke(
        clientName: String,
        args: JSONValue,
        ctx: ToolCallContext,
        resources: ToolResources
    ) async -> Result<TypedToolOutput, ToolError>
}

/// Session resources available to tool handlers (cwd, locks, permissions, hunks).
public final class ToolResources: @unchecked Sendable {
    public var cwd: String
    public var sessionFolder: String
    public var locks: PathResourceLockManager
    public var permissionPipeline: PermissionPipeline?
    public var hunkTracker: HunkTrackerActor?
    public var promptIndex: Int
    public var sessionId: String
    public var agentId: String
    /// Optional path boundary roots (workspace sandbox).
    public var allowedRoots: [String]
    public var extras: TypedExtensions

    public init(
        cwd: String,
        sessionFolder: String? = nil,
        locks: PathResourceLockManager = PathResourceLockManager(),
        permissionPipeline: PermissionPipeline? = nil,
        hunkTracker: HunkTrackerActor? = nil,
        promptIndex: Int = 0,
        sessionId: String = "session",
        agentId: String = "main",
        allowedRoots: [String] = [],
        extras: TypedExtensions = TypedExtensions()
    ) {
        self.cwd = cwd
        self.sessionFolder = sessionFolder ?? cwd
        self.locks = locks
        self.permissionPipeline = permissionPipeline
        self.hunkTracker = hunkTracker
        self.promptIndex = promptIndex
        self.sessionId = sessionId
        self.agentId = agentId
        self.allowedRoots = allowedRoots
        self.extras = extras
    }
}
