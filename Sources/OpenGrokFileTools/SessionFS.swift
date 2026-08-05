// SessionFS.swift
//
// Path resolution, atomic writes, path locks, and agent hunk attribution
// shared by all mutation tools.

import Foundation
import OpenGrokFileUtils
import OpenGrokHunkTracker
import OpenGrokShared
import OpenGrokToolRegistry
import OpenGrokWorkspace

public enum SessionFSError: Error, Sendable, Equatable, CustomStringConvertible {
    case notFound(String)
    case isDirectory(String)
    case notDirectory(String)
    case outsideWorkspace(String)
    case symlinkEscape(String)
    case io(String)
    case binaryFile(String)
    case staleContext(String)
    case noMatch(String)
    case ambiguousMatch(String)
    case invalidInput(String)

    public var description: String {
        switch self {
        case .notFound(let p): return "File not found: \(p)"
        case .isDirectory(let p): return "File path is a directory: \(p)"
        case .notDirectory(let p): return "Not a directory: \(p)"
        case .outsideWorkspace(let p): return "Path escapes workspace: \(p)"
        case .symlinkEscape(let p): return "Symlink target escapes workspace: \(p)"
        case .io(let m): return m
        case .binaryFile(let p): return "Binary file cannot be edited as text: \(p)"
        case .staleContext(let m): return m
        case .noMatch(let m): return m
        case .ambiguousMatch(let m): return m
        case .invalidInput(let m): return m
        }
    }
}

public enum SessionFS {
    /// Resolve a model path against cwd. Absolute paths are preserved.
    public static func resolve(cwd: String, path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/") {
            return (trimmed as NSString).standardizingPath
        }
        let base = (cwd as NSString).standardizingPath
        return ((base as NSString).appendingPathComponent(trimmed) as NSString).standardizingPath
    }

    /// Reject paths that escape `allowedRoots` when roots are configured.
    ///
    /// Containment is delegated to `PathBoundary`, so traversal, NUL bytes,
    /// case folding, Unicode normalization, and symlink targets that point
    /// outside the root are all rejected. Paths that do not exist yet are
    /// checked lexically (the parent directory is created on write).
    public static func enforceRoots(_ absolute: String, roots: [String]) throws {
        guard !roots.isEmpty else { return }
        let path = (absolute as NSString).standardizingPath
        var sawSymlinkEscape = false
        for root in roots {
            let boundary = PathBoundary(
                root: URL(fileURLWithPath: (root as NSString).standardizingPath)
            )
            do {
                _ = try boundary.resolve(path)
                return
            } catch let error as PathBoundaryError {
                if case .symlinkEscape = error { sawSymlinkEscape = true }
            } catch {
                continue
            }
        }
        if sawSymlinkEscape {
            throw SessionFSError.symlinkEscape(path)
        }
        throw SessionFSError.outsideWorkspace(path)
    }

    public static func readText(at absolute: String) throws -> String {
        let url = URL(fileURLWithPath: absolute)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: absolute, isDirectory: &isDir) else {
            throw SessionFSError.notFound(absolute)
        }
        if isDir.boolValue { throw SessionFSError.isDirectory(absolute) }
        let data = try Data(contentsOf: url)
        if isBinaryData(data) {
            throw SessionFSError.binaryFile(absolute)
        }
        return String(decoding: data, as: UTF8.self)
    }

    public static func readBytes(at absolute: String) throws -> Data {
        let url = URL(fileURLWithPath: absolute)
        guard FileManager.default.fileExists(atPath: absolute) else {
            throw SessionFSError.notFound(absolute)
        }
        return try Data(contentsOf: url)
    }

    public static func fileExists(_ absolute: String) -> Bool {
        FileManager.default.fileExists(atPath: absolute)
    }

    public static func isDirectory(_ absolute: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: absolute, isDirectory: &isDir) && isDir.boolValue
    }

    /// Atomic write under a per-path lock. Records agent hunk only on success.
    public static func writeText(
        absolute: String,
        content: String,
        resources: ToolResources,
        previousContent: String?
    ) async throws {
        try enforceRoots(absolute, roots: resources.allowedRoots)
        let lock = await resources.locks.acquirePath(absolute)
        defer { Task { await lock.release() } }

        let url = URL(fileURLWithPath: absolute)
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        do {
            try AtomicFile.write(url, contents: content, options: AtomicWriteOptions(syncFile: true))
        } catch {
            // Never attribute failed writes.
            throw SessionFSError.io("write failed: \(error.localizedDescription)")
        }

        // Attribution only after successful write.
        if let tracker = resources.hunkTracker {
            await tracker.recordAgentWrite(
                path: absolute,
                content: content,
                promptIndex: resources.promptIndex,
                previousContent: previousContent,
                agentId: resources.agentId,
                writeSucceeded: true
            )
        }
    }

    public static func isBinaryData(_ data: Data) -> Bool {
        // NUL byte in the first 8 KiB → binary (matches common tool heuristics).
        let sample = data.prefix(8 * 1024)
        return sample.contains(0)
    }

    public static func imageMIME(for path: String) -> String? {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        case "bmp": return "image/bmp"
        case "svg": return "image/svg+xml"
        default: return nil
        }
    }
}
