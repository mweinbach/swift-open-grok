// SecureFile.swift
//
// Port of `xai-grok-shell-base::util::secure_file`.
//
// Owner-only file creation for credential-adjacent material:
// - Unix: mode 0o600 via no-follow open + fchmod (never follows a final symlink)
// - Windows: explicit unsupported until owner-only DACL adapter lands
//   (never reports owner-only success without an enforced ACL)

import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Owner-only secure file helpers.
public enum SecureFile: Sendable {
    /// Create parent directories if needed, write `contents`, and enforce
    /// owner-only permissions (Unix `0o600`).
    public static func write(at path: URL, contents: Data) throws {
        #if os(Windows)
        // Refuse silent weakening: without a DACL adapter, "secure write"
        // cannot uphold the contract.
        throw FileUtilsError.unsupported(
            "Windows owner-only DACL secure write is not yet wired; use Credential Manager"
        )
        #else
        try AtomicFile.write(path, data: contents, options: .ownerOnly)
        try ensureOwnerOnlyPermissions(at: path)
        #endif
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

    /// Whether the path currently has owner-only mode bits on Unix.
    /// On Windows throws `unsupported` — never reports success without a DACL.
    public static func isOwnerOnly(at path: URL) throws -> Bool {
        #if os(Windows)
        _ = path
        throw FileUtilsError.unsupported(
            "Windows owner-only DACL inspection is not yet wired"
        )
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
    _ = path
    throw FileUtilsError.unsupported(
        "Windows owner-only DACL enforcement is not yet wired"
    )
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
