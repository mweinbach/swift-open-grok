// RpcSearch.swift
//
// Search methods (`workspace.ripgrep`, `workspace.fuzzy_*`). Ported from
// `crates/codegen/xai-grok-workspace-types/src/rpc/search.rs`.
//
// Note: `ContentSearchMatch` is the RPC content-search hit shape and is
// distinct from the stream-side `ContentMatch` in `WorkspaceTypes.swift`
// (which carries `path`/`line_number`/`spans` for `OpsChunk.ripgrepHit`).

import Foundation
import OpenGrokShared

// MARK: - Content search

/// `workspace.ripgrep` request (camelCase wire format).
public struct ContentSearchRequest: Hashable, Sendable, Codable, Equatable, WorkspaceRpc {
    public var pattern: String
    public var caseInsensitive: Bool
    public var wholeWord: Bool
    public var isRegex: Bool
    public var includeGlobs: [String]
    public var excludeGlobs: [String]
    public var maxFiles: UInt64?
    public var maxMatches: UInt64?
    public var respectGitignore: Bool
    public var cwd: String?
    public var contextId: String?

    public init(
        pattern: String,
        caseInsensitive: Bool = false,
        wholeWord: Bool = false,
        isRegex: Bool = false,
        includeGlobs: [String] = [],
        excludeGlobs: [String] = [],
        maxFiles: UInt64? = nil,
        maxMatches: UInt64? = nil,
        respectGitignore: Bool = true,
        cwd: String? = nil,
        contextId: String? = nil
    ) {
        self.pattern = pattern
        self.caseInsensitive = caseInsensitive
        self.wholeWord = wholeWord
        self.isRegex = isRegex
        self.includeGlobs = includeGlobs
        self.excludeGlobs = excludeGlobs
        self.maxFiles = maxFiles
        self.maxMatches = maxMatches
        self.respectGitignore = respectGitignore
        self.cwd = cwd
        self.contextId = contextId
    }

    public static let method: String = "workspace.ripgrep"
    public typealias Response = ContentSearchData

    enum CodingKeys: String, CodingKey {
        case pattern
        case caseInsensitive
        case wholeWord
        case isRegex
        case includeGlobs
        case excludeGlobs
        case maxFiles
        case maxMatches
        case respectGitignore
        case cwd
        case contextId
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pattern = try c.decode(String.self, forKey: .pattern)
        caseInsensitive = try c.decodeIfPresent(Bool.self, forKey: .caseInsensitive) ?? false
        wholeWord = try c.decodeIfPresent(Bool.self, forKey: .wholeWord) ?? false
        isRegex = try c.decodeIfPresent(Bool.self, forKey: .isRegex) ?? false
        includeGlobs = try c.decodeIfPresent([String].self, forKey: .includeGlobs) ?? []
        excludeGlobs = try c.decodeIfPresent([String].self, forKey: .excludeGlobs) ?? []
        maxFiles = try c.decodeIfPresent(UInt64.self, forKey: .maxFiles)
        maxMatches = try c.decodeIfPresent(UInt64.self, forKey: .maxMatches)
        respectGitignore = try c.decodeIfPresent(Bool.self, forKey: .respectGitignore) ?? true
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        contextId = try c.decodeIfPresent(String.self, forKey: .contextId)
    }
}

/// One match line inside a content-search hit file.
public struct ContentSearchMatch: Hashable, Sendable, Codable, Equatable {
    public var line: UInt64
    public var content: String
    public var matchStart: UInt64?
    public var matchEnd: UInt64?

    public init(line: UInt64, content: String, matchStart: UInt64? = nil, matchEnd: UInt64? = nil) {
        self.line = line
        self.content = content
        self.matchStart = matchStart
        self.matchEnd = matchEnd
    }

    enum CodingKeys: String, CodingKey {
        case line, content, matchStart, matchEnd
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(line, forKey: .line)
        try c.encode(content, forKey: .content)
        try c.encodeIfPresent(matchStart, forKey: .matchStart)
        try c.encodeIfPresent(matchEnd, forKey: .matchEnd)
    }
}

/// One file with matches in a content-search response.
public struct ContentSearchMatchFile: Hashable, Sendable, Codable, Equatable {
    public var name: String
    public var path: String
    public var matches: [ContentSearchMatch]

    public init(name: String, path: String, matches: [ContentSearchMatch] = []) {
        self.name = name
        self.path = path
        self.matches = matches
    }

    /// Derive `name` from the final path component (matches Rust
    /// `ContentMatchFile::new`).
    public static func fromPath(_ path: String) -> ContentSearchMatchFile {
        let name = (path as NSString).lastPathComponent
        return ContentSearchMatchFile(name: name.isEmpty ? path : name, path: path)
    }
}

public struct ContentSearchData: Hashable, Sendable, Codable, Equatable {
    public var files: [ContentSearchMatchFile]
    public var totalMatches: UInt64
    public var totalFiles: UInt64
    public var truncated: Bool

    public init(
        files: [ContentSearchMatchFile] = [],
        totalMatches: UInt64 = 0,
        totalFiles: UInt64 = 0,
        truncated: Bool = false
    ) {
        self.files = files
        self.totalMatches = totalMatches
        self.totalFiles = totalFiles
        self.truncated = truncated
    }

    enum CodingKeys: String, CodingKey {
        case files, totalMatches, totalFiles, truncated
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        files = try c.decodeIfPresent([ContentSearchMatchFile].self, forKey: .files) ?? []
        totalMatches = try c.decodeIfPresent(UInt64.self, forKey: .totalMatches) ?? 0
        totalFiles = try c.decodeIfPresent(UInt64.self, forKey: .totalFiles) ?? 0
        truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
    }
}

// MARK: - Fuzzy search

public struct FuzzyClientId: Hashable, Sendable, Codable, Equatable {
    public var instanceId: String
    public var connId: String

    public init(instanceId: String = "", connId: String = "") {
        self.instanceId = instanceId
        self.connId = connId
    }

    enum CodingKeys: String, CodingKey { case instanceId, connId }
}

/// Untagged: `null` ⇒ `.none`, object ⇒ `.clientId(...)`.
public enum FuzzyTargetClientId: Hashable, Sendable, Codable, Equatable {
    case none
    case clientId(FuzzyClientId)

    public var isNone: Bool {
        if case .none = self { return true }
        return false
    }

    public init(from decoder: Decoder) throws {
        if let c = try? decoder.singleValueContainer(), c.decodeNil() {
            self = .none
            return
        }
        self = .clientId(try FuzzyClientId(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .none:
            var c = encoder.singleValueContainer()
            try c.encodeNil()
        case .clientId(let id):
            try id.encode(to: encoder)
        }
    }
}

public struct FuzzyOpenReq: Hashable, Sendable, Codable, Equatable, WorkspaceRpc {
    public var root: String?
    public var requestId: String?
    public var hidden: Bool
    public var sessionId: String?
    public var targetClientId: FuzzyTargetClientId

    public init(
        root: String? = nil,
        requestId: String? = nil,
        hidden: Bool = false,
        sessionId: String? = nil,
        targetClientId: FuzzyTargetClientId = .none
    ) {
        self.root = root
        self.requestId = requestId
        self.hidden = hidden
        self.sessionId = sessionId
        self.targetClientId = targetClientId
    }

    public static let method: String = "workspace.fuzzy_open"
    public typealias Response = String

    enum CodingKeys: String, CodingKey {
        case root
        case requestId = "request_id"
        case hidden
        case sessionId = "session_id"
        case targetClientId = "target_client_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        root = try c.decodeIfPresent(String.self, forKey: .root)
        requestId = try c.decodeIfPresent(String.self, forKey: .requestId)
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId)
        targetClientId = try c.decodeIfPresent(FuzzyTargetClientId.self, forKey: .targetClientId) ?? .none
    }
}

public struct FuzzyChangeReq: Hashable, Sendable, Codable, Equatable, WorkspaceRpc {
    public var searchId: String
    public var query: String
    public var dirsOnly: Bool
    public var limit: UInt64?

    public init(searchId: String, query: String, dirsOnly: Bool = false, limit: UInt64? = nil) {
        self.searchId = searchId
        self.query = query
        self.dirsOnly = dirsOnly
        self.limit = limit
    }

    public static let method: String = "workspace.fuzzy_change"
    public typealias Response = Bool

    enum CodingKeys: String, CodingKey {
        case searchId = "search_id"
        case query
        case dirsOnly = "dirs_only"
        case limit
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        searchId = try c.decode(String.self, forKey: .searchId)
        query = try c.decode(String.self, forKey: .query)
        dirsOnly = try c.decodeIfPresent(Bool.self, forKey: .dirsOnly) ?? false
        limit = try c.decodeIfPresent(UInt64.self, forKey: .limit)
    }
}

public struct FuzzyCloseReq: Hashable, Sendable, Codable, Equatable, WorkspaceRpc {
    public var searchId: String

    public init(searchId: String) {
        self.searchId = searchId
    }

    public static let method: String = "workspace.fuzzy_close"
    public typealias Response = Bool

    enum CodingKeys: String, CodingKey {
        case searchId = "search_id"
    }
}

public struct FuzzyStatusReq: Hashable, Sendable, Codable, Equatable, WorkspaceRpc {
    public var searchId: String

    public init(searchId: String = "") {
        self.searchId = searchId
    }

    public static let method: String = "workspace.fuzzy_search"
    public typealias Response = JSONValue

    enum CodingKeys: String, CodingKey {
        case searchId = "search_id"
    }
}
