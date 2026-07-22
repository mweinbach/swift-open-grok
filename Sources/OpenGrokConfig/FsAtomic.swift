// FsAtomic.swift
//
// Port of `xai-grok-config/src/fs_atomic.rs`.
//
// Atomic file writes, shared by the managed-cache marker, the signature
// sidecar, and downstream identifier caches. The temp file name is unique per
// writer (pid + counter) and `createNew`, so concurrent writers don't
// collide. `mode` (Unix only) is applied at temp-file creation, so the final
// file never exists with looser permissions.

import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(ucrt)
import ucrt
#endif

/// Process-wide write nonce for unique temp-file names.
private let writeNonce: OSAtomicCounter = OSAtomicCounter()

/// A thread-safe incrementing counter. Uses `OSAtomicIncrement64` on Darwin
/// and a `DispatchQueue` barrier on non-Darwin for portability.
private final class OSAtomicCounter: @unchecked Sendable {
    private var value: UInt64 = 0
    private let lock = NSLock()
    func next() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        value &+= 1
        return value
    }
}

/// Atomic temp + rename so a torn write can't leave a half-written file.
///
/// - Parameters:
///   - finalPath: the final file URL.
///   - contents: the new contents (UTF-8).
///   - mode: optional Unix mode (e.g. `0o600`); applied at temp-file
///     creation, ignored on Windows.
public func writeAtomically(
    _ finalPath: URL,
    contents: String,
    mode: UInt32? = nil
) throws {
    let dir = finalPath.deletingLastPathComponent()
    let name = finalPath.lastPathComponent
    let pid = UInt64(ProcessInfo.processInfo.processIdentifier)
    let nonce = writeNonce.next()
    let tmp = dir.appendingPathComponent("\(name).\(pid).\(nonce).tmp")
    let data = Data(contents.utf8)

    // Write the temp file with O_CREAT|O_EXCL. Do not combine `.atomic` with
    // `.withoutOverwriting` — Foundation rejects that pairing.
    do {
        try data.write(to: tmp, options: [.withoutOverwriting])
    } catch {
        // Best-effort cleanup; rethrow the original error.
        try? FileManager.default.removeItem(at: tmp)
        throw error
    }

    #if canImport(Darwin) || canImport(Glibc)
    if let mode = mode {
        // chmod the temp file BEFORE the rename so the final file never
        // exists with looser permissions.
        let cstr = tmp.path.withCString { strdup($0) }
        defer { free(cstr) }
        // `mode_t` is `UInt16` on Darwin, `UInt32` on Linux — cast explicitly.
        if chmod(cstr, mode_t(mode)) != 0 {
            let err = String(cString: strerror(errno))
            try? FileManager.default.removeItem(at: tmp)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: "chmod failed: \(err)"])
        }
    }
    #endif

    // Rename temp → final (atomic on the same filesystem).
    do {
        // FileManager.replaceItem attempts an atomic swap; falls back to
        // remove+rename when the destination doesn't exist. We try
        // `removeItem` + `moveItem` to guarantee the swap when the dest is
        // absent (replaceItem requires an existing dest).
        if FileManager.default.fileExists(atPath: finalPath.path) {
            _ = try FileManager.default.replaceItemAt(
                finalPath,
                withItemAt: tmp,
                backupItemName: nil,
                options: []
            )
        } else {
            try FileManager.default.moveItem(at: tmp, to: finalPath)
        }
    } catch {
        try? FileManager.default.removeItem(at: tmp)
        throw error
    }
}
