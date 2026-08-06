// AtomicWrite.swift
//
// Local atomic write helper for catalog caches. Mirrors OpenGrokConfig's
// temp+rename pattern without requiring string conversion of binary JSON.

import Foundation
import OpenGrokShared

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Atomic temp + rename so a torn write can't leave a half-written cache file.
func writeAtomicallyData(_ finalPath: URL, contents: Data, mode: UInt32? = 0o600) throws {
    let dir = finalPath.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let pid = ProcessInfo.processInfo.processIdentifier
    let nonce = UInt64.random(in: 0...UInt64.max)
    let tmp = dir.appendingPathComponent("\(finalPath.lastPathComponent).\(pid).\(nonce).tmp")
    do {
        try contents.write(to: tmp, options: [.withoutOverwriting])
    } catch {
        try? FileManager.default.removeItem(at: tmp)
        throw error
    }
    #if canImport(Darwin) || canImport(Glibc)
    if let mode {
        _ = tmp.path.withCString { chmod($0, mode_t(mode)) }
    }
    #endif
    // Replace destination atomically when possible.
    try atomicallyReplaceItem(at: finalPath, with: tmp)
}
