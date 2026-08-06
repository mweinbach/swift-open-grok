// ImageToolRegistrationTests.swift
//
// Registration and permission-category contract for `image_gen` / `image_edit`.
//
// Upstream references:
//   * `xai-grok-tools/src/registry/types.rs:713` — both tools are registered
//     unconditionally, independent of whether any session advertises them.
//   * `grok_build/image_gen/mod.rs:571` and `image_edit/mod.rs:258` —
//     `ToolKind::ImageGen` for both, `is_read_only: false`.
//   * `xai-grok-workspace/src/permission/types.rs:272` — `AccessKind::from`
//     matches neither variant, so both land on `AccessKind::Read(None)`.

import Foundation
import Testing
@testable import OpenGrokToolRegistry
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokToolRuntime
import OpenGrokWorkspace

private struct RecordingHandler: ToolHandler {
    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var names: [String] = []

        func record(_ name: String) {
            lock.lock(); defer { lock.unlock() }
            names.append(name)
        }

        var recorded: [String] {
            lock.lock(); defer { lock.unlock() }
            return names
        }
    }

    let box: Box

    func invoke(
        clientName: String,
        args: JSONValue,
        ctx: ToolCallContext,
        resources: ToolResources
    ) async -> Result<TypedToolOutput, ToolError> {
        box.record(clientName)
        guard let toolId = try? ToolId(clientName) else {
            return .failure(.invalidArguments("bad tool id"))
        }
        return .success(TypedToolOutput(
            toolId: toolId,
            value: .object(["content": .string("ok")]),
            modelOutput: [.text(text: "ok")]
        ))
    }
}

private func imageToolConfig() -> ToolServerConfig {
    let kinds = BuiltinToolCatalog.mediaToolKinds
    return ToolServerConfig(tools: [
        ToolConfig.fromId(
            BuiltinToolCatalog.imageGenQualifiedId,
            kind: kinds[BuiltinToolCatalog.imageGenQualifiedId]
        ),
        ToolConfig.fromId(
            BuiltinToolCatalog.imageEditQualifiedId,
            kind: kinds[BuiltinToolCatalog.imageEditQualifiedId]
        ),
    ])
}

@Suite("Image tool registration")
struct ImageToolRegistrationTests {

    @Test("both image tools are catalogued with the ImageGen kind")
    func catalogued() {
        let kinds = BuiltinToolCatalog.mediaToolKinds
        #expect(kinds["GrokBuild:image_gen"] == .imageGen)
        #expect(kinds["GrokBuild:image_edit"] == .imageGen)
        #expect(BuiltinToolCatalog.mediaTools.allSatisfy { $0.namespace == .grokBuild })
        // `ToolKind::ImageGen` is not read-only upstream (`is_read_only: false`).
        #expect(ProductToolKind.imageGen.isReadOnly == false)
    }

    /// The registry knows them even though no preset selects them, exactly as
    /// upstream registers the tools unconditionally and lets the session's
    /// `ToolServerConfig` decide advertisement.
    @Test("a default builder knows both ids but no preset advertises them")
    func registeredButNotPreset() {
        let builder = ToolRegistryBuilder()
        #expect(builder.hasToolId(BuiltinToolCatalog.imageGenQualifiedId))
        #expect(builder.hasToolId(BuiltinToolCatalog.imageEditQualifiedId))
        for preset in NamedToolsetPreset.allCases {
            let ids = Set(
                toolServerConfig(for: preset, catalogKinds: builder.knownToolKinds())
                    .tools.map(\.id)
            )
            #expect(!ids.contains(BuiltinToolCatalog.imageGenQualifiedId))
            #expect(!ids.contains(BuiltinToolCatalog.imageEditQualifiedId))
        }
    }

    @Test("schemas carry upstream's required fields")
    func schemas() {
        func required(_ schema: JSONValue) -> [String] {
            guard case .object(let obj) = schema,
                  case .array(let items)? = obj["required"]
            else { return [] }
            return items.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
        }
        func properties(_ schema: JSONValue) -> Set<String> {
            guard case .object(let obj) = schema,
                  case .object(let props)? = obj["properties"]
            else { return [] }
            return Set(props.keys)
        }
        #expect(required(BuiltinToolCatalog.imageGenSchema) == ["prompt"])
        #expect(properties(BuiltinToolCatalog.imageGenSchema) == ["prompt", "aspect_ratio"])
        #expect(Set(required(BuiltinToolCatalog.imageEditSchema)) == ["prompt", "image"])
        #expect(
            properties(BuiltinToolCatalog.imageEditSchema)
                == ["prompt", "image", "aspect_ratio"]
        )
        // `image` is a list of references, not one string.
        guard case .object(let editObj) = BuiltinToolCatalog.imageEditSchema,
              case .object(let props)? = editObj["properties"],
              case .object(let image)? = props["image"]
        else {
            Issue.record("image_edit schema is malformed")
            return
        }
        #expect(image["type"] == .string("array"))
    }

    /// `ToolKind::ImageGen` sits in the same capability arm as `edit` / `write`
    /// (`xai-grok-workspace/src/capability.rs`), so a read-only or
    /// execute-scoped session never sees an image tool.
    @Test("capability mode gates image tools like mutations")
    func capabilityGating() {
        let config = imageToolConfig()
        #expect(ToolCapabilityMode.readOnly.filter(config).tools.isEmpty)
        #expect(ToolCapabilityMode.execute.filter(config).tools.isEmpty)
        #expect(ToolCapabilityMode.readWrite.filter(config).tools.count == 2)
        #expect(ToolCapabilityMode.all.filter(config).tools.count == 2)
    }

    @Test("finalize advertises both tools with their schemas and kind")
    func finalizeAdvertises() throws {
        var builder = ToolRegistryBuilder()
        let box = RecordingHandler.Box()
        builder.setHandler(
            qualifiedId: BuiltinToolCatalog.imageGenQualifiedId,
            handler: RecordingHandler(box: box)
        )
        let resources = ToolResources(cwd: NSTemporaryDirectory())
        let bridge = try ToolBridge.finalize(
            builder: builder,
            config: imageToolConfig(),
            resources: resources,
            options: FinalizeOptions(capabilityMode: .readWrite)
        )
        let names = bridge.toolDefinitions().map(\.name)
        #expect(names == ["image_edit", "image_gen"])
        #expect(bridge.toolKind(for: "image_gen") == .imageGen)
        #expect(bridge.toolKind(for: "image_edit") == .imageGen)
        let genDefinition = bridge.toolDefinitions().first { $0.name == "image_gen" }
        #expect(genDefinition?.argumentsSchema == BuiltinToolCatalog.imageGenSchema)
        #expect(genDefinition?.description == BuiltinToolCatalog.imageGenDescription)
    }

    /// Registration alone must not make a tool callable: a session that never
    /// bound an `ImageGenClient` gets `not_implemented`, not a bare crash or a
    /// silent success.
    @Test("a registered tool with no handler refuses to dispatch")
    func unboundHandlerRefuses() async throws {
        let builder = ToolRegistryBuilder()
        let pipeline = PermissionPipeline(
            permissions: PermissionHandle(allowAll: true, shellCwd: NSTemporaryDirectory())
        )
        let bridge = try ToolBridge.finalize(
            builder: builder,
            config: imageToolConfig(),
            resources: ToolResources(
                cwd: NSTemporaryDirectory(),
                permissionPipeline: pipeline
            ),
            options: FinalizeOptions(capabilityMode: .readWrite)
        )
        let result = await bridge.call(
            name: "image_gen",
            args: .object(["prompt": .string("a cat")])
        )
        guard case .failure(let error) = result else {
            Issue.record("expected an unbound image_gen call to fail")
            return
        }
        #expect(error.kind == .notImplemented)
    }

    /// The permission category upstream actually uses. A `denyMutations`
    /// session refuses `write` but must still dispatch `image_gen`: routing
    /// image generation to `AccessKind.edit` would deny a call upstream allows.
    @Test("image tools dispatch under a mutation-denying permission pipeline")
    func permissionCategoryIsRead() async throws {
        let root = NSTemporaryDirectory()
        let permissions = PermissionHandle(
            config: PermissionConfig(
                rules: [PermissionRule(action: .deny, tool: .edit, source: .synthetic)],
                promptPolicy: .deny
            ),
            allowAll: false,
            shellCwd: root,
            prompter: HeadlessPermissionPrompter()
        )
        let resources = ToolResources(
            cwd: root,
            permissionPipeline: PermissionPipeline(
                permissions: permissions,
                planMode: PlanModeTracker(sessionDirectory: root),
                hooks: FailOpenPreToolUseHookRunner()
            )
        )

        var builder = ToolRegistryBuilder()
        let box = RecordingHandler.Box()
        let handler = RecordingHandler(box: box)
        builder.setHandler(
            qualifiedId: BuiltinToolCatalog.imageGenQualifiedId,
            handler: handler
        )
        // The write tool is the control: same pipeline, same session, denied.
        builder.setHandler(qualifiedId: "OpenCode:write", handler: handler)

        var config = imageToolConfig()
        config.tools.append(ToolConfig.fromId("OpenCode:write", kind: .write))
        let bridge = try ToolBridge.finalize(
            builder: builder,
            config: config,
            resources: resources,
            options: FinalizeOptions(capabilityMode: .readWrite)
        )

        let denied = await bridge.call(
            name: "write",
            args: .object(["file_path": .string("x.txt"), "content": .string("y")])
        )
        guard case .failure(let writeError) = denied else {
            Issue.record("expected write to be denied under denyMutations")
            return
        }
        #expect(writeError.kind == .permissionDenied)

        let allowed = await bridge.call(
            name: "image_gen",
            args: .object(["prompt": .string("a cat")])
        )
        #expect(allowed.isSuccess)
        #expect(box.recorded == ["image_gen"])
    }
}

extension Result {
    fileprivate var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
