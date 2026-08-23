// CanonicalPath.swift
//
// Canonicalization, no-follow probes, and hostile-path checks for durable
// and security-sensitive writers.
//
// Security contract:
//  * Lexical rejection of empty / NUL / `..` path components before I/O.
//  * Parent directories are opened with O_DIRECTORY|O_NOFOLLOW so a trailing
//    parent symlink cannot redirect writers (system intermediate links such
//    as /var → /private/var are resolved by the kernel path walk).
//  * Final components are opened/created via openat(O_NOFOLLOW) / renameat
//    against that verified parent descriptor — no preflight lstat race.

import Foundation

#if os(Windows)
import COpenGrokSockets
import WinSDK
#elseif canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Path inspection helpers that never silently follow unexpected symlinks.
public enum PathSecurity: Sendable {
    /// Lexically reject hostile path payloads before filesystem I/O.
    ///
    /// Rejects empty paths, embedded NUL bytes, and any `..` path component.
    /// Pair with `canonicalize` or descriptor-relative open for filesystem-
    /// backed resolution. Does not resolve the tree; it is a pure lexical gate.
    public static func rejectHostileLexical(_ path: String) throws {
        if path.isEmpty {
            throw FileUtilsError.hostilePath(path: path, reason: "empty path")
        }
        if path.contains("\0") {
            throw FileUtilsError.hostilePath(path: path, reason: "NUL byte in path")
        }
        // Split on both separators so Windows-style paths are covered on all hosts.
        let parts = path.split(whereSeparator: { $0 == "/" || $0 == "\\" })
        for part in parts {
            if part == ".." {
                throw FileUtilsError.hostilePath(
                    path: path,
                    reason: "path traversal component '..'"
                )
            }
        }
    }

    /// Resolve `path` to a canonical absolute path via `realpath` (Unix) or
    /// Foundation standardization (Windows). Fails if the path does not exist.
    public static func canonicalize(_ path: URL) throws -> URL {
        try rejectHostileLexical(path.path)
        #if os(Windows)
        let standardized = path.standardizedFileURL
        guard FileManager.default.fileExists(atPath: standardized.path) else {
            throw FileUtilsError.notFound(path: path.path)
        }
        return standardized
        #else
        let resolved = path.path.withCString { cstr -> String? in
            guard let buf = realpath(cstr, nil) else { return nil }
            defer { free(buf) }
            return String(cString: buf)
        }
        guard let resolved else {
            if errno == ENOENT {
                throw FileUtilsError.notFound(path: path.path)
            }
            if errno == EACCES || errno == EPERM {
                throw FileUtilsError.permissionDenied(
                    path: path.path,
                    detail: String(cString: strerror(errno))
                )
            }
            throw FileUtilsError.io(
                path: path.path,
                detail: "realpath: \(String(cString: strerror(errno)))"
            )
        }
        return URL(fileURLWithPath: resolved)
        #endif
    }

    /// `true` when the final path component is a symbolic link (`lstat`).
    public static func isSymlink(_ path: URL) throws -> Bool {
        try rejectHostileLexical(path.path)
        #if os(Windows)
        if let values = try? path.resourceValues(forKeys: [.isSymbolicLinkKey]) {
            return values.isSymbolicLink == true
        }
        return false
        #else
        var st = stat()
        let rc = path.path.withCString { lstat($0, &st) }
        if rc != 0 {
            if errno == ENOENT {
                throw FileUtilsError.notFound(path: path.path)
            }
            throw FileUtilsError.io(
                path: path.path,
                detail: "lstat: \(String(cString: strerror(errno)))"
            )
        }
        return (st.st_mode & S_IFMT) == S_IFLNK
        #endif
    }

    /// Open-for-read without following a final-component symlink.
    ///
    /// Opens the parent with `O_DIRECTORY|O_NOFOLLOW` (trailing parent symlink
    /// rejected) and the final name with `openat(O_NOFOLLOW)`.
    public static func readNoFollow(_ path: URL) throws -> Data {
        try readNoFollow(path, maximumBytes: nil, requireOwnerOnly: false)
    }

    /// On Windows, bounds and owner identity are checked against the exact
    /// no-delete-sharing handle from which every byte is subsequently read.
    public static func readNoFollow(
        _ path: URL,
        maximumBytes: Int?,
        requireOwnerOnly: Bool = false
    ) throws -> Data {
        try rejectHostileLexical(path.path)
        if let maximumBytes, maximumBytes < 0 {
            throw FileUtilsError.hostilePath(path: path.path, reason: "negative secure-read byte bound")
        }
        #if os(Windows)
        return try windowsReadNoFollow(
            path,
            maximumBytes: maximumBytes,
            requireOwnerOnly: requireOwnerOnly
        )
        #else
        let fd = try openFileNoFollow(at: path, flags: O_RDONLY)
        defer { close(fd) }
        if maximumBytes != nil || requireOwnerOnly {
            var information = stat()
            guard fstat(fd, &information) == 0 else {
                throw posixMap(path: path.path, op: "fstat")
            }
            if requireOwnerOnly,
               information.st_uid != geteuid() || (information.st_mode & 0o777) != 0o600
            {
                throw FileUtilsError.permissionDenied(
                    path: path.path,
                    detail: "document is not private to the current user"
                )
            }
            if let maximumBytes {
                guard information.st_size >= 0,
                      UInt64(information.st_size) <= UInt64(maximumBytes)
                else {
                    throw FileUtilsError.io(path: path.path, detail: "file exceeds secure-read byte bound")
                }
            }
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        do {
            let bytes = try handle.readToEnd() ?? Data()
            if let maximumBytes, bytes.count > maximumBytes {
                throw FileUtilsError.io(path: path.path, detail: "file exceeds secure-read byte bound")
            }
            return bytes
        } catch let error as FileUtilsError {
            throw error
        } catch {
            throw FileUtilsError.io(path: path.path, detail: error.localizedDescription)
        }
        #endif
    }

    /// Hard-link count for the path (`st_nlink`). Useful for hostile-path
    /// tests; returns 1 on platforms without the probe.
    public static func hardLinkCount(_ path: URL) throws -> UInt {
        #if os(Windows)
        _ = path
        return 1
        #else
        var st = stat()
        let rc = path.path.withCString { lstat($0, &st) }
        if rc != 0 {
            if errno == ENOENT {
                throw FileUtilsError.notFound(path: path.path)
            }
            throw FileUtilsError.io(
                path: path.path,
                detail: "lstat: \(String(cString: strerror(errno)))"
            )
        }
        return UInt(st.st_nlink)
        #endif
    }

    /// Device identifier for cross-device detection (`st_dev`).
    public static func deviceID(_ path: URL) throws -> UInt64 {
        #if os(Windows)
        _ = path
        return 0
        #else
        var st = stat()
        let rc = path.path.withCString { stat($0, &st) }
        if rc != 0 {
            if errno == ENOENT {
                throw FileUtilsError.notFound(path: path.path)
            }
            throw FileUtilsError.io(
                path: path.path,
                detail: "stat: \(String(cString: strerror(errno)))"
            )
        }
        return UInt64(st.st_dev)
        #endif
    }

    // MARK: - Descriptor-relative Unix helpers (internal / @testable)

    #if os(Windows)
    private static func windowsReadNoFollow(
        _ path: URL,
        maximumBytes: Int?,
        requireOwnerOnly: Bool
    ) throws -> Data {
        let native = try WindowsSecurePath.extendedLengthPath(path.path)
        let rawHandle = native.withCString(encodedAs: UTF16.self) { pointer in
            CreateFileW(
                pointer,
                DWORD(GENERIC_READ) | DWORD(READ_CONTROL),
                DWORD(FILE_SHARE_READ) | DWORD(FILE_SHARE_WRITE),
                nil,
                DWORD(OPEN_EXISTING),
                DWORD(FILE_FLAG_OPEN_REPARSE_POINT),
                nil
            )
        }
        guard let handle = rawHandle, handle != INVALID_HANDLE_VALUE else {
            throw WindowsSecurePath.windowsError(
                path: path.path,
                operation: "open no-follow document",
                code: GetLastError()
            )
        }
        defer { CloseHandle(handle) }

        var information = BY_HANDLE_FILE_INFORMATION()
        guard GetFileInformationByHandle(handle, &information) else {
            throw WindowsSecurePath.windowsError(
                path: path.path,
                operation: "inspect no-follow document handle",
                code: GetLastError()
            )
        }
        if information.dwFileAttributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) != 0 {
            throw FileUtilsError.symlinkEncountered(path: path.path)
        }
        guard information.dwFileAttributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) == 0 else {
            throw FileUtilsError.hostilePath(path: path.path, reason: "secure-read target is a directory")
        }

        if requireOwnerOnly {
            try verifyWindowsOwnerPrivate(handle, path: path.path)
        }

        let size = (UInt64(information.nFileSizeHigh) << 32) | UInt64(information.nFileSizeLow)
        guard size <= UInt64(Int.max) else {
            throw FileUtilsError.io(path: path.path, detail: "secure-read file size overflows platform Int")
        }
        if let maximumBytes, size > UInt64(maximumBytes) {
            throw FileUtilsError.io(path: path.path, detail: "file exceeds secure-read byte bound")
        }

        var result = Data()
        result.reserveCapacity(Int(size))
        var chunk = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            var count: DWORD = 0
            let succeeded = chunk.withUnsafeMutableBytes { bytes in
                ReadFile(handle, bytes.baseAddress, DWORD(bytes.count), &count, nil)
            }
            guard succeeded else {
                throw WindowsSecurePath.windowsError(
                    path: path.path,
                    operation: "read no-follow document handle",
                    code: GetLastError()
                )
            }
            if count == 0 {
                if requireOwnerOnly {
                    try verifyWindowsOwnerPrivate(handle, path: path.path)
                }
                return result
            }
            if let maximumBytes, Int(count) > maximumBytes - result.count {
                throw FileUtilsError.io(path: path.path, detail: "file exceeds secure-read byte bound")
            }
            result.append(contentsOf: chunk.prefix(Int(count)))
        }
    }

    private static func verifyWindowsOwnerPrivate(_ handle: HANDLE, path: String) throws {
        let bridged = OGSocketHandle(Int(bitPattern: handle))
        let ownerPrivate = og_file_handle_is_private_to_current_user(bridged, 0)
        guard ownerPrivate == 1 else {
            let detail = String(cString: og_socket_last_error_message())
            throw FileUtilsError.permissionDenied(
                path: path,
                detail: ownerPrivate == 0 ? "document is not private to the current user"
                    : "same-handle owner verification failed: \(detail)"
            )
        }
    }
    #else
    /// Open a directory. Trailing symlink components are rejected (`O_NOFOLLOW`).
    /// Returns an owned file descriptor; caller must `close`.
    static func openDirectoryNoFollow(at path: URL) throws -> Int32 {
        try rejectHostileLexical(path.path)
        var flags: Int32 = O_RDONLY | O_DIRECTORY | O_NOFOLLOW
        #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
        flags |= O_CLOEXEC
        #endif
        let fd = path.path.withCString { open($0, flags) }
        guard fd >= 0 else {
            throw mapOpenError(path: path.path, code: errno)
        }
        return fd
    }

    /// Open a file by opening the parent with `O_DIRECTORY|O_NOFOLLOW` and the
    /// final component with `flags | O_NOFOLLOW` via `openat`. Returns owned fd.
    static func openFileNoFollow(at path: URL, flags: Int32) throws -> Int32 {
        try rejectHostileLexical(path.path)
        let parent = path.deletingLastPathComponent()
        let name = path.lastPathComponent
        guard !name.isEmpty, name != "/", name != "..", name != "." else {
            throw FileUtilsError.hostilePath(path: path.path, reason: "invalid final component")
        }
        // Root path edge case: parent may equal path for "/".
        let dirPath: URL
        if parent.path.isEmpty || parent.path == path.path {
            dirPath = URL(fileURLWithPath: "/")
        } else {
            dirPath = parent
        }
        let dirFD = try openDirectoryNoFollow(at: dirPath)
        defer { close(dirFD) }
        var finalFlags = flags | O_NOFOLLOW
        #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
        finalFlags |= O_CLOEXEC
        #endif
        let fd = name.withCString { openat(dirFD, $0, finalFlags) }
        guard fd >= 0 else {
            throw mapOpenError(path: path.path, code: errno)
        }
        return fd
    }

    /// Rename within a verified parent directory descriptor (`renameat`).
    static func renameNoFollow(
        directoryFD: Int32,
        from name: String,
        to finalName: String,
        directoryPath: String
    ) throws {
        let rc = name.withCString { src in
            finalName.withCString { dst in
                renameat(directoryFD, src, directoryFD, dst)
            }
        }
        if rc != 0 {
            if errno == EXDEV {
                throw FileUtilsError.crossDevice(
                    source: "\(directoryPath)/\(name)",
                    destination: "\(directoryPath)/\(finalName)"
                )
            }
            if errno == ELOOP {
                throw FileUtilsError.symlinkEncountered(
                    path: "\(directoryPath)/\(finalName)"
                )
            }
            throw posixMap(path: "\(directoryPath)/\(finalName)", op: "renameat")
        }
    }

    /// Open the parent directory of `path` with no-follow trailing semantics
    /// and return `(dirFD, finalComponentName)`. Caller owns `dirFD`.
    static func openParentDirectoryNoFollow(
        of path: URL
    ) throws -> (dirFD: Int32, name: String) {
        try rejectHostileLexical(path.path)
        let parent = path.deletingLastPathComponent()
        let name = path.lastPathComponent
        guard !name.isEmpty, name != "/", name != "..", name != "." else {
            throw FileUtilsError.hostilePath(path: path.path, reason: "missing final component")
        }
        let dirFD = try openDirectoryNoFollow(at: parent)
        return (dirFD, name)
    }

    private static func mapOpenError(path: String, code: Int32) -> FileUtilsError {
        if code == ELOOP {
            return .symlinkEncountered(path: path)
        }
        if code == ENOENT {
            return .notFound(path: path)
        }
        if code == EACCES || code == EPERM {
            return .permissionDenied(
                path: path,
                detail: String(cString: strerror(code))
            )
        }
        if code == ENOTDIR {
            return .io(path: path, detail: "not a directory")
        }
        return .io(path: path, detail: "open: \(String(cString: strerror(code)))")
    }
    #endif
}

#if !os(Windows)
func posixMap(path: String, op: String, code: Int32 = errno) -> FileUtilsError {
    let detail = String(cString: strerror(code))
    if code == ENOENT {
        return .notFound(path: path)
    }
    if code == EACCES || code == EPERM {
        return .permissionDenied(path: path, detail: "\(op): \(detail)")
    }
    if code == ELOOP {
        return .symlinkEncountered(path: path)
    }
    if code == EXDEV {
        return .crossDevice(source: path, destination: path)
    }
    return .io(path: path, detail: "\(op): \(detail)")
}
#endif
