// AtomicReplace.swift
//
// Platform adapter for the temp-file → final-file step of an atomic write.

import Foundation

#if os(Windows)
import WinSDK
#elseif canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Atomically move `source` onto `destination`, replacing it if it exists.
///
/// Exists because `FileManager.replaceItemAt` is not portable:
/// swift-corelibs-foundation throws `NSFileNoSuchFile` (naming the
/// *destination*, confusingly) instead of replacing an existing file, so every
/// atomic write in this port failed on Linux the moment its target already
/// existed — which is the common case for config, caches, and session state.
///
/// `rename(2)` is the primitive `replaceItemAt` wraps on POSIX: atomic within a
/// filesystem, and it replaces the destination. Darwin keeps `replaceItemAt`
/// because it also handles the cross-volume and preserve-metadata cases this
/// port relies on there.
///
/// Callers must already have `source` fully written and `fsync`'d if they need
/// durability; this only performs the swap.
public func atomicallyReplaceItem(at destination: URL, with source: URL) throws {
    #if os(Windows)
    let maximumAttempts = 40
    for attempt in 0..<maximumAttempts {
        let moved = source.path.withCString(encodedAs: UTF16.self) { sourcePath in
            destination.path.withCString(encodedAs: UTF16.self) { destinationPath in
                MoveFileExW(
                    sourcePath,
                    destinationPath,
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
            throw NSError(
                domain: "OpenGrokShared.AtomicReplace",
                code: Int(code),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "MoveFileExW(\(source.path), \(destination.path)) failed with Windows error \(code)",
                ]
            )
        }
        Sleep(DWORD(min(attempt + 1, 10)))
    }
    #elseif canImport(Darwin)
    // `replaceItemAt` requires an existing original, so a first write has to
    // move instead. `rename(2)` needs no such split, which is why the Linux
    // branch below has no `fileExists` pre-check — and no TOCTOU window.
    if FileManager.default.fileExists(atPath: destination.path) {
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: source)
    } else {
        try FileManager.default.moveItem(at: source, to: destination)
    }
    #else
    let status = source.path.withCString { sourcePath in
        destination.path.withCString { destinationPath in
            rename(sourcePath, destinationPath)
        }
    }
    guard status == 0 else {
        let code = errno
        throw NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [
                NSLocalizedDescriptionKey:
                    "rename(\(source.path), \(destination.path)) failed: "
                    + String(cString: strerror(code)),
            ]
        )
    }
    #endif
}
