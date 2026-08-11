// OpenGrokToolRegistryTests.swift
//
// Focused tests for R19 registry finalization: capability, allow/deny,
// tool mode, packs, hosted/direct-only, Code Mode namespaces, output caps.

import Foundation
import Testing
@testable import OpenGrokToolRegistry
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokToolRuntime
import OpenGrokWorkspace

@Suite("OpenGrokToolRegistry finalization")
struct ToolRegistryTests {

    @Test("catalog contains W5-S1 file tools with kinds")
    func catalogFileTools() {
        let kinds = BuiltinToolCatalog.fileToolKinds
        #expect(kinds["GrokBuild:read_file"] == .read)
        #expect(kinds["GrokBuild:search_replace"] == .edit)
        #expect(kinds["GrokBuild:grep"] == .search)
        #expect(kinds["GrokBuild:list_dir"] == .listDir)
        #expect(kinds["Codex:apply_patch"] == .edit)
        #expect(kinds["OpenCode:edit"] == .edit)
        #expect(kinds["OpenCode:write"] == .write)
        #expect(kinds["OpenCode:glob"] == .search)
        #expect(kinds["GrokBuildHashline:hashline_edit"] == .edit)
        #expect(BuiltinToolCatalog.allQualifiedIds.count >= 15)
    }

    @Test("capability mode drops edit tools under read-only")
    func capabilityReadOnly() throws {
        let builder = ToolRegistryBuilder()
        let full = toolServerConfig(for: .grokBuild, catalogKinds: builder.knownToolKinds())
        let filtered = ToolCapabilityMode.readOnly.filter(full)
        let ids = Set(filtered.tools.map(\.id))
        #expect(ids.contains("GrokBuild:read_file"))
        #expect(ids.contains("GrokBuild:grep"))
        #expect(!ids.contains("GrokBuild:search_replace"))
    }

    @Test("capability mode execute keeps search but not edit")
    func capabilityExecute() {
        let builder = ToolRegistryBuilder()
        let full = toolServerConfig(for: .grokBuild, catalogKinds: builder.knownToolKinds())
        let filtered = ToolCapabilityMode.execute.filter(full)
        let ids = Set(filtered.tools.map(\.id))
        #expect(ids.contains("GrokBuild:read_file"))
        #expect(!ids.contains("GrokBuild:search_replace"))
    }

    @Test("capability mode is subset partial order")
    func capabilitySubset() {
        #expect(ToolCapabilityMode.readOnly.isSubset(of: .all))
        #expect(ToolCapabilityMode.readOnly.isSubset(of: .readWrite))
        #expect(ToolCapabilityMode.readOnly.isSubset(of: .execute))
        #expect(!ToolCapabilityMode.readWrite.isSubset(of: .execute))
        #expect(!ToolCapabilityMode.execute.isSubset(of: .readWrite))
        #expect(ToolCapabilityMode.readWrite.isSubset(of: .all))
    }

    @Test("allow/deny name filters")
    func nameFilters() {
        let f = ToolNameFilters(allow: ["read_file", "grep"], deny: ["grep"])
        #expect(f.admits(clientName: "read_file"))
        #expect(!f.admits(clientName: "grep"))
        #expect(!f.admits(clientName: "search_replace"))
    }

    @Test("finalize explore preset is read-only tools")
    func finalizeExplore() throws {
        let builder = ToolRegistryBuilder()
        let config = toolServerConfig(for: .explore, catalogKinds: builder.knownToolKinds())
        let resources = ToolResources(cwd: "/tmp")
        let set = try unwrap(builder.finalize(config: config, resources: resources))
        let names = Set(set.clientNames)
        #expect(names == ["grep", "list_dir", "read_file"])
        #expect(set.topLevelDefinitions().count == 3)
    }

    @Test("finalize rejects unknown tool id")
    func finalizeUnknown() {
        let builder = ToolRegistryBuilder()
        let config = ToolServerConfig(tools: [ToolConfig.fromId("GrokBuild:not_a_real_tool")])
        let resources = ToolResources(cwd: "/tmp")
        switch builder.finalize(config: config, resources: resources) {
        case .success:
            Issue.record("expected failure")
        case .failure(let errors):
            #expect(errors.contains { $0.category == "tool_not_found" })
        }
    }

    @Test("finalize rejects mixed standard and hashline file tools")
    func fileToolsetConflict() {
        let builder = ToolRegistryBuilder()
        let config = ToolServerConfig(tools: [
            ToolConfig.fromId("GrokBuild:read_file", kind: .read),
            ToolConfig.fromId("GrokBuildHashline:hashline_read", kind: .read),
        ])
        let resources = ToolResources(cwd: "/tmp")
        switch builder.finalize(config: config, resources: resources) {
        case .success:
            Issue.record("expected file_toolset_conflict")
        case .failure(let errors):
            #expect(errors.contains { $0.category == "file_toolset_conflict" })
        }
    }

    @Test("finalize rejects duplicate client names")
    func duplicateClientName() {
        let builder = ToolRegistryBuilder()
        let config = ToolServerConfig(tools: [
            ToolConfig.fromId("GrokBuild:read_file", kind: .read).withName("dup"),
            ToolConfig.fromId("GrokBuild:list_dir", kind: .listDir).withName("dup"),
        ])
        let resources = ToolResources(cwd: "/tmp")
        switch builder.finalize(config: config, resources: resources) {
        case .success:
            Issue.record("expected duplicate_client_name")
        case .failure(let errors):
            #expect(errors.contains { $0.category == "duplicate_client_name" })
        }
    }

    @Test("Code Mode Only hides ordinary tools top-level but keeps nested")
    func codeModeOnlyVisibility() throws {
        let builder = ToolRegistryBuilder()
        let config = toolServerConfig(for: .explore, catalogKinds: builder.knownToolKinds())
        let resources = ToolResources(cwd: "/tmp")
        let options = FinalizeOptions(toolMode: .codeModeOnly)
        let set = try unwrap(builder.finalize(config: config, resources: resources, options: options))
        #expect(set.topLevelDefinitions().isEmpty)
        #expect(set.nestedDefinitions().count == 3)
        #expect(set.codeModeNamespaces[""]?.toolNames.contains("read_file") == true)
    }

    @Test("direct-only tools remain top-level under Code Mode Only")
    func directOnlyTopLevel() {
        let vis = listVisibility(
            clientName: "ask_user_question",
            kind: .askUser,
            options: FinalizeOptions(toolMode: .codeModeOnly)
        )
        #expect(vis == .topLevel)
        let hiddenHosted = listVisibility(
            clientName: "web_search",
            kind: .webSearch,
            options: FinalizeOptions(
                toolMode: .standard,
                hostedClientNames: ["web_search"],
                includeHosted: false
            )
        )
        #expect(hiddenHosted == .hidden)
    }

    @Test("deny filter drops tools during finalize")
    func denyFilterFinalize() throws {
        let builder = ToolRegistryBuilder()
        let config = toolServerConfig(for: .explore, catalogKinds: builder.knownToolKinds())
        let resources = ToolResources(cwd: "/tmp")
        let options = FinalizeOptions(nameFilters: ToolNameFilters(deny: ["grep"]))
        let set = try unwrap(builder.finalize(config: config, resources: resources, options: options))
        #expect(!set.clientNames.contains("grep"))
        #expect(set.clientNames.contains("read_file"))
    }

    @Test("behavior version resolution for managed tools")
    func versions() {
        switch resolveVersion(presetName: "legacy-0.4.10", fqToolId: "GrokBuild:read_file", override: nil) {
        case .success(let v):
            #expect(v == "legacy-0.4.10")
        case .failure(let m):
            Issue.record("resolveVersion failed: \(m)")
        }
        #expect(isLegacyContract("legacy-0.4.10"))
        #expect(!isLegacyContract("current"))
        #expect(isVersionManaged("GrokBuild:search_replace"))
        #expect(!isVersionManaged("OpenCode:edit"))
    }

    @Test("output cap preserves head/tail metadata")
    func outputCapHeadTail() {
        let big = String(repeating: "A", count: 100) + String(repeating: "B", count: 100)
        let capped = truncateFrontAndBack(big, maxChars: 40)
        #expect(capped.metadata.truncated)
        #expect(capped.metadata.headChars == 20)
        #expect(capped.metadata.tailChars == 20)
        #expect(capped.text.contains("A"))
        #expect(capped.text.contains("B"))
        #expect(capped.text.contains("output truncated"))
        #expect(capped.metadata.footer != nil)

        let byteCap = capToolOutput(String(repeating: "x", count: 100_000), maxBytes: 1_000)
        #expect(byteCap.metadata.truncated)
        #expect(byteCap.metadata.totalBytes == 100_000)
        #expect(byteCap.metadata.shownBytes < 100_000)
        #expect(byteCap.metadata.headChars > 0)
        #expect(byteCap.metadata.tailChars > 0)
    }

    @Test("builder register accepts custom pack-style specs")
    func customRegister() {
        var builder = ToolRegistryBuilder(registerBuiltins: false)
        builder.register(
            spec: RegisteredToolSpec(
                namespace: .mcp,
                id: "demo_tool",
                kind: .other,
                description: "demo"
            )
        )
        #expect(builder.hasToolId("MCP:demo_tool"))
        #expect(builder.knownToolKinds()["MCP:demo_tool"] == .other)
    }

    @Test("prepareAndCall without handler returns notImplemented")
    func noHandler() async throws {
        let builder = ToolRegistryBuilder()
        let config = toolServerConfig(for: .explore, catalogKinds: builder.knownToolKinds())
        let pipeline = PermissionPipeline(
            permissions: PermissionHandle(allowAll: true, shellCwd: NSTemporaryDirectory())
        )
        let resources = ToolResources(cwd: "/tmp", permissionPipeline: pipeline)
        let set = try unwrap(builder.finalize(config: config, resources: resources))
        let result = await set.prepareAndCall(
            clientName: "read_file",
            args: .object(["target_file": .string("x")])
        )
        switch result {
        case .failure(let err):
            #expect(err.kind == .notImplemented)
        case .success:
            Issue.record("expected notImplemented without handler")
        }
    }

    @Test("namespace and kind wire forms")
    func taxonomyWire() throws {
        let data = try JSONEncoder().encode(ProductToolNamespace.grokBuild)
        let s = String(data: data, encoding: .utf8)
        #expect(s == "\"grok_build\"")
        #expect(ProductToolNamespace.grokBuild.displayName == "GrokBuild")
        let kindData = try JSONEncoder().encode(ProductToolKind.listDir)
        #expect(String(data: kindData, encoding: .utf8) == "\"list_dir\"")
        let meta = CanonicalToolMeta(name: "read_file", kind: .read, namespace: .grokBuild)
        #expect(meta.readOnly)
        #expect(meta.label == "Read")
    }

    @Test("future tool kinds remain parseable without registering inert specs")
    func taxonomyOnlyKindsAreNotRegistered() throws {
        // `image_to_video` / `reference_to_video` are real catalog entries now;
        // keep only kinds that still have no RegisteredToolSpec.
        let taxonomyOnlyKinds: [ProductToolKind] = [
            .lsp, .searchTool, .useTool,
        ]
        for kind in taxonomyOnlyKinds {
            let encoded = try JSONEncoder().encode(kind)
            #expect(try JSONDecoder().decode(ProductToolKind.self, from: encoded) == kind)
        }

        let registeredNames = Set(BuiltinToolCatalog.builtinTools.map(\.id))
        let taxonomyOnlyNames: Set<String> = [
            "lsp",
        ]
        #expect(registeredNames.isDisjoint(with: taxonomyOnlyNames))
        #expect(registeredNames.contains("image_to_video"))
        #expect(registeredNames.contains("reference_to_video"))
        #expect(
            BuiltinToolCatalog.videoToolKinds[BuiltinToolCatalog.referenceToVideoQualifiedId]
                == .referenceToVideo
        )
        #expect(
            BuiltinToolCatalog.referenceToVideoDescription
                == BuiltinToolCatalog.videoTools
                .first(where: { $0.id == "reference_to_video" })?
                .description
        )
    }
}

private func unwrap(
    _ result: Result<FinalizedToolset, RequirementErrors>
) throws -> FinalizedToolset {
    switch result {
    case .success(let s): return s
    case .failure(let e):
        throw e.first ?? RequirementError(tool: "?", message: "unknown")
    }
}
