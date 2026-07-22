// Errors.swift
//
// Typed errors for durable file operations. Callers must never treat
// unsupported seams as silent success.

import Foundation

/// Errors raised by OpenGrok file utilities.
public enum FileUtilsError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The path does not exist.
    case notFound(path: String)
    /// Permission was denied by the OS.
    case permissionDenied(path: String, detail: String)
    /// Source and destination are on different devices (rename/EXDEV).
    case crossDevice(source: String, destination: String)
    /// Operation is not supported on this platform or configuration.
    case unsupported(String)
    /// A path contained a symlink where no-follow semantics were required.
    case symlinkEncountered(path: String)
    /// Path traversal or hostile path rejected before touching the filesystem.
    case hostilePath(path: String, reason: String)
    /// An I/O failure with a redacted, non-secret description.
    case io(path: String, detail: String)
    /// Lock acquisition failed (busy / timeout / interrupted).
    case lockFailed(path: String, detail: String)
    /// Checksum mismatch between expected and observed digests.
    case checksumMismatch(path: String, expected: String, actual: String)
    /// Directory metadata fsync failed under a required-durability policy.
    case directorySyncFailed(path: String, detail: String)

    public var description: String {
        switch self {
        case .notFound(let path):
            return "file not found: \(path)"
        case .permissionDenied(let path, let detail):
            return "permission denied for \(path): \(detail)"
        case .crossDevice(let source, let destination):
            return "cross-device link \(source) -> \(destination)"
        case .unsupported(let detail):
            return "unsupported: \(detail)"
        case .symlinkEncountered(let path):
            return "symlink encountered under no-follow policy: \(path)"
        case .hostilePath(let path, let reason):
            return "hostile path \(path): \(reason)"
        case .io(let path, let detail):
            return "I/O error at \(path): \(detail)"
        case .lockFailed(let path, let detail):
            return "lock failed for \(path): \(detail)"
        case .checksumMismatch(let path, let expected, let actual):
            return "checksum mismatch for \(path): expected \(expected), got \(actual)"
        case .directorySyncFailed(let path, let detail):
            return "directory fsync failed for \(path): \(detail)"
        }
    }
}

/// Policy for parent-directory fsync after an atomic rename.
public enum DirectorySyncPolicy: String, Sendable, Equatable, Codable, CaseIterable {
    /// Durable default: directory fsync failure is a hard error.
    case required
    /// Best-effort: directory fsync failure is ignored (not the durable default).
    case bestEffort
    /// Skip directory fsync entirely.
    case none
}
