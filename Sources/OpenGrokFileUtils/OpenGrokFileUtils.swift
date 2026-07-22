// OpenGrokFileUtils.swift
//
// Open Grok — Swift port of durable filesystem primitives used by
// sessions, secrets, managed policy, and worktrees.
//
// Reference crates / modules:
//   * `xai-file-utils` — SHA-256 streaming helpers, workspace classifier
//   * `xai-grok-config::fs_atomic` — atomic temp + rename writers
//   * `xai-grok-shell-base::util::secure_file` — owner-only 0o600 files
//
// Platform seams (Darwin / Linux / Windows) surface typed
// `FileUtilsError.unsupported` or `crossDevice` rather than silent no-ops.

import Foundation

/// Module-level convenience re-export of the atomic write entry point used by
/// downstream targets (mirrors `write_atomically` naming in Rust config).
public func writeAtomically(
    _ finalPath: URL,
    contents: String,
    mode: UInt32? = nil
) throws {
    try AtomicFile.write(
        finalPath,
        contents: contents,
        options: AtomicWriteOptions(mode: mode)
    )
}

/// Byte-oriented atomic write.
public func writeAtomically(
    _ finalPath: URL,
    data: Data,
    mode: UInt32? = nil
) throws {
    try AtomicFile.write(
        finalPath,
        data: data,
        options: AtomicWriteOptions(mode: mode)
    )
}
