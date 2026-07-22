// RpcFilesystem.swift
//
// File I/O methods: service-level put/get and `workspace.fs_*` /
// `workspace.client_fs_*` extension ops. Ported from
// `crates/codegen/xai-grok-workspace-types/src/rpc/fs.rs`.

import Foundation
import OpenGrokShared

// MARK: - Service-level put/get

public struct PutFileEntry: Hashable, Sendable, Codable, Equatable {
    public var path: String
    public var content: String
    public var createDirs: Bool
    public var append: Bool

    public init(path: String, content: String, createDirs: Bool = true, append: Bool = false) {
        self.path = path
        self.content = content
        self.createDirs = createDirs
        self.append = append
    }

    enum CodingKeys: String, CodingKey {
        case path, content
        case createDirs = "create_dirs"
        case append
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        content = try c.decode(String.self, forKey: .content)
        createDirs = try c.decodeIfPresent(Bool.self, forKey: .createDirs) ?? true
        append = try c.decodeIfPresent(Bool.self, forKey: .append) ?? false
    }
}

public struct PutFilesReq: Hashable, Sendable, Codable, Equatable, WorkspaceRpc {
    public var files: [PutFileEntry]
    public init(files: [PutFileEntry]) { self.files = files }
    public static let method: String = "workspace.put_files"
    public typealias Response = PutFilesRes
}

public struct PutFileResult: Hashable, Sendable, Codable, Equatable {
    public var path: String
    public var ok: Bool
    public var error: String?
    public var hash: String?

    public init(path: String, ok: Bool, error: String? = nil, hash: String? = nil) {
        self.path = path
        self.ok = ok
        self.error = error
        self.hash = hash
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(path, forKey: .path)
        try c.encode(ok, forKey: .ok)
        try c.encodeIfPresent(error, forKey: .error)
        try c.encodeIfPresent(hash, forKey: .hash)
    }

    enum CodingKeys: String, CodingKey { case path, ok, error, hash }
}

public struct PutFilesRes: Hashable, Sendable, Codable, Equatable {
    public var results: [PutFileResult]
    public init(results: [PutFileResult] = []) { self.results = results }
}

public struct GetFileEntry: Hashable, Sendable, Codable, Equatable {
    public var path: String
    public var ifNoneMatch: String?
    public var offset: UInt64?
    public var length: UInt64?

    public init(path: String, ifNoneMatch: String? = nil, offset: UInt64? = nil, length: UInt64? = nil) {
        self.path = path
        self.ifNoneMatch = ifNoneMatch
        self.offset = offset
        self.length = length
    }

    enum CodingKeys: String, CodingKey {
        case path
        case ifNoneMatch = "if_none_match"
        case offset, length
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(path, forKey: .path)
        try c.encodeIfPresent(ifNoneMatch, forKey: .ifNoneMatch)
        try c.encodeIfPresent(offset, forKey: .offset)
        try c.encodeIfPresent(length, forKey: .length)
    }
}

public struct GetFilesReq: Hashable, Sendable, Codable, Equatable, WorkspaceRpc {
    public var files: [GetFileEntry]
    public init(files: [GetFileEntry]) { self.files = files }
    public static let method: String = "workspace.get_files"
    public typealias Response = GetFilesRes
}

public struct GetFileResult: Hashable, Sendable, Codable, Equatable {
    public var path: String
    public var exists: Bool
    public var content: String?
    public var hash: String?
    public var matched: Bool
    public var size: UInt64?
    public var error: String?

    public init(
        path: String,
        exists: Bool,
        content: String? = nil,
        hash: String? = nil,
        matched: Bool = false,
        size: UInt64? = nil,
        error: String? = nil
    ) {
        self.path = path
        self.exists = exists
        self.content = content
        self.hash = hash
        self.matched = matched
        self.size = size
        self.error = error
    }

    enum CodingKeys: String, CodingKey {
        case path, exists, content, hash, matched, size, error
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        exists = try c.decode(Bool.self, forKey: .exists)
        content = try c.decodeIfPresent(String.self, forKey: .content)
        hash = try c.decodeIfPresent(String.self, forKey: .hash)
        matched = try c.decodeIfPresent(Bool.self, forKey: .matched) ?? false
        size = try c.decodeIfPresent(UInt64.self, forKey: .size)
        error = try c.decodeIfPresent(String.self, forKey: .error)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(path, forKey: .path)
        try c.encode(exists, forKey: .exists)
        try c.encodeIfPresent(content, forKey: .content)
        try c.encodeIfPresent(hash, forKey: .hash)
        try c.encode(matched, forKey: .matched)
        try c.encodeIfPresent(size, forKey: .size)
        try c.encodeIfPresent(error, forKey: .error)
    }
}

public struct GetFilesRes: Hashable, Sendable, Codable, Equatable {
    public var results: [GetFileResult]
    public init(results: [GetFileResult] = []) { self.results = results }
}

// MARK: - workspace.fs_* (shell-facing)

public struct FsListNode: Hashable, Sendable, Codable, Equatable {
    public var name: String
    public var path: String
    public var nodeType: String
    public var isSymlink: Bool?
    public var size: UInt64?
    public var modifiedAt: String?

    public init(
        name: String,
        path: String,
        nodeType: String,
        isSymlink: Bool? = nil,
        size: UInt64? = nil,
        modifiedAt: String? = nil
    ) {
        self.name = name
        self.path = path
        self.nodeType = nodeType
        self.isSymlink = isSymlink
        self.size = size
        self.modifiedAt = modifiedAt
    }

    enum CodingKeys: String, CodingKey {
        case name, path
        case nodeType = "type"
        case isSymlink
        case size
        case modifiedAt
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(path, forKey: .path)
        try c.encode(nodeType, forKey: .nodeType)
        try c.encodeIfPresent(isSymlink, forKey: .isSymlink)
        try c.encodeIfPresent(size, forKey: .size)
        try c.encodeIfPresent(modifiedAt, forKey: .modifiedAt)
    }
}

public struct FsListData: Hashable, Sendable, Codable, Equatable {
    public var nodes: [FsListNode]
    public var truncated: Bool
    public init(nodes: [FsListNode] = [], truncated: Bool = false) {
        self.nodes = nodes
        self.truncated = truncated
    }
}

public struct FsExistsData: Hashable, Sendable, Codable, Equatable {
    public var exists: Bool
    public init(exists: Bool) { self.exists = exists }
}

public struct FsReadFileData: Hashable, Sendable, Codable, Equatable {
    public var content: String
    public var contentBase64: String?
    public var size: UInt64
    public var lineCount: UInt64?
    public var contentType: String

    public init(
        content: String,
        contentBase64: String? = nil,
        size: UInt64,
        lineCount: UInt64? = nil,
        contentType: String
    ) {
        self.content = content
        self.contentBase64 = contentBase64
        self.size = size
        self.lineCount = lineCount
        self.contentType = contentType
    }

    enum CodingKeys: String, CodingKey {
        case content
        case contentBase64
        case size
        case lineCount
        case contentType = "type"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(content, forKey: .content)
        try c.encodeIfPresent(contentBase64, forKey: .contentBase64)
        try c.encode(size, forKey: .size)
        try c.encodeIfPresent(lineCount, forKey: .lineCount)
        try c.encode(contentType, forKey: .contentType)
    }
}

public enum FsReadEncoding: Hashable, Sendable, Codable, Equatable {
    case utf8
    case base64

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        switch try c.decode(String.self) {
        case "utf8": self = .utf8
        case "base64": self = .base64
        default:
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "unknown FsReadEncoding")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .utf8: try c.encode("utf8")
        case .base64: try c.encode("base64")
        }
    }
}

public struct FsListReq: Hashable, Sendable, Codable, Equatable, WorkspaceRpc {
    public var path: String
    public var cwd: String?
    public var depth: UInt64
    public var limit: UInt64
    public var offset: UInt64
    public var includeHidden: Bool
    public var followSymlinks: Bool
    public var respectGitIgnore: Bool
    public var includeGlobs: [String]
    public var excludeGlobs: [String]

    public init(
        path: String,
        cwd: String? = nil,
        depth: UInt64 = 1,
        limit: UInt64 = 1000,
        offset: UInt64 = 0,
        includeHidden: Bool = true,
        followSymlinks: Bool = true,
        respectGitIgnore: Bool = true,
        includeGlobs: [String] = [],
        excludeGlobs: [String] = []
    ) {
        self.path = path
        self.cwd = cwd
        self.depth = depth
        self.limit = limit
        self.offset = offset
        self.includeHidden = includeHidden
        self.followSymlinks = followSymlinks
        self.respectGitIgnore = respectGitIgnore
        self.includeGlobs = includeGlobs
        self.excludeGlobs = excludeGlobs
    }

    public static let method: String = "workspace.fs_list"
    public typealias Response = FsListData

    enum CodingKeys: String, CodingKey {
        case path, cwd, depth, limit, offset
        case includeHidden = "include_hidden"
        case followSymlinks = "follow_symlinks"
        case respectGitIgnore = "respect_git_ignore"
        case includeGlobs = "include_globs"
        case excludeGlobs = "exclude_globs"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        depth = try c.decodeIfPresent(UInt64.self, forKey: .depth) ?? 1
        limit = try c.decodeIfPresent(UInt64.self, forKey: .limit) ?? 1000
        offset = try c.decodeIfPresent(UInt64.self, forKey: .offset) ?? 0
        includeHidden = try c.decodeIfPresent(Bool.self, forKey: .includeHidden) ?? true
        followSymlinks = try c.decodeIfPresent(Bool.self, forKey: .followSymlinks) ?? true
        respectGitIgnore = try c.decodeIfPresent(Bool.self, forKey: .respectGitIgnore) ?? true
        includeGlobs = try c.decodeIfPresent([String].self, forKey: .includeGlobs) ?? []
        excludeGlobs = try c.decodeIfPresent([String].self, forKey: .excludeGlobs) ?? []
    }
}

public struct FsExistsReq: Hashable, Sendable, Codable, Equatable, WorkspaceRpc {
    public var path: String
    public var cwd: String?
    public init(path: String, cwd: String? = nil) {
        self.path = path
        self.cwd = cwd
    }
    public static let method: String = "workspace.fs_exists"
    public typealias Response = FsExistsData
}

public struct FsReadFileReq: Hashable, Sendable, Codable, Equatable, WorkspaceRpc {
    public var path: String
    public var cwd: String?
    public var offset: UInt64?
    public var length: UInt64?
    public var maxBytes: UInt64
    public var encoding: FsReadEncoding

    public init(
        path: String,
        cwd: String? = nil,
        offset: UInt64? = nil,
        length: UInt64? = nil,
        maxBytes: UInt64 = 1_048_576,
        encoding: FsReadEncoding = .utf8
    ) {
        self.path = path
        self.cwd = cwd
        self.offset = offset
        self.length = length
        self.maxBytes = maxBytes
        self.encoding = encoding
    }

    public static let method: String = "workspace.fs_read_file"
    public typealias Response = FsReadFileData

    enum CodingKeys: String, CodingKey {
        case path, cwd, offset, length
        case maxBytes = "max_bytes"
        case encoding
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        offset = try c.decodeIfPresent(UInt64.self, forKey: .offset)
        length = try c.decodeIfPresent(UInt64.self, forKey: .length)
        maxBytes = try c.decodeIfPresent(UInt64.self, forKey: .maxBytes) ?? 1_048_576
        encoding = try c.decodeIfPresent(FsReadEncoding.self, forKey: .encoding) ?? .utf8
    }
}

public struct FsWriteFileReq: Hashable, Sendable, Codable, Equatable, WorkspaceRpc {
    public var path: String
    public var cwd: String?
    public var content: String
    public var createDirs: Bool

    public init(path: String, cwd: String? = nil, content: String, createDirs: Bool = true) {
        self.path = path
        self.cwd = cwd
        self.content = content
        self.createDirs = createDirs
    }

    public static let method: String = "workspace.fs_write_file"
    public typealias Response = WorkspaceRpcUnit

    enum CodingKeys: String, CodingKey {
        case path, cwd, content
        case createDirs = "create_dirs"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        content = try c.decode(String.self, forKey: .content)
        createDirs = try c.decodeIfPresent(Bool.self, forKey: .createDirs) ?? true
    }
}

public struct FsDeleteFileReq: Hashable, Sendable, Codable, Equatable, WorkspaceRpc {
    public var path: String
    public var cwd: String?
    public init(path: String, cwd: String? = nil) {
        self.path = path
        self.cwd = cwd
    }
    public static let method: String = "workspace.fs_delete_file"
    public typealias Response = WorkspaceRpcUnit
}

// MARK: - client_fs_* (camelCase)

public let CLIENT_FS_LIST_METHOD: String = "workspace.client_fs_list"
public let CLIENT_FS_STAT_METHOD: String = "workspace.client_fs_stat"
public let CLIENT_FS_READ_FILE_METHOD: String = "workspace.client_fs_read_file"

public enum FsNodeType: Hashable, Sendable, Codable, Equatable {
    case directory
    case file

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        switch try c.decode(String.self) {
        case "directory": self = .directory
        case "file": self = .file
        default:
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "unknown FsNodeType")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .directory: try c.encode("directory")
        case .file: try c.encode("file")
        }
    }
}

public enum FsContentType: Hashable, Sendable, Codable, Equatable {
    case text
    case binary

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        switch try c.decode(String.self) {
        case "text": self = .text
        case "binary": self = .binary
        default:
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "unknown FsContentType")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .text: try c.encode("text")
        case .binary: try c.encode("binary")
        }
    }
}

public struct ClientFsListReq: Hashable, Sendable, Codable, Equatable, WorkspaceRpc {
    public var path: String
    public var depth: UInt32
    public var includeHidden: Bool
    public var limit: UInt32
    public var offset: UInt64
    public var followSymlinks: Bool
    public var respectGitIgnore: Bool
    public var includeGlobs: [String]
    public var excludeGlobs: [String]

    public init(
        path: String,
        depth: UInt32 = 1,
        includeHidden: Bool = true,
        limit: UInt32 = 1000,
        offset: UInt64 = 0,
        followSymlinks: Bool = true,
        respectGitIgnore: Bool = true,
        includeGlobs: [String] = [],
        excludeGlobs: [String] = []
    ) {
        self.path = path
        self.depth = depth
        self.includeHidden = includeHidden
        self.limit = limit
        self.offset = offset
        self.followSymlinks = followSymlinks
        self.respectGitIgnore = respectGitIgnore
        self.includeGlobs = includeGlobs
        self.excludeGlobs = excludeGlobs
    }

    public static let method: String = CLIENT_FS_LIST_METHOD
    public typealias Response = ClientFsListRes

    enum CodingKeys: String, CodingKey {
        case path, depth, includeHidden, limit, offset
        case followSymlinks, respectGitIgnore, includeGlobs, excludeGlobs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        depth = try c.decodeIfPresent(UInt32.self, forKey: .depth) ?? 1
        includeHidden = try c.decodeIfPresent(Bool.self, forKey: .includeHidden) ?? true
        limit = try c.decodeIfPresent(UInt32.self, forKey: .limit) ?? 1000
        offset = try c.decodeIfPresent(UInt64.self, forKey: .offset) ?? 0
        followSymlinks = try c.decodeIfPresent(Bool.self, forKey: .followSymlinks) ?? true
        respectGitIgnore = try c.decodeIfPresent(Bool.self, forKey: .respectGitIgnore) ?? true
        includeGlobs = try c.decodeIfPresent([String].self, forKey: .includeGlobs) ?? []
        excludeGlobs = try c.decodeIfPresent([String].self, forKey: .excludeGlobs) ?? []
    }
}

public struct ClientFsListNode: Hashable, Sendable, Codable, Equatable {
    public var name: String
    public var path: String
    public var nodeType: FsNodeType
    public var isSymlink: Bool?
    public var size: UInt64?
    public var mtimeMs: Int64?

    public init(
        name: String,
        path: String,
        nodeType: FsNodeType,
        isSymlink: Bool? = nil,
        size: UInt64? = nil,
        mtimeMs: Int64? = nil
    ) {
        self.name = name
        self.path = path
        self.nodeType = nodeType
        self.isSymlink = isSymlink
        self.size = size
        self.mtimeMs = mtimeMs
    }

    enum CodingKeys: String, CodingKey {
        case name, path
        case nodeType = "type"
        case isSymlink, size, mtimeMs
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(path, forKey: .path)
        try c.encode(nodeType, forKey: .nodeType)
        try c.encodeIfPresent(isSymlink, forKey: .isSymlink)
        try c.encodeIfPresent(size, forKey: .size)
        try c.encodeIfPresent(mtimeMs, forKey: .mtimeMs)
    }
}

public struct ClientFsListRes: Hashable, Sendable, Codable, Equatable {
    public var nodes: [ClientFsListNode]
    public var truncated: Bool
    public init(nodes: [ClientFsListNode] = [], truncated: Bool = false) {
        self.nodes = nodes
        self.truncated = truncated
    }
}

public struct ClientFsStatReq: Hashable, Sendable, Codable, Equatable, WorkspaceRpc {
    public var path: String
    public init(path: String) { self.path = path }
    public static let method: String = CLIENT_FS_STAT_METHOD
    public typealias Response = ClientFsStatRes
}

public struct ClientFsStatRes: Hashable, Sendable, Codable, Equatable {
    public var exists: Bool
    public var nodeType: FsNodeType?
    public var size: UInt64?
    public var mtimeMs: Int64?
    public var hash: String?

    public init(
        exists: Bool,
        nodeType: FsNodeType? = nil,
        size: UInt64? = nil,
        mtimeMs: Int64? = nil,
        hash: String? = nil
    ) {
        self.exists = exists
        self.nodeType = nodeType
        self.size = size
        self.mtimeMs = mtimeMs
        self.hash = hash
    }

    enum CodingKeys: String, CodingKey {
        case exists, nodeType, size, mtimeMs, hash
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(exists, forKey: .exists)
        try c.encodeIfPresent(nodeType, forKey: .nodeType)
        try c.encodeIfPresent(size, forKey: .size)
        try c.encodeIfPresent(mtimeMs, forKey: .mtimeMs)
        try c.encodeIfPresent(hash, forKey: .hash)
    }
}

public struct ClientFsReadFileReq: Hashable, Sendable, Codable, Equatable, WorkspaceRpc {
    public var path: String
    public var offset: UInt64?
    public var length: UInt64?
    public var maxBytes: UInt64
    public var encoding: FsReadEncoding

    public init(
        path: String,
        offset: UInt64? = nil,
        length: UInt64? = nil,
        maxBytes: UInt64 = 1_048_576,
        encoding: FsReadEncoding = .utf8
    ) {
        self.path = path
        self.offset = offset
        self.length = length
        self.maxBytes = maxBytes
        self.encoding = encoding
    }

    public static let method: String = CLIENT_FS_READ_FILE_METHOD
    public typealias Response = ClientFsReadFileRes

    enum CodingKeys: String, CodingKey {
        case path, offset, length, maxBytes, encoding
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        offset = try c.decodeIfPresent(UInt64.self, forKey: .offset)
        length = try c.decodeIfPresent(UInt64.self, forKey: .length)
        maxBytes = try c.decodeIfPresent(UInt64.self, forKey: .maxBytes) ?? 1_048_576
        encoding = try c.decodeIfPresent(FsReadEncoding.self, forKey: .encoding) ?? .utf8
    }
}

public struct ClientFsReadFileRes: Hashable, Sendable, Codable, Equatable {
    public var content: String?
    public var contentBase64: String?
    public var size: UInt64
    public var hash: String
    public var contentType: FsContentType

    public init(
        content: String? = nil,
        contentBase64: String? = nil,
        size: UInt64,
        hash: String,
        contentType: FsContentType
    ) {
        self.content = content
        self.contentBase64 = contentBase64
        self.size = size
        self.hash = hash
        self.contentType = contentType
    }

    enum CodingKeys: String, CodingKey {
        case content, contentBase64, size, hash
        case contentType = "type"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(content, forKey: .content)
        try c.encodeIfPresent(contentBase64, forKey: .contentBase64)
        try c.encode(size, forKey: .size)
        try c.encode(hash, forKey: .hash)
        try c.encode(contentType, forKey: .contentType)
    }
}
