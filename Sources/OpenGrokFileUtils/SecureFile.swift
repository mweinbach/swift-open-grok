// SecureFile.swift
//
// Port of `xai-grok-shell-base::util::secure_file`.
//
// Owner-only file creation for credential-adjacent material:
// - Unix: mode 0o600 via no-follow open + fchmod (never follows a final symlink)
// - Windows: protected DACL granting file read/write only to the owner

import Foundation

#if os(Windows)
import COpenGrokSockets
import WinSDK
#elseif canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Owner-only secure file helpers.
public enum SecureFile: Sendable {
    /// Create parent directories if needed, write `contents`, and enforce
    /// owner-only permissions (Unix `0o600`).
    public static func write(at path: URL, contents: Data) throws {
        try AtomicFile.write(path, data: contents, options: .ownerOnly)
        try ensureOwnerOnlyPermissions(at: path)
    }

    /// UTF-8 convenience wrapper.
    public static func write(at path: URL, contents: String) throws {
        try write(at: path, contents: Data(contents.utf8))
    }

    /// Ensure `path` is owner-read/write only.
    ///
    /// Best-effort on missing files (`notFound` is ignored). Other errors
    /// propagate so callers can fail closed when tightening a secret store.
    ///
    /// Uses descriptor-based no-follow validation: open with `O_NOFOLLOW`,
    /// then `fstat`/`fchmod`. Never follows a final symlink (a hostile
    /// replacement cannot cause chmod of the symlink target).
    public static func ensureOwnerOnlyPermissions(at path: URL) throws {
        do {
            try ensureOwnerOnlyPermissionsInner(at: path)
        } catch let err as FileUtilsError {
            if case .notFound = err { return }
            throw err
        }
    }

    /// Whether the path currently has owner-only mode bits or DACL entries.
    public static func isOwnerOnly(at path: URL) throws -> Bool {
        #if os(Windows)
        try PathSecurity.rejectHostileLexical(path.path)
        let result = path.path.withCString { og_file_is_owner_only($0) }
        if result >= 0 { return result == 1 }
        throw windowsSecureFileError(path: path.path, operation: "inspect owner-only DACL")
        #else
        try PathSecurity.rejectHostileLexical(path.path)
        let fd = try PathSecurity.openFileNoFollow(at: path, flags: O_RDONLY)
        defer { close(fd) }
        var st = stat()
        if fstat(fd, &st) != 0 {
            throw posixMap(path: path.path, op: "fstat")
        }
        return (st.st_mode & 0o777) == 0o600
        #endif
    }
}

private func ensureOwnerOnlyPermissionsInner(at path: URL) throws {
    #if os(Windows)
    try PathSecurity.rejectHostileLexical(path.path)
    let result = path.path.withCString { og_file_apply_owner_only($0) }
    if result == 0 { return }
    let code = Int(og_socket_last_error_code())
    if code == Int(ERROR_FILE_NOT_FOUND) || code == Int(ERROR_PATH_NOT_FOUND) {
        throw FileUtilsError.notFound(path: path.path)
    }
    throw windowsSecureFileError(path: path.path, operation: "apply owner-only DACL")
    #else
    try PathSecurity.rejectHostileLexical(path.path)
    // Open no-follow so a raced symlink is never fchmod'd.
    let fd: Int32
    do {
        fd = try PathSecurity.openFileNoFollow(at: path, flags: O_RDWR)
    } catch let err as FileUtilsError {
        throw err
    }
    defer { close(fd) }
    var st = stat()
    if fstat(fd, &st) != 0 {
        throw posixMap(path: path.path, op: "fstat")
    }
    let mode = st.st_mode & 0o777
    if mode != 0o600 {
        if fchmod(fd, 0o600) != 0 {
            throw FileUtilsError.permissionDenied(
                path: path.path,
                detail: "fchmod 0600: \(String(cString: strerror(errno)))"
            )
        }
    }
    #endif
}

#if os(Windows)
private func windowsSecureFileError(path: String, operation: String) -> FileUtilsError {
    let code = Int(og_socket_last_error_code())
    let detail = String(cString: og_socket_last_error_message())
    return .io(
        path: path,
        detail: "\(operation): \(detail.isEmpty ? "Windows error \(code)" : detail)"
    )
}
#endif
