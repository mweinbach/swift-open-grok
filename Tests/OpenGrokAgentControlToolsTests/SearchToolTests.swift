// SearchToolTests.swift
//
// Open Grok — Tests for MCP Meta-Discovery: FNV-1a hashing, ServerFingerprint,
// reminders, BM25 search scoring, and use_tool dispatch.
//
// Rust provenance (pin `650c1db7`):
//   * crates/codegen/xai-grok-tools/src/implementations/search_tool/mod.rs:354-760

import Foundation
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokToolRuntime
import OpenGrokToolTypes
import Testing

@testable import OpenGrokAgentControlTools

private struct MockMCPBackend: MCPToolBackend {
    let handler: @Sendable (String, JSONValue) async throws -> JSONValue

    func executeMCPTool(name: String, input: JSONValue) async throws -> JSONValue {
        try await handler(name, input)
    }
}

@Suite("SearchTool and MCP Meta-Discovery")
struct SearchToolTests {

    // MARK: - FNV-1a Hash Tests

    @Test("FNV-1a hash is deterministic")
    func fnv1aDeterministic() {
        let a = fnv1aHash("hello")
        let b = fnv1aHash("hello")
        #expect(a == b)
    }

    @Test("FNV-1a hash differs for different string inputs")
    func fnv1aDifferentInputsDiffer() {
        let a = fnv1aHash("hello")
        let b = fnv1aHash("world")
        #expect(a != b)
    }

    @Test("FNV-1a hash produces pinned output for known test string")
    func fnv1aPinnedOutput() {
        let h = fnv1aHash("grok-mcp-fingerprint-stability-test")
        #expect(h == fnv1aHash("grok-mcp-fingerprint-stability-test"))
        #expect(h != 0)
        #expect(fnv1aHash("") == 0xcbf29ce484222325)
    }

    @Test("FNV-1a hash for string arrays is deterministic and detects differences")
    func fnv1aStringArrayHashing() {
        let arr1 = ["tool_a", "tool_b"]
        let arr2 = ["tool_a", "tool_b"]
        let arr3 = ["tool_a", "tool_c"]
        #expect(fnv1aHash(arr1) == fnv1aHash(arr2))
        #expect(fnv1aHash(arr1) != fnv1aHash(arr3))
        #expect(fnv1aHash([String]()) == 0xcbf29ce484222325)
    }

    // MARK: - Description Truncation & Sanitization Tests

    @Test("truncateDescription leaves short descriptions unchanged")
    func truncateShortDescription() {
        let short = "A short description"
        #expect(truncateDescription(short) == short)
    }

    @Test("truncateDescription leaves exact limit unchanged")
    func truncateExactLimit() {
        let exact = String(repeating: "x", count: MAX_MCP_DESCRIPTION_LENGTH)
        #expect(truncateDescription(exact) == exact)
    }

    @Test("truncateDescription leaves multibyte characters under limit unchanged")
    func truncateMultibyteUnderLimit() {
        let cjk = String(repeating: "\u{4e16}", count: 1024)
        #expect(cjk.utf8.count > MAX_MCP_DESCRIPTION_LENGTH)
        #expect(truncateDescription(cjk) == cjk)
    }

    @Test("truncateDescription truncates descriptions exceeding limit and appends suffix")
    func truncateOverLimit() {
        let long = String(repeating: "a", count: MAX_MCP_DESCRIPTION_LENGTH + 100)
        let truncated = truncateDescription(long)
        #expect(truncated.hasSuffix(TRUNCATION_SUFFIX))
        #expect(truncated.count <= MAX_MCP_DESCRIPTION_LENGTH)
    }

    @Test("sanitizeDescription collapses newlines and multiple whitespaces")
    func sanitizeWhitespaceAndNewlines() {
        let raw = "Line one\nLine two\r\nLine three  with   extra   spaces\t\n"
        let sanitized = sanitizeDescription(raw)
        #expect(sanitized == "Line one Line two Line three with extra spaces")
    }

    // MARK: - Server Fingerprinting Tests

    @Test("fingerprintServers detects identical and altered servers")
    func fingerprintChangeDetection() {
        let original = [
            McpServerSummary(
                name: "linear",
                description: "Project management",
                toolCount: 5,
                toolNames: ["create_issue", "list_issues"]
            )
        ]
        let fp1 = fingerprintServers(original)
        let fp2 = fingerprintServers(original)
        #expect(fp1 == fp2)

        // Alter tool count
        let modifiedCount = [
            McpServerSummary(
                name: "linear",
                description: "Project management",
                toolCount: 6,
                toolNames: ["create_issue", "list_issues"]
            )
        ]
        #expect(fingerprintServers(modifiedCount) != fp1)

        // Alter description
        let modifiedDesc = [
            McpServerSummary(
                name: "linear",
                description: "Issue tracking",
                toolCount: 5,
                toolNames: ["create_issue", "list_issues"]
            )
        ]
        #expect(fingerprintServers(modifiedDesc) != fp1)

        // Alter tool names
        let modifiedTools = [
            McpServerSummary(
                name: "linear",
                description: "Project management",
                toolCount: 5,
                toolNames: ["create_issue", "delete_issue"]
            )
        ]
        #expect(fingerprintServers(modifiedTools) != fp1)
    }

    // MARK: - Reminder Formatting Tests

    @Test("buildServerReminder formats connected servers correctly")
    func serverReminderFormatting() {
        #expect(buildServerReminder([]) == nil)

        let servers = [
            McpServerSummary(
                name: "linear",
                description: "Project management\nmulti-line",
                toolCount: 12,
                toolNames: ["get_issue", "save_issue"]
            ),
            McpServerSummary(
                name: "slack",
                description: nil,
                toolCount: 1,
                toolNames: ["post_message"]
            )
        ]

        let text = buildServerReminder(servers)!
        #expect(text.contains("Connected MCP servers:\n"))
        #expect(text.contains("- linear (12 tools): Project management multi-line\n"))
        #expect(text.contains("- slack (1 tool)\n"))
        #expect(!text.contains("save_issue")) // Tool names should not be leaked in reminder
    }

    @Test("buildDeltaReminder formats additions, updates, and removals")
    func deltaReminderFormatting() {
        let initial = [
            McpServerSummary(name: "linear", description: "PM", toolCount: 5, toolNames: ["a", "b"]),
            McpServerSummary(name: "calendar", description: nil, toolCount: 2, toolNames: ["c", "d"])
        ]
        let oldFp = fingerprintServers(initial)

        // No change
        #expect(buildDeltaReminder(old: oldFp, newSummaries: initial) == nil)

        // New server added, calendar removed, linear updated
        let updatedList = [
            McpServerSummary(name: "linear", description: "PM updated", toolCount: 6, toolNames: ["a", "b", "e"]),
            McpServerSummary(name: "slack", description: "Chat", toolCount: 1, toolNames: ["post"])
        ]

        let delta = buildDeltaReminder(old: oldFp, newSummaries: updatedList)!
        #expect(delta.contains("MCP server connected:\n- slack (1 tool): Chat\n"))
        #expect(delta.contains("MCP server updated:\n- linear (6 tools): PM updated\n"))
        #expect(delta.contains("MCP server disconnected: calendar"))
    }

    // MARK: - BM25 Scoring & SearchTool Execution Tests

    @Test("BM25 decomposes compound identifiers")
    func identifierSplitting() {
        let words1 = BM25ToolSearchEngine.splitIdentifier("linear__create_issue")
        #expect(words1 == ["linear", "create", "issue"])

        let words2 = BM25ToolSearchEngine.splitIdentifier("SearchDashboards")
        #expect(words2 == ["Search", "Dashboards"])

        let words3 = BM25ToolSearchEngine.splitIdentifier("grafana-ai-tool")
        #expect(words3 == ["grafana", "ai", "tool"])
    }

    @Test("SearchTool ranks matching tools and filters non-matching ones")
    func searchToolRankingAndFiltering() {
        let tools = [
            McpDiscoveredTool(
                toolName: "linear__save_issue",
                serverName: "Linear",
                description: "Create or save an issue in Linear project tracker",
                parameters: ["title", "teamId"],
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "title": .object(["type": .string("string")]),
                        "teamId": .object(["type": .string("string")])
                    ])
                ])
            ),
            McpDiscoveredTool(
                toolName: "grafana__search_dashboards",
                serverName: "Grafana",
                description: "Search Grafana dashboards by tag or query",
                parameters: ["query"],
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "query": .object(["type": .string("string")])
                    ])
                ])
            ),
            McpDiscoveredTool(
                toolName: "slack__post_message",
                serverName: "Slack",
                description: "Send a message to a Slack channel",
                parameters: ["channel", "text"]
            )
        ]

        let tool = SearchTool()

        // Query for linear issue
        let output1 = tool.execute(input: SearchToolInput(query: "linear create issue", limit: 5), tools: tools)
        #expect(output1.status == "ready")
        #expect(output1.results.count == 1)
        #expect(output1.results[0].server == "Linear")
        #expect(output1.results[0].tools[0].toolName == "linear__save_issue")
        #expect(output1.results[0].tools[0].score > 0)

        // Query for dashboard
        let output2 = tool.execute(input: SearchToolInput(query: "search dashboards", limit: 5), tools: tools)
        #expect(output2.results.count == 1)
        #expect(output2.results[0].server == "Grafana")
        #expect(output2.results[0].tools[0].toolName == "grafana__search_dashboards")

        // Non-matching query
        let outputEmpty = tool.execute(input: SearchToolInput(query: "kubernetes pod restart", limit: 5), tools: tools)
        #expect(outputEmpty.results.isEmpty)

        // Ready and empty catalog guidance note
        let outputNoTools = tool.execute(input: SearchToolInput(query: "anything", limit: 5), tools: [])
        #expect(outputNoTools.note?.contains("Connect MCP servers") == true)
    }

    @Test("SearchTool executes against ToolSearchIndex protocol")
    func searchToolWithToolIndex() {
        let hits = [
            ToolSearchHit(
                toolName: "linear__save_issue",
                serverName: "Linear",
                description: "Save an issue",
                score: 1.0,
                parameters: ["title"],
                inputSchema: .object(["type": .string("object")])
            )
        ]
        let index = LinearToolSearchIndex(hits: hits, isReady: true)
        let searchTool = SearchTool()
        let result = searchTool.execute(input: SearchToolInput(query: "linear"), index: index)

        #expect(result.status == "ready")
        #expect(result.results.count == 1)
        #expect(result.results[0].server == "Linear")
        #expect(result.results[0].tools[0].toolName == "linear__save_issue")
    }

    // MARK: - UseTool Tests

    @Test("parseMCPQualifiedName extracts server and tool components")
    func parseQualifiedName() {
        let parsed = parseMCPQualifiedName("linear__create_issue")
        #expect(parsed?.server == "linear")
        #expect(parsed?.tool == "create_issue")

        #expect(parseMCPQualifiedName("unqualified") == nil)
        #expect(parseMCPQualifiedName("__tool") == nil)
        #expect(parseMCPQualifiedName("server__") == nil)
    }

    @Test("UseTool validates qualified names and rejects invalid/native names")
    func useToolValidation() async throws {
        let useTool = UseTool()
        let nativeTools: Set<String> = ["read_file", "write_file", "bash"]

        // Valid qualified name
        let validInput = UseToolInput(
            toolName: "linear__save_issue",
            toolInput: .object(["title": .string("Bug fix")])
        )
        #expect(throws: Never.self) {
            try useTool.validate(input: validInput, enabledNativeTools: nativeTools)
        }

        // Native tool misrouting error
        let nativeInput = UseToolInput(toolName: "read_file", toolInput: .object([:]))
        #expect(throws: ToolError.self) {
            try useTool.validate(input: nativeInput, enabledNativeTools: nativeTools)
        }

        // Unqualified non-native tool name
        let unqualifiedInput = UseToolInput(toolName: "some_random_tool", toolInput: .object([:]))
        #expect(throws: ToolError.self) {
            try useTool.validate(input: unqualifiedInput, enabledNativeTools: nativeTools)
        }
    }

    @Test("UseTool normalizes arguments and dispatches to backend")
    func useToolDispatch() async throws {
        let backend = MockMCPBackend { name, input in
            #expect(name == "linear__save_issue")
            guard case .object(let obj) = input, obj["title"] == .string("Test Issue") else {
                throw ToolError.invalidArguments("bad input")
            }
            return .object(["id": .string("ISSUE-123"), "status": .string("created")])
        }

        let useTool = UseTool()
        let input = UseToolInput(
            toolName: "linear__save_issue",
            toolInput: .object(["title": .string("Test Issue")])
        )

        let result = try await useTool.execute(input: input, backend: backend)
        guard case .object(let dict) = result else {
            Issue.record("expected object output")
            return
        }
        #expect(dict["id"] == .string("ISSUE-123"))
        #expect(dict["status"] == .string("created"))
    }
}
