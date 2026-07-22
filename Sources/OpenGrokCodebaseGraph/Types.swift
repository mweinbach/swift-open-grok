// Types.swift
//
// Core types for OpenGrokCodebaseGraph — port of xai-codebase-graph types.

import Foundation

/// Events that can trigger index updates.
public enum FileEvent: Sendable, Equatable {
    case created(path: String)
    case modified(path: String)
    case deleted(path: String)
    case renamed(from: String, to: String)

    public var path: String {
        switch self {
        case .created(let p), .modified(let p), .deleted(let p): return p
        case .renamed(_, let to): return to
        }
    }

    public var requiresReparse: Bool {
        switch self {
        case .created, .modified: return true
        case .deleted, .renamed: return false
        }
    }
}

/// 1-indexed position in a file.
public struct Position: Sendable, Equatable, Hashable, Codable {
    public var line: Int
    public var column: Int
    public init(line: Int, column: Int) {
        self.line = line
        self.column = column
    }
}

/// Inclusive/exclusive source range.
public struct SourceRange: Sendable, Equatable, Hashable, Codable {
    public var start: Position
    public var end: Position
    public init(start: Position, end: Position) {
        self.start = start
        self.end = end
    }
}

/// Index statistics.
public struct IndexStats: Sendable, Equatable, Codable {
    public var files: Int
    public var definitions: Int
    public var references: Int
    public init(files: Int = 0, definitions: Int = 0, references: Int = 0) {
        self.files = files
        self.definitions = definitions
        self.references = references
    }
}

/// A symbol occurrence (name + 1-indexed line/column).
public struct SymbolOccurrence: Sendable, Equatable, Hashable {
    public var name: String
    public var line: Int
    public var column: Int
    public init(name: String, line: Int, column: Int = 1) {
        self.name = name
        self.line = line
        self.column = column
    }
}

/// Alias mapping (imported-as → original).
public struct SymbolAlias: Sendable, Equatable, Hashable {
    public var alias: String
    public var original: String
    public init(alias: String, original: String) {
        self.alias = alias
        self.original = original
    }
}

/// File metadata for staleness detection.
public struct FileMeta: Sendable, Equatable, Hashable, Codable {
    public var size: UInt64
    public var mtimeSeconds: Int64
    public var mtimeNanoseconds: UInt32

    public init(size: UInt64, mtimeSeconds: Int64, mtimeNanoseconds: UInt32 = 0) {
        self.size = size
        self.mtimeSeconds = mtimeSeconds
        self.mtimeNanoseconds = mtimeNanoseconds
    }

    public static func from(url: URL) -> FileMeta? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else {
            return nil
        }
        let size = UInt64(values.fileSize ?? 0)
        let mtime = values.contentModificationDate ?? Date(timeIntervalSince1970: 0)
        let secs = Int64(mtime.timeIntervalSince1970)
        let nanos = UInt32((mtime.timeIntervalSince1970.truncatingRemainder(dividingBy: 1)) * 1_000_000_000)
        return FileMeta(size: size, mtimeSeconds: secs, mtimeNanoseconds: nanos)
    }

    public func isStale(at path: String) -> Bool {
        guard let current = FileMeta.from(url: URL(fileURLWithPath: path)) else {
            return true
        }
        return current != self
    }
}

/// Location of a symbol definition or reference.
public struct SymbolLocation: Sendable, Equatable, Hashable, Codable {
    public var path: String
    public var line: Int
    public var column: Int
    public var name: String

    public init(path: String, line: Int, column: Int = 1, name: String = "") {
        self.path = path
        self.line = line
        self.column = column
        self.name = name
    }
}

/// Kind of a symbol node.
public enum NodeKind: String, Sendable, Equatable, Codable {
    case definition
    case reference
    case import_
    case scope
}

/// Maximum indexable file size (bytes). Matches Rust MAX_INDEXABLE_FILE_SIZE.
public let maxIndexableFileSize: Int = 1_048_576

/// True when content looks binary (NUL in first 8KB).
public func isBinaryContent(_ data: Data) -> Bool {
    let n = min(data.count, 8000)
    return data.prefix(n).contains(0)
}
