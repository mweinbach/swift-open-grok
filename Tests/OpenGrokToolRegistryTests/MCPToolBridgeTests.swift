// MCPToolBridgeTests.swift
//
// Proves that MCP tools reach the model through the same finalized toolset and
// the same permission pipeline as file tools, and that a broken server degrades
// only its own tools.
//
// The provider seam is stubbed here so these run without a live MCP server; the
// full protocol path (real server actor -> real client actor -> registry) is
// covered by the end-to-end test in OpenGrokCLITests.

import Foundation
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokToolRuntime
import OpenGrokToolTypes
import OpenGrokWorkspace
import Testing
@testable import OpenGrokToolRegistry

// MARK: - Stubs

private struct StubProvider: MCPToolProviding {
    let serverName: String
    var tools: [MCPBridgedTool] = []
    var listError: (any Error)?
    var callError: (any Error)?
    var result: MCPBridgedCallResult = MCPBridgedCallResult(text: "ok")
    /// Records the raw tool name and arguments the bridge sent.
    let calls: CallLog = CallLog()

    func listBridgedTools() async throws -> [MCPBridgedTool] {
        if let listError { throw listError }
        return tools
    }

    func callBridgedTool(name: String, arguments: JSONValue) async throws -> MCPBridgedCallResult {
        calls.record(name: name, arguments: arguments)
        if let callError { throw callError }
        return result
    }
}

private final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(name: String, arguments: JSONValue)] = []

    func record(name: String, arguments: JSONValue) {
        lock.lock()
        entries.append((name, arguments))
        lock.unlock()
    }

    var all: [(name: String, arguments: JSONValue)] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
}

private struct StubError: Error, CustomStringConvertible {
    var description: String
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

private func allowAllPipeline(hooks: (any PreToolUseHookRunner)? = nil) -> PermissionPipeline {
    PermissionPipeline(
        permissions: PermissionHandle(allowAll: true, shellCwd: NSTemporaryDirectory()),
        hooks: FailOpenPreToolUseHookRunner(inner: hooks)
    )
}

// MARK: - Naming

@Suite("MCP tool naming")
struct MCPToolNamingTests {
    @Test("a qualified name is server, delimiter, tool")
    func qualifiedName() {
        #expect(mcpQualifiedToolName(server: "linear", tool: "save_issue") == "linear__save_issue")
        #expect(mcpServerToolPrefix("linear") == "linear__")
    }

    @Test("a qualified name round-trips")
    func roundTrips() {
        let parsed = parseMCPQualifiedToolName("linear__save_issue")
        #expect(parsed?.server == "linear")
        #expect(parsed?.tool == "save_issue")
    }

    @Test("ambiguous and malformed names are rejected")
    func rejectsAmbiguous() {
        // Zero delimiters.
        #expect(parseMCPQualifiedToolName("plain") == nil)
        // Two delimiter boundaries: could split either way.
        #expect(parseMCPQualifiedToolName("a__b__c") == nil)
        // Overlapping boundaries in `a___b` are equally ambiguous.
        #expect(parseMCPQualifiedToolName("a___b") == nil)
        // Empty halves.
        #expect(parseMCPQualifiedToolName("__tool") == nil)
        #expect(parseMCPQualifiedToolName("server__") == nil)
        #expect(parseMCPQualifiedToolName("") == nil)
    }

    @Test("two servers exposing the same tool name stay distinct")
    func distinctPerServer() {
        #expect(
            mcpQualifiedToolName(server: "a", tool: "search")
                != mcpQualifiedToolName(server: "b", tool: "search")
        )
    }
}

// MARK: - Registration

@Suite("MCP tool registration")
struct MCPToolRegistrationTests {
    @Test("discovered tools become callable under their qualified names")
    func registersTools() async {
        let toolset = makeToolset()
        let provider = StubProvider(serverName: "linear", tools: [
            MCPBridgedTool(name: "save_issue", description: "Save an issue."),
            MCPBridgedTool(name: "search", description: "Search issues."),
        ])

        let registration = await MCPToolBridge.register(provider: provider, into: toolset)

        #expect(registration.failure == nil)
        #expect(registration.registeredNames == ["linear__save_issue", "linear__search"])
        #expect(toolset.tool(named: "linear__save_issue") != nil)
        #expect(toolset.tool(named: "linear__search")?.namespace == .mcp)
    }

    @Test("registered tools appear in the model-facing definitions")
    func toolsAreListedToTheModel() async {
        let toolset = makeToolset()
        let provider = StubProvider(serverName: "linear", tools: [
            MCPBridgedTool(
                name: "save_issue",
                description: "Save an issue.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object(["title": .object(["type": .string("string")])]),
                ])
            )
        ])
        await MCPToolBridge.register(provider: provider, into: toolset)

        let definition = try? #require(
            toolset.topLevelDefinitions().first { $0.name == "linear__save_issue" }
        )
        #expect(definition?.description == "Save an issue.")
        #expect(definition?.argumentsSchema != nil)
    }

    @Test("a server hidden tool is skipped")
    func hiddenToolSkipped() async {
        let toolset = makeToolset()
        let provider = StubProvider(serverName: "linear", tools: [
            MCPBridgedTool(name: "visible", description: ""),
            MCPBridgedTool(name: "internal_only", description: "", modelVisible: false),
        ])

        let registration = await MCPToolBridge.register(provider: provider, into: toolset)
        #expect(registration.registeredNames == ["linear__visible"])
        #expect(registration.skipped["internal_only"] != nil)
        #expect(toolset.tool(named: "linear__internal_only") == nil)
    }

    @Test("a tool whose name would make an ambiguous qualified name is skipped")
    func ambiguousToolNameSkipped() async {
        let toolset = makeToolset()
        let provider = StubProvider(serverName: "linear", tools: [
            MCPBridgedTool(name: "fine", description: ""),
            MCPBridgedTool(name: "has__delimiter", description: ""),
            MCPBridgedTool(name: "has spaces", description: ""),
        ])

        let registration = await MCPToolBridge.register(provider: provider, into: toolset)
        #expect(registration.registeredNames == ["linear__fine"])
        #expect(registration.skipped.count == 2)
    }

    @Test("a server whose own name is unusable registers nothing")
    func unusableServerNameRejected() async {
        let toolset = makeToolset()
        let provider = StubProvider(serverName: "bad name", tools: [
            MCPBridgedTool(name: "tool", description: "")
        ])

        let registration = await MCPToolBridge.register(provider: provider, into: toolset)
        #expect(registration.isFailure)
        #expect(toolset.clientNames.isEmpty)
    }

    @Test("MCP tools are not exposed in read-only capability mode")
    func readOnlyModeExposesNothing() async {
        let toolset = makeToolset(capabilityMode: .readOnly)
        let provider = StubProvider(serverName: "linear", tools: [
            MCPBridgedTool(name: "search", description: "")
        ])

        let registration = await MCPToolBridge.register(provider: provider, into: toolset)
        #expect(registration.isFailure)
        #expect(toolset.clientNames.isEmpty)
    }

    @Test("unregister drops only the named server's tools")
    func unregisterIsScoped() async {
        let toolset = makeToolset()
        await MCPToolBridge.register(
            provider: StubProvider(serverName: "alpha", tools: [
                MCPBridgedTool(name: "one", description: "")
            ]),
            into: toolset
        )
        await MCPToolBridge.register(
            provider: StubProvider(serverName: "beta", tools: [
                MCPBridgedTool(name: "two", description: "")
            ]),
            into: toolset
        )
        #expect(toolset.clientNames.count == 2)

        MCPToolBridge.unregister(server: "alpha", from: toolset)
        #expect(toolset.clientNames == ["beta__two"])
    }
}

// MARK: - Failure isolation

@Suite("MCP failure isolation")
struct MCPFailureIsolationTests {
    @Test("a server that fails tools/list leaves the toolset untouched")
    func listFailureIsContained() async {
        let toolset = makeToolset()
        await MCPToolBridge.register(
            provider: StubProvider(serverName: "healthy", tools: [
                MCPBridgedTool(name: "ok", description: "")
            ]),
            into: toolset
        )

        var broken = StubProvider(serverName: "broken")
        broken.listError = StubError(description: "transport closed")

        let registration = await MCPToolBridge.register(provider: broken, into: toolset)
        #expect(registration.isFailure)
        #expect(registration.failure?.contains("transport closed") == true)
        // The healthy server's tool is still callable.
        #expect(toolset.clientNames == ["healthy__ok"])
    }

    @Test("a call that throws becomes a tool error, not a crash")
    func callFailureBecomesToolError() async {
        let toolset = makeToolset(pipeline: allowAllPipeline())
        var provider = StubProvider(serverName: "linear", tools: [
            MCPBridgedTool(name: "search", description: "")
        ])
        provider.callError = StubError(description: "server went away")
        await MCPToolBridge.register(provider: provider, into: toolset)

        let outcome = await toolset.prepareAndCall(
            clientName: "linear__search",
            args: .object(["q": .string("x")])
        )
        guard case .failure(let error) = outcome else {
            Issue.record("expected a failure")
            return
        }
        #expect(error.detail.contains("server went away"))

        // The tool stays registered and callable; one bad call is not fatal.
        #expect(toolset.tool(named: "linear__search") != nil)
    }

    @Test("a server-reported isError becomes a tool error carrying the message")
    func serverErrorResultSurfaces() async {
        let toolset = makeToolset(pipeline: allowAllPipeline())
        var provider = StubProvider(serverName: "linear", tools: [
            MCPBridgedTool(name: "search", description: "")
        ])
        provider.result = MCPBridgedCallResult(text: "rate limited", isError: true)
        await MCPToolBridge.register(provider: provider, into: toolset)

        let outcome = await toolset.prepareAndCall(
            clientName: "linear__search",
            args: .object([:])
        )
        guard case .failure(let error) = outcome else {
            Issue.record("expected a failure")
            return
        }
        #expect(error.detail == "rate limited")
    }

    @Test("calling an unregistered MCP tool is a not-found error")
    func unknownToolIsNotFound() async {
        let toolset = makeToolset(pipeline: allowAllPipeline())
        let outcome = await toolset.prepareAndCall(
            clientName: "ghost__tool",
            args: .object([:])
        )
        guard case .failure(let error) = outcome else {
            Issue.record("expected a failure")
            return
        }
        #expect(error.kind == .notFound)
    }
}

// MARK: - Permission routing

/// Records what the permission pipeline was asked to authorize.
private final class RecordingHookRunner: PreToolUseHookRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [(toolName: String, access: AccessKind)] = []
    var denyReason: String?

    init(denyReason: String? = nil) { self.denyReason = denyReason }

    func runPreToolUse(
        toolName: String,
        toolCallId: String,
        access: AccessKind,
        permissionMode: String?
    ) async -> PreToolUseHookDecision {
        record(toolName: toolName, access: access)
        if let denyReason {
            return .deny(reason: denyReason, hookName: "recorder")
        }
        return .allow
    }

    private func record(toolName: String, access: AccessKind) {
        lock.lock()
        seen.append((toolName, access))
        lock.unlock()
    }

    var observed: [(toolName: String, access: AccessKind)] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }
}

@Suite("MCP permission routing")
struct MCPPermissionRoutingTests {
    @Test("an MCP call is classified as an MCP access, not a read")
    func classifiedAsMCPTool() async {
        let recorder = RecordingHookRunner()
        let toolset = makeToolset(pipeline: allowAllPipeline(hooks: recorder))
        await MCPToolBridge.register(
            provider: StubProvider(serverName: "linear", tools: [
                MCPBridgedTool(name: "search", description: "")
            ]),
            into: toolset
        )

        _ = await toolset.prepareAndCall(
            clientName: "linear__search",
            args: .object(["query": .string("bug")])
        )

        let observed = try? #require(recorder.observed.first)
        #expect(observed?.toolName == "linear__search")
        guard case .mcpTool(let name, let input)? = observed?.access else {
            Issue.record("expected .mcpTool, got \(String(describing: observed?.access))")
            return
        }
        // The qualified name is what permission rules glob against, and the raw
        // arguments ride along for the classifier.
        #expect(name == "linear__search")
        #expect(input == .object(["query": .string("bug")]))
    }

    @Test("a PreToolUse deny blocks the MCP call before it reaches the server")
    func hookDenyBlocksTheCall() async {
        let toolset = makeToolset(
            pipeline: allowAllPipeline(hooks: RecordingHookRunner(denyReason: "no external calls"))
        )
        let provider = StubProvider(serverName: "linear", tools: [
            MCPBridgedTool(name: "search", description: "")
        ])
        await MCPToolBridge.register(provider: provider, into: toolset)

        let outcome = await toolset.prepareAndCall(
            clientName: "linear__search",
            args: .object([:])
        )
        guard case .failure = outcome else {
            Issue.record("expected the hook deny to block the dispatch")
            return
        }
        // The server was never contacted.
        #expect(provider.calls.all.isEmpty)
    }

    @Test("a deny rule on tool 'mcp' blocks the call")
    func mcpDenyRuleBlocks() async {
        var config = PermissionConfig()
        config.rules = [
            PermissionRule(action: .deny, tool: .mcp, pattern: "linear__*")
        ]
        let pipeline = PermissionPipeline(
            permissions: PermissionHandle(config: config, shellCwd: NSTemporaryDirectory())
        )
        let toolset = makeToolset(pipeline: pipeline)
        let provider = StubProvider(serverName: "linear", tools: [
            MCPBridgedTool(name: "search", description: "")
        ])
        await MCPToolBridge.register(provider: provider, into: toolset)

        let outcome = await toolset.prepareAndCall(
            clientName: "linear__search",
            args: .object([:])
        )
        guard case .failure = outcome else {
            Issue.record("expected the deny rule to block the dispatch")
            return
        }
        #expect(provider.calls.all.isEmpty)
    }

    @Test("an allowed call reaches the server with the raw tool name")
    func allowedCallReachesServer() async {
        let toolset = makeToolset(pipeline: allowAllPipeline())
        var provider = StubProvider(serverName: "linear", tools: [
            MCPBridgedTool(name: "search", description: "")
        ])
        provider.result = MCPBridgedCallResult(text: "three results")
        await MCPToolBridge.register(provider: provider, into: toolset)

        let outcome = await toolset.prepareAndCall(
            clientName: "linear__search",
            args: .object(["query": .string("bug")])
        )
        guard case .success(let typed) = outcome else {
            Issue.record("expected success, got \(outcome)")
            return
        }
        #expect(typed.modelOutput == [.text(text: "three results")])

        let call = try? #require(provider.calls.all.first)
        // The server prefix is stripped: servers know their own tools by their
        // raw names.
        #expect(call?.name == "search")
        #expect(call?.arguments == .object(["query": .string("bug")]))
    }

    @Test("non-object arguments are normalized before they reach the server")
    func argumentsAreNormalized() async {
        let toolset = makeToolset(pipeline: allowAllPipeline())
        let provider = StubProvider(serverName: "linear", tools: [
            MCPBridgedTool(name: "search", description: "")
        ])
        await MCPToolBridge.register(provider: provider, into: toolset)

        _ = await toolset.prepareAndCall(clientName: "linear__search", args: .null)
        #expect(provider.calls.all.first?.arguments == .object([:]))
    }
}
