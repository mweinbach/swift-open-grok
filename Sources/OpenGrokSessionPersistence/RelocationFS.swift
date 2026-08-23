// RelocationFS.swift
//
// Durable filesystem operations and path resolution for session relocation.
// Port of `crates/codegen/xai-grok-shell/src/session/storage/relocation/fs.rs`.

import Foundation
import OpenGrokConfig
import OpenGrokPaths
import OpenGrokFileUtils
import OpenGrokShared

#if os(Windows)
import COpenGrokSockets
import WinSDK
#elseif canImport(Darwin)
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
        // Directory durability requires persisting metadata, not a stable-media
        // file flush; F_FULLFSYNC remains reserved for file contents below.
        _ = fsync(fd)
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
        let existingType = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type]
            as? FileAttributeType
        let alreadyExisted = existingType == .typeDirectory
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
        // Only a newly published directory needs a durable parent entry. Still
        // create and restrict existing directories above; skipping that work
        // would permit stale permissions or a changed path type.
        guard !alreadyExisted else { return }
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
            #if os(Windows)
            try writeWindowsOwnerOnlyTemporaryFile(at: tempURL, data: data)
            try replaceWindowsItemDurably(at: path, with: tempURL)
            #else
            try data.write(to: tempURL, options: [.atomic])
            let mode = permissions ?? 0o600
            _ = chmod(tempURL.path, mode_t(mode))
            try syncFile(tempURL)
            try atomicallyReplaceItem(at: path, with: tempURL)
            #endif
            // Rename moves the already-synced inode; only its new directory
            // entry still needs a durability barrier.
            try? syncDirectory(parent)
        } catch {
            #if os(Windows)
            do {
                try removeWindowsTemporaryFileIfPresent(tempURL)
            } catch let cleanupError {
                throw RelocationError.io(
                    operation: "writeAtomicDurable",
                    path: path.path,
                    message: "\(error.localizedDescription); temporary cleanup failed: "
                        + cleanupError.localizedDescription
                )
            }
            #else
            _ = try? FileManager.default.removeItem(at: tempURL)
            #endif
            throw RelocationError.io(operation: "writeAtomicDurable", path: path.path, message: error.localizedDescription)
        }
    }

    #if os(Windows)
    static func windowsExtendedLengthPath(_ rawPath: String) throws -> String {
        let path = rawPath.replacingOccurrences(of: "/", with: "\\")
        guard !path.isEmpty, !path.unicodeScalars.contains("\0") else {
            throw RelocationError.inconsistent("invalid Windows session path: \(rawPath)")
        }

        let extendedPrefix = "\\\\?\\"
        let extendedUNCPrefix = "\\\\?\\UNC\\"
        let uncRemainder: Substring?
        let localPath: String?

        if path.hasPrefix(extendedUNCPrefix) {
            uncRemainder = path.dropFirst(extendedUNCPrefix.count)
            localPath = nil
        } else if path.hasPrefix(extendedPrefix) {
            uncRemainder = nil
            localPath = String(path.dropFirst(extendedPrefix.count))
        } else if path.hasPrefix("\\\\.\\") {
            throw RelocationError.inconsistent("refusing Windows device session path: \(rawPath)")
        } else if path.hasPrefix("\\\\") {
            uncRemainder = path.dropFirst(2)
            localPath = nil
        } else {
            uncRemainder = nil
            localPath = path
        }

        if let uncRemainder {
            let components = uncRemainder.split(separator: "\\", omittingEmptySubsequences: true)
            guard components.count >= 2,
                  !components.contains(where: { $0 == "." || $0 == ".." })
            else {
                throw RelocationError.inconsistent("invalid Windows UNC session path: \(rawPath)")
            }
            return extendedUNCPrefix + components.joined(separator: "\\")
        }

        guard let localPath else {
            throw RelocationError.inconsistent("invalid Windows session path: \(rawPath)")
        }
        let bytes = Array(localPath.utf8)
        let isDriveLetter = bytes.first.map {
            (65...90).contains($0) || (97...122).contains($0)
        } ?? false
        guard bytes.count >= 3, isDriveLetter, bytes[1] == 58, bytes[2] == 92 else {
            throw RelocationError.inconsistent("Windows session path is not absolute: \(rawPath)")
        }

        let components = localPath.dropFirst(3).split(
            separator: "\\",
            omittingEmptySubsequences: true
        )
        guard !components.contains(where: { $0 == "." || $0 == ".." }) else {
            throw RelocationError.inconsistent("Windows session path is not canonical: \(rawPath)")
        }

        return extendedPrefix + String(localPath.prefix(2)) + "\\"
            + components.joined(separator: "\\")
    }

    private static func writeWindowsOwnerOnlyTemporaryFile(at path: URL, data: Data) throws {
        let extendedPath = try windowsExtendedLengthPath(path.standardizedFileURL.path)
        var handle: OGSocketHandle = -1
        let created = extendedPath.withCString { og_file_create_owner_only($0, &handle) }
        guard created == 0 else {
            throw windowsNativeFileError(operation: "create owner-only session temporary", path: path)
        }

        do {
            let secured = extendedPath.withCString { og_file_apply_owner_only($0) }
            guard secured == 0 else {
                throw windowsNativeFileError(operation: "protect session temporary DACL", path: path)
            }

            let ownerOnly = extendedPath.withCString { og_file_is_owner_only($0) }
            guard ownerOnly == 1 else {
                if ownerOnly < 0 {
                    throw windowsNativeFileError(operation: "inspect session temporary DACL", path: path)
                }
                throw RelocationError.io(
                    operation: "inspect session temporary DACL",
                    path: path.path,
                    message: "session temporary is not owner-private"
                )
            }

            let currentUserOwnsFile = extendedPath.withCString {
                og_path_is_private_to_current_user($0, 0)
            }
            guard currentUserOwnsFile == 1 else {
                if currentUserOwnsFile < 0 {
                    throw windowsNativeFileError(operation: "inspect session temporary owner", path: path)
                }
                throw RelocationError.io(
                    operation: "inspect session temporary owner",
                    path: path.path,
                    message: "session temporary does not belong to the current user"
                )
            }

            let written = data.withUnsafeBytes { bytes in
                og_file_handle_write_all(handle, bytes.baseAddress, bytes.count)
            }
            guard written == Int64(data.count) else {
                throw windowsNativeFileError(operation: "write owner-only session temporary", path: path)
            }
            guard og_file_handle_flush(handle) == 0 else {
                throw windowsNativeFileError(operation: "flush owner-only session temporary", path: path)
            }
        } catch {
            guard og_file_handle_close(handle) == 0 else {
                let closeError = windowsNativeFileError(
                    operation: "close failed session temporary",
                    path: path
                )
                throw RelocationError.io(
                    operation: "write owner-only session temporary",
                    path: path.path,
                    message: "\(error.localizedDescription); \(closeError.description)"
                )
            }
            throw error
        }

        guard og_file_handle_close(handle) == 0 else {
            throw windowsNativeFileError(operation: "close owner-only session temporary", path: path)
        }
    }

    private static func removeWindowsTemporaryFileIfPresent(_ path: URL) throws {
        let extendedPath = try windowsExtendedLengthPath(path.standardizedFileURL.path)
        let removed = extendedPath.withCString(encodedAs: UTF16.self) { DeleteFileW($0) }
        if removed { return }

        let code = GetLastError()
        guard code == DWORD(ERROR_FILE_NOT_FOUND) || code == DWORD(ERROR_PATH_NOT_FOUND) else {
            throw RelocationError.io(
                operation: "remove owner-only session temporary",
                path: path.path,
                message: "Windows error \(code)"
            )
        }
    }

    private static func windowsNativeFileError(operation: String, path: URL) -> RelocationError {
        let code = og_socket_last_error_code()
        let detail = String(cString: og_socket_last_error_message())
        return .io(
            operation: operation,
            path: path.path,
            message: detail.isEmpty ? "Windows error \(code)" : detail
        )
    }

    private static func replaceWindowsItemDurably(at destination: URL, with source: URL) throws {
        let sourcePath = try windowsExtendedLengthPath(source.standardizedFileURL.path)
        let destinationPath = try windowsExtendedLengthPath(destination.standardizedFileURL.path)
        let maximumAttempts = 40

        for attempt in 0..<maximumAttempts {
            let moved = sourcePath.withCString(encodedAs: UTF16.self) { sourcePointer in
                destinationPath.withCString(encodedAs: UTF16.self) { destinationPointer in
                    MoveFileExW(
                        sourcePointer,
                        destinationPointer,
                        DWORD(MOVEFILE_REPLACE_EXISTING) | DWORD(MOVEFILE_WRITE_THROUGH)
                    )
                }
            }
            if moved { return }

            let code = GetLastError()
            let isTransientCollision = code == DWORD(ERROR_ACCESS_DENIED)
                || code == DWORD(ERROR_SHARING_VIOLATION)
                || code == DWORD(ERROR_LOCK_VIOLATION)
            if !isTransientCollision || attempt == maximumAttempts - 1 {
                throw RelocationError.io(
                    operation: "MoveFileExW",
                    path: destination.path,
                    message: "Windows error \(code)"
                )
            }
            Sleep(DWORD(min(attempt + 1, 10)))
        }
    }
    #endif

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
