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

private func stringArrayProp(_ description: String) -> JSONValue {
    .object([
        "type": .string("array"),
        "items": .object(["type": .string("string")]),
        "description": .string(description),
    ])
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

    // MARK: Media tools

    /// Model-facing text for `image_gen`. Kept byte-identical to
    /// `OpenGrokWebMediaTools.IMAGE_GEN_DESCRIPTION`, which is the same
    /// upstream `description_template`; the registry cannot import the tools
    /// target, so `ImageToolRegistrationTests` pins the two together.
    public static let imageGenDescription = "Generate a new image from a text description using the configured image provider; returns the saved image's absolute path. When telling the user where it was saved, refer to it by its short session-relative path (for example `images/1.png`) rather than the absolute path, so it renders as a clickable link that opens the image. To produce multiple images, emit multiple tool calls with distinct prompts."

    public static let imageEditDescription = "Edit or transform existing image(s) via the configured image provider; use instead of image_gen for image-to-image work (preserve likeness, transfer style, remix). Returns the saved image's absolute path. When telling the user where it was saved, refer to it by its short session-relative path (for example `images/1.png`) rather than the absolute path, so it renders as a clickable link that opens the image. Each required `image` is one reference — a user-attachment token (for example \"[Image #1]\"), an absolute filesystem path, or a `data:image/...;base64,...` URL (see the `image` parameter for the resolution order and details)."

    public static let imageGenSchema = objectSchema(
        properties: [
            "prompt": stringProp("Text description of the image to generate."),
            "aspect_ratio": stringProp(
                "Aspect ratio of the generated image, decide it based on the user's request. Defaults to 'auto'. 1:1 for square (icons, profiles), 16:9 for wide (landscapes, cinematic), 9:16 for tall (phone wallpapers, stories), 3:2 for horizontal photos, 2:3 for vertical (portraits, posters)."
            ),
        ],
        required: ["prompt"]
    )

    public static let imageEditSchema = objectSchema(
        properties: [
            "prompt": stringProp(
                "A text description of the desired edit or transformation. Describe what the output image should look like, referencing the input image(s)."
            ),
            "image": stringArrayProp(
                "Reference image(s) to condition the edit on. Each is one reference, in priority order: (1) a user attachment — its placeholder token, e.g. \"[Image #1]\" (attachments have no path you can see, so never invent one); (2) an absolute filesystem path the user gave you; (3) a `data:image/...;base64,...` URL."
            ),
            "aspect_ratio": stringProp(
                "The aspect ratio of the output image. For single-image edits this is ignored — the output matches the input image's aspect ratio. For multi-image edits, defaults to 'auto'. Supported values: 1:1, 16:9, 9:16, 4:3, 3:4, 3:2, 2:3, 2:1, 1:2, 19.5:9, 9:19.5, 20:9, 9:20, auto."
            ),
        ],
        required: ["prompt", "image"]
    )

    /// Image generation / editing tools.
    ///
    /// Registered unconditionally, exactly as upstream's registry does
    /// (`b.register::<ImageGenTool>()` / `ImageEditTool`,
    /// `xai-grok-tools/src/registry/types.rs:713`). Whether a *session*
    /// advertises them is a separate decision made when the session's
    /// `ToolServerConfig` is assembled, from resolved image credentials —
    /// see `xai-grok-agent/src/builder.rs:771`.
    ///
    /// Both carry `ToolKind::ImageGen`, so `ToolCapabilityMode` already drops
    /// them from a `.readOnly` or `.execute` session.
    public static let mediaTools: [RegisteredToolSpec] = [
        RegisteredToolSpec(
            namespace: .grokBuild, id: "image_gen", kind: .imageGen,
            description: imageGenDescription,
            inputSchema: imageGenSchema
        ),
        RegisteredToolSpec(
            namespace: .grokBuild, id: "image_edit", kind: .imageGen,
            description: imageEditDescription,
            inputSchema: imageEditSchema
        ),
    ]

    public static var mediaToolKinds: [String: ProductToolKind] {
        Dictionary(uniqueKeysWithValues: mediaTools.map { ($0.qualifiedId, $0.kind) })
    }

    public static let imageGenQualifiedId = "GrokBuild:image_gen"
    public static let imageEditQualifiedId = "GrokBuild:image_edit"

    // MARK: Web tools

    public static let webSearchDescription = "Search the web and return a synthesized answer with source citations. Use for current events, documentation, and anything outside the workspace."

    public static let webFetchDescription = "Fetch the content of a specific public URL and return it as markdown. Use when you already have a URL; use web_search when you need to find one."

    public static let xSearchDescription = "Search public posts on X and return a synthesized answer with source citations."

    public static let webSearchSchema = objectSchema(
        properties: [
            "query": stringProp("The search query."),
            "allowed_domains": stringArrayProp(
                "Optional domains to restrict the search to."
            ),
        ],
        required: ["query"]
    )

    public static let webFetchSchema = objectSchema(
        properties: [
            "url": stringProp("The URL to fetch content from."),
        ],
        required: ["url"]
    )

    public static let xSearchSchema = objectSchema(
        properties: [
            "query": stringProp("The X search query."),
        ],
        required: ["query"]
    )

    /// Web search / fetch tools.
    ///
    /// Registered unconditionally, the way upstream's registry does
    /// (`xai-grok-tools/src/registry/types.rs:708-711`). Whether a session
    /// advertises them is decided when its `ToolServerConfig` is assembled,
    /// from the resolved search backend and the `--disable-web-search` switch
    /// — the same split the image tools use.
    public static let webTools: [RegisteredToolSpec] = [
        RegisteredToolSpec(
            namespace: .grokBuild, id: "web_search", kind: .webSearch,
            description: webSearchDescription,
            inputSchema: webSearchSchema
        ),
        RegisteredToolSpec(
            namespace: .grokBuild, id: "web_fetch", kind: .webFetch,
            description: webFetchDescription,
            inputSchema: webFetchSchema
        ),
        RegisteredToolSpec(
            namespace: .grokBuild, id: "x_search", kind: .webSearch,
            description: xSearchDescription,
            inputSchema: xSearchSchema
        ),
    ]

    public static var webToolKinds: [String: ProductToolKind] {
        Dictionary(uniqueKeysWithValues: webTools.map { ($0.qualifiedId, $0.kind) })
    }

    public static let webSearchQualifiedId = "GrokBuild:web_search"
    public static let webFetchQualifiedId = "GrokBuild:web_fetch"
    public static let xSearchQualifiedId = "GrokBuild:x_search"

    // MARK: Session-state tools

    public static let todoWriteDescription = """
        Create and manage a structured task list. The user sees this list live — it is your primary way to show progress.

        Use for any task with 3+ steps. Skip for trivial single-step work.
        """

    public static let todoWriteSchema = objectSchema(
        properties: [
            "merge": boolProp(
                "Optional. When true (default), merges the provided todos into the existing list by id — send only the items you are changing, and to flip status without changing content send just id + status. When false, the provided todos replace the existing list."
            ),
            "todos": .object([
                "type": .string("array"),
                "description": .string("Array of todo items to write to the workspace"),
                "items": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "id": stringProp("Unique identifier for the todo item"),
                        "content": stringProp("The description/content of the todo item"),
                        "status": .object([
                            "type": .string("string"),
                            "enum": .array([
                                .string("pending"), .string("in_progress"),
                                .string("completed"), .string("cancelled"),
                            ]),
                            "description": .string(
                                "The status of the todo item: pending, in_progress, completed, or cancelled"
                            ),
                        ]),
                    ]),
                    "required": .array([.string("id")]),
                ]),
            ]),
        ],
        required: ["todos"]
    )

    /// `todo_write`.
    ///
    /// Carries `.read` rather than `.edit`: it touches no file and runs no
    /// process, so upstream gives it `ToolScope::Read`
    /// (`grok_build/todo/mod.rs:300-305`). That is load-bearing — a planning
    /// agent under a read-only capability mode must still be able to record its
    /// plan, and `plan` is exactly the preset where this is the only state tool.
    public static let sessionStateTools: [RegisteredToolSpec] = [
        RegisteredToolSpec(
            namespace: .grokBuild, id: "todo_write", kind: .read,
            description: todoWriteDescription,
            inputSchema: todoWriteSchema
        ),
    ]

    public static var sessionStateToolKinds: [String: ProductToolKind] {
        Dictionary(uniqueKeysWithValues: sessionStateTools.map { ($0.qualifiedId, $0.kind) })
    }

    public static let todoWriteQualifiedId = "GrokBuild:todo_write"

    // MARK: Plan-mode lifecycle tools

    /// `enter_plan_mode` / `exit_plan_mode` — the agent-initiated plan-mode
    /// lifecycle. Upstream ships both in `grok_build` with `ToolScope::Read`
    /// (`enter_plan_mode/mod.rs:93-100`, `exit_plan_mode/mod.rs:104-110`):
    /// neither mutates user files directly, so they never prompt as edits.
    /// Plan-mode enforcement (read-only + plan-file gating) lives in the
    /// permission pipeline's plan gate, not in these tools.
    ///
    /// Both tools carry `.enterPlan` / `.exitPlan` so the capability filter
    /// keeps them in every mode (`CapabilityFilter.kindAllowed` meta arm) and
    /// `accessKind(for:)` routes them to `.read(nil)` — the same arm upstream's
    /// `From<&ToolInput> for AccessKind` reaches for unknown input kinds.
    public static let enterPlanModeDescription = """
        Use this tool when a task has ambiguity about the right approach or when the user asks you to write a plan. This tool enables a read-only plan mode where you explore the codebase and create an implementation plan for the user.
        """

    public static let exitPlanModeDescription = """
        Exit plan mode and present your plan to the user.

        Use this after you have finished writing your plan to the plan file in plan mode.
        """

    public static let planModeTools: [RegisteredToolSpec] = [
        RegisteredToolSpec(
            namespace: .grokBuild, id: "enter_plan_mode", kind: .enterPlan,
            description: enterPlanModeDescription,
            inputSchema: objectSchema(properties: [:])
        ),
        RegisteredToolSpec(
            namespace: .grokBuild, id: "exit_plan_mode", kind: .exitPlan,
            description: exitPlanModeDescription,
            inputSchema: objectSchema(properties: [:])
        ),
    ]

    public static var planModeToolKinds: [String: ProductToolKind] {
        Dictionary(uniqueKeysWithValues: planModeTools.map { ($0.qualifiedId, $0.kind) })
    }

    public static let enterPlanModeQualifiedId = "GrokBuild:enter_plan_mode"
    public static let exitPlanModeQualifiedId = "GrokBuild:exit_plan_mode"

    /// Every spec `ToolRegistryBuilder(registerBuiltins: true)` installs.
    public static var builtinTools: [RegisteredToolSpec] {
        fileTools + mediaTools + webTools + sessionStateTools + planModeTools
    }

    public static var allQualifiedIds: Set<String> {
        Set(builtinTools.map(\.qualifiedId))
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
