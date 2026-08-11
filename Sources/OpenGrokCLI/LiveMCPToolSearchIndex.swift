// LiveMCPToolSearchIndex.swift
//
// Production `ToolSearchIndexing` backed by the live `FinalizedToolset`'s
// MCP tools. `search_tool` reads this through `ToolSearchIndexResource`;
// reconnect / toggle / auth sites call `refresh(from:)` so discovery tracks
// the running toolset rather than a stale connect-time snapshot.
//
// Scoring is a lightweight keyword match (name weighted above description).
// Upstream uses BM25 (`search_tool/mod.rs`); this keeps the live seam honest
// without a separate index crate. Ranking quality can tighten later without
// changing the protocol.

import Foundation
import OpenGrokToolRegistry

/// Live MCP tool search index for `search_tool`.
public final class LiveMCPToolSearchIndex: ToolSearchIndexing, @unchecked Sendable {
    private let lock = NSLock()
    private var catalog: [ToolSearchResult] = []
    private var servers: [MCPServerSummary] = []
    private var ready = true

    public init() {}

    /// Replace the catalog from every MCP tool currently registered on
    /// `toolset`. Safe to call after connect, auth recovery, or tool toggle.
    public func refresh(from toolset: FinalizedToolset) {
        var results: [ToolSearchResult] = []
        var byServer: [String: (description: String?, names: [String])] = [:]

        for name in toolset.clientNames {
            guard let tool = toolset.tool(named: name), tool.namespace == .mcp else {
                continue
            }
            guard let parsed = parseMCPQualifiedToolName(name) else { continue }
            results.append(
                ToolSearchResult(
                    toolName: name,
                    serverName: parsed.server,
                    description: sanitizeMCPDescription(tool.description),
                    inputSchema: tool.inputSchema,
                    score: 0
                )
            )
            var entry = byServer[parsed.server] ?? (nil, [])
            entry.names.append(parsed.tool)
            byServer[parsed.server] = entry
        }

        let summaries = byServer.keys.sorted().map { server in
            let entry = byServer[server]!
            return MCPServerSummary(
                name: server,
                description: entry.description,
                toolCount: entry.names.count,
                toolNames: entry.names.sorted()
            )
        }

        lock.lock()
        catalog = results
        servers = summaries
        ready = true
        lock.unlock()
    }

    /// Refresh when the live composition installed this concrete index.
    public static func refreshIfPresent(in toolset: FinalizedToolset) {
        guard let resource = toolset.resources.extras.get(ToolSearchIndexResource.self),
              let live = resource.index as? LiveMCPToolSearchIndex
        else { return }
        live.refresh(from: toolset)
    }

    public func searchSnapshot(query: String, limit: Int) -> ToolSearchSnapshot {
        lock.lock()
        let catalog = self.catalog
        let ready = self.ready
        lock.unlock()

        let capped = max(1, limit)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let results: [ToolSearchResult]
        if trimmed.isEmpty {
            results = Array(catalog.prefix(capped))
        } else {
            let tokens = trimmed.lowercased()
                .split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
                .map(String.init)
                .filter { !$0.isEmpty }
            results = Array(
                catalog
                    .map { entry -> ToolSearchResult in
                        var copy = entry
                        copy.score = score(entry: entry, tokens: tokens)
                        return copy
                    }
                    .filter { $0.score > 0 }
                    .sorted { $0.score > $1.score }
                    .prefix(capped)
            )
        }

        return ToolSearchSnapshot(
            results: results,
            totalHiddenTools: 0,
            isReady: ready
        )
    }

    public func listServerSummaries() -> [MCPServerSummary] {
        lock.lock(); defer { lock.unlock() }
        return servers
    }

    private func score(entry: ToolSearchResult, tokens: [String]) -> Float {
        let name = entry.toolName.lowercased()
        let description = entry.description.lowercased()
        var total: Float = 0
        for token in tokens {
            if name.contains(token) { total += 2 }
            if description.contains(token) { total += 1 }
        }
        return total
    }
}
