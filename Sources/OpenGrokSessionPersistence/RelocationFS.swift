// RelocationFS.swift
//
// Durable filesystem operations and path resolution for session relocation.
// Port of `crates/codegen/xai-grok-shell/src/session/storage/relocation/fs.rs`.

import Foundation
import OpenGrokConfig
import OpenGrokPaths
import OpenGrokFileUtils
import OpenGrokShared

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum RelocationFS: Sendable {
    public static let relocationsDirName = "relocations"
    public static let sessionsDirName = "sessions"
    public static let summaryFileName = "summary.json"

    // MARK: - Path Resolution

    public static func defaultGrokHome() -> URL {
        OpenGrokStatePaths.stateDirectory(environment: ProcessInfo.processInfo.environment)
    }

    public static func relocationsDir(grokHome: URL) -> URL {
        grokHome.appendingPathComponent(relocationsDirName, isDirectory: true)
    }

    public static func journalPath(grokHome: URL, sessionID: String) -> URL {
        relocationsDir(grokHome: grokHome).appendingPathComponent("\(sessionID).json")
    }

    public static func lockPath(grokHome: URL, sessionID: String) -> URL {
        relocationsDir(grokHome: grokHome).appendingPathComponent("\(sessionID).lock")
    }

    public static func sessionsDir(grokHome: URL) -> URL {
        grokHome.appendingPathComponent(sessionsDirName, isDirectory: true)
    }

    public static func sessionDirAt(grokHome: URL, cwd: String, sessionID: String) -> URL {
        sessionsDir(grokHome: grokHome)
            .appendingPathComponent(encodeCwdDirname(cwd), isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
    }

    public static func stagingName(sessionID: String, nonce: String) -> String {
        ".\(sessionID).relocating-\(nonce)"
    }

    public static func stagingDirAt(grokHome: URL, targetCWD: String, sessionID: String, nonce: String) -> URL {
        sessionsDir(grokHome: grokHome)
            .appendingPathComponent(encodeCwdDirname(targetCWD), isDirectory: true)
            .appendingPathComponent(stagingName(sessionID: sessionID, nonce: nonce), isDirectory: true)
    }

    // MARK: - CWD Encoding

    /// Encode a CWD string into a filesystem-safe directory name component.
    public static func encodeCwdDirname(_ cwd: String) -> String {
        OpenGrokConfig.encodeCwdDirname(cwd)
    }

    public static func urlEncodePath(_ s: String) -> String {
        OpenGrokPaths.urlEncodePath(s)
    }

    // MARK: - Validation

    public static func validateComponent(field: String, value: String) throws {
        if value.isEmpty
            || value == "."
            || value == ".."
            || value.contains("/")
            || value.contains("\\")
        {
            throw RelocationError.invalidComponent(field: field, value: value)
        }
    }

    public static func validateCWD(field: String, value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || !isAbsolutePath(trimmed) {
            throw RelocationError.invalidCWD(field: field, value: value)
        }
    }

    // MARK: - Directory and File Sync

    public static func syncDirectory(_ url: URL) throws {
        #if !os(Windows)
        let path = url.path
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else {
            let err = errno
            if err == ENOENT { return }
            throw RelocationError.io(operation: "syncDirectory.open", path: path, message: String(cString: strerror(err)))
        }
        defer { close(fd) }
        #if os(macOS)
        _ = fcntl(fd, F_FULLFSYNC)
        #else
        _ = fsync(fd)
        #endif
        #endif
    }

    public static func syncFile(_ url: URL) throws {
        #if !os(Windows)
        let path = url.path
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else {
            let err = errno
            if err == ENOENT { return }
            throw RelocationError.io(operation: "syncFile.open", path: path, message: String(cString: strerror(err)))
        }
        defer { close(fd) }
        #if os(macOS)
        _ = fcntl(fd, F_FULLFSYNC)
        #else
        _ = fsync(fd)
        #endif
        #endif
    }

    // MARK: - Durable Creation and Removal

    public static func createDirectoryDurable(_ url: URL) throws {
        #if !os(Windows)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        _ = chmod(url.path, S_IRWXU)
        #else
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        #endif
        let parent = url.deletingLastPathComponent()
        try? syncDirectory(parent)
        try? syncDirectory(url)
    }

    public static func removeDirectoryDurable(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw RelocationError.io(operation: "removeDirectory", path: url.path, message: error.localizedDescription)
        }
        let parent = url.deletingLastPathComponent()
        try? syncDirectory(parent)
    }

    public static func requireDirectory(_ url: URL) throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            throw RelocationError.inconsistent("expected directory at \(url.path)")
        }
        // Verify not a symlink
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        if let type = attrs?[.type] as? FileAttributeType, type == .typeSymbolicLink {
            throw RelocationError.inconsistent("expected real directory, got symlink at \(url.path)")
        }
    }

    public static func requireRegularFile(_ url: URL) throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
            throw RelocationError.inconsistent("expected regular file at \(url.path)")
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        if let type = attrs?[.type] as? FileAttributeType, type == .typeSymbolicLink {
            throw RelocationError.inconsistent("expected regular file, got symlink at \(url.path)")
        }
    }

    // MARK: - Atomic Durable File Writing

    public static func writeAtomicDurable(path: URL, data: Data, permissions: UInt16? = nil) throws {
        let parent = path.deletingLastPathComponent()
        try createDirectoryDurable(parent)

        let tempURL = parent.appendingPathComponent(".\(path.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: tempURL, options: [.atomic])
            #if !os(Windows)
            let mode = permissions ?? 0o600
            _ = chmod(tempURL.path, mode_t(mode))
            #endif
            try syncFile(tempURL)

            try atomicallyReplaceItem(at: path, with: tempURL)
            try? syncFile(path)
            try? syncDirectory(parent)
        } catch {
            _ = try? FileManager.default.removeItem(at: tempURL)
            throw RelocationError.io(operation: "writeAtomicDurable", path: path.path, message: error.localizedDescription)
        }
    }

    // MARK: - Atomic Publication (No-Replace)

    public static func publishNoReplace(source: URL, target: URL) throws {
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw RelocationError.inconsistent("source directory missing for publication: \(source.path)")
        }
        if FileManager.default.fileExists(atPath: target.path) {
            throw RelocationError.collision(path: target.path)
        }

        #if os(macOS)
        let ret = renamex_np(source.path, target.path, UInt32(RENAME_EXCL))
        if ret != 0 {
            let err = errno
            if err == EEXIST {
                throw RelocationError.collision(path: target.path)
            }
            // Fallback if filesystem does not support renamex_np
            do {
                try FileManager.default.moveItem(at: source, to: target)
            } catch {
                throw RelocationError.io(operation: "publishNoReplace", path: target.path, message: error.localizedDescription)
            }
        }
        #else
        do {
            try FileManager.default.moveItem(at: source, to: target)
        } catch {
            if FileManager.default.fileExists(atPath: target.path) {
                throw RelocationError.collision(path: target.path)
            }
            throw RelocationError.io(operation: "publishNoReplace", path: target.path, message: error.localizedDescription)
        }
        #endif

        let targetParent = target.deletingLastPathComponent()
        try? syncDirectory(targetParent)
        try? syncDirectory(target)
    }

    // MARK: - Directory Copy

    public static func copyDirectory(source: URL, target: URL) throws {
        try requireDirectory(source)

        let sourceStandard = source.standardizedFileURL.path
        let targetStandard = target.standardizedFileURL.path
        if targetStandard == sourceStandard || targetStandard.hasPrefix(sourceStandard + "/") {
            throw RelocationError.inconsistent("copy target must not equal or be nested under source: \(target.path)")
        }

        if FileManager.default.fileExists(atPath: target.path) {
            throw RelocationError.collision(path: target.path)
        }

        try createDirectoryDurable(target)
        try copyDirectoryContents(source: source, target: target)
        try? syncDirectory(target)
    }

    private static func copyDirectoryContents(source: URL, target: URL) throws {
        let contents = try FileManager.default.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
            options: []
        )

        for item in contents {
            let itemName = item.lastPathComponent
            let destItem = target.appendingPathComponent(itemName)

            let attrs = try FileManager.default.attributesOfItem(atPath: item.path)
            guard let fileType = attrs[FileAttributeKey.type] as? FileAttributeType else {
                throw RelocationError.inconsistent("unsupported entry: \(item.path)")
            }

            if fileType == FileAttributeType.typeDirectory {
                try createDirectoryDurable(destItem)
                try copyDirectoryContents(source: item, target: destItem)
                #if !os(Windows)
                if let perms = attrs[FileAttributeKey.posixPermissions] as? NSNumber {
                    _ = chmod(destItem.path, mode_t(perms.uint32Value))
                }
                #endif
                try? syncDirectory(destItem)
            } else if fileType == FileAttributeType.typeRegular {
                try FileManager.default.copyItem(at: item, to: destItem)
                #if !os(Windows)
                if let perms = attrs[FileAttributeKey.posixPermissions] as? NSNumber {
                    _ = chmod(destItem.path, mode_t(perms.uint32Value))
                }
                #endif
                try? syncFile(destItem)
            } else if fileType == FileAttributeType.typeSymbolicLink {
                let dest = try FileManager.default.destinationOfSymbolicLink(atPath: item.path)
                try FileManager.default.createSymbolicLink(atPath: destItem.path, withDestinationPath: dest)
            } else {
                // Reject FIFO, socket, device special files
                throw RelocationError.inconsistent("unsupported special file in session directory: \(item.path)")
            }
        }
    }
}
