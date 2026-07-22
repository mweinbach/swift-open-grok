// RpcCodeNav.swift
//
// Codebase index / code navigation methods. Ported from
// `crates/codegen/xai-grok-workspace-types/src/rpc/code_nav.rs`.

import Foundation
import OpenGrokShared

public struct CodeGotoDefinitionReq: Hashable, Sendable, Codable, Equatable, WorkspaceRpc {
    public var root: String?
    public var file: String
    public var line: UInt64
    public var col: UInt64

    public init(root: String? = nil, file: String, line: UInt64, col: UInt64) {
        self.root = root
        self.file = file
        self.line = line
        self.col = col
    }

    public static let method: String = "workspace.code_goto_definition"
    public typealias Response = CodeNavResponse

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        root = try c.decodeIfPresent(String.self, forKey: .root)
        file = try c.decode(String.self, forKey: .file)
        line = try c.decode(UInt64.self, forKey: .line)
        col = try c.decode(UInt64.self, forKey: .col)
    }

    enum CodingKeys: String, CodingKey { case root, file, line, col }
}

public struct CodeGotoReferencesReq: Hashable, Sendable, Codable, Equatable, WorkspaceRpc {
    public var root: String?
    public var file: String
    public var line: UInt64
    public var col: UInt64
    public var includeDefinition: Bool

    public init(root: String? = nil, file: String, line: UInt64, col: UInt64, includeDefinition: Bool = false) {
        self.root = root
        self.file = file
        self.line = line
        self.col = col
        self.includeDefinition = includeDefinition
    }

    public static let method: String = "workspace.code_goto_references"
    public typealias Response = CodeNavResponse

    enum CodingKeys: String, CodingKey {
        case root, file, line, col
        case includeDefinition = "include_definition"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        root = try c.decodeIfPresent(String.self, forKey: .root)
        file = try c.decode(String.self, forKey: .file)
        line = try c.decode(UInt64.self, forKey: .line)
        col = try c.decode(UInt64.self, forKey: .col)
        includeDefinition = try c.decodeIfPresent(Bool.self, forKey: .includeDefinition) ?? false
    }
}

public struct CodeFindDefinitionsReq: Hashable, Sendable, Codable, Equatable, WorkspaceRpc {
    public var root: String?
    public var symbol: String
    public var contextFile: String?

    public init(root: String? = nil, symbol: String, contextFile: String? = nil) {
        self.root = root
        self.symbol = symbol
        self.contextFile = contextFile
    }

    public static let method: String = "workspace.code_find_definitions"
    public typealias Response = CodeNavResponse

    enum CodingKeys: String, CodingKey {
        case root, symbol
        case contextFile = "context_file"
    }
}

public struct CodeFindReferencesReq: Hashable, Sendable, Codable, Equatable, WorkspaceRpc {
    public var root: String?
    public var symbol: String
    public var contextFile: String?

    public init(root: String? = nil, symbol: String, contextFile: String? = nil) {
        self.root = root
        self.symbol = symbol
        self.contextFile = contextFile
    }

    public static let method: String = "workspace.code_find_references"
    public typealias Response = CodeNavResponse

    enum CodingKeys: String, CodingKey {
        case root, symbol
        case contextFile = "context_file"
    }
}

public struct CodeIndexStatusReq: Hashable, Sendable, Codable, Equatable, WorkspaceRpc {
    public var root: String?

    public init(root: String? = nil) {
        self.root = root
    }

    public static let method: String = "workspace.code_index_status"
    public typealias Response = CodeIndexStatusResponse

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        root = try c.decodeIfPresent(String.self, forKey: .root)
    }

    enum CodingKeys: String, CodingKey { case root }
}

public struct CodeIndexStats: Hashable, Sendable, Codable, Equatable {
    public var files: UInt64
    public var definitions: UInt64
    public var references: UInt64

    public init(files: UInt64, definitions: UInt64, references: UInt64) {
        self.files = files
        self.definitions = definitions
        self.references = references
    }
}

public struct CodeIndexStatusResponse: Hashable, Sendable, Codable, Equatable {
    public var active: Bool
    public var fileCount: UInt64?
    public var stats: CodeIndexStats?

    public init(active: Bool, fileCount: UInt64? = nil, stats: CodeIndexStats? = nil) {
        self.active = active
        self.fileCount = fileCount
        self.stats = stats
    }

    enum CodingKeys: String, CodingKey {
        case active
        case fileCount = "file_count"
        case stats
    }
}

public struct CodeNavLocation: Hashable, Sendable, Codable, Equatable {
    public var path: String
    public var line: UInt64
    public var symbol: String?

    public init(path: String, line: UInt64, symbol: String? = nil) {
        self.path = path
        self.line = line
        self.symbol = symbol
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(path, forKey: .path)
        try c.encode(line, forKey: .line)
        try c.encodeIfPresent(symbol, forKey: .symbol)
    }

    enum CodingKeys: String, CodingKey { case path, line, symbol }
}

public struct CodeNavResponse: Hashable, Sendable, Codable, Equatable {
    public var locations: [CodeNavLocation]

    public init(locations: [CodeNavLocation] = []) {
        self.locations = locations
    }
}
