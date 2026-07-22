// Index.swift
//
// Scope-graph index, builder, and navigator. Deterministic, bounded,
// incrementally invalidated, cancellation-safe.

import Foundation

/// In-memory code graph index.
public struct ScopeGraphIndex: Sendable, Equatable {
    public var files: [String: FileSymbols]
    public var root: String

    public init(root: String, files: [String: FileSymbols] = [:]) {
        self.root = root
        self.files = files
    }

    public var stats: IndexStats {
        var defs = 0
        var refs = 0
        for f in files.values {
            defs += f.definitions.count
            refs += f.references.count
        }
        return IndexStats(files: files.count, definitions: defs, references: refs)
    }

    public mutating func upsert(_ symbols: FileSymbols) {
        files[symbols.path] = symbols
    }

    public mutating func remove(path: String) {
        files.removeValue(forKey: path)
    }

    public mutating func rename(from: String, to: String) {
        guard var s = files.removeValue(forKey: from) else { return }
        s.path = to
        files[to] = s
    }
}

/// Build a fresh index over a repository root.
public struct IndexBuilder: Sendable {
    public var maxFileSize: Int
    public var threads: Int

    public init(maxFileSize: Int = maxIndexableFileSize, threads: Int = 1) {
        self.maxFileSize = maxFileSize
        self.threads = max(1, threads)
    }

    public func withThreads(_ n: Int) -> IndexBuilder {
        var b = self
        b.threads = max(1, n)
        return b
    }

    /// Build index. Cancellation-safe via `Task.checkCancellation`.
    public func build(root: String) throws -> ScopeGraphIndex {
        var index = ScopeGraphIndex(root: root)
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: root),
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .isHiddenKey],
            options: [.skipsHiddenFiles]
        ) else {
            return index
        }
        let rootStd = (root as NSString).standardizingPath
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            // Skip VCS and common build dirs.
            let abs = url.resolvingSymlinksInPath().path
            let rel: String
            if abs.hasPrefix(rootStd + "/") {
                rel = String(abs.dropFirst(rootStd.count + 1))
            } else {
                rel = url.path.replacingOccurrences(of: root.hasSuffix("/") ? root : root + "/", with: "")
            }
            if shouldSkip(rel) { continue }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            let size = values.fileSize ?? 0
            if size > maxFileSize { continue }
            if SourceLanguage.detect(path: url.path) == .unknown { continue }
            guard let data = try? Data(contentsOf: url) else { continue }
            if isBinaryContent(data) { continue }
            guard let content = String(data: data, encoding: .utf8) else { continue }
            var symbols = SymbolExtractor.extract(path: rel, content: content)
            symbols.meta = FileMeta.from(url: url)
            index.upsert(symbols)
        }
        return index
    }

    private func shouldSkip(_ rel: String) -> Bool {
        let parts = rel.split(separator: "/")
        let skipDirs: Set<String> = [
            ".git", ".sl", "node_modules", "target", ".build", "dist",
            "build", ".venv", "venv", "__pycache__", ".idea", ".vscode"
        ]
        return parts.contains { skipDirs.contains(String($0)) }
    }
}

/// Navigation queries over an index.
public struct Navigator: Sendable {
    public var index: ScopeGraphIndex

    public init(_ index: ScopeGraphIndex) {
        self.index = index
    }

    /// Go-to-definition for a symbol name (or symbol at line).
    public func gotoDefinition(name: String) -> [SymbolLocation] {
        var out: [SymbolLocation] = []
        for (path, file) in index.files {
            for d in file.definitions where d.name == name {
                out.append(SymbolLocation(path: path, line: d.line, column: d.column, name: d.name))
            }
            // Follow aliases.
            for a in file.aliases where a.alias == name {
                out.append(contentsOf: gotoDefinition(name: a.original))
            }
        }
        return out.sorted { ($0.path, $0.line) < ($1.path, $1.line) }
    }

    /// Go-to-definition at a file position: pick the definition name on that line.
    public func gotoDefinition(path: String, line: Int, column: Int = 1) -> [SymbolLocation] {
        guard let file = index.files[path] else { return [] }
        // Prefer a definition on this exact line; else a reference on this line.
        if let d = file.definitions.first(where: { $0.line == line }) {
            return gotoDefinition(name: d.name)
        }
        if let r = file.references.first(where: { $0.line == line }) {
            return gotoDefinition(name: r.name)
        }
        _ = column
        return []
    }

    /// Find all references to a symbol name.
    public func findReferences(name: String) -> [SymbolLocation] {
        var out: [SymbolLocation] = []
        for (path, file) in index.files {
            for r in file.references where r.name == name {
                out.append(SymbolLocation(path: path, line: r.line, column: r.column, name: r.name))
            }
            // Definitions also count as reference sites for "find all".
            for d in file.definitions where d.name == name {
                out.append(SymbolLocation(path: path, line: d.line, column: d.column, name: d.name))
            }
        }
        return out.sorted { ($0.path, $0.line) < ($1.path, $1.line) }
    }

    public func hasDefinition(_ name: String) -> Bool {
        !gotoDefinition(name: name).isEmpty
    }
}

// MARK: - Cache

public let cacheFileName = "codebase-graph-index.json"

public func getCachePath(repoPath: String, under stateRoot: String? = nil) -> String {
    let root = stateRoot ?? (ProcessInfo.processInfo.environment["OPENGROK_HOME"]
        ?? (NSHomeDirectory() as NSString).appendingPathComponent(".opengrok"))
    // Simple stable key: last path component + hash of full path.
    let name = URL(fileURLWithPath: repoPath).lastPathComponent
    let digest = stableHash(repoPath)
    let dir = (root as NSString)
        .appendingPathComponent("indexes")
    return (dir as NSString)
        .appendingPathComponent("\(name)-\(digest)")
        .appending("/\(cacheFileName)")
}

public func saveIndex(_ index: ScopeGraphIndex, to path: String) throws {
    let fm = FileManager.default
    try fm.createDirectory(
        atPath: (path as NSString).deletingLastPathComponent,
        withIntermediateDirectories: true
    )
    let encodable = IndexDTO(from: index)
    let data = try JSONEncoder().encode(encodable)
    try data.write(to: URL(fileURLWithPath: path), options: .atomic)
}

public func loadIndex(from path: String) throws -> ScopeGraphIndex {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let dto = try JSONDecoder().decode(IndexDTO.self, from: data)
    return dto.toIndex()
}

public func cacheExists(at path: String) -> Bool {
    FileManager.default.fileExists(atPath: path)
}

private func stableHash(_ s: String) -> String {
    var h: UInt64 = 14695981039346656037
    for b in s.utf8 {
        h ^= UInt64(b)
        h = h &* 1099511628211
    }
    return String(h, radix: 16)
}

private struct IndexDTO: Codable {
    var root: String
    var files: [FileDTO]

    struct FileDTO: Codable {
        var path: String
        var definitions: [OccDTO]
        var references: [OccDTO]
        var aliases: [AliasDTO]
        var meta: FileMeta?
    }
    struct OccDTO: Codable {
        var name: String
        var line: Int
        var column: Int?
    }
    struct AliasDTO: Codable {
        var alias: String
        var original: String
    }

    init(from index: ScopeGraphIndex) {
        root = index.root
        files = index.files.values.sorted(by: { $0.path < $1.path }).map { f in
            FileDTO(
                path: f.path,
                definitions: f.definitions.map { OccDTO(name: $0.name, line: $0.line, column: $0.column) },
                references: f.references.map { OccDTO(name: $0.name, line: $0.line, column: $0.column) },
                aliases: f.aliases.map { AliasDTO(alias: $0.alias, original: $0.original) },
                meta: f.meta
            )
        }
    }

    func toIndex() -> ScopeGraphIndex {
        var filesMap: [String: FileSymbols] = [:]
        for f in files {
            filesMap[f.path] = FileSymbols(
                path: f.path,
                definitions: f.definitions.map {
                    SymbolOccurrence(name: $0.name, line: $0.line, column: $0.column ?? 1)
                },
                references: f.references.map {
                    SymbolOccurrence(name: $0.name, line: $0.line, column: $0.column ?? 1)
                },
                aliases: f.aliases.map { SymbolAlias(alias: $0.alias, original: $0.original) },
                meta: f.meta
            )
        }
        return ScopeGraphIndex(root: root, files: filesMap)
    }
}
