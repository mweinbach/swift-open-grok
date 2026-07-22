// Search.swift
//
// Open Grok — Swift port of `xai-tool-runtime/src/search.rs`.

import Foundation
import OpenGrokShared

/// A single tool search hit.
public struct ToolSearchHit: Sendable, Hashable {
    public var toolName: String
    public var serverName: String
    public var description: String
    public var score: Float
    public var parameters: [String]
    public var inputSchema: JSONValue

    public init(
        toolName: String,
        serverName: String,
        description: String,
        score: Float,
        parameters: [String],
        inputSchema: JSONValue
    ) {
        self.toolName = toolName
        self.serverName = serverName
        self.description = description
        self.score = score
        self.parameters = parameters
        self.inputSchema = inputSchema
    }
}

/// Snapshot of a search query — results plus index metadata.
public struct SearchSnapshot: Sendable, Hashable {
    public var results: [ToolSearchHit]
    public var totalHiddenTools: Int
    public var isReady: Bool

    public init(results: [ToolSearchHit], totalHiddenTools: Int, isReady: Bool) {
        self.results = results
        self.totalHiddenTools = totalHiddenTools
        self.isReady = isReady
    }
}

/// Summary of an MCP server (or other tool source) available for search.
public struct ServerSummary: Sendable, Hashable {
    public var name: String
    public var description: String?
    public var toolNames: [String]

    public init(name: String, description: String? = nil, toolNames: [String]) {
        self.name = name
        self.description = description
        self.toolNames = toolNames
    }

    public var toolCount: Int { toolNames.count }
}

/// Backend-agnostic search interface.
public protocol ToolSearchIndex: Sendable {
    func searchSnapshot(query: String, limit: Int) -> SearchSnapshot
    func listServerSummaries() -> [ServerSummary]
}

/// Resource wrapper for storing a `ToolSearchIndex` behind a shared handle.
public struct ToolIndex: Sendable {
    public let index: any ToolSearchIndex
    public init(_ index: any ToolSearchIndex) { self.index = index }
}

/// Simple in-memory linear search index for tests and lightweight hosts.
public struct LinearToolSearchIndex: ToolSearchIndex {
    public var hits: [ToolSearchHit]
    public var isReady: Bool

    public init(hits: [ToolSearchHit] = [], isReady: Bool = true) {
        self.hits = hits
        self.isReady = isReady
    }

    public func searchSnapshot(query: String, limit: Int) -> SearchSnapshot {
        let q = query.lowercased()
        let matched = hits.filter { hit in
            q.isEmpty
                || hit.toolName.lowercased().contains(q)
                || hit.description.lowercased().contains(q)
                || hit.serverName.lowercased().contains(q)
        }
        .sorted { $0.score > $1.score }
        let limited = Array(matched.prefix(max(0, limit)))
        return SearchSnapshot(
            results: limited,
            totalHiddenTools: max(0, hits.count - limited.count),
            isReady: isReady
        )
    }

    public func listServerSummaries() -> [ServerSummary] {
        var byServer: [String: [String]] = [:]
        for hit in hits {
            byServer[hit.serverName, default: []].append(hit.toolName)
        }
        return byServer.keys.sorted().map { name in
            ServerSummary(
                name: name,
                toolNames: (byServer[name] ?? []).sorted()
            )
        }
    }
}
