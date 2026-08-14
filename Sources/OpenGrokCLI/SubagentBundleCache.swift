// SubagentBundleCache.swift
//
// On-disk cache for the xAI-published subagent bundle: personas, roles,
// agents, and skills written under `<grok home>/bundled`.
//
// Writes are checksum-tracked through `manifest.json`, so a file the user
// edited by hand is never overwritten and never pruned. Archive extraction
// is bounded (entry count, per-entry size, total decompressed size) and every
// path is sanitized before it is joined onto the cache root.

import Foundation
import OpenGrokBuildSupport
import OpenGrokCLIChatProxyTypes
import OpenGrokFileUtils
import OpenGrokPaths
import OpenGrokShared

// MARK: - Constants & Limits

public enum BundleArchiveLimits {
    public static let maxDecompressedSize: Int = 50 * 1024 * 1024
    public static let maxEntries: Int = 1000
    public static let maxEntrySize: UInt64 = 1024 * 1024
    public static let bundledDirName = "bundled"
    public static let manifestFileName = "manifest.json"
}

// MARK: - Errors

public enum BundleError: Error, CustomStringConvertible, Equatable, Sendable {
    case invalidBundleName(String)
    case archiveExtractionFailed(String)
    case fileIO(String)
    case entryNotFound(kind: String, name: String)
    case unknownEntryKind(String)

    public var description: String {
        switch self {
        case .invalidBundleName(let msg):
            return msg
        case .archiveExtractionFailed(let msg):
            return msg
        case .fileIO(let msg):
            return msg
        case .entryNotFound(let kind, let name):
            return "\(kind) '\(name)' not found in bundle cache"
        case .unknownEntryKind(let kind):
            return "unknown entry kind: \(kind)"
        }
    }
}

// MARK: - Manifest

public struct BundleManifest: Codable, Equatable, Sendable {
    public var version: String
    public var checksums: [String: String]

    public init(version: String = "", checksums: [String: String] = [:]) {
        self.version = version
        self.checksums = checksums
    }
}

// MARK: - File Kind & State

public enum BundleFileKind: Sendable, Equatable, CaseIterable {
    case persona
    case role
    case agent
    case skill

    public var dirName: String {
        switch self {
        case .persona: return "personas"
        case .role: return "roles"
        case .agent: return "agents"
        case .skill: return "skills"
        }
    }

    public var fileExtension: String {
        switch self {
        case .agent, .skill: return "md"
        case .persona, .role: return "toml"
        }
    }

    public var label: String {
        switch self {
        case .persona: return "persona"
        case .role: return "role"
        case .agent: return "agent"
        case .skill: return "skill"
        }
    }

    public static func fromDirName(_ dirName: String) -> BundleFileKind? {
        switch dirName {
        case "personas": return .persona
        case "roles": return .role
        case "agents": return .agent
        case "skills": return .skill
        default: return nil
        }
    }
}

public enum BundleFileState: Sendable, Equatable {
    case absent
    case matchesManaged
    case modifiedOrUnmanaged
}

public struct BundleFile: Sendable {
    public var relativePath: String
    public var checksum: String
    public var content: String

    public init(relativePath: String, checksum: String, content: String) {
        self.relativePath = relativePath
        self.checksum = checksum
        self.content = content
    }
}

// MARK: - Core Functions

/// Root directory for bundled subagents under `openGrokHome`.
public func bundledRoot(openGrokHome: URL) -> URL {
    openGrokHome.appendingPathComponent(BundleArchiveLimits.bundledDirName, isDirectory: true)
}

/// Read cached `manifest.json` from `root` if it exists.
public func readCachedManifest(root: URL) throws -> BundleManifest? {
    let manifestURL = manifestPath(root: root)
    guard FileManager.default.fileExists(atPath: manifestURL.path) else {
        return nil
    }
    do {
        let data = try Data(contentsOf: manifestURL)
        return try JSONDecoder().decode(BundleManifest.self, from: data)
    } catch {
        throw BundleError.fileIO("failed to read \(manifestURL.path): \(error.localizedDescription)")
    }
}

/// Write a `SubagentBundle` to the disk cache, updating `manifest.json`.
public func writeBundleToCache(root: URL, bundle: SubagentBundle) throws -> BundleManifest {
    let oldManifest = (try readCachedManifest(root: root)).map(sanitizeManifest)
    try ensureBundleDirs(root: root)

    let files = try bundleFiles(bundle: bundle)
    var nextChecksums: [String: String] = [:]

    for file in files {
        let previousChecksum = oldManifest?.checksums[file.relativePath]
        let absoluteURL = root.appendingPathComponent(file.relativePath)
        let state = try bundleFileState(path: absoluteURL, oldChecksum: previousChecksum)

        switch state {
        case .absent, .matchesManaged:
            try writeBundleFile(absoluteURL: absoluteURL, content: Data(file.content.utf8))
            nextChecksums[file.relativePath] = file.checksum
        case .modifiedOrUnmanaged:
            if let previousChecksum {
                nextChecksums[file.relativePath] = previousChecksum
            }
        }
    }

    if let oldManifest {
        try pruneRemovedFiles(root: root, oldManifest: oldManifest, retainedChecksums: &nextChecksums)
    }

    let nextManifest = BundleManifest(version: bundle.version, checksums: nextChecksums)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let manifestData = try encoder.encode(nextManifest)
    let manifestURL = manifestPath(root: root)
    try manifestData.write(to: manifestURL, options: .atomic)

    return nextManifest
}

/// Extract an archive (.tar.gz) into the disk cache, enforcing bounds and updating `manifest.json`.
public func extractBundleArchive(root: URL, archiveBytes: Data) throws -> BundleManifest {
    let tarBytes = try BundleArchiveExtractor.decompressGzip(archiveBytes, maxSize: BundleArchiveLimits.maxDecompressedSize)

    let oldManifest = (try readCachedManifest(root: root)).map(sanitizeManifest)
    try ensureBundleDirs(root: root)

    var nextChecksums: [String: String] = [:]
    var version = ""
    var totalDecompressed: Int = 0
    var entryCount: Int = 0

    let entries = try BundleArchiveExtractor.parseTar(tarBytes)

    for entry in entries {
        guard entry.isRegularFile else {
            continue
        }

        entryCount += 1
        if entryCount > BundleArchiveLimits.maxEntries {
            throw BundleError.archiveExtractionFailed("archive exceeds maximum entry count (\(BundleArchiveLimits.maxEntries))")
        }

        let entrySize = UInt64(entry.data.count)
        if entrySize > BundleArchiveLimits.maxEntrySize {
            throw BundleError.archiveExtractionFailed("archive entry exceeds maximum size (\(BundleArchiveLimits.maxEntrySize) bytes)")
        }

        let (newTotal, overflow) = totalDecompressed.addingReportingOverflow(Int(entrySize))
        if overflow || newTotal > BundleArchiveLimits.maxDecompressedSize {
            throw BundleError.archiveExtractionFailed("archive exceeds maximum decompressed size (\(BundleArchiveLimits.maxDecompressedSize) bytes)")
        }
        totalDecompressed = newTotal

        let rawPath = entry.path
        let path = rawPath.hasPrefix("./") ? String(rawPath.dropFirst(2)) : rawPath

        if path == "bundle.json" {
            struct ArchiveBundleMetadata: Codable {
                let version: String
            }
            guard let meta = try? JSONDecoder().decode(ArchiveBundleMetadata.self, from: entry.data) else {
                throw BundleError.archiveExtractionFailed("failed to parse bundle.json")
            }
            version = meta.version
            continue
        }

        guard let cacheRelativePath = mapArchivePathToCachePath(path) else {
            continue
        }

        let checksum = SHA256.hexDigest(Array(entry.data))
        let absoluteURL = root.appendingPathComponent(cacheRelativePath)
        let previousChecksum = oldManifest?.checksums[cacheRelativePath]
        let state = try bundleFileState(path: absoluteURL, oldChecksum: previousChecksum)

        switch state {
        case .absent, .matchesManaged:
            try writeBundleFile(absoluteURL: absoluteURL, content: entry.data)
            nextChecksums[cacheRelativePath] = checksum
        case .modifiedOrUnmanaged:
            if let prev = previousChecksum {
                nextChecksums[cacheRelativePath] = prev
            }
        }
    }

    if version.isEmpty {
        throw BundleError.archiveExtractionFailed("archive missing bundle.json with version field")
    }

    if let oldManifest {
        try pruneRemovedFiles(root: root, oldManifest: oldManifest, retainedChecksums: &nextChecksums)
    }

    let nextManifest = BundleManifest(version: version, checksums: nextChecksums)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let manifestData = try encoder.encode(nextManifest)
    let manifestURL = manifestPath(root: root)
    try manifestData.write(to: manifestURL, options: .atomic)

    return nextManifest
}

/// Compute SHA-256 hex checksum of the file at `path`.
public func checksumFile(at path: URL) throws -> String {
    let data = try Data(contentsOf: path)
    return SHA256.hexDigest(Array(data))
}

/// Count checksum entries matching a given prefix.
public func countEntriesByPrefix(manifest: BundleManifest, prefix: String) -> Int {
    manifest.checksums.keys.filter { $0.hasPrefix(prefix) }.count
}

/// Clean and validate relative paths, rejecting path traversal and invalid characters.
public func sanitizeRelativePath(_ relativePath: String) -> String? {
    if relativePath.isEmpty || relativePath.hasPrefix("/") || relativePath.contains("\\") {
        return nil
    }

    let parts = relativePath.components(separatedBy: "/")
    guard parts.count >= 2 else { return nil }

    let dirName = parts[0]
    let second = parts[1]

    if parts.count == 2 {
        if second.isEmpty { return nil }
        guard let kind = BundleFileKind.fromDirName(dirName) else { return nil }
        if kind == .skill { return nil }
        let expectedExt = ".\(kind.fileExtension)"
        guard second.hasSuffix(expectedExt) else { return nil }
        let fileStem = String(second.dropLast(expectedExt.count))
        guard (try? validateBundleName(kind: kind, name: fileStem)) != nil else { return nil }
        return relativePathFor(kind: kind, name: fileStem)
    } else {
        guard dirName == "skills" else { return nil }
        guard (try? validateBundleName(kind: .skill, name: second)) != nil else { return nil }

        for component in parts.dropFirst(2) {
            if component.isEmpty || component == "." || component == ".." {
                return nil
            }
            if component.unicodeScalars.contains(where: { isControlCharacter($0) }) {
                return nil
            }
        }
        return relativePath
    }
}

/// Map an archive path to a cache relative path (stripping `subagents/` if present).
public func mapArchivePathToCachePath(_ archivePath: String) -> String? {
    if archivePath.hasPrefix("subagents/") {
        let rest = String(archivePath.dropFirst("subagents/".count))
        return sanitizeRelativePath(rest)
    }
    if archivePath.hasPrefix("skills/") {
        return sanitizeRelativePath(archivePath)
    }
    return nil
}

/// Validate bundle entry name against path traversal, separators, and control characters.
public func validateBundleName(kind: BundleFileKind, name: String) throws {
    let hasControl = name.unicodeScalars.contains { isControlCharacter($0) }
    if name.isEmpty
        || name == "."
        || name == ".."
        || name.contains("/")
        || name.contains("\\")
        || hasControl
    {
        throw BundleError.invalidBundleName("invalid bundled \(kind.label) name: \(name)")
    }
}

// MARK: - Internal Helpers

private func isControlCharacter(_ scalar: UnicodeScalar) -> Bool {
    (scalar.value <= 0x1F) || (scalar.value >= 0x7F && scalar.value <= 0x9F)
}

public func sanitizeManifest(_ manifest: BundleManifest) -> BundleManifest {
    var sanitized: [String: String] = [:]
    for (relativePath, checksum) in manifest.checksums {
        if let cleanPath = sanitizeRelativePath(relativePath) {
            sanitized[cleanPath] = checksum
        }
    }
    return BundleManifest(version: manifest.version, checksums: sanitized)
}

public func relativePathFor(kind: BundleFileKind, name: String) -> String {
    switch kind {
    case .skill:
        return "\(kind.dirName)/\(name)/SKILL.md"
    default:
        return "\(kind.dirName)/\(name).\(kind.fileExtension)"
    }
}

public func bundleFiles(bundle: SubagentBundle) throws -> [BundleFile] {
    var files: [BundleFile] = []
    try extendBundleFiles(files: &files, kind: .persona, entries: bundle.personas)
    try extendBundleFiles(files: &files, kind: .role, entries: bundle.roles)
    try extendBundleFiles(files: &files, kind: .agent, entries: bundle.agents)
    try extendBundleFiles(files: &files, kind: .skill, entries: bundle.skills)
    return files
}

private func extendBundleFiles(
    files: inout [BundleFile],
    kind: BundleFileKind,
    entries: [String: String]
) throws {
    for (name, content) in entries {
        try validateBundleName(kind: kind, name: name)
        let relPath = relativePathFor(kind: kind, name: name)
        let checksum = SHA256.hexDigest(Array(content.utf8))
        files.append(BundleFile(
            relativePath: relPath,
            checksum: checksum,
            content: content
        ))
    }
}

private func manifestPath(root: URL) -> URL {
    root.appendingPathComponent(BundleArchiveLimits.manifestFileName)
}

private func ensureBundleDirs(root: URL) throws {
    let fm = FileManager.default
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    for dirName in ["personas", "roles", "agents", "skills"] {
        let dir = root.appendingPathComponent(dirName, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }
}

private func writeBundleFile(absoluteURL: URL, content: Data) throws {
    let fm = FileManager.default
    let parent = absoluteURL.deletingLastPathComponent()
    try fm.createDirectory(at: parent, withIntermediateDirectories: true)
    try content.write(to: absoluteURL, options: .atomic)
}

private func checksumFileIfExists(at path: URL) throws -> String? {
    guard FileManager.default.fileExists(atPath: path.path) else {
        return nil
    }
    return try checksumFile(at: path)
}

private func bundleFileState(path: URL, oldChecksum: String?) throws -> BundleFileState {
    guard let currentChecksum = try checksumFileIfExists(at: path) else {
        return .absent
    }
    if let oldChecksum, currentChecksum == oldChecksum {
        return .matchesManaged
    }
    return .modifiedOrUnmanaged
}

private func pruneRemovedFiles(
    root: URL,
    oldManifest: BundleManifest,
    retainedChecksums: inout [String: String]
) throws {
    for (relativePath, previousChecksum) in sanitizeManifest(oldManifest).checksums {
        if retainedChecksums[relativePath] != nil {
            continue
        }

        let absoluteURL = root.appendingPathComponent(relativePath)
        let state = try bundleFileState(path: absoluteURL, oldChecksum: previousChecksum)
        switch state {
        case .absent:
            break
        case .matchesManaged:
            try? FileManager.default.removeItem(at: absoluteURL)
        case .modifiedOrUnmanaged:
            retainedChecksums[relativePath] = previousChecksum
        }
    }
}
