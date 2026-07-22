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

#if canImport(Darwin)
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
        try rejectHostileLexical(path.path)
        #if os(Windows)
        if try isSymlink(path) {
            throw FileUtilsError.symlinkEncountered(path: path.path)
        }
        do {
            return try Data(contentsOf: path)
        } catch {
            throw FileUtilsError.io(path: path.path, detail: error.localizedDescription)
        }
        #else
        let fd = try openFileNoFollow(at: path, flags: O_RDONLY)
        defer { close(fd) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        do {
            return try handle.readToEnd() ?? Data()
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

    #if !os(Windows)
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
