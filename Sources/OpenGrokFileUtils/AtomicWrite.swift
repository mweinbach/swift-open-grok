// AtomicWrite.swift
//
// Atomic temp + fsync + rename primitives for durable persistence.
// Semantics align with `xai-grok-config::fs_atomic::write_atomically` and the
// durable JSONL / trust / checkpoint patterns (write, sync_all, rename,
// parent-dir fsync). Cross-device renames surface as
// `FileUtilsError.crossDevice`.
//
// When `noFollowFinal` is set, every path component is opened with
// O_NOFOLLOW via openat and replacement uses renameat against a verified
// parent directory descriptor — no preflight lstat race.

import Foundation

#if os(Windows)
import COpenGrokSockets
import WinSDK
#endif

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(ucrt)
import ucrt
#endif

/// Process-wide write nonce for unique temp-file names.
private final class WriteNonce: @unchecked Sendable {
    static let shared = WriteNonce()
    private var value: UInt64 = 0
    private let lock = NSLock()
    func next() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        value &+= 1
        return value
    }
}

/// Options for an atomic write.
public struct AtomicWriteOptions: Sendable, Equatable {
    /// Optional Unix permission mode applied to the temp file before rename
    /// (e.g. `0o600`). Ignored on Windows; the final file never exists with
    /// looser permissions than requested on Unix.
    public var mode: UInt32?
    /// When true (default), `fsync` the temp file before rename.
    public var syncFile: Bool
    /// Parent-directory durability after rename. Default `.required` so a
    /// successful return means directory metadata was persisted (or the
    /// platform has no directory fsync primitive).
    public var directorySync: DirectorySyncPolicy
    /// When true, refuse to follow symlinks for every path component and
    /// perform creation/replacement through verified directory descriptors.
    public var noFollowFinal: Bool

    public init(
        mode: UInt32? = nil,
        syncFile: Bool = true,
        directorySync: DirectorySyncPolicy = .required,
        noFollowFinal: Bool = false
    ) {
        self.mode = mode
        self.syncFile = syncFile
        self.directorySync = directorySync
        self.noFollowFinal = noFollowFinal
    }

    /// Back-compat initializer using a Bool for directory sync.
    /// `true` → `.required`, `false` → `.none`.
    public init(
        mode: UInt32? = nil,
        syncFile: Bool = true,
        syncDirectory: Bool,
        noFollowFinal: Bool = false
    ) {
        self.mode = mode
        self.syncFile = syncFile
        self.directorySync = syncDirectory ? .required : .none
        self.noFollowFinal = noFollowFinal
    }

    /// Owner-only credentials-style write (`0o600`, full durability, no-follow).
    public static let ownerOnly = AtomicWriteOptions(
        mode: 0o600,
        syncFile: true,
        directorySync: .required,
        noFollowFinal: true
    )
}

/// Atomic file write utilities.
public enum AtomicFile: Sendable {
    /// Write UTF-8 text atomically (temp + optional fsync + rename).
    public static func write(
        _ finalPath: URL,
        contents: String,
        options: AtomicWriteOptions = AtomicWriteOptions()
    ) throws {
        try write(finalPath, data: Data(contents.utf8), options: options)
    }

    /// Write raw bytes atomically.
    public static func write(
        _ finalPath: URL,
        data: Data,
        options: AtomicWriteOptions = AtomicWriteOptions()
    ) throws {
        try PathSecurity.rejectHostileLexical(finalPath.path)

        if options.noFollowFinal {
            try writeNoFollow(finalPath, data: data, options: options)
            return
        }

        try ensureParentDirectory(of: finalPath)

        let dir = finalPath.deletingLastPathComponent()
        let name = finalPath.lastPathComponent.isEmpty ? "file" : finalPath.lastPathComponent
        let pid = UInt64(ProcessInfo.processInfo.processIdentifier)
        let nonce = WriteNonce.shared.next()
        let tmp = dir.appendingPathComponent("\(name).\(pid).\(nonce).tmp")

        try createExclusiveFile(at: tmp, mode: options.mode)
        do {
            let handle = try FileHandle(forWritingTo: tmp)
            defer { try? handle.close() }
            try handle.write(contentsOf: data)
            if options.syncFile {
                try handle.synchronize()
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw FileUtilsError.io(path: tmp.path, detail: error.localizedDescription)
        }

        if let mode = options.mode {
            try applyUnixMode(mode, to: tmp)
        }

        do {
            try renameReplacing(tmp, to: finalPath)
        } catch let err as FileUtilsError {
            try? FileManager.default.removeItem(at: tmp)
            throw err
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw mapRenameError(source: tmp.path, destination: finalPath.path, error: error)
        }

        try applyDirectorySync(dir, policy: options.directorySync)
    }

    /// Atomically rename `source` over `destination` on the same filesystem.
    public static func rename(
        _ source: URL,
        to destination: URL,
        directorySync: DirectorySyncPolicy = .required
    ) throws {
        try PathSecurity.rejectHostileLexical(source.path)
        try PathSecurity.rejectHostileLexical(destination.path)
        try ensureParentDirectory(of: destination)
        do {
            try renameReplacing(source, to: destination)
        } catch let err as FileUtilsError {
            throw err
        } catch {
            throw mapRenameError(source: source.path, destination: destination.path, error: error)
        }
        try applyDirectorySync(
            destination.deletingLastPathComponent(),
            policy: directorySync
        )
    }

    /// Back-compat rename with Bool directory sync.
    public static func rename(
        _ source: URL,
        to destination: URL,
        syncDirectory: Bool
    ) throws {
        try rename(
            source,
            to: destination,
            directorySync: syncDirectory ? .required : .none
        )
    }

    /// `fsync` a file path (opens read-write if needed).
    public static func fsyncFile(at path: URL) throws {
        #if os(Windows)
        let handle = try FileHandle(forUpdating: path)
        defer { try? handle.close() }
        try handle.synchronize()
        #else
        let fd = path.path.withCString { open($0, O_RDONLY) }
        guard fd >= 0 else {
            throw posixError(path: path.path, op: "open for fsync")
        }
        defer { close(fd) }
        if fsync(fd) != 0 {
            throw posixError(path: path.path, op: "fsync")
        }
        #endif
    }

    /// `fsync` a directory. Failures always surface (callers choose policy).
    public static func fsyncDirectory(at dir: URL) throws {
        try fsyncDirectoryRequired(dir)
    }
}

// MARK: - No-follow atomic write (Unix)

#if !os(Windows)
private func writeNoFollow(
    _ finalPath: URL,
    data: Data,
    options: AtomicWriteOptions
) throws {
    // Ensure parents exist without following intermediate symlinks.
    try ensureParentDirectoryNoFollow(of: finalPath)

    let parent = finalPath.deletingLastPathComponent()
    let finalName = finalPath.lastPathComponent
    guard !finalName.isEmpty, finalName != "..", finalName != "." else {
        throw FileUtilsError.hostilePath(
            path: finalPath.path,
            reason: "invalid final component"
        )
    }

    let dirFD = try PathSecurity.openDirectoryNoFollow(at: parent)
    defer { close(dirFD) }

    let pid = UInt64(ProcessInfo.processInfo.processIdentifier)
    let nonce = WriteNonce.shared.next()
    let tmpName = "\(finalName).\(pid).\(nonce).tmp"
    let fileMode: mode_t = mode_t(options.mode ?? 0o600)

    // Create exclusive temp via openat(O_NOFOLLOW|O_CREAT|O_EXCL).
    let tmpFD = tmpName.withCString { name in
        openat(dirFD, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, fileMode)
    }
    guard tmpFD >= 0 else {
        throw posixMap(path: parent.appendingPathComponent(tmpName).path, op: "openat create")
    }

    var tmpClosed = false
    do {
        // Write + optional fsync through the descriptor (no path re-open).
        try writeAll(fd: tmpFD, data: data, path: parent.appendingPathComponent(tmpName).path)
        if options.syncFile {
            if fsync(tmpFD) != 0 {
                throw posixMap(
                    path: parent.appendingPathComponent(tmpName).path,
                    op: "fsync"
                )
            }
        }
        // Re-assert mode via fchmod (never follows a symlink).
        if fchmod(tmpFD, fileMode) != 0 {
            throw posixMap(
                path: parent.appendingPathComponent(tmpName).path,
                op: "fchmod"
            )
        }
        close(tmpFD)
        tmpClosed = true
    } catch {
        if !tmpClosed {
            close(tmpFD)
        }
        _ = tmpName.withCString { unlinkat(dirFD, $0, 0) }
        throw error
    }

    do {
        try PathSecurity.renameNoFollow(
            directoryFD: dirFD,
            from: tmpName,
            to: finalName,
            directoryPath: parent.path
        )
    } catch {
        _ = tmpName.withCString { unlinkat(dirFD, $0, 0) }
        throw error
    }

    try applyDirectorySyncFD(dirFD, path: parent.path, policy: options.directorySync)
}

private func ensureParentDirectoryNoFollow(of path: URL) throws {
    let parent = path.deletingLastPathComponent()
    guard !parent.path.isEmpty else { return }
    // Create intermediate directories, then verify a no-follow open succeeds.
    // mkdir(2) on an existing symlink-to-dir yields EEXIST; the subsequent
    // openat(O_NOFOLLOW) rejects that symlink.
    do {
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    } catch {
        // May already exist; fall through to open verification.
    }
    let fd = try PathSecurity.openDirectoryNoFollow(at: parent)
    close(fd)
}

private func applyDirectorySyncFD(
    _ dirFD: Int32,
    path: String,
    policy: DirectorySyncPolicy
) throws {
    switch policy {
    case .none:
        return
    case .bestEffort:
        _ = fsync(dirFD)
    case .required:
        if fsync(dirFD) != 0 {
            throw FileUtilsError.directorySyncFailed(
                path: path,
                detail: String(cString: strerror(errno))
            )
        }
    }
}
#else
private func writeNoFollow(
    _ finalPath: URL,
    data: Data,
    options: AtomicWriteOptions
) throws {
    let parent = finalPath.deletingLastPathComponent().standardizedFileURL
    let finalName = finalPath.lastPathComponent
    guard !finalName.isEmpty, finalName != "..", finalName != "." else {
        throw FileUtilsError.hostilePath(
            path: finalPath.path,
            reason: "invalid final component"
        )
    }

    let directoryHandles = try windowsPrepareDirectoriesNoFollow(parent)
    defer {
        for handle in directoryHandles.reversed() {
            CloseHandle(handle)
        }
    }

    try windowsRejectReparsePoint(at: finalPath, allowMissing: true)

    let pid = UInt64(ProcessInfo.processInfo.processIdentifier)
    let nonce = WriteNonce.shared.next()
    let tmp = parent.appendingPathComponent("\(finalName).\(pid).\(nonce).tmp")
    do {
        try windowsCreateAndWriteTemp(tmp, data: data, options: options)

        try windowsRejectReparsePoint(at: finalPath, allowMissing: true)
        try renameReplacing(tmp, to: finalPath)
        try applyDirectorySync(parent, policy: options.directorySync)
    } catch {
        try? FileManager.default.removeItem(at: tmp)
        throw error
    }
}

private func windowsCreateAndWriteTemp(
    _ path: URL,
    data: Data,
    options: AtomicWriteOptions
) throws {
    if options.mode == 0o600 {
        var handle: OGSocketHandle = -1
        let created = path.path.withCString { pointer in
            og_file_create_owner_only(pointer, &handle)
        }
        guard created == 0 else {
            throw windowsNativeFileError(path: path.path, operation: "create owner-only temp")
        }
        var closed = false
        defer {
            if !closed { _ = og_file_handle_close(handle) }
        }
        let count = data.withUnsafeBytes { bytes in
            og_file_handle_write_all(handle, bytes.baseAddress, bytes.count)
        }
        guard count == data.count else {
            throw windowsNativeFileError(path: path.path, operation: "write owner-only temp")
        }
        if options.syncFile, og_file_handle_flush(handle) != 0 {
            throw windowsNativeFileError(path: path.path, operation: "flush owner-only temp")
        }
        guard og_file_handle_close(handle) == 0 else {
            throw windowsNativeFileError(path: path.path, operation: "close owner-only temp")
        }
        closed = true
        return
    }

    let rawHandle = path.path.withCString(encodedAs: UTF16.self) { pointer in
        CreateFileW(
            pointer,
            DWORD(GENERIC_WRITE),
            DWORD(FILE_SHARE_READ),
            nil,
            DWORD(CREATE_NEW),
            DWORD(FILE_ATTRIBUTE_TEMPORARY | FILE_FLAG_OPEN_REPARSE_POINT),
            nil
        )
    }
    guard let handle = rawHandle, handle != INVALID_HANDLE_VALUE else {
        throw windowsFileError(path: path.path, operation: "create exclusive temp")
    }
    defer { CloseHandle(handle) }
    try windowsWriteAll(handle: handle, data: data, path: path.path)
    if options.syncFile, !FlushFileBuffers(handle) {
        throw windowsFileError(path: path.path, operation: "flush temp")
    }
}

private func windowsNativeFileError(path: String, operation: String) -> FileUtilsError {
    let code = Int(og_socket_last_error_code())
    let detail = String(cString: og_socket_last_error_message())
    return .io(
        path: path,
        detail: "\(operation): \(detail.isEmpty ? "Windows error \(code)" : detail)"
    )
}

private func windowsPrepareDirectoriesNoFollow(_ directory: URL) throws -> [HANDLE] {
    let prefixes = try windowsDirectoryPrefixes(directory.path)
    var handles: [HANDLE] = []
    do {
        for (index, path) in prefixes.enumerated() {
            if index > 0 {
                let created = path.withCString(encodedAs: UTF16.self) { pointer in
                    CreateDirectoryW(pointer, nil)
                }
                if !created {
                    let code = GetLastError()
                    guard code == DWORD(ERROR_ALREADY_EXISTS) else {
                        throw windowsFileError(
                            path: path,
                            operation: "create parent directory",
                            code: code
                        )
                    }
                }
            }
            handles.append(try windowsOpenDirectoryNoFollow(path))
        }
        return handles
    } catch {
        for handle in handles.reversed() {
            CloseHandle(handle)
        }
        throw error
    }
}

private func windowsDirectoryPrefixes(_ path: String) throws -> [String] {
    let normalized = path.replacingOccurrences(of: "/", with: "\\")
    if normalized.hasPrefix("\\\\") {
        let components = normalized.dropFirst(2).split(separator: "\\", omittingEmptySubsequences: true)
        guard components.count >= 2 else {
            throw FileUtilsError.hostilePath(path: path, reason: "invalid UNC path")
        }
        var current = "\\\\\(components[0])\\\(components[1])\\"
        var result = [current]
        for component in components.dropFirst(2) {
            current += "\(component)\\"
            result.append(String(current.dropLast()))
        }
        return result
    }

    guard normalized.count >= 3 else {
        throw FileUtilsError.hostilePath(path: path, reason: "path is not absolute")
    }
    let driveEnd = normalized.index(normalized.startIndex, offsetBy: 2)
    guard normalized[normalized.index(after: normalized.startIndex)] == ":",
          normalized[driveEnd] == "\\"
    else {
        throw FileUtilsError.hostilePath(path: path, reason: "path is not absolute")
    }

    let rootEnd = normalized.index(after: driveEnd)
    var current = String(normalized[..<rootEnd])
    var result = [current]
    let remainder = normalized[rootEnd...]
    for component in remainder.split(separator: "\\", omittingEmptySubsequences: true) {
        if !current.hasSuffix("\\") { current += "\\" }
        current += component
        result.append(current)
    }
    return result
}

private func windowsOpenDirectoryNoFollow(_ path: String) throws -> HANDLE {
    let rawHandle = path.withCString(encodedAs: UTF16.self) { pointer in
        CreateFileW(
            pointer,
            DWORD(FILE_READ_ATTRIBUTES),
            DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE),
            nil,
            DWORD(OPEN_EXISTING),
            DWORD(FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT),
            nil
        )
    }
    guard let handle = rawHandle, handle != INVALID_HANDLE_VALUE else {
        throw windowsFileError(path: path, operation: "open parent directory")
    }
    var information = BY_HANDLE_FILE_INFORMATION()
    guard GetFileInformationByHandle(handle, &information) else {
        let error = windowsFileError(path: path, operation: "inspect parent directory")
        CloseHandle(handle)
        throw error
    }
    let attributes = information.dwFileAttributes
    guard attributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0 else {
        CloseHandle(handle)
        throw FileUtilsError.symlinkEncountered(path: path)
    }
    guard attributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0 else {
        CloseHandle(handle)
        throw FileUtilsError.hostilePath(path: path, reason: "parent component is not a directory")
    }
    return handle
}

private func windowsRejectReparsePoint(at path: URL, allowMissing: Bool) throws {
    let rawHandle = path.path.withCString(encodedAs: UTF16.self) { pointer in
        CreateFileW(
            pointer,
            DWORD(FILE_READ_ATTRIBUTES),
            DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE),
            nil,
            DWORD(OPEN_EXISTING),
            DWORD(FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT),
            nil
        )
    }
    guard let handle = rawHandle, handle != INVALID_HANDLE_VALUE else {
        let code = GetLastError()
        if allowMissing, code == DWORD(ERROR_FILE_NOT_FOUND) || code == DWORD(ERROR_PATH_NOT_FOUND) {
            return
        }
        throw windowsFileError(path: path.path, operation: "inspect final path", code: code)
    }
    defer { CloseHandle(handle) }
    var information = BY_HANDLE_FILE_INFORMATION()
    guard GetFileInformationByHandle(handle, &information) else {
        throw windowsFileError(path: path.path, operation: "inspect final path")
    }
    let attributes = information.dwFileAttributes
    if attributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) != 0 {
        throw FileUtilsError.symlinkEncountered(path: path.path)
    }
    if attributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0 {
        throw FileUtilsError.hostilePath(path: path.path, reason: "final component is a directory")
    }
}

private func windowsWriteAll(handle: HANDLE, data: Data, path: String) throws {
    try data.withUnsafeBytes { buffer in
        guard let base = buffer.baseAddress else { return }
        var offset = 0
        while offset < buffer.count {
            let remaining = min(buffer.count - offset, Int(UInt32.max))
            var written: DWORD = 0
            let succeeded = WriteFile(
                handle,
                base + offset,
                DWORD(remaining),
                &written,
                nil
            )
            guard succeeded, written > 0 else {
                throw windowsFileError(path: path, operation: "write temp")
            }
            offset += Int(written)
        }
    }
}

private func windowsFileError(
    path: String,
    operation: String,
    code: DWORD = GetLastError()
) -> FileUtilsError {
    if code == DWORD(ERROR_ACCESS_DENIED) {
        return .permissionDenied(path: path, detail: "\(operation): Windows error \(code)")
    }
    if code == DWORD(ERROR_FILE_NOT_FOUND) || code == DWORD(ERROR_PATH_NOT_FOUND) {
        return .notFound(path: path)
    }
    return .io(path: path, detail: "\(operation): Windows error \(code)")
}
#endif

// MARK: - Internals

private func ensureParentDirectory(of path: URL) throws {
    let parent = path.deletingLastPathComponent()
    guard !parent.path.isEmpty else { return }
    // Reject traversal before creating arbitrary trees.
    try PathSecurity.rejectHostileLexical(parent.path)
    do {
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: nil
        )
    } catch {
        throw FileUtilsError.io(path: parent.path, detail: error.localizedDescription)
    }
}

private func createExclusiveFile(at path: URL, mode: UInt32?) throws {
    #if os(Windows)
    do {
        try Data().write(to: path, options: [.withoutOverwriting])
    } catch {
        throw FileUtilsError.io(path: path.path, detail: error.localizedDescription)
    }
    _ = mode
    #else
    var flags: Int32 = O_WRONLY | O_CREAT | O_EXCL
    #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
    flags |= O_NOFOLLOW
    #endif
    let fileMode: mode_t = mode_t(mode ?? 0o600)
    let fd = path.path.withCString { open($0, flags, fileMode) }
    guard fd >= 0 else {
        throw posixError(path: path.path, op: "create exclusive temp")
    }
    close(fd)
    #endif
}

private func applyUnixMode(_ mode: UInt32, to path: URL) throws {
    #if os(Windows)
    _ = mode
    _ = path
    #else
    // Use O_NOFOLLOW open + fchmod so a raced symlink is not chmod'd.
    var flags: Int32 = O_WRONLY
    #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(Linux)
    flags |= O_NOFOLLOW
    #endif
    let fd = path.path.withCString { open($0, flags) }
    guard fd >= 0 else {
        if errno == ELOOP {
            throw FileUtilsError.symlinkEncountered(path: path.path)
        }
        throw posixError(path: path.path, op: "open for fchmod")
    }
    defer { close(fd) }
    if fchmod(fd, mode_t(mode)) != 0 {
        throw posixError(path: path.path, op: "fchmod")
    }
    #endif
}

private func renameReplacing(_ source: URL, to destination: URL) throws {
    #if os(Windows)
    let maximumAttempts = 40
    for attempt in 0..<maximumAttempts {
        let moved = source.path.withCString(encodedAs: UTF16.self) { sourcePointer in
            destination.path.withCString(encodedAs: UTF16.self) { destinationPointer in
                MoveFileExW(
                    sourcePointer,
                    destinationPointer,
                    DWORD(MOVEFILE_REPLACE_EXISTING) | DWORD(MOVEFILE_WRITE_THROUGH)
                )
            }
        }
        if moved { return }

        let code = GetLastError()
        if code == DWORD(ERROR_NOT_SAME_DEVICE) {
            throw FileUtilsError.crossDevice(source: source.path, destination: destination.path)
        }
        let isTransientCollision = code == DWORD(ERROR_ACCESS_DENIED)
            || code == DWORD(ERROR_SHARING_VIOLATION)
            || code == DWORD(ERROR_LOCK_VIOLATION)
        if !isTransientCollision || attempt == maximumAttempts - 1 {
            throw FileUtilsError.io(path: destination.path, detail: "Windows error \(code)")
        }
        Sleep(DWORD(min(attempt + 1, 10)))
    }
    #else
    let rc = source.path.withCString { src in
        destination.path.withCString { dst in
            rename(src, dst)
        }
    }
    if rc != 0 {
        if errno == EXDEV {
            throw FileUtilsError.crossDevice(source: source.path, destination: destination.path)
        }
        throw posixError(path: destination.path, op: "rename")
    }
    #endif
}

private func applyDirectorySync(_ dir: URL, policy: DirectorySyncPolicy) throws {
    switch policy {
    case .none:
        return
    case .bestEffort:
        try? fsyncDirectoryRequired(dir)
    case .required:
        try fsyncDirectoryRequired(dir)
    }
}

private func fsyncDirectoryRequired(_ dir: URL) throws {
    #if os(Windows)
    // Windows has no portable directory fsync; document as no-op success for
    // NTFS metadata durability (FlushFileBuffers on a directory handle is a
    // future adapter). Callers that need hard guarantees on Windows must use
    // a platform-specific path.
    _ = dir
    #else
    let fd = dir.path.withCString { open($0, O_RDONLY) }
    guard fd >= 0 else {
        throw FileUtilsError.directorySyncFailed(
            path: dir.path,
            detail: "open: \(String(cString: strerror(errno)))"
        )
    }
    defer { close(fd) }
    if fsync(fd) != 0 {
        throw FileUtilsError.directorySyncFailed(
            path: dir.path,
            detail: String(cString: strerror(errno))
        )
    }
    #endif
}

private func mapRenameError(source: String, destination: String, error: Error) -> FileUtilsError {
    let ns = error as NSError
    if ns.domain == NSPOSIXErrorDomain && ns.code == Int(EXDEV) {
        return .crossDevice(source: source, destination: destination)
    }
    #if !os(Windows)
    if errno == EXDEV {
        return .crossDevice(source: source, destination: destination)
    }
    #endif
    return .io(path: destination, detail: error.localizedDescription)
}

#if !os(Windows)
private func posixError(path: String, op: String) -> FileUtilsError {
    posixMap(path: path, op: op)
}

private func writeAll(fd: Int32, data: Data, path: String) throws {
    var written = 0
    let count = data.count
    while written < count {
        let n: Int = data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return sysWrite(fd, base.advanced(by: written), count - written)
        }
        if n < 0 {
            if errno == EINTR { continue }
            throw posixMap(path: path, op: "write")
        }
        if n == 0 { break }
        written += n
    }
}

#if canImport(Darwin)
private func sysWrite(_ fd: Int32, _ buf: UnsafeRawPointer?, _ n: Int) -> Int {
    Darwin.write(fd, buf, n)
}
#elseif canImport(Glibc)
private func sysWrite(_ fd: Int32, _ buf: UnsafeRawPointer?, _ n: Int) -> Int {
    Glibc.write(fd, buf, n)
}
#endif
#endif
