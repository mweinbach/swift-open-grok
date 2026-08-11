// MCPMetaToolTests.swift
//
// Tests for search_tool / use_tool MCP meta-tools: catalog entries, schemas,
// description truncation, grouped search results, qualified-name validation,
// native-tool corrective error, dispatch routing, and capability-mode listing.

import Foundation
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokToolRuntime
import OpenGrokToolTypes
import OpenGrokWorkspace
import Testing
@testable import OpenGrokToolRegistry

// MARK: - Stubs

private struct StubSearchIndex: ToolSearchIndexing {
    var snapshot: ToolSearchSnapshot = ToolSearchSnapshot()
    var summaries: [MCPServerSummary] = []

    func searchSnapshot(query: String, limit: Int) -> ToolSearchSnapshot {
        var s = snapshot
        s.results = Array(s.results.prefix(limit))
        return s
    }

    func listServerSummaries() -> [MCPServerSummary] {
        summaries
    }
}

private func makeToolset(
    capabilityMode: ToolCapabilityMode = .readWrite,
    pipeline: PermissionPipeline? = nil
) -> FinalizedToolset {
    var options = FinalizeOptions.unrestricted
    options.capabilityMode = capabilityMode
    return FinalizedToolset(
        tools: [],
        resources: ToolResources(
            cwd: NSTemporaryDirectory(),
            permissionPipeline: pipeline
        ),
        codeModeNamespaces: [:],
        options: options
    )
}

private func allowAllPipeline() -> PermissionPipeline {
    PermissionPipeline(
        permissions: PermissionHandle(allowAll: true, shellCwd: NSTemporaryDirectory())
    )
}

private func makeResources(
    index: StubSearchIndex? = nil,
    nativeTools: Set<String>? = nil
) -> ToolResources {
    let resources = ToolResources(cwd: NSTemporaryDirectory())
    if let index {
        resources.extras.insert(ToolSearchIndexResource(index))
    }
    if let nativeTools {
        resources.extras.insert(EnabledNativeToolNames(nativeTools))
    }
    return resources
}

// MARK: - Description truncation

@Suite("MCP description truncation")
struct MCPDescriptionTruncationTests {
    @Test("short description is unchanged")
    func shortUnchanged() {
        let short = "A short description"
        #expect(truncateMCPDescription(short) == short)
    }

    @Test("exact limit is unchanged")
    func exactLimit() {
        let exact = String(repeating: "x", count: maxMCPDescriptionLength)
        #expect(truncateMCPDescription(exact) == exact)
    }

    @Test("over limit appends suffix")
    func overLimitAppendsSuffix() {
        let long = String(repeating: "a", count: maxMCPDescriptionLength + 100)
        let result = truncateMCPDescription(long)
        #expect(result.hasSuffix("\u{2026} [truncated]"))
        #expect(result.count <= maxMCPDescriptionLength)
    }

    @Test("multi-byte chars under char limit unchanged")
    func multibyte() {
        let cjk = String(repeating: "\u{4e16}", count: 1024)
        #expect(cjk.count < maxMCPDescriptionLength)
        #expect(truncateMCPDescription(cjk) == cjk)
    }
}

// MARK: - Description sanitization

@Suite("MCP description sanitization")
struct MCPDescriptionSanitizationTests {
    @Test("newlines and excess whitespace collapse to spaces")
    func sanitizes() {
        let raw = "Line one\nLine two\r\nLine three"
        #expect(sanitizeMCPDescription(raw) == "Line one Line two Line three")
    }

    @Test("already clean string unchanged")
    func clean() {
        let clean = "Already clean"
        #expect(sanitizeMCPDescription(clean) == clean)
    }
}

// MARK: - Catalog entries

@Suite("MCP meta-tool catalog")
struct MCPMetaToolCatalogTests {
    @Test("search_tool and use_tool are in builtinTools")
    func inBuiltinCatalog() {
        let ids = BuiltinToolCatalog.builtinTools.map(\.qualifiedId)
        #expect(ids.contains("GrokBuild:search_tool"))
        #expect(ids.contains("GrokBuild:use_tool"))
    }

    @Test("search_tool has correct kind and schema")
    func searchToolSpec() {
        let spec = BuiltinToolCatalog.mcpMetaTools.first { $0.id == "search_tool" }
        #expect(spec?.kind == .searchTool)
        #expect(spec?.namespace == .grokBuild)
        if case .object(let props) = spec?.inputSchema,
           case .object(let properties) = props["properties"] {
            #expect(properties["query"] != nil)
            #expect(properties["limit"] != nil)
        } else {
            Issue.record("search_tool schema missing properties")
        }
    }

    @Test("use_tool has correct kind and schema")
    func useToolSpec() {
        let spec = BuiltinToolCatalog.mcpMetaTools.first { $0.id == "use_tool" }
        #expect(spec?.kind == .useTool)
        #expect(spec?.namespace == .grokBuild)
        if case .object(let props) = spec?.inputSchema,
           case .object(let properties) = props["properties"] {
            #expect(properties["tool_name"] != nil)
            #expect(properties["tool_input"] != nil)
        } else {
            Issue.record("use_tool schema missing properties")
        }
    }

    @Test("use_tool tool_input allows arbitrary properties")
    func useToolInputAllowsArbitrary() {
        if case .object(let props) = useToolSchema,
           case .object(let properties) = props["properties"],
           case .object(let inputSchema) = properties["tool_input"],
           case .bool(let additional) = inputSchema["additionalProperties"] {
            #expect(additional == true)
        } else {
            Issue.record("tool_input must have additionalProperties: true")
        }
    }
}

// MARK: - Capability mode

@Suite("MCP meta-tool capability mode")
struct MCPMetaToolCapabilityTests {
    @Test("search_tool is always allowed")
    func searchToolAlwaysAllowed() {
        for mode in ToolCapabilityMode.allCases {
            #expect(
                mode.kindAllowed(.searchTool),
                "search_tool should be allowed in \(mode)"
            )
        }
    }

    @Test("use_tool requires readWrite or execute")
    func useToolRequiresWrite() {
        #expect(ToolCapabilityMode.readWrite.kindAllowed(.useTool))
        #expect(ToolCapabilityMode.execute.kindAllowed(.useTool))
        #expect(ToolCapabilityMode.all.kindAllowed(.useTool))
        #expect(!ToolCapabilityMode.readOnly.kindAllowed(.useTool))
    }
}

// MARK: - search_tool handler

@Suite("search_tool handler")
struct SearchToolHandlerTests {
    @Test("empty catalog returns note about no integration tools")
    func emptyCatalog() async {
        let handler = SearchToolHandler()
        let resources = makeResources()
        let result = await handler.invoke(
            clientName: "search_tool",
            args: .object(["query": .string("linear")]),
            ctx: ToolCallContext(),
            resources: resources
        )
        guard case .success(let output) = result else {
            Issue.record("expected success"); return
        }
        let text = output.modelOutput.first.flatMap {
            if case .text(let t) = $0 { return t } else { return nil }
        } ?? ""
        #expect(text.contains("No integration tools are configured"))
    }

    @Test("results are grouped by server")
    func groupedByServer() async {
        var index = StubSearchIndex()
        index.snapshot = ToolSearchSnapshot(results: [
            ToolSearchResult(toolName: "linear__save_issue", serverName: "linear",
                             description: "Save", score: 2.0),
            ToolSearchResult(toolName: "linear__search", serverName: "linear",
                             description: "Search", score: 1.5),
            ToolSearchResult(toolName: "slack__post_message", serverName: "slack",
                             description: "Post", score: 1.0),
        ], totalHiddenTools: 5, isReady: true)

        let handler = SearchToolHandler()
        let resources = makeResources(index: index)
        let result = await handler.invoke(
            clientName: "search_tool",
            args: .object(["query": .string("save")]),
            ctx: ToolCallContext(),
            resources: resources
        )
        guard case .success(let output) = result else {
            Issue.record("expected success"); return
        }
        let text = output.modelOutput.first.flatMap {
            if case .text(let t) = $0 { return t } else { return nil }
        } ?? ""
        #expect(text.contains("\"status\" : \"ready\""))
        #expect(text.contains("\"server\" : \"linear\""))
        #expect(text.contains("\"server\" : \"slack\""))
        #expect(text.contains("\"total_hidden_tools\" : 5"))
    }

    @Test("partial status when index is not ready")
    func partialStatus() async {
        var index = StubSearchIndex()
        index.snapshot = ToolSearchSnapshot(results: [], isReady: false)

        let handler = SearchToolHandler()
        let resources = makeResources(index: index)
        let result = await handler.invoke(
            clientName: "search_tool",
            args: .object(["query": .string("test")]),
            ctx: ToolCallContext(),
            resources: resources
        )
        guard case .success(let output) = result else {
            Issue.record("expected success"); return
        }
        let text = output.modelOutput.first.flatMap {
            if case .text(let t) = $0 { return t } else { return nil }
        } ?? ""
        #expect(text.contains("\"status\" : \"partial\""))
    }

    @Test("limit parameter caps result count")
    func limitParameter() async {
        var index = StubSearchIndex()
        index.snapshot = ToolSearchSnapshot(results: (0..<10).map { i in
            ToolSearchResult(
                toolName: "server__tool_\(i)", serverName: "server",
                description: "Tool \(i)", score: Float(10 - i)
            )
        })

        let handler = SearchToolHandler()
        let resources = makeResources(index: index)
        let result = await handler.invoke(
            clientName: "search_tool",
            args: .object(["query": .string("tool"), "limit": .number(.int64(3))]),
            ctx: ToolCallContext(),
            resources: resources
        )
        guard case .success(let output) = result else {
            Issue.record("expected success"); return
        }
        let text = output.modelOutput.first.flatMap {
            if case .text(let t) = $0 { return t } else { return nil }
        } ?? ""
        #expect(text.contains("tool_0"))
        #expect(text.contains("tool_2"))
        #expect(!text.contains("tool_3"))
    }

    @Test("schemas are included in results")
    func schemasIncluded() async {
        let schema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "title": .object(["type": .string("string")])
            ]),
        ])
        var index = StubSearchIndex()
        index.snapshot = ToolSearchSnapshot(results: [
            ToolSearchResult(
                toolName: "linear__save_issue", serverName: "linear",
                description: "Save an issue.", inputSchema: schema, score: 1.0
            ),
        ])

        let handler = SearchToolHandler()
        let resources = makeResources(index: index)
        let result = await handler.invoke(
            clientName: "search_tool",
            args: .object(["query": .string("linear")]),
            ctx: ToolCallContext(),
            resources: resources
        )
        guard case .success(let output) = result else {
            Issue.record("expected success"); return
        }
        let text = output.modelOutput.first.flatMap {
            if case .text(let t) = $0 { return t } else { return nil }
        } ?? ""
        #expect(text.contains("input_schema"))
        #expect(text.contains("\"title\""))
    }

    @Test("missing query returns error")
    func missingQuery() async {
        let handler = SearchToolHandler()
        let resources = makeResources()
        let result = await handler.invoke(
            clientName: "search_tool",
            args: .object([:]),
            ctx: ToolCallContext(),
            resources: resources
        )
        guard case .failure(let err) = result else {
            Issue.record("expected failure"); return
        }
        #expect(err.kind == .invalidArguments)
        #expect(err.detail.contains("query"))
    }
}

// MARK: - use_tool handler

@Suite("use_tool handler")
struct UseToolHandlerTests {
    @Test("rejects unqualified tool name with search_tool steer")
    func rejectsUnqualified() async {
        let toolset = makeToolset()
        let handler = UseToolHandler(toolset: toolset)
        let resources = makeResources()
        let result = await handler.invoke(
            clientName: "use_tool",
            args: .object([
                "tool_name": .string("read_file"),
                "tool_input": .object([:]),
            ]),
            ctx: ToolCallContext(),
            resources: resources
        )
        guard case .failure(let err) = result else {
            Issue.record("expected failure"); return
        }
        #expect(err.kind == .invalidArguments)
        #expect(err.detail.contains("not a valid MCP tool name"))
        #expect(err.detail.contains("search_tool"))
    }

    @Test("native tool returns corrective error")
    func nativeToolCorrective() async {
        let toolset = makeToolset()
        let handler = UseToolHandler(toolset: toolset)
        let resources = makeResources(nativeTools: ["scheduler_create"])
        let result = await handler.invoke(
            clientName: "use_tool",
            args: .object([
                "tool_name": .string("scheduler_create"),
                "tool_input": .object(["interval": .string("5m")]),
            ]),
            ctx: ToolCallContext(),
            resources: resources
        )
        guard case .failure(let err) = result else {
            Issue.record("expected failure"); return
        }
        #expect(err.kind == .invalidArguments)
        #expect(err.detail.contains("native tool"))
        #expect(err.detail.contains("scheduler_create"))
        #expect(err.detail.contains("directly"))
    }

    @Test("unknown non-MCP name gets generic warning, not corrective")
    func unknownNonMCPName() async {
        let toolset = makeToolset()
        let handler = UseToolHandler(toolset: toolset)
        let resources = makeResources(nativeTools: ["scheduler_create"])
        let result = await handler.invoke(
            clientName: "use_tool",
            args: .object([
                "tool_name": .string("jira"),
                "tool_input": .object([:]),
            ]),
            ctx: ToolCallContext(),
            resources: resources
        )
        guard case .failure(let err) = result else {
            Issue.record("expected failure"); return
        }
        #expect(err.detail.contains("not a valid MCP tool name"))
        #expect(!err.detail.contains("native tool"))
    }

    @Test("qualified name dispatches through the toolset")
    func qualifiedDispatches() async {
        let toolset = makeToolset(pipeline: allowAllPipeline())
        var provider = StubMCPProvider(serverName: "linear")
        provider.tools = [MCPBridgedTool(name: "save_issue", description: "Save")]
        provider.result = MCPBridgedCallResult(text: "issue created")
        await MCPToolBridge.register(provider: provider, into: toolset)

        let handler = UseToolHandler(toolset: toolset)
        let resources = makeResources()
        let result = await handler.invoke(
            clientName: "use_tool",
            args: .object([
                "tool_name": .string("linear__save_issue"),
                "tool_input": .object(["title": .string("test")]),
            ]),
            ctx: ToolCallContext(),
            resources: resources
        )
        guard case .success(let output) = result else {
            Issue.record("expected success, got \(result)"); return
        }
        #expect(output.modelOutput == [.text(text: "issue created")])
        #expect(provider.calls.all.first?.name == "save_issue")
    }

    @Test("string-encoded tool_input is parsed to object")
    func stringEncodedInput() async {
        let toolset = makeToolset(pipeline: allowAllPipeline())
        var provider = StubMCPProvider(serverName: "linear")
        provider.tools = [MCPBridgedTool(name: "list_issues", description: "List")]
        provider.result = MCPBridgedCallResult(text: "ok")
        await MCPToolBridge.register(provider: provider, into: toolset)

        let handler = UseToolHandler(toolset: toolset)
        let resources = makeResources()
        let result = await handler.invoke(
            clientName: "use_tool",
            args: .object([
                "tool_name": .string("linear__list_issues"),
                "tool_input": .string("{\"assignee\": \"me\", \"limit\": 10}"),
            ]),
            ctx: ToolCallContext(),
            resources: resources
        )
        guard case .success = result else {
            Issue.record("expected success"); return
        }
        let captured = provider.calls.all.first?.arguments
        if case .object(let obj) = captured {
            #expect(obj["assignee"] == .string("me"))
            // JSONDecoder yields `.double` for bare JSON numbers; assert via
            // the numeric accessor rather than a specific case tag.
            #expect(obj["limit"]?.int64Value == 10)
        } else {
            Issue.record("expected captured arguments to be an object, got \(String(describing: captured))")
        }
    }

    @Test("null tool_input normalizes to empty object")
    func nullToolInput() async {
        let toolset = makeToolset(pipeline: allowAllPipeline())
        var provider = StubMCPProvider(serverName: "server")
        provider.tools = [MCPBridgedTool(name: "tool", description: "Tool")]
        provider.result = MCPBridgedCallResult(text: "ok")
        await MCPToolBridge.register(provider: provider, into: toolset)

        let handler = UseToolHandler(toolset: toolset)
        let resources = makeResources()
        _ = await handler.invoke(
            clientName: "use_tool",
            args: .object([
                "tool_name": .string("server__tool"),
                "tool_input": .null,
            ]),
            ctx: ToolCallContext(),
            resources: resources
        )
        let captured = provider.calls.all.first?.arguments
        #expect(captured == .object([:]))
    }

    @Test("unknown qualified name returns not-found")
    func unknownQualifiedName() async {
        let toolset = makeToolset(pipeline: allowAllPipeline())
        let handler = UseToolHandler(toolset: toolset)
        let resources = makeResources()
        let result = await handler.invoke(
            clientName: "use_tool",
            args: .object([
                "tool_name": .string("ghost__tool"),
                "tool_input": .object([:]),
            ]),
            ctx: ToolCallContext(),
            resources: resources
        )
        guard case .failure(let err) = result else {
            Issue.record("expected failure"); return
        }
        #expect(err.kind == .notFound)
    }

    @Test("missing tool_name returns error")
    func missingToolName() async {
        let toolset = makeToolset()
        let handler = UseToolHandler(toolset: toolset)
        let resources = makeResources()
        let result = await handler.invoke(
            clientName: "use_tool",
            args: .object(["tool_input": .object([:])]),
            ctx: ToolCallContext(),
            resources: resources
        )
        guard case .failure(let err) = result else {
            Issue.record("expected failure"); return
        }
        #expect(err.kind == .invalidArguments)
        #expect(err.detail.contains("tool_name"))
    }
}

// MARK: - Grouping helper

@Suite("Server grouping")
struct ServerGroupingTests {
    @Test("results group by server preserving score order within groups")
    func groupsPreserveOrder() {
        let results = [
            ToolSearchResult(toolName: "a__x", serverName: "a", description: "", score: 3.0),
            ToolSearchResult(toolName: "b__y", serverName: "b", description: "", score: 2.5),
            ToolSearchResult(toolName: "a__z", serverName: "a", description: "", score: 2.0),
            ToolSearchResult(toolName: "b__w", serverName: "b", description: "", score: 1.0),
        ]
        let groups = groupByServer(results)
        #expect(groups.count == 2)
        #expect(groups[0].serverName == "a")
        #expect(groups[0].tools.count == 2)
        #expect(groups[0].tools[0].toolName == "a__x")
        #expect(groups[0].tools[1].toolName == "a__z")
        #expect(groups[1].serverName == "b")
    }

    @Test("empty results produce empty groups")
    func emptyResults() {
        let groups = groupByServer([])
        #expect(groups.isEmpty)
    }
}

// MARK: - Argument normalization

@Suite("Argument normalization")
struct ArgumentNormalizationTests {
    @Test("null normalizes to empty object")
    func nullToObject() {
        #expect(normalizeArguments(.null) == .object([:]))
    }

    @Test("string-encoded JSON object is parsed")
    func stringParsed() {
        let input = JSONValue.string("{\"key\": \"value\"}")
        let result = normalizeArguments(input)
        if case .object(let obj) = result {
            #expect(obj["key"] == .string("value"))
        } else {
            Issue.record("expected parsed object, got \(result)")
        }
    }

    @Test("non-JSON string passes through")
    func nonJsonString() {
        let input = JSONValue.string("not json")
        #expect(normalizeArguments(input) == input)
    }

    @Test("object passes through unchanged")
    func objectUnchanged() {
        let input = JSONValue.object(["a": .string("b")])
        #expect(normalizeArguments(input) == input)
    }
}

// MARK: - Registry builder integration

@Suite("MCP meta-tool registry integration")
struct MCPMetaToolRegistryTests {
    @Test("search_tool and use_tool survive finalization")
    func finalizesMetaTools() {
        let builder = ToolRegistryBuilder()
        let config = ToolServerConfig(tools: [
            ToolConfig.fromId("GrokBuild:search_tool", kind: .searchTool),
            ToolConfig.fromId("GrokBuild:use_tool", kind: .useTool),
            ToolConfig.fromId("GrokBuild:read_file", kind: .read),
        ])
        let result = builder.finalize(
            config: config,
            resources: ToolResources(cwd: NSTemporaryDirectory())
        )
        guard case .success(let toolset) = result else {
            Issue.record("expected success, got \(result)"); return
        }
        let names = toolset.clientNames
        #expect(names.contains("search_tool"))
        #expect(names.contains("use_tool"))
        #expect(names.contains("read_file"))
    }

    @Test("readOnly mode drops use_tool but keeps search_tool")
    func readOnlyDropsUseTool() {
        let builder = ToolRegistryBuilder()
        let config = ToolServerConfig(tools: [
            ToolConfig.fromId("GrokBuild:search_tool", kind: .searchTool),
            ToolConfig.fromId("GrokBuild:use_tool", kind: .useTool),
            ToolConfig.fromId("GrokBuild:read_file", kind: .read),
        ])
        let result = builder.finalize(
            config: config,
            resources: ToolResources(cwd: NSTemporaryDirectory()),
            options: FinalizeOptions(capabilityMode: .readOnly)
        )
        guard case .success(let toolset) = result else {
            Issue.record("expected success"); return
        }
        let names = toolset.clientNames
        #expect(names.contains("search_tool"))
        #expect(!names.contains("use_tool"))
    }
}

// MARK: - Stub MCP provider for use_tool dispatch tests

private final class StubCallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(name: String, arguments: JSONValue)] = []

    // NSLock is sync-only under Swift 6 / macOS 27 SDK — keep lock use in
    // private sync helpers so async call sites never touch it directly.
    func record(name: String, arguments: JSONValue) {
        recordLocked(name: name, arguments: arguments)
    }

    var all: [(name: String, arguments: JSONValue)] {
        snapshotLocked()
    }

    private func recordLocked(name: String, arguments: JSONValue) {
        lock.lock()
        entries.append((name, arguments))
        lock.unlock()
    }

    private func snapshotLocked() -> [(name: String, arguments: JSONValue)] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }
}

private struct StubMCPProvider: MCPToolProviding {
    let serverName: String
    var tools: [MCPBridgedTool] = []
    var result: MCPBridgedCallResult = MCPBridgedCallResult(text: "ok")
    let calls: StubCallLog = StubCallLog()

    func listBridgedTools() async throws -> [MCPBridgedTool] { tools }

    func callBridgedTool(name: String, arguments: JSONValue) async throws -> MCPBridgedCallResult {
        calls.record(name: name, arguments: arguments)
        return result
    }
}
