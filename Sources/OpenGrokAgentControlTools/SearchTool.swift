// SearchTool.swift
//
// Open Grok — MCP Meta-Discovery: search_tool, FNV-1a hashing, server fingerprinting,
// description truncation, server reminders, and BM25 tool search index.
//
// Rust provenance (pin `650c1db7`):
//   * crates/codegen/xai-grok-tools/src/implementations/search_tool/mod.rs
//   * crates/codegen/xai-grok-tools/src/implementations/search_tool/types.rs
//   * crates/codegen/xai-grok-shell/src/session/tool_index.rs

import Foundation
import OpenGrokShared
import OpenGrokToolProtocol
import OpenGrokToolRuntime
import OpenGrokToolTypes

// MARK: - Constants

/// Maximum character length for MCP tool/server descriptions.
/// Descriptions exceeding this are truncated with `TRUNCATION_SUFFIX`.
public let MAX_MCP_DESCRIPTION_LENGTH: Int = 2048

/// Truncation suffix appended when a description exceeds `MAX_MCP_DESCRIPTION_LENGTH`.
public let TRUNCATION_SUFFIX: String = "\u{2026} [truncated]"

// MARK: - FNV-1a 64-bit Hash

/// Deterministic, portable 64-bit FNV-1a hash function.
/// Uses offset basis `0xcbf29ce484222325` and prime `0x00000100000001B3`.
/// Stable across architectures, platforms, and runtime restarts.
public func fnv1aHash(_ string: String) -> UInt64 {
    var hash: UInt64 = 0xcbf29ce484222325
    let prime: UInt64 = 0x00000100000001B3
    for byte in string.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* prime
    }
    return hash
}

/// Deterministic FNV-1a hash for an array of strings.
/// Separates elements with a null byte to prevent concatenation collisions.
public func fnv1aHash(_ strings: [String]) -> UInt64 {
    var hash: UInt64 = 0xcbf29ce484222325
    let prime: UInt64 = 0x00000100000001B3
    for str in strings {
        for byte in str.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        hash ^= 0
        hash = hash &* prime
    }
    return hash
}

// MARK: - Description Helpers

/// Truncates a string to `MAX_MCP_DESCRIPTION_LENGTH` characters, appending `TRUNCATION_SUFFIX`
/// if truncated. Operates on Character boundaries to prevent breaking multi-byte or grapheme clusters.
public func truncateDescription(_ s: String) -> String {
    if s.count <= MAX_MCP_DESCRIPTION_LENGTH {
        return s
    }
    let budget = MAX_MCP_DESCRIPTION_LENGTH - TRUNCATION_SUFFIX.count
    return String(s.prefix(budget)) + TRUNCATION_SUFFIX
}

/// Collapses newlines and multiple whitespaces into a single space, trimming surrounding whitespace.
public func sanitizeDescription(_ s: String) -> String {
    s.split(whereSeparator: { $0.isNewline })
        .flatMap { $0.split(whereSeparator: { $0.isWhitespace }).map(String.init) }
        .joined(separator: " ")
}

// MARK: - Server Fingerprints & Summaries

/// Fingerprint for change detection: (toolCount, descriptionHash, toolNamesHash).
public struct ServerFingerprint: Sendable, Codable, Equatable, Hashable {
    public var toolCount: Int
    public var descriptionHash: UInt64
    public var toolNamesHash: UInt64

    public init(toolCount: Int, descriptionHash: UInt64, toolNamesHash: UInt64) {
        self.toolCount = toolCount
        self.descriptionHash = descriptionHash
        self.toolNamesHash = toolNamesHash
    }
}

/// Summary of an MCP server available for tool search and system reminders.
public struct McpServerSummary: Sendable, Codable, Equatable, Hashable {
    public var name: String
    public var description: String?
    public var toolCount: Int
    public var toolNames: [String]

    public init(
        name: String,
        description: String? = nil,
        toolCount: Int? = nil,
        toolNames: [String] = []
    ) {
        self.name = name
        self.description = description
        self.toolCount = toolCount ?? toolNames.count
        self.toolNames = toolNames
    }
}

public typealias MCPServerSummary = McpServerSummary

/// Build fingerprints for a list of MCP server summaries.
public func fingerprintServers(_ summaries: [McpServerSummary]) -> [String: ServerFingerprint] {
    var map: [String: ServerFingerprint] = [:]
    for summary in summaries {
        let desc = summary.description ?? ""
        map[summary.name] = ServerFingerprint(
            toolCount: summary.toolCount,
            descriptionHash: fnv1aHash(desc),
            toolNamesHash: fnv1aHash(summary.toolNames)
        )
    }
    return map
}

private func formatServerLine(_ server: McpServerSummary) -> String {
    let sanitized = server.description
        .map(sanitizeDescription)
        .map(truncateDescription)
    let toolWord = server.toolCount == 1 ? "tool" : "tools"
    if let desc = sanitized, !desc.isEmpty {
        return "- \(server.name) (\(server.toolCount) \(toolWord)): \(desc)\n"
    } else {
        return "- \(server.name) (\(server.toolCount) \(toolWord))\n"
    }
}

/// Build a full system reminder body listing all connected MCP servers.
/// Returns `nil` if `summaries` is empty.
public func buildServerReminder(_ summaries: [McpServerSummary]) -> String? {
    guard !summaries.isEmpty else { return nil }
    var text = "Connected MCP servers:\n"
    for server in summaries {
        text += formatServerLine(server)
    }
    return text
}

/// Build a delta system reminder noting added, updated, or removed MCP servers.
/// Returns `nil` if nothing changed.
public func buildDeltaReminder(
    old: [String: ServerFingerprint],
    newSummaries: [McpServerSummary]
) -> String? {
    let newMap = fingerprintServers(newSummaries)

    let added = newSummaries.filter { old[$0.name] == nil }
    let updated = newSummaries.filter { summary in
        if let oldFp = old[summary.name] {
            return oldFp != newMap[summary.name]
        }
        return false
    }
    let removed = old.keys.filter { newMap[$0] == nil }.sorted()

    if added.isEmpty && updated.isEmpty && removed.isEmpty {
        return nil
    }

    var text = ""

    if !added.isEmpty {
        let s = added.count == 1 ? "" : "s"
        text += "MCP server\(s) connected:\n"
        for server in added {
            text += formatServerLine(server)
        }
    }

    if !updated.isEmpty {
        if !text.isEmpty {
            text += "\n"
        }
        let s = updated.count == 1 ? "" : "s"
        text += "MCP server\(s) updated:\n"
        for server in updated {
            text += formatServerLine(server)
        }
    }

    if !removed.isEmpty {
        if !text.isEmpty {
            text += "\n"
        }
        let s = removed.count == 1 ? "" : "s"
        text += "MCP server\(s) disconnected: \(removed.joined(separator: ", "))"
    }

    return text
}

// MARK: - BM25 Scoring & Search Engine

/// Discovered tool item for tool indexing and search.
public struct McpDiscoveredTool: Sendable, Codable, Equatable, Hashable {
    public var toolName: String
    public var serverName: String
    public var description: String
    public var parameters: [String]
    public var inputSchema: JSONValue
    public var score: Float

    public init(
        toolName: String,
        serverName: String,
        description: String,
        parameters: [String] = [],
        inputSchema: JSONValue = .object(["type": .string("object")]),
        score: Float = 0.0
    ) {
        self.toolName = toolName
        self.serverName = serverName
        self.description = description
        self.parameters = parameters
        self.inputSchema = inputSchema
        self.score = score
    }

    public init(_ hit: ToolSearchHit) {
        self.init(
            toolName: hit.toolName,
            serverName: hit.serverName,
            description: hit.description,
            parameters: hit.parameters,
            inputSchema: hit.inputSchema,
            score: hit.score
        )
    }

    public var asHit: ToolSearchHit {
        ToolSearchHit(
            toolName: toolName,
            serverName: serverName,
            description: description,
            score: score,
            parameters: parameters,
            inputSchema: inputSchema
        )
    }
}

/// BM25 keyword search engine for MCP tools.
public enum BM25ToolSearchEngine {
    /// Split compound identifiers (snake_case, kebab-case, camelCase, PascalCase, and '__').
    public static func splitIdentifier(_ s: String) -> [String] {
        var words: [String] = []
        let parts = s.components(separatedBy: "__")
            .flatMap { $0.split(separator: "_") }
            .flatMap { $0.split(separator: "-") }

        for part in parts {
            if part.isEmpty { continue }
            let chars = Array(part)
            var start = 0
            for i in 1..<chars.count {
                if chars[i - 1].isLowercase && chars[i].isUppercase {
                    words.append(String(chars[start..<i]))
                    start = i
                }
            }
            words.append(String(chars[start...]))
        }
        return words
    }

    /// Tokenize text into lowercased terms and sub-identifier terms.
    public static func tokenize(_ text: String) -> [String] {
        let normalized = text.lowercased()
        var tokens: [String] = []
        let rawWords = normalized.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" && $0 != "-" })
        for word in rawWords {
            let str = String(word)
            tokens.append(str)
            let splits = splitIdentifier(str).map { $0.lowercased() }
            if splits.count > 1 || (splits.count == 1 && splits[0] != str) {
                tokens.append(contentsOf: splits)
            }
        }
        return tokens.filter { !$0.isEmpty }
    }

    /// Search tools using BM25 relevance scoring.
    public static func search(
        query: String,
        tools: [McpDiscoveredTool],
        limit: Int = 5,
        k1: Double = 1.2,
        b: Double = 0.75
    ) -> [McpDiscoveredTool] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tools.isEmpty, !trimmed.isEmpty else {
            return []
        }

        let lowerTrimmed = trimmed.lowercased()

        // Fast path: exact match on qualified name or unqualified tool name
        if let exactIdx = tools.firstIndex(where: {
            let toolLower = $0.toolName.lowercased()
            return toolLower == lowerTrimmed
                || toolLower.components(separatedBy: "__").last == lowerTrimmed
        }) {
            var exact = tools[exactIdx]
            exact.score = 10.0
            var results = [exact]
            if limit > 1 {
                var remaining = tools
                remaining.remove(at: exactIdx)
                let others = searchBM25Core(query: trimmed, tools: remaining, limit: limit - 1, k1: k1, b: b)
                results.append(contentsOf: others)
            }
            return Array(results.prefix(limit))
        }

        return searchBM25Core(query: trimmed, tools: tools, limit: limit, k1: k1, b: b)
    }

    private static func searchBM25Core(
        query: String,
        tools: [McpDiscoveredTool],
        limit: Int,
        k1: Double,
        b: Double
    ) -> [McpDiscoveredTool] {
        let queryTokens = tokenize(query)
        guard !queryTokens.isEmpty else { return [] }

        var docTokens: [[String]] = []
        docTokens.reserveCapacity(tools.count)
        var docLengths: [Double] = []
        docLengths.reserveCapacity(tools.count)
        var totalLength: Double = 0

        for tool in tools {
            var docText = "\(tool.serverName) \(tool.toolName) \(tool.description)"
            if !tool.parameters.isEmpty {
                docText += " \(tool.parameters.joined(separator: " "))"
            }
            let tokens = tokenize(docText)
            docTokens.append(tokens)
            let len = Double(tokens.count)
            docLengths.append(len)
            totalLength += len
        }

        let numDocs = Double(tools.count)
        let avgDocLength = max(1.0, totalLength / numDocs)

        // Document frequency per query term
        var docFrequencies: [String: Double] = [:]
        for q in Set(queryTokens) {
            var count = 0
            for tokens in docTokens {
                if tokens.contains(q) {
                    count += 1
                }
            }
            if count > 0 {
                docFrequencies[q] = Double(count)
            }
        }

        var scored: [(tool: McpDiscoveredTool, score: Double)] = []

        for (i, tool) in tools.enumerated() {
            let tokens = docTokens[i]
            let docLen = docLengths[i]
            let docLenNorm = 1.0 - b + b * (docLen / avgDocLength)

            var tfDict: [String: Double] = [:]
            for token in tokens {
                tfDict[token, default: 0] += 1
            }

            var score: Double = 0.0
            for q in queryTokens {
                guard let df = docFrequencies[q] else { continue }
                let tf = tfDict[q] ?? 0
                guard tf > 0 else { continue }

                let idf = log(1.0 + (numDocs - df + 0.5) / (df + 0.5))
                let numerator = tf * (k1 + 1.0)
                let denominator = tf + k1 * docLenNorm
                score += idf * (numerator / denominator)
            }

            if score > 0 {
                var copy = tool
                copy.score = Float(score)
                scored.append((copy, score))
            }
        }

        scored.sort { $0.score > $1.score }
        return Array(scored.prefix(limit).map(\.tool))
    }
}

// MARK: - SearchTool Types & Surface

/// Input arguments for `search_tool`.
public struct SearchToolInput: Sendable, Codable, Equatable {
    public var query: String
    public var limit: Int?

    public init(query: String, limit: Int? = 5) {
        self.query = query
        self.limit = limit
    }

    public static func parse(_ value: JSONValue) throws -> SearchToolInput {
        guard case .object(let dict) = value else {
            throw ToolError.invalidArguments("expected object input for search_tool")
        }
        guard let queryVal = dict["query"] else {
            throw ToolError.invalidArguments("missing required parameter 'query'")
        }
        let queryString: String
        switch queryVal {
        case .string(let s): queryString = s
        default: queryString = "\(queryVal)"
        }

        var limitVal: Int? = 5
        if let lim = dict["limit"] {
            if let i = lim.int64Value {
                limitVal = Int(i)
            } else if let d = lim.doubleValue {
                limitVal = Int(d)
            } else if let s = lim.stringValue {
                limitVal = Int(s)
            }
        }
        return SearchToolInput(query: queryString, limit: limitVal)
    }
}

/// Server group result returned by `search_tool`.
public struct SearchToolServerGroup: Sendable, Codable, Equatable {
    public var server: String
    public var tools: [SearchToolEntry]

    public init(server: String, tools: [SearchToolEntry]) {
        self.server = server
        self.tools = tools
    }
}

/// Tool entry in search results containing description and schema.
public struct SearchToolEntry: Sendable, Codable, Equatable {
    public var toolName: String
    public var description: String
    public var score: Float
    public var inputSchema: JSONValue

    public init(
        toolName: String,
        description: String,
        score: Float,
        inputSchema: JSONValue
    ) {
        self.toolName = toolName
        self.description = description
        self.score = score
        self.inputSchema = inputSchema
    }
}

/// Response payload from `search_tool`.
public struct SearchToolOutputPayload: Sendable, Codable, Equatable {
    public var results: [SearchToolServerGroup]
    public var totalHiddenTools: Int
    public var status: String
    public var note: String?

    public init(
        results: [SearchToolServerGroup],
        totalHiddenTools: Int,
        status: String = "ready",
        note: String? = nil
    ) {
        self.results = results
        self.totalHiddenTools = totalHiddenTools
        self.status = status
        self.note = note
    }

    public var asJSONValue: JSONValue {
        var obj: [String: JSONValue] = [
            "status": .string(status),
            "total_hidden_tools": .number(.int64(Int64(totalHiddenTools))),
            "results": .array(results.map { group in
                .object([
                    "server": .string(group.server),
                    "tools": .array(group.tools.map { tool in
                        .object([
                            "tool_name": .string(tool.toolName),
                            "description": .string(tool.description),
                            "score": .number(.double(Double(tool.score))),
                            "input_schema": tool.inputSchema,
                        ])
                    }),
                ])
            }),
        ]
        if let note = note {
            obj["note"] = .string(note)
        }
        return .object(obj)
    }

    public var asJSONString: String {
        guard let data = try? JSONEncoder().encode(self),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }
}

/// Tool implementation for MCP meta-discovery `search_tool`.
public struct SearchTool: Sendable {
    public static let clientName = "search_tool"
    public static let namespace = "GrokBuild"

    public static let descriptionTemplate = """
    Search for MCP tools by keyword and retrieve their input schemas.

    If status is "partial", some servers may still be connecting.
    """

    public static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "query": .object([
                "type": .string("string"),
                "description": .string("Keywords to match against tool names, server names, and descriptions. Include the server name and action for best results (e.g. \"linear create issue\", \"slack read thread history\").")
            ]),
            "limit": .object([
                "type": .string("integer"),
                "description": .string("Maximum number of results to return (default 5).")
            ])
        ]),
        "required": .array([.string("query")])
    ])

    public init() {}

    /// Execute a search query over tools using BM25 ranking and group results by server.
    public func execute(
        input: SearchToolInput,
        tools: [McpDiscoveredTool],
        isReady: Bool = true
    ) -> SearchToolOutputPayload {
        let limit = max(1, input.limit ?? 5)
        let ranked = BM25ToolSearchEngine.search(query: input.query, tools: tools, limit: limit)

        // Group results by server, preserving BM25 score order within groups
        // Groups are sorted by highest score (best-matching server first)
        var groups: [String: (bestScore: Float, tools: [SearchToolEntry])] = [:]
        var serverOrder: [String] = []

        for r in ranked {
            let entry = SearchToolEntry(
                toolName: r.toolName,
                description: truncateDescription(r.description),
                score: r.score,
                inputSchema: r.inputSchema
            )
            if var existing = groups[r.serverName] {
                existing.tools.append(entry)
                groups[r.serverName] = existing
            } else {
                groups[r.serverName] = (bestScore: r.score, tools: [entry])
                serverOrder.append(r.serverName)
            }
        }

        serverOrder.sort {
            (groups[$0]?.bestScore ?? 0) > (groups[$1]?.bestScore ?? 0)
        }

        let resultGroups = serverOrder.compactMap { server -> SearchToolServerGroup? in
            guard let g = groups[server] else { return nil }
            return SearchToolServerGroup(server: server, tools: g.tools)
        }

        let status = isReady ? "ready" : "partial"
        let note: String?
        if !isReady {
            note = "Some MCP servers are still connecting. Results may be incomplete."
        } else if tools.isEmpty && resultGroups.isEmpty {
            note = "No MCP tools are available in this session. Connect MCP servers here, or if this is a subagent, check the agent's mcpInheritance."
        } else {
            note = nil
        }

        return SearchToolOutputPayload(
            results: resultGroups,
            totalHiddenTools: tools.count,
            status: status,
            note: note
        )
    }

    /// Execute search against a `ToolSearchIndex` backend.
    public func execute(
        input: SearchToolInput,
        index: (any ToolSearchIndex)?
    ) -> SearchToolOutputPayload {
        guard let index = index else {
            return SearchToolOutputPayload(
                results: [],
                totalHiddenTools: 0,
                status: "ready",
                note: "No MCP tools are available in this session. Connect MCP servers here, or if this is a subagent, check the agent's mcpInheritance."
            )
        }

        let limit = max(1, input.limit ?? 5)
        let snapshot = index.searchSnapshot(query: input.query, limit: limit)
        let tools = snapshot.results.map { McpDiscoveredTool($0) }

        var groups: [String: (bestScore: Float, tools: [SearchToolEntry])] = [:]
        var serverOrder: [String] = []

        for r in tools {
            let entry = SearchToolEntry(
                toolName: r.toolName,
                description: truncateDescription(r.description),
                score: r.score,
                inputSchema: r.inputSchema
            )
            if var existing = groups[r.serverName] {
                existing.tools.append(entry)
                groups[r.serverName] = existing
            } else {
                groups[r.serverName] = (bestScore: r.score, tools: [entry])
                serverOrder.append(r.serverName)
            }
        }

        serverOrder.sort {
            (groups[$0]?.bestScore ?? 0) > (groups[$1]?.bestScore ?? 0)
        }

        let resultGroups = serverOrder.compactMap { server -> SearchToolServerGroup? in
            guard let g = groups[server] else { return nil }
            return SearchToolServerGroup(server: server, tools: g.tools)
        }

        let status = snapshot.isReady ? "ready" : "partial"
        let note: String?
        if !snapshot.isReady {
            note = "Some MCP servers are still connecting. Results may be incomplete."
        } else if snapshot.totalHiddenTools == 0 && resultGroups.isEmpty {
            note = "No MCP tools are available in this session. Connect MCP servers here, or if this is a subagent, check the agent's mcpInheritance."
        } else {
            note = nil
        }

        return SearchToolOutputPayload(
            results: resultGroups,
            totalHiddenTools: snapshot.totalHiddenTools,
            status: status,
            note: note
        )
    }
}
